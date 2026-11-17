import SwiftUI
import CoreLocation
import CoreWLAN
import UserNotifications

/// A hub the user named during setup. `prefix` is the first 5 bytes of its BSSID,
/// which both of its bands (2.4 and 5 GHz) share.
struct SavedHub: Codable, Equatable {
    var prefix: String
    var name: String
}

/// Hub names live in ~/Library/Application Support/HubWatch/hubs.json
enum Store {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HubWatch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hubs.json")
    }
    static func load() -> [SavedHub] {
        (try? JSONDecoder().decode([SavedHub].self, from: Data(contentsOf: url))) ?? []
    }
    static func save(_ hubs: [SavedHub]) {
        try? JSONEncoder().encode(hubs).write(to: url)
    }
}

var hubs: [SavedHub] = Store.load()

func normalize(_ bssid: String) -> String {
    bssid.lowercased().split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":")
}
func prefixOf(_ bssid: String) -> String { String(normalize(bssid).prefix(14)) }
func roomName(_ bssid: String) -> String? { hubs.first { bssid.hasPrefix($0.prefix) }?.name }

func quality(_ rssi: Int) -> (label: String, color: Color) {
    switch rssi {
    case (-50)...: return ("Excellent", .green)
    case (-60)...: return ("Good", .green)
    case (-70)...: return ("Fair", .orange)
    default: return ("Weak", .red)
    }
}

struct Reading: Identifiable {
    var id: String { bssid }
    let bssid: String
    let rssi: Int
    let channel: Int
    var band: String { channel > 14 ? "5 GHz" : "2.4 GHz" }
}

final class Model: NSObject, ObservableObject, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
    @Published var history: [String] = []
    private var lastRoom: String?

    // MARK: Setup walk-through
    enum SetupStep { case welcome, finding, recognize, naming, review }
    @Published var setupActive = hubs.isEmpty
    @Published var step: SetupStep = .welcome
    @Published var candidate: String?
    @Published var candidateRSSI = 0
    @Published var nameDraft = ""
    @Published var hint = ""
    @Published var ssid = ""

    /// Best signal seen for each hub (keyed by BSSID prefix).
    var foundPrefixes: [String: Int] {
        var d: [String: Int] = [:]
        for r in scan { let p = prefixOf(r.bssid); d[p] = max(d[p] ?? -200, r.rssi) }
        return d
    }

    /// Hubs that were found but not named yet, strongest first.
    var unnamedPrefixes: [(prefix: String, rssi: Int)] {
        foundPrefixes.filter { p in !hubs.contains { $0.prefix == p.key } }
            .map { (prefix: $0.key, rssi: $0.value) }
            .sorted { $0.rssi > $1.rssi }
    }

    /// Hubs the user chose to skip during this setup run.
    @Published var skipped: Set<String> = []

    /// Unnamed hubs that haven't been skipped.
    var pendingPrefixes: [(prefix: String, rssi: Int)] { unnamedPrefixes.filter { !skipped.contains($0.prefix) } }

    /// Skip the hub currently shown as strongest; name it later with "Name more hubs".
    func skipCurrent() {
        if let top = pendingPrefixes.first { skipped.insert(top.prefix) }
        hint = ""
        if pendingPrefixes.isEmpty { step = .review }
    }

    /// Pick the strongest unnamed hub, but only if the user is standing next to it.
    func recognize() {
        guard let top = pendingPrefixes.first else {
            hint = "No unnamed hub found. Wait a few seconds and try again."
            return
        }
        if top.rssi < -55 {
            hint = "The closest unnamed hub is \(top.rssi) dBm. Move right next to it (-55 dBm or stronger) and try again."
            return
        }
        candidate = top.prefix
        candidateRSSI = top.rssi
        nameDraft = ""
        hint = ""
        step = .naming
    }

    func saveName() {
        let n = nameDraft.trimmingCharacters(in: .whitespaces)
        guard let c = candidate, !n.isEmpty else { hint = "Enter a name for this hub."; return }
        hubs.append(SavedHub(prefix: c, name: n))
        Store.save(hubs)
        candidate = nil
        hint = ""
        step = pendingPrefixes.isEmpty ? .review : .recognize
        objectWillChange.send()
    }

    func finishSetup() { setupActive = false; lastRoom = nil }

    func nameMoreHubs() { hint = ""; skipped = []; step = .recognize; setupActive = true }

    func redoSetup() {
        hubs = []
        Store.save(hubs)
        skipped = []
        hint = ""
        history = []
        lastRoom = nil
        step = .welcome
        setupActive = true
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Log and announce a move from one hub to another.
    private func trackRoaming() {
        guard let c = connected, let room = roomName(c.bssid) else { return }
        if let prev = lastRoom, prev != room {
            let t = Date().formatted(date: .omitted, time: .standard)
            history.insert("\(t)  \(prev) → \(room)  (\(c.rssi) dBm, \(c.band))", at: 0)
            history = Array(history.prefix(8))
            notify("Moved to \(room)", "From \(prev) · \(c.rssi) dBm · \(c.band)")
        }
        lastRoom = room
    }

    @Published var authorized = false
    @Published var connected: Reading?
    @Published var scan: [Reading] = []
    @Published var updated = "never"
    @Published var status = ""
    @Published var busy = false
    private var networks: [String: CWNetwork] = [:]
    private let lm = CLLocationManager()
    @Published var scanning = false

    private var cancelled = false

    func stopSwitching() { cancelled = true; status = "Stopping…" }

    /// Sleep that ends early when Stop is pressed.
    private func wait(_ seconds: Double) {
        var left = seconds
        while left > 0 && !cancelled { Thread.sleep(forTimeInterval: 0.25); left -= 0.25 }
    }

    private func isOn(_ prefix: String, _ i: CWInterface) -> Bool {
        i.bssid().map { normalize($0).hasPrefix(prefix) } ?? false
    }

    /// Ask macOS to join a specific hub; if that doesn't land there, power-cycle Wi-Fi and retry.
    func force(to room: String) {
        guard !busy, let i = CWWiFiClient.shared().interface(),
              let prefix = hubs.first(where: { $0.name == room })?.prefix else { return }
        let cands = scan.filter { $0.bssid.hasPrefix(prefix) }
        let strongest = cands.max { $0.rssi < $1.rssi }
        let fiveG = cands.filter { $0.channel > 14 }.max { $0.rssi < $1.rssi }
        // Prefer 5 GHz (faster) unless it is more than 10 dB weaker than the strongest band.
        let target: Reading? = {
            if let f = fiveG, let s = strongest, f.rssi >= s.rssi - 10 { return f }
            return strongest
        }()
        let net = target.flatMap { networks[$0.bssid] }
        cancelled = false
        busy = true
        status = "Switching to \(room)\(target.map { " (\($0.band))" } ?? "")…"
        DispatchQueue.global().async {
            var note = ""
            for attempt in 1...5 {
                if self.cancelled { break }
                DispatchQueue.main.async { self.status = "Switching to \(room)… try \(attempt) of 5" }
                if let net {
                    do { try i.associate(to: net, password: nil) } catch { note = error.localizedDescription }
                    self.wait(5)
                    if self.cancelled || self.isOn(prefix, i) { break }
                }
                do { try i.setPower(false); self.wait(1); try i.setPower(true) }
                catch { note = error.localizedDescription }
                self.wait(7)
                if self.cancelled || self.isOn(prefix, i) { break }
            }
            let ok = self.isOn(prefix, i)
            let stopped = self.cancelled
            DispatchQueue.main.async {
                self.busy = false
                self.status = stopped ? "Stopped." : ok ? "Now connected to \(room)."
                                 : "Couldn't move to \(room) after 5 tries.\(note.isEmpty ? "" : " (\(note))") The mesh may keep choosing another hub."
                self.refresh()
            }
        }
    }

    override init() {
        super.init()
        lm.delegate = self
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        lm.requestWhenInUseAuthorization()
        updateAuth()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self.refresh() }
        refresh()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { updateAuth(); refresh() }

    private func updateAuth() {
        let s = lm.authorizationStatus
        authorized = (s == .authorizedAlways || s == .authorized)
    }

    func refresh() {
        guard authorized, !scanning, !busy, let i = CWWiFiClient.shared().interface() else { return }
        if let b = i.bssid() {
            connected = Reading(bssid: normalize(b), rssi: i.rssiValue(), channel: i.wlanChannel()?.channelNumber ?? 0)
        } else {
            connected = nil
        }
        trackRoaming()
        if let s = i.ssid() { ssid = s }
        let homeSSID = ssid
        guard !homeSSID.isEmpty else { return }
        scanning = true
        DispatchQueue.global().async {
            let nets = (try? i.scanForNetworks(withSSID: nil)) ?? []
            let home = nets.filter { $0.ssid == homeSSID }
            let rows = home.map {
                Reading(bssid: normalize($0.bssid ?? "?"), rssi: $0.rssiValue, channel: $0.wlanChannel?.channelNumber ?? 0)
            }
            let byBSSID = Dictionary(home.map { (normalize($0.bssid ?? "?"), $0) }, uniquingKeysWith: { a, _ in a })
            DispatchQueue.main.async {
                self.scan = rows
                self.networks = byBSSID
                self.updated = Date().formatted(date: .omitted, time: .standard)
                self.scanning = false
            }
        }
    }

    /// Strongest reading per room, strongest room first.
    var rooms: [(name: String, best: Reading, all: [Reading])] {
        hubs.compactMap { hub in
            let r = scan.filter { $0.bssid.hasPrefix(hub.prefix) }.sorted { $0.rssi > $1.rssi }
            return r.first.map { (hub.name, $0, r) }
        }.sorted { $0.best.rssi > $1.best.rssi }
    }

    var summary: String {
        var lines = ["Connected: \(connected.flatMap { roomName($0.bssid) } ?? "unknown") \(connected.map { "\($0.bssid) \($0.rssi) dBm ch\($0.channel)" } ?? "")"]
        for r in rooms { for x in r.all { lines.append("\(r.name): \(x.bssid) \(x.rssi) dBm ch\(x.channel) \(x.band)") } }
        return lines.joined(separator: "\n")
    }
}

struct SignalBar: View {
    let rssi: Int
    var body: some View {
        let pct = max(0.05, min(1, Double(rssi + 90) / 50))
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            GeometryReader { g in Capsule().fill(quality(rssi).color).frame(width: g.size.width * pct) }
        }
        .frame(width: 110, height: 8)
    }
}

/// First-run walk-through: find the hubs, then name them one by one.
struct SetupView: View {
    @ObservedObject var m: Model
    private let suggestions = ["Living room", "Dining room", "Hallway", "Kitchen", "Bedroom", "Office", "Basement", "Garage"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch m.step {
            case .welcome: welcome
            case .finding: finding
            case .recognize: recognize
            case .naming: naming
            case .review: review
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(_ t: String) -> some View { Text(t).font(.system(size: 28, weight: .bold)) }
    private func hintText() -> some View {
        Group { if !m.hint.isEmpty { Text(m.hint).foregroundStyle(.orange) } }
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Welcome to HubWatch")
            Text("HubWatch shows which Google Wifi hub your Mac is connected to, and how strong the signal is. Setup takes about a minute: you'll walk up to each hub and give it a name.")
            if m.authorized {
                Button("Start setup") { m.step = .finding }
            } else {
                Text("First, allow Location access when macOS asks. macOS needs it to tell which hub you're on. HubWatch never stores or sends your location.")
                    .foregroundStyle(.secondary)
                Text("Missed the prompt? System Settings > Privacy & Security > Location Services > HubWatch.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Waiting for permission…") }
            }
        }
    }

    var finding: some View {
        let n = m.foundPrefixes.count
        return VStack(alignment: .leading, spacing: 14) {
            title("Finding your hubs")
            if n == 0 {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for Wi-Fi points on \"\(m.ssid)\"…") }
            } else {
                Text("Found \(n) Wi-Fi point\(n == 1 ? "" : "s") on \"\(m.ssid)\".").font(.title3)
                Text("Each hub appears on two bands (2.4 and 5 GHz) but counts once.").foregroundStyle(.secondary)
                if n == 1 {
                    Text("Only one found. If you have more hubs, they may be out of range. You can name the rest later.")
                        .foregroundStyle(.secondary)
                }
                Button("Continue") { m.step = .recognize }
            }
        }
    }

    var recognize: some View {
        let named = hubs.count
        let total = named + m.unnamedPrefixes.count
        return VStack(alignment: .leading, spacing: 14) {
            title("Hub \(min(named + 1, max(total, 1))) of \(max(total, 1))")
            Text("Stand right next to the hub you want to name, then press Recognize.").font(.title3)
            if let top = m.pendingPrefixes.first {
                HStack(spacing: 10) {
                    SignalBar(rssi: top.rssi)
                    Text("Strongest unnamed hub now: \(top.rssi) dBm").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 16) {
                Button("Recognize this hub") { m.recognize() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Skip this hub") { m.skipCurrent() }
                    .buttonStyle(.link)
            }
            hintText()
            if named > 0 { Button("Finish setup") { m.step = .review } }
        }
    }

    var naming: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Got it")
            Text("Signal \(m.candidateRSSI) dBm, so you're next to it. What do you call this one?").font(.title3)
            TextField("For example: Hallway", text: $m.nameDraft)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                .onSubmit { m.saveName() }
            VStack(alignment: .leading, spacing: 6) {
                Text("Or pick a name").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(suggestions.filter { s in !hubs.contains { $0.name == s } }.prefix(5), id: \.self) { s in
                        Button { m.nameDraft = s } label: {
                            Text(s).font(.callout).padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(m.nameDraft == s ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.15)))
                                .overlay(Capsule().stroke(m.nameDraft == s ? Color.accentColor : Color.clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 16) {
                Button("Save hub") { m.saveName() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { m.hint = ""; m.step = .recognize }
                    .buttonStyle(.link)
            }
            .padding(.top, 8)
            hintText()
        }
    }

    var review: some View {
        let left = m.unnamedPrefixes.count
        return VStack(alignment: .leading, spacing: 14) {
            title("Your hubs")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(hubs, id: \.prefix) { h in
                    HStack {
                        Text(h.name).font(.body.weight(.semibold))
                        Text(h.prefix).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            if left > 0 {
                Text("\(left) hub\(left == 1 ? "" : "s") not named yet.").foregroundStyle(.orange)
                Button("Name another") { m.skipped = []; m.step = .recognize }
            }
            Button("Done") { m.finishSetup() }
        }
    }
}

struct ContentView: View {
    @ObservedObject var m: Model

    var body: some View {
        Group {
            if m.setupActive {
                SetupView(m: m).padding(22).frame(minWidth: 680, minHeight: 440)
            } else {
                mainBody
            }
        }
    }

    var mainBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !m.authorized {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Location permission needed").font(.title2.bold())
                    Text("macOS only reveals which hub you're on when Location is allowed.\nSystem Settings > Privacy & Security > Location Services > HubWatch.")
                        .foregroundStyle(.secondary)
                }
            } else {
                header
                Text("Hubs nearby").font(.headline)
                VStack(spacing: 10) {
                    ForEach(m.rooms, id: \.name) { room in row(room) }
                    if m.rooms.isEmpty { Text("Scanning…").foregroundStyle(.secondary) }
                }
                if !m.status.isEmpty {
                    HStack(spacing: 8) {
                        if m.busy { ProgressView().controlSize(.small) }
                        Text(m.status).font(.callout)
                        if m.busy { Button("Stop") { m.stopSwitching() } }
                    }
                }
                if !m.history.isEmpty {
                    Text("Recent moves").font(.headline)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(m.history, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button { m.refresh() } label: {
                    Label(m.scanning ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }
                Button("Copy details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(m.summary, forType: .string)
                }
                Button("Redo setup") { m.redoSetup() }
                if !m.unnamedPrefixes.isEmpty {
                    Button("Name \(m.unnamedPrefixes.count) more hub\(m.unnamedPrefixes.count == 1 ? "" : "s")") { m.nameMoreHubs() }
                }
                Spacer()
                Text("Updated \(m.updated)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(minWidth: 680, minHeight: 600)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }

    var header: some View {
        let c = m.connected
        let q = c.map { quality($0.rssi) }
        return VStack(alignment: .leading, spacing: 4) {
            Text("You're connected to").font(.subheadline).foregroundStyle(.secondary)
            Text(c.flatMap { roomName($0.bssid) } ?? (c == nil ? "Not connected" : "Unknown hub"))
                .font(.system(size: 34, weight: .bold))
            if let c, let q {
                HStack(spacing: 8) {
                    Circle().fill(q.color).frame(width: 10, height: 10)
                    Text("\(q.label) · \(c.rssi) dBm · \(c.band) (channel \(c.channel))")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    func row(_ room: (name: String, best: Reading, all: [Reading])) -> some View {
        let here = m.connected.map { roomName($0.bssid) == room.name } ?? false
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(room.name).font(.body.weight(.semibold)).lineLimit(1).fixedSize()
                    if here { Text("You're here").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor)).foregroundStyle(.white).lineLimit(1).fixedSize() }
                }
                Text(room.all.map { "\($0.band) \($0.rssi) dBm" }.joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text(quality(room.best.rssi).label).font(.caption).foregroundStyle(.secondary)
            SignalBar(rssi: room.best.rssi)
            Button("Switch here") { m.force(to: room.name) }
                .disabled(here || m.busy)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).stroke(here ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: here ? 2 : 1))
    }
}

@main
struct HubWatchApp: App {
    @StateObject var model = Model()
    @Environment(\.openWindow) var openWindow

    var room: String? { model.connected.flatMap { roomName($0.bssid) } }
    var shortLabel: String {
        guard model.authorized else { return "📶?" }
        guard !model.setupActive else { return "📶 Setup" }
        guard model.connected != nil else { return "📶 off" }
        return "📶 " + (room.map { String($0.split(separator: " ").first ?? "") } ?? "Unknown")
    }

    var body: some Scene {
        Window("HubWatch", id: "main") { ContentView(m: model) }
        MenuBarExtra {
            if let c = model.connected {
                Text("\(room ?? "Unknown hub") · \(quality(c.rssi).label) · \(c.rssi) dBm")
            } else {
                Text(model.authorized ? "Not connected" : "Location permission needed")
            }
            Divider()
            Button("Open HubWatch") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Text(shortLabel)
        }
    }
}

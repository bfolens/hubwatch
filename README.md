# HubWatch

A small Mac app that shows which Google Wifi hub your Mac is connected to, and how strong the signal is.

- Shows the hub you're on by room name ("Dining room"), with signal quality, band (2.4 or 5 GHz) and channel.
- Lists every hub in range with a signal bar, refreshed every 5 seconds.
- Menu bar icon with the current hub (for example `📶 Dining`).
- Notifies you when your Mac moves from one hub to another, and keeps a short history.
- **Switch here** button that asks your Mac to move to a hub (see the limits below).
- First-run setup that walks you through naming each hub.

Google Wifi / Nest Wifi only for now.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (provides `swiftc`): `xcode-select --install`
- A Google Wifi or Nest Wifi mesh, with your Mac connected to it

## Install

```bash
git clone <this-repo-url>
cd <repo-folder>/HubWatch
bash install.sh
```

This builds the app, copies it to `~/Applications/HubWatch.app`, and sets it to open at every login.
To build without installing, run `bash build.sh` and open `HubWatch.app`.

To stop it opening at login:

```bash
bash install.sh --remove
```

## First-run setup

macOS only tells an app which access point it's connected to when Location Services is allowed, so the first launch asks for that. HubWatch never stores or sends your location.

If you missed the prompt: System Settings > Privacy & Security > Location Services > HubWatch.

Then the setup walks you through your hubs:

1. **Find your hubs.** HubWatch scans and reports how many Wi-Fi points it found on your network.
2. **Recognize each hub.** Stand right next to a hub and press **Recognize this hub**. It picks the strongest hub that isn't named yet, and only accepts it if the signal is -55 dBm or stronger, which means you're next to it.
3. **Name it.** Type a name or tap a suggestion, then **Save hub**. Repeat for the next hub.
4. **Skip if you need to.** **Skip this hub** moves on without naming the hub currently shown as strongest. You can name it later.
5. **Review.** Check the list and press **Done**.

In the main window, **Refresh** rescans right away, **Redo setup** starts over (it clears the saved names), and **Name more hubs** appears if a hub was found but never named.

## Reading the window

| Signal | Label |
|---|---|
| -50 dBm or stronger | Excellent |
| -50 to -60 | Good |
| -60 to -70 | Fair |
| weaker than -70 | Weak |

Each hub row shows both bands. A hub appears twice in a scan (2.4 and 5 GHz), but counts as one hub.

## Switch here: what it can and can't do

Pressing **Switch here** asks macOS to join a hub's access point (preferring 5 GHz when it's within 10 dB of the strongest band). If that doesn't land there, it turns Wi-Fi off and on and checks again, up to 5 tries. **Stop** ends it early.

- It works best for moving to the **closest** hub, for example when your Mac is stuck on a far one.
- Moving to a **farther** hub usually fails or doesn't last. macOS often answers `tmpErr`, and the mesh moves your Mac back to the strongest hub.
- Google Wifi doesn't offer a way to pin a device to one hub.

## How it finds hubs

Every access point has an address called a BSSID. The first 5 bytes are the same for a hub's 2.4 and 5 GHz radios (for example `aa:bb:cc:dd:ee`). HubWatch treats every access point that broadcasts your current network name as one of your hubs, groups them by that prefix, and maps each prefix to the name you gave it.

## Files

| Path | What it is |
|---|---|
| `HubWatch/HubWatch.swift` | The whole app (SwiftUI, CoreWLAN, CoreLocation) |
| `HubWatch/build.sh` | Builds and ad-hoc signs `HubWatch.app` |
| `HubWatch/install.sh` | Builds, installs to `~/Applications`, adds the login item |
| `~/Library/Application Support/HubWatch/hubs.json` | Your saved hub names |
| `~/Library/LaunchAgents/local.hubwatch.plist` | The login item (created by `install.sh`) |
| `lan-scanner/app.py` | A separate, optional tool: a local web page listing every device on your network with ping latency (`python3 lan-scanner/app.py`, then open http://localhost:8787) |
| `LICENSE` | MIT license |

## Troubleshooting

- **Window says "Location permission needed".** Allow it in System Settings > Privacy & Security > Location Services. After a rebuild the app has a new signature, so macOS may ask again.
- **Menu bar icon isn't visible.** On a laptop with a notch, a crowded menu bar can hide it. Hold Cmd and drag a few other icons off the bar, and check System Settings > Menu Bar > Allow in the Menu Bar. The window works without it.
- **No notifications.** Allow HubWatch in System Settings > Notifications. The Recent moves list works either way.
- **Setup finds no hubs.** Make sure your Mac is on the Google Wifi network, and that Location is allowed.
- **A hub shows as unnamed.** It was found but never named. Press **Name more hubs**.
- **Setup says the signal is too weak.** You aren't close enough to the hub. Move within a few feet of it.

## Limits

- Google Wifi doesn't say which hub each other device (phone, TV) uses, so HubWatch only knows about your Mac.
- Latency and signal are measured from your Mac's position, not from the hubs themselves.
- Ad-hoc signed, for personal use. It isn't notarized, so don't expect to share the app as-is with other people.

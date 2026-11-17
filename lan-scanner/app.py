#!/usr/bin/env python3
"""Rudimentary home Wi-Fi monitor: lists devices on the LAN with ping-based quality.
Run: python3 app.py   then open http://localhost:8787
"""
import json, re, socket, subprocess, threading, time, ipaddress
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8787
REFRESH_SECONDS = 60
state = {"devices": [], "updated": None, "scanning": False}


def sh(cmd, timeout=15):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def local_network():
    gw = re.search(r"gateway: (\S+)", sh(["route", "-n", "get", "default"]))
    gateway = gw.group(1) if gw else "192.168.1.1"
    return gateway, ipaddress.ip_network(gateway + "/24", strict=False)


def ping(ip, count=3):
    out = sh(["ping", "-c", str(count), "-t", "5", ip], timeout=10)
    loss = re.search(r"([\d.]+)% packet loss", out)
    rtt = re.search(r"= [\d.]+/([\d.]+)/", out)
    return (float(loss.group(1)) if loss else 100.0,
            float(rtt.group(1)) if rtt else None)


def hostname(ip):
    try:
        return socket.gethostbyaddr(ip)[0].replace(".lan", "").replace(".local", "")
    except Exception:
        return ""


def quality(loss, rtt):
    if rtt is None or loss >= 50:
        return "poor"
    if loss > 0 or rtt > 80:
        return "fair"
    return "good" if rtt <= 30 else "ok"


def scan():
    state["scanning"] = True
    gateway, net = local_network()
    ips = [str(i) for i in net.hosts()]
    with ThreadPoolExecutor(64) as ex:
        list(ex.map(lambda ip: ping(ip, 1), ips))  # populate ARP table
    found = {}
    for line in sh(["arp", "-an"]).splitlines():
        m = re.match(r"\? \(([\d.]+)\) at ([0-9a-f:]+)", line)
        if m and m.group(1) in ips:
            mac = ":".join(p.zfill(2) for p in m.group(2).split(":"))
            found[m.group(1)] = mac

    def probe(ip):
        loss, rtt = ping(ip, 3)
        return {"ip": ip, "mac": found[ip], "name": hostname(ip),
                "loss": loss, "rtt": rtt, "quality": quality(loss, rtt),
                "gateway": ip == gateway}

    with ThreadPoolExecutor(32) as ex:
        devices = list(ex.map(probe, found))
    devices.sort(key=lambda d: tuple(int(x) for x in d["ip"].split(".")))
    state.update(devices=devices, updated=time.strftime("%H:%M:%S"), scanning=False)


def loop():
    while True:
        scan()
        time.sleep(REFRESH_SECONDS)


PAGE = """<!doctype html><meta charset=utf-8><title>Wi-Fi Monitor</title>
<style>
body{font:15px system-ui;margin:2rem auto;max-width:820px;padding:0 1rem}
table{border-collapse:collapse;width:100%}td,th{padding:6px 10px;border-bottom:1px solid #ddd;text-align:left}
.dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px}
.good{background:#2e9e4f}.ok{background:#8bc34a}.fair{background:#f0a500}.poor{background:#d93a3a}
small{color:#666}
</style>
<h2>Devices on my network</h2><small id=meta>loading…</small>
<table><thead><tr><th>Quality<th>Name<th>IP<th>MAC<th>Latency<th>Loss</tr></thead><tbody id=rows></tbody></table>
<script>
async function load(){
 const d=await (await fetch('/api/devices')).json();
 meta.textContent=(d.scanning?'Scanning… ':'')+d.devices.length+' devices · updated '+(d.updated||'never');
 rows.innerHTML=d.devices.map(x=>`<tr><td><span class="dot ${x.quality}"></span>${x.quality}
 <td>${x.name||'—'}${x.gateway?' (router)':''}<td>${x.ip}<td>${x.mac}
 <td>${x.rtt==null?'—':x.rtt.toFixed(1)+' ms'}<td>${x.loss}%</tr>`).join('');
}
load();setInterval(load,5000);
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/devices":
            body, ctype = json.dumps(state).encode(), "application/json"
        else:
            body, ctype = PAGE.encode(), "text/html"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    threading.Thread(target=loop, daemon=True).start()
    print(f"http://localhost:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()

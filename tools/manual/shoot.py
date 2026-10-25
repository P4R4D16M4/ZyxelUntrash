#!/usr/bin/env python3
"""Screenshots of Untrash Desk for the user guide (docs/user-guide/img/d*.webp).

  python3 tools/manual/shoot.py            all Desk screenshots
  python3 tools/manual/shoot.py d03 d47    only these
  python3 tools/manual/shoot.py --list     the scenario names

The Desk runs in its PC test mode (untrashos/image/tests/test-desk-host.py
builds the root) with example data only: users anna, ben, clara, the shares
Documents, Music, Photos, Videos, host name familynas, network 192.0.2.x.
Commands the Desk runs to read the system (ip, systemctl, lsblk, smartctl,
journalctl, ...) are stubs with example output, so nothing of the PC that
runs this ends up in a picture.  A headless Chromium (Debian package
"chromium") is driven over the DevTools protocol; no other dependency.
The installer screenshots (i*.webp) are not made here.
"""
import base64
import importlib.util
import io
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OS = os.path.join(ROOT, "untrashos")
IMG = os.path.join(ROOT, "docs", "user-guide", "img")
W, H = 1440, 900


# ------------------------------------------------------------- DevTools client (stdlib websocket)

class CDP:
    def __init__(self, ws_url):
        u = urllib.parse.urlsplit(ws_url)
        self.s = socket.create_connection((u.hostname, u.port))
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (u.path, u.hostname, u.port, key)).encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += self.s.recv(4096)
        if b" 101 " not in resp.split(b"\r\n")[0]:
            raise RuntimeError("DevTools handshake failed: %r" % resp[:200])
        self.buf, self.n = resp.split(b"\r\n\r\n", 1)[1], 0

    def _read(self, n):
        while len(self.buf) < n:
            c = self.s.recv(1 << 20)
            if not c:
                raise RuntimeError("DevTools connection closed")
            self.buf += c
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _frame(self):
        data = b""
        while True:
            b0, b1 = self._read(2)
            ln = b1 & 0x7f
            if ln == 126:
                ln = struct.unpack(">H", self._read(2))[0]
            elif ln == 127:
                ln = struct.unpack(">Q", self._read(8))[0]
            data += self._read(ln)
            if b0 & 0x80:
                return data

    def call(self, method, **params):
        self.n += 1
        msg = json.dumps({"id": self.n, "method": method, "params": params}).encode()
        hdr = bytes([0x81]) + (bytes([0x80 | len(msg)]) if len(msg) < 126 else
                               bytes([0x80 | 126]) + struct.pack(">H", len(msg)) if len(msg) < 65536 else
                               bytes([0x80 | 127]) + struct.pack(">Q", len(msg)))
        mask = os.urandom(4)
        self.s.sendall(hdr + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(msg)))
        while True:
            r = json.loads(self._frame())
            if r.get("id") == self.n:
                if "error" in r:
                    raise RuntimeError("%s: %s" % (method, r["error"]))
                return r.get("result", {})

    def js(self, code, timeout=30):
        """Run an async JS snippet in the page; returns its value."""
        wrapped = ("Promise.race([(async () => {%s})(), new Promise((_, no) => setTimeout(() => no(new Error('scenario timed out')), %d))])"
                   % (code, timeout * 1000))
        r = self.call("Runtime.evaluate", expression=wrapped, awaitPromise=True,
                      returnByValue=True, timeout=timeout * 1000)
        if r.get("exceptionDetails"):
            raise RuntimeError("JS: %s" % r["exceptionDetails"].get("exception", {}).get("description", r["exceptionDetails"]))
        return (r.get("result") or {}).get("value")

    def shot(self, path, height=H):
        from PIL import Image
        self.call("Emulation.setDeviceMetricsOverride", width=W, height=height, deviceScaleFactor=1, mobile=False)
        time.sleep(0.4)
        png = base64.b64decode(self.call("Page.captureScreenshot", format="png")["data"])
        Image.open(io.BytesIO(png)).convert("RGB").save(path, "WEBP", quality=88, method=6)
        if height != H:
            self.call("Emulation.setDeviceMetricsOverride", width=W, height=H, deviceScaleFactor=1, mobile=False)


# ------------------------------------------------------------- example system

STUBS = {
    "ip": "echo '2: eth0    inet 192.0.2.20/24 brd 192.0.2.255 scope global eth0\\       valid_lft forever preferred_lft forever'",
    "systemctl": 'case "$2" in smbd|ssh|vsftpd|nfs-server|minidlna|chrony|hd-idle|avahi-daemon|'
                 'smbd.service|ssh.service|vsftpd.service|nfs-server.service|minidlna.service|chrony.service|hd-idle.service|'
                 'avahi-daemon.service) echo active;; *) echo inactive;; esac',
    "lsblk": "cat <<'J'\n" + json.dumps({"blockdevices": [
        {"name": "sda", "path": "/dev/sda", "size": 4000787030016, "type": "disk", "tran": "sata", "model": "WDC WD40EFRX-68N32N0",
         "serial": "WD-EXAMPLE0001", "fstype": None, "partlabel": None, "mountpoint": None},
        {"name": "sdb", "path": "/dev/sdb", "size": 4000787030016, "type": "disk", "tran": "sata", "model": "WDC WD40EFRX-68N32N0",
         "serial": "WD-EXAMPLE0002", "fstype": None, "partlabel": None, "mountpoint": None}]}) + "\nJ",
    "smartctl": "echo 'SMART overall-health self-assessment test result: PASSED'; "
                "echo '194 Temperature_Celsius     0x0022   116   104   000    Old_age   Always       -       34'",
    "journalctl": "cat <<'L'\n"
                  "2026-10-18T12:30:57+0200 familynas systemd[1]: Started untrash-desk.service - Untrash Desk.\n"
                  "2026-10-18T12:30:59+0200 familynas smbd[812]: smbd version 4.17 started.\n"
                  "2026-10-18T12:31:03+0200 familynas untrash-storage[640]: md2: raid1 [UU] clean, volume Volume1 mounted\n"
                  "2026-10-18T13:02:41+0200 familynas minidlnad[901]: media scan finished: 1243 files\n"
                  "2026-10-18T13:05:25+0200 familynas sshd[1203]: Accepted publickey for admin from 192.0.2.50 port 51022\n"
                  "2026-10-18T13:07:02+0200 familynas untrash-desk[780]: login admin from 192.0.2.50\n"
                  "2026-10-18T14:00:01+0200 familynas untrash-backup[1502]: job \"Photos to USB\": 12 files, 84 MB, done\n"
                  "L",
    "lpstat": "true", "repquota": "true", "blkid": "true", "findfs": "true",
}


def load_test_helpers():
    spec = importlib.util.spec_from_file_location("tdh", os.path.join(OS, "image/tests/test-desk-host.py"))
    m = importlib.util.module_from_spec(spec)
    sys.argv, argv = [sys.argv[0]], sys.argv           # the module must not run its own main
    spec.loader.exec_module(m)
    sys.argv = argv
    return m


def demo_jpg(path, hue, w=1600, h=1067):
    from PIL import Image, ImageDraw
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    for y in range(h):                    # a sky-to-ground gradient, different per picture
        t = y / h
        d.line([(0, y), (w, y)], fill=(int(40 + 180 * t * hue[0]), int(80 + 120 * (1 - t) * hue[1]), int(120 + 110 * (1 - t) * hue[2])))
    d.ellipse((w * 0.62, h * 0.18, w * 0.78, h * 0.42), fill=(255, 226, 150))
    im.save(path, "JPEG", quality=80)


def build(w, tdh, port):
    r, stick = tdh.build_root(w)
    open(r + "/etc/untrash-version", "w").write("1.1\n")
    for vol, label, size, free in (("aaaa0001", "Volume1", 4000000000000, 2200000000000),
                                   ("sysvol-real", "System", 4000000000000, 2200000000000)):
        os.makedirs(r + "/i-data/%s/.system" % vol, exist_ok=True)
        open(r + "/i-data/%s/.system/name_label" % vol, "w").write(label)
        open(r + "/i-data/%s/.system/test_df" % vol, "w").write("%d %d\n" % (size, free))
    # live values for Status: two disks, eth0 with traffic, a booted slot
    os.makedirs(r + "/run/untrash", exist_ok=True)
    open(r + "/run/untrash/boot.env", "w").write("ZT_BOOT=nand\nZT_SLOT=a\n")
    for d in ("sda", "sdb"):
        os.makedirs(r + "/sys/block/%s" % d, exist_ok=True)
        open(r + "/sys/block/%s/removable" % d, "w").write("0\n")
    os.makedirs(r + "/sys/class/net/eth0", exist_ok=True)
    open(r + "/sys/class/net/eth0/operstate", "w").write("up\n")
    bindir = os.path.join(w, "bin")
    os.makedirs(bindir)
    for n, sh in STUBS.items():
        open(os.path.join(bindir, n), "w").write("#!/bin/sh\n" + sh + "\n")
        os.chmod(os.path.join(bindir, n), 0o755)
    env = tdh.env_for(r, stick, port)
    env["PATH"] = bindir + ":" + env["PATH"]
    return r, env


DEMO_PROCS = [  # pid, name, ppid, uid, cpu ticks per tick, rss pages, command
    (1, "systemd", 0, 0, 0, 2900, "/sbin/init"), (2, "kthreadd", 0, 0, 0, 0, ""), (41, "kworker/0:1", 2, 0, 0, 0, ""),
    (512, "systemd-journal", 1, 0, 0, 3100, "/usr/lib/systemd/systemd-journald"),
    (780, "untrash-desk", 1, 0, 3, 9800, "/usr/bin/python3 /usr/lib/untrash/untrash-desk"),
    (812, "smbd", 1, 0, 1, 5200, "/usr/sbin/smbd --foreground --no-process-group"),
    (901, "minidlnad", 1, 104, 9, 4100, "/usr/sbin/minidlnad -S -f /etc/minidlna.conf"),
    (955, "dnsmasq", 1, 105, 0, 900, "/usr/sbin/dnsmasq -k --conf-file=/etc/untrash/adblock/dnsmasq.conf"),
    (1203, "sshd", 1, 0, 0, 1700, "sshd: /usr/sbin/sshd -D [listener]"),
    (1502, "rclone", 1, 0, 6, 7400, "rclone sync /i-data/aaaa0001/Photos dropbox:Photos"),
    (1610, "ffmpeg", 780, 0, 14, 12800, "ffmpeg -re -f concat -i /run/untrash/tv/holiday.txt -c:v libx264 -f hls index.m3u8"),
]


def live_ticker(r, stop):
    """/proc/stat and /proc/net/dev that move, so Status shows load and traffic."""
    t = 0
    for pid, name, ppid, uid, _c, _rss, cmd in DEMO_PROCS:
        os.makedirs(r + "/proc/%d" % pid, exist_ok=True)
        open(r + "/proc/%d/status" % pid, "w").write("Name:\t%s\nUid:\t%d\t%d\t%d\t%d\n" % (name, uid, uid, uid, uid))
        open(r + "/proc/%d/cmdline" % pid, "w").write(cmd.replace(" ", "\0"))
    with open(r + "/etc/passwd", "a") as f:
        f.write("root:x:0:0:root:/root:/bin/sh\nminidlna:x:104:110::/var/lib/minidlna:/usr/sbin/nologin\n"
                "dnsmasq:x:105:65534::/var/lib/misc:/usr/sbin/nologin\n")
    while not stop.is_set():
        t += 1
        for pid, name, ppid, uid, c, rss, cmd in DEMO_PROCS:
            open(r + "/proc/%d/stat" % pid, "w").write("%d (%s) S %d %d %d 0 -1 0 0 0 0 0 %d %d 0 0 20 0 1 0 %d 0 %d\n"
                                                    % (pid, name, ppid, pid, pid, c * t, 0, 1000 + pid, rss))
        cpu = lambda u, i: "%d 0 %d %d 0 0 0 0 0 0" % (u * t, u * t // 4, i * t)  # noqa: E731
        open(r + "/proc/stat.tmp", "w").write("cpu  %s\ncpu0 %s\ncpu1 %s\n" % (cpu(46, 154), cpu(23, 77), cpu(22, 78)))
        os.replace(r + "/proc/stat.tmp", r + "/proc/stat")
        open(r + "/proc/net/dev.tmp", "w").write(
            "Inter-|   Receive |  Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes\n"
            "    lo: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n"
            "  eth0: %d 0 0 0 0 0 0 0 %d 0 0 0 0 0 0 0\n" % (3500000 * t, 96000 * t))
        os.replace(r + "/proc/net/dev.tmp", r + "/proc/net/dev")
        stop.wait(0.5)


def api(base, jar_opener, path, body=None):
    rq = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
                                headers={"X-UT": "1", "Content-Type": "application/json"})
    try:
        with jar_opener.open(rq) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        return {"error": e.read().decode(errors="replace"), "status": e.code}


def populate(r, base, op, pw):
    """Example users, groups, shares and files, through the Desk's own API."""
    api(base, op, "/api/login", {"user": "admin", "password": pw})
    api(base, op, "/api/settings", {"hostname": "familynas", "netbios": {"name": "FAMILYNAS", "workgroup": "WORKGROUP",
                                                                        "description": "Family NAS in the hallway"}})
    for name in ("alice", "bob"):
        api(base, op, "/api/users/delete", {"name": name})
    for name, desc in (("anna", ""), ("ben", "")):
        api(base, op, "/api/users/create", {"name": name, "description": desc, "password": pw, "groups": ["family"]})
    for s in ("guestonly", "mixed", "groups", "nobody", "guestplus", "off", "gone"):
        api(base, op, "/api/shares/delete", {"name": s})
    for name, desc in (("Documents", "Letters, contracts, manuals"), ("Music", ""), ("Photos", "Holiday and family photos"), ("Videos", "")):
        api(base, op, "/api/shares/save", {"new": True, "name": name, "description": desc, "volume": "aaaa0001", "recycle": True,
                                           "users": {"admin": "rw", "anna": "rw", "ben": "ro"}})
    v = r + "/i-data/aaaa0001"
    os.makedirs(v + "/Photos/Summer 2026", exist_ok=True)
    for i, (n, hue) in enumerate((("Beach_2026-07-14.jpg", (0.4, 1, 1)), ("Garden.jpg", (0.2, 1.2, 0.5)),
                                  ("Mountains_2026-08-02.jpg", (0.6, 0.8, 1.1)), ("Sunset.jpg", (1.2, 0.5, 0.4)))):
        demo_jpg(v + "/Photos/Summer 2026/" + n, hue)
    demo_jpg(v + "/Photos/Birthday_cake.jpg", (1, 0.7, 0.6))
    demo_jpg(v + "/Photos/City_at_night.jpg", (0.3, 0.4, 1))
    os.makedirs(v + "/Documents/Letters", exist_ok=True)
    os.makedirs(v + "/Documents/Contracts", exist_ok=True)
    for n, data in (("Shopping list.txt", b"Milk\nBread\nCoffee\n"), ("Tax 2025.odt", b"PK\x03\x04" + os.urandom(18000)),
                    ("Washing machine manual.pdf", b"%PDF-1.4\n" + os.urandom(240000)), ("Budget 2026.ods", b"PK\x03\x04" + os.urandom(9000))):
        open(v + "/Documents/" + n, "wb").write(data)
    os.makedirs(v + "/Music/Holiday mix", exist_ok=True)
    for n in ("01 Morning.mp3", "02 Seaside.mp3", "03 Road trip.mp3"):
        open(v + "/Music/Holiday mix/" + n, "wb").write(os.urandom(300000))
    for n, src in (("Holiday_2026.mp4", "mandelbrot=size=1280x720:rate=25"), ("Birthday.mp4", "testsrc2=size=1280x720:rate=25")):
        out = v + "/Videos/" + n               # short real videos (ffmpeg), so player and channel play
        if subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", src, "-f", "lavfi", "-i",
                           "sine=frequency=440", "-t", "6", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", out],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            open(out, "wb").write(os.urandom(500000))
    api(base, op, "/api/tv/save", {"name": "Holiday channel", "items": [{"share": "Videos", "path": "Holiday_2026.mp4"}], "profile": "480"})


# ------------------------------------------------------------- scenarios

SETTLE = "await new Promise(r => setTimeout(r, %d));"
OPEN = "openApp('%s'); " + SETTLE % 1200
DESK = ("location.reload();", 2200)          # fresh desk before each picture


def sc(js, wait=600, login=True, height=H):
    return {"js": js, "wait": wait, "login": login, "height": height}


SCENARIOS = {
    "d00-first-setup": sc("", login=False),          # special: a fresh root (way A)
    "d01-login": sc("const u = document.querySelector('#u'); if (u) u.value = 'admin'; const p = document.querySelector('#p'); if (p) p.value = 'example-pw';", login=False),
    "d02-desktop-overview": sc("closeAll(); " + OPEN % "overview" + " maximize('overview');"),
    "d03-files-photos": sc("closeAll(); FS.share = 'Photos'; FS.path = 'Summer 2026'; FS.sel = new Set(['Garden.jpg']); " + OPEN % "files"),
    "d05-files-share-link": sc("closeAll(); FS.share = 'Photos'; FS.path = 'Summer 2026'; " + OPEN % "files" +
                               " linkDialog('Photos', 'Summer 2026/Beach_2026-07-14.jpg', 'Beach_2026-07-14.jpg');"),
    "d06-files-export": sc("closeAll(); FS.share = 'Videos'; FS.path = ''; " + OPEN % "files" +
                           " await exportDialog('Videos', 'Holiday_2026.mp4', 'Holiday_2026.mp4', false); " + SETTLE % 600 +
                           " const c = [...document.querySelectorAll('.ut-scrim input[type=radio]')].find(x => /conv/i.test(x.value)); if (c) { c.checked = true; c.dispatchEvent(new Event('change', {bubbles: true})); }"),
    "d07-player-video": sc("closeAll(); FS.share = 'Videos'; FS.path = ''; " + OPEN % "files" +
                           " openPlayer(['Holiday_2026.mp4', 'Birthday.mp4'], 'Holiday_2026.mp4', n => n); " + SETTLE % 1500 +
                           " const v = document.querySelector('#pv'); if (v) { v.muted = true; await Promise.race([v.play().catch(() => 0), new Promise(r => setTimeout(r, 3000))]); " + SETTLE % 1800 + " v.pause(); }", wait=800),
    "d09-shares-photos-rights": sc("closeAll(); " + OPEN % "shares" + " render('shares', 'Photos');"),
    "d10-shares-new": sc("closeAll(); " + OPEN % "shares" + " render('shares', '_new'); " + SETTLE % 500 +
                         " const n = document.querySelector('.ut-window [id^=sn], .ut-window #nn'); if (n) n.value = 'Projects';"),
    "d11-storage": sc("closeAll(); " + OPEN % "storage" + " maximize('storage');"),
    "d12-storage-new-volume": sc("closeAll(); " + OPEN % "storage" + " const b = document.querySelector('#rnew'); if (b) b.click();"),
    "d13-users-anna": sc("closeAll(); " + OPEN % "users" + " render('users', 'u:anna');"),
    "d14-users-new": sc("closeAll(); " + OPEN % "users" + " render('users', '_nu'); " + SETTLE % 400 +
                        " document.querySelector('#un').value = 'clara'; document.querySelector('#ud').value = 'Clara (guest room PC)';"
                        " document.querySelector('#up1').value = 'example-pw'; document.querySelector('#up2').value = 'example-pw';"),
    "d16-status": sc("closeAll(); " + OPEN % "status" + " maximize('status');", wait=4500),
    "d20-network": sc("closeAll(); " + OPEN % "network" + " maximize('network');"),
    "d22-settings-services": sc("closeAll(); " + OPEN % "settings" + " maximize('settings'); render('settings', 'services');"),
    "d24-settings-power": sc("closeAll(); " + OPEN % "settings" + " maximize('settings'); render('settings', 'power');"),
    "d25-settings-notify": sc("closeAll(); " + OPEN % "settings" + " maximize('settings'); render('settings', 'notify');"),
    "d30-adblock-overview": sc("closeAll(); " + OPEN % "adblock"),
    "d32-adblock-rules": sc("closeAll(); " + OPEN % "adblock" + " render('adblock', 'rules');"),
    "d38-media-new-channel": sc("closeAll(); " + OPEN % "media" + " render('media', 'tv'); " + SETTLE % 800 +
                                " const b = document.querySelector('#tvn'); if (b) b.click(); " + SETTLE % 800 +
                                " const d = document.querySelector('.ut-scrim'); const nm = d.querySelector('input'); if (nm) nm.value = 'Film night';"
                                " const sel = [...d.querySelectorAll('select')].find(x => [...x.options].some(o => o.value === 'Videos'));"
                                " if (sel) { sel.value = 'Videos'; sel.dispatchEvent(new Event('change', {bubbles: true})); }", wait=1200),
    "d39-channels-watch": sc("closeAll(); " + OPEN % "tv" + SETTLE % 6000 +
                             " const v = document.querySelector('.ut-window video'); if (v) { v.muted = true; await Promise.race([v.play().catch(() => 0), new Promise(r => setTimeout(r, 3000))]); }", wait=4000),
    "d40-cloud": sc("closeAll(); " + OPEN % "cloud"),
    "d42-cloud-job": sc("closeAll(); " + OPEN % "cloud" + " const b = document.querySelector('#cjob'); if (b) b.click();"),
    "d43-backup-new-job": sc("closeAll(); " + OPEN % "backup" + " const b = [...document.querySelectorAll('.ut-window button')].find(x => x.id === 'bnew' || /New backup|\\+ ?Job|\\+ ?Backup/.test(x.textContent)); if (b) b.click(); " + SETTLE % 600 +
                             " const d = document.querySelector('.ut-scrim'); const n = d && d.querySelector('#bn'); if (n) n.value = 'Nightly photo archive';"
                             " const sel = d && [...d.querySelectorAll('select')].find(x => [...x.options].some(o => o.value === 'Photos'));"
                             " if (sel) { sel.value = 'Photos'; sel.dispatchEvent(new Event('change', {bubbles: true})); }", height=1320),
    "d44-downloads-settings": sc("closeAll(); " + OPEN % "downloads" + " render('downloads', 'settings');"),
    "d45-updates": sc("closeAll(); " + OPEN % "updates", wait=1200),
    "d46-logs": sc("closeAll(); " + OPEN % "logs", wait=1200),
    "d47-sounds": sc("closeAll(); " + OPEN % "sound" + " maximize('sound');", wait=1200),
    "d49-feedback": sc("closeAll(); " + OPEN % "feedback", wait=1200),
    "d50-power-dialog": sc("closeAll(); powerDialog();"),
    "d52-user-anna-files": sc("closeAll(); FS.share = 'Photos'; FS.path = ''; " + OPEN % "files", login="anna"),
    "d54-manual": sc("closeAll(); " + OPEN % "manual" + " maximize('manual');", wait=2000),
}

HELPERS = """
window.closeAll = () => { Object.keys(wins).forEach(k => { const w = wins[k]; if (w) { const x = w.querySelector('[data-act=close]'); if (x) x.click(); else w.remove(); } }); };
window.maximize = k => { const w = wins[k]; if (!w) return; const b = w.querySelector('[data-act=max]'); if (b) b.click(); };
"""


def main():
    import signal
    signal.signal(signal.SIGTERM, lambda *_a: sys.exit(1))     # finally: stop the Desk and Chromium
    want = [a for a in sys.argv[1:] if not a.startswith("-")]
    if "--list" in sys.argv:
        print("\n".join(SCENARIOS))
        return 0
    names = [n for n in SCENARIOS if not want or any(n.startswith(x) for x in want)]
    tdh = load_test_helpers()
    w = tempfile.mkdtemp(prefix="ut-shoot-")
    procs = []
    try:
        port = 18900 + os.getpid() % 500
        r, env = build(w, tdh, port)
        desk = os.path.join(OS, "image/rootfs/usr/lib/untrash/untrash-desk")
        procs.append(subprocess.Popen([sys.executable, desk], env=env, stdout=open(w + "/desk.log", "w"), stderr=subprocess.STDOUT))
        base = "http://127.0.0.1:%d" % port
        for _i in range(100):
            try:
                urllib.request.urlopen(base + "/api/state", timeout=1)
                break
            except OSError:
                time.sleep(0.1)
        import http.cookiejar
        op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        populate(r, base, op, tdh.PW)
        import threading
        os.makedirs(r + "/proc/net", exist_ok=True)
        stop = threading.Event()
        threading.Thread(target=live_ticker, args=(r, stop), daemon=True).start()
        cport = 19400 + os.getpid() % 500
        procs.append(subprocess.Popen(["chromium", "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars",
                                       "--remote-debugging-port=%d" % cport, "--user-data-dir=" + w + "/chrome",
                                       "--window-size=%d,%d" % (W, H), "--lang=en-US", "about:blank"],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        for _i in range(100):
            try:
                tabs = json.load(urllib.request.urlopen("http://127.0.0.1:%d/json" % cport, timeout=1))
                page = next(t for t in tabs if t["type"] == "page")
                break
            except (OSError, StopIteration, ValueError):
                time.sleep(0.1)
        c = CDP(page["webSocketDebuggerUrl"])
        c.call("Page.enable")
        c.call("Emulation.setDeviceMetricsOverride", width=W, height=H, deviceScaleFactor=1, mobile=False)
        c.call("Emulation.setTimezoneOverride", timezoneId="Europe/Berlin")
        cur_user = None
        for n in names:
            s = SCENARIOS[n]
            if n == "d00-first-setup":
                continue            # needs an uninitialised root; kept as it is (no dock in it)
            user = s["login"] if isinstance(s["login"], str) else ("admin" if s["login"] else None)
            if user != cur_user:
                c.call("Page.navigate", url=base + "/")
                time.sleep(1.5)
                c.js("await fetch('/api/logout', {method: 'POST', headers: {'X-UT': '1'}}).catch(() => 0);")
                if user:
                    c.js("await fetch('/api/login', {method: 'POST', headers: {'X-UT': '1', 'Content-Type': 'application/json'},"
                         " body: JSON.stringify({user: %s, password: %s})});" % (json.dumps(user), json.dumps(tdh.PW)))
                c.js("try { localStorage.setItem('ut-lang', 'en'); } catch (e) {}")
                cur_user = user
            c.call("Page.navigate", url=base + "/")
            time.sleep(2.2)
            c.js(HELPERS)
            try:
                c.js(s["js"], timeout=60)
            except RuntimeError as e:
                print("WARN %s: %s" % (n, e))
            time.sleep(s["wait"] / 1000)
            c.shot(os.path.join(IMG, n + ".webp"), s["height"])
            print("shot", n)
    finally:
        if "stop" in locals():
            stop.set()
        for p in procs:
            p.terminate()
        for p in procs:
            try:
                p.wait(10)
            except subprocess.TimeoutExpired:
                p.kill()
        shutil.rmtree(w, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

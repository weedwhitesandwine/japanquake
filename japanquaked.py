#!/usr/bin/env python3
"""Japan Quake Monitor's engine.

Two feeds, both from the P2P地震情報 relay of JMA's own bulletins:

  * code 551 — 震源・震度情報, the confirmed report. It arrives a couple of
    minutes after the shaking and is never wrong. Polled over plain HTTPS.
  * code 556 — 緊急地震速報, the early warning. It arrives *before* the
    shaking, which is the whole point of it, so it is worth nothing if it is
    polled: a thirty-second poll would routinely deliver a warning after the
    event it warned about. It comes over a WebSocket instead, and only when
    the user has switched early warnings on.

Everything is written to ~/.local/state/japanquake/state.json. Nothing is ever
written inside the plugin directory: the shell watches that tree and reloads
the plugin on every write there.

Depends on nothing outside the Python standard library.
"""

import base64
import errno
import json
import math
import os
import socket
import ssl
import struct
import sys
import time
import urllib.error
import urllib.request

STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "japanquake"
)
STATE_FILE = os.path.join(STATE_DIR, "state.json")
SETTINGS_FILE = os.path.join(STATE_DIR, "settings.json")
LOCK_FILE = os.path.join(STATE_DIR, "japanquaked.lock")
NAMES_FILE = os.path.join(STATE_DIR, "place-names.json")

HISTORY_URL = "https://api.p2pquake.net/v2/history?codes=551&limit=40"
# JMA publishes the same bulletins with an English name for every epicentre.
# The relay does not, so this is read alongside it purely to build a Japanese
# -> English dictionary of place names, which is cached and grows over time.
JMA_LIST_URL = "https://www.jma.go.jp/bosai/quake/data/list.json"
WS_HOST, WS_PORT, WS_PATH = "api.p2pquake.net", 443, "/v2/ws"
USER_AGENT = "japanquake-omarchy-plugin/0.1 (+https://github.com/weedwhitesandwine/japanquake)"

POLL_SECONDS = 30

# Ceilings on anything that arrives from the network. These feeds answer with a
# few tens of kilobytes; a response orders of magnitude larger is not a feed,
# and this process is long-lived, so it is truncated before it is parsed.
MAX_HTTP_BYTES = 4 * 1024 * 1024
MAX_FRAME_BYTES = 1 * 1024 * 1024
MAX_QUAKES = 200

# The same idea for the files in the state directory. This process writes them,
# but it does not own the disk: a restored backup, or anything else with write
# access to a home directory, can leave something quite different behind. Each
# is read up to its ceiling and no further, before it is parsed.
MAX_SETTINGS_BYTES = 16 * 1024
MAX_STATE_BYTES = 4 * 1024 * 1024
MAX_NAMES_BYTES = 1 * 1024 * 1024

TOKYO_LAT, TOKYO_LON = 35.681, 139.767

# JMA's shindo scale is not linear and is not a number: 5 and 6 are each split
# into a weak and a strong band. The relay encodes it times ten, with the split
# bands at 45/50 and 55/60.
SHINDO = {
    10: "1", 20: "2", 30: "3", 40: "4",
    45: "5-", 50: "5+", 55: "6-", 60: "6+", 70: "7",
}

# Ordering for thresholds. Shindo 5- is stronger than 4, which the raw numbers
# would not tell you.
SHINDO_RANK = {"1": 1, "2": 2, "3": 3, "4": 4, "5-": 5, "5+": 6, "6-": 7, "6+": 8, "7": 9}

TSUNAMI = {
    "None": "none",
    "Unknown": "unknown",
    "Checking": "checking",
    "NonEffective": "slight-sea-change",
    "Watch": "watch",
    "Warning": "warning",
}


def log(*a):
    print("japanquaked:", *a, file=sys.stderr, flush=True)


def ensure_state_dir():
    os.makedirs(STATE_DIR, exist_ok=True)


def take_lock():
    """A second copy should step aside quietly, not fight over the socket."""
    ensure_state_dir()
    fd = os.open(LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        import fcntl
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        if e.errno in (errno.EACCES, errno.EAGAIN):
            return None
        raise
    os.ftruncate(fd, 0)
    os.write(fd, str(os.getpid()).encode())
    return fd


def read_json_file(path, ceiling):
    """Read one of our own state files, refusing it if it is past its ceiling.
    Reading a byte more than the ceiling is what tells us it is too big, so
    nothing larger is ever held, let alone parsed."""
    with open(path, "rb") as f:
        raw = f.read(ceiling + 1)
    if len(raw) > ceiling:
        raise ValueError("%s is larger than %d bytes" % (path, ceiling))
    return json.loads(raw.decode("utf-8", "replace"))


def read_settings():
    try:
        s = read_json_file(SETTINGS_FILE, MAX_SETTINGS_BYTES)
        return s if isinstance(s, dict) else {}
    except Exception:
        return {}


_names = None


def place_names():
    """Japanese epicentre name -> English, cached on disk. Missing entries are
    not an error: the name is simply shown in Japanese alone."""
    global _names
    if _names is None:
        try:
            _names = read_json_file(NAMES_FILE, MAX_NAMES_BYTES)
            if not isinstance(_names, dict):
                _names = {}
        except Exception:
            _names = {}
    return _names


def fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=20) as r:
        raw = r.read(MAX_HTTP_BYTES + 1)
    if len(raw) > MAX_HTTP_BYTES:
        raise ValueError("response larger than %d bytes" % MAX_HTTP_BYTES)
    return json.loads(raw.decode("utf-8", "replace"))


def refresh_place_names():
    data = fetch_json(JMA_LIST_URL)
    if not isinstance(data, list):
        return 0
    names = place_names()
    added = 0
    for item in data:
        ja, en = item.get("anm"), item.get("en_anm")
        if ja and en and names.get(ja) != en:
            names[ja] = en
            added += 1
    if added:
        tmp = NAMES_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(names, f, ensure_ascii=False)
        os.replace(tmp, NAMES_FILE)
    return added


def distance_km(lat, lon):
    """Great-circle distance from Tokyo Station, or None for a report that has
    no epicentre yet — the first bulletin of a quake often carries intensities
    only."""
    if lat is None or lon is None:
        return None
    r = 6371.0
    p1, p2 = math.radians(TOKYO_LAT), math.radians(lat)
    dp = math.radians(lat - TOKYO_LAT)
    dl = math.radians(lon - TOKYO_LON)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return round(r * 2 * math.asin(math.sqrt(a)))


def bearing_from_tokyo(lat, lon):
    if lat is None or lon is None:
        return ""
    dl = math.radians(lon - TOKYO_LON)
    p1, p2 = math.radians(TOKYO_LAT), math.radians(lat)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    deg = (math.degrees(math.atan2(y, x)) + 360) % 360
    points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
              "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    return points[int((deg + 11.25) % 360 / 22.5)]


def clean_quake(item):
    eq = item.get("earthquake") or {}
    hypo = eq.get("hypocenter") or {}

    # A magnitude or depth of -1 is the relay's way of saying "not stated in
    # this bulletin", which is normal for an intensity-only first report.
    def maybe(v):
        return None if v in (None, -1, -1.0) else v

    lat = maybe(hypo.get("latitude"))
    lon = maybe(hypo.get("longitude"))
    if lat == 0 and lon == 0:
        lat = lon = None

    scale = eq.get("maxScale")
    shindo = SHINDO.get(scale)

    prefs = {}
    for pt in item.get("points") or []:
        pref = pt.get("pref")
        s = SHINDO.get(pt.get("scale"))
        if not pref or not s:
            continue
        if pref not in prefs or SHINDO_RANK.get(s, 0) > SHINDO_RANK.get(prefs[pref], 0):
            prefs[pref] = s

    return {
        "id": item.get("id"),
        "time": eq.get("time") or "",
        "place": hypo.get("name") or "",
        "placeEn": place_names().get(hypo.get("name") or "", ""),
        "lat": lat,
        "lon": lon,
        "depth": maybe(hypo.get("depth")),
        "magnitude": maybe(hypo.get("magnitude")),
        "shindo": shindo,
        "rank": SHINDO_RANK.get(shindo, 0),
        "tsunami": TSUNAMI.get(eq.get("domesticTsunami"), "unknown"),
        "distance": distance_km(lat, lon),
        "bearing": bearing_from_tokyo(lat, lon),
        "prefectures": [{"pref": k, "shindo": v} for k, v in
                        sorted(prefs.items(), key=lambda kv: -SHINDO_RANK.get(kv[1], 0))],
        "report": (item.get("issue") or {}).get("type") or "",
    }


def clean_eew(item):
    """An early warning is a forecast, not a measurement: it says where the
    quake started and how strong it is expected to be, and it can be cancelled
    outright a moment later."""
    body = item.get("earthquake") or {}
    hypo = body.get("hypocenter") or {}
    lat = hypo.get("latitude")
    lon = hypo.get("longitude")
    if lat in (None, -1, 0) and lon in (None, -1, 0):
        lat = lon = None
    return {
        "id": item.get("id"),
        "at": time.time(),
        "cancelled": bool(item.get("cancelled")),
        "test": (item.get("issue") or {}).get("type") == "Test",
        "place": hypo.get("name") or "",
        "lat": lat,
        "lon": lon,
        "depth": hypo.get("depth"),
        "magnitude": hypo.get("magnitude"),
        "serial": (item.get("issue") or {}).get("serial") or "",
        "distance": distance_km(lat, lon),
        "bearing": bearing_from_tokyo(lat, lon),
    }


def write_state(**changes):
    ensure_state_dir()
    try:
        state = read_json_file(STATE_FILE, MAX_STATE_BYTES)
        if not isinstance(state, dict):
            state = {}
    except Exception:
        state = {}
    state.update(changes)
    state["updated"] = time.time()
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_FILE)


def fetch_reports():
    try:
        refresh_place_names()
    except Exception as e:
        log("place-name refresh failed (names stay Japanese):", e)
    data = fetch_json(HISTORY_URL)
    if not isinstance(data, list):
        raise ValueError("feed did not return a list")
    quakes = [clean_quake(i) for i in data[:MAX_QUAKES] if isinstance(i, dict)]
    quakes = [q for q in quakes if q["time"]]
    quakes = merge_bulletins(quakes)
    write_state(quakes=quakes, error=None)
    return quakes


def merge_bulletins(quakes):
    """One earthquake, one entry.

    JMA issues a quake in instalments: an intensity-only 震度速報 within seconds,
    then the epicentre, then the full report. The relay passes each one along
    separately, so a single event arrives as up to three records sharing a
    timestamp — which is why an unmerged list shows the same quake three times,
    once without an epicentre and once without an intensity.

    They are folded into whichever record is most complete, field by field, so
    a later bulletin that drops a detail an earlier one carried cannot lose it.
    """
    merged = {}
    order = []
    for q in quakes:
        key = q["time"]
        if key not in merged:
            merged[key] = dict(q)
            order.append(key)
            continue
        into = merged[key]
        for field in ("place", "placeEn", "lat", "lon", "depth", "magnitude",
                      "distance", "bearing"):
            if into.get(field) in (None, "") and q.get(field) not in (None, ""):
                into[field] = q[field]
        # Intensity: the strongest reading anyone reported for this quake.
        if q["rank"] > into["rank"]:
            into["shindo"], into["rank"] = q["shindo"], q["rank"]
        if len(q["prefectures"]) > len(into["prefectures"]):
            into["prefectures"] = q["prefectures"]
        if q["tsunami"] not in ("unknown",) and into["tsunami"] == "unknown":
            into["tsunami"] = q["tsunami"]
        # Keep the id of the fullest bulletin so "have I shown this?" is stable.
        if q["report"] == "DetailScale":
            into["id"] = q["id"]
            into["report"] = q["report"]
    return [merged[k] for k in order]


# --------------------------------------------------------------------------
# A WebSocket client, in about eighty lines of standard library.
#
# Nothing here is general-purpose: it speaks only what this one feed needs —
# a client handshake, masked pings and pongs out, unfragmented text frames in.
# It exists so the plugin can hold an early-warning socket without asking the
# user to install a WebSocket library.
# --------------------------------------------------------------------------

class WebSocket:
    def __init__(self, host, port, path):
        key = base64.b64encode(os.urandom(16)).decode()
        raw = socket.create_connection((host, port), timeout=20)
        ctx = ssl.create_default_context()
        self.sock = ctx.wrap_socket(raw, server_hostname=host)
        self.sock.sendall((
            f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\nUser-Agent: {USER_AGENT}\r\n\r\n"
        ).encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("server closed during handshake")
            buf += chunk
        head, rest = buf.split(b"\r\n\r\n", 1)
        if b"101" not in head.split(b"\r\n")[0]:
            raise ConnectionError("handshake refused: %s" % head.split(b"\r\n")[0])
        self.buf = rest

    def _recv_exactly(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _send_frame(self, opcode, payload=b""):
        header = bytes([0x80 | opcode])
        mask = os.urandom(4)
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def ping(self):
        self._send_frame(0x9)

    def recv_text(self):
        """Return the next text message, or None for a frame we don't care
        about (a pong, say). Raises on close."""
        b0, b1 = self._recv_exactly(2)
        opcode = b0 & 0x0F
        length = b1 & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._recv_exactly(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._recv_exactly(8))[0]
        if length > MAX_FRAME_BYTES:
            raise ConnectionError("frame of %d bytes refused" % length)
        if b1 & 0x80:                       # a server must never mask
            self._recv_exactly(4)
        payload = self._recv_exactly(length) if length else b""
        if opcode == 0x8:
            raise ConnectionError("server closed")
        if opcode == 0x9:
            self._send_frame(0xA, payload)  # pong back with the same body
            return None
        if opcode == 0x1:
            return payload.decode("utf-8", "replace")
        return None

    def close(self):
        try:
            self._send_frame(0x8)
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass


def run_daemon():
    lock = take_lock()
    if lock is None:
        log("another copy already holds the lock; stepping aside")
        return 0

    ws = None
    last_poll = 0.0
    last_ping = 0.0
    want_eew_prev = None

    while True:
        now = time.time()
        want_eew = read_settings().get("earlyWarning", True) is not False

        if want_eew != want_eew_prev:
            log("early warnings", "on" if want_eew else "off")
            want_eew_prev = want_eew
            if not want_eew and ws:
                ws.close()
                ws = None
                write_state(eewConnected=False)

        if want_eew and ws is None:
            try:
                ws = WebSocket(WS_HOST, WS_PORT, WS_PATH)
                write_state(eewConnected=True)
                log("early-warning socket open")
            except Exception as e:
                write_state(eewConnected=False)
                log("socket failed, retrying:", e)
                time.sleep(15)
                continue

        if now - last_poll >= POLL_SECONDS:
            last_poll = now
            try:
                fetch_reports()
            except (urllib.error.URLError, OSError, ValueError) as e:
                log("report poll failed:", e)
                write_state(error=str(e))

        if ws is None:
            time.sleep(1)
            continue

        # Keep the connection honest through a quiet night.
        if now - last_ping > 120:
            last_ping = now
            try:
                ws.ping()
            except Exception:
                ws = None
                continue

        try:
            self_timeout = max(1.0, POLL_SECONDS - (time.time() - last_poll))
            ws.sock.settimeout(min(5.0, self_timeout))
            msg = ws.recv_text()
        except socket.timeout:
            continue
        except Exception as e:
            log("socket dropped, will reconnect:", e)
            try:
                ws.close()
            except Exception:
                pass
            ws = None
            write_state(eewConnected=False)
            time.sleep(5)
            continue

        if not msg:
            continue
        try:
            item = json.loads(msg)
        except ValueError:
            continue
        code = item.get("code")
        if code == 556:
            write_state(eew=clean_eew(item))
        elif code == 551:
            # The confirmed report for a quake we may already have warned
            # about. Take it immediately rather than waiting for the poll.
            try:
                fetch_reports()
                last_poll = time.time()
            except Exception:
                pass


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "daemon"
    ensure_state_dir()
    if mode == "once":
        try:
            fetch_reports()
        except Exception as e:
            write_state(error=str(e))
            return 1
        return 0
    return run_daemon() or 0


if __name__ == "__main__":
    sys.exit(main())

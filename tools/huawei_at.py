"""
huawei_at.py — couche AT commune pour dongles Huawei (E1550 / E173 / E169 / E1750...)
utilisés comme UE boîte noire face au banc Osmocom.

- un thread lecteur sépare les réponses de commande et les URC (RING, +CMTI, ^CONN, ^CEND...)
- gestion du prompt '>' pour AT+CMGS
- helpers : init, PIN, forçage 2G, enregistrement manuel sur une PLMN de test

Dépendance : pyserial (pip install pyserial)
"""
import queue
import re
import threading
import time

import serial

URC_PREFIXES = (
    "RING", "+CRING", "+CLIP", "+CMTI", "+CMT:", "+CDS", "+CBM",
    "^ORIG", "^CONF", "^CONN", "^CEND", "^RSSI", "^HCSQ", "^BOOT", "^MODE",
    "^SRVST", "^SIMST", "^SYSINFOEX", "^NWTIME", "+CREG", "+CGREG",
    "NO CARRIER", "BUSY", "NO ANSWER",
)
FINAL = re.compile(r"^(OK|ERROR|\+CME ERROR:.*|\+CMS ERROR:.*)$")


class ATError(Exception):
    def __init__(self, cmd, final, lines):
        super().__init__(f"{cmd!r} -> {final}")
        self.cmd, self.final, self.lines = cmd, final, lines


def _prefix(cmd):
    m = re.match(r"AT([+^][A-Z0-9]+)", cmd, re.I)
    return m.group(1).upper() if m else None


class Modem:
    def __init__(self, port, baud=115200, verbose=True):
        self.ser = serial.Serial(port, baud, timeout=0.1)
        self.verbose = verbose
        self.resp = queue.Queue()
        self.urc = queue.Queue()
        self._pending = None
        self._cmt_header = None
        self._lock = threading.Lock()
        self._stop = False
        self._buf = b""
        threading.Thread(target=self._reader, daemon=True).start()

    # ---------- lecture ----------
    def _log(self, direction, s):
        if self.verbose:
            print(f"{time.strftime('%H:%M:%S')} {direction} {s}")

    def _reader(self):
        while not self._stop:
            data = self.ser.read(512)
            if not data:
                continue
            self._buf += data
            *lines, self._buf = re.split(rb"\r\n|\r|\n", self._buf)
            for raw in lines:
                line = raw.decode(errors="replace").strip()
                if line:
                    self._route(line)
            # prompt de saisie SMS : "> " sans fin de ligne
            if self._buf.strip() == b">":
                self._buf = b""
                self._log("<<", ">")
                self.resp.put(">")

    def _route(self, line):
        self._log("<<", line)
        if self._cmt_header is not None:  # 2e ligne d'un +CMT: (texte du SMS)
            self.urc.put(self._cmt_header + "\n" + line)
            self._cmt_header = None
            return
        if line.startswith("+CMT:"):
            self._cmt_header = line
            return
        if self._pending and line.upper().startswith(self._pending):
            self.resp.put(line)
        elif line.startswith(URC_PREFIXES):
            self.urc.put(line)
        else:
            self.resp.put(line)

    # ---------- commandes ----------
    def _drain(self):
        while not self.resp.empty():
            self.resp.get_nowait()

    def _collect(self, cmd, timeout):
        lines, deadline = [], time.time() + timeout
        while True:
            try:
                l = self.resp.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                self._pending = None
                raise TimeoutError(f"pas de réponse à {cmd!r}")
            if l == cmd:  # écho
                continue
            if FINAL.match(l):
                self._pending = None
                if l != "OK":
                    raise ATError(cmd, l, lines)
                return lines
            lines.append(l)

    def cmd(self, c, timeout=5):
        with self._lock:
            self._drain()
            self._pending = _prefix(c)
            self._log(">>", c)
            self.ser.write((c + "\r").encode())
            return self._collect(c, timeout)

    def cmd_prompt(self, c, payload, timeout=60):
        """Commande avec prompt '>' (AT+CMGS) : payload terminé par Ctrl-Z."""
        with self._lock:
            self._drain()
            self._pending = _prefix(c)
            self._log(">>", c)
            self.ser.write((c + "\r").encode())
            deadline = time.time() + 10
            while True:
                try:
                    l = self.resp.get(timeout=max(0.01, deadline - time.time()))
                except queue.Empty:
                    self.ser.write(b"\x1b")  # ESC = annule
                    raise TimeoutError("pas de prompt '>'")
                if l == ">":
                    break
                if FINAL.match(l):
                    raise ATError(c, l, [])
            self._log(">>", payload + " <Ctrl-Z>")
            self.ser.write(payload.encode() + b"\x1a")
            return self._collect(c, timeout)

    def try_cmd(self, c, timeout=5):
        try:
            return self.cmd(c, timeout)
        except (ATError, TimeoutError) as e:
            self._log("!!", str(e))
            return None

    def close(self):
        self._stop = True
        self.ser.close()

    # ---------- helpers réseau ----------
    def init(self, pin=None, force_2g=False):
        self.cmd("ATE0")
        self.cmd("AT+CMEE=2")
        self.try_cmd("ATI")
        self.try_cmd("AT+CGSN")      # IMEI
        st = " ".join(self.cmd("AT+CPIN?", timeout=10))
        if "SIM PIN" in st:
            if not pin:
                raise RuntimeError("la SIM demande un PIN (--pin)")
            self.cmd(f'AT+CPIN="{pin}"', timeout=10)
            time.sleep(3)
        self.try_cmd("AT+CIMI")      # IMSI
        if force_2g:
            # dongles 3G : 13 = GSM only ; dongles LTE : SYSCFGEX "01"
            if self.try_cmd("AT^SYSCFG=13,1,3FFFFFFF,2,4", timeout=10) is None:
                self.try_cmd('AT^SYSCFGEX="01",3FFFFFFF,2,4,7FFFFFFFFFFFFFFF,,', timeout=10)

    def register(self, plmn=None, timeout=120):
        if plmn:
            self.cmd(f'AT+COPS=1,2,"{plmn}"', timeout=timeout)
        else:
            self.try_cmd("AT+COPS=0", timeout=timeout)
        deadline = time.time() + timeout
        while time.time() < deadline:
            r = self.try_cmd("AT+CREG?")
            m = re.search(r"\+CREG:\s*\d+,(\d)", " ".join(r or []))
            if m and m.group(1) in ("1", "5"):
                self.try_cmd("AT+COPS?")
                self.try_cmd("AT+CSQ")
                return True
            time.sleep(2)
        raise TimeoutError("pas d'enregistrement réseau (CREG ≠ 1/5)")

    def wait_urc(self, timeout=None):
        try:
            return self.urc.get(timeout=timeout)
        except queue.Empty:
            return None


def common_args(p):
    p.add_argument("--port", default="/dev/ttyUSB2", help="port AT (PCUI) du dongle")
    p.add_argument("--pin")
    p.add_argument("--plmn", help='PLMN du banc, ex. "00101" (sélection manuelle)')
    p.add_argument("--force-2g", action="store_true",
                   help="forcer GSM only (pour s'accrocher à un BTS Osmocom) ; "
                        "par défaut : mode auto (ex. Free, pas de 2G)")
    p.add_argument("-q", "--quiet", action="store_true")
    return p


def open_modem(args):
    m = Modem(args.port, verbose=not args.quiet)
    m.init(pin=args.pin, force_2g=args.force_2g)
    m.register(args.plmn)
    return m

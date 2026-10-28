#!/usr/bin/env python3
# osmo-ts-probe.py - WHO CARRIES BURSTS RIGHT NOW? Writes the state of the 8
# timeslots that the LAB GSM banner (configs/conky/labgsm.html, via
# osmo-topzone.py) blinks in orange.
#
# Two sources:
#   1. THE osmo-bsc CONF: phys_chan_config of each timeslot (CCCH+SDCCH4,
#      SDCCH8, TCH/F ...). Gives the TYPE, hence the label of each cell and
#      whether a TCH can carry VOICE. Looked up in, whichever exists:
#         $OSMO_BSC_CFG, /etc/osmocom/osmo-bsc.cfg, $OSMO_REPO/configs/osmo-bsc.cfg
#   2. THE osmo-bsc VTY (telnet 127.0.0.1 4242, `show lchan summary`): which
#      logical channels are ESTABLISHED, on which timeslot, of which type. An
#      established TCH = voice -> the timeslot blinks. No VTY (bench stopped) ->
#      bsc=false, the banner switches to demonstration mode.
#
# Output: $OSMO_FFT_DIR/timeslots.json (default /run/osmo-fft, /tmp as
# fallback - see run_dir(), the SAME rule as the reader), rewritten every
# period, of the form:
#   {"bsc":true,"arfcn":"ARFCN 514 · DCS 1800",
#    "ts":[{"n":0,"type":"CCCH+SDCCH4","active":false,"voice":false}, ...]}
import json
import os
import re
import socket
import sys
import time

REPO = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")
# ── WHERE TO WRITE: THE SAME RULE AS THE READER, RE-EVALUATED EVERY TURN ────
# The reader (tools/osmo-topzone.py) looks ONLY at $OSMO_FFT_DIR then /tmp, so
# the rule is the same here, word for word: the first directory that EXISTS
# AND IS WRITABLE, between $OSMO_FFT_DIR and /tmp.
#
# "writable" and not only "exists": /run/osmo-fft is created by
# osmo-fft-snap.service (RuntimeDirectory, 0775, group sudo), but it may also
# have been created earlier by another tool as 0755 root:root, in which case
# the session probe cannot write there.
#
# The rule is RE-EVALUATED AT EVERY WRITE: that directory is a
# RuntimeDirectory, it disappears when the unit stops and comes back when it
# restarts. A probe that resolved its path once would otherwise keep writing
# into the void until the next restart.
RUN_PREFERE = os.environ.get("OSMO_FFT_DIR", "/run/osmo-fft")


def run_dir():
    for d in (RUN_PREFERE, "/tmp"):
        if os.path.isdir(d) and os.access(d, os.W_OK):
            return d
    return "/tmp"
VTY_HOST = os.environ.get("OSMO_BSC_VTY_HOST", "127.0.0.1")
VTY_PORT = int(os.environ.get("OSMO_BSC_VTY_PORT", "4242"))
# THE BANNER FOLLOWS ONE PRECISE BTS, AND ONLY ONE. The eight cells are the
# TDMA frame of ONE carrier: BTS 0, TRX 0 - the bench BTS. On a multi-operator
# bench (several BTS declared in the same osmo-bsc) the VTY lines of the other
# BTS/TRX are ignored, so a channel established on BTS 1 never lights a cell
# of BTS 0.
BTS_NR = int(os.environ.get("OSMO_BTS_NR", "0"))
TRX_NR = int(os.environ.get("OSMO_TRX_NR", "0"))


def cfg_path():
    for p in (os.environ.get("OSMO_BSC_CFG"),
              "/etc/osmocom/osmo-bsc.cfg",
              os.path.join(REPO, "configs/osmo-bsc.cfg")):
        if p and os.path.exists(p):
            return p
    return None


def read_types():
    """[(n, phys_chan_config)] of the first trx of the followed bts in the conf."""
    p = cfg_path()
    types = {}
    arfcn = None
    if not p:
        return types, arfcn
    try:
        txt = open(p, errors="replace").read()
    except OSError:
        return types, arfcn
    # The block of THE followed bts (BTS_NR), not "the first one found": on a
    # multi-BTS conf the phys_chan_config differ from one BTS to another, and
    # the cell labels must be those of the carrier being displayed.
    blocks = re.split(r'\n\s*bts\s+(\d+)', txt)
    block = txt
    # re.split with a group yields [before, "0", block0, "1", block1, ...]
    for i in range(1, len(blocks) - 1, 2):
        if int(blocks[i]) == BTS_NR:
            block = blocks[i + 1]
            break
    else:
        if len(blocks) > 2:
            block = blocks[2]                # no BTS_NR: the first one
    # arfcn of the first trx (a template placeholder __ARFCN__ is ignored)
    m = re.search(r'\n\s*arfcn\s+(\d+)', block)
    if m:
        arfcn = m.group(1)
    # first trx only
    trx0 = re.split(r'\n\s*trx\s+\d+', block)
    scope = trx0[1] if len(trx0) > 1 else block
    # phys_chan_config is not necessarily the line that FOLLOWS "timeslot N":
    # a comment ("! ...") may sit between the two. Take the first
    # phys_chan_config of the timeslot block, up to the next timeslot.
    for tm in re.finditer(r'\n\s*timeslot\s+(\d+)((?:\n(?!\s*timeslot\s)[^\n]*)*)', scope):
        pm = re.search(r'\n\s*phys_chan_config\s+(\S+)', tm.group(2))
        if pm:
            types[int(tm.group(1))] = pm.group(1)
    return types, arfcn


# ── THE VTY CONNECTION THAT STAYS OPEN ──────────────────────────────────────
# The connection is kept across probe turns, and the reply is read up to the
# VTY prompt instead of sleeping a fixed delay: the reply is processed as soon
# as it is complete, usually within a few milliseconds, so a channel that gets
# established blinks its cell without a visible lag.
_PROMPT = re.compile(rb'[\r\n][A-Za-z0-9_.\-]+(?:\([^)]*\))?[>#]\s*$')


class Vty:
    def __init__(self):
        self.s = None

    def _connect(self):
        try:
            self.s = socket.create_connection((VTY_HOST, VTY_PORT), timeout=1.0)
            self.s.settimeout(1.0)
            self._read_until_prompt()          # the welcome banner
            return True
        except OSError:
            self.s = None
            return False

    def close(self):
        if self.s is not None:
            try:
                self.s.close()
            except OSError:
                pass
            self.s = None

    def _read_until_prompt(self, limit=262144):
        buf = b""
        while True:
            try:
                chunk = self.s.recv(4096)
            except socket.timeout:
                break                          # return what we have
            except OSError:
                self.close()
                return None
            if not chunk:
                self.close()
                return None
            buf += chunk
            if _PROMPT.search(buf) or len(buf) > limit:
                break
        return buf

    def cmd(self, text):
        """Output of a command, or None if the VTY is not reachable."""
        if self.s is None and not self._connect():
            return None
        try:
            self.s.sendall(text.encode() + b"\r\n")
        except OSError:
            self.close()
            if not self._connect():            # a single retry
                return None
            try:
                self.s.sendall(text.encode() + b"\r\n")
            except OSError:
                self.close()
                return None
        out = self._read_until_prompt()
        if out is None:
            return None
        return out.decode(errors="replace")


VTY = Vty()


def vty_lchan():
    """Return (ok, {ts: {'active':bool,'voice':bool}}) from the osmo-bsc VTY."""
    act = {}
    text = VTY.cmd("show lchan summary")
    if text is None:
        return False, act
    # typical lines: "BTS 0, TRX 0, Timeslot 2, ... Lchan 0, Type TCH/F, State ESTABLISHED ..."
    for line in text.splitlines():
        m = re.search(r'Timeslot\s+(\d+)', line)
        if not m:
            continue
        # The BTS and TRX of the line: a line from another BTS (or another
        # carrier) does not concern this banner. A line that does not name
        # them is kept - old output format, better to show than to lose the
        # information.
        mb = re.search(r'BTS\s+(\d+)', line)
        mx = re.search(r'TRX\s+(\d+)', line)
        if (mb and int(mb.group(1)) != BTS_NR) or (mx and int(mx.group(1)) != TRX_NR):
            continue
        ts = int(m.group(1))
        d = act.setdefault(ts, {"active": False, "voice": False})
        d["active"] = True
        typ = ""
        mt = re.search(r'Type\s+(\S+)', line)
        if mt:
            typ = mt.group(1).upper()
        state = line.upper()
        established = ("ESTABLISHED" in state or "ACTIVE" in state)
        if "TCH" in typ and established:
            d["voice"] = True
    return True, act


def vty_text(cmd):
    """Raw output of an osmo-bsc VTY command, or None if unreachable."""
    return VTY.cmd(cmd)


def vty_identity():
    """MCC/MNC, A5, arfcn, band LIVE from the VTY (the most up to date). {} if none."""
    ident = {}
    net = vty_text("show network")
    if net:
        m = re.search(r'Country Code[:\s]+(\d+).*?Network Code[:\s]+(\d+)', net, re.S)
        if m:
            ident["mcc"], ident["mnc"] = m.group(1), m.group(2)
        m = re.search(r'[Ee]ncryption[:\s]+A5/?(\d)', net)
        if m:
            ident["a5"] = m.group(1)
    bts = vty_text("show bts 0")
    if bts:
        m = re.search(r'\bARFCN[:\s]+(\d+)', bts) or re.search(r'\bC0[:\s]+(\d+)', bts)
        if m:
            ident["arfcn"] = m.group(1)
        m = re.search(r'[Bb]and[:\s]+(\S+)', bts)
        if m:
            ident["band"] = m.group(1)
    return ident


def net_from_cfg():
    """Fallback: MCC/MNC/A5/band from the conf file, placeholders ignored."""
    p = cfg_path()
    out = {}
    if not p:
        return out
    try:
        txt = open(p, errors="replace").read()
    except OSError:
        return out
    def grab(rx, key):
        m = re.search(rx, txt)
        if m and "__" not in m.group(1):
            out[key] = m.group(1)
    grab(r'\n\s*network country code\s+(\S+)', "mcc")
    grab(r'\n\s*mobile network code\s+(\S+)', "mnc")
    grab(r'\n\s*encryption\s+a5\s+(\S+)', "a5")
    grab(r'\n\s*band\s+(\S+)', "band")
    return out


def build():
    types, cfg_arfcn = read_types()
    if not types:
        # reasonable default without a conf: the classic bench topology
        types = {0: "CCCH+SDCCH4", 1: "SDCCH8", 2: "TCH/F", 3: "TCH/F",
                 4: "TCH/F", 5: "TCH/F", 6: "TCH/F", 7: "TCH/F"}
    ok, act = vty_lchan()
    ts = []
    for n in range(8):
        a = act.get(n, {})
        ts.append({"n": n, "type": types.get(n, "NONE"),
                   "active": bool(a.get("active")), "voice": bool(a.get("voice"))})
    out = {"bsc": ok, "ts": ts}

    # ── THE LIVE VALUES: ARFCN / IMSI (MCC-MNC) / A5 / band ──────────────────
    # The VTY wins (real state of the running network); the conf file is the
    # fallback; the repo template does not count (__MCC__ placeholders ignored).
    ident = {}
    if cfg_arfcn and "__" not in cfg_arfcn:
        ident["arfcn"] = cfg_arfcn
    ident.update(net_from_cfg())
    if ok:
        ident.update(vty_identity())  # live overrides the file

    band = ident.get("band", "")
    band_txt = ""
    if band:
        b = str(band).upper().replace("DCS", "DCS ").replace("PCS", "PCS ")
        band_txt = " · " + b
    if ident.get("arfcn"):
        out["arfcn"] = "ARFCN %s%s" % (ident["arfcn"], band_txt)
    if ident.get("mcc") and ident.get("mnc"):
        out["imsi"] = "%s-%s" % (str(ident["mcc"]).zfill(3), str(ident["mnc"]).zfill(2))
    if ident.get("a5"):
        out["a5"] = str(ident["a5"])
    out.update(live_info(ts))
    return out


# ── THE BENCH IN REAL TIME, FOR THE BANNER ──────────────────────────────────
# The banner receives the whole bench - the core daemons, the radio, the HLR
# subscribers, the calls in progress, how long the stack has been up - read
# cheaply (/proc, the HLR sqlite database read-only) every 2 s: the rest of
# the probe runs four times per second, and daemons that live for hours do
# not need to be recounted at that rate. Names are those the kernel keeps
# (comm, 15 characters) - "osmo-sip-connector" reads "osmo-sip-connec" there,
# as in tools/conky-osmo-status.sh.
COEUR = (("HLR", "osmo-hlr"), ("MSC", "osmo-msc"), ("BSC", "osmo-bsc"), ("STP", "osmo-stp"),
         ("MGW", "osmo-mgw"), ("BTS", "osmo-bts-trx"), ("SIP", "osmo-sip-connector"),
         ("SMSC", "proto-smsc-daemon"), ("PBX", "asterisk"))
RADIO = (("MOBILE", "mobile"), ("TRXCON", "trxcon"), ("QEMU", "qemu-system-arm"),
         ("GAPK", "osmo-gapk"))
HLR_DB = os.environ.get("OSMO_HLR_DB", "/var/lib/osmocom/hlr.db")
_live = {"quand": 0.0, "val": {}}


def _procs():
    """(comm names, command lines, {comm: pid}) of all processes."""
    comms, cmds, pids = set(), [], {}
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            with open("/proc/%s/comm" % p) as f:
                c = f.read().strip()
            with open("/proc/%s/cmdline" % p, "rb") as f:
                cmds.append(f.read(300).replace(b"\0", b" ").decode(errors="replace"))
        except OSError:
            continue
        comms.add(c)
        pids.setdefault(c, int(p))
    return comms, cmds, pids


def _depuis(pid):
    """How many seconds this process has been running (0 if unreadable)."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            champs = f.read().rsplit(")", 1)[1].split()
        start = int(champs[19]) / os.sysconf("SC_CLK_TCK")
        with open("/proc/uptime") as f:
            up = float(f.read().split()[0])
        return max(0, int(up - start))
    except (OSError, ValueError, IndexError):
        return 0


def live_info(ts):
    now = time.time()
    if now - _live["quand"] < 2.0:
        return _live["val"]
    val = {}
    try:
        comms, cmds, pids = _procs()
        core = {n: (c[:15] in comms) for n, c in COEUR}
        radio = {n: (c[:15] in comms) for n, c in RADIO}
        phy = ""
        if any("qemu-system-arm" in c for c in cmds):
            phy = "Calypso émulé (QEMU)"
        if any("fake_trx.py" in c for c in cmds):
            phy = "faketrx"
        if any(re.search(r"pont/pont(_dsp)?\.py", c) for c in cmds):
            phy = (phy + " + pont") if phy else "pont"
        # The ISO bench has NO osmo-trx: the transceiver is faketrx
        # (fake_trx.py) and pont (pont.py / pont_dsp.py) - shown as such.
        # GAPK: the osmo-gapk binary only exists for the duration of a call;
        # outside a call the gapk-start.sh watcher IS the nominal state.
        radio["FAKETRX"] = any("fake_trx.py" in c for c in cmds)
        radio["PONT"] = any(re.search(r"pont/pont(_dsp)?\.py", c) for c in cmds)
        radio["GAPK"] = radio.get("GAPK", False) or any("gapk-start.sh" in c for c in cmds)
        subs = {}
        if core["HLR"] and os.path.exists(HLR_DB):
            try:
                import sqlite3
                con = sqlite3.connect("file:%s?mode=ro" % HLR_DB, uri=True, timeout=0.2)
                tot = con.execute("select count(*) from subscriber").fetchone()[0]
                att = con.execute("select count(*) from subscriber where vlr_number is not null "
                                  "and vlr_number != ''").fetchone()[0]
                con.close()
                subs = {"total": tot, "attached": att}
            except Exception:  # noqa: BLE001 - locked or unreadable db: no subscribers
                subs = {}
        depuis = 0
        for c in ("osmo-bsc", "osmo-stp", "osmo-msc"):
            if c in pids:
                depuis = _depuis(pids[c])
                break
        val = {"core": core, "radio": radio, "phy": phy, "subs": subs,
               "calls": sum(1 for t in ts if t.get("voice")), "up": depuis}
    except Exception as e:  # noqa: BLE001 - the banner lives without this info
        print("[ts-probe] infos banc : %s" % e, file=sys.stderr, flush=True)
    _live.update(quand=now, val=val)
    return val


def main():
    # 0.25 s: short enough for a channel lighting up to look "immediate" to
    # the eye, long enough not to hammer the osmo-bsc VTY (4 "show lchan
    # summary" per second on an already open connection).
    period = float(os.environ.get("OSMO_TS_PERIOD", "0.25"))
    try:
        os.makedirs(RUN_PREFERE, exist_ok=True)
    except OSError:
        pass                                  # run_dir() falls back to /tmp
    tmp = None
    dernier = (None, 0.0)                     # (message, when) - see below
    while True:
        try:
            out = build()
            dest = os.path.join(run_dir(), "timeslots.json")
            # ── ONE TEMPORARY FILE PER PROCESS ──────────────────────────────
            # Two probes may run at the same time (e.g. a widget surviving
            # from a previous X session). The PID in the temporary name keeps
            # the write atomic even with several writers: each one renames
            # its own temporary file only.
            tmp = "%s.%d.tmp" % (dest, os.getpid())
            with open(tmp, "w") as f:
                json.dump(out, f)
            os.replace(tmp, dest)
            tmp = None
        except Exception as e:  # noqa: BLE001 - a probe must never die
            # An orphan temporary file must not stay in /run.
            if tmp:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                tmp = None
            # ── THE SAME FAULT IS NOT LOGGED FOUR TIMES PER SECOND ──────────
            # A lasting failure (directory not accessible) would flood the log
            # with identical lines. Log the first one, then one per minute as
            # long as nothing changes.
            msg = "%s (destination %s)" % (e, run_dir())
            now = time.time()
            if msg != dernier[0] or now - dernier[1] > 60:
                print("[ts-probe] %s" % msg, file=sys.stderr, flush=True)
                dernier = (msg, now)
        time.sleep(period)


if __name__ == "__main__":
    main()

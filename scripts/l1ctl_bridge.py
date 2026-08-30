#!/usr/bin/env python3
"""
l1ctl_bridge.py — Pure sercomm ↔ UDP bridge.

The bridge is a translator/forwarder:
  mobile ←L1CTL→ bridge ←sercomm/UART→ firmware ARM (L1 processing)
  BTS ←TRXD/TRXC/CLK→ bridge (built-in TRX server)

The firmware ARM does ALL L1 processing. The bridge just forwards.
Bursts from BTS arrive via TRXD → bridge sends to firmware via sercomm (new DLCI).
TX bursts from firmware arrive via sercomm → bridge sends to BTS via TRXD.
"""

import errno, fcntl, os, select, signal, socket, struct, sys, termios, threading, time

# ═══════════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════════

GSM_HYPERFRAME = 2715648
GSM_FRAME_US   = 4615.0
L1CTL_SOCK     = "/tmp/osmocom_l2"
SERCOMM_FLAG   = 0x7E; SERCOMM_ESCAPE = 0x7D; SERCOMM_XOR = 0x20
DLCI_L1CTL     = 5
DLCI_BURST     = 6   # New DLCI for burst data (firmware ↔ bridge)

# ═══════════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════════

def udp_bind_connect(bind_port, dst_addr, dst_port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", bind_port))
    s.connect((dst_addr, dst_port))
    s.setblocking(False); return s

def sercomm_wrap(dlci, payload):
    out = bytearray([SERCOMM_FLAG])
    for b in bytes([dlci, 0x03]) + payload:
        if b in (SERCOMM_FLAG, SERCOMM_ESCAPE):
            out.append(SERCOMM_ESCAPE); out.append(b ^ SERCOMM_XOR)
        else: out.append(b)
    out.append(SERCOMM_FLAG); return bytes(out)

class SercommParser:
    def __init__(self): self.buf = bytearray()
    def feed(self, data):
        self.buf.extend(data); frames = []
        while True:
            try: s = self.buf.index(SERCOMM_FLAG)
            except ValueError: self.buf.clear(); break
            if s > 0: del self.buf[:s]
            try: e = self.buf.index(SERCOMM_FLAG, 1)
            except ValueError: break
            raw = bytes(self.buf[1:e]); del self.buf[:e+1]
            if not raw: continue
            out = bytearray(); i = 0
            while i < len(raw):
                if raw[i] == SERCOMM_ESCAPE: i += 1; out.append(raw[i] ^ SERCOMM_XOR) if i < len(raw) else None
                else: out.append(raw[i])
                i += 1
            if len(out) >= 2: frames.append((out[0], bytes(out[2:])))
        return frames

class LPReader:
    def __init__(self): self.buf = bytearray()
    def feed(self, data):
        self.buf.extend(data); msgs = []
        while len(self.buf) >= 2:
            ml = struct.unpack(">H", self.buf[:2])[0]
            if len(self.buf) < 2 + ml: break
            msgs.append(bytes(self.buf[2:2+ml])); del self.buf[:2+ml]
        return msgs


# ═══════════════════════════════════════════════════════════════════════════════
# BTS TRX Server — built-in virtual TRX for the BTS
# ═══════════════════════════════════════════════════════════════════════════════

class BTSTrx:
    """Virtual TRX for the BTS. Provides CLK, TRXC, TRXD."""

    def __init__(self, bts_base=5700):
        self.bts_base = bts_base
        self.clk_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.clk_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.clk_sock.bind(("127.0.0.1", bts_base)); self.clk_sock.setblocking(False)

        self.trxc_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.trxc_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.trxc_sock.bind(("127.0.0.1", bts_base + 1)); self.trxc_sock.setblocking(False)

        self.trxd_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.trxd_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.trxd_sock.bind(("127.0.0.1", bts_base + 2)); self.trxd_sock.setblocking(False)

        self.bts_trxd_addr = None
        self.clk_fn = 0
        self.running = False
        self.stats = {"dl": 0, "ul": 0}

        self._stop = threading.Event()
        self._clk_thread = threading.Thread(target=self._clock_run, daemon=True)
        self._clk_thread.start()
        print(f"bts-trx: listening on {bts_base}-{bts_base+2}", flush=True)

    def _clock_run(self):
        tick_ns = int(GSM_FRAME_US * 1000)
        t_next = time.monotonic_ns()
        while not self._stop.is_set():
            t_next += tick_ns
            dt = t_next - time.monotonic_ns()
            if dt > 0: time.sleep(dt / 1e9)
            elif dt < -tick_ns * 10: t_next = time.monotonic_ns()
            self.clk_fn = (self.clk_fn + 1) % GSM_HYPERFRAME
            if self.clk_fn % 102 == 0:
                try: self.clk_sock.sendto(f"IND CLOCK {self.clk_fn}\0".encode(),
                                           ("127.0.0.1", self.bts_base + 100))
                except: pass

    def handle_trxc(self):
        try: data, addr = self.trxc_sock.recvfrom(256)
        except: return
        cmd = data.strip(b'\x00').decode(errors='replace')
        parts = cmd.split()
        if len(parts) < 2 or parts[0] != "CMD": return
        verb = parts[1]
        params = " ".join(parts[2:])
        if verb != "SETPOWER":
            print(f"  [TRXC] {cmd}", flush=True)

        if verb == "POWERON":
            self.running = True; rsp = "RSP POWERON 0"
        elif verb == "POWEROFF":
            self.running = False; rsp = "RSP POWEROFF 0"
        elif verb == "SETFORMAT":
            rsp = "RSP SETFORMAT 0"
        elif params:
            rsp = f"RSP {verb} 0 {params}"
        else:
            rsp = f"RSP {verb} 0"
        self.trxc_sock.sendto(rsp.encode(), addr)

    def recv_dl_burst(self):
        """Receive DL burst from BTS. Returns raw TRXD packet or None."""
        try: data, addr = self.trxd_sock.recvfrom(512)
        except: return None
        self.bts_trxd_addr = addr
        self.stats["dl"] += 1
        return data

    def send_ul_burst(self, data):
        """Send UL burst to BTS. Data is raw TRXD packet."""
        if not self.bts_trxd_addr: return
        self.trxd_sock.sendto(data, self.bts_trxd_addr)
        self.stats["ul"] += 1

    def sockets(self):
        return [self.trxc_sock, self.trxd_sock]

    def close(self):
        self._stop.set()
        for s in [self.clk_sock, self.trxc_sock, self.trxd_sock]:
            try: s.close()
            except: pass


# ═══════════════════════════════════════════════════════════════════════════════
# Main — pure forwarder
# ═══════════════════════════════════════════════════════════════════════════════

def send_to_mobile(client, payload):
    if client:
        try: client.sendall(struct.pack(">H", len(payload)) + payload); return True
        except: return False
    return False

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <uart-sock> [l1ctl-sock] [bts-base]"); sys.exit(1)

    pty_path = sys.argv[1]
    global L1CTL_SOCK
    if len(sys.argv) > 2 and not sys.argv[2].startswith("-"):
        L1CTL_SOCK = sys.argv[2]
    nums = [a for a in sys.argv[2:] if a.isdigit()]
    bts_base = int(nums[0]) if len(nums) > 0 else 5700

    try: os.unlink(L1CTL_SOCK)
    except FileNotFoundError: pass

    # QEMU UART
    import stat as stat_mod
    qemu_sock = None
    if os.path.exists(pty_path) and stat_mod.S_ISSOCK(os.stat(pty_path).st_mode):
        qemu_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        qemu_sock.connect(pty_path); qemu_sock.setblocking(False)
        pty_fd = qemu_sock.fileno()
    else:
        pty_fd = os.open(pty_path, os.O_RDWR | os.O_NOCTTY)
        attrs = termios.tcgetattr(pty_fd)
        attrs[0] = attrs[1] = attrs[3] = 0
        attrs[2] = termios.CS8 | termios.CLOCAL | termios.CREAD
        attrs[4] = attrs[5] = termios.B115200
        attrs[6][termios.VMIN] = 1; attrs[6][termios.VTIME] = 0
        termios.tcsetattr(pty_fd, termios.TCSANOW, attrs)
        fl = fcntl.fcntl(pty_fd, fcntl.F_GETFL)
        fcntl.fcntl(pty_fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)

    # L1CTL server
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(L1CTL_SOCK); srv.listen(1); srv.setblocking(False)

    # BTS TRX server
    trx = BTSTrx(bts_base)

    print(f"bridge: uart={pty_path} l1ctl={L1CTL_SOCK} bts={bts_base}", flush=True)
    print(f"  sercomm DLCI {DLCI_L1CTL}=L1CTL, DLCI {DLCI_BURST}=bursts", flush=True)

    parser = SercommParser(); lp = LPReader()
    client = None; running = True
    stats = {"l1ctl_tx": 0, "l1ctl_rx": 0, "burst_dl": 0, "burst_ul": 0}

    def shutdown(s, f): nonlocal running; running = False
    signal.signal(signal.SIGINT, shutdown); signal.signal(signal.SIGTERM, shutdown)

    try:
        while running:
            rlist = [srv, pty_fd] + trx.sockets()
            if client: rlist.append(client)
            try: readable, _, _ = select.select(rlist, [], [], 0.5)
            except (OSError, ValueError): break

            # ── Accept mobile ──
            if srv in readable:
                conn, _ = srv.accept(); conn.setblocking(False)
                if client:
                    try: client.close()
                    except: pass
                client = conn; lp = LPReader()
                print("mobile connected", flush=True)

            # ── L1CTL: mobile → firmware (pure forward via sercomm) ──
            if client and client in readable:
                try: raw = client.recv(4096)
                except BlockingIOError: raw = b""
                if not raw:
                    print("mobile disconnected", flush=True)
                    try: client.close()
                    except: pass
                    client = None
                else:
                    for payload in lp.feed(raw):
                        stats["l1ctl_tx"] += 1
                        frame = sercomm_wrap(DLCI_L1CTL, payload)
                        try: os.write(pty_fd, frame)
                        except OSError: pass
                        if stats["l1ctl_tx"] <= 10:
                            mt = payload[0] if payload else 0
                            print(f"  [L1CTL→fw] type=0x{mt:02x} len={len(payload)}", flush=True)

            # ── UART: firmware → mobile/bridge ──
            if pty_fd in readable:
                try: raw = os.read(pty_fd, 4096)
                except OSError as e:
                    if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK): raw = b""
                    else: raise
                if raw:
                    for dlci, payload in parser.feed(raw):
                        if dlci == DLCI_L1CTL and client:
                            # L1CTL from firmware → mobile
                            stats["l1ctl_rx"] += 1
                            send_to_mobile(client, payload)
                        elif dlci == DLCI_BURST:
                            # TX burst from firmware → BTS
                            trx.send_ul_burst(payload)
                            stats["burst_ul"] += 1

            # ── BTS TRXC ──
            if trx.trxc_sock in readable:
                trx.handle_trxc()

            # ── BTS TRXD: DL burst → firmware via sercomm (TS0, 1 per multiframe) ──
            if trx.trxd_sock in readable:
                data = trx.recv_dl_burst()
                if data and len(data) >= 6 and client:
                    tn = data[0] & 0x07
                    fn = struct.unpack(">I", data[1:5])[0]
                    mf = fn % 51
                    # Forward FCCH(0,10,20,30,40), SCH(1,11,21,31,41), BCCH(2-5), CCCH(6-9)
                    if tn == 0 and mf <= 9:
                        frame = sercomm_wrap(DLCI_BURST, data)
                        try: os.write(pty_fd, frame)
                        except OSError: pass
                        stats["burst_dl"] += 1

    finally:
        if client: client.close()
        srv.close(); trx.close()
        if qemu_sock: qemu_sock.close()
        else: os.close(pty_fd)
        try: os.unlink(L1CTL_SOCK)
        except: pass
        print(f"done l1ctl={stats['l1ctl_tx']}/{stats['l1ctl_rx']} "
              f"burst={stats['burst_dl']}/{stats['burst_ul']}", flush=True)

if __name__ == "__main__":
    main()

# vty.py - access to the Osmocom VTYs from the host.
#
# The lab VTYs only listen on 127.0.0.1 INSIDE the node: from the host, they
# are reached through "docker exec". Not every container has nc; they all
# have python3, telnet and socat. A small python relay is therefore pushed
# into the container, which also gives a PERSISTENT session: the VTY keeps
# its context (enable, config node) from one command to the next, exactly
# like a manual telnet.
#
# In native mode (no docker), the same class talks directly to the local socket.

import os
import re
import shutil
import socket
import subprocess
import threading
import time

EOC = b"\x01EOC\x01"

# Relay executed INSIDE the node. Protocol: one command per line on stdin,
# the raw VTY output on stdout, terminated by the EOC marker.
_RELAY = r'''
import socket, sys, time
port = int(sys.argv[1])
EOC = b"\x01EOC\x01\n"
try:
    s = socket.create_connection(("127.0.0.1", port), 5)
except Exception as e:
    sys.stdout.buffer.write(("__ERR__ %s\n" % e).encode()); sys.stdout.buffer.write(EOC)
    sys.stdout.buffer.flush(); sys.exit(0)
s.settimeout(0.35)
def pump(idle=0.35, hard=8.0):
    out = b""; t0 = time.time(); last = time.time()
    while True:
        try:
            d = s.recv(65536)
            if not d:
                break
            out += d; last = time.time()
        except socket.timeout:
            if out and (time.time() - last) >= idle:
                break
            if (time.time() - t0) > hard:
                break
    return out
sys.stdout.buffer.write(pump()); sys.stdout.buffer.write(EOC); sys.stdout.buffer.flush()
for line in sys.stdin:
    cmd = line.rstrip("\n")
    try:
        s.sendall(cmd.encode() + b"\r\n")
    except Exception as e:
        sys.stdout.buffer.write(("__ERR__ %s\n" % e).encode())
        sys.stdout.buffer.write(EOC); sys.stdout.buffer.flush(); break
    sys.stdout.buffer.write(pump()); sys.stdout.buffer.write(EOC); sys.stdout.buffer.flush()
'''

_IAC = re.compile(rb"\xff[\xfb-\xfe].|\xff[\xf0-\xfa]")


def clean(raw):
    """Readable VTY output: telnet negotiation, CRs and prompts removed."""
    if isinstance(raw, str):
        raw = raw.encode("utf-8", "replace")
    raw = _IAC.sub(b"", raw)
    txt = raw.decode("utf-8", "replace").replace("\r", "")
    out = []
    for line in txt.split("\n"):
        # The prompt ("OsmoSTP> ", "OsmoHLR# ") comes back with every command:
        # it adds nothing in a panel, and the real prompt is shown by the
        # console itself.
        line = re.sub(r"^Osmo[A-Za-z0-9_-]*[#>]\s?", "", line)
        line = line.replace("\x00", "")
        out.append(line.rstrip())
    while out and not out[0].strip():
        out.pop(0)
    while out and not out[-1].strip():
        out.pop()
    return "\n".join(out)


class VtyError(Exception):
    pass


class VtySession(object):
    """Persistent VTY session to a (node, port)."""

    def __init__(self, node, port, docker=True, timeout=12.0):
        self.node = node
        self.port = int(port)
        self.docker = docker
        self.timeout = timeout
        self.proc = None
        self.sock = None
        self.banner = ""
        self.lock = threading.Lock()
        self.alive = False

    # ── open / close ─────────────────────────────────────────────────────
    def open(self):
        if self.alive:
            return self
        if self.docker and not _container_up(self.node):
            raise VtyError("le conteneur %s ne tourne pas" % self.node)
        if self.docker:
            self.proc = subprocess.Popen(
                ["docker", "exec", "-i", self.node, "python3", "-", str(self.port)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
            self.proc.stdin.write(_RELAY.encode())
            self.proc.stdin.flush()
            self.proc.stdin.close()
            # The relay then reads its commands on stdin, which has just been
            # closed. docker exec cannot reopen stdin, so the relay is started
            # again in "script on the command line" mode (see _open_docker).
            self.proc.kill()
            self.proc = None
            return self._open_docker()
        try:
            self.sock = socket.create_connection(("127.0.0.1", self.port), 5)
        except OSError as exc:
            raise VtyError("VTY 127.0.0.1:%s injoignable (%s)"
                           % (self.port, exc.strerror or exc))
        self.sock.settimeout(0.35)
        self.banner = clean(self._pump_socket())
        self.alive = True
        return self

    def _open_docker(self):
        # -c: the relay comes as an argument, stdin stays free for the
        # commands. This is what gives the persistent session.
        self.proc = subprocess.Popen(
            ["docker", "exec", "-i", self.node, "python3", "-c", _RELAY, str(self.port)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0,
        )
        try:
            self.banner = clean(self._read_until_eoc())
        except Exception as exc:
            self.close()
            raise VtyError("VTY %s:%s injoignable (%s)" % (self.node, self.port, exc))
        if "__ERR__" in self.banner:
            msg = self.banner.strip()
            self.close()
            raise VtyError(msg.replace("__ERR__", "").strip())
        self.alive = True
        return self

    def close(self):
        self.alive = False
        if self.proc:
            try:
                self.proc.stdin.close()
            except Exception:
                pass
            try:
                self.proc.terminate()
                self.proc.wait(timeout=2)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
            self.proc = None
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None

    # ── dialogue ─────────────────────────────────────────────────────────
    def _read_until_eoc(self):
        buf = b""
        deadline = time.time() + self.timeout
        while EOC not in buf:
            if time.time() > deadline:
                raise VtyError("delai depasse en lisant le VTY")
            chunk = self.proc.stdout.read(1)
            if not chunk:
                raise VtyError("relais VTY termine")
            buf += chunk
        return buf.split(EOC)[0]

    def _pump_socket(self, idle=0.35, hard=8.0):
        out = b""
        t0 = last = time.time()
        while True:
            try:
                d = self.sock.recv(65536)
                if not d:
                    break
                out += d
                last = time.time()
            except socket.timeout:
                if out and (time.time() - last) >= idle:
                    break
                if (time.time() - t0) > hard:
                    break
        return out

    def cmd(self, command):
        """Send a command, return the cleaned output."""
        with self.lock:
            if not self.alive:
                self.open()
            if self.docker:
                try:
                    self.proc.stdin.write(command.encode() + b"\n")
                    self.proc.stdin.flush()
                    raw = self._read_until_eoc()
                except (BrokenPipeError, VtyError):
                    self.close()
                    raise VtyError("session VTY perdue (%s:%s)" % (self.node, self.port))
            else:
                self.sock.sendall(command.encode() + b"\r\n")
                raw = self._pump_socket()
            return clean(raw)


class VtyPool(object):
    """Open sessions, one per (node, port). Closed on request - that is what
    Escape does in the console: THIS VTY is left, the others stay
    available."""

    def __init__(self, docker=True):
        self.docker = docker
        self.sessions = {}

    def get(self, node, port):
        key = (node, int(port))
        sess = self.sessions.get(key)
        if sess is None or not sess.alive:
            sess = VtySession(node, port, docker=self.docker)
            sess.open()
            self.sessions[key] = sess
        return sess

    def cmd(self, node, port, command):
        return self.get(node, port).cmd(command)

    def drop(self, node, port):
        key = (node, int(port))
        sess = self.sessions.pop(key, None)
        if sess:
            sess.close()
            return True
        return False

    def close_all(self):
        for sess in list(self.sessions.values()):
            sess.close()
        self.sessions.clear()


def _container_up(name):
    try:
        out = subprocess.run(["docker", "ps", "--format", "{{.Names}}"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=10).stdout.decode()
    except Exception:
        return False
    return name in out.split()


def docker_available():
    return shutil.which("docker") is not None and os.system(
        "docker ps >/dev/null 2>&1") == 0

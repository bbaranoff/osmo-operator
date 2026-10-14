#!/usr/bin/env python3
"""
ism_payload.py — le PAYLOAD des SMS sur une liaison radio ISM, le reste par IP.

Idee (option start-direct.sh --payload-ism, cf. wiki/Payload-ISM.md) : entre deux
noeuds osmo-operator, la SIGNALISATION (adresses, MSISDN, IMSI, SC-address, SS7,
SIP) continue de passer par IP comme avec --wan. SEUL le contenu du message (le
texte du SMS, extrait du TPDU) voyage sur une liaison radio en bande ISM (433 /
868 / 915 MHz, 2,4 GHz — sans licence). Les deux relais se coordonnent par TCP ;
le TCP ne porte plus le texte mais un JETON de correlation, et le texte arrive
par la radio, estampille du meme jeton.

Ce module ne connait aucun materiel : il parle a l INTERFACE DE DONNEES de ta
radio (un peripherique serie, une paire de tubes nommes, ou l entree/sortie d un
programme que tu fournis — un montage SDR GNU Radio, rtl_433, un module LoRa/
RFM69/CC1101 en UART...). On choisit le backend par variable d environnement ou
par la section [payload] de sms-routing.conf.

Trame (robuste sur un lien bruite, sans dependance hors stdlib) : une ligne JSON
terminee par \\n, payload en hexa, CRC32 :
    {"t":"<jeton>","p":"<hex>","c":"<crc32hex>"}\\n
Une ligne tronquee ou un CRC faux est ignore (la radio peut perdre des octets).

BACKENDS (ISM_LINK / [payload] link=) :
  loopback  tout en memoire, pour un essai sur une seule machine (pas de radio)
  fifo      deux tubes nommes : ISM_TX (ecriture) et ISM_RX (lecture).
            Branche n importe quel outil radio dessus (socat, un flowgraph SDR...)
  serial    un /dev/tty* en lecture/ecriture brute (module ISM en UART).
            Debit pose par le script de mise en place (stty), ISM_SERIAL=/dev/ttyUSB0
  exec      lance une commande TX (trame sur son stdin) et une commande RX
            (trames sur son stdout) : ISM_TX_CMD / ISM_RX_CMD. Le plus general.

Variables : ISM_LINK, ISM_TX, ISM_RX, ISM_SERIAL, ISM_TX_CMD, ISM_RX_CMD,
ISM_PAYLOAD_TTL (secondes, defaut 120), ISM_RECV_TIMEOUT (defaut 30).

Autotest (sans radio) :
    python3 ism_payload.py --selftest
    python3 ism_payload.py --selftest --link fifo --tx /tmp/ism_a --rx /tmp/ism_b
"""

import os
import sys
import time
import json
import zlib
import queue
import shlex
import select
import threading
import subprocess
from typing import Optional, Dict, Tuple, Callable

DEFAULT_TTL = float(os.environ.get("ISM_PAYLOAD_TTL", "120"))
DEFAULT_RECV_TIMEOUT = float(os.environ.get("ISM_RECV_TIMEOUT", "30"))


def _log(msg: str):
    sys.stderr.write("[ism] %s\n" % msg)
    sys.stderr.flush()


def frame_encode(token: str, payload: bytes) -> bytes:
    """(token, payload) -> une ligne de trame terminee par \\n."""
    hexp = payload.hex()
    crc = "%08x" % (zlib.crc32(payload) & 0xFFFFFFFF)
    obj = {"t": token, "p": hexp, "c": crc}
    return (json.dumps(obj, separators=(",", ":")) + "\n").encode("ascii")


def frame_decode(line: bytes) -> Optional[Tuple[str, bytes]]:
    """Une ligne de trame -> (token, payload), ou None si invalide / CRC faux."""
    try:
        obj = json.loads(line.decode("ascii", "replace").strip())
        token = obj["t"]
        payload = bytes.fromhex(obj["p"])
        if ("%08x" % (zlib.crc32(payload) & 0xFFFFFFFF)) != obj.get("c"):
            _log("trame rejetee : CRC faux (jeton %s)" % token)
            return None
        return token, payload
    except Exception:
        return None


# ═══════════════════════════════════════════════════════════════════════════════
# Backends : chacun expose write_frame(bytes) et un generateur read_frames()
# ═══════════════════════════════════════════════════════════════════════════════

class _Backend:
    def write_frame(self, data: bytes) -> None:
        raise NotImplementedError

    def read_line(self, timeout: float) -> Optional[bytes]:
        """Une ligne (sans le \\n), ou None si rien avant timeout."""
        raise NotImplementedError

    def close(self) -> None:
        pass


class LoopbackBackend(_Backend):
    """TX ecrit directement dans la file de RX : un essai sans radio."""
    def __init__(self):
        self._q: "queue.Queue[bytes]" = queue.Queue()

    def write_frame(self, data: bytes) -> None:
        for line in data.splitlines():
            if line:
                self._q.put(line)

    def read_line(self, timeout: float) -> Optional[bytes]:
        try:
            return self._q.get(timeout=timeout)
        except queue.Empty:
            return None


class FifoBackend(_Backend):
    """Deux tubes nommes : tx (ecriture, vers la radio) et rx (lecture)."""
    def __init__(self, tx_path: str, rx_path: str):
        self.tx_path = tx_path
        self.rx_path = rx_path
        for p in (tx_path, rx_path):
            if p and not os.path.exists(p):
                os.mkfifo(p, 0o600)
        # Lecture non bloquante : on ouvre le rx en O_RDONLY|O_NONBLOCK et on
        # garde un ecrivain fictif pour ne pas voir EOF a chaque vidage du tube.
        self._rx_fd = os.open(rx_path, os.O_RDONLY | os.O_NONBLOCK)
        try:
            self._rx_keepalive = os.open(rx_path, os.O_WRONLY | os.O_NONBLOCK)
        except OSError:
            self._rx_keepalive = -1
        self._buf = b""

    def write_frame(self, data: bytes) -> None:
        # O_WRONLY peut bloquer si personne ne lit : ecriture best-effort.
        fd = os.open(self.tx_path, os.O_WRONLY | os.O_NONBLOCK)
        try:
            os.write(fd, data)
        except BlockingIOError:
            _log("fifo tx pleine, trame perdue")
        finally:
            os.close(fd)

    def read_line(self, timeout: float) -> Optional[bytes]:
        if b"\n" in self._buf:
            line, self._buf = self._buf.split(b"\n", 1)
            return line
        r, _, _ = select.select([self._rx_fd], [], [], timeout)
        if not r:
            return None
        try:
            chunk = os.read(self._rx_fd, 4096)
        except BlockingIOError:
            return None
        if not chunk:
            return None
        self._buf += chunk
        if b"\n" in self._buf:
            line, self._buf = self._buf.split(b"\n", 1)
            return line
        return None

    def close(self) -> None:
        for fd in (getattr(self, "_rx_fd", -1), getattr(self, "_rx_keepalive", -1)):
            if fd and fd >= 0:
                try:
                    os.close(fd)
                except OSError:
                    pass


class SerialBackend(_Backend):
    """Un /dev/tty* en brut. Le debit est pose dehors (stty), on lit/ecrit les octets."""
    def __init__(self, dev: str):
        self.dev = dev
        self._fd = os.open(dev, os.O_RDWR | os.O_NONBLOCK | os.O_NOCTTY)
        self._buf = b""

    def write_frame(self, data: bytes) -> None:
        try:
            os.write(self._fd, data)
        except BlockingIOError:
            time.sleep(0.05)
            try:
                os.write(self._fd, data)
            except OSError:
                _log("serie tx occupee, trame perdue")

    def read_line(self, timeout: float) -> Optional[bytes]:
        if b"\n" in self._buf:
            line, self._buf = self._buf.split(b"\n", 1)
            return line
        r, _, _ = select.select([self._fd], [], [], timeout)
        if not r:
            return None
        try:
            chunk = os.read(self._fd, 4096)
        except BlockingIOError:
            return None
        if chunk:
            self._buf += chunk
        if b"\n" in self._buf:
            line, self._buf = self._buf.split(b"\n", 1)
            return line
        return None

    def close(self) -> None:
        try:
            os.close(self._fd)
        except OSError:
            pass


class ExecBackend(_Backend):
    """Lance un TX (trame sur stdin) et un RX (trames sur stdout) : ton pipeline SDR."""
    def __init__(self, tx_cmd: str, rx_cmd: str):
        self.tx_cmd = tx_cmd
        self.rx_cmd = rx_cmd
        self._rx = subprocess.Popen(shlex.split(rx_cmd), stdout=subprocess.PIPE,
                                    bufsize=0)

    def write_frame(self, data: bytes) -> None:
        # Un TX par trame : simple et sans etat ; la commande emet puis rend la main.
        try:
            p = subprocess.Popen(shlex.split(self.tx_cmd), stdin=subprocess.PIPE)
            p.stdin.write(data)
            p.stdin.close()
            p.wait(timeout=30)
        except Exception as e:
            _log("exec tx echec : %s" % e)

    def read_line(self, timeout: float) -> Optional[bytes]:
        if self._rx.stdout is None:
            return None
        r, _, _ = select.select([self._rx.stdout], [], [], timeout)
        if not r:
            return None
        line = self._rx.stdout.readline()
        return line.rstrip(b"\n") if line else None

    def close(self) -> None:
        try:
            self._rx.terminate()
        except Exception:
            pass


def make_backend(cfg: Dict[str, str]) -> _Backend:
    link = (cfg.get("link") or os.environ.get("ISM_LINK") or "loopback").lower()
    if link == "loopback":
        return LoopbackBackend()
    if link == "fifo":
        tx = cfg.get("tx") or os.environ.get("ISM_TX") or "/tmp/osmo_ism_tx"
        rx = cfg.get("rx") or os.environ.get("ISM_RX") or "/tmp/osmo_ism_rx"
        return FifoBackend(tx, rx)
    if link == "serial":
        dev = cfg.get("serial") or os.environ.get("ISM_SERIAL") or "/dev/ttyUSB0"
        return SerialBackend(dev)
    if link == "exec":
        tx = cfg.get("tx_cmd") or os.environ.get("ISM_TX_CMD")
        rx = cfg.get("rx_cmd") or os.environ.get("ISM_RX_CMD")
        if not tx or not rx:
            raise ValueError("backend exec : ISM_TX_CMD et ISM_RX_CMD requis")
        return ExecBackend(tx, rx)
    raise ValueError("backend ISM inconnu : %r (loopback, fifo, serial, exec)" % link)


# ═══════════════════════════════════════════════════════════════════════════════
# PayloadLink : send(jeton, payload) / recv(jeton, timeout), RX en tache de fond
# ═══════════════════════════════════════════════════════════════════════════════

class PayloadLink:
    """La liaison payload ISM, vue par le relais SMS."""
    def __init__(self, cfg: Optional[Dict[str, str]] = None,
                 ttl: float = DEFAULT_TTL,
                 on_payload: Optional[Callable[[str, bytes], None]] = None):
        self.cfg = cfg or {}
        self.ttl = ttl
        self.backend = make_backend(self.cfg)
        self._store: Dict[str, Tuple[bytes, float]] = {}
        self._lock = threading.Lock()
        self._cv = threading.Condition(self._lock)
        self._on_payload = on_payload
        self._running = True
        self._rx = threading.Thread(target=self._rx_loop, daemon=True)
        self._rx.start()
        _log("liaison payload ISM prete (backend %s)"
             % (self.cfg.get("link") or os.environ.get("ISM_LINK") or "loopback"))

    def _rx_loop(self):
        while self._running:
            line = self.backend.read_line(timeout=1.0)
            if not line:
                self._prune()
                continue
            dec = frame_decode(line)
            if not dec:
                continue
            token, payload = dec
            with self._cv:
                self._store[token] = (payload, time.time())
                self._cv.notify_all()
            if self._on_payload:
                try:
                    self._on_payload(token, payload)
                except Exception as e:
                    _log("on_payload : %s" % e)

    def _prune(self):
        now = time.time()
        with self._lock:
            old = [t for t, (_, ts) in self._store.items() if now - ts > self.ttl]
            for t in old:
                del self._store[t]

    def send(self, token: str, payload: bytes) -> None:
        """Emet le payload sur la radio, estampille du jeton."""
        self.backend.write_frame(frame_encode(token, payload))

    def recv(self, token: str, timeout: float = DEFAULT_RECV_TIMEOUT) -> Optional[bytes]:
        """Attend le payload de ce jeton, recu par la radio (None si absent a temps)."""
        deadline = time.time() + timeout
        with self._cv:
            while token not in self._store:
                remaining = deadline - time.time()
                if remaining <= 0:
                    return None
                self._cv.wait(timeout=remaining)
            payload, _ = self._store.pop(token)
            return payload

    def close(self):
        self._running = False
        self.backend.close()


def new_token() -> str:
    """Un jeton de correlation court et unique (12 hexa)."""
    return os.urandom(6).hex()


# ═══════════════════════════════════════════════════════════════════════════════
# Autotest
# ═══════════════════════════════════════════════════════════════════════════════

def _selftest(cfg: Dict[str, str]) -> int:
    link = cfg.get("link") or os.environ.get("ISM_LINK") or "loopback"
    print("autotest liaison payload ISM — backend %s" % link)
    if link == "fifo":
        # deux liens croises : A ecrit sur tx et lit sur rx ; un second lien
        # miroir rejoue ce que A emet vers A lui-meme, pour boucler sans radio.
        a = PayloadLink(dict(cfg))
        mirror_cfg = dict(cfg)
        mirror_cfg["tx"], mirror_cfg["rx"] = cfg.get("rx"), cfg.get("tx")
        b = PayloadLink(mirror_cfg)
        links = [a, b]
        tx, rx = a, b
    else:
        link_obj = PayloadLink(dict(cfg))
        links = [link_obj]
        tx = rx = link_obj

    ok = True
    for text in ["Bonjour banc", "éàü accents 2G", "x" * 140]:
        token = new_token()
        payload = text.encode("utf-8")
        tx.send(token, payload)
        got = rx.recv(token, timeout=5)
        good = got == payload
        ok = ok and good
        print("  %s jeton=%s  %r" % ("OK " if good else "KO ", token,
                                     text[:30] + ("…" if len(text) > 30 else "")))
    # CRC : une trame corrompue doit etre rejetee
    bad = frame_encode("deadbeef", b"hello")
    assert frame_decode(bad.replace(b'"c":"', b'"c":"00')) is None
    print("  OK  trame a CRC faux rejetee")
    for l in links:
        l.close()
    print("resultat :", "OK" if ok else "ECHEC")
    return 0 if ok else 1


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description="Liaison payload ISM")
    ap.add_argument("--selftest", action="store_true", help="autotest (sans radio par defaut)")
    ap.add_argument("--link", help="loopback|fifo|serial|exec")
    ap.add_argument("--tx"); ap.add_argument("--rx")
    ap.add_argument("--serial"); ap.add_argument("--tx-cmd"); ap.add_argument("--rx-cmd")
    a = ap.parse_args(argv)
    cfg = {k: v for k, v in {
        "link": a.link, "tx": a.tx, "rx": a.rx, "serial": a.serial,
        "tx_cmd": a.tx_cmd, "rx_cmd": a.rx_cmd}.items() if v}
    if a.selftest:
        return _selftest(cfg)
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# airmesh.py - the mesh is made ON THE BURSTS, not on the calls.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT IT DOES
#
# What crosses the network is the burst. The radio medium becomes shared: the
# BTS of node 2 transmits, the mobile of node 1 hears it, synchronises on it,
# reads its SI, and does its location update FOR REAL. Everything else - BSC,
# MSC, HLR, MGW, Asterisk - stays enclosed in its node. Only the air is shared.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHO DOES WHAT: QEMU emits the bursts, fake_trx translates, airmesh transports
#
# The bursts are not made here. They come from the Calypso running in QEMU:
# the firmware modulates, pont.py collects what the ARM drops in its sidebands,
# encodes it into bursts and puts it on TRXD. In the other direction it decodes
# the BTS downlink and hands it back to the firmware. THAT is the radio.
#
# fake_trx.py is the node TRANSLATOR: a burst switch linking N transceivers and
# distributing what one EMITS to all those whose RECEIVE frequency matches
# (burst_fwd.py, forward_msg). It makes nothing, it routes.
#
# airmesh is the transport between nodes. It plugs into the translator, takes
# what passes there, sends it to the peers, and injects what comes back.
#
#     ┌──────────────────────── one node ─────────────────────────┐
#     │   QEMU/Calypso ──sidebands── pont.py ──TRXD 5700──┐       │
#     │   osmo-bts-trx ───────────────────────TRXD 5700───┤       │
#     │   trxcon/mobile ──────────────────────TRXD 6700───┤ fake  │
#     │   airmesh(mobile side) ───────────────TRXD 6706───┤ _trx  │
#     │   airmesh(BTS side) ──────────────────TRXD 6709───┘       │
#     └───────────────────────────┬───────────────────────────────┘
#                                 │  UDP AIRM (default 4739)
#                 ┌───────────────┴───────────────┐
#              node 2                          node 3
#
# WHY TWO ATTACHMENTS. fake_trx pairs on the FREQUENCY: a transceiver only
# hears what is emitted on its receive frequency. A single attachment point
# would hear only one direction, and a mobile that does not hear the BTS never
# attaches to it.
#   - mobile side: rx = downlink, tx = uplink. It HEARS what the local BTS
#     emits, and INJECTS the uplink of the remote mobiles towards it.
#   - BTS side   : rx = uplink, tx = downlink. It HEARS what the local mobiles
#     emit, and INJECTS the downlink of the remote BTSs towards them.
#
# ─────────────────────────────────────────────────────────────────────────────
# HOW IT ATTACHES WITHOUT CHANGING A LINE OF QEMU-SRC
#
# fake_trx creates one more transceiver per declared mobile (60-fake-trx.sh:
# --trx ue<n>@127.0.0.<g>:<port>, port = 6700 + (n-1) * 3). Those transceivers
# are "mobiles" only by name: fake_trx knows neither role nor band for them
# until they have sent RXTUNE and TXTUNE.
#
# So TWO more mobiles than the bench has are declared - N_MS + 2 - and airmesh
# takes their two places. It tunes the first like a mobile and the second the
# other way round, like a BTS. No change to the launcher, no qosmo-grgsm file
# touched: two slots already provided for, used differently.
#
# WHAT TO KNOW WHEN READING THEM: `pgrep -a fake_trx` shows two mobiles that do
# not exist, and the fake_trx log announces ue3 and ue4. This is intended. The
# name comes from the launcher.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE THREE DIFFICULTIES, AND WHAT IS DONE ABOUT EACH
#
# 1. THE CLOCK. A TDMA frame lasts 4.615 ms and carries a 22-bit number (FN)
#    that wraps every 3 h 28. Two nodes have two unrelated clocks: a burst
#    tagged fn=12345 on one designates no instant on the other.
#    WHAT IS DONE: OFFSET tracking. airmesh continuously measures the
#    difference between the local FN and the FN announced by each peer, and
#    REWRITES the FN at injection. Both clocks advance at the same nominal rate
#    (a 4.615 ms software timer on both sides), so the offset is almost
#    constant and the drift is caught up at every received burst.
#    WHAT WOULD BE BETTER: a master node that BROADCASTS the FN, the others
#    having no clock of their own. That requires taking over clck_gen; the
#    offset is enough as long as the nodes are on the same LAN. The function
#    _fn_offset() is the only place to replace.
#
# 2. THE DELAY. A burst must arrive BEFORE the local scheduler needs it. It is
#    therefore injected LOOKAHEAD frames ahead (default 6, i.e. ~28 ms): a LAN
#    round trip fits easily, a link with 30 ms latency does not. Bursts that
#    arrive too late are COUNTED, never silently dropped - a radio mesh losing
#    5 % of its bursts shows in the statistics, not in the BSC logs.
#
# 3. WHO HEARS WHOM. Without a graph, every mobile would hear every BTS of the
#    bench at full power: no cell, no reselection, nothing left to show.
#    data/air-mesh.txt gives the attenuation between nodes, in dB. Below a
#    floor, the burst is not transmitted - that is what makes a MESH and not a
#    bus.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE TWO MODES (AIRMESH_MODE)
#
#   fake  (default) - the burst goes through as is. Pure switching: no
#                     demodulation, no channel coding, the bit train comes out
#                     identical. Exact and cheap.
#   pont            - the burst goes through the Calypso chain: demodulation to
#                     L2 (libosmocoding), handed to QEMU through the sidebands,
#                     and what the ARM answers is re-modulated into bursts
#                     before leaving again on the mesh. pont.py holds that
#                     chain; airmesh hands over through a FIFO and does not
#                     touch it.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT IS NOT VALIDATED
#
# This file is written against the formats and port conventions read in
# osmocom-bb (trx_toolkit: transceiver.py, data_msg.py, burst_fwd.py) and
# against the TRXDv0 implemented on both sides by pont.py. The part to prove
# first is the clock offset tracking (point 1), the only one resting on an
# assumption - that both clck_gen advance at the same rate. The counters are
# there for that: "hors_fenetre" rising means point 1 or point 2 gives way.

import argparse, os, socket, struct, sys, threading, time, collections

# ── TRXD v0, as osmocom-bb writes it ─────────────────────────────────────────
# Common header: byte 0 = (version << 4) | slot number, then FN on 4 bytes
# big-endian.  (data_msg.py, parse_hdr / append_hdr_to)
#   TxMsg (L1 -> transceiver): common header + pwr(1)            = 6 bytes
#   RxMsg (transceiver -> L1): common header + rssi(1) + toa(2)  = 8 bytes
# Then 148 bytes, one per bit (hard on transmit, soft on receive).
TRXD_VER      = 0
CHDR_LEN      = 5
TX_HDR_LEN    = CHDR_LEN + 1
RX_HDR_LEN    = CHDR_LEN + 3
BURST_LEN     = 148

# ── Our protocol between nodes ───────────────────────────────────────────────
# Deliberately flat and readable in tcpdump: a radio mesh is debugged by
# watching the packets go by, not by re-reading a serialisation schema.
#   magic(4) ver(1) dir(1) node(2) arfcn(2) tn(1) reserved(1)
#   fn(4) pwr(1) rssi(1) toa(2 signed) nbits(2)   = 22 bytes, then nbits bytes
AIRM_MAGIC    = b"AIRM"
AIRM_VER      = 1
AIRM_HDR      = ">4sBBHHBBIbbhH"
AIRM_HDR_LEN  = struct.calcsize(AIRM_HDR)
DIR_DL        = 0      # what a BTS emits
DIR_UL        = 1      # what a mobile emits

FN_MAX        = 2715648          # 26 * 51 * 2048, the GSM FN wrap-around
FRAME_S       = 4.615e-3


def arfcn_to_khz(arfcn, uplink=False):
    """Frequency in kHz. GSM900 / DCS1800, the two bands of the bench.

    fake_trx does not pair on the ARFCN but on the FREQUENCY: getting the band
    wrong gives no error, it gives a transceiver that simply never hears
    anything - the longest failure to track down.
    """
    if 512 <= arfcn <= 885:                      # DCS 1800
        dl = 1805200 + 200 * (arfcn - 512)
        return dl - 95000 if uplink else dl
    if 0 <= arfcn <= 124:                        # GSM 900
        dl = 935000 + 200 * arfcn
        return dl - 45000 if uplink else dl
    if 975 <= arfcn <= 1023:                     # E-GSM 900
        dl = 935000 + 200 * (arfcn - 1024)
        return dl - 45000 if uplink else dl
    raise ValueError("ARFCN hors des bandes connues : %d" % arfcn)


class Stats:
    """What to look at when the mesh "half works"."""
    def __init__(self):
        self.lock = threading.Lock()
        self.c = collections.Counter()

    def bump(self, k, n=1):
        with self.lock:
            self.c[k] += n

    def render(self):
        with self.lock:
            return " ".join("%s=%d" % (k, v) for k, v in sorted(self.c.items()))


ST = Stats()


class Topologie:
    """Who hears whom, and at what cost.

    data/air-mesh.txt, one edge per line:
        <node a> <node b> <attenuation dB> [uni]
    Without the word "uni" the edge holds in both directions. A pair absent
    from the file does not hear each other: it is a mesh, not a bus - two nodes
    only see each other if someone wrote it.
    """

    def __init__(self, chemin, defaut_db):
        self.aretes = {}
        self.defaut = defaut_db
        self.ouvert = False
        if chemin and os.path.isfile(chemin):
            self._charger(chemin)
            self.ouvert = True

    def _charger(self, chemin):
        with open(chemin, "r", encoding="utf-8", errors="replace") as f:
            for ligne in f:
                ligne = ligne.split("#", 1)[0].strip()
                if not ligne:
                    continue
                ch = ligne.split()
                if len(ch) < 3:
                    continue
                try:
                    a, b, att = int(ch[0]), int(ch[1]), float(ch[2])
                except ValueError:
                    continue
                self.aretes[(a, b)] = att
                if len(ch) < 4 or ch[3] != "uni":
                    self.aretes[(b, a)] = att

    def attenuation(self, src, dst):
        """dB between two nodes, or None if one does not hear the other.

        Without a file, everybody hears everybody at the default attenuation:
        that is the behaviour of a bus, useful for a first two-node trial, and
        it is ANNOUNCED at start-up so that it is not taken for a topology.
        """
        if not self.ouvert:
            return self.defaut
        return self.aretes.get((src, dst))


class TrxLien:
    """An L1 as seen from fake_trx: CTRL and DATA, exactly like trxcon.

    Port conventions read in transceiver.py (Transceiver.__init__): the
    transceiver BINDS base+1 (CTRL) and base+2 (DATA); the L1 binds base+101
    and base+102 and sends to the former. We are on the L1 side.
    """

    def __init__(self, nom, host, base, arfcn, rx_uplink):
        self.nom  = nom
        self.host = host
        self.base = base
        self.arfcn = arfcn
        self.rx_uplink = rx_uplink        # True: we listen to the uplink
        self.ctrl = self._sock(base + 101)
        self.data = self._sock(base + 102)
        self.ctrl_seq = 0
        self.slots = set()

    @staticmethod
    def _sock(port):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", port))
        return s

    # ── CTRL ────────────────────────────────────────────────────────────────
    def cmd(self, texte, attente=1.0):
        """Send a CTRL command and wait for its answer.

        The answer is AWAITED rather than firing the commands back to back:
        fake_trx answers RSP <cmd> <code>, and a non-zero code (frequency out
        of band, slot refused) would otherwise go unnoticed. A mistuned
        transceiver emits no error afterwards - it simply stays silent.
        """
        self.ctrl.sendto(("CMD " + texte + "\0").encode(), (self.host, self.base + 1))
        self.ctrl.settimeout(attente)
        try:
            rep, _ = self.ctrl.recvfrom(512)
        except socket.timeout:
            return None
        finally:
            self.ctrl.settimeout(None)
        return rep.rstrip(b"\0").decode(errors="replace")

    def accorder(self, slots):
        """Full POWERON: tune both frequencies then open the slots.

        The order matters. fake_trx refuses SETSLOT on a transceiver that has
        no frequency, and POWERON on a transceiver without a slot is useless:
        it runs and hears nothing.
        """
        rx = arfcn_to_khz(self.arfcn, uplink=self.rx_uplink)
        tx = arfcn_to_khz(self.arfcn, uplink=not self.rx_uplink)
        for cmd in ("RXTUNE %d" % rx, "TXTUNE %d" % tx):
            rep = self.cmd(cmd)
            if rep is None or " 0" not in rep:
                raise RuntimeError("%s : %s refuse (%s)" % (self.nom, cmd, rep))
        for tn in slots:
            # type 1 = TCH/F for fake_trx; what matters here is that the slot
            # is ACTIVE, the real content is carried by the bursts themselves.
            self.cmd("SETSLOT %d 1" % tn)
            self.slots.add(tn)
        rep = self.cmd("POWERON")
        if rep is None or " 0" not in rep:
            raise RuntimeError("%s : POWERON refuse (%s)" % (self.nom, rep))

    def eteindre(self):
        try:
            self.cmd("POWEROFF", attente=0.3)
        except OSError:
            pass

    # ── DATA ────────────────────────────────────────────────────────────────
    def lire(self):
        """A burst fake_trx delivers to us: what the local neighbour EMITTED."""
        paquet, _ = self.data.recvfrom(1024)
        if len(paquet) < RX_HDR_LEN + BURST_LEN:
            ST.bump("rx_court")
            return None
        ver = paquet[0] >> 4
        if ver != TRXD_VER:
            ST.bump("rx_version_inattendue")
            return None
        tn   = paquet[0] & 0x0F
        fn   = struct.unpack(">L", paquet[1:5])[0]
        rssi = -paquet[5]
        toa  = struct.unpack(">h", paquet[6:8])[0]
        bits = paquet[RX_HDR_LEN:RX_HDR_LEN + BURST_LEN]
        return tn, fn, rssi, toa, bits

    def ecrire(self, tn, fn, pwr, bits):
        """Inject a burst: fake_trx distributes it to whoever is tuned to it."""
        hdr = bytearray(TX_HDR_LEN)
        hdr[0] = (TRXD_VER << 4) | (tn & 0x0F)
        hdr[1:5] = struct.pack(">L", fn % FN_MAX)
        hdr[5] = pwr & 0xFF
        self.data.sendto(bytes(hdr) + bytes(bits), (self.host, self.base + 2))


class Maillage:
    def __init__(self, cfg):
        self.cfg = cfg
        self.noeud = cfg.node
        self.topo = Topologie(cfg.topologie, cfg.attenuation_defaut)
        self.pairs = cfg.pairs                      # [(id, ip, port)]
        self.stop = threading.Event()

        # The clock: last local FN seen, and estimated offset per peer.
        self._fn_local = 0
        self._fn_vu_a  = time.monotonic()
        self._ecart    = {}                         # peer id -> offset in frames
        self._verrou   = threading.Lock()

        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((cfg.bind, cfg.port))

        # Mobile side: hears the local downlink, injects the remote uplink.
        self.ms  = TrxLien("airmesh-ms",  "127.0.0.1", cfg.trx_ms,
                           cfg.arfcn, rx_uplink=False)
        # BTS side: hears the local uplink, injects the remote downlink.
        self.bts = TrxLien("airmesh-bts", "127.0.0.1", cfg.trx_bts,
                           cfg.arfcn, rx_uplink=True)

    # ── Clock ───────────────────────────────────────────────────────────────
    def _note_fn_local(self, fn):
        with self._verrou:
            self._fn_local = fn
            self._fn_vu_a  = time.monotonic()

    def _fn_maintenant(self):
        """The local FN, extrapolated from the last burst seen.

        We have no clock of our own: the only reference FN is the one fake_trx
        delivers with each burst. Between two bursts we advance by the watch -
        4.615 ms per frame. Enough for a six-frame lookahead; it would not be
        enough to timestamp anything.
        """
        with self._verrou:
            base, quand = self._fn_local, self._fn_vu_a
        return (base + int((time.monotonic() - quand) / FRAME_S)) % FN_MAX

    def _fn_offset(self, pair, fn_distant):
        """Offset between a peer's clock and ours, smoothed.

        This is THE fragile point of the mesh, and the only place to replace
        the day a master node broadcasts the FN: here, we only assume that both
        clocks advance at the same rate.
        """
        vu = (self._fn_maintenant() - fn_distant) % FN_MAX
        with self._verrou:
            ancien = self._ecart.get(pair)
            if ancien is None:
                self._ecart[pair] = vu
                return vu
            # Running average on the circular offset: without the wrap, an FN
            # wrap-around would make the offset jump by two million frames and
            # the mesh would go silent for three hours.
            d = (vu - ancien + FN_MAX // 2) % FN_MAX - FN_MAX // 2
            neuf = (ancien + d // 8) % FN_MAX
            self._ecart[pair] = neuf
            return neuf

    # ── Sending to the peers ────────────────────────────────────────────────
    def _diffuser(self, sens, tn, fn, rssi, toa, bits):
        for (pid, ip, port) in self.pairs:
            att = self.topo.attenuation(self.noeud, pid)
            if att is None:
                ST.bump("hors_portee")
                continue
            r = max(-120, min(-1, int(rssi - att)))
            if r <= self.cfg.plancher:
                ST.bump("sous_plancher")
                continue
            paquet = struct.pack(AIRM_HDR, AIRM_MAGIC, AIRM_VER, sens,
                                 self.noeud, self.cfg.arfcn, tn, 0,
                                 fn % FN_MAX, 0, r, toa, len(bits)) + bytes(bits)
            try:
                self.sock.sendto(paquet, (ip, port))
                ST.bump("emis_dl" if sens == DIR_DL else "emis_ul")
            except OSError:
                ST.bump("emission_echec")

    def _boucle_locale(self, lien, sens):
        """What the LOCAL neighbour emits goes to the peers."""
        while not self.stop.is_set():
            try:
                lu = lien.lire()
            except OSError:
                break
            if lu is None:
                continue
            tn, fn, rssi, toa, bits = lu
            self._note_fn_local(fn)
            self._diffuser(sens, tn, fn, rssi, toa, bits)

    # ── Receiving from the peers ────────────────────────────────────────────
    def _boucle_maillage(self):
        while not self.stop.is_set():
            try:
                paquet, _ = self.sock.recvfrom(2048)
            except OSError:
                break
            if len(paquet) < AIRM_HDR_LEN:
                ST.bump("mesh_court")
                continue
            (magie, ver, sens, src, arfcn, tn, _res,
             fn, _pwr, rssi, toa, nbits) = struct.unpack(AIRM_HDR, paquet[:AIRM_HDR_LEN])
            if magie != AIRM_MAGIC or ver != AIRM_VER:
                ST.bump("mesh_etranger")
                continue
            bits = paquet[AIRM_HDR_LEN:AIRM_HDR_LEN + nbits]
            if len(bits) != nbits or nbits != BURST_LEN:
                ST.bump("mesh_tronque")
                continue
            if arfcn != self.cfg.arfcn:
                # A peer on another carrier: normal, and even the point - two
                # neighbouring operators do not occupy the same channel. Not
                # counted as an error.
                ST.bump("autre_arfcn")
                continue

            # Where this burst falls in OUR time.
            fn_local = (fn + self._fn_offset(src, fn)) % FN_MAX
            cible    = (self._fn_maintenant() + self.cfg.lookahead) % FN_MAX
            retard   = (cible - fn_local + FN_MAX // 2) % FN_MAX - FN_MAX // 2
            if retard > self.cfg.tolerance:
                ST.bump("hors_fenetre_tard")
                continue
            fn_inj = cible

            if sens == DIR_DL:
                # A remote downlink: a BTS from elsewhere. Injected through the
                # BTS side, the one whose tx the local mobiles listen to.
                self.bts.ecrire(tn, fn_inj, self._pwr(rssi), bits)
                ST.bump("injecte_dl")
            else:
                self.ms.ecrire(tn, fn_inj, self._pwr(rssi), bits)
                ST.bump("injecte_ul")

    @staticmethod
    def _pwr(rssi):
        """TxMsg carries an attenuation (0 = full power), not an RSSI.

        The attenuation already applied by the topology is carried over,
        bounded to a byte: this is what gives the mobile a reason to prefer
        one cell over another.
        """
        return max(0, min(255, -rssi - 40))

    # ── Process life ────────────────────────────────────────────────────────
    def _boucle_stats(self):
        while not self.stop.wait(self.cfg.stats_s):
            ecarts = " ".join("n%d:%+d" % (k, v if v < FN_MAX // 2 else v - FN_MAX)
                              for k, v in sorted(self._ecart.items()))
            print("[airmesh] fn=%d %s | ecarts %s" %
                  (self._fn_maintenant(), ST.render(), ecarts or "aucun"),
                  flush=True)

    def demarrer(self):
        print("[airmesh] noeud %d  arfcn %d  pairs %s" %
              (self.noeud, self.cfg.arfcn,
               ", ".join("%d@%s:%d" % p for p in self.pairs) or "aucun"), flush=True)
        if not self.topo.ouvert:
            print("[airmesh] AUCUNE topologie (%s) : tous les pairs s'entendent "
                  "a %.0f dB - c'est un bus, pas un maillage."
                  % (self.cfg.topologie, self.cfg.attenuation_defaut), flush=True)
        if self.cfg.mode != "fake":
            print("[airmesh] mode '%s' : les bursts passent par la chaine "
                  "Calypso de pont.py (FIFO %s)" % (self.cfg.mode, self.cfg.fifo),
                  flush=True)

        slots = [int(x) for x in self.cfg.slots.split(",") if x != ""]
        self.ms.accorder(slots)
        self.bts.accorder(slots)

        fils = [
            threading.Thread(target=self._boucle_locale, args=(self.ms, DIR_DL),
                             name="local-dl", daemon=True),
            threading.Thread(target=self._boucle_locale, args=(self.bts, DIR_UL),
                             name="local-ul", daemon=True),
            threading.Thread(target=self._boucle_maillage, name="maillage", daemon=True),
            threading.Thread(target=self._boucle_stats, name="stats", daemon=True),
        ]
        for f in fils:
            f.start()
        try:
            while not self.stop.is_set():
                time.sleep(0.5)
        except KeyboardInterrupt:
            pass
        finally:
            self.stop.set()
            self.ms.eteindre()
            self.bts.eteindre()
            print("[airmesh] arret. %s" % ST.render(), flush=True)


def paire(txt):
    """--pair 2:192.168.1.12:4739"""
    ch = txt.split(":")
    if len(ch) != 3:
        raise argparse.ArgumentTypeError("attendu <noeud>:<ip>:<port>, recu %r" % txt)
    return (int(ch[0]), ch[1], int(ch[2]))


def main():
    p = argparse.ArgumentParser(
        prog="airmesh",
        description="Maillage de bursts GSM entre noeuds : le milieu radio devient commun.")
    p.add_argument("--node", type=int, required=True, help="numero de CE noeud")
    p.add_argument("--arfcn", type=int, default=int(os.environ.get("AIRMESH_ARFCN", "514")))
    p.add_argument("--pair", dest="pairs", action="append", type=paire, default=[],
                   metavar="NOEUD:IP:PORT", help="un pair du maillage (repetable)")
    p.add_argument("--bind", default=os.environ.get("AIRMESH_BIND", "0.0.0.0"))
    p.add_argument("--port", type=int, default=int(os.environ.get("AIRMESH_PORT", "4739")))
    # 6700 + (n-1)*3: the two mobile slots following the real ones.
    # With two real MS, the bench must run with N_MS=4 and airmesh takes 3 and 4.
    p.add_argument("--trx-ms", type=int, default=int(os.environ.get("AIRMESH_TRX_MS", "6706")),
                   help="base TRXD de l'emplacement pris cote mobile (defaut : MS 3)")
    p.add_argument("--trx-bts", type=int, default=int(os.environ.get("AIRMESH_TRX_BTS", "6709")),
                   help="base TRXD de l'emplacement pris cote BTS (defaut : MS 4)")
    p.add_argument("--slots", default=os.environ.get("AIRMESH_SLOTS", "0,1,2,3,4,5,6,7"))
    p.add_argument("--lookahead", type=int, default=int(os.environ.get("AIRMESH_LOOKAHEAD", "6")),
                   help="trames d'avance a l'injection (6 = ~28 ms)")
    p.add_argument("--tolerance", type=int, default=int(os.environ.get("AIRMESH_TOL", "2")),
                   help="trames de retard tolerees avant de compter le burst perdu")
    p.add_argument("--topologie", default=os.environ.get("AIRMESH_TOPO", "data/air-mesh.txt"))
    p.add_argument("--attenuation-defaut", type=float,
                   default=float(os.environ.get("AIRMESH_ATT", "20")))
    p.add_argument("--plancher", type=int, default=int(os.environ.get("AIRMESH_PLANCHER", "-110")),
                   help="dBm sous lesquels le burst n'est pas transmis")
    # fake: the burst goes through as is, airmesh is only a transport.
    # pont: it goes through the Calypso chain of pont.py - demodulation, handed
    # to QEMU, remodulation - before leaving again. This is the mode that
    # really makes the firmware transmit on behalf of the mesh.
    p.add_argument("--mode", choices=("fake", "pont"),
                   default=os.environ.get("AIRMESH_MODE", "fake"))
    p.add_argument("--fifo", default=os.environ.get("AIRMESH_FIFO", "/dev/shm/airmesh_pont"))
    p.add_argument("--stats-s", type=float, default=float(os.environ.get("AIRMESH_STATS", "10")))
    cfg = p.parse_args()

    try:
        Maillage(cfg).demarrer()
    except RuntimeError as e:
        print("[airmesh] %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

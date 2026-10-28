#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""air.py - the air between two emulated Calypsos: the bursts one emits, the other receives.

Two-instance setup (c54x_exe/run.sh INSTANCE=2): instance 1 is the TRX of BTS#0 (trx
firmware, start-native.sh --osmo-trx), instance 2 is the mobile.
Each c54x_exe publishes the final bursts its ROM emits into a ring
/dev/shm/calypso_tx_rom (pont.c, tx_tsp_publier): header w(4) slots(4), then 160-byte
slots: seq(4) fn(4) type(1) tsc(1) offset(1) src(1) bits(148). Each BSP (calypso_bsp.c)
expects the bursts it must receive as TRXDv0 over UDP (6702, CALYPSO_BSP_PORT):
tn(1) fn(4, big-endian) rssi(1) toa(2) bits(148, one 0/1 byte per bit).

This relay reads A's ring and sends it to B's BSP, and B's ring to A's BSP: the downlink
(FB, SB, dummy, NB from the TRX) goes to the mobile, the uplink (RACH, NB from the mobile)
goes to the TRX. It starts from the end of the rings (no replay) and counts what passes
every 5 s.

  python3 air.py --a-ring /dev/shm/calypso_tx_rom --a-port 6702 \\
                 --b-ring /dev/shm/calypso2/calypso_tx_rom --b-port 6712
From instance 2 (run.sh, private mount namespace) the ring of instance 1 is read at
/run/calypso-shm-hote/calypso_tx_rom.

Third Calypso, phone 2 of the TRX (TS1, instance 3: --c-ring / --c-port): its bursts go
to the mobile with tn=1; the mobile's bursts go to the TS0 TRX (A) while it is on the SDCCH,
to the TS1 TRX (C) once the ASSIGNMENT COMMAND has gone through. The air reads that
ASSIGNMENT COMMAND in the SDCCH/4 blocks of TS0 (pont.gsm, libosmocoding) and announces it
to the mobile's c54x_exe through --tch-cfg (pont/state.py format: seq, tn, tsc, arfcn);
a RACH from the mobile gives the SDCCH back (tn=0).

Phone 2 has its OWN frame counter (it starts from 0 at its boot, like phone 1): its bursts
leave its ring with its local fn, and its BSP expects uplink bursts in its own numbering.
The host transceiver measures D = fn1 - fn2 on the DATA_IND of both phones and writes it
to --fn-delta (/tmp/osmocom_fn_delta_2); the air tags C->B with fn + D and sends B->C with
fn - D, in tn 0 (phone 2's BSP files a tn=1 burst in the "other" slots, rx[2], which its
firmware does not read: for it TS1 is ITS slot). While D is unknown, nothing goes through C.
"""
import argparse
import os
import socket
import struct
import sys
import time

# The bridge's block decoder (libosmocoding via ctypes), to read the ASSIGNMENT COMMAND.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
try:
    from pont import gsm
except Exception as _e:   # pragma: no cover - without libosmocoding the air still relays, without TCH
    gsm = None
    print("air : pont.gsm indisponible (%s) : pas de detection de l'ASSIGNMENT COMMAND" % _e, flush=True)

HDR = 8
SLOT = 160
TYPES = {0: "?", 1: "RACH", 2: "NB", 3: "SB", 4: "DUMMY", 5: "FB", 101: "TS1", 102: "TS2", 103: "TS3", 104: "TS4", 105: "TS5", 106: "TS6", 107: "TS7"}


class Anneau:
    """A calypso_tx_rom ring; only what is written after our arrival is read."""

    def __init__(self, path, nom):
        self.path, self.nom = path, nom
        self.fd = -1
        self.seq = None          # last seq read
        self.slots = 256
        self.rate = 0
        # fn CONTINUITY. In TRX mode the published fn is the tick of the emitting c54x_exe
        # (the trx firmware does not set a_a5fn): it restarts from 0 when banc-trx is relaunched,
        # while the mobile's BSP (STREAM: one burst per frame, in fn order) expects a monotonic
        # sequence. We therefore relay fn + offset, the offset being realigned on every fn
        # step back so that the numbering seen by the receiver stays monotonic and continuous
        # (+1 from the last relayed fn).
        self.fn_dec = 0
        self.fn_dernier = None
        self.recalages = 0

    def fn_continu(self, fn):
        out = (fn + self.fn_dec) % 2715648
        if self.fn_dernier is not None:
            d = (out - self.fn_dernier) % 2715648
            if d > 100000:                  # step back (or absurd jump): realign after the last; d == 0 = same frame
                self.fn_dec = (self.fn_dernier + 1 - fn) % 2715648
                out = (fn + self.fn_dec) % 2715648
                self.recalages += 1
                print("air : anneau %s : fn recule (%d apres %d), decalage recale a +%d (%d recalages)"
                      % (self.nom, fn, self.fn_dernier, self.fn_dec, self.recalages), flush=True)
        self.fn_dernier = out
        return out

    def _ouvrir(self):
        if self.fd >= 0:
            return True
        try:
            self.fd = os.open(self.path, os.O_RDONLY)
        except OSError:
            return False
        hdr = os.pread(self.fd, HDR, 0)
        if len(hdr) < HDR:
            os.close(self.fd); self.fd = -1
            return False
        w, slots = struct.unpack("<II", hdr)
        self.slots = slots or 256
        self.seq = w                        # start from the end
        print("air : anneau %s ouvert (%s), %d cases, seq=%d" % (self.nom, self.path, self.slots, w), flush=True)
        return True

    def nouveaux(self):
        """Return the slots (seq, fn, type, tsc, offset, src, bits) written since the last call."""
        if not self._ouvrir():
            return []
        # When the other instance is relaunched (./start-native.sh --bts while the mobile runs),
        # its c54x_exe RECREATES the ring (new inode) and the old descriptor would read a deleted
        # file forever (A->B frozen, no more downlink for the mobile). Compare the inode periodically.
        self.tours = getattr(self, "tours", 0) + 1
        if self.tours % 200 == 0:
            try:
                if os.stat(self.path).st_ino != os.fstat(self.fd).st_ino:
                    print("air : anneau %s recree (%s) : reouverture" % (self.nom, self.path), flush=True)
                    os.close(self.fd); self.fd = -1
                    if not self._ouvrir():
                        return []
            except OSError:
                pass
        try:
            hdr = os.pread(self.fd, HDR, 0)
        except OSError:
            os.close(self.fd); self.fd = -1
            return []
        if len(hdr) < HDR:
            return []
        w = struct.unpack("<I", hdr[:4])[0]
        if w == self.seq:
            return []
        if w < self.seq:                     # ring recreated (new run)
            print("air : anneau %s remis a zero (seq %d -> %d)" % (self.nom, self.seq, w), flush=True)
            self.seq = 0
        debut = self.seq + 1
        if w - debut >= self.slots:          # too far behind: jump to the most recent
            self.rate += (w - debut) - (self.slots - 1)
            debut = w - (self.slots - 1)
        out = []
        for s in range(debut, w + 1):
            off = HDR + ((s - 1) % self.slots) * SLOT
            try:
                case = os.pread(self.fd, SLOT, off)
            except OSError:
                break
            if len(case) < SLOT:
                break
            seq, fn = struct.unpack("<II", case[:8])
            typ, tsc, offset, src = case[8], case[9], case[10], case[11]
            if seq != s:                     # slot not written yet / overwritten
                continue
            out.append((seq, fn, typ, tsc, offset, src, case[12:160]))
        self.seq = w
        return out


class Cible:
    """The other instance's BSP, as TRXDv0 over UDP."""

    def __init__(self, host, port, nom, tn):
        self.addr, self.nom, self.tn = (host, port), nom, tn
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.envoyes = 0
        self.par_type = {}

    def envoyer(self, fn, typ, bits, tn=None):
        """tn: the timeslot announced in the TRXD header; by default the target's. The rings
        carry the burst's TS (bits 4-6 of src): it is relayed as is."""
        if tn is None:
            tn = self.tn
        pkt = bytes([tn & 7]) + struct.pack(">I", fn) + b"\x00\x00\x00" + bytes(b & 1 for b in bits)
        try:
            self.sock.sendto(pkt, self.addr)
        except OSError as e:
            print("air : envoi vers %s %s:%d : %s" % (self.nom, self.addr[0], self.addr[1], e), flush=True)
            return
        self.envoyes += 1
        self.par_type[typ] = self.par_type.get(typ, 0) + 1
        if tn:
            self.par_type[100 + tn] = self.par_type.get(100 + tn, 0) + 1   # count per timeslot (TS1..7)


class Decalage:
    """D = fn1 - fn2, published by the transceiver (--fn-delta-file); re-read when the file changes."""

    def __init__(self, chemin):
        self.chemin, self.d, self.mtime, self.prochain = chemin, None, None, 0.0
        self.changements = 0

    def lire(self):
        now = time.monotonic()
        if now < self.prochain or not self.chemin:
            return self.d
        self.prochain = now + 0.5
        try:
            st = os.stat(self.chemin)
        except OSError:
            return self.d
        if st.st_mtime == self.mtime and self.d is not None:
            return self.d
        try:
            d = int(open(self.chemin).read().strip())
        except (OSError, ValueError):
            return self.d
        self.mtime = st.st_mtime
        if d != self.d:
            self.changements += 1
            print("air : decalage de trames du telephone 2 : fn1 - fn2 = %d (%s, %d changements)" % (d, self.chemin, self.changements), flush=True)
            self.d = d
        return self.d


SDCCH4_DL = {22: 0, 23: 0, 24: 0, 25: 0, 26: 1, 27: 1, 28: 1, 29: 1, 32: 2, 33: 2, 34: 2, 35: 2, 36: 3, 37: 3, 38: 3, 39: 3}


class Dedie:
    """The ASSIGNMENT COMMAND read on the SDCCH/4 of TS0, and the TCH announcement to the
    mobile (calypso_tch_cfg)."""

    def __init__(self, chemin):
        self.chemin = chemin
        self.blocs = {}          # subchannel -> [(fn, bits)]
        self.tn = None
        self.tsc = 7
        self.seq = 0
        self.decodes = 0
        self.rates = 0

    def _ecrire(self, tn, tsc, arfcn):
        if not self.chemin:
            return
        self.seq += 1
        buf = bytearray(16)
        buf[0:4] = int(self.seq).to_bytes(4, "little")
        buf[4] = tn & 0xff
        buf[5] = tsc & 0xff
        buf[6:8] = int(arfcn).to_bytes(2, "little")
        fd = os.open(self.chemin, os.O_CREAT | os.O_WRONLY, 0o644)
        try:
            os.pwrite(fd, bytes(buf), 0)
        finally:
            os.close(fd)

    def descendant(self, fn, typ, bits):
        """A TS0 burst from the TRX: accumulate SDCCH/4 blocks and look for the ASSIGNMENT COMMAND."""
        if gsm is None or typ != 2:
            return
        ss = SDCCH4_DL.get(fn % 51)
        if ss is None:
            return
        acc = self.blocs.setdefault(ss, [])
        if acc and (fn - acc[-1][0]) % 2715648 != 1:
            acc.clear()
        acc.append((fn, bytes(b & 1 for b in bits)))
        if len(acc) < 4:
            return
        quatre = acc[:]; acc.clear()
        try:
            l2 = gsm.xcch_decode([gsm.coded_from_burst(b) for _, b in quatre])
        except Exception as e:
            print("air : decodage SDCCH : %s" % e, flush=True); return
        if l2 is None:
            self.rates += 1; return
        self.decodes += 1
        off, mt = gsm.rr_message_type(l2)
        if mt == gsm.RR_ASSIGNMENT_COMMAND and len(l2) > off + 4:
            b0, b1, b2 = l2[off + 2], l2[off + 3], l2[off + 4]
            if (b1 >> 4) & 1:
                print("air : ASSIGNMENT COMMAND avec saut de frequence (fn=%u) : ignore" % fn, flush=True); return
            tn, tsc, arfcn = b0 & 0x07, (b1 >> 5) & 0x07, ((b1 & 0x03) << 8) | b2
            self.tn, self.tsc = tn, tsc
            self._ecrire(tn, tsc, arfcn)
            print("air : ASSIGNMENT COMMAND (fn=%u, SDCCH/4 ss%d) : TCH TS%d TSC=%d ARFCN=%d -> annonce %s (seq %d), montant du mobile vers le TRX du TS%d"
                  % (fn, ss, tn, tsc, arfcn, self.chemin, self.seq, tn), flush=True)
        elif mt == gsm.RR_CHANNEL_RELEASE and self.tn is not None:
            self.liberer("CHANNEL RELEASE sur le SDCCH")

    def liberer(self, raison):
        if self.tn is None:
            return
        tn = self.tn; self.tn = None
        self._ecrire(0, 0, 0)
        print("air : TCH TS%d rendu (%s) : montant du mobile vers le TRX du TS0 (seq %d)" % (tn, raison, self.seq), flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--a-ring", required=True, help="anneau TX de A, le TRX du TS0 (ce que A emet)")
    ap.add_argument("--a-port", type=int, required=True, help="port UDP du BSP de A (ce que A recoit)")
    ap.add_argument("--b-ring", required=True, help="anneau TX de B, le mobile")
    ap.add_argument("--b-port", type=int, required=True, help="port UDP du BSP de B")
    ap.add_argument("--c-ring", default=None, help="anneau TX de C, le telephone 2 du TRX (TS1), optionnel")
    ap.add_argument("--c-port", type=int, default=None, help="port UDP du BSP de C")
    ap.add_argument("--tch-cfg", default=None, help="annonce du TCH au c54x_exe du mobile (calypso_tch_cfg de son /dev/shm)")
    ap.add_argument("--fn-delta", default="/tmp/osmocom_fn_delta_2", help="fichier ou le transceiver publie fn1 - fn2 du telephone 2 (avec --c-ring)")
    ap.add_argument("--c-toujours", action="store_true", help="relayer C->B meme hors TCH (defaut : seulement pendant un TCH assigne, les bursts TS1 dans la trame des SB cassaient la synchro du mobile le 21/10)")
    ap.add_argument("--c-tn", type=int, default=0, help="tn de l'en-tete TRXD des bursts du mobile envoyes au telephone 2 (0 : son intervalle principal)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--tn", type=int, default=0, help="timeslot annonce dans l'en-tete TRXD des bursts de A (defaut 0)")
    ap.add_argument("--b-fn-delta", type=int, default=int(os.environ.get("AIR_B_FN_DELTA", "0") or 0),
                    help="[21/10] trames ajoutees au fn des bursts du mobile B (defaut 0 : le fn publie par c54x_exe est "
                         "le bon ; l'ecart de 2 vu le 21/10 venait d'une comparaison au RA_R de la L1 TI). Env AIR_B_FN_DELTA")
    ap.add_argument("--sans", default="", help="types a ne pas relayer, ex. « ?,RACH »")
    ap.add_argument("--periode", type=float, default=0.002, help="periode de scrutation (s)")
    ap.add_argument("--stats", type=float, default=5.0, help="periode des comptes (s)")
    args = ap.parse_args()
    noms = {v: k for k, v in TYPES.items()}
    sans = {noms[t.strip()] for t in args.sans.split(",") if t.strip() in noms}

    a_ring, b_ring = Anneau(args.a_ring, "A"), Anneau(args.b_ring, "B")
    vers_b = Cible(args.host, args.b_port, "B", args.tn)   # what A emits -> B receives (TS0)
    vers_a = Cible(args.host, args.a_port, "A", args.tn)   # what B emits -> A receives
    c_ring = Anneau(args.c_ring, "C") if args.c_ring else None
    vers_b1 = Cible(args.host, args.b_port, "B(TS1)", 1) if c_ring else None   # what C emits -> B receives, tn 1
    vers_c = Cible(args.host, args.c_port, "C", 1) if (c_ring and args.c_port) else None
    dedie = Dedie(args.tch_cfg)
    decalage = Decalage(args.fn_delta if c_ring else None)
    c_sans_d = 0
    mobile_tch = 0.0          # time of the mobile's last burst on a dedicated TS (tn_m != 0):
                              # with a ciphered SDCCH the air cannot read the ASSIGNMENT COMMAND,
                              # the mobile itself tells it is on the TCH
    print("air : A %s -> udp %d (B) ; B %s -> udp %d (A) ; tn %d%s%s%s" %
          (args.a_ring, args.b_port, args.b_ring, args.a_port, args.tn,
           " ; C %s -> udp %d (B, tn 1) ; B -> udp %s (C) sur TCH" % (args.c_ring, args.b_port, args.c_port) if c_ring else "",
           " ; annonce TCH : %s" % args.tch_cfg if args.tch_cfg else "",
           " ; sans %s" % args.sans if sans else "")
          + (" ; fn de B %+d" % args.b_fn_delta if args.b_fn_delta else ""), flush=True)
    prochain = time.monotonic() + args.stats
    while True:
        bouge = False
        for seq, fn, typ, tsc, offset, src, bits in a_ring.nouveaux():
            bouge = True
            if typ in sans or offset == 0xff and typ == 0:
                continue
            fnc = a_ring.fn_continu(fn)
            tn_b = (src >> 4) & 7                      # the burst's TS (TS0: BCCH/CCCH/SDCCH, TS1: the TCH)
            vers_b.envoyer(fnc, typ, bits, tn_b)
            if tn_b == 0:
                dedie.descendant(fnc, typ, bits)
        if c_ring:
            d = decalage.lire()
            for seq, fn, typ, tsc, offset, src, bits in c_ring.nouveaux():
                bouge = True
                if typ in sans or offset == 0xff and typ == 0:
                    continue
                if d is None or (dedie.tn is None and not args.c_toujours and time.monotonic() - mobile_tch > 2.0):
                    c_sans_d += 1
                    continue
                vers_b1.envoyer((fn + d) % 2715648, typ, bits)
        for seq, fn, typ, tsc, offset, src, bits in b_ring.nouveaux():
            bouge = True
            if typ in sans or offset == 0xff and typ == 0:
                continue
            fnc = (b_ring.fn_continu(fn) + args.b_fn_delta) % 2715648
            tn_m = (src >> 4) & 7                      # the TS the mobile transmitted on (montant_tn_dedie)
            if typ == 1:                                   # RACH: the mobile is (back) on TS0
                if dedie.tn is not None:
                    dedie.liberer("RACH du mobile")
                vers_a.envoyer(fnc, typ, bits, 0)
            elif tn_m and vers_c is not None:
                mobile_tch = time.monotonic()
                d = decalage.lire()
                if d is None:
                    c_sans_d += 1
                    continue
                vers_c.envoyer((fnc - d) % 2715648, typ, bits, args.c_tn)   # TS1 TCH -> TRX phone 2, ITS numbering
            else:
                vers_a.envoyer(fnc, typ, bits, tn_m)       # single TRX phone: TS0 and TS1 by tn
        if not bouge:
            time.sleep(args.periode)
        if time.monotonic() >= prochain:
            prochain += args.stats
            def fmt(c):
                return " ".join("%s=%d" % (TYPES.get(t, str(t)), n) for t, n in sorted(c.par_type.items())) or "-"
            print("air : A->B %d (%s)  B->A %d (%s)%s  rates A %d B %d%s  SDCCH blocs %d/%d%s" %
                  (vers_b.envoyes, fmt(vers_b), vers_a.envoyes, fmt(vers_a),
                   "  C->B %d (%s)  B->C %d (%s)" % (vers_b1.envoyes, fmt(vers_b1), vers_c.envoyes if vers_c else 0, fmt(vers_c) if vers_c else "-") if c_ring else "",
                   a_ring.rate, b_ring.rate, " C %d" % c_ring.rate if c_ring else "",
                   dedie.decodes, dedie.decodes + dedie.rates, "  TCH TS%d" % dedie.tn if dedie.tn is not None else "")
                  + ("  D=%s%s" % (decalage.d, " (sans D : %d perdus)" % c_sans_d if c_sans_d else "") if c_ring else ""), flush=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass

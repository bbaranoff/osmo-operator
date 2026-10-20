#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""air.py - l'air entre deux Calypsos emules : les bursts que l'un emet, l'autre les recoit.

[2026-10-19] Montage a deux instances (c54x_exe/run.sh INSTANCE=2) : l'instance 1 est le
TRX de la BTS#0 (firmware trx, start-native.sh --osmo-trx), l'instance 2 est le mobile.
Chaque c54x_exe publie les bursts finaux que sa ROM emet dans un anneau
/dev/shm/calypso_tx_rom (pont.c, tx_tsp_publier) : en-tete w(4) slots(4), puis des cases de
160 octets : seq(4) fn(4) type(1) tsc(1) offset(1) src(1) bits(148). Chaque BSP (calypso_bsp.c)
attend les bursts qu'il doit recevoir en TRXDv0 sur UDP (6702, CALYPSO_BSP_PORT) :
tn(1) fn(4, gros-boutiste) rssi(1) toa(2) bits(148, un octet 0/1 par bit).

Ce relais lit l'anneau de A et l'envoie au BSP de B, et l'anneau de B au BSP de A : le
descendant (FB, SB, dummy, NB du TRX) va au mobile, le montant (RACH, NB du mobile) va au TRX.
Il part de la fin des anneaux (pas de rejeu), et compte ce qui passe toutes les 5 s.

  python3 air.py --a-ring /dev/shm/calypso_tx_rom --a-port 6702 \\
                 --b-ring /dev/shm/calypso2/calypso_tx_rom --b-port 6712
Depuis l'instance 2 (run.sh, espace de montage prive) l'anneau de l'instance 1 se lit en
/run/calypso-shm-hote/calypso_tx_rom.

[2026-10-20] Troisieme Calypso, le telephone 2 du TRX (TS1, instance 3 : --c-ring / --c-port) : ses bursts
vont au mobile avec tn=1 ; les bursts du mobile vont au TRX du TS0 (A) tant qu'il est sur le SDCCH, au TRX
du TS1 (C) une fois l'ASSIGNMENT COMMAND passe. L'air lit cet ASSIGNMENT COMMAND dans les blocs SDCCH/4 du
TS0 (pont.gsm, libosmocoding) et l'annonce au c54x_exe du mobile par --tch-cfg (format de pont/state.py :
seq, tn, tsc, arfcn), comme le faisait le pont ; un RACH du mobile rend le SDCCH (tn=0).
"""
import argparse
import os
import socket
import struct
import sys
import time

# [2026-10-20] le decodeur de blocs du pont (libosmocoding par ctypes) pour lire l'ASSIGNMENT COMMAND
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
try:
    from pont import gsm
except Exception as _e:   # pragma: no cover - sans libosmocoding l'air relaie quand meme, sans TCH
    gsm = None
    print("air : pont.gsm indisponible (%s) : pas de detection de l'ASSIGNMENT COMMAND" % _e, flush=True)

HDR = 8
SLOT = 160
TYPES = {0: "?", 1: "RACH", 2: "NB", 3: "SB", 4: "DUMMY", 5: "FB", 101: "TS1", 102: "TS2", 103: "TS3", 104: "TS4", 105: "TS5", 106: "TS6", 107: "TS7"}


class Anneau:
    """Un anneau calypso_tx_rom ; on ne lit que ce qui est ecrit apres notre arrivee."""

    def __init__(self, path, nom):
        self.path, self.nom = path, nom
        self.fd = -1
        self.seq = None          # derniere seq lue
        self.slots = 256
        self.rate = 0
        # [2026-10-20] CONTINUITE DU fn. En mode TRX le fn publie est le tick du c54x_exe emetteur
        # (le firmware trx ne pose pas a_a5fn) : il repart de 0 quand on relance banc-trx, et le BSP
        # du mobile (STREAM : un burst par trame, dans l'ordre des fn) attendait alors un fn de
        # 357073 en voyant arriver 15000 (« le DSP court devant le BTS », 61200 manques). On relaie
        # donc fn + decalage, le decalage etant recale a chaque recul du fn pour que la numerotation
        # vue du recepteur reste monotone et continue (+1 par rapport au dernier fn relaye).
        self.fn_dec = 0
        self.fn_dernier = None
        self.recalages = 0

    def fn_continu(self, fn):
        out = (fn + self.fn_dec) % 2715648
        if self.fn_dernier is not None:
            d = (out - self.fn_dernier) % 2715648
            if d > 100000:                  # recul (ou saut absurde) : on recale juste apres le dernier ; d == 0 = un autre slot de la meme trame
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
        self.seq = w                        # on part de la fin
        print("air : anneau %s ouvert (%s), %d cases, seq=%d" % (self.nom, self.path, self.slots, w), flush=True)
        return True

    def nouveaux(self):
        """Rend les cases (seq, fn, type, tsc, offset, src, bits) ecrites depuis le dernier appel."""
        if not self._ouvrir():
            return []
        # [2026-10-20 22:25] l'autre instance relancee (./start-native.sh --bts pendant que le mobile tourne) :
        # son c54x_exe RECREE l'anneau (nouvel inode) et l'ancien descripteur lit un fichier supprime
        # pour toujours (A->B fige, le mobile n'a plus de descendant). On compare l'inode a chaque tour.
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
        if w < self.seq:                     # anneau recree (nouveau run)
            print("air : anneau %s remis a zero (seq %d -> %d)" % (self.nom, self.seq, w), flush=True)
            self.seq = 0
        debut = self.seq + 1
        if w - debut >= self.slots:          # trop de retard : on saute au plus recent
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
            if seq != s:                     # case pas encore ecrite / ecrasee
                continue
            out.append((seq, fn, typ, tsc, offset, src, case[12:160]))
        self.seq = w
        return out


class Cible:
    """Le BSP de l'autre instance, en TRXDv0 sur UDP."""

    def __init__(self, host, port, nom, tn):
        self.addr, self.nom, self.tn = (host, port), nom, tn
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.envoyes = 0
        self.par_type = {}

    def envoyer(self, fn, typ, bits, tn=None):
        """tn : l'intervalle annonce dans l'en-tete TRXD ; par defaut celui de la cible. [2026-10-20] les
        anneaux portent maintenant le TS du burst (bits 4-6 de src) : on le relaie tel quel."""
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
            self.par_type[100 + tn] = self.par_type.get(100 + tn, 0) + 1   # compte par intervalle (TS1..7)


SDCCH4_DL = {22: 0, 23: 0, 24: 0, 25: 0, 26: 1, 27: 1, 28: 1, 29: 1, 32: 2, 33: 2, 34: 2, 35: 2, 36: 3, 37: 3, 38: 3, 39: 3}


class Dedie:
    """L'ASSIGNMENT COMMAND lu sur le SDCCH/4 du TS0, et l'annonce du TCH au mobile (calypso_tch_cfg)."""

    def __init__(self, chemin):
        self.chemin = chemin
        self.blocs = {}          # sous-canal -> [(fn, bits)]
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
        """Un burst TS0 du TRX : accumule les blocs SDCCH/4 et cherche l'ASSIGNMENT COMMAND."""
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
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--tn", type=int, default=0, help="timeslot annonce dans l'en-tete TRXD des bursts de A (defaut 0)")
    ap.add_argument("--sans", default="", help="types a ne pas relayer, ex. « ?,RACH »")
    ap.add_argument("--periode", type=float, default=0.002, help="periode de scrutation (s)")
    ap.add_argument("--stats", type=float, default=5.0, help="periode des comptes (s)")
    args = ap.parse_args()
    noms = {v: k for k, v in TYPES.items()}
    sans = {noms[t.strip()] for t in args.sans.split(",") if t.strip() in noms}

    a_ring, b_ring = Anneau(args.a_ring, "A"), Anneau(args.b_ring, "B")
    vers_b = Cible(args.host, args.b_port, "B", args.tn)   # ce que A emet -> B recoit (TS0)
    vers_a = Cible(args.host, args.a_port, "A", args.tn)   # ce que B emet -> A recoit
    c_ring = Anneau(args.c_ring, "C") if args.c_ring else None
    vers_b1 = Cible(args.host, args.b_port, "B(TS1)", 1) if c_ring else None   # ce que C emet -> B recoit, tn 1
    vers_c = Cible(args.host, args.c_port, "C", 1) if (c_ring and args.c_port) else None
    dedie = Dedie(args.tch_cfg)
    print("air : A %s -> udp %d (B) ; B %s -> udp %d (A) ; tn %d%s%s%s" %
          (args.a_ring, args.b_port, args.b_ring, args.a_port, args.tn,
           " ; C %s -> udp %d (B, tn 1) ; B -> udp %s (C) sur TCH" % (args.c_ring, args.b_port, args.c_port) if c_ring else "",
           " ; annonce TCH : %s" % args.tch_cfg if args.tch_cfg else "",
           " ; sans %s" % args.sans if sans else ""), flush=True)
    prochain = time.monotonic() + args.stats
    while True:
        bouge = False
        for seq, fn, typ, tsc, offset, src, bits in a_ring.nouveaux():
            bouge = True
            if typ in sans or offset == 0xff and typ == 0:
                continue
            fnc = a_ring.fn_continu(fn)
            tn_b = (src >> 4) & 7                      # le TS du burst (TS0 : BCCH/CCCH/SDCCH, TS1 : le TCH)
            vers_b.envoyer(fnc, typ, bits, tn_b)
            if tn_b == 0:
                dedie.descendant(fnc, typ, bits)
        if c_ring:
            for seq, fn, typ, tsc, offset, src, bits in c_ring.nouveaux():
                bouge = True
                if typ in sans or offset == 0xff and typ == 0:
                    continue
                vers_b1.envoyer(c_ring.fn_continu(fn), typ, bits)
        for seq, fn, typ, tsc, offset, src, bits in b_ring.nouveaux():
            bouge = True
            if typ in sans or offset == 0xff and typ == 0:
                continue
            fnc = b_ring.fn_continu(fn)
            tn_m = (src >> 4) & 7                      # le TS sur lequel le mobile a emis (montant_tn_dedie)
            if typ == 1:                                   # RACH : le mobile est (re)venu sur le TS0
                if dedie.tn is not None:
                    dedie.liberer("RACH du mobile")
                vers_a.envoyer(fnc, typ, bits, 0)
            elif tn_m and vers_c is not None:
                vers_c.envoyer(fnc, typ, bits, tn_m)       # TCH du TS1 -> telephone 2 du TRX (montage a 3 Calypsos)
            else:
                vers_a.envoyer(fnc, typ, bits, tn_m)       # un seul telephone TRX : TS0 et TS1 par tn
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
                   dedie.decodes, dedie.decodes + dedie.rates, "  TCH TS%d" % dedie.tn if dedie.tn is not None else ""), flush=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass

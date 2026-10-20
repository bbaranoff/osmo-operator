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
"""
import argparse
import os
import socket
import struct
import sys
import time

HDR = 8
SLOT = 160
TYPES = {0: "?", 1: "RACH", 2: "NB", 3: "SB", 4: "DUMMY", 5: "FB"}


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
            if d == 0 or d > 100000:        # recul (ou saut absurde) : on recale juste apres le dernier
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

    def envoyer(self, fn, typ, bits):
        pkt = bytes([self.tn & 7]) + struct.pack(">I", fn) + b"\x00\x00\x00" + bytes(b & 1 for b in bits)
        try:
            self.sock.sendto(pkt, self.addr)
        except OSError as e:
            print("air : envoi vers %s %s:%d : %s" % (self.nom, self.addr[0], self.addr[1], e), flush=True)
            return
        self.envoyes += 1
        self.par_type[typ] = self.par_type.get(typ, 0) + 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--a-ring", required=True, help="anneau TX de A (ce que A emet)")
    ap.add_argument("--a-port", type=int, required=True, help="port UDP du BSP de A (ce que A recoit)")
    ap.add_argument("--b-ring", required=True)
    ap.add_argument("--b-port", type=int, required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--tn", type=int, default=0, help="timeslot annonce dans l'en-tete TRXD (defaut 0)")
    ap.add_argument("--sans", default="", help="types a ne pas relayer, ex. « ?,RACH »")
    ap.add_argument("--periode", type=float, default=0.002, help="periode de scrutation (s)")
    ap.add_argument("--stats", type=float, default=5.0, help="periode des comptes (s)")
    args = ap.parse_args()
    noms = {v: k for k, v in TYPES.items()}
    sans = {noms[t.strip()] for t in args.sans.split(",") if t.strip() in noms}

    a_ring, b_ring = Anneau(args.a_ring, "A"), Anneau(args.b_ring, "B")
    vers_b = Cible(args.host, args.b_port, "B", args.tn)   # ce que A emet -> B recoit
    vers_a = Cible(args.host, args.a_port, "A", args.tn)   # ce que B emet -> A recoit
    print("air : A %s -> udp %d (B) ; B %s -> udp %d (A) ; tn %d%s" %
          (args.a_ring, args.b_port, args.b_ring, args.a_port, args.tn,
           " ; sans %s" % args.sans if sans else ""), flush=True)
    prochain = time.monotonic() + args.stats
    while True:
        bouge = False
        for anneau, cible in ((a_ring, vers_b), (b_ring, vers_a)):
            for seq, fn, typ, tsc, offset, src, bits in anneau.nouveaux():
                bouge = True
                if typ in sans or offset == 0xff and typ == 0:
                    continue
                cible.envoyer(anneau.fn_continu(fn), typ, bits)
        if not bouge:
            time.sleep(args.periode)
        if time.monotonic() >= prochain:
            prochain += args.stats
            def fmt(c):
                return " ".join("%s=%d" % (TYPES.get(t, str(t)), n) for t, n in sorted(c.par_type.items())) or "-"
            print("air : A->B %d (%s)  B->A %d (%s)  rates A %d B %d" %
                  (vers_b.envoyes, fmt(vers_b), vers_a.envoyes, fmt(vers_a), a_ring.rate, b_ring.rate), flush=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass

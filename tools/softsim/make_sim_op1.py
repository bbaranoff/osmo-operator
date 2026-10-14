#!/usr/bin/env python3
# tools/softsim/make_sim_op1.py - genere le sim.xml de la SIM de l abonne du HLR
# a partir du sim.xml de demonstration de softSIM.
#
#   make_sim_op1.py <sim.xml de base> <sortie> [--imsi 001010001000001]
#
# Remplace l EF_IMSI (6f07) des deux DF par l IMSI donne, encode en BCD comme
# TS 51.011 (octet 1 : chiffre 1 + indicateur impair + type IMSI). Le Ki n est
# PAS ecrit ici : il vient de SOFTSIM_KI (lu par le serveur patche).
import re
import sys

DEMO_IMSI_BODY = "084906202771401469"  # IMSI de demonstration 460027217044196


def imsi_body(imsi):
    d = [int(c) for c in imsi]
    if len(d) != 15:
        raise SystemExit("IMSI a 15 chiffres attendu : %r" % imsi)
    out = [(d[0] << 4) | 0x09]  # chiffre 1, indicateur impair, type IMSI (1)
    for k in range(1, 15, 2):
        lo = d[k]
        hi = d[k + 1] if k + 1 < 15 else 0xF
        out.append((hi << 4) | lo)
    return "08" + "".join("%02x" % b for b in out)


def iccid_body(imsi, mcc, mnc):
    """ICCID de 20 chiffres (89 + MCC + MNC + fin de l IMSI + 00 + cle de Luhn),
    en BCD a quartets inverses comme TS 51.011 : le sim.xml de demonstration porte
    un ICCID aux quartets invalides (e, a) que le mobile affichait en > et :."""
    d = [int(c) for c in "89" + mcc + mnc + imsi[5:] + "00"]
    tot = 0
    for k, v in enumerate(reversed(d)):  # le chiffre de controle s ajoute apres
        if k % 2 == 0:
            v *= 2
            v = v - 9 if v > 9 else v
        tot += v
    d.append((10 - tot % 10) % 10)
    return "".join("%x%x" % (d[k + 1], d[k]) for k in range(0, 20, 2))


def plmn_bcd(mcc, mnc):
    """PLMN sur 3 octets (TS 31.102) : MCC1 MCC2 / MNC3 MCC3 / MNC2 MNC1."""
    m = [int(c) for c in mcc]
    n = [int(c) for c in mnc]
    n3 = n[2] if len(n) == 3 else 0xF
    return "%02x%02x%02x" % ((m[1] << 4) | m[0], (n3 << 4) | m[2], (n[1] << 4) | n[0])


def set_file_body(s, fid, fn):
    """Remplace le <body> du fichier fid (DF et tous les endroits) par fn(old_hex)."""
    pat = re.compile(r'(<file id="%s"[^>]*>.*?<body>)([0-9a-fA-F]*)(</body>)' % fid, re.S)
    return pat.sub(lambda m: m.group(1) + fn(m.group(2)) + m.group(3), s)


def set_plmn(s, mcc, mnc):
    """Remplace le PLMN des fichiers qui le portent (PLMNsel, FPLMN, LOCI, SPN)."""
    p = plmn_bcd(mcc, mnc)
    # EF_PLMNsel : premiere entree = PLMN, le reste en ff (meme longueur)
    s = set_file_body(s, "6f30", lambda b: p + "ff" * (len(b) // 2 - 3))
    # EF_FPLMN : aucune PLMN interdite
    s = set_file_body(s, "6f7b", lambda b: "ff" * (len(b) // 2))
    # EF_LOCI : LAI = PLMN (octets 4..6 du body, apres le TMSI)
    def loci(b):
        raw = bytearray.fromhex(b)
        raw[4:7] = bytes.fromhex(p)
        return raw.hex()
    s = set_file_body(s, "6f7e", loci)
    # EF_SPN : nom de l operateur, indicateur d affichage 00
    s = set_file_body(s, "6f46", lambda b: "00" + "Test".encode().hex() + "ff" * (len(b) // 2 - 5))
    return s


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)
    src, dst = argv[1], argv[2]
    imsi = argv[argv.index("--imsi") + 1] if "--imsi" in argv else "001010001000001"
    # verification : l encodeur reproduit l IMSI de demonstration
    assert imsi_body("460027217044196") == DEMO_IMSI_BODY
    body = imsi_body(imsi)
    s = open(src, encoding="utf-8").read()
    s, n = re.subn(r"<body>%s</body>" % DEMO_IMSI_BODY, "<body>%s</body>" % body, s)
    if n == 0:
        raise SystemExit("EF_IMSI de demonstration introuvable dans %s" % src)
    mcc = imsi[:3]
    mnc = imsi[3:5]  # MNC a 2 chiffres, comme l IMSI du plan
    s = set_plmn(s, mcc, mnc)
    # EF_ICCID (2fe2) : 10 octets, valide en BCD
    s = set_file_body(s, "2fe2", lambda b: iccid_body(imsi, mcc, mnc))
    open(dst, "w", encoding="utf-8").write(s)
    print("EF_IMSI %s -> %s (%d occurrence(s))" % (imsi, body, n))


if __name__ == "__main__":
    main(sys.argv)

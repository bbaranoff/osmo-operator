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
    open(dst, "w", encoding="utf-8").write(s)
    print("EF_IMSI %s -> %s (%d occurrence(s))" % (imsi, body, n))


if __name__ == "__main__":
    main(sys.argv)

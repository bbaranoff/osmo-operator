#!/usr/bin/env python3
# pont_dsp.py - le pont du montage DSP (c54x_exe --arm, bursts vers le BSP du
# C54x sur --dsp-port 6702). Le montage grgsm a son propre point d'entree,
# pont.py, qui garde ses defauts d'avant le decoupage du 2026-09-23 ; les deux
# partagent le paquet (trx, descendant, montant, chiffrement A5).
import os
import sys

# Un burst montant reveille apres sa trame part quand meme, jusqu'a 26 trames
# de retard : la BTS le range par son fn (cf. trx.py Transmitter.run).
os.environ.setdefault("PONT_UL_RETARD_MAX", "26")

sys.path[0] = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
from pont import main

if __name__ == "__main__":
    main()

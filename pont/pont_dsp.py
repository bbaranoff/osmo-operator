#!/usr/bin/env python3
# pont_dsp.py - le pont du montage DSP (c54x_exe --arm, bursts vers le BSP du
# C54x sur --dsp-port 6702). Le montage grgsm a son propre point d'entree,
# pont.py, qui garde ses defauts d'avant le decoupage du 2026-09-23 ; les deux
# partagent le paquet (trx, descendant, montant, chiffrement A5).
#
# [2026-09-23] Ce point d'entree lance pont.dsp.main, le vrai pont DSP : memes
# briques, mais l'etat dedie suit le DSP au lieu du decodage du pont (voir
# pont/dsp/__init__.py). pont/__init__.py et pont.py n'en dependent pas.
# Lance par c54x_exe/run.sh en MODE=dsp (PONT_PY par defaut), donc aussi par
# start-direct.sh --dsp.
import os
import sys

# Un burst montant reveille apres sa trame part quand meme, jusqu'a 26 trames
# de retard : la BTS le range par son fn (cf. trx.py Transmitter.run).
os.environ.setdefault("PONT_UL_RETARD_MAX", "26")
# Le Kc est garde apres la liberation (pont/dsp/uplink.py) : c'est la
# retention qui le rend encore lisible une fois montant.c revenu en clair.
os.environ.setdefault("PONT_KC_RETENTION", "1")

sys.path[0] = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
from pont.dsp import main

if __name__ == "__main__":
    main()

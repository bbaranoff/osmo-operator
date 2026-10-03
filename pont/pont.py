#!/usr/bin/env python3
# pont.py - le pont du montage GRGSM (couche 1 gr-gsm dans QEMU).
#
# [2026-09-23] Le pont est coupe en deux points d'entree sur le meme paquet :
#   pont.py           montage grgsm : QEMU recoit les blocs L2 en GSMTAP
#                     (4730/4731), le pont dechiffre A5 pour lui.
#   pont_dsp.py       montage DSP (c54x_exe --arm, --dsp-port 6702) : les
#                     bursts partent vers le BSP du C54x.
# Les deux gardent le chiffrement A5 dans le pont. Ce qui change d'un montage
# a l'autre passe par les DEFAUTS poses ici, avant l'import : le chemin grgsm
# garde exactement le comportement qu'il avait avant le decoupage, et ce qu'on
# change pour le DSP ne peut plus le casser. Une variable posee par
# l'operateur gagne toujours (setdefault).
import os
import sys

# Un burst montant reveille apres sa trame est JETE, comme avant le 2026-09-23
# (le montage DSP l'envoie, cf. trx.py Transmitter.run).
os.environ.setdefault("PONT_UL_RETARD_MAX", "0")

# [2026-10-03] INJECTEUR DE BRUIT (qosmo/tools/injecteur_bruit.py, cible grgsm).
# La L1 gr-gsm de QEMU ecoute GSMTAP sur 4730 en dur : pour intercaler
# l'injecteur, c'est le pont qui vise ailleurs. BRUIT_MODE=ber ou relais (les
# seuls modes qui aient un sens sur des blocs L2 deja decodes) fait viser
# BRUIT_PORT_GRGSM (14730), ou l'injecteur ecoute (qosmo/run_modules/38-bruit.sh,
# c54x_exe/run.sh). Sans BRUIT_MODE, rien ne change. PONT_GSMTAP_PORT pose par
# l'operateur (ou par c54x_exe/run.sh) gagne.
if os.environ.get("BRUIT_MODE", "") in ("ber", "relais"):
    os.environ.setdefault("PONT_GSMTAP_PORT", os.environ.get("BRUIT_PORT_GRGSM", "14730"))

sys.path[0] = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
from pont import main

if __name__ == "__main__":
    if any(a == "--dsp-port" or a.startswith("--dsp-port=") for a in sys.argv[1:]):
        sys.exit("pont.py est le pont du montage grgsm : pour le DSP, lancer pont/pont_dsp.py --dsp-port 6702")
    main()

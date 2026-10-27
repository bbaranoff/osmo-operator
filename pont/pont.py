#!/usr/bin/env python3
# pont.py - the bridge of the GRGSM setup (gr-gsm layer 1 inside QEMU).
#
# The bridge has two entry points on the same package:
#   pont.py           grgsm setup: QEMU receives the L2 blocks as GSMTAP
#                     (4730/4731), the bridge deciphers A5 for it.
#   pont_dsp.py       DSP setup (c54x_exe --arm, --dsp-port 6702): the bursts
#                     go to the C54x BSP.
# Both keep the A5 ciphering in the bridge. What differs between the two
# setups goes through the DEFAULTS set here, before the import, so that a
# change for the DSP cannot break the grgsm path. A variable set by the
# operator always wins (setdefault).
import os
import sys

# An uplink burst woken up after its frame is DROPPED (the DSP setup sends it,
# see trx.py Transmitter.run).
os.environ.setdefault("PONT_UL_RETARD_MAX", "0")

# NOISE INJECTOR (qosmo/tools/injecteur_bruit.py, grgsm target).
# The gr-gsm L1 of QEMU listens for GSMTAP on 4730, hard-coded: to insert the
# injector, the bridge is what aims elsewhere. BRUIT_MODE=ber or relais (the
# only modes that make sense on already decoded L2 blocks) aims at
# BRUIT_PORT_GRGSM (14730), where the injector listens
# (qosmo/run_modules/38-bruit.sh, c54x_exe/run.sh). Without BRUIT_MODE nothing
# changes. PONT_GSMTAP_PORT set by the operator (or by c54x_exe/run.sh) wins.
if os.environ.get("BRUIT_MODE", "") in ("ber", "relais"):
    os.environ.setdefault("PONT_GSMTAP_PORT", os.environ.get("BRUIT_PORT_GRGSM", "14730"))

sys.path[0] = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
from pont import main

if __name__ == "__main__":
    if any(a == "--dsp-port" or a.startswith("--dsp-port=") for a in sys.argv[1:]):
        sys.exit("pont.py est le pont du montage grgsm : pour le DSP, lancer pont/pont_dsp.py --dsp-port 6702")
    main()

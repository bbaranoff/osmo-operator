#!/usr/bin/env python3
# pont_dsp.py - the bridge of the DSP setup (c54x_exe --arm, bursts to the
# C54x BSP on --dsp-port 6702). The grgsm setup has its own entry point,
# pont.py, with its own defaults; both share the package (trx, downlink,
# uplink, A5 ciphering).
#
# This entry point starts pont.dsp.main, the real DSP bridge: same building
# blocks, but the dedicated state follows the DSP instead of the bridge's own
# decoding (see pont/dsp/__init__.py). pont/__init__.py and pont.py do not
# depend on it. Started by c54x_exe/run.sh in MODE=dsp (default PONT_PY), so
# also by start-native.sh --dsp.
import os
import sys

# An uplink burst woken up after its frame is still sent, up to 26 frames
# late: the BTS files it by its fn (see trx.py Transmitter.run).
os.environ.setdefault("PONT_UL_RETARD_MAX", "26")
# The Kc is kept after the release (pont/dsp/uplink.py): the retention is
# what keeps it readable once montant.c is back in clear.
os.environ.setdefault("PONT_KC_RETENTION", "1")
# The downlink also goes to the BSP of instance 4 (banc-rssi, udp 6762): with
# a classic BTS, the rssi application has no other source (the air only relays
# the TX ring of the instance 1 Calypso, here the mobile). Without rssi
# running, the copy goes to an empty port. PONT_DSP_COPIES= (empty) cuts it.
os.environ.setdefault("PONT_DSP_COPIES", "6762")

sys.path[0] = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
from pont.dsp import main

if __name__ == "__main__":
    main()

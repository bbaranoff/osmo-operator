#!/bin/bash
# Runs si_bridge (2 grgsm: clear always-on + ciphered spawned on Kc) in a loop.
# --line-buffered: otherwise grep buffers by 4KB blocks -> late logs, the
# respawn/Kc cannot be watched in real time. Python errors/tracebacks are
# let through as well (otherwise invisible).
source /root/.env/bin/activate 2>/dev/null
echo "[si-bridge] 2 grgsm (clair iq_grgsm.fifo + chiffre iq_grgsm_ciph.fifo) -> feed_*"
while true; do
  python3 ${GSM_ROOT}/si_bridge.py /tmp/iq_grgsm.fifo 2>&1 \
    | grep --line-buffered -E "si-bridge|SI|Traceback|Error|error|Exception"
  sleep 2
done

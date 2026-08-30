#!/bin/bash
# Lance si_bridge (2 grgsm : clair toujours-on + chiffre spawne sur Kc) en boucle.
# --line-buffered : sinon le grep bufferise par blocs (4KB) -> logs en retard,
# impossible de voir le respawn/Kc en temps reel. On laisse passer aussi les
# erreurs/tracebacks Python (sinon invisibles).
source /root/.env/bin/activate 2>/dev/null
echo "[si-bridge] 2 grgsm (clair iq_grgsm.fifo + chiffre iq_grgsm_ciph.fifo) -> feed_*"
while true; do
  python3 ${GSM_ROOT}/si_bridge.py /tmp/iq_grgsm.fifo 2>&1 \
    | grep --line-buffered -E "si-bridge|SI|Traceback|Error|error|Exception"
  sleep 2
done

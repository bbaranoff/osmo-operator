#!/usr/bin/env bash
# tools/matrix.sh <burst|si> - MATRICE DYNAMIQUE du treillis 51-multiframe (cote mobile).
#
# Deux vues "temps/canal" complementaires des 2 FFT (frequence) :
#   tools/matrix.sh burst  -> dynamique des BURSTS (TRXD ts0 DL :5702) :
#                       lignes = FN%51 (structure canal), colonnes = temps,
#                       couleur = vide / dummy(idle) / reel(actif).
#   tools/matrix.sh si     -> dynamique des SI/L2 decodes (GSMTAP :4729/:4730) :
#                       lignes = FN%51, couleur = type de message (SI/IMM/UA/PAGING/?).
#
# Sniff PASSIF (AF_PACKET via gsm_sniff.py dans le conteneur, ne vole rien, aucune
# fifo) -> pipe -> rendu matplotlib sur l'hote (X). Ferme la fenetre pour quitter.
#
# Usage : ./tools/matrix.sh burst    |    ./tools/matrix.sh si
#         CONTAINER=osmo-operator-66 TS=0 W=240 ./tools/matrix.sh burst
set -euo pipefail
MODE="${1:?usage: tools/matrix.sh <burst|si>}"
case "$MODE" in burst|si) ;; *) echo "mode invalide: $MODE (burst|si)"; exit 1;; esac
export MODE
export CONTAINER="${CONTAINER:-osmo-operator-66}"
export TS="${TS:-0}"          # timeslot a afficher (0 = canal combine CCCH+SDCCH4)
export W="${W:-240}"          # colonnes (multiframes d'historique)
export DISPLAY="${DISPLAY:-:0}"
PY="${PY:-/root/.env/bin/python3}"; command -v "$PY" >/dev/null 2>&1 || PY=python3

SNIFF=/opt/GSM/qemu-src/opt-gsm-scripts/gsm_sniff.py
docker exec "$CONTAINER" test -f "$SNIFF" || { echo "gsm_sniff absent dans $CONTAINER"; exit 1; }

# gsm_sniff (conteneur, passif) -> stdout -> python hote (rendu matrice live)
docker exec "$CONTAINER" sh -c "SNIFF_IFACE=lo stdbuf -oL python3 $SNIFF $MODE" \
| "$PY" - <<'PYEOF'
import sys, os, re, threading, collections
import numpy as np, matplotlib
matplotlib.use("TkAgg") if not os.environ.get("MATRIX_SAVE") else matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation
from matplotlib.colors import ListedColormap, BoundaryNorm

MODE = os.environ.get("MODE","burst"); TS = int(os.environ.get("TS","0")); W = int(os.environ.get("W","240"))
DUMMY = "00011111011011101100000101001001"   # debut du dummy burst GSM (idle)

# --- type SI/L2 -> code couleur (mode si) ---
SI_CODE = {"?":1,"SI1":2,"SI2":3,"SI3":4,"SI4":5,"SI2bis":6,"SI2ter":7,"SI13":8,
           "PAGING-REQ-1":9,"PAGING-REQ-2":9,"PAGING-REQ-3":9,
           "IMM-ASSIGN":10,"IMM-ASSIGN-EXT":10,"IMM-ASSIGN-REJ":10}
# LAPDm (SDCCH/SACCH) detecte par octet de controle : on tag "DEDIE"
SI_LABELS = ["·","?","SI1","SI2","SI3","SI4","SI2b","SI2t","SI13","PAG","IMM","DEDIE"]
SI_COLORS = ["#101018","#888","#1f77b4","#2ca02c","#17becf","#9467bd","#8c564b","#e377c2",
             "#7f7f7f","#ff7f0e","#d62728","#ffd700"]

mat = np.zeros((51, W)); curmf=[None]; lock=threading.Lock()

re_ts  = re.compile(r"ts(\d)\b")
re_m51 = re.compile(r"%51=(\d+)")
re_fn  = re.compile(r"\bfn=(\d+)|\bFN=(\d+)")
re_148 = re.compile(r"\b([01]{148})\b")
re_si  = re.compile(r"\b(SI2bis|SI2ter|SI1[3]?|SI[2-4]|IMM-ASSIGN-?\w*|PAGING-REQ-\d)\b")
re_port= re.compile(r":(\d{4})\b")

def reader():
    for line in sys.stdin:
        m51 = re_m51.search(line);  mts = re_ts.search(line)
        if not m51: continue
        if mts and int(mts.group(1)) != TS:   # filtre timeslot (defaut ts0)
            # en mode si les lignes :4730 n'ont pas toujours ts -> on garde
            if MODE=="burst": continue
        fnm = re_fn.search(line); fn = int(fnm.group(1) or fnm.group(2)) if fnm else None
        r = int(m51.group(1)) % 51
        if MODE=="burst":
            mb = re_148.search(line)
            if "NOPE" in line or "vide" in line: v = 0.0          # burst vide
            elif mb and mb.group(1).startswith(DUMMY): v = 1.0    # dummy (idle)
            elif mb: v = 2.0                                       # reel (actif)
            else: v = 0.0
        else:
            ms = re_si.search(line)
            if ms: v = float(SI_CODE.get(ms.group(1), 1))
            elif "?" in line:                                     # LAPDm dedie (SDCCH/SACCH UA/I)
                v = 11.0 if (22<=r<=25 or 26<=r<=39 or 42<=r<=49) else 1.0
            else: v = 1.0
        mf = fn//51 if fn is not None else (curmf[0] or 0)
        with lock:
            if curmf[0] is None: curmf[0]=mf
            while mf > curmf[0]:                # nouvelle multiframe -> shift gauche
                mat[:, :-1] = mat[:, 1:]; mat[:, -1] = 0; curmf[0]+=1
            if mf == curmf[0]:
                mat[r, -1] = v

threading.Thread(target=reader, daemon=True).start()

plt.style.use("dark_background")
fig, ax = plt.subplots(figsize=(12,7))
title = ("BURSTS ts%d (·=vide  bleu=dummy/idle  rouge=ACTIF)" % TS) if MODE=="burst" \
        else "SI / L2 decodes (type par couleur)"
fig.suptitle("Matrice dynamique 51-multiframe - %s  [%s]" % (title, os.environ.get("CONTAINER","")),
             color="#7fd", fontsize=11)
if MODE=="burst":
    cmap = ListedColormap(["#101018","#1f77b4","#d62728"]); norm = BoundaryNorm([-.5,.5,1.5,2.5], cmap.N)
else:
    cmap = ListedColormap(SI_COLORS); norm = BoundaryNorm([i-.5 for i in range(len(SI_COLORS)+1)], cmap.N)
im = ax.imshow(mat, aspect="auto", origin="lower", cmap=cmap, norm=norm, interpolation="nearest")
ax.set_ylabel("FN % 51  (FCCH=0,10..  SCH=1,11..  BCCH=2-5  CCCH=6-19  SDCCH=22-39  SACCH=42-49)")
ax.set_xlabel("temps (multiframes 51) →")
# reperes des bandes canal (combine BCCH+SDCCH4 ts0)
for y in (0,10,20,30,40): ax.axhline(y, color="#444", lw=.4)
for y0,y1,lbl,c in [(2,5,"BCCH","#17becf"),(22,25,"SDCCH/0","#ffd700"),(42,45,"SACCH/0","#ff7f0e")]:
    ax.axhspan(y0-.5,y1+.5, xmin=0, xmax=0.015, color=c, alpha=.8)
if MODE=="si":
    from matplotlib.patches import Patch
    ax.legend(handles=[Patch(color=SI_COLORS[i], label=SI_LABELS[i]) for i in range(1,len(SI_LABELS))],
              loc="upper left", ncol=4, fontsize=7, framealpha=.3)

def update(_):
    with lock: im.set_data(mat.copy())
    return (im,)
ani = FuncAnimation(fig, update, interval=250, blit=False, cache_frame_data=False)
print("[matrix:%s] fenetre live - ferme pour quitter." % MODE, flush=True)
plt.show()
PYEOF

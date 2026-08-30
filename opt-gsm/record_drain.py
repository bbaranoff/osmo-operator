#!/usr/bin/env python3
# record_drain.py — draine le FIFO live iq_record.fifo -> record.cfile en RING
# (128 MB, fseek wrap), HORS du hot-path qemu. C'est l'EXTERNALISATION du ring
# cfile que qemu ecrivait avant dans son hot-path DL (= ce qui causait les
# underruns). Ici qemu ne fait qu'un write() non-bloquant vers le FIFO ; ce
# process (independant) absorbe le flux et l'ecrit sur disque a son rythme.
# grgsm_decode -c relit record.cfile offline comme avant => SI preserve.
#
# Ouverture du FIFO en O_RDWR : ne bloque pas a l'ouverture ET ne voit jamais
# d'EOF (on garde nous-memes un write-end), donc qemu (O_WRONLY|O_NONBLOCK)
# trouve toujours un lecteur => son open reussit et le flux coule.
#
# =============================================================================
# [2026-08-11] CAPTURE COMPLETE, DECLENCHABLE — a cote du ring, pas a sa place
# =============================================================================
# Le ring ci-dessus rembobine tous les 128 Mo (~15,5 s) : parfait pour rejouer
# le passe immediat, inutilisable pour capturer un appel entier. La capture
# complete ci-dessous ne rembobine JAMAIS.
#
# POURQUOI UN TUBE DEDIE, et pas une lecture de iq_record.fifo : un FIFO n'est
# pas diffusable — deux lecteurs se PARTAGENT les octets, ils ne les voient pas
# chacun en entier. Draîner iq_record.fifo ici volerait donc une partie du flux
# au ring et casserait le decodage SI. On ajoute un 8e tube au relai
# (CALYPSO_RELAY_FIFOS), que qemu alimente comme les autres.
# ⚠️ RELAY_NFIFO_MAX vaut 8 dans qemu_wrap.c et 7 tubes etaient deja declares :
# ce tube consomme LA DERNIERE PLACE. En ajouter un 9e exige de relever la
# constante ET de recompiler, sinon il est ignore EN SILENCE.
#
# ⚠️ PAS SUR TMPFS. /dev/shm et /tmp sont de la RAM. Le flux fait 1083333 ech/s
# x 8 o = 8,7 Mo/s = 520 Mo/min = 31 Go/h : une capture complete sur tmpfs
# epuise la memoire de la machine en quelques minutes. Le defaut pointe donc sur
# l'overlay (disque). Verifier `df -h` avant une longue capture.
#
# DECLENCHEMENT : la capture n'ecrit que TANT QUE le fichier declencheur existe.
#     touch /tmp/iq_full.trigger    -> demarre (ouvre/tronque le .cfile)
#     rm    /tmp/iq_full.trigger    -> arrete et FERME proprement le fichier
# Hors declenchement le tube est quand meme LU et jete : sinon l'anneau memoire
# du relai se remplit et qemu se met a jeter des trames entieres pour TOUS les
# tubes.
#
# PLAFOND : a CALYPSO_RECORD_FULL_MAX octets la capture S'ARRETE et le DIT. Elle
# ne rembobine pas — un fichier qui se remord la queue en silence est exactement
# ce qu'on veut eviter ici.
import os, sys, threading

FIFO = os.environ.get("CALYPSO_RECORD_FIFO", "/tmp/iq_record.fifo")
OUT  = os.environ.get("CALYPSO_RECORD_FILE", "/tmp/record.cfile")
RING = int(os.environ.get("CALYPSO_RECORD_RING", str(128 << 20)))   # 128 MB

FULL_ON      = os.environ.get("CALYPSO_RECORD_FULL", "0") == "1"
FULL_FIFO    = os.environ.get("CALYPSO_RECORD_FULL_FIFO", "/tmp/iq_full.fifo")
FULL_FILE    = os.environ.get("CALYPSO_RECORD_FULL_FILE", "/opt/GSM/captures/full.cfile")
FULL_TRIGGER = os.environ.get("CALYPSO_RECORD_FULL_TRIGGER", "/tmp/iq_full.trigger")
FULL_MAX     = int(os.environ.get("CALYPSO_RECORD_FULL_MAX", str(8 << 30)))   # 8 GB

def log(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()

def full_drain():
    """Capture complete : lit toujours, n'ecrit que sous declencheur, ne wrap jamais."""
    if not os.path.exists(FULL_FIFO):
        os.mkfifo(FULL_FIFO, 0o666)
    os.makedirs(os.path.dirname(FULL_FILE) or ".", exist_ok=True)
    fd = os.open(FULL_FIFO, os.O_RDWR)       # meme idiome que le ring : ni blocage ni EOF
    log("[record-full] %s -> %s (plafond %d MB) — declencheur : %s"
        % (FULL_FIFO, FULL_FILE, FULL_MAX >> 20, FULL_TRIGGER))
    out = None
    w = 0
    plafond_dit = False
    while True:
        b = os.read(fd, 1 << 16)
        if not b:
            continue
        armed = os.path.exists(FULL_TRIGGER)
        if armed and out is None:
            out = open(FULL_FILE, "wb", buffering=1 << 20)
            w = 0
            plafond_dit = False
            log("[record-full] DEMARRE -> %s" % FULL_FILE)
        elif not armed and out is not None:
            out.flush(); out.close(); out = None
            log("[record-full] ARRETE : %s, %.1f MB (%.1f s d'IQ)"
                % (FULL_FILE, w / 1048576.0, w / 8666664.0))
        if out is None:
            continue                          # on jette, mais on a LU : le relai ne bouche pas
        if w + len(b) > FULL_MAX:
            if not plafond_dit:
                log("[record-full] PLAFOND %d MB atteint : capture ARRETEE (pas de "
                    "rembobinage). Retirer %s, vider %s, puis relancer."
                    % (FULL_MAX >> 20, FULL_TRIGGER, FULL_FILE))
                plafond_dit = True
            out.flush(); out.close(); out = None
            continue
        out.write(b)
        w += len(b)
        out.flush()

if not os.path.exists(FIFO):
    os.mkfifo(FIFO, 0o666)

if FULL_ON:
    threading.Thread(target=full_drain, daemon=True).start()
else:
    log("[record-full] inactif (CALYPSO_RECORD_FULL != 1)")

fd = os.open(FIFO, os.O_RDWR)            # O_RDWR : pas de blocage / pas d'EOF
out = open(OUT, "wb", buffering=1 << 20)
w = 0
log("[record-drain] %s -> %s (ring %d MB)" % (FIFO, OUT, RING >> 20))
while True:
    b = os.read(fd, 1 << 16)            # 64 KB
    if not b:
        continue
    out.write(b)
    w += len(b)
    if w >= RING:                        # RING : rembobine (grgsm relit depuis 0)
        out.seek(0); w = 0
    out.flush()

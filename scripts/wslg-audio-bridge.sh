#!/bin/bash
# wslg-audio-bridge.sh - Fait sortir l'audio des conteneurs Osmocom sur les
# haut-parleurs de l'HOTE, depuis l'INTERIEUR du Docker. Marche dans deux cas :
#
#   • WSL2 + WSLg  : l'hote audio = PulseServer WSLg (/mnt/wslg/PulseServer),
#                    qui relaie lui-meme vers Windows.
#   • Linux natif  : l'hote audio = le PulseAudio/PipeWire de la session
#                    graphique (/run/user/<uid>/pulse/native).
#
# Principe (verifie) :
#   host-relay  → expose le pulse de l'hote en TCP (module-native-protocol-tcp)
#   container   → pont AUDIO direct dans le conteneur :
#                     parec(gsm_audio.monitor) | paplay(--server=tcp:<gw>:4713)
#
# On N'utilise PAS module-tunnel-sink : sur TCP/WSL son horloge derive (la
# latence grimpe a >1 s → son hache "tout pete"). parec|paplay = un seul
# serveur d'horloge (celui de l'hote) + simple pipe d'octets → audio propre.
#
# Le conteneur garde son PulseAudio autonome ; on ne touche pas a gsm_audio
# (le dashboard continue de lire gsm_audio.monitor).
#
# Usage :
#   wslg-audio-bridge.sh host-relay              # hote : ouvre le pulse en TCP
#   wslg-audio-bridge.sh container <name> [gw]   # conteneur : lance le pont
#   wslg-audio-bridge.sh test <name>             # bip 880Hz via gsm_audio
#   wslg-audio-bridge.sh down <name>             # stoppe le pont
#   wslg-audio-bridge.sh all <name> [gw]         # host-relay + container + test
set -euo pipefail

TCP_PORT="${WSLG_TCP_PORT:-4713}"
# ACL : tout le bloc prive 172.16/12 (couvre les subnets docker gsm-inter/op)
TCP_ACL="${WSLG_TCP_ACL:-127.0.0.1;172.16.0.0/12}"

log()  { echo -e "  [host-audio] $*"; }
die()  { echo -e "  [host-audio][FAIL] $*" >&2; exit 1; }

# IP de l'hote vue depuis le conteneur = gateway de sa route par defaut.
detect_gw() {
    docker exec "$1" sh -c "ip route 2>/dev/null | awk '/default/{print \$3; exit}'" 2>/dev/null || true
}

# Utilisateur de la session graphique (proprietaire du pulse natif).
# [2026-08-12] Le critere n'est pas le nom mais la PRESENCE du socket pulse :
# sous `sudo -i` SUDO_USER est perdu et `id -un` rend root, dont le
# /run/user/0/pulse/native n'existe quasiment jamais - on partait alors chercher
# un pulse inexistant au lieu de celui, bien vivant, de la session graphique.
# On balaye donc /run/user/* en dernier recours. Meme logique que
# session_pulse_user() de start.sh.
session_user() {
    local u uid sock
    for u in "${HOST_PULSE_USER:-}" "${SUDO_USER:-}" "$(logname 2>/dev/null || true)" "$(id -un)"; do
        [ -n "$u" ] || continue
        uid="$(id -u "$u" 2>/dev/null)" || continue
        [ -S "/run/user/${uid}/pulse/native" ] && { echo "$u"; return 0; }
    done
    for sock in /run/user/*/pulse/native; do
        [ -S "$sock" ] || continue
        uid="${sock#/run/user/}"; uid="${uid%%/*}"
        u="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)"
        [ -n "$u" ] && { echo "$u"; return 0; }
    done
    echo "${HOST_PULSE_USER:-${SUDO_USER:-$(id -un)}}"   # rien trouve : ancien defaut
}

# Execute `pactl ...` sur le pulse de l'hote natif, en tant qu'utilisateur session.
pactl_native() {
    local u uid rt
    u="$(session_user)"; uid="$(id -u "$u")"; rt="/run/user/${uid}"
    if [ "$(id -un)" = "$u" ]; then
        XDG_RUNTIME_DIR="$rt" PULSE_SERVER="unix:${rt}/pulse/native" pactl "$@"
    else
        sudo -u "$u" XDG_RUNTIME_DIR="$rt" PULSE_SERVER="unix:${rt}/pulse/native" pactl "$@"
    fi
}

# Execute un outil pulse quelconque (pactl, parec, timeout parec...) contre le
# pulse de l'HOTE, en WSLg comme en natif. Generalise pactl_native.
host_pa() {
    local bin="$1"; shift
    if [ -S /mnt/wslg/PulseServer ]; then
        PULSE_SERVER="unix:/mnt/wslg/PulseServer" "$bin" "$@"
    else
        local u uid rt
        u="$(session_user)"; uid="$(id -u "$u")"; rt="/run/user/${uid}"
        if [ "$(id -un)" = "$u" ]; then
            XDG_RUNTIME_DIR="$rt" PULSE_SERVER="unix:${rt}/pulse/native" "$bin" "$@"
        else
            sudo -u "$u" XDG_RUNTIME_DIR="$rt" PULSE_SERVER="unix:${rt}/pulse/native" "$bin" "$@"
        fi
    fi
}

# ── HOTE : choisir une source micro qui a REELLEMENT du signal ───────────────
#
# [2026-08-12] Panne vecue : le micro du dashboard web (bouton -> WebSocket ->
# pacat -> sink gsm_mic) debitait au bon rythme (49400 o/3 s a 8 kHz s16le) mais
# ne transportait que du ZERO. Cause : le navigateur capture la source PAR
# DEFAUT du systeme, et sur cette machine le defaut pointait sur
# alsa_input...hw_Generic_1__source - presente, NON mutee, volume 93 %, et
# pourtant silence numerique integral. La vraie entree etait hw_acp__source.
# `pactl` ne permet pas de distinguer les deux : il faut ECOUTER.
#
# On ne code donc aucun nom de peripherique (ils changent d'une machine a
# l'autre) : on mesure. Critere volontairement binaire - un micro vivant a
# TOUJOURS un plancher de bruit, donc des octets non nuls ; une entree mal
# routee ne sort que des zeros. `tr -d '\0' | wc -c` suffit : pas de dependance
# python/sox, ca tourne partout ou parec existe.
# ATTENTION AU FAUX NEGATIF : une source SUSPENDUE met ~2 s a delivrer ses
# premiers octets (mesure : timeout 1s -> 0 octet, timeout 3s -> 32000 octets
# dont 31946 non nuls, sur la MEME source vivante). Juger sur une fenetre courte
# revient a declarer muet tout peripherique au repos. On distingue donc deux
# cas distincts, jamais confondus :
#   - RIEN capture            -> le peripherique n'a pas demarre (indetermine)
#   - capture mais TOUT A ZERO -> silence numerique (la vraie panne)
# On lit jusqu'a MIC_PROBE_BYTES puis on coupe (head ferme le tube, parec recoit
# SIGPIPE) : rapide sur un peripherique vivant, seul un mort coute le timeout.
MIC_PROBE_SECS="${MIC_PROBE_SECS:-4}"
# Seconde chance pour un peripherique QUI N'A RIEN RENDU (verdict 2). Le
# commentaire ci-dessus mesure ~2 s de reveil sur une source suspendue ; une
# carte USB derriere un hub, ou un bluetooth qui doit negocier son profil, en
# demande davantage. Ce parametre existe pour ne pas condamner ces machines-la.
MIC_PROBE_SECS_SLOW="${MIC_PROBE_SECS_SLOW:-12}"
MIC_PROBE_BYTES="${MIC_PROBE_BYTES:-16000}"   # 1 s @ 8 kHz s16le mono
MIC_MIN_BYTES="${MIC_MIN_BYTES:-4000}"        # en deca : pas de verdict possible
MIC_MIN_NONZERO="${MIC_MIN_NONZERO:-100}"
MIC_MAX_PROBES="${MIC_MAX_PROBES:-8}"
# 1 = ne JAMAIS toucher au defaut systeme de l'hote (on se contente de dire ce
# qu'on a mesure). Utile sur un poste de travail : la selection ci-dessous est
# permanente, elle survit a l'arret d'osmo_egprs.
MIC_KEEP_DEFAULT="${MIC_KEEP_DEFAULT:-0}"

# Renvoie "<octets_captures> <octets_non_nuls>" sur stdout.
# $2 = duree de la fenetre (defaut MIC_PROBE_SECS).
probe_source() {
    local src="$1" secs="${2:-$MIC_PROBE_SECS}" tmp raw nz
    tmp="$(mktemp)"
    # `|| true` : timeout sort en 124, head provoque un SIGPIPE - sous
    # `set -o pipefail` l'un ou l'autre tuerait le script.
    { host_pa timeout "$secs" parec -d "$src" \
        --format=s16le --rate=8000 --channels=1 2>/dev/null || true; } \
      | head -c "$MIC_PROBE_BYTES" > "$tmp" 2>/dev/null || true
    raw="$(wc -c < "$tmp")"; nz="$(tr -d '\000' < "$tmp" | wc -c)"
    rm -f "$tmp"
    echo "${raw:-0} ${nz:-0}"
}

# 0 = signal, 1 = silence numerique, 2 = indetermine (rien capture)
source_verdict() {
    local r raw nz secs="${2:-$MIC_PROBE_SECS}"
    r="$(probe_source "$1" "$secs")"; raw="${r%% *}"; nz="${r##* }"
    [ "$raw" -ge "$MIC_MIN_BYTES" ] || return 2
    [ "$nz"  -ge "$MIC_MIN_NONZERO" ] || return 1
    return 0
}

# [2026-08-12] Le code distinguait soigneusement le verdict 1 (silence
# numerique = LA panne) du verdict 2 (rien capture = INDETERMINE)... puis
# traitait les deux pareil : dans les deux cas on partait chercher ailleurs et
# on reecrivait le defaut systeme. Un peripherique simplement lent a demarrer se
# faisait donc evincer au profit d'une entree qui, elle, n'a rien prouve de plus.
# "Indetermine" veut dire qu'il faut REGARDER PLUS LONGTEMPS, pas conclure.
verdict_retry() {
    local src="$1" rc=0
    source_verdict "$src" || rc=$?
    [ "$rc" = "2" ] || return "$rc"
    log "[mic]   ${src} : rien en ${MIC_PROBE_SECS}s - seconde chance sur ${MIC_PROBE_SECS_SLOW}s"
    rc=0; source_verdict "$src" "$MIC_PROBE_SECS_SLOW" || rc=$?
    return "$rc"
}

host_mic() {
    command -v parec >/dev/null 2>&1 \
        || { log "[mic] parec absent - selection micro ignoree"; return 0; }
    host_pa pactl info >/dev/null 2>&1 \
        || { log "[mic] pulse hote injoignable - selection micro ignoree"; return 0; }

    # RAPPEL DE PORTEE, sinon cette fonction se fait crediter d'un pouvoir
    # qu'elle n'a pas : elle regle le defaut du PULSE DE L'HOTE. Le micro du
    # tableau de bord, lui, est celui du POSTE QUI AFFICHE LA PAGE (getUserMedia
    # -> WebSocket -> pacat -> gsm_mic). Les deux ne coincident que si l'on
    # navigue depuis la machine hote. Depuis un autre poste, c'est le selecteur
    # de la page (web/index.html, #mic-dev) qui decide, et rien d'autre.
    log "[mic] selection de l'entree du PULSE DE L'HOTE (le navigateur, lui,"
    log "[mic]   utilise le micro de SON poste - selecteur dans le tableau de bord)."

    local cur rc; cur="$(host_pa pactl get-default-source 2>/dev/null || true)"
    if [ -n "$cur" ]; then
        # `|| rc=$?` OBLIGATOIRE : sous `set -e` un appel nu de source_verdict
        # renvoyant 1 (silence) ou 2 (rien capture) tuerait le script sur place,
        # sans une ligne de log - panne observee, tres deroutante.
        rc=0; verdict_retry "$cur" || rc=$?
        case "$rc" in
            0) log "[mic] source par defaut deja valide : ${cur}"; return 0 ;;
            1) log "[mic] defaut '${cur}' : SILENCE NUMERIQUE - recherche d'une autre entree..." ;;
            2) log "[mic] defaut '${cur}' : aucune donnee meme en ${MIC_PROBE_SECS_SLOW}s - recherche..." ;;
        esac
    fi

    if [ "$MIC_KEEP_DEFAULT" = "1" ]; then
        log "[mic] MIC_KEEP_DEFAULT=1 - defaut systeme laisse tel quel, pas de bascule."
        return 0
    fi

    local src i=0
    for src in $(host_pa pactl list short sources 2>/dev/null | awk '{print $2}' | grep -v '\.monitor$'); do
        [ "$src" = "$cur" ] && continue
        i=$((i + 1)); [ "$i" -gt "$MIC_MAX_PROBES" ] && break
        rc=0; verdict_retry "$src" || rc=$?        # cf. remarque set -e ci-dessus
        if [ "$rc" = "0" ]; then
            if host_pa pactl set-default-source "$src" >/dev/null 2>&1; then
                log "[mic] source par defaut -> ${src} (signal detecte)"
                # La bascule est PERMANENTE : pulse la garde apres l'arret
                # d'osmo_egprs. On journalise l'ancienne valeur pour que le
                # retour en arriere soit une commande, pas une enquete.
                [ -n "$cur" ] && log "[mic]   ancien defaut : ${cur}"
                [ -n "$cur" ] && log "[mic]   restaurer : pactl set-default-source ${cur}"
                log "[mic]   (MIC_KEEP_DEFAULT=1 desactive cette bascule)"
                log "[mic]   un onglet qui tient deja le micro reste epingle sur"
                log "[mic]   l'ancien peripherique : recouper/relancer le bouton micro."
                return 0
            fi
        else
            log "[mic]   ${src} : $([ "$rc" = 1 ] && echo 'silence numerique' || echo 'aucune donnee')"
        fi
    done

    log "[mic][!] AUCUNE source micro ne produit de signal (${i} testee(s))."
    log "[mic][!]   -> micro coupe materiellement (touche/interrupteur) ?"
    log "[mic][!]   -> mauvais profil UCM : verifier 'pactl list cards' / alsamixer."
    log "[mic][!]   Sans ca l'echo-test rendra le HP mais jamais la voix."
    return 0
}

# ── HOTE : expose le pulse de l'hote en TCP (idempotent) ─────────────────────
host_relay() {
    if [ -S /mnt/wslg/PulseServer ]; then
        # WSL2 + WSLg : socket monde-accessible (root OK)
        export PULSE_SERVER="unix:/mnt/wslg/PulseServer"
        if pactl list short modules 2>/dev/null | grep -q "protocol-tcp.*port=${TCP_PORT}"; then
            log "relai TCP deja actif (WSLg) :${TCP_PORT}"; return 0
        fi
        pactl load-module module-native-protocol-tcp \
            "port=${TCP_PORT}" "auth-ip-acl=${TCP_ACL}" auth-anonymous=1 >/dev/null \
            || die "load module-native-protocol-tcp (WSLg)"
        log "relai TCP WSLg → Windows active :${TCP_PORT}"
    else
        # Linux natif : pulse de la session graphique
        local u uid; u="$(session_user)"; uid="$(id -u "$u")"
        [ -S "/run/user/${uid}/pulse/native" ] \
            || die "pulse de session introuvable (/run/user/${uid}/pulse/native) - session audio demarree ? user=$u"
        if pactl_native list short modules 2>/dev/null | grep -q "protocol-tcp.*port=${TCP_PORT}"; then
            log "relai TCP deja actif (natif, user=$u) :${TCP_PORT}"; return 0
        fi
        pactl_native load-module module-native-protocol-tcp \
            "port=${TCP_PORT}" "auth-ip-acl=${TCP_ACL}" auth-anonymous=1 >/dev/null \
            || die "load module-native-protocol-tcp (natif)"
        log "relai TCP natif active (user=$u) :${TCP_PORT}"
    fi
}

# ── CONTENEUR : pont parec|paplay supervise vers le pulse de l'hote ──────────
container_bridge() {
    local name="$1" gw="${2:-}"
    [ -n "$name" ] || die "nom de conteneur requis"
    [ -z "$gw" ] && gw="$(detect_gw "$name")"
    [ -n "$gw" ] || die "gateway introuvable pour $name"
    docker exec -i "$name" sh -s -- "tcp:${gw}:${TCP_PORT}" <<'EOSH'
set -eu
RELAY="$1"
pactl info >/dev/null 2>&1 || { echo "  [host-audio][FAIL] pas de daemon pulse dans le conteneur" >&2; exit 1; }
# Le relai hote doit etre joignable
if ! pactl --server="$RELAY" info >/dev/null 2>&1; then
    echo "  [host-audio][FAIL] relai hote injoignable ($RELAY) - lancer 'host-relay' d'abord" >&2; exit 1
fi
# Stoppe un pont precedent (idempotent)
pkill -f "paplay --server=${RELAY}" 2>/dev/null || true
[ -f /run/host-audio.pid ] && kill -- "-$(cat /run/host-audio.pid)" 2>/dev/null || true
mkdir -p /var/log/osmocom
# Pont supervise : redemarre si parec/paplay tombe. setsid = nouveau groupe → kill propre.
setsid sh -c '
  while true; do
    parec -d gsm_audio.monitor --latency-msec=30 --format=s16le --rate=8000 --channels=1 \
      | paplay --server='"${RELAY}"' --latency-msec=250 --raw --format=s16le --rate=8000 --channels=1
    sleep 1
  done' >/var/log/osmocom/host-audio.log 2>&1 &
echo $! > /run/host-audio.pid
echo "  [host-audio] pont parec|paplay gsm_audio.monitor -> ${RELAY} (pgid $!)"
EOSH
}

# ── CONTENEUR : bip de test via gsm_audio (preuve bout-en-bout) ──────────────
container_test() {
    docker exec -i "$1" sh -s <<'EOSH'
set -eu
ffmpeg -y -hide_banner -loglevel error -f lavfi -i "sine=frequency=880:duration=1" -ar 8000 -ac 1 /tmp/host_test.wav
paplay -d gsm_audio /tmp/host_test.wav
echo "  [host-audio] bip 880Hz injecte dans gsm_audio -> hote"
EOSH
}

container_down() {
    docker exec -i "$1" sh -s <<'EOSH'
set -eu
[ -f /run/host-audio.pid ] && kill -- "-$(cat /run/host-audio.pid)" 2>/dev/null || true
pkill -f 'parec -d gsm_audio.monitor' 2>/dev/null || true
rm -f /run/host-audio.pid
echo "  [host-audio] pont arrete"
EOSH
}

cmd="${1:-}"; shift || true
case "$cmd" in
    host-relay) host_relay ;;
    host-mic)   host_mic ;;
    container)  container_bridge "${1:-}" "${2:-}" ;;
    test)       container_test "${1:-}" ;;
    down)       container_down "${1:-}" ;;
    all)        host_relay; host_mic; container_bridge "${1:-}" "${2:-}"; container_test "${1:-}" ;;
    *) echo "usage: $0 {host-relay|host-mic|container <name> [gw]|test <name>|down <name>|all <name> [gw]}" >&2; exit 2 ;;
esac

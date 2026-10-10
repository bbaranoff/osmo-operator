#!/bin/bash
# =============================================================================
# osmo-lte.sh - LA 4G DU BANC : Open5GS (le coeur), srsENB et srsUE sur la
# radio ZeroMQ, lances DANS L ORDRE ET DANS LES TEMPS.
#
# [2026-09-07] POURQUOI UN LANCEUR, alors que trois lignes de commande
# suffisent. Parce que les trois lignes ont deux pieges, et qu on est tombe
# dans les deux le meme jour :
#
#   1. « fail_on_disconnect=true » sur l eNB. C est l argument de la doc, et il
#      fait ce qu il dit : quand l eNB ne recoit AUCUN echantillon de l UE
#      pendant 2000 ms (ZMQ_TIMEOUT_MS, rf_zmq_imp_trx.h), sa radio S ARRETE.
#      Le processus reste, le S1 vers le coeur reste, mais plus rien ne sort
#      sur ZeroMQ - on l a mesure : une centaine d octets par sens, la poignee
#      de main ZMTP et rien d autre. Un srsUE lance UNE MINUTE apres l eNB
#      trouve donc une radio morte : « Attaching UE... » et jamais « Found
#      Cell ». Ici l UE part une demi-seconde apres l eNB.
#
#   2. Le SIB3. sib.conf programme les SIB emis par « si_mapping_info » ; en
#      y mettant [ 7 ] (le SIB7, la liste GERAN du CSFB) A LA PLACE de [ 3 ],
#      on a retire le SIB3. Or srsUE ne juge une cellule « convenable » QUE
#      s il a le SIB3 (srsue rrc.cc, cell_selection_criteria : has_sib3()) :
#      « Failed to configure serving cell », T3410 expire, cinq essais, rien.
#      Il faut [ 3, 7 ] - on le verifie avant de lancer.
#
# [2026-09-08] LE COEUR EST OPEN5GS, plus srsepc (tools/osmo-epc.sh : mongod,
# ogstun, les huit demons, le SGs vers OsmoMSC pour le CSFB). Le MME ecoute
# le S1 sur 127.0.0.2 - c est ce que dit enb.conf (mme_addr). Et le netns
# « ue1 » de l UE vit dans /run : il disparait au reboot, on le recree ici.
#
# LES CONFIGS SONT CELLES DU DEPOT (configs/srsran/*.conf, user_db.csv),
# posees dans ~/.config/srsran de root par tools/osmo-lte-install.sh. Elles
# portent la radio ZeroMQ (device_name / device_args : ports 2000/2001,
# base_srate 11.52e6) : on ne les redit PAS sur la ligne de commande, sauf
# OSMO_LTE_SRATE pour forcer une autre cadence. Les srs* sont lances DEPUIS
# ce repertoire : sib.conf / rr.conf / rb.conf y sont resolus, et le .ctxt
# (le contexte NAS que srsue sauve dans son cwd) y vit aussi.
#
#   osmo-lte start      coeur (osmo-epc), puis eNB, puis UE (refuse si l un tourne deja)
#   osmo-lte start-gui  LE MEME LANCEMENT, AVEC LES TRACES srsGUI a l ecran
#                       (constellation, spectre, PDSCH) : --gui.enable sur l eNB
#                       et l UE, et un DISPLAY. Jamais par systemd - une unite
#                       systeme n a pas d ecran ; c est un lancement direct.
#   osmo-lte stop       arrete eNB et UE (le coeur reste : « osmo-epc stop »)
#   osmo-lte restart    stop puis start
#   osmo-lte status     processus, S1, debit ZeroMQ, adresse de l UE
#   osmo-lte log        les journaux, en direct
#   osmo-lte toggle     L ICONE : le service osmo-lte (systemd) - le demarre s il
#                       est arrete, l arrete s il tourne (pkexec hors root)
#   osmo-lte up|down    le service, explicitement (Actions du clic droit)
#   osmo-lte journal    journalctl -u osmo-lte -f
#   osmo-lte install    pose les configs et les lanceurs (tools/osmo-lte-install.sh)
# =============================================================================
set -u

REPO="${OSMO_REPO:-/opt/GSM/osmo-operator}"
SRS_DIR="${OSMO_SRSRAN_DIR:-/root/.config/srsran}"
NETNS="${OSMO_LTE_NETNS:-ue1}"
ZMQ_ENB="${OSMO_ZMQ_PORT:-2000}"
ZMQ_UE="${OSMO_ZMQ_PORT_UE:-2001}"
SRATE="${OSMO_LTE_SRATE:-}"           # vide = ce que disent enb.conf / ue.conf
LOGDIR="${OSMO_LTE_LOGDIR:-/tmp}"
BUILD="${OSMO_SRSRAN_BUILD:-/opt/LTE/srsRAN_4G/build}"
EPC="${OSMO_EPC:-/usr/local/bin/osmo-epc}"
[ -x "$EPC" ] || EPC="$REPO/tools/osmo-epc.sh"
MME_S1="${OSMO_LTE_MME:-127.0.0.2}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
_say()  { echo -e "  ${CYAN}→${NC} $*"; }
_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
_warn() { echo -e "  ${YELLOW}!${NC} $*"; }
_err()  { echo -e "  ${RED}✗${NC} $*" >&2; }

_root() { [ "$(id -u)" -eq 0 ] && return 0; _err "il faut root (netns, tun, SCTP) : sudo $0 $*"; return 1; }

# [2026-09-08] LE GESTE DE L ICONE. La 4G vit dans services/osmo-lte.service
# (Open5GS + eNB + UE) ; l icone du bureau (data/desktop/osmo-lte.desktop)
# appelle « osmo-lte toggle » : un clic demarre, le suivant arrete. Depuis
# une session sans root, pkexec ouvre la fenetre de mot de passe (repli
# sudo) ; le resultat part en notification, il n y a pas de terminal.
SVC="${OSMO_LTE_SERVICE:-osmo-lte.service}"
ICONE=/usr/share/osmo-operator/icons/osmo-lte.svg
_notif() { command -v notify-send >/dev/null 2>&1 && notify-send -i "$ICONE" "4G du banc" "$1" 2>/dev/null || true; _say "$1"; }
_svc() {
    local act="$1" rc
    if [ "$act" = toggle ]; then
        case "$(systemctl is-active "$SVC" 2>/dev/null)" in active|activating) act=stop ;; *) act=start ;; esac
    fi
    [ "$act" = start ] && _notif "demarrage de la 4G (Open5GS, eNB, UE)... une trentaine de secondes"
    if [ "$(id -u)" -eq 0 ]; then systemctl "$act" "$SVC"; rc=$?
    elif command -v pkexec >/dev/null 2>&1; then pkexec systemctl "$act" "$SVC"; rc=$?
    else sudo systemctl "$act" "$SVC"; rc=$?; fi
    if [ "$rc" -eq 0 ]; then
        [ "$act" = start ] && _notif "4G en marche : UE attache dans $NETNS (osmo-lte status)" || _notif "4G arretee (eNB, UE et coeur)"
    else
        _notif "echec ($act, code $rc) - journalctl -u $SVC"
    fi
    return "$rc"
}

# ── LE MODE « AVEC TRACES » (srsGUI) ────────────────────────────────────────
# [2026-09-10] srsRAN est desormais compile avec ENABLE_GUI=ON (srsGUI, pose
# avant lui par tools/osmo-lte-install.sh) : srsenb et srsue SAVENT tracer leur
# constellation, leur spectre et leur PDSCH en temps reel. Ils ne le FONT que
# si on le demande - « [gui] enable » de enb.conf/ue.conf vaut false, et on ne
# le change pas : la 4G du banc demarre normalement par un service systemd, qui
# n a pas d ecran, et une fenetre Qt qui ne peut pas s ouvrir ferait echouer un
# demarrage qui marchait.
#
# D ou DEUX modes, et le mode normal reste EXACTEMENT ce qu il etait :
#     « start »      ce que fait le service, sans rien a l ecran
#     « start-gui »  le meme lancement + --gui.enable=1 sur les deux
#   (ces deux libelles ne commencent pas par « osmo-lte start » a dessein :
#    l aide du bas de fichier est un `sed` de plage sur ce motif, et une
#    seconde occurrence lui faisait recracher le script entier.)
# La seule difference dans lte_start est un tableau vide quand GUI=0.
GUI=0

# Qt a besoin d un serveur X et d un cookie. Le mode traces est lance depuis le
# bureau (icone, terminal de session) mais TOURNE EN ROOT : DISPLAY et
# XAUTHORITY ne suivent pas toujours (pkexec nettoie l environnement, sudo
# aussi selon env_reset). On les retrouve : le socket X du serveur en marche, et
# le cookie de la session graphique ACTIVE.
_display_ou_rien() {
    if [ -z "${DISPLAY:-}" ]; then
        local s n=""
        for s in /tmp/.X11-unix/X*; do
            [ -S "$s" ] || continue
            n="${s##*/X}"; break
        done
        [ -n "$n" ] || { _err "aucun serveur X (/tmp/.X11-unix vide) : le mode traces demande un ecran - « $0 start » sans traces"; return 1; }
        export DISPLAY=":$n"
        _say "DISPLAY absent : on prend $DISPLAY"
    fi
    if [ -z "${XAUTHORITY:-}" ] || [ ! -r "${XAUTHORITY:-}" ]; then
        local uid f
        uid="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$0 ~ / active / {print $2; exit}')"
        [ -n "$uid" ] || uid="$(loginctl list-sessions --no-legend 2>/dev/null | awk 'NR==1{print $2}')"
        for f in "/run/user/$uid/gdm/Xauthority" "/run/user/$uid/.Xauthority" \
                 "$(getent passwd "${uid:-0}" | cut -d: -f6)/.Xauthority"; do
            [ -n "$uid" ] || break
            [ -r "$f" ] && { export XAUTHORITY="$f"; break; }
        done
    fi
    # Qt suivrait WAYLAND_DISPLAY s il traine dans l environnement, et echouerait
    # en root sur le socket wayland de l utilisateur : on impose xcb.
    export QT_QPA_PLATFORM=xcb
    # Un srsenb qui n est pas lie a srsGUI accepte --gui.enable sans rien
    # afficher : on le dit plutot que de laisser chercher.
    local b
    b="$(_bin srsenb 2>/dev/null)"
    if [ -n "$b" ] && ! ldd "$b" 2>/dev/null | grep -q libsrsgui; then
        _warn "srsenb n est pas lie a srsGUI : aucune trace ne s affichera - « osmo-lte-install --build »"
    fi
    return 0
}

# Le mode traces se lance depuis la session, pas depuis systemd : c est donc
# LUI qui va chercher root, en emportant l ecran (meme geste que l icone du
# banc, launch/osmo-launch.sh : pkexec env DISPLAY=... XAUTHORITY=...).
_root_avec_display() {
    [ "$(id -u)" -eq 0 ] && return 0
    _display_ou_rien || return 1
    _say "elevation (pkexec) en gardant $DISPLAY"
    if command -v pkexec >/dev/null 2>&1; then
        exec pkexec /usr/bin/env DISPLAY="$DISPLAY" XAUTHORITY="${XAUTHORITY:-}" \
             QT_QPA_PLATFORM=xcb "$0" start-gui
    fi
    exec sudo DISPLAY="$DISPLAY" XAUTHORITY="${XAUTHORITY:-}" QT_QPA_PLATFORM=xcb "$0" start-gui
}

# Le binaire installe d abord, la compilation locale sinon.
_bin() {
    local n="$1"
    command -v "$n" 2>/dev/null && return 0
    for f in "$BUILD/srs${n#srs}/src/$n" "$BUILD/$n/src/$n"; do [ -x "$f" ] && { echo "$f"; return 0; }; done
    return 1
}

# Le SIB3 doit etre programme (piege n° 2 de l entete).
_verifier_sib() {
    local sib="$SRS_DIR/sib.conf"
    [ -f "$sib" ] || { _warn "pas de $sib : srsENB prendra ses valeurs par defaut"; return 0; }
    local map
    map="$(grep -oE 'si_mapping_info\s*=\s*\[[^]]*\]' "$sib" | head -1)"
    if [ -n "$map" ] && ! printf '%s' "$map" | grep -qE '\[\s*(3|[0-9]+\s*,\s*)*3(\s*,|\s*\])'; then
        _err "sib.conf : « $map » ne programme pas le SIB3 - srsUE ne s attachera jamais (il faut [ 3, 7 ])"
        return 1
    fi
    _ok "sib.conf : $map"
}

# Les configs : celles de ~/.config/srsran, sinon celles du depot, posees.
_configs() {
    [ -f "$SRS_DIR/enb.conf" ] && [ -f "$SRS_DIR/ue.conf" ] && return 0
    [ -d "$REPO/configs/srsran" ] || { _err "pas de configs srsRAN ($SRS_DIR, ni $REPO/configs/srsran)"; return 1; }
    mkdir -p "$SRS_DIR"
    cp -n "$REPO/configs/srsran/"* "$SRS_DIR/"
    _ok "configs srsRAN posees depuis le depot dans $SRS_DIR"
}

lte_tourne() { pgrep -x "$1" >/dev/null 2>&1; }

lte_start() {
    _root start || return 1
    local enb ue
    enb="$(_bin srsenb)" || { _err "srsenb introuvable (dpkg -i osmo-build-srsran, ou osmo-lte-install --build)"; return 1; }
    ue="$(_bin srsue)"   || { _err "srsue introuvable"; return 1; }
    for p in srsenb srsue; do
        lte_tourne "$p" && { _err "$p tourne deja (pid $(pgrep -x "$p" | head -1)) - « $0 restart » pour repartir propre"; return 1; }
    done
    _configs || return 1
    _verifier_sib || return 1
    ip netns list 2>/dev/null | grep -qw "$NETNS" || { ip netns add "$NETNS" && _ok "espace reseau $NETNS cree"; }

    # Le coeur : Open5GS, par osmo-epc (idempotent : ce qui tourne deja reste).
    "$EPC" start | sed 's/^/  /'
    for _ in $(seq 1 20); do ss -Sln 2>/dev/null | grep -q "$MME_S1:36412 " && break; sleep 0.25; done
    ss -Sln 2>/dev/null | grep -q "$MME_S1:36412 " && _ok "MME : S1 en ecoute sur $MME_S1" \
        || _warn "MME : le S1 n ecoute pas sur $MME_S1 (voir « osmo-epc status », osmo-epc log mme)"

    export HOME=/root                      # srs* lisent ~/.config/srsran : celui de root
    cd "$SRS_DIR" || return 1              # sib.conf & co. relatifs, et le .ctxt de srsue
    rm -f .ctxt                            # un vieux contexte fait echouer l attach apres un redemarrage du coeur

    # Les traces : rien du tout quand GUI=0 - le mode normal est intact.
    local -a gui_opt=()
    [ "$GUI" = 1 ] && gui_opt=(--gui.enable=1)
    local -a enb_rf=() ue_rf=()
    if [ -n "$SRATE" ]; then
        enb_rf=(--rf.device_name=zmq --rf.device_args="fail_on_disconnect=true,tx_port=tcp://*:$ZMQ_ENB,rx_port=tcp://localhost:$ZMQ_UE,id=enb,base_srate=$SRATE")
        ue_rf=(--rf.device_name=zmq --rf.device_args="tx_port=tcp://*:$ZMQ_UE,rx_port=tcp://localhost:$ZMQ_ENB,id=ue,base_srate=$SRATE")
    fi
    # L eNB, et l UE tout de suite derriere : voir le piege n° 1.
    setsid "$enb" "$SRS_DIR/enb.conf" "${enb_rf[@]}" "${gui_opt[@]}" \
        --log.filename="$LOGDIR/osmo-lte-enb.log" >"$LOGDIR/osmo-lte-enb.console" 2>&1 </dev/null &
    sleep 0.5
    setsid "$ue" "$SRS_DIR/ue.conf" "${ue_rf[@]}" "${gui_opt[@]}" \
        --gw.netns="$NETNS" --log.filename="$LOGDIR/osmo-lte-ue.log" >"$LOGDIR/osmo-lte-ue.console" 2>&1 </dev/null &
    _ok "srsENB puis srsUE lances (ZeroMQ $ZMQ_ENB/$ZMQ_UE, UE dans $NETNS${SRATE:+, base_srate $SRATE})${gui_opt:+ ${GREEN}avec les traces srsGUI sur $DISPLAY${NC}}"

    _say "attente de l attach (30 s max)..."
    local i ip
    for i in $(seq 1 60); do
        ip="$(ip -n "$NETNS" -4 -o addr show 2>/dev/null | awk '/tun_srsue/ {print $4}')"
        [ -n "$ip" ] && break
        sleep 0.5
    done
    if [ -n "$ip" ]; then
        _ok "UE attache : $ip (tun_srsue dans $NETNS) en $((i / 2)) s"
    else
        _err "pas d attach en 30 s - voir $LOGDIR/osmo-lte-ue.console et « $0 status »"
        grep -E "Found|Attach|fail|Reject" "$LOGDIR/osmo-lte-ue.console" | tail -4 | sed 's/^/      /'
        return 1
    fi
}

lte_stop() {
    _root stop || return 1
    local p n=0
    for p in srsue srsenb; do
        if lte_tourne "$p"; then pkill -x "$p"; n=$((n + 1)); fi
    done
    sleep 2
    for p in srsue srsenb; do lte_tourne "$p" && pkill -9 -x "$p"; done
    [ "$n" -gt 0 ] && _ok "$n processus srs* arrete(s)" || _say "rien ne tournait"
    # Le S1 met un instant a se refermer cote SCTP ; l eNB suivant en a besoin.
    sleep 1
}

lte_status() {
    echo -e "\033[1msrsRAN sur ZeroMQ + Open5GS - la 4G du banc\033[0m"
    local p
    for p in open5gs-mmed srsenb srsue; do
        lte_tourne "$p" && _ok "$p : pid $(pgrep -x "$p" | head -1)" || _warn "$p : arrete"
    done
    ss -San 2>/dev/null | grep -q "ESTAB.*:36412" && _ok "S1 : eNB associe au MME" || _warn "S1 : pas d association eNB-MME"
    # Les echantillons eNB -> UE partent de la douille locale :$ZMQ_ENB de
    # l eNB (bytes_sent) ; ce qu elle RECOIT n est que les requetes de l UE.
    local a b
    a="$(ss -tin state established "( sport = :$ZMQ_ENB )" 2>/dev/null | grep -oE "bytes_sent:[0-9]+" | head -1 | cut -d: -f2)"
    if [ -n "$a" ]; then
        sleep 1
        b="$(ss -tin state established "( sport = :$ZMQ_ENB )" 2>/dev/null | grep -oE "bytes_sent:[0-9]+" | head -1 | cut -d: -f2)"
        local ko=$(( (${b:-0} - a) / 1024 ))
        if [ "$ko" -gt 100 ]; then _ok "ZeroMQ : $ko Ko/s d echantillons eNB -> UE"
        else _warn "ZeroMQ : $ko Ko/s - la radio de l eNB est morte (fail_on_disconnect) : « $0 restart »"; fi
    else
        _warn "ZeroMQ : aucun lien eNB <-> UE"
    fi
    local ip
    ip="$(ip -n "$NETNS" -4 -o addr show 2>/dev/null | awk '/tun_srsue/ {print $4}')"
    [ -n "$ip" ] && _ok "UE : attache, $ip dans $NETNS" || _warn "UE : pas attache (pas de tun_srsue dans $NETNS)"
}

case "${1:-status}" in
    start)   lte_start ;;
    start-gui|gui|start-display)
        # Le mode traces : root AVEC l ecran, puis le lancement normal + GUI=1.
        _root_avec_display || exit 1
        _display_ou_rien || exit 1
        GUI=1
        lte_start ;;
    stop)    lte_stop ;;
    restart) lte_stop; lte_start ;;
    status)  lte_status ;;
    log)     exec tail -F "$LOGDIR"/osmo-lte-{enb,ue}.console ;;
    toggle|bascule) _svc toggle ;;
    up)      _svc start ;;
    down)    _svc stop ;;
    journal) exec journalctl -u "$SVC" -f --no-pager ;;
    install) shift; exec bash "$REPO/tools/osmo-lte-install.sh" "$@" ;;
    *)       sed -n '/^#   osmo-lte start/,/^#   osmo-lte install/p' "$0" | sed 's/^# \{0,2\}//'; exit 2 ;;
esac

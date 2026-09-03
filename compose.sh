#!/bin/bash
# =============================================================================
#  compose.sh - le banc en docker compose v2 : images, hub + un operateur
# =============================================================================
#
#    sudo ./compose.sh build [--no-cache] [--lite] [--stp]   les images (= build.sh)
#    sudo ./compose.sh up [--ms N] [--phy faketrx|virtphy|qemu] [--no-run]
#    sudo ./compose.sh down          arrete et retire hub + operateur (configs gardees)
#    sudo ./compose.sh ps | logs [service] | shell
#    sudo ./compose.sh debs          le cache .deb de l hote (/var/cache/osmo-debs)
#
#  `up` fait ce que start.sh fait pour UN operateur, avec compose.yaml comme
#  description du banc :
#    1. les configs (apply_config_templates de generate_configs.sh, la config
#       du hub par helpers/create_interop.sh) dans data/compose/ ;
#    2. data/compose/.env : les adresses calculees par les memes fonctions que
#       start.sh (op_backbone_ip, op_private_*), les choix (N_MS, PHY_MODE) ;
#    3. data/compose/compose.audio.yaml : le socket PulseAudio de l hote et
#       /dev/snd, quand ils existent (compose ne sait pas les rendre optionnels) ;
#    4. docker compose --profile bench up -d ;
#    5. run.sh dans le conteneur, attente du HLR, abonnes de test dans le HLR
#       (memes IMSI / MSISDN <noeud>00<op><ms> / Ki que start.sh).
#  Pour N operateurs, le WAN, les ports publies : start.sh.
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$DIR"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

CDIR="${OSMO_COMPOSE_DIR:-$DIR/data/compose}"
FILES=(-f "$DIR/compose.yaml")

usage() { sed -n '2,24p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit "${1:-0}"; }
die() { echo -e "${RED}$*${NC}" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "Root requis (sudo)."; }
need_compose() {
    docker compose version >/dev/null 2>&1 \
        || die "docker compose v2 absent : sudo ./build.sh l installe (docker-compose-v2 + docker-buildx)."
}

# La bibliotheque de start.sh : ses fonctions (op_*, apply_config_templates...)
# sans son execution - meme decoupe que build-iso.sh (load_start_lib).
load_start_lib() {
    local lib; lib="$(mktemp)"
    awk '
        /^banner[[:space:]]*$/                    { exit }
        /^\[ "\$\{1:-\}" = "stop" \]/             { exit }
        /^\[ "\$\(id -u\)" -ne 0 \]/              { exit }
        /^choose_network_mode[[:space:]]*$/       { exit }
        /^\.\//                                   { exit }
        /^case "\$NETWORK_MODE" in[[:space:]]*$/  { exit }
        { print }
    ' "$DIR/start.sh" > "$lib"
    export OSMO_REPO_DIR="$DIR"
    # shellcheck disable=SC1090
    source "$lib"
    rm -f "$lib"
}

compose() {
    local envf=()
    [ -f "$CDIR/.env" ] && envf=(--env-file "$CDIR/.env")
    [ -f "$CDIR/compose.audio.yaml" ] && FILES+=(-f "$CDIR/compose.audio.yaml")
    docker compose "${FILES[@]}" "${envf[@]+"${envf[@]}"}" "$@"
}

cmd_build() { need_root; exec bash "$DIR/build.sh" "$@"; }

cmd_up() {
    need_root; need_compose
    local n_ms=2 phy="${PHY_MODE:-faketrx}" do_run=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --ms)     n_ms="${2:?}"; shift ;;
            --ms=*)   n_ms="${1#*=}" ;;
            --phy)    phy="${2:?}"; shift ;;
            --phy=*)  phy="${1#*=}" ;;
            --no-run) do_run=0 ;;
            -h|--help) usage 0 ;;
            *) die "option inconnue : $1" ;;
        esac; shift
    done
    [[ "$n_ms" =~ ^[1-9][0-9]?$ ]] || die "--ms : 1 a 99"

    for img in "${IMAGE_RUN:-osmocom-run}" "${IMAGE_STP:-osmocom-stp}"; do
        docker image inspect "$img" >/dev/null 2>&1 \
            || die "image $img absente : sudo ./compose.sh build --stp (ou ./build.sh --stp, puis ./start.sh une fois pour osmocom-run)"
    done

    load_start_lib
    export OSMO_PRIV_BY_OP=1      # on provisionne PAR operateur (voir _osmo_priv_index)
    local op=1 node="${WAN_NODE_ID:-1}"
    local bb_ip priv_net priv_gw priv_ip mcc mnc name
    bb_ip="$(op_backbone_ip "$op")"
    priv_net="$(op_private_net "$op")"; priv_gw="$(op_private_gw "$op")"; priv_ip="$(op_private_ip "$op")"
    mcc="$(op_mcc "$op")"; mnc="$(op_mnc "$op")"; name="$(op_default_name "$op")"

    echo -e "${CYAN}── Banc compose : hub 172.20.0.10 + operateur ${op} (${name}, MCC ${mcc} MNC ${mnc}, ${n_ms} MS, PHY ${phy}) ──${NC}"
    echo -e "  backbone ${CYAN}${bb_ip}${NC}   prive ${CYAN}${priv_ip}${NC} (${priv_net})"

    # 1. Les configs
    rm -rf "$CDIR/op1" "$CDIR/hub"
    mkdir -p "$CDIR/op1/osmocom" "$CDIR/op1/asterisk" "$CDIR/op1/bb" "$CDIR/hub"
    apply_config_templates "$CDIR/op1" "$priv_ip" "$priv_gw" "$op" \
        "1.${op}.1" "1.${op}.2" "1.${op}.3" "$mcc" "$mnc" "$name" \
        172.20.0.10 "no shutdown" 1 \
        || die "generation des configs echouee"
    bash "$DIR/helpers/create_interop.sh" 1 "$CDIR/hub/osmo-stp-interop.cfg" >/dev/null \
        || die "generation de la config du hub echouee"
    for f in extensions.conf pjsip.conf rtp.conf modules.conf annuaire.conf; do
        [ -f "$CDIR/op1/asterisk/$f" ] || { [ -f "$DIR/configs/$f" ] && cp "$DIR/configs/$f" "$CDIR/op1/asterisk/$f" || : > "$CDIR/op1/asterisk/$f"; }
    done
    [ -f "$CDIR/op1/bb/mobile.cfg" ] || cp "$DIR/configs/mobile.cfg" "$CDIR/op1/bb/mobile.cfg"
    cp -f "$DIR/configs/asound.conf" "$CDIR/asound.conf"
    chmod +x "$CDIR/op1/osmocom"/*.sh 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} configs dans ${CDIR}"

    # 2. .env : ce que compose.yaml lit
    local host_ip; host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)"
    cat > "$CDIR/.env" <<ENV
# genere par compose.sh up - ne pas editer : relancer compose.sh up
IMAGE_RUN=${IMAGE_RUN:-osmocom-run}
IMAGE_STP=${IMAGE_STP:-osmocom-stp}
OSMO_COMPOSE_DIR=${CDIR}
OP1_BACKBONE_IP=${bb_ip}
OP1_PRIV_NET=${priv_net}
OP1_PRIV_GW=${priv_gw}
OP1_PRIV_IP=${priv_ip}
N_MS=${n_ms}
PHY_MODE=${phy}
HOST_IP=${host_ip}
WAN_NODE_ID=${node}
ENV

    # 3. L audio de l hote : socket pulse et /dev/snd quand ils existent
    local pa=""
    for s in /var/run/pulse/native /run/pulse/native "/run/user/${SUDO_UID:-$(id -u)}/pulse/native"; do
        [ -S "$s" ] && { pa="$s"; break; }
    done
    {
        echo "# genere par compose.sh up : l audio de l hote, quand il existe"
        echo "services:"
        echo "  operator-1:"
        if [ -n "$pa" ]; then
            echo "    volumes:"; echo "      - ${pa}:/run/pulse/native"
            echo "    environment:"; echo "      PULSE_SERVER: unix:/run/pulse/native"
        fi
        if [ -d /dev/snd ]; then
            echo "    devices:"; echo "      - /dev/snd:/dev/snd"
            getent group audio >/dev/null 2>&1 && { echo "    group_add:"; echo "      - \"$(getent group audio | cut -d: -f3)\""; }
        fi
    } > "$CDIR/compose.audio.yaml"
    [ -n "$pa" ] && echo -e "  ${GREEN}✓${NC} audio : socket pulse ${pa}" \
                 || echo -e "  ${YELLOW}audio : pas de socket pulse sur l hote - repli TCP 172.20.0.1:4713${NC}"

    # 4. Les conteneurs
    modprobe sctp 2>/dev/null || true; modprobe tun 2>/dev/null || true
    mkdir -p /tmp/osmocom-logs/op1
    compose --profile bench up -d --remove-orphans
    echo -e "  ${GREEN}✓${NC} osmo-inter-stp et osmo-operator-1 lances"
    [ "$do_run" = 1 ] || { echo "  (--no-run : run.sh non lance - docker exec -ti osmo-operator-1 bash)"; return 0; }

    # 5. La pile, puis les abonnes
    echo -e "  ${GREEN}[*] run.sh dans osmo-operator-1...${NC}"
    docker exec -d osmo-operator-1 bash -c \
        "mkdir -p /var/log/osmocom && { RUN_NO_PROCESS=0 CALYPSO_NO_ATTACH=1 /etc/osmocom/run.sh; } > /var/log/osmocom/run.sh.log 2>&1"
    echo -ne "  ${GREEN}[*] Attente HLR (4258)${NC}"
    local retry=0
    while ! docker exec osmo-operator-1 bash -c "echo >/dev/tcp/127.0.0.1/4258" 2>/dev/null; do
        sleep 2; echo -n "."; retry=$((retry + 1))
        [ $retry -ge 45 ] && { echo -e " ${RED}TIMEOUT${NC}"; break; }
    done
    echo -e " ${GREEN}✓${NC}"
    local ms imsi msisdn ki feed
    feed="$(mktemp)"
    echo "enable" > "$feed"
    for ms in $(seq 1 "$n_ms"); do
        imsi="${mcc}${mnc}$(printf '%04d%06d' "$op" "$ms")"
        msisdn="$(osmo_msisdn "$node" "$op" "$ms")"
        ki="$(printf '00112233445566778899aabbccdd%02x%02x' "$ms" "$op")"
        printf 'subscriber imsi %s create\nsubscriber imsi %s update msisdn %s\nsubscriber imsi %s update aud2g comp128v1 ki %s\n' \
            "$imsi" "$imsi" "$msisdn" "$imsi" "$ki" >> "$feed"
        echo "    MS${ms} : IMSI ${imsi}  MSISDN ${msisdn}"
    done
    echo "end" >> "$feed"
    docker cp "$feed" osmo-operator-1:/tmp/hlr_feed.vty; rm -f "$feed"
    docker exec osmo-operator-1 bash -c '(sleep 1; cat /tmp/hlr_feed.vty; sleep 2) | nc -q2 127.0.0.1 4258 >/dev/null 2>&1; rm -f /tmp/hlr_feed.vty' || true
    echo -e "  ${GREEN}✓${NC} HLR alimente (${n_ms} abonnes)"
    echo ""
    echo -e "${GREEN}Banc pret.${NC}  docker exec -ti osmo-operator-1 bash   |   ./compose.sh logs   |   ./compose.sh down"
}

cmd_down()  { need_root; need_compose; compose --profile bench down --remove-orphans; }
cmd_ps()    { need_compose; compose --profile bench ps; }
cmd_logs()  { need_compose; compose --profile bench logs -f "$@"; }
cmd_shell() { exec docker exec -ti "${1:-osmo-operator-1}" bash; }
cmd_debs()  { ls -1sh "${OSMO_DEB_CACHE:-/var/cache/osmo-debs}"/osmo-build-*.deb 2>/dev/null || echo "cache vide (${OSMO_DEB_CACHE:-/var/cache/osmo-debs})"; }

case "${1:-}" in
    build) shift; cmd_build "$@" ;;
    up)    shift; cmd_up "$@" ;;
    down)  shift; cmd_down ;;
    ps)    cmd_ps ;;
    logs)  shift; cmd_logs "$@" ;;
    shell) shift; cmd_shell "$@" ;;
    debs)  cmd_debs ;;
    -h|--help|help|'') usage 0 ;;
    *) die "commande inconnue : $1 (build|up|down|ps|logs|shell|debs)" ;;
esac

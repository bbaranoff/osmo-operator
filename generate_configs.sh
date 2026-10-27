#!/usr/bin/env bash
# =============================================================================
#  generate_configs.sh - the ONLY place where the network configuration is
#                        decided, and the only one that substitutes templates.
# =============================================================================
#
#  HOW IT WORKS
#  ------------
#  The files under configs/ carry markers (__MCC__, __ARFCN__, __KI__, ...)
#  that apply_config_templates() replaces at start-up. The derivation
#  formulas (ARFCN, BSIC, IMSI, IMEI, Ki...) are only DEFAULTS: globals.conf,
#  at the repository root, exposes them all and wins.
#
#  TWO USAGES
#  ----------
#    ./generate_configs.sh [--force] [--show] [KEY=VALUE ...]
#         writes/completes globals.conf at the root, then prints the
#         effective values. Without --force an existing globals.conf is
#         NEVER overwritten.
#
#    . ./generate_configs.sh
#         loads globals.conf and defines apply_config_templates() and
#         apply_native_post_patches().
#
#  WHO CALLS WHAT
#  --------------
#    launch/start-docker.sh  -> runs this script (writes globals.conf), then
#                               sources it
#    start-native.sh         -> sources globals.conf
#    lib/gabarits.sh         -> sources this script for apply_config_templates()
#    iso_modules/30-image-configs.sh, startup_scripts/11-regen-configs.sh
#                            -> apply_native_post_patches() on a generated tree
#
#  PRECEDENCE
#  ----------
#    command line / environment  >  globals.conf  >  defaults of _gc_table
#
#  MULTI-OPERATOR
#  --------------
#  In `virtual` mode (N_OPERATORS > 1) each operator needs DISTINCT values.
#  A value set in globals.conf applies to ALL of them, which is almost always
#  wrong for ARFCN, LAC, IMSI... Leave them empty (the default) to keep the
#  per-operator derivation and pin only what you really want pinned. The
#  script warns when a per-operator field is pinned with N_OPERATORS > 1.
#
#  ENVIRONMENT
#  -----------
#    OSMO_NO_REGEN=1    keep the installed configs (start-native.sh default;
#                       --regen clears it)
#    OSMO_NO_STP_IP=1   skip the node SS7 addressing (network/set-node-id.sh)
#    OSMO_WAN_NODE, WAN_NODE_ID, ROLE_FILE (/etc/osmo-role): node number
#    OSMO_ROLE, OSMO_HUB_IP, WAN_STP_TARGET, INTER_STP_IP: WAN node identity
#    SAP_MODE=1         mobile.cfg uses "sim sap" instead of "sim test"
#    RCTX_INTER_OVERRIDE, INTER_LOCAL_IP_OVERRIDE, SIP_REMOTE_IP_OVERRIDE:
#                       set by the ISO build / --regen for a WAN node
#    WAN_CONF_FILE      WAN table (default /etc/osmo-wan.conf)
#
#  SPDX-License-Identifier: GPL-2.0-or-later
# =============================================================================

_GC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GC_FILE="$_GC_HERE/globals.conf"

# ── Exposed settings, with their default ─────────────────────────────────────
# Format: KEY|DEFAULT|PER-OP|COMMENT
#   PER-OP=1 -> the value is normally derived from the operator number;
#               pinning it only makes sense with a single operator.
#
# The body of _gc_table is a TABLE, not shell: the only non-data line allowed
# is "#SECTION|<title>". A plain "#" line there becomes a malformed entry, so
# explanations go HERE, above the function.
#
# Known limitation: the mobile emulated under QEMU does not decipher A5/1 yet
# (the cipher path of hw/arm/calypso/l1ctl_sock.c is not exercised), so with
# the default ENCRYPTION="a5 1" its Location Update stops after CIPHERING
# MODE COMPLETE (T3210). The osmocom-bb side-car handles A5/1 fine.
# Work-around: ENCRYPTION="a5 0" on the command line.
_gc_table() {
cat <<'TABLE'
#SECTION|Identite du reseau
MCC|001|0|Mobile Country Code (3 chiffres)
MNC|01|0|Mobile Network Code (2 chiffres)
OP_NAME|OsmoQEMU|0|Nom court et long du reseau
#SECTION|Securite et carte SIM
ENCRYPTION|a5 1|0|Chiffrement : "a5 1" (defaut), "a5 0" (aucun), "a5 0 1 3"...
SIM_ALGO|comp128|0|Algorithme d'authentification (comp128, xor...)
KI||1|Ki de la SIM, 16 octets hexa espaces
IMSI||1|IMSI du mobile
IMEI||1|IMEI du mobile
#SECTION|Radio
ARFCN||1|Canal radio (a accorder avec BAND)
BAND|DCS1800|0|Bande : GSM900, DCS1800, PCS1900, GSM850
BSIC||1|Base Station Identity Code, 0..63
LAC||1|Location Area Code
CELL_ID||1|Cell identity
IPA_UNIT_ID||1|Identifiant IPA du BTS
MS_MAX_POWER|15|0|Puissance max autorisee au mobile (0..15)
RXLEV_ACCESS_MIN|0|0|Niveau recu minimal pour acceder a la cellule
CELL_RESEL_HYST|4|0|Hysteresis de reselection de cellule (dB)
T3109|5|0|Timer T3109 du BSC (s) - liberation de canal
#SECTION|GPRS
BVCI||1|BSSGP Virtual Connection Id
NSEI||1|Network Service Entity Id
NSVCI||1|NS Virtual Connection Id
APN|internet|0|Nom du point d'acces
#SECTION|Services
SMS_SC||1|Numero du centre SMS
#SECTION|Dimensionnement
MS_COUNT|2|0|Nombre de mobiles simules
N_OPERATORS|1|0|Nombre d'operateurs (mode "virtual")
HOST_IP|127.0.0.1|0|Adresse de l'hote vue par la pile
TABLE
}

# ── Write globals.conf ───────────────────────────────────────────────────────
_gc_write() {
    local force=$1
    if [ -f "$_GC_FILE" ] && [ "$force" != "1" ]; then
        printf '  globals.conf existe deja - conserve (--force pour regenerer)\n'
        return 0
    fi
    {
        printf '# ═══════════════════════════════════════════════════════════════\n'
        printf '#  globals.conf - la configuration du reseau, en un seul endroit.\n'
        printf '# ═══════════════════════════════════════════════════════════════\n'
        printf '#\n'
        printf '#  Edite ce fichier a la main : il ne sera JAMAIS reecrit par un run.\n'
        printf '#  Seul "./generate_configs.sh --force" le regenere.\n'
        printf '#\n'
        printf '#  CE FICHIER FAIT AUTORITE - SUR LES VARIABLES QU'"'"'IL DECLARE, ET SUR\n'
        printf '#  ELLES SEULES. Il est lu en dernier : les %s reglages ci-dessous\n' "$(_gc_table | grep -vc '^#SECTION')"
        printf '#  ecrasent leur homonyme dans l'"'"'environnement. Tout le reste (CALYPSO_*,\n'
        printf '#  LOG_DIR, MODE...) passe au travers, intact. Deux facons de le modifier :\n'
        printf '#      vim globals.conf\n'
        printf '#      ./generate_configs.sh ARFCN=520\n'
        printf '#\n'
        printf '#  Un champ VIDE = valeur calculee automatiquement. Les champs notes\n'
        printf '#  [auto/operateur] se deduisent du numero d'"'"'operateur : ne les fige\n'
        printf '#  que si N_OPERATORS=1, sinon tous les operateurs se marchent dessus.\n'
        printf '# ═══════════════════════════════════════════════════════════════\n'
        local key def perop comment
        while IFS='|' read -r key def perop comment; do
            [ -n "$key" ] || continue
            if [ "$key" = "#SECTION" ]; then
                printf '\n# ── %s %s\n\n' "$def" \
                    "$(printf '%.0s─' $(seq 1 $((56 - ${#def}))))"
                continue
            fi
            printf '# %s%s\n' "$comment" \
                "$([ "$perop" = 1 ] && printf '  [auto/operateur]')"
            case "$def" in
                *" "*|"") printf '%s="%s"\n' "$key" "$def" ;;
                *)        printf '%s=%s\n'   "$key" "$def" ;;
            esac
        done < <(_gc_table)
    } > "$_GC_FILE"
    printf '  globals.conf ecrit (%s reglages)\n' \
           "$(_gc_table | grep -vc '^#SECTION')"
}

# ── Set one value IN the file, in place, keeping the layout ──────────────────
_gc_set() {
    local key="${1%%=*}" val="${1#*=}"
    _gc_table | grep -q "^${key}|" || {
        printf '  ⚠ reglage inconnu : %s (voir --show)\n' "$key" >&2; return 1; }
    [ -f "$_GC_FILE" ] || _gc_write 1 >/dev/null
    local q; case "$val" in *" "*|"") q="\"$val\"" ;; *) q="$val" ;; esac
    if grep -qE "^${key}=" "$_GC_FILE"; then
        sed -i "s|^${key}=.*|${key}=${q}|" "$_GC_FILE"
    else
        printf '%s=%s\n' "$key" "$q" >> "$_GC_FILE"
    fi
    printf '  %s = %s\n' "$key" "${val:-(auto)}"
}

# ── Loading ──────────────────────────────────────────────────────────────────
# Loads globals.conf, then COMPLETES it with the table defaults. Precedence:
#     command line / environment  >  globals.conf  >  default of _gc_table
# globals.conf assigns unconditionally, so the keys already present in the
# environment are saved BEFORE sourcing it and restored AFTER. Any key still
# empty then receives its factory default: an absent globals.conf (fresh
# clone, the file is gitignored) must never leave BAND, SIM_ALGO, APN...
# empty in the substituted configs, or osmo-bsc refuses to start.
gc_load() {
    local key def perop comment
    local -A _gc_env=()
    while IFS='|' read -r key def perop comment; do
        [ -n "$key" ] && [ "$key" != "#SECTION" ] || continue
        if [ -n "${!key:-}" ]; then _gc_env["$key"]="${!key}"; fi
    done < <(_gc_table)

    [ -f "$_GC_FILE" ] && . "$_GC_FILE"

    if [ "${#_gc_env[@]}" -gt 0 ]; then
        for key in "${!_gc_env[@]}"; do printf -v "$key" '%s' "${_gc_env[$key]}"; done
    fi

    while IFS='|' read -r key def perop comment; do
        [ -n "$key" ] && [ "$key" != "#SECTION" ] || continue
        [ -n "${!key:-}" ] || printf -v "$key" '%s' "$def"
    done < <(_gc_table)
    return 0
}

# ── Random IMEI with its Luhn check digit ────────────────────────────────────
# Plausible TAC (35892500) + six random serial digits + Luhn digit, so that
# two benches, or two MS of the same operator, never share an IMEI and the
# value passes the check of equipment that validates it.
rand_imei() {
    local body d i sum=0 dbl parity
    body="35892500$(printf '%06d' "$(( (RANDOM << 15 | RANDOM) % 1000000 ))")"
    # Luhn over the 14 digits: double every second digit from the right,
    # folding two-digit results.
    for (( i = ${#body} - 1; i >= 0; i-- )); do
        d=${body:i:1}
        parity=$(( (${#body} - 1 - i) % 2 ))
        if [ "$parity" -eq 0 ]; then
            dbl=$(( d * 2 )); [ "$dbl" -gt 9 ] && dbl=$(( dbl - 9 ))
            sum=$(( sum + dbl ))
        else
            sum=$(( sum + d ))
        fi
    done
    printf '%s%d' "$body" "$(( (10 - sum % 10) % 10 ))"
}

# ── THE NUMBERING PLAN, IN ONE PLACE ─────────────────────────────────────────
#
#   MSISDN = <node> 00 <operator> <MS rank on 2 digits>
#            node 1, operator 1, MS 1  ->  100101
#            node 1, operator 1, MS 2  ->  100102
#            node 2, operator 1, MS 1  ->  200101
#
# The leading digit is the node address, so SMS and dialplan routing can be
# read directly from the number on a multi-node bench.
#
# Invariant: the IMSI (MCC MNC <op on 4 digits> <ms on 6>) and the Ki
# (00 11 ... dd <ms> <op>) do NOT depend on the node. They are derived
# identically here (mobile.cfg), in start-native.sh (mobiles) and in
# launch/start-docker.sh (HLR subscribers) and must stay bit-identical,
# otherwise authentication fails on a Kc mismatch with no trace other than a
# CIPHER MODE reject. Only the MSISDN, which enters no security computation,
# carries the node.
osmo_msisdn_pfx() { printf '%s00' "${1:-1}"; }                       # <node>00
osmo_msisdn()     { printf '%d' "$(( ${1:-1} * 100000 + ${2:-1} * 100 + ${3:-1} ))"; }

# The node as seen by the generator: environment first (what
# launch/start-docker.sh passes to a container and what start-native.sh
# exports before a --regen), then /etc/osmo-role, then 1. NEVER empty: a
# numbering plan without a node is everybody's plan.
osmo_node_id() {
    local n="${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}"
    if [ -z "$n" ] && [ -r "${ROLE_FILE:-/etc/osmo-role}" ]; then
        n="$(awk -F= '/^OSMO_WAN_NODE=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' \
             "${ROLE_FILE:-/etc/osmo-role}" 2>/dev/null)"
    fi
    case "$n" in [1-9]) ;; *) n=1 ;; esac
    printf '%s' "$n"
}

# ── Template substitution - the SINGLE implementation ────────────────────────
#  Signature shared by all callers:
#    apply_config_templates DEST CONTAINER_IP GATEWAY_IP OP_ID \
#                           PC_MSC PC_STP PC_BSC MCC MNC OP_NAME \
#                           INTER_STP INTER_STP_SHUTDOWN N_OPERATORS
#  Writes DEST/osmocom, DEST/asterisk and DEST/bb from configs/ and scripts/,
#  then DEST/osmocom/radio-plan.env (the decided radio plan and PLMN, read by
#  start-native.sh for the mobiles and the side-car) and sms-routing.conf.
apply_config_templates() {
    local dest=$1 container_ip=$2 gateway_ip=$3 op_id=$4

    # OSMO_NO_REGEN=1: keep the configs already in place. In a container they
    # were just generated by launch/start-docker.sh with the node identity,
    # point codes and inter-STP; regenerating from the templates would replace
    # them with the single-machine defaults. start-native.sh sets it by
    # default, --regen clears it.
    if [ "${OSMO_NO_REGEN:-0}" = "1" ]; then
        echo "  gabarits : conserves (OSMO_NO_REGEN=1 ; --regen pour regenerer)"
        return 0
    fi
    local pc_msc=$5 pc_stp=$6 pc_bsc=$7 mcc=$8 mnc=$9 op_name=${10}

    # PLMN check before writing anything: osmo-msc refuses "network country
    # code 000" (an empty MCC gives 000 through printf), exits, and systemd
    # restarts it endlessly. Fail HERE, where the parameter name is known.
    case "$mcc" in
        ''|000|00|0) echo "  ERREUR : MCC invalide ('$mcc') pour l'operateur $op_id - osmo-msc refuserait la config" >&2; return 1 ;;
    esac
    case "$mnc" in
        ''|'-') echo "  ERREUR : MNC vide pour l'operateur $op_id" >&2; return 1 ;;
    esac
    local inter_stp=${11} inter_stp_shutdown=${12} n_operators=${13}

    # The node enters the numbering plan (MSISDN = <node>00<op><ms>), NOT the
    # IMSI nor the Ki (see osmo_msisdn).
    local node msisdn_pfx
    node="$(osmo_node_id)"
    msisdn_pfx="$(osmo_msisdn_pfx "$node")"

    mkdir -p "$dest/osmocom" "$dest/asterisk" "$dest/bb"
    local f bn

    for f in configs/*.cfg; do
        [ "$(basename "$f")" = "osmo-stp-interop.cfg" ] && continue
        cp "$f" "$dest/osmocom/"
    done
    [ -f "configs/osmo-bts-virtual.cfg" ] && cp "configs/osmo-bts-virtual.cfg" "$dest/osmocom/"
    for f in configs/*.conf; do
        bn=$(basename "$f"); [ "$bn" = "sms-routing.conf" ] && continue
        cp "$f" "$dest/asterisk/"
    done
    # scripts/ as a whole, so that a script added later is never silently
    # left out.
    cp scripts/* "$dest/osmocom/" 2>/dev/null || true
    chmod +x "$dest/osmocom"/*.sh 2>/dev/null || true

    if [ -f "configs/mobile.cfg.template" ]; then
        cp "configs/mobile.cfg.template" "$dest/bb/mobile.cfg"
        cp "configs/mobile.cfg.template" "$dest/bb/mobile_group1.cfg"
    elif [ -f "configs/mobile.cfg" ]; then
        cp "configs/mobile.cfg" "$dest/bb/mobile.cfg"
        cp "configs/mobile.cfg" "$dest/bb/mobile_group1.cfg"
    fi
    # The SIM mode of the template follows --sap: "sim sap" only when
    # SAP_MODE=1 (set by --sap / --softsim in startup_scripts/01-defauts-options.sh),
    # "sim test" otherwise. Same rule as ms_sim_mode in
    # startup_scripts/06-banc-dsp-menu.sh; containers, without softSIM, stay
    # in "sim test".
    local _sim=test _f
    [ "${SAP_MODE:-0}" = 1 ] && _sim=sap
    for _f in "$dest/bb/mobile.cfg" "$dest/bb/mobile_group1.cfg"; do
        [ -f "$_f" ] && sed -i "s#^\([[:space:]]*\)sim \(sap\|test\|reader\)\$#\1sim ${_sim}#" "$_f"
    done

    local rctx_msc rctx_stp rctx_bsc rctx_inter
    rctx_msc=$(op_rctx_msc "$op_id");   rctx_stp=$(op_rctx_stp "$op_id")
    rctx_bsc=$(op_rctx_bsc "$op_id")
    # RCTX_INTER_OVERRIDE: set when the image is a WAN NODE. The routing
    # context identifies the AS at the hub, and the local formula (op*100+50)
    # gives the same value on every node. Empty = local formula.
    rctx_inter="${RCTX_INTER_OVERRIDE:-$(op_rctx_inter "$op_id")}"

    # ── The values: globals.conf wins, otherwise the default formula ─────────
    local arfcn="${ARFCN:-$(( 512 + op_id * 2 ))}"
    # The SECOND BTS (the side-car) needs its own channel: +100 keeps the
    # side-cars (614, 616, 618...) out of reach of the main plan (514, 516,
    # 518...) and inside the DCS1800 band (512-885). In a virtual medium
    # fake_trx pairs by frequency, so two cells on one ARFCN mix their bursts.
    local arfcn_bts1="${ARFCN_BTS1:-$(( 612 + op_id * 2 ))}"
    # +2 on the main BTS step of 10: 6010/6012, 6020/6022...
    local ipa_unit_id_bts1="${IPA_UNIT_ID_BTS1:-$(( 6000 + op_id * 10 + 2 ))}"
    local bsic="${BSIC:-$(( (op_id * 7) % 64 ))}"
    # The side-car has its own BSIC: it is what tells two cells apart in the
    # mobile measurements.
    local bsic_bts1="${BSIC_BTS1:-$(( (bsic + 1) % 64 ))}"
    local lac="${LAC:-0x000${op_id}}"
    local cell_id="${CELL_ID:-$(( 6000 + op_id ))}"
    # Step of 10, not 6000+op_id: the second BTS takes op*10+2, so the two BTS
    # of an operator never present the same unit-id to the BSC (which would
    # accept one and eject the other, in a loop), whatever the operator count.
    local ipa_unit_id="${IPA_UNIT_ID:-$(( 6000 + op_id * 10 ))}"
    local bvci="${BVCI:-$(( op_id * 10 + 2 ))}"
    local nsei="${NSEI:-$(( op_id * 10 ))}"
    local nsvci="${NSVCI:-$(( op_id * 10 ))}"
    # Same subscriber plan as the HLR (launch/start-docker.sh, "HLR subscribers"):
    #    IMSI = MCC MNC <operator on 4 digits> <MS index on 6>
    # This template serves MS #1.
    local imsi="${IMSI:-${mcc}${mnc}$(printf '%04d%06d' "$op_id" 1)}"
    local imei="${IMEI:-$(rand_imei)}"
    # Ki: last two bytes = MS index, then operator - the HLR order
    # (printf '...dd%02x%02x' ms_idx op_id). Without a common Ki there is no
    # Kc and the CIPHER MODE is rejected.
    local ki="${KI:-00 11 22 33 44 55 66 77 88 99 aa bb cc dd $(printf '%02x %02x' 1 "$op_id")}"
    local sms_sc="${SMS_SC:-+336661234$(printf '%04d' "$op_id")}"

    local inter_local_ip sip_remote_ip rtp_start rtp_end sip_host_port
    # On a WAN node the ASP source address is not a docker-plan IP but the
    # segment address, or 0.0.0.0 when it comes from DHCP.
    inter_local_ip="${INTER_LOCAL_IP_OVERRIDE:-$(op_backbone_ip "$op_id")}"
    # The SIP leg to Asterisk is NOT the backbone: it is local in both
    # topologies, and Asterisk identifies it on loopback only (pjsip.conf
    # [gsm_msc-identify] match=127.0.0.1).
    sip_remote_ip="${SIP_REMOTE_IP_OVERRIDE:-127.0.0.1}"
    rtp_start=$(linphone_rtp_start "$op_id"); rtp_end=$(linphone_rtp_end "$op_id")
    sip_host_port=$(linphone_sip_port "$op_id")

    # ── The radio plan, WRITTEN next to the configurations ───────────────────
    # The generator is the only one that decides ARFCN, unit-id, PLMN...: it
    # WRITES what it decided and the other scripts READ it instead of
    # recomputing the formulas.
    {
        printf '# radio-plan.env - ecrit par generate_configs.sh. Ne pas editer.\n'
        printf '# Le plan radio et le PLMN de CET operateur, tels qu ils viennent\n'
        printf '# d etre poses dans les configurations voisines. start-native.sh le\n'
        printf '# lit pour accorder les mobiles et pour piloter le side-car.\n'
        printf 'OPERATOR_ID=%s\n'      "$op_id"
        printf 'PLAN_NODE=%s\n'        "$node"
        printf 'PLAN_MSISDN_PFX=%s\n'  "$msisdn_pfx"
        printf 'PLAN_MCC=%s\n'         "$mcc"
        printf 'PLAN_MNC=%s\n'         "$mnc"
        printf 'PLAN_ARFCN=%s\n'       "$arfcn"
        printf 'PLAN_ARFCN_BTS1=%s\n'  "$arfcn_bts1"
        printf 'PLAN_UNIT_ID=%s\n'     "$ipa_unit_id"
        printf 'PLAN_UNIT_ID_BTS1=%s\n' "$ipa_unit_id_bts1"
        printf 'PLAN_BSIC_BTS1=%s\n'    "$bsic_bts1"
        printf 'PLAN_LAC=%s\n'         "$lac"
        printf 'PLAN_BSIC=%s\n'        "$bsic"
        printf 'PLAN_CELL_ID=%s\n'     "$cell_id"
    } > "$dest/osmocom/radio-plan.env"

    # extensions.conf carries a #include "annuaire.conf" (subscriber entries,
    # written by launch/start-docker.sh so that the caller name reaches the
    # handset). Asterisk warns on every load when an include is missing, so
    # a bench started without start-docker.sh always gets a file, even empty:
    # the _X. fallback of extensions.conf does the rest.
    if [ ! -f "$dest/asterisk/annuaire.conf" ]; then
        {
            printf '; annuaire.conf - fiches d abonnes, ecrites par start-docker.sh.\n'
            printf '; Vide ici : ce banc a ete monte sans annuaire. Les appels\n'
            printf '; passent, ils affichent le numero au lieu du nom.\n'
            printf '[sub-annuaire]\n'
        } > "$dest/asterisk/annuaire.conf"
    fi

    for f in "$dest/osmocom"/*.cfg "$dest/asterisk"/*.conf "$dest/bb"/*.cfg; do
        [ -f "$f" ] || continue
        sed -i \
            -e "s|__ENCRYPTION__|${ENCRYPTION}|g" \
            -e "s|__INTER_NET_GATEWAY__|172.20.0.1|g" \
            -e "s|__CONTAINER_IP__|${container_ip}|g" \
            -e "s|__GATEWAY_IP__|${gateway_ip}|g" \
            -e "s|__HLR_IP__|127.0.0.2|g" \
            -e "s|__INTER_STP_IP__|${inter_stp}|g" \
            -e "s|__INTER_STP_SHUTDOWN__|${inter_stp_shutdown}|g" \
            -e "s|__INTER_LOCAL_IP__|${inter_local_ip}|g" \
            -e "s|__SIP_REMOTE_IP__|${sip_remote_ip}|g" \
            -e "s|__MSISDN_PFX__|${msisdn_pfx}|g" \
            -e "s|__OPERATOR_ID__|${op_id}|g" \
            -e "s|__PC_MSC__|${pc_msc}|g" -e "s|__PC_STP__|${pc_stp}|g" -e "s|__PC_BSC__|${pc_bsc}|g" \
            -e "s|__RCTX_MSC__|${rctx_msc}|g" -e "s|__RCTX_STP__|${rctx_stp}|g" \
            -e "s|__RCTX_BSC__|${rctx_bsc}|g" -e "s|__RCTX_INTER__|${rctx_inter}|g" \
            -e "s|__MCC__|${mcc}|g" -e "s|__MNC__|${mnc}|g" -e "s|__OP_NAME__|${op_name}|g" \
            -e "s|__ARFCN__|${arfcn}|g" -e "s|__IPA_UNIT_ID__|${ipa_unit_id}|g" \
            -e "s|__ARFCN_BTS1__|${arfcn_bts1}|g" \
            -e "s|__IPA_UNIT_ID_BTS1__|${ipa_unit_id_bts1}|g" \
            -e "s|__BSIC_BTS1__|${bsic_bts1}|g" \
            -e "s|__CELL_ID__|${cell_id}|g" -e "s|__BSIC__|${bsic}|g" -e "s|__LAC__|${lac}|g" \
            -e "s|__BVCI__|${bvci}|g" -e "s|__NSEI__|${nsei}|g" -e "s|__NSVCI__|${nsvci}|g" \
            -e "s|__IMSI__|${imsi}|g" -e "s|__IMEI__|${imei}|g" -e "s|__KI__|${ki}|g" \
            -e "s|__SMS_SC__|${sms_sc}|g" -e "s|__HOST_IP__|${HOST_IP}|g" \
            -e "s|__BAND__|${BAND}|g" -e "s|__SIM_ALGO__|${SIM_ALGO}|g" \
            -e "s|__MS_MAX_POWER__|${MS_MAX_POWER}|g" \
            -e "s|__RXLEV_ACCESS_MIN__|${RXLEV_ACCESS_MIN}|g" \
            -e "s|__CELL_RESEL_HYST__|${CELL_RESEL_HYST}|g" \
            -e "s|__T3109__|${T3109}|g" -e "s|__APN__|${APN}|g" \
            -e "s|__NEIGHBOR_MODE_BTS0__|$([ -n "${MS_MAGNETITE:-}" ] && [ "${MAGNETITE_VOISINS:-0}" != 1 ] && echo manual || echo automatic)|g" \
            -e "s|__TS1_PCHAN_BTS0__|${TS1_PCHAN:-$([ "${OSMO_TRX:-0}" = 1 ] && echo TCH/F || echo SDCCH8)}|g" \
            -e "s|__SIP_HOST_PORT__|${sip_host_port}|g" \
            -e "s|__ALSA_OUTPUT__|${ALSA_OUTPUT}|g" -e "s|__ALSA_INPUT__|${ALSA_INPUT}|g" \
            -e "s|__RTP_START__|${rtp_start}|g" -e "s|__RTP_END__|${rtp_end}|g" \
            "$f"
    done

    generate_pjsip_interop_trunks     "$op_id" "$n_operators" >> "$dest/asterisk/pjsip.conf"
    generate_extensions_interop_out   "$op_id" "$n_operators" >> "$dest/asterisk/extensions.conf"
    # SMS routes (default generator). Regenerated when the real MSISDN of the
    # first MS is missing or a stray route (op0000/op000) is present.
    _src="$dest/osmocom/sms-routing.conf"
    _generate_sms_routing_conf_fallback "$op_id" "$n_operators" >  "$_src"
    if ! grep -q "^$(osmo_msisdn "$node" "$op_id" 1) = " "$_src" 2>/dev/null \
       || grep -qE "^${op_id}0000? = " "$_src" 2>/dev/null; then
        _generate_sms_routing_conf_fallback "$op_id" "$n_operators" >  "$_src"
    fi

    # ── The node SS7 addressing: delegated to set-node-id.sh ─────────────────
    # The templates carry the defaults of a SINGLE machine (point code 1.1.2,
    # ASP to 127.0.0.1, shutdown). On a WAN node they are wrong, so
    # network/set-node-id.sh (the only place that keeps osmo-stp, osmo-msc
    # and osmo-bsc and their cross point codes consistent) is replayed AFTER
    # the substitution. Its failure is the generation's failure.
    _apply_node_ss7_addressing "$dest" || return 1
}

# Replays the node SS7 addressing on freshly generated configs.
#   $1 = destination directory (the one that contains osmocom/)
# No effect, silently, when the machine is not a WAN node, when the script is
# missing, or when OSMO_NO_STP_IP=1 asks for it explicitly.
_apply_node_ss7_addressing() {
    local dest="$1"
    local role_file="${ROLE_FILE:-/etc/osmo-role}"
    local here="${GEN_HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

    [ "${OSMO_NO_STP_IP:-0}" = "1" ] && return 0
    [ -d "$dest/osmocom" ] || return 0

    # ENVIRONMENT FIRST, the role file next: a container has no
    # /etc/osmo-role, only the variables launch/start-docker.sh passes it
    # (OSMO_WAN_NODE, OSMO_HUB_IP).
    local role node hub
    node="${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}"
    hub="${OSMO_HUB_IP:-}"
    role="${OSMO_ROLE:-}"
    if [ -r "$role_file" ]; then
        [ -n "$role" ] || role="$(awk -F= '/^OSMO_ROLE=/{gsub(/[ \r\t]/,"",$2);v=$2}    END{print v}' "$role_file")"
        [ -n "$node" ] || node="$(awk -F= '/^OSMO_WAN_NODE=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' "$role_file")"
        [ -n "$hub"  ] || hub="$(awk  -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2);v=$2}  END{print v}' "$role_file")"
    fi
    # An EXPLICIT declaration only: OSMO_ROLE=operator (a VM, a native node)
    # or OSMO_WAN_NODE in the environment (what start-docker.sh passes to a
    # container). WAN_NODE_ID alone is NOT a declaration: on the host it
    # designates the MACHINE's node, not the container whose configs are
    # being generated, and applying it to every operator would give them all
    # the same point code.
    [ "$role" = "operator" ] || [ -n "${OSMO_WAN_NODE:-}" ] || return 0
    [[ "$node" =~ ^[1-9]$ ]] || return 0

    local setid="$here/network/set-node-id.sh"
    [ -r "$setid" ] || return 0

    # The hub, from any source: without it set-node-id.sh would PROMPT, and
    # nobody answers from a start-up loop.
    [ -n "$hub" ] || hub="${WAN_STP_TARGET:-${INTER_STP_IP:-}}"

    # --op is the operator INDEX inside the point code 1.<node><op>.<role>,
    # not the operator count: a WAN node carries one here. Not the operator
    # id either: in start-docker.sh it is the CONTAINER index, and node 2
    # would move from 1.21.2 to 1.22.2.
    local args=(--node "$node" --op 1 --native --conf-dir "$dest/osmocom")
    [ -n "$hub" ] && args+=(--hub-ip "$hub")

    # </dev/null: this rewrite is automatic and must NEVER ask a question. A
    # reported failure is preferred to a hang.
    if bash "$setid" "${args[@]}" </dev/null >/dev/null 2>&1; then
        echo "  ✓ adressage SS7 du noeud ${node} reapplique (set-node-id.sh)"
    else
        echo "  ⚠ adressage SS7 du noeud ${node} NON reapplique - l'ASP inter-STP" >&2
        echo "    gardera les defauts du gabarit (127.0.0.1, shutdown)." >&2
        # Configs left with the template SS7 identity are no better than no
        # configs: nothing upstream re-reads the point code, so fail here.
        return 1
    fi
}

# ── sms-routing.conf: THE ROUTING IS READ FROM THE NUMBER ────────────────────
# The routing key is the NODE, not the operator, and it is the first digit of
# the MSISDN (<node>00<op><ms>). The addresses come from the WAN TABLE
# (/etc/osmo-wan.conf), the only source that knows where the other nodes are
# really reachable. Without a table (single-node bench) there is one entry:
# ours.
#
#   $1 file  $2 node  $3 operator  $4 MS count  $5 local IP of the core
#   $6 WAN table
_write_sms_routing_native() {
    local out="$1" node="$2" op_id="$3" n_ms="$4" host_ip="$5" wanf="$6"
    local spec="" ent id ip nops n o m
    local -a ids=() 

    # WAN_NODES="id:ip:prefix[:operators] ..." - read without sourcing the
    # table: that file also sets WAN_NODE_ID and WAN_OPS, which would
    # overwrite the caller's.
    if [ -r "$wanf" ]; then
        spec="$(sed -n 's/^WAN_NODES=//p' "$wanf" | tr -d '"'"'"'' | tail -1)"
    fi

    # OUR address, the one other nodes reach us at: the table first (an
    # explicit choice), then the default route, loopback last - an isolated
    # bench must still route its SMS.
    local self_ip=""
    for ent in $spec; do
        IFS=: read -r id ip _ nops <<< "$ent"
        [ "$id" = "$node" ] && self_ip="$ip"
    done
    if [ -z "$self_ip" ]; then
        self_ip="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
    fi
    [ -n "$self_ip" ] || self_ip="$host_ip"

    {
        printf '# sms-routing.conf - ecrit par generate_configs.sh.\n'
        printf '# Cle de routage = NUMERO DE NOEUD, premier chiffre du MSISDN.\n'
        printf '# MSISDN = <noeud>00<operateur><rang du MS sur 2 chiffres>\n\n'
        printf '[local]\n'
        printf 'operator_id = %s\n' "$node"
        printf 'sc_address  = 1999001%s444\n\n' "$op_id"
        printf '[operators]\n'
        if [ -n "$spec" ]; then
            for ent in $spec; do
                IFS=: read -r id ip _ nops <<< "$ent"
                [ -n "$id" ] || continue
                [ "$id" = "$node" ] && ip="$self_ip"
                printf '%s = %s\n' "$id" "$ip"
            done
        else
            printf '%s = %s\n' "$node" "$self_ip"
        fi
        printf '\n[routes]\n'
        if [ -n "$spec" ]; then
            for ent in $spec; do
                IFS=: read -r id ip _ nops <<< "$ent"
                [ -n "$id" ] || continue
                # nops missing = 3-field entry: default to 1 operator.
                nops="${nops:-1}"
                case "$nops" in ''|*[!0-9]*) nops=1 ;; esac
                for o in $(seq 1 "$nops"); do
                    for m in $(seq 1 "$n_ms"); do
                        printf '%s = %s\n' "$(osmo_msisdn "$id" "$o" "$m")" "$id"
                    done
                done
            done
        else
            for m in $(seq 1 "$n_ms"); do
                printf '%s = %s\n' "$(osmo_msisdn "$node" "$op_id" "$m")" "$node"
            done
        fi
        printf '\n[relay]\nport = 7890\nconnect_timeout = 10\nretry_count = 3\nretry_delay = 5\n'
    } > "$out"
}

# ── NATIVE post-patches: the ISO recipe, in ONE place ────────────────────────
# What turns "the templates are substituted" into "the machine has a
# configuration that starts" on a native host (ISO, VM, start-native.sh):
#
#   sms-routing.conf  one route per embarked MS, on the local core address
#                     (the template fallback lists docker-plan addresses).
#   osmo-sgsn.cfg     "gtp local-ip", "gsup remote-ip" and the NS listen
#                     address follow the native plan.
#   osmo-msc.cfg      "hlr remote-ip" follows the HLR bind address.
#   osmo-stp.cfg      the local-ip of the ASP to the inter-STP hub.
#   pjsip.conf        the [transport-udp] block loses its docker NAT settings.
#   mobile.cfg        the GSMTAP target becomes 127.0.0.1.
#   run.sh            "trxcon <options>" and "mobile <options>" reduced to
#                     the bare binary: the start-up modules decide the options.
#
# Called on both sides, on the same tree: the ISO build ($TEMP_CONFIG then
# $ROOTFS/etc) and start-native.sh --regen (its temporary directory).
# Idempotent: replaying it on an already patched tree changes nothing.
#
#   $1  root that holds osmocom/ : $TEMP_CONFIG, $ROOTFS/etc, /etc
#   $2  operator number         (default 1)
#   $3  number of embarked MS   (default 2)
#   $4  local address of the core (default 127.0.0.2)
#   $5  node number             (default: osmo_node_id)
#   $6  WAN table to read       (default /etc/osmo-wan.conf)
#   $7  SGSN GTP local-ip       (default 192.168.<node+1>.1)
#   $8  HLR address             (default 127.0.0.2)
apply_native_post_patches() {
    local dest="${1:?apply_native_post_patches : racine manquante}"
    local op_id="${2:-1}" n_ms="${3:-2}" host_ip="${4:-127.0.0.2}"
    local node="${5:-$(osmo_node_id)}" wanf="${6:-${WAN_CONF_FILE:-/etc/osmo-wan.conf}}"
    # sgsn_gtp_ip  The SGSN and the GGSN both open a GTP socket; on the same
    #              address the SGSN dies on "Address already in use". Default:
    #              the gateway of the node's private segment,
    #              192.168.<node+1>.1, set by network/osmo-ip-plan.sh.
    # hlr_ip       "gsup remote-ip" and the hlr "remote-ip" of the MSC
    #              designate WHERE THE HLR LISTENS (the "bind ip" of
    #              osmo-hlr.cfg), not the local address of the node.
    local sgsn_gtp_ip="${7:-}"
    local hlr_ip="${8:-127.0.0.2}"
    local cfg="$dest/osmocom"
    [ -d "$cfg" ] || return 0
    [ "$n_ms" -ge 1 ] 2>/dev/null || n_ms=1
    case "$node" in [1-9]) ;; *) node=1 ;; esac
    # AFTER the node validation, never before: an empty $node would give
    # 192.168.1.1, the bench LAN where the VMs and the SS7 hub live.
    : "${sgsn_gtp_ip:=192.168.$((node + 1)).1}"

    _write_sms_routing_native "$cfg/sms-routing.conf" \
        "$node" "$op_id" "$n_ms" "$host_ip" "$wanf"

    if [ -f "$cfg/osmo-sgsn.cfg" ]; then
        sed -i \
            -e "s/^\([[:space:]]*gtp[[:space:]]\+local-ip[[:space:]]\+\).*/\1${sgsn_gtp_ip}/" \
            -e "s/^\([[:space:]]*gsup[[:space:]]\+remote-ip[[:space:]]\+\).*/\1${hlr_ip}/" \
            -e "/^[[:space:]]*bind udp local\$/,/^[[:space:]]*!\$/ s/^\([[:space:]]*listen[[:space:]]\+\).*/\1${host_ip} 23000/" \
            "$cfg/osmo-sgsn.cfg"
    fi

    if [ -f "$cfg/osmo-msc.cfg" ]; then
        sed -i \
            -e "/^hlr\$/,/^!\$/ s/^\([[:space:]]*remote-ip[[:space:]]\+\).*/\1${hlr_ip}/" \
            "$cfg/osmo-msc.cfg"
    fi

    # ── osmo-stp.cfg: the local-ip of the ASP to the inter-STP ───────────────
    # The template sets  local-ip __INTER_LOCAL_IP__  under  asp asp-to-inter,
    # substituted by op_backbone_ip(N) = 172.20.0.<10+N>: right INSIDE the
    # container, nonexistent on the host. An unbindable local-ip gives no
    # readable error: the ASP simply never comes up (as-inter AS_DOWN).
    #
    # The local-ip is the source address the kernel picks to reach the hub
    # (ip route get): an SCTP association bound to 127.0.0.1 towards a hub on
    # a network address - even this machine's own - is refused ("Network is
    # unreachable"). 127.0.0.1 only when the hub is on loopback or no route
    # leads to it. The remote-ip is already resolved by the template.
    #
    # awk, not sed: only the local-ip that follows "asp asp-to-inter" must
    # change, not those of the listen block above it, which are correct.
    if [ -f "$cfg/osmo-stp.cfg" ]; then
        local inter_rip inter_lip=127.0.0.1
        inter_rip="$(awk '/^[[:space:]]*asp[[:space:]]+asp-to-inter[[:space:]]/{f=1;next} f&&/^[[:space:]]*remote-ip[[:space:]]/{print $2; exit} f&&/^ (asp|as) /{exit}' "$cfg/osmo-stp.cfg")"
        case "$inter_rip" in
            ""|127.*|__*) ;;   # __* : template not substituted yet
            *) inter_lip="$(ip -4 route get "$inter_rip" 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}')"
               [ -n "$inter_lip" ] || inter_lip=127.0.0.1 ;;
        esac
        awk -v lip="$inter_lip" '
            /^[[:space:]]*asp[[:space:]]+asp-to-inter[[:space:]]/ { in_asp = 1; print; next }
            in_asp && /^[[:space:]]*local-ip[[:space:]]/ {
                sub(/local-ip[[:space:]]+.*/, "local-ip " lip); in_asp = 0; print; next
            }
            /^[[:space:]]*(as|asp|cs7|listen)[[:space:]]/ && !/asp-to-inter/ { in_asp = 0 }
            { print }
        ' "$cfg/osmo-stp.cfg" > "$cfg/osmo-stp.cfg.tmp" \
            && mv -f "$cfg/osmo-stp.cfg.tmp" "$cfg/osmo-stp.cfg"
    fi

    # ── pjsip.conf: the [transport-udp] block ────────────────────────────────
    # configs/pjsip.conf carries no placeholder: its transport block is pinned
    # on the docker plan (external_media_address / external_signaling_address
    # = 10.2.0.2, local_net = 172.20.0.0/16). external_* is a NAT option: for
    # any peer OUTSIDE local_net Asterisk rewrites the Contact and the SDP
    # with that address, which a LAN Linphone cannot reach.
    # On a flat host there is no NAT boundary: the external_* lines are
    # REMOVED (pjsip then answers with the socket address, per destination)
    # and local_net covers the whole private space, whatever the topology.
    if [ -f "$dest/asterisk/pjsip.conf" ]; then
        awk '
            /^\[transport-udp\]/ { in_t = 1; print; next }
            in_t && /^\[/         { in_t = 0 }
            in_t && /^[[:space:]]*external_(media|signaling)_address[[:space:]]*=/ { next }
            in_t && /^[[:space:]]*local_net[[:space:]]*=/ {
                if (!done) {
                    print "local_net=127.0.0.0/8"
                    print "local_net=10.0.0.0/8"
                    print "local_net=172.16.0.0/12"
                    print "local_net=192.168.0.0/16"
                    print "local_net=176.16.32.0/24"
                    done = 1
                }
                next
            }
            { print }
        ' "$dest/asterisk/pjsip.conf" > "$dest/asterisk/pjsip.conf.tmp" \
            && mv -f "$dest/asterisk/pjsip.conf.tmp" "$dest/asterisk/pjsip.conf"
    fi

    # ── mobile.cfg: the GSMTAP target ────────────────────────────────────────
    # The template sets  remote-host __INTER_NET_GATEWAY__  under  gsmtap,
    # substituted by 172.20.0.1 (the docker bridge gateway), which only exists
    # while a docker network is up. The other components (osmo-bts-trx,
    # osmo-pcu, osmo-bsc) already send to 127.0.0.1:4729.
    if [ -f "$cfg/mobile.cfg" ]; then
        sed -i \
            -e "/^gsmtap\$/,/^!\$/ s/^\([[:space:]]*remote-host[[:space:]]\+\).*/\1127.0.0.1/" \
            "$cfg/mobile.cfg"
    fi

    if [ -f "$cfg/run.sh" ]; then
        sed -i \
            -e 's#^[[:space:]]*\([^[:space:]]*/\)\?trxcon\([[:space:]].*\)\?$#trxcon#' \
            -e 's#^[[:space:]]*\([^[:space:]]*/\)\?mobile\([[:space:]].*\)\?$#mobile#' \
            "$cfg/run.sh"
    fi
    chmod +x "$cfg"/*.sh 2>/dev/null || true
    return 0
}

# ── Show the effective values ────────────────────────────────────────────────
_gc_show() {
    local key def perop comment val src
    printf '\n  %-13s %-26s %s\n' "REGLAGE" "VALEUR EFFECTIVE" "ORIGINE"
    printf '  %-13s %-26s %s\n' "-------" "----------------" "-------"
    while IFS='|' read -r key def perop comment; do
        [ -n "$key" ] && [ "$key" != "#SECTION" ] || continue
        val="${!key:-}"
        if [ -n "$val" ]; then src="globals.conf / env"
        elif [ "$perop" = 1 ]; then src="derive de l'operateur"; val="(auto)"
        else src="defaut"; val="$def"; fi
        printf '  %-13s %-26s %s\n' "$key" "$val" "$src"
    done < <(_gc_table)
    printf '\n'
}

# ── Multi-operator guard ─────────────────────────────────────────────────────
_gc_warn_perop() {
    [ "${N_OPERATORS:-1}" -gt 1 ] 2>/dev/null || return 0
    local key def perop comment figes=""
    while IFS='|' read -r key def perop comment; do
        [ "$key" != "#SECTION" ] && [ "$perop" = 1 ] && [ -n "${!key:-}" ] && figes="$figes $key"
    done < <(_gc_table)
    [ -n "$figes" ] || return 0
    printf '\n  ⚠ N_OPERATORS=%s mais ces champs par-operateur sont FIGES :%s\n' \
           "$N_OPERATORS" "$figes"
    printf '    Tous les operateurs partageront la meme valeur - collision garantie\n'
    printf '    sur la radio et/ou les identites. Videz-les dans globals.conf.\n\n'
}

# ── Executed mode ────────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    force=0; show=0; _gc_sets=()
    for a in "$@"; do
        case "$a" in
            --force) force=1 ;;
            --show)  show=1 ;;
            -h|--help)
                sed -n '2,60p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; exit 0 ;;
            *=*)     _gc_sets+=("$a") ;;
            *) printf 'option inconnue : %s (voir --help)\n' "$a" >&2; exit 2 ;;
        esac
    done
    _gc_write "$force"
    for kv in "${_gc_sets[@]}"; do _gc_set "$kv"; done
    gc_load
    _gc_warn_perop
    [ "$show" = 1 ] && _gc_show
    exit 0
fi

# ── Sourced mode ─────────────────────────────────────────────────────────────
gc_load

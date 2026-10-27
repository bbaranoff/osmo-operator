# =============================================================================
#  lib/gabarits.sh - the osmo-operator configuration template engine
# =============================================================================
#
#  The functions below substitute __ENCRYPTION__, __MCC__, __KI__, __ARFCN__ ...
#  in configs/*.cfg and install the result in /etc/osmocom, /etc/asterisk and
#  ~/.osmocom/bb. Without them, the core daemons start on the files left by a
#  previous run, and `ENCRYPTION=a5 0` has no effect, silently.
#
#  THIS FILE DOES NOTHING WHEN SOURCED: it only defines functions.
#  The only expected caller is run_modules/08-gabarits.sh.
#
#  ENVIRONMENT DEPENDENCIES (set by the caller, defaults below): ENCRYPTION,
#  HOST_IP, ALSA_OUTPUT, ALSA_INPUT.
#  The current directory must be the osmo-operator one: the functions read
#  `configs/*.cfg` and `scripts/*` by RELATIVE path.
# -----------------------------------------------------------------------------

: "${ENCRYPTION:=a5 0}"
: "${HOST_IP:=127.0.0.1}"
: "${ALSA_OUTPUT:=default}"
: "${ALSA_INPUT:=default}"

# These functions have a TWIN in start-docker.sh: both must say the same thing.
# THIS copy is the one read by a machine that reclones the repository at every
# boot, i.e. the one that matters on an ISO.
#
#   backbone  172.20.0.<10+op>   the segment shared with the inter-STP (.10)
#   private   192.168.<op+1>.x   one segment per operator; the +1 leaves
#                                192.168.1.0/24 to the bench LAN.
op_backbone_ip()  { echo "172.20.0.$((10 + $1))"; }
# ── THE PRIVATE SEGMENT INDEX: THE NODE OR THE OPERATOR, DEPENDING ON THE HOST ─
# 192.168.<index+1>.x, where "index" depends on where the code runs:
#
#   DOCKER    a host carries N operator containers, each in its own netns.
#             What distinguishes them is the OPERATOR NUMBER; the node is
#             common to all containers of the machine. index = operator.
#   VM/NATIVE the machine IS the node and carries only one operator. What
#             distinguishes it from its neighbours is the NODE NUMBER.
#             index = node.
#
# Without this distinction, every VM would write 192.168.2.10 (operator 1) in
# osmo-ggsn.cfg while the ISO plan reserves 192.168.<node+1>.x: on node 2 the
# GGSN would bind to the address of node 1. The switch is here, once, and both
# twins (start-docker.sh, lib/gabarits.sh) inherit it.
_osmo_priv_index() {
    local op="${1:-1}"
    # THE ORCHESTRATOR IS NOT INSIDE THE CONTAINER IT CREATES.
    # The detection below asks "am I INSIDE a container?", the right question
    # for code running inside one. start-docker.sh, however, provisions the
    # containers FROM THE HOST: it would take the VM/native branch and return
    # the NODE index - 1 - for every operator, so both private networks would
    # land on 192.168.2.0/24 and docker would refuse the second one for
    # overlap:
    #     ── Operateur 2 : ... Prive : 192.168.2.10
    #     ✗ Echec creation reseau gsm-net-op2 (192.168.2.0/24)
    # OSMO_PRIV_BY_OP=1 says "I provision per operator"; start_bridge_mode
    # sets it. It is the only thing the detection cannot guess.
    [ "${OSMO_PRIV_BY_OP:-0}" = "1" ] && { printf '%s' "$op"; return; }
    # Same detection as start-native.sh: the pair /.dockerenv +
    # /etc/docker-entrypoint-cmd identifies a container OF THIS REPOSITORY; the
    # cgroup is the fallback for any container.
    if [ -f /.dockerenv ] || grep -qa 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
        printf '%s' "$op"; return
    fi
    local n="${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}"
    [ -n "$n" ] || n="$(awk -F= '/^OSMO_WAN_NODE=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' \
                        "${ROLE_FILE:-/etc/osmo-role}" 2>/dev/null)"
    [ -n "$n" ] || n="$(sed -n 's/^PLAN_NODE=//p' "${OSMOCOM_CFG:-/etc/osmocom}/radio-plan.env" 2>/dev/null | tail -1)"
    case "$n" in [1-9]) ;; *) n=1 ;; esac
    printf '%s' "$n"
}
op_private_ip()   { echo "192.168.$(($(_osmo_priv_index "$1") + 1)).10"; }
op_private_gw()   { echo "192.168.$(($(_osmo_priv_index "$1") + 1)).1"; }
op_private_net()  { echo "192.168.$(($(_osmo_priv_index "$1") + 1)).0/24"; }
op_netns()        { echo "osmo-op$1"; }
op_rctx_msc()     { echo $(( $1 * 100 + 10 )); }
op_rctx_stp()     { echo $(( $1 * 100 + 20 )); }
op_rctx_bsc()     { echo $(( $1 * 100 + 30 )); }
op_rctx_inter()   { echo $(( $1 * 100 + 50 )); }
# ── NO PORT OFFSET ──────────────────────────────────────────────────────────
# No SIP/RTP port is published for the containers: they sit on a routable
# bridge and are reached directly, at their own address, on the nominal port
# (172.20.0.12:5060 and 172.20.0.13:5060 answer 401 from the host without any
# publication). So there is no conflict with the native Asterisk on 5060 and
# no offset to compute.
#
# The functions below keep their shape (generate_configs.sh still uses them to
# write the configs) but return the NOMINAL values.
# OSMO_PORT_OFFSET=N remains available for whoever wants an offset.
PORT_OFFSET="${OSMO_PORT_OFFSET:-0}"
# RTP follows the same rule: nominal range, 200 ports per operator.
linphone_sip_port()  { echo $(( 5060  + ${PORT_OFFSET:-0}      + ($1 - 1) )); }
linphone_rtp_start() { echo $(( 30000 + ${PORT_OFFSET:-0} * 10 + ($1 - 1) * 200 )); }
linphone_rtp_end()   { echo $(( 30000 + ${PORT_OFFSET:-0} * 10 + $1 * 200 - 1 )); }
# Both twins enumerate the operators from the same base: with OP_ID_BASE=2 the
# containers take ranks 2 and 3 and rank 1 stays native. A loop hard-coded on
# 1..N would build a trunk to "operator 1" at 172.20.0.11, a backbone address
# NOBODY carries (the native one is on the host), and none to operator 3: the
# trunk would exist but point into the void.
generate_pjsip_interop_trunks() {
    local op_id=$1 n_operators=$2 remote_op remote_ip
    # ── THE OPERATORS BELOW THE BASE ARE THE NATIVE ONES ───────────────────
    # The loop starts at 1, not at the base: with OP_ID_BASE=2 (containers on
    # ranks 2..N, rank 1 native on the host) op2 must also get a trunk to the
    # native operator, otherwise a call 100201 -> 100101 falls into the _X.
    # catch-all of [interop_out] and ends in Congestion.
    for remote_op in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))) \
                     $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        # An operator below the base is NATIVE: it runs on the host, not in a
        # container. Seen from a container, the host is the docker bridge
        # gateway - the same address as the audio bridge and sms-routing.conf.
        # NB: match=172.20.0.1 does not swallow the Linphone REGISTERs, which
        # arrive through the same gateway: pjsip.conf sets
        # endpoint_identifier_order=username,ip,anonymous - username first.
        if [ "$remote_op" -lt "${OP_ID_BASE:-1}" ]; then
            remote_ip="${INTER_NET_GATEWAY:-172.20.0.1}"
        else
            remote_ip=$(op_backbone_ip "$remote_op")
        fi
        cat <<EOF

[interop-identify-op${remote_op}]
type=identify
endpoint=interop_trunk_op${remote_op}
match=${remote_ip}

[interop_trunk_op${remote_op}]
type=endpoint
transport=transport-udp
context=interop_in
disallow=all
allow=gsm
allow=ulaw
aors=interop_trunk_op${remote_op}
direct_media=no
rtp_symmetric=yes
force_rport=yes
media_encryption=no

[interop_trunk_op${remote_op}]
type=aor
contact=sip:${remote_ip}:5060
qualify_frequency=15
qualify_timeout=5.0
EOF
    done
}
generate_extensions_interop_out() {
    local op_id=$1 n_operators=$2 remote_op
    # The prefix carries the NODE: MSISDN = <node>00<operator><rank>. A fixed
    # "600" would not match anything once the number starts with the node
    # number - inter-operator calls would end in Congestion without any line
    # saying that the pattern does not match.
    local _pfx; _pfx="$(osmo_msisdn_pfx "$(osmo_node_id)")"
    printf '[interop_out]\n\n'
    # One single pattern: MSISDNs are six digits, <node>00<operator><rank>.
    # ── THE OPERATORS BELOW THE BASE ARE THE NATIVE ONES ───────────────────
    # The loop starts at 1, not at the base: with OP_ID_BASE=2 (containers on
    # ranks 2..N, rank 1 native on the host) op2 must also get a route to the
    # native operator, otherwise a call 100201 -> 100101 falls into the _X.
    # catch-all of [interop_out] and ends in Congestion. Same rule as
    # sms-routing.conf, on the VOICE path.
    for remote_op in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))) \
                     $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        cat <<EOF
exten => _${_pfx}${remote_op}XX,1,NoOp(=== INTEROP OUT Op${remote_op}: \${EXTEN} ===)
 same => n,Dial(PJSIP/\${EXTEN}@interop_trunk_op${remote_op},,rT)
 same => n,Congestion()
 same => n,Hangup()

EOF
    done

    # ── THE SOFTPHONES TOO, AND WITHOUT PREFIX ──────────────────────────────
    # From [internal], a Linphone can reach another operator by dialling the
    # number as is: without this route, 100201 would fall into the _X.
    # catch-all of [internal] and go to the LOCAL MSC, which returns
    #     rx MNCC_SETUP_REQ for unknown subscriber number '100201'
    # before sending it back through MNCC to Asterisk - a detour that consumes
    # an MNCC transaction for nothing and makes a SIP->SIP call depend on the
    # MSC. _<pfx><op>XX is MORE SPECIFIC than _X.: Asterisk picks it first,
    # without touching the template's catch-all. Gosub(sub-record) as for _9.,
    # otherwise these calls would be the only ones not recorded.
    printf '[internal]\n\n'
    for remote_op in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))) \
                     $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        cat <<EOF
exten => _${_pfx}${remote_op}XX,1,NoOp(=== SIP -> INTER-OP Op${remote_op}: \${EXTEN} - CallerID: \${CALLERID(all)} ===)
 same => n,Gosub(sub-record,s,1(\${EXTEN}))
 same => n,Goto(interop_out,\${EXTEN},1)

EOF
    done
    # NO _X. catch-all here: the configs/extensions.conf template already
    # declares one in this same context. Two identical extensions in a context
    # make Asterisk refuse the second, with six warnings at every load:
    #     add_priority: Unable to register extension '_X.' priority 1
    #                   in 'interop_out', already in use
}
_generate_sms_routing_conf_fallback() {
    # 'local i' is NOT cosmetic. This function is called, through
    # apply_config_templates, FROM the "for i in ..." loop that starts the
    # operators. Without local, its own loop overwrites the caller's variable
    # and leaves it at n_operators: all following containers would compute
    # their ports with the SAME index, hence
    #     Bind for 0.0.0.0:5082 failed: port is already allocated
    # on the second container - and, before the error, two operators announced
    # on the same SIP/RTP/SMS.
    local i
    local op_id=$1 n_operators=$2 i j
    printf '# sms-routing.conf - Fallback\n\n[local]\noperator_id = %s\nsc_address  = 1999001%s444\n\n[operators]\n' "$op_id" "$op_id"
    # ── THE OPERATORS BELOW THE BASE ARE THE NATIVE ONES ────────────────────
    # start-multi.sh sets OP_ID_BASE=2: the containers take ranks 2..N and
    # operator 1 stays NATIVE, on the host. It must still appear in [operators]
    # and [routes], otherwise an SMS to 100101 ends in "No route for
    # destination" and the native operator is unreachable from the whole bench.
    # It is pointed at the docker bridge gateway, which IS the host seen from a
    # container - the same address as the audio bridge (172.20.0.1).
    local _natif_gw="${INTER_NET_GATEWAY:-172.20.0.1}"
    for i in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))); do printf '%s = %s\n' "$i" "$_natif_gw"; done
    for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do printf '%s = %s\n' "$i" "$(op_backbone_ip "$i")"; done
    printf '\n[routes]\n'
    for i in $(seq 1 $(( ${OP_ID_BASE:-1} - 1 ))); do
        for ms in 1 2; do printf '%s = %s\n' "$(osmo_msisdn "$(osmo_node_id)" "$i" "$ms")" "$i"; done
    done
    for i in $(seq "${OP_ID_BASE:-1}" "$(( ${OP_ID_BASE:-1} + n_operators - 1 ))"); do
        # EXACT MSISDNs, not a prefix: a prefix too short swallows the
        # neighbouring numbers, a missing prefix makes the relay reject every
        # local SMS with "No route for destination".
        for ms in 1 2; do printf '%s = %s\n' "$(osmo_msisdn "$(osmo_node_id)" "$i" "$ms")" "$i"; done   # exact MSISDNs <node>00<op><ms> (100101, 100102, 200101...)
    done
    printf '\n[relay]\nport = 7890\nconnect_timeout = 10\nretry_count = 3\nretry_delay = 5\n'
}
# apply_config_templates() lives in generate_configs.sh (one single copy, for
# this file and for start-docker.sh); its values (ARFCN, BSIC, KI, IMSI...)
# are exposed in globals.conf instead of being formulas buried in the
# substitution.
_GAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -r "$_GAB_ROOT/generate_configs.sh" ] && . "$_GAB_ROOT/generate_configs.sh"

# ── Native config install. $1=src $2=root prefix (/ or /etc/netns/<ns>) ──
# ── CONTAINER ADDRESSES HAVE NO PLACE ON THE HOST ───────────────────────────
# The templates are written for a CONTAINER: they set the operator backbone
# address (172.20.0.<10+N>) and the docker bridge gateway (172.20.0.1). On the
# host, neither exists.
#
# apply_native_post_patches (generate_configs.sh) also fixes these, but only
# start-native.sh calls it; qosmo-grgsm/run_modules/08-gabarits.sh calls ONLY
# apply_config_templates + install_configs_native and does not even source
# generate_configs.sh. So the fixes are hooked here, in install_configs_native
# - the MANDATORY path of the native mode, whatever the caller. Idempotent:
# replaying changes nothing.
_gab_fixups_natifs() {
    local src="$1" f

    # 1. osmo-stp.cfg: the local-ip of the ASP to the inter-STP. Only the
    #    local-ip following "asp asp-to-inter" is touched: those of the listen
    #    block above (127.0.0.1 / 127.0.0.2) are correct. 127.0.0.1 is the only
    #    address one can be sure of on a host, EXCEPT when the hub is on a
    #    network address, even ours: an SCTP bound to 127.0.0.1 towards
    #    192.168.1.31 is refused ("Network is unreachable") and as-inter stays
    #    AS_DOWN. So the source address the kernel picks towards the hub is
    #    used (same rule as generate_configs.sh).
    f="$src/osmocom/osmo-stp.cfg"
    if [ -f "$f" ]; then
        local rip lip=127.0.0.1
        rip="$(awk '/^[[:space:]]*asp[[:space:]]+asp-to-inter[[:space:]]/{x=1;next} x&&/^[[:space:]]*remote-ip[[:space:]]/{print $2; exit} x&&/^ (asp|as) /{exit}' "$f")"
        case "$rip" in
            ""|127.*|__*) ;;   # __* : template not substituted yet
            *) lip="$(ip -4 route get "$rip" 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}')"
               [ -n "$lip" ] || lip=127.0.0.1 ;;
        esac
        awk -v lip="$lip" '
            /^[[:space:]]*asp[[:space:]]+asp-to-inter[[:space:]]/ { a = 1; print; next }
            a && /^[[:space:]]*local-ip[[:space:]]/ {
                sub(/local-ip[[:space:]]+.*/, "local-ip " lip); a = 0; print; next
            }
            /^[[:space:]]*(as|asp|cs7|listen)[[:space:]]/ && !/asp-to-inter/ { a = 0 }
            { print }
        ' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
    fi

    # 2. mobile.cfg: the GSMTAP target. 172.20.0.1 does not exist without the
    #    bridge, and the packets would go nowhere - Wireshark stays empty on
    #    udp/4729 without any message saying so.
    for f in "$src/osmocom/mobile.cfg" "$src/bb/mobile.cfg" "$src/bb/mobile_group1.cfg"; do
        [ -f "$f" ] || continue
        sed -i "/^gsmtap\$/,/^!\$/ s/^\([[:space:]]*remote-host[[:space:]]\+\).*/\1127.0.0.1/" "$f"
    done

    # 3. pjsip.conf: on a flat host there is no NAT boundary to declare.
    #    external_* makes pjsip REWRITE Contact and SDP for any peer outside
    #    local_net - a LAN Linphone would receive an unreachable address.
    #    Without them, pjsip answers with the socket address, the right one,
    #    per destination.
    f="$src/asterisk/pjsip.conf"
    if [ -f "$f" ]; then
        awk '
            /^\[transport-udp\]/ { t = 1; print; next }
            t && /^\[/            { t = 0 }
            t && /^[[:space:]]*external_(media|signaling)_address[[:space:]]*=/ { next }
            t && /^[[:space:]]*local_net[[:space:]]*=/ {
                if (!d) {
                    print "local_net=127.0.0.0/8"; print "local_net=10.0.0.0/8"
                    print "local_net=172.16.0.0/12"; print "local_net=192.168.0.0/16"
                    print "local_net=176.16.32.0/24"; d = 1
                }
                next
            }
            { print }
        ' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
    fi

    # 4. sms-routing.conf: THE NATIVE OPERATOR MUST KNOW THE OTHERS.
    #    The fallback written by apply_config_templates is meant FOR A
    #    CONTAINER: 172.20.0.11 as the operator address (the DOCKER backbone
    #    address, which does not exist on the host) and no other operator at
    #    all, so an SMS from the native to 100201 would end in "No route for
    #    destination". Same trap as points 1 to 3 above, hence the fix in the
    #    same place: install_configs_native is the MANDATORY path of the
    #    native mode, whatever the caller.
    #
    #    THE SOURCE OF TRUTH is osmo-multi.conf (written by addition.sh):
    #        MULTI_OPS="1:native::1.1.2:150 2:docker:172.20.0.12:... 3:docker:..."
    #    The keying by OPERATOR, the containers' one, is kept: on a
    #    single-machine bench everybody is on node 1, a keying by node would
    #    confuse them. Without osmo-multi.conf (single operator), nothing is
    #    touched.
    f="$src/osmocom/sms-routing.conf"
    local mc="${OSMO_MULTI_CONF:-/etc/osmocom/osmo-multi.conf}"
    if [ -f "$f" ] && [ -r "$mc" ]; then
        local _ops _node _self _sc _id _mode _ip _e
        _ops="$(sed -n 's/^MULTI_OPS=//p' "$mc" | tr -d '"' | tail -1)"
        _node="$(sed -n 's/^MULTI_NODE=//p' "$mc" | tail -1)"; case "$_node" in [1-9]) ;; *) _node=1 ;; esac
        # Identity: it is RE-READ, not recomputed - it says which operator this
        # native is, and it may have been realigned by start-multi.sh
        # (aligner_natif).
        _self="$(sed -n 's/^operator_id[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
        _sc="$(sed -n 's/^sc_address[[:space:]]*=[[:space:]]*//p'  "$f" | head -1)"
        case "$_self" in [1-9]*) ;; *) _self=1 ;; esac
        [ -n "$_sc" ] || _sc="1999001${_self}444"
        if [ -n "$_ops" ]; then
            {
                printf '# sms-routing.conf - natif, reecrit par _gab_fixups_natifs\n'
                printf '# Table issue de %s (MULTI_OPS). Cle = numero d operateur.\n' "$mc"
                printf '# MSISDN = <noeud>00<operateur><rang du MS sur 2 chiffres>\n\n'
                printf '[local]\noperator_id = %s\nsc_address  = %s\n\n[operators]\n' "$_self" "$_sc"
                for _e in $_ops; do
                    IFS=: read -r _id _mode _ip _ <<< "$_e"
                    [ -n "$_id" ] || continue
                    # The native one is US: 127.0.0.1 is the only address one
                    # can be sure of on a host (same choice as in point 1).
                    if [ "$_mode" = native ] || [ "$_id" = "$_self" ]; then _ip=127.0.0.1; fi
                    [ -n "$_ip" ] || continue
                    printf '%s = %s\n' "$_id" "$_ip"
                done
                printf '\n[routes]\n'
                for _e in $_ops; do
                    IFS=: read -r _id _mode _ip _ <<< "$_e"
                    [ -n "$_id" ] || continue
                    for _m in 1 2; do
                        printf '%s = %s\n' "$(( _node * 100000 + _id * 100 + _m ))" "$_id"
                    done
                done
                printf '\n[relay]\nport = 7890\nconnect_timeout = 10\nretry_count = 3\nretry_delay = 5\n'
            } > "$f.tmp" && mv -f "$f.tmp" "$f"
        fi
    fi

    # 5. THE INTER-OPERATOR VOICE PATH: SIP trunks + [interop_out].
    #    Same need as point 4, on VOICE. Without it, the native [interop_out]
    #    only holds _X. -> Congestion() and pjsip.conf has no
    #    interop_trunk_opN: a call 100101 -> 100201 leaves the MSC
    #        rx MNCC_SETUP_REQ for unknown subscriber number '100201'
    #    goes to osmo-sip-connector, hits the catch-all and comes back as
    #        INVITE got status(503), releasing leg
    #
    #    The logic is NOT rewritten: generate_extensions_interop_out and
    #    generate_pjsip_interop_trunks (above in this file) already produce it.
    #    They are replayed here with the real topology, as in point 4.
    #    OP_ID_BASE=1: seen from the native, all remotes are containers and do
    #    carry a backbone address; this is the opposite of the container case,
    #    where the native is the one without.
    local mc5="${OSMO_MULTI_CONF:-/etc/osmocom/osmo-multi.conf}"
    if [ -r "$mc5" ]; then
        local _ops5 _self5 _n5=0 _e5 _i5
        _ops5="$(sed -n 's/^MULTI_OPS=//p' "$mc5" | tr -d '"' | tail -1)"
        _self5="$(sed -n 's/^operator_id[[:space:]]*=[[:space:]]*//p' "$src/osmocom/sms-routing.conf" 2>/dev/null | head -1)"
        case "$_self5" in [1-9]*) ;; *) _self5=1 ;; esac
        for _e5 in $_ops5; do
            IFS=: read -r _i5 _ <<< "$_e5"
            case "$_i5" in [1-9]*) [ "$_i5" -gt "$_n5" ] && _n5="$_i5" ;; esac
        done
        # Idempotence marker: replaying install_configs_native must not stack
        # the same extensions (Asterisk would refuse the duplicates with
        # "already in use" and flood the log).
        local _mk5='; --- interop natif : ajoute par _gab_fixups_natifs ---'
        if [ "$_n5" -gt 1 ]; then
            f="$src/asterisk/extensions.conf"
            if [ -f "$f" ] && ! grep -qF "$_mk5" "$f"; then
                { printf '\n%s\n' "$_mk5"
                  OP_ID_BASE=1 generate_extensions_interop_out "$_self5" "$_n5"; } >> "$f"
            fi
            f="$src/asterisk/pjsip.conf"
            if [ -f "$f" ] && ! grep -qF "$_mk5" "$f"; then
                { printf '\n%s\n' "$_mk5"
                  OP_ID_BASE=1 generate_pjsip_interop_trunks "$_self5" "$_n5"; } >> "$f"
            fi
        fi
    fi
}

install_configs_native() {
    local src=$1 root="${2:-}"
    _gab_fixups_natifs "$src"
    mkdir -p "${root}/etc/osmocom" "${root}/etc/asterisk" "$HOME/.osmocom/bb"
    # /etc/osmocom/.proteges: one file name per line (# comment), never
    # overwritten by the regeneration. The page http://127.0.0.1:8090/ (Configs
    # osmo tab) adds each file it saves; removing the line gives the file back
    # to the template.
    local _prot="${root}/etc/osmocom/.proteges" _f _b
    for _f in "$src/osmocom"/*; do
        [ -e "$_f" ] || continue
        _b="${_f##*/}"
        if [ -f "$_prot" ] && grep -qxF "$_b" <(sed 's/#.*//; s/[[:space:]]*$//' "$_prot"); then
            printf '  gabarits   %s protege (%s) : conserve\n' "$_b" "$_prot" >&2
            continue
        fi
        cp -f "$_f" "${root}/etc/osmocom/" 2>/dev/null || true
    done
    cp -f "$src/asterisk"/*.conf "${root}/etc/asterisk/" 2>/dev/null || true
    [ -f "$src/bb/mobile.cfg" ]        && cp -f "$src/bb/mobile.cfg"        "$HOME/.osmocom/bb/mobile.cfg"
    [ -f "$src/bb/mobile_group1.cfg" ] && cp -f "$src/bb/mobile_group1.cfg" "$HOME/.osmocom/bb/mobile_group1.cfg"
    if [ -f configs/asound.conf ]; then
        cp -f configs/asound.conf "${root}/etc/asound.conf"
        ALSA_OUTPUT="gsm_out"; ALSA_INPUT="gsm_in"
    fi
}

detect_host_ip() {
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1) || true
    [ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    HOST_IP="${HOST_IP:-127.0.0.1}"
}

# ── tmux auto-attach ────────────────────────────────────────────────────────
# run.sh runs in the background and creates the tmux session 'osmocom'
# (socket /tmp/osmocom_tmux). Wait until it is ready (run.sh finished), then
# attach to it in the current terminal. $1 = run.sh log to watch.
#   AUTO_ATTACH=0   → disabled (stays in the background, manual message)
#   Also disabled without a TTY (scripted/bg) or when already inside tmux.

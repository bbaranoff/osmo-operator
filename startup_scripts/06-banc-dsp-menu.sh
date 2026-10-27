# 06-banc-dsp-menu.sh - part of start.sh (DSP bench, --menu, mobile configs)
# Sourced by start.sh in the main shell: same order, same variables.
banc_dsp() {
    MODE=dsp bash "$BANC_DSP" "$@"
}
banc_dsp_arreter() {
    [ -x "$BANC_DSP" ] || return 0
    banc_dsp --stop "$@"
}
# ALL the Calypso instances (INSTANCE=N: /tmp/c54x-pontN, the over-the-air
# mobile = 2, phone 2 of the TRX = 3, trials = 4...). run.sh --stop (instance 1)
# already takes 2 and 3 down; this collects the rest, then the orphans by name
# (c54x_exe, Calypso QEMU, transceiver).
# banc-rssi (instance 4) and Magnetite (/dev/shm/magnetite, QEMU "-M calypso"
# like the bench) are SEPARATE: neither is stopped here. The protected pids
# are read from their pid files; the pkill below go through this filter
# instead of killing everything that matches.
banc_dsp_pids_proteges() {
    cat /tmp/c54x-pont4/*.pid /dev/shm/magnetite/*.pid 2>/dev/null | tr '\n' ' '
}
banc_dsp_tuer_sauf_proteges() {
    local nom p garde
    garde=" $(banc_dsp_pids_proteges) "
    # pgrep -x: process name (comm), not the command line: a shell containing this text is not targeted
    for nom in "$@"; do
        for p in $(pgrep -x -- "$nom" 2>/dev/null); do
            case "$garde" in *" $p "*) ;; *) kill "$p" 2>/dev/null || true ;; esac
        done
    done
}
banc_dsp_arreter_instances() {
    local d n
    for d in /tmp/c54x-pont[0-9]*; do
        [ -d "$d" ] || continue
        n="${d#/tmp/c54x-pont}"
        [ "$n" = 4 ] && continue                     # banc-rssi: stopped by banc-rssi-stop only
        ls "$d"/*.pid >/dev/null 2>&1 || continue
        [ -x "$BANC_DSP" ] && INSTANCE="$n" AIR=1 OSMO_TRX=0 MODE=dsp bash "$BANC_DSP" --stop >/dev/null 2>&1 || true
        rm -f "$d"/*.pid
    done
    banc_dsp_tuer_sauf_proteges 'c54x_exe --arm' 'qemu-system-arm -M calypso' 'transceiver -l /tmp/osmocom_l2'
    for k in /tmp/calypso_keys[0-9]*.sock /tmp/osmocom_l2_[0-9]*; do
        case "$k" in /tmp/calypso_keys4.sock|/tmp/osmocom_l2_4) continue ;; esac
        rm -f "$k" 2>/dev/null
    done
    return 0
}

# --- 2b. C launcher of QEMU (qosmo) -------------------------------------------
# QEMU is not called directly by 40-qemu.sh: the qosmo tree carries a C
# launcher, tools/qosmo-launch, installed in /usr/local/bin/qosmo. It sets the
# working defaults (calypso machine + DSP ROMs, -cpu arm946, -gdb tcp::1234,
# -serial pty x2, -monitor unix:$RUN_DIR/...), reads l1s/last_rach in the
# ELF, and publishes stable links to the ptys ($RUN_DIR/modem.pty for
# osmocon, $RUN_DIR/irda.pty). Options: --bind, --trx-port, --iq-tee,
# --l1ctl, --monitor, --gdb (see `qosmo --help`).
# The name is passed to run.sh through QOSMO_LAUNCHER; if missing, 40-qemu.sh
# falls back to the historical qemu-system-arm line - said, without blocking.
say_begin "Lanceur QEMU"
: "${QOSMO_LAUNCHER:=/usr/local/bin/${CALYPSO_FORK:-qosmo}}"
export QOSMO_LAUNCHER
if [ -x "$QOSMO_LAUNCHER" ]; then
    say_end " OK " "$C_OK" "Lanceur QEMU" "$QOSMO_LAUNCHER ($("$QOSMO_LAUNCHER" -V 2>/dev/null | head -1))"
elif [ -f "$RUN_ROOT/tools/qosmo-launch/qosmo-launch.c" ] && command -v gcc >/dev/null 2>&1 \
     && make -s -C "$RUN_ROOT/tools/qosmo-launch" install >/dev/null 2>&1 && [ -x "$QOSMO_LAUNCHER" ]; then
    say_end " OK " "$C_OK" "Lanceur QEMU" "$QOSMO_LAUNCHER (compile a l'instant depuis $RUN_ROOT/tools/qosmo-launch)"
else
    say_end "WARN" "$C_SK" "Lanceur QEMU" "$QOSMO_LAUNCHER absent : 40-qemu.sh appellera qemu-system-arm directement"
    printf '       %s-> make -C %s/tools/qosmo-launch install%s\n' "$C_DIM" "$RUN_ROOT" "$C_Z"
fi
# ══ --menu: ASK instead of guessing ═══════════════════════════════════════
# The launcher resolves the profile, the node, the inter-STP and the WAN on
# its own, which is what an ISO booting with nobody in front needs. In front
# of a bench, the same silent resolution forces one to re-read the script to
# know what was chosen, and to relaunch with the right options otherwise.
#
# This menu CHANGES no rule: it PRE-FILLS every question with the value the
# launcher would have taken alone, and only writes what the operator changes.
# Validating everything untouched gives exactly the default launch.
#
# It steps aside when nobody can answer (no terminal, --dry-run, NO_MENU=1
# set by start-docker.sh in front of a container): a question without a
# reader is a launch that freezes without saying so.
menu_interactif() {
    [ "${MENU_MODE:-0}" -eq 1 ] || return 0
    [ "${NO_MENU:-0}" = "1" ] && return 0
    [ "$DRY" -eq 1 ] && return 0
    [ -t 0 ] || { printf "  %smenu%s       ignore : pas de terminal\n" "${C_DIM:-}" "${C_Z:-}"; return 0; }

    local has_wt=0
    command -v whiptail >/dev/null 2>&1 && has_wt=1

    # One question, one default, one answer. Without whiptail, fall back to
    # read: a minimal ISO does not always have newt.
    _ask() {   # $1 = title  $2 = question  $3 = default
        local rep
        if [ "$has_wt" -eq 1 ]; then
            rep="$(whiptail --title "$1" --inputbox "$2" 11 70 "$3" 3>&1 1>&2 2>&3)" || rep="$3"
        else
            printf "  %s [%s] : " "$2" "$3" >&2
            read -r rep </dev/tty || rep=""
        fi
        printf "%s" "${rep:-$3}"
    }
    _yesno() { # $1 = title  $2 = question  $3 = default (0=yes 1=no)
        if [ "$has_wt" -eq 1 ]; then
            if [ "$3" -eq 0 ]; then whiptail --title "$1" --yesno "$2" 10 70; else
                whiptail --title "$1" --defaultno --yesno "$2" 10 70; fi
            return $?
        fi
        local d="o" rep
        [ "$3" -eq 0 ] || d="n"
        printf "  %s [%s] : " "$2" "$d" >&2
        read -r rep </dev/tty || rep=""
        case "${rep:-$d}" in [oOyY]*) return 0 ;; *) return 1 ;; esac
    }

    # One choice from a CLOSED list. `_ask` is free input: fine for a node
    # number, not for "gr-gsm or DSP", where any keystroke outside the list
    # gives a broken launch. whiptail --radiolist returns the chosen token;
    # without newt, the entries are numbered and a digit is read.
    #   $1 title  $2 question  $3 default  $4.. = token label token label...
    _menu() {
        local titre="$1" q="$2" def="$3"; shift 3
        local rep
        if [ "$has_wt" -eq 1 ]; then
            local args=() j l
            while [ $# -gt 0 ]; do
                j="$1"; l="$2"; shift 2
                if [ "$j" = "$def" ]; then args+=("$j" "$l" ON); else args+=("$j" "$l" OFF); fi
            done
            rep="$(whiptail --title "$titre" --radiolist "$q" 15 74 4 "${args[@]}" 3>&1 1>&2 2>&3)" || rep="$def"
        else
            local -a jetons=() i=1
            printf "  %s\n" "$q" >&2
            while [ $# -gt 0 ]; do
                jetons+=("$1")
                printf "    %d) %-12s %s\n" "$i" "$1" "$2" >&2
                shift 2; i=$((i+1))
            done
            printf "  choix [%s] : " "$def" >&2
            read -r rep </dev/tty || rep=""
            case "$rep" in
                ''|*[!0-9]*) rep="$def" ;;
                *) rep="${jetons[$((rep-1))]:-$def}" ;;
            esac
        fi
        printf "%s" "${rep:-$def}"
    }

    printf "  %smenu%s       --menu : les defauts proposes sont ceux du lancement automatique\n" \
        "${C_DIM:-}" "${C_Z:-}"

    # ── 1. WHO DOES LAYER 1 ──────────────────────────────────────────────────
    # The first choice, because it drives the second: the DSP has no use for
    # a second base station.
    _L1="$(_menu "Couche 1" \
        "Qui demodule ?\n\n  DSP     (defaut) le C54x execute la mask-ROM TI et decode lui-meme :\n          le mobile campe (SI1-4) et fait sa mise a jour de localisation.\n  gr-gsm  la pile va jusqu a l appel voix. Le DSP ne tourne pas." \
        "$([ "${DSP_MODE:-0}" = 1 ] && echo c54x_exe || echo grgsm_exe)" \
        c54x_exe  "DSP C54x hors QEMU, mask-ROM TI (defaut)" \
        grgsm_exe "couche 1 gr-gsm dans qosmo (pile complete)")"
    case "$_L1" in c54x_exe) DSP_MODE=1 ;; *) DSP_MODE=0 ;; esac

    # ── 2. TOPOLOGY: ALONE OR HYBRID ─────────────────────────────────────────
    # Same axis as CALYPSO_PROFILE, said in bench terms:
    #   seul     = profile `qemu`         -> one BTS, one QEMU
    #   hybride  = profile `faketrx-qemu` -> + fake_trx side-car and an MS#2
    # The default follows the choice above: hybrid in gr-gsm, alone in DSP.
    _topo_def=hybride
    [ "${DSP_MODE:-0}" = 1 ] && _topo_def=seul
    [ "$PROFILE" = qemu ] && _topo_def=seul
    _topo="$(_menu "Topologie" \
        "Combien de stations de base ?\n\n  seul     une BTS et un QEMU. C est ce qu il faut pour le DSP.\n  hybride  + un side-car fake_trx et un second mobile, pour que\n           MS#2 appelle MS#1 sans sortir de la maquette." \
        "$_topo_def" \
        seul    "une BTS, un QEMU" \
        hybride "+ side-car fake_trx et MS#2")"
    case "$_topo" in
        seul)    PROFILE=qemu ;;
        hybride) PROFILE=faketrx-qemu ;;
    esac
    PROFILE_CHOISI=1
    unset _topo _topo_def

    # The other profiles (faketrx alone, noproc) stay reachable, but from the
    # command line: offering them here would weigh down the usual choice.
    PROFILE="$(_ask "Profil" \
        "Profil de pile retenu (modifiable) :\n  faketrx-qemu = hybride   qemu = seul\n  faketrx  noproc  aussi acceptes" \
        "$PROFILE")"

    # The node is already resolved above (--node, environment, /etc/osmo-role,
    # WAN table): THAT result is proposed, not an arbitrary 1.
    NODE_ID="$(_ask "Noeud SS7" \
        "Numero de ce noeud (1-9). Il fixe le point code 1.<noeud><op>.<role>,\nle routing context et les MSISDN <noeud>00<op><rang>." \
        "${NODE_ID:-1}")"
    NODE_OP="$(_ask "Operateur" "Operateur porte par ce noeud (1-9) :" "${NODE_OP:-1}")"
    HUB_IP="$(_ask "Inter-STP" \
        "Adresse du hub SS7 (vide = ne pas toucher au remote-ip en place) :" \
        "${HUB_IP:-$(awk -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' "${ROLE_FILE:-/etc/osmo-role}" 2>/dev/null)}")"

    _yesno "WAN" "Monter le maillage WAN entre noeuds ?" "$([ "${WAN_MESH:-0}" -eq 1 ] && echo 0 || echo 1)" \
        && WAN_MESH=1 || WAN_MESH=0

    _yesno "Configurations" \
        "Regenerer /etc/osmocom et /etc/asterisk depuis les gabarits ?\n\nLa pile sera ARRETEE, les fichiers sauvegardes, puis reecrits\navec l'identite du noeud ci-dessus." \
        "$([ "${REGEN_GABARITS:-0}" -eq 1 ] && echo 0 || echo 1)" \
        && REGEN_GABARITS=1 || REGEN_GABARITS=0

    printf "  %smenu%s       profil=%s  noeud=%s  op=%s  hub=%s  wan=%s  regen=%s\n" \
        "${C_DIM:-}" "${C_Z:-}" "$PROFILE" "${NODE_ID:-?}" "$NODE_OP" \
        "${HUB_IP:-inchange}" "$WAN_MESH" "$REGEN_GABARITS"
}
menu_interactif

# Profile → mapping to the profiles expected by run.sh
case "$PROFILE" in
    faketrx-qemu|hybrid) CALYPSO_PROFILE=hybrid;   MODE=faketrx-qemu ;;
    faketrx)             CALYPSO_PROFILE=faketrx;  MODE=faketrx ;;
    qemu)                CALYPSO_PROFILE=calypso;  MODE=qemu ;;
    noproc|core)         CALYPSO_PROFILE=core;     MODE=noproc; RUN_NO_PROCESS=1 ;;
    *)                   CALYPSO_PROFILE=hybrid;   MODE=faketrx-qemu; PROFILE=faketrx-qemu ;;
esac
export CALYPSO_PROFILE MODE
export RUN_NO_PROCESS="${RUN_NO_PROCESS:-0}"
export ENCRYPTION MS_COUNT HOST_IP
# RAND set as a prefix (e.g. `RAND=0 ./start-native.sh`) forces the
# authentication challenge, through the getenv("RAND") gate of the osmo-hlr +
# osmo-msc patches. RAND must reach BOTH processes: osmo-hlr draws it in the
# vector (SRES/Kc computed on RAND=0 -> LU accepted) and osmo-msc sends it.
# RAND set on osmo-msc ALONE -> mismatch -> LU reject. RAND absent -> normal
# network. core_svc_start (run.sh) starts these daemons in two ways, both
# are covered:
#   - direct child (setsid, no systemd) -> inherits the env: exported.
#   - systemd service -> `systemctl start` does NOT inherit the env:
#     transient drop-in /run/systemd/system/<unit>.service.d/rand.conf +
#     daemon-reload.
[ -n "${RAND:-}" ] && export RAND
if command -v systemctl >/dev/null 2>&1; then
    _rand_changed=0
    for _u in osmo-hlr osmo-msc; do
        systemctl cat "$_u" >/dev/null 2>&1 || continue
        _dd="/run/systemd/system/$_u.service.d"
        [ -f "$_dd/rand.conf" ] && _rand_changed=1
        if [ -n "${RAND:-}" ]; then
            mkdir -p "$_dd" 2>/dev/null \
                && printf '[Service]\nEnvironment=RAND=%s\n' "$RAND" > "$_dd/rand.conf" \
                && _rand_changed=1
        else
            rm -f "$_dd/rand.conf" 2>/dev/null || true
        fi
    done
    [ "$_rand_changed" = 1 ] && systemctl daemon-reload 2>/dev/null || true
    # bounce only if the forcing changes, and HLR BEFORE MSC so that the MSC
    # fetches vectors at RAND=0 again; a normal run without RAND touches nothing.
    if [ -n "${RAND:-}" ] || [ "$_rand_changed" = 1 ]; then
        for _u in osmo-hlr osmo-msc; do
            systemctl is-active --quiet "$_u" 2>/dev/null && systemctl restart "$_u" 2>/dev/null || true
        done
    fi
    unset _u _dd _rand_changed
fi
# Layer 2 client: the command-line option OVERRIDES everything, and it is
# EXPORTED - a value set without export does not reach run.sh (same rule as
# ENCRYPTION, cf. generate_configs.sh).
if [ -n "${L2_CLIENT_CHOISI:-}" ]; then
    CALYPSO_L2_CLIENT="$L2_CLIENT_CHOISI"
fi
export CALYPSO_L2_CLIENT="${CALYPSO_L2_CLIENT:-mobile}"
# ── THE BUFFER OF THE `mobile` ALSA-PULSEAUDIO PLUGIN ───────────────────────
# The mechanism is the one documented in qosmo/run_modules/70-l2.sh ("MUTE
# DOWNLINK"): the `mobile` writes one GSM frame (160 samples, 20 ms) per
# `snd_pcm_writei`, and if the plugin buffer is too short each write returns
# -EPIPE; pq_alsa.c answers with a silent `snd_pcm_prepare()`, which TEARS
# DOWN AND REBUILDS the PulseAudio stream. As soon as a consumer reads
# gsm_audio.monitor (our loopback to the speakers) the minimum latency of the
# sink rises to 26 ms, and short buffers rebuild the stream constantly
# (writer paced at 20 ms like the mobile, 10 s:
#     80 ms -> 16 rebuilds   120 -> 19   160 -> 1   200 -> 0   240 -> 0
# during a real call that is 50 rebuilds per second: stream destroyed at
# every frame, saturated voice). The value is above the first stable step
# (200 ms) with margin for jitter under load.
# The variable is exported HERE because update.sh re-fetches qosmo: its
# internal default may differ, this one wins (`:=`).
# CHECK, during an established call: the sink-input index of the mobile must
# stay FIXED (`pactl list short sink-inputs`, two readings 1 s apart).
export CALYPSO_PULSE_LATENCY_MSEC="${CALYPSO_PULSE_LATENCY_MSEC:-320}"
export LOG_DIR RUN_DIR
# --- 2c. ARM firmware: FIRMWARE_SRC -------------------------------------------
# Both launchers (qosmo/run.sh through bench.env, c54x_exe/run.sh) read
# FIRMWARE_ELF / FIRMWARE_BIN from the environment. FIRMWARE_SRC is the name
# the packaging scripts use (build-debs.sh, 71-debs-banc.sh); it is accepted
# here too so that a call
#     FIRMWARE_SRC=/path/layer1.xxx.elf ./start-native.sh
# loads that firmware into QEMU. A file = the ELF itself; a directory = the
# firmware/ tree (FIRMWARE_DIR, board/<board>/ below it).
# An explicit FIRMWARE_ELF keeps the upper hand.
if [ -n "${FIRMWARE_SRC:-}" ]; then
    if [ -f "$FIRMWARE_SRC" ]; then
        : "${FIRMWARE_ELF:=$FIRMWARE_SRC}"
    elif [ -d "$FIRMWARE_SRC" ]; then
        : "${FIRMWARE_DIR:=$FIRMWARE_SRC}"
        export FIRMWARE_DIR
    else
        printf '  %sFIRMWARE_SRC introuvable : %s%s\n' "$C_SK" "$FIRMWARE_SRC" "$C_Z" >&2
    fi
fi
if [ -n "${FIRMWARE_ELF:-}" ]; then
    # The .bin next to the ELF if it exists (qosmo --bin, c54x_exe); otherwise
    # the launchers apply their own default.
    [ -n "${FIRMWARE_BIN:-}" ] || [ ! -r "${FIRMWARE_ELF%.elf}.bin" ] || FIRMWARE_BIN="${FIRMWARE_ELF%.elf}.bin"
    export FIRMWARE_ELF FIRMWARE_BIN
fi
# --- 3. validation of the critical paths --------------------------------------
say_begin "Validation des chemins"
path_ok=1
_check() {
    local name="$1" val="${!1:-}"
    if [ -z "$val" ]; then
        printf '\n       %s%s non defini%s\n' "$C_DIM" "$name" "$C_Z"
        path_ok=0
    elif [ -e "$val" ]; then
        :
    else
        printf '\n       %s%s introuvable : %s%s\n' "$C_DIM" "$name" "$val" "$C_Z"
        path_ok=0
    fi
}
# Optional variables depending on the profile; only block if present and broken
# (DSP_PROM0 not checked: the ROM is not generated by qosmo - cf. run.sh
#  --check-paths and run_modules/00-prereqs.sh.)
for v in QEMU_BIN FIRMWARE_ELF OSMOCON; do
    # `[ -n x ] && _check || true` would swallow the verdict: _check could set
    # path_ok=0 without the loop letting it through. Explicit form.
    if [ -n "${!v:-}" ]; then _check "$v"; fi
done
if [ $path_ok -eq 1 ]; then
    say_end " OK " "$C_OK" "Validation des chemins"
else
    say_end "WARN" "$C_SK" "Validation des chemins" "certains chemins manquent (run.sh verifiera)"
fi
# --- 4. generation of the mobile configs --------------------------------------
# MS#1 (QEMU / main mobile) and MS#2 (faketrx side-car) for the hybrid profile.
BB_DIR="/root/.osmocom/bb"
mkdir -p "$BB_DIR"
# Possible sources for the mobile template
MS_TEMPLATE=""
for t in \
    "${OQC_ROOT:-}/cfgs/mobile_group1.cfg" \
    "$RUN_ROOT/cfgs/mobile_group1.cfg" \
    "$HERE/configs/mobile.cfg.template" \
    "$HERE/configs/mobile.cfg" \
    "$BB_DIR/mobile_group1.cfg" \
    "$BB_DIR/mobile.cfg"
do
    if [ -f "$t" ]; then MS_TEMPLATE="$t"; break; fi
done
# The MS SIM: "sap" for MS#1 when --sap is requested (its socket is the SAP
# server one, SAP_SOCK), "test" (the template's test SIM) otherwise.
ms_sim_mode() {
    if [ "${SAP_MODE:-0}" = 1 ] && [ "$1" = "${SAP_SOCK:-/tmp/osmocom_sap}" ]; then echo sap; else echo test; fi
}
generate_mobile_cfg() {
    local dest="$1" vty_port="$2" l2sock="$3" sapsock="$4" arfcn="$5" imsi="$6" ki="$7"
    # ALSA devices PER MOBILE. The template carries gsm_out/gsm_in for
    # everybody; keeping that would put both mobiles on the same sink and the
    # same source, i.e. the audio loop (cf. /etc/asound.conf).
    local aout="${8:-gsm_out}" ain="${9:-gsm_in}"
    # GUARD: the template list contains $BB_DIR/mobile.cfg, which is also a
    # DESTINATION. If it is the one selected, `sed "$tpl" > "$dest"` with
    # tpl == dest makes the shell truncate the file BEFORE sed reads it: an
    # EMPTY mobile.cfg, and the mobile no longer starts. Switch to the
    # fallback template rather than self-destruct.
    local tpl="$MS_TEMPLATE"
    if [ -n "$tpl" ] && [ "$tpl" -ef "$dest" ] 2>/dev/null; then
        printf '\n       %sMS_TEMPLATE == destination (%s) : template de secours%s\n' \
            "$C_DIM" "$dest" "$C_Z"
        tpl=""
    fi
    if [ -n "$tpl" ]; then
        # the template carries "sim sap": only the MS#1 of --sap keeps it
        # (delimiter #: the | of s|..| would break the \| alternation of sed)
        local _sim_sed=(-e "s#^\([[:space:]]*\)sim \(sap\|test\|reader\)\$#\1sim $(ms_sim_mode "$sapsock")#")
        sed \
            -e "s|bind 127.0.0.1 424[0-9]|bind 127.0.0.1 ${vty_port}|" \
            -e "s|layer2-socket /tmp/osmocom_l2[_0-9]*|layer2-socket ${l2sock}|" \
            -e "s|sap-socket /tmp/osmocom_sap[_0-9]*|sap-socket ${sapsock}|" \
            "${_sim_sed[@]}" \
            -e "s|stick [0-9]*|stick ${arfcn}|" \
            -e "s|^\([[:space:]]*\)imsi .*|\1imsi ${imsi}|" \
            -e "s|^\([[:space:]]*\)imei .*|\1imei $(rand_imei) 0|" \
            -e "s|^\([[:space:]]*\)ki .*|\1ki comp128 ${ki}|" \
            -e "s|alsa-output-dev .*|alsa-output-dev ${aout}|" \
            -e "s|alsa-input-dev .*|alsa-input-dev ${ain}|" \
            "$tpl" > "$dest"
    else
        # Minimal fallback template
        cat > "$dest" <<EOF
!
! mobile.cfg genere par start-native.sh (secours)
!
log stderr
 logging color 1
 logging print category 1
 logging timestamp 0
!
line vty
 no login
 bind 127.0.0.1 ${vty_port}
!
ms 1
 layer2-socket ${l2sock}
 sap-socket ${sapsock}
 sim $(ms_sim_mode "$sapsock")
 imsi ${imsi}
 ki comp128 ${ki}
 network-selection-mode auto
 stick ${arfcn}
!
EOF
    fi
    _ms_cfg_garantir_tch "$dest" "$aout" "$ain"
    _ms_cfg_garantir_log "$dest"
}

# ── THE tch-voice BLOCK, GUARANTEED, WHATEVER THE TEMPLATE ──────────────────
# The template selected by the loop above is the FIRST one found, almost
# always qosmo/cfgs/mobile_group1.cfg - a file from another repository, which
# update.sh re-fetches, and which does not carry "io-tch-format rtp". The
# generation sed only SUBSTITUTES: what the template lacks, the result lacks.
#
# Without that line, the mobile reads and writes its TCH frames in the Texas
# Instruments layout of real Calypsos, while pont.py codes them with
# libosmocoding, i.e. in the RTP/RFC3551 layout (33 bytes opened by the 0xD
# signature). Both ends then misunderstand each other IN BOTH DIRECTIONS, no
# counter flinches, and the sound comes out robotic (cf. the comment in
# configs/mobile.cfg: downlink ring "d2 2c fd a2" against uplink ring
# "83 00 05 e1 ... ff ff ff ff", a frame with fields).
#
# The template is not fixed - it is not ours - the result is guaranteed: the
# four tch-voice settings are set here, and the whole block is created if
# missing (the fallback template above has none).
# MS_TCH_FORMAT for a bench that wants something other than "rtp".
_ms_cfg_garantir_tch() {
    local dest="$1" aout="${2:-gsm_out}" ain="${3:-gsm_in}" fmt="${MS_TCH_FORMAT:-rtp}"
    [ -f "$dest" ] || return 0
    awk -v aout="$aout" -v ain="$ain" -v fmt="$fmt" '
        BEGIN { vu = 0; dedans = 0 }
        # The block exists: our four settings are put at its head, once.
        /^[[:space:]]*tch-voice[[:space:]]*$/ && !vu {
            vu = 1; dedans = 1
            print " tch-voice"
            print "  io-handler gapk"
            print "  io-tch-format " fmt
            print "  alsa-output-dev " aout
            print "  alsa-input-dev " ain
            next
        }
        # Inside the block: the old copies of THESE four lines are removed,
        # everything else is kept - the other settings as well as the
        # comments, which document the measurements and are worth more
        # than the code.
        dedans {
            if ($0 ~ /^[[:space:]][[:space:]]+(io-handler|io-tch-format|alsa-output-dev|alsa-input-dev)([[:space:]]|$)/) next
            if ($0 ~ /^[[:space:]][[:space:]]+[a-z]/ || $0 ~ /^[!#]/) { print; next }
            dedans = 0
        }
        # No block at all: it is placed right before "no shutdown".
        /^[[:space:]]*no shutdown[[:space:]]*$/ && !vu {
            vu = 1
            print " tch-voice"
            print "  io-handler gapk"
            print "  io-tch-format " fmt
            print "  alsa-output-dev " aout
            print "  alsa-input-dev " ain
        }
        { print }
    ' "$dest" > "${dest}.tch" 2>/dev/null && mv -f "${dest}.tch" "$dest" || rm -f "${dest}.tch"
}
# ── THE log stderr BLOCK, GUARANTEED, SAME SHAPE EVERYWHERE ─────────────────
# qosmo/cfgs/mobile_group1.cfg and c54x_exe/mobile_pont.cfg carry a "log
# stderr" (color, timestamp, category); configs/mobile.cfg carries NONE -
# only the "log gsmtap". The file placed in /root/.osmocom/bb would otherwise
# depend on the template selected first, and mobile.log would come out either
# with colors and its 17-digit timestamp (what the osmo-fft-snap.py panel and
# rapport-run.sh can read) or with the libosmocore defaults plus the qosmo -d
# mask. THE block is set here, once, whatever the template: the seven
# categories the bench follows in debug, color per subsystem, compact
# timestamp. BEWARE of the two timestamps of libosmocore 1.12: "logging
# timestamp 1" = ctime ("Mon Oct 19 10:10:03 2026", 25 columns); "logging
# print extended-timestamp 1" = YYYYMMDDhhmmssnnn (17 digits, sortable, and
# the only one tail_lines() of the panel can strip). The second one is set.
# The gsmtap block is not touched.
MS_LOG_STDERR_BLOC=' logging filter all 1
 logging color 1
 logging timestamp 0
 logging print extended-timestamp 1
 logging print category 1
 logging level mm debug
 logging level rr debug
 logging level cc debug
 logging level sms debug
 logging level plmn debug
 logging level sim debug
 logging level sap debug'
_ms_cfg_garantir_log() {
    local dest="$1" existe=0
    [ -f "$dest" ] || return 0
    # Whether the block exists is known BEFORE reading: in mobile_group1.cfg,
    # "line vty" precedes "log stderr", and a single pass would insert a second
    # block before line vty before reaching the first one.
    grep -q '^log stderr[[:space:]]*$' "$dest" && existe=1
    awk -v bloc="$MS_LOG_STDERR_BLOC" -v existe="$existe" '
        BEGIN { vu = 0; dedans = 0 }
        # The block exists: it is replaced entirely, once.
        /^log stderr[[:space:]]*$/ && !vu {
            vu = 1; dedans = 1
            print "log stderr"; print bloc
            next
        }
        dedans {
            if ($0 ~ /^[[:space:]]+[a-z]/) next     # old line of the block
            dedans = 0                               # "!" or other: end of the block
        }
        # No block: it is placed before the first "log gsmtap", otherwise
        # before "line vty".
        /^(log gsmtap|line vty)([[:space:]]|$)/ && !existe && !vu {
            vu = 1
            print "log stderr"; print bloc; print "!"
        }
        { print }
        END { if (!vu) { print "!"; print "log stderr"; print bloc; print "!" } }
    ' "$dest" > "${dest}.log" 2>/dev/null && mv -f "${dest}.log" "$dest" || rm -f "${dest}.log"
}
# ⚠️ THE RUN DOES NOT USE mobile.cfg FOR MS#1. The Calypso mobile runs with
#     mobile -c /root/.osmocom/bb/mobile_group1.cfg
# and mobile_group1.cfg is COPIED as is by qosmo (run_modules/20-mobile-cfg.sh,
# from $QEMU_TREE/cfgs): a static file, never derived from the operator. It
# carries the identity of operator 1 - IMSI 001010001000001, ARFCN 514 -
# whatever the operator; on operator 2 (HLR expects 002010002000001, BTS on
# 516) the mobile would show up with 001010001000001 on 514:
#     Mobile Subscriber of MS '1':
#      IMSI: 001010001000001
#      Status: U2_NOT_UPDATED  IMSI detached  LAI: invalid
#      Registered PLMN: MCC-MNC 001-01
#
# So MS#1 is written to BOTH files. mobile.cfg stays the reference (other
# modules read it), mobile_group1.cfg is the one the launcher opens. Check
# which one is running before trusting a setting set here:
#     pgrep -a mobile
# ── IMSI and Ki of the MS: the HLR plan, not the plan of operator 1 ────────
# On operator 2, whose network broadcasts another MNC, a mobile presenting
# the IMSI of an operator 1 subscriber has no record at the MSC nor the HLR:
# the Location Updating stays unanswered while the whole stack is up.
# The plan is the one of start-docker.sh ("HLR subscribers" section):
#     IMSI = MCC MNC <operator on 4 digits> <MS index on 6 digits>
#     Ki   = 00112233445566778899aabbccdd <MS index> <operator>
# MCC and MNC are re-read from the configuration ACTUALLY deployed - the one
# the BTS broadcasts - and not guessed again from a convention.
MS_OP_ID="${OPERATOR_ID:-1}"
MS_MCC="$(awk '$1=="network" && $2=="country" && $3=="code" {print $4; exit}' /etc/osmocom/osmo-bsc.cfg 2>/dev/null || true)"
MS_MNC="$(awk '$1=="mobile" && $2=="network" && $3=="code" {print $4; exit}' /etc/osmocom/osmo-bsc.cfg 2>/dev/null || true)"
# ── THE FALLBACKS FOLLOW THE PLAN, THEY DO NOT INVENT IT ────────────────────
# The fallbacks apply when osmo-bsc.cfg is not readable yet (configs not
# regenerated at that moment). The real plan (/var/tmp/osmo-annuaire.csv):
#   op 1 -> 001|01   op 2 -> 001|02   op 3 -> 001|03
# The WHOLE bench is in MCC 001 - the test PLMN, common to all operators -
# and the MNC is what tells them apart. A hard-coded MNC "01" would give
# operator 2 the MNC of operator 1 and ms_imsi() would produce
# 001|01|0002|000001: subscribers that reach the HLR WITHOUT MSISDN nor IMEI
# ("none" / "-------------"), which the VLR cannot attach to anyone.
# On the first launch of a fresh installation, osmo-bsc.cfg is still the
# template: it holds the MARKERS __MCC__ / __MNC__, which would otherwise be
# written as is into the mobile_*.cfg ("imsi __MCC____MNC__0001000002",
# refused by mobile) and exported to run.sh. Only digits count; otherwise,
# the fallback below.
[[ "$MS_MCC" =~ ^[0-9]{3}$ ]] || MS_MCC=""
[[ "$MS_MNC" =~ ^[0-9]{2,3}$ ]] || MS_MNC=""
[ -n "$MS_MCC" ] || MS_MCC="001"
[ -n "$MS_MNC" ] || MS_MNC="$(printf '%02d' "$MS_OP_ID")"
ms_imsi() { printf '%s%s%04d%06d' "$MS_MCC" "$MS_MNC" "$MS_OP_ID" "$1"; }

# ── THE FOURTH PROVISIONER ──────────────────────────────────────────────────
# run.sh embeds its own subscriber module (run_modules/21-abonnes-hlr.sh, in
# qosmo). It computes its IMSI as MCC+MNC+operator+rank - the same formula as
# ours - but reads MCC and MNC from /etc/osmocom/osmo-msc.cfg through a path
# that does not always succeed; it then falls back to its defaults, 001 and
# 01, and on operator 2 would build 001010002000001: a subscriber nobody
# presents, with an MSISDN of the old plan (20001) on top, which HOLDS that
# number and prevents the right subscriber from getting it.
#
# It honours MCC and MNC from the environment. With them set, its IMSI becomes
# exactly the one start-docker.sh has already provisioned - and its own state
# check (mod_abonnes_hlr_status) finds it present, so it does nothing. The
# duplicate is neutralized by its idempotence, without touching qosmo.
# WITHOUT "${MNC:-...}": 03-affichage.sh has already sourced globals.conf
# (MNC="01"), which would win over the deployed config. MS_MCC/MS_MNC ARE the
# deployed config.
export MCC="$MS_MCC"
export MNC="$MS_MNC"

# ── The radio plan: READ, not recomputed ────────────────────────────────────
# generate_configs.sh writes it to /etc/osmocom/radio-plan.env together with
# the configurations. Re-reading it here guarantees that the mobile agrees
# with what the BTS REALLY broadcasts - not with a copied formula that would
# end up diverging. The fallbacks remain, for a bench set up without this file.
if [ -r /etc/osmocom/radio-plan.env ]; then
    # shellcheck disable=SC1091
    . /etc/osmocom/radio-plan.env
    printf '  %splan radio%s  lu dans /etc/osmocom/radio-plan.env\n' "${C_DIM:-}" "${C_Z:-}"
fi

# ── The two radio channels, and which MS attaches to which ──────────────────
# Hard-coded ARFCNs (514 and 516) are the values of operator 1, and of it
# alone. On operator 2 the main BTS moves to 516; with the side-car staying
# there too, two cells share the same frequency, their bursts mixed in a
# medium where fake_trx pairs by frequency: the mobile sends its RACH, no
# Immediate Assignment comes back.
#
# MS#1 follows the main BTS, whose ARFCN is read from the configuration
# ACTUALLY deployed - the BSC decides it and imposes it to the BTS through
# OML, so that is where the truth is.
MS_ARFCN1="${PLAN_ARFCN:-}"
[ -n "$MS_ARFCN1" ] || MS_ARFCN1="$(awk '/^ bts 0$/{b=1} b && /^ *arfcn /{print $2; exit}' /etc/osmocom/osmo-bsc.cfg 2>/dev/null || true)"
# Same guard as for MCC/MNC: a template not regenerated yet gives __ARFCN__.
[[ "$MS_ARFCN1" =~ ^[0-9]+$ ]] || MS_ARFCN1=""
[ -n "$MS_ARFCN1" ] || MS_ARFCN1=$(( 512 + MS_OP_ID * 2 ))

# MS#2 follows the side-car. That one is decided by US: the qosmo module
# 13-sidecar-cfg.sh reads SC_ARFCN and SC_UNIT_ID from the environment
# (run_modules/_lib/radio.sh: ": "${SC_ARFCN:=516}""). Setting them here
# avoids modifying qosmo, and keeps a single source per value - the same
# formulas as generate_configs.sh.
export SC_ARFCN="${SC_ARFCN:-${PLAN_ARFCN_BTS1:-$(( 612 + MS_OP_ID * 2 ))}}"
export SC_UNIT_ID="${SC_UNIT_ID:-${PLAN_UNIT_ID_BTS1:-$(( 6000 + MS_OP_ID * 10 + 2 ))}}"
MS_ARFCN2="$SC_ARFCN"
ms_ki()   { printf '00 11 22 33 44 55 66 77 88 99 aa bb cc dd %02x %02x' "$1" "$MS_OP_ID"; }

# Random IMEI, Luhn check digit computed - one per MS, never two identical in
# the same trace.
rand_imei() {
    local body d i sum=0 dbl parity
    body="35892500$(printf '%06d' "$(( (RANDOM << 15 | RANDOM) % 1000000 ))")"
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


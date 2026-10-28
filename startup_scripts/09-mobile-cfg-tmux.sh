# 09-mobile-cfg-tmux.sh - part of start.sh (mobile configs, TRX bridge,
# air mesh, summary, run.sh arguments, tmux session purge)
# Sourced by start.sh in the main shell: same order, same variables.
MS1_GROUP_CFG="$BB_DIR/mobile_group1.cfg"
if [ "$MS1_GROUP_CFG" != "$MS1_CFG" ]; then
    generate_mobile_cfg "$MS1_GROUP_CFG" \
        4247 \
        /tmp/osmocom_l2 \
        "${SAP_SOCK:-/tmp/osmocom_sap}" \
        "$MS_ARFCN1" \
        "$(ms_imsi 1)" \
        "$(ms_ki 1)"
    printf '  %sMS#1%s       aussi ecrit dans %s (le fichier que run.sh ouvre)\n' \
        "${C_DIM:-}" "${C_Z:-}" "$MS1_GROUP_CFG"
fi
say_end " OK " "$C_OK" "Generation mobile MS#1" "$MS1_CFG"
say_begin "Generation mobile MS#2 (faketrx)"
MS2_CFG="$BB_DIR/mobile_faketrx_bts1.cfg"
generate_mobile_cfg "$MS2_CFG" \
    4248 \
    /tmp/ms2_l2 \
    /tmp/ms2_sap \
    "$MS_ARFCN2" \
    "$(ms_imsi 2)" \
    "$(ms_ki 2)" \
    gsm_out gsm_in
say_end " OK " "$C_OK" "Generation mobile MS#2 (faketrx)" "$MS2_CFG"
# ── THE EMULATED SIM READS THE SAME FILE AS THE MOBILE ──────────────────────
# CALYPSO_SIM_CFG is the ONLY environment variable the QEMU model reads
# (hw/arm/calypso/calypso_sim.c): it takes the "test-sim" section - imsi and
# ki comp128 - in mobile.cfg format, i.e. exactly the MS#1 file generated
# above. Without it, the emulated SIM keeps its default IMSI
# (001010000000001), unknown to the HLR provisioned with the plan.
# (The MS#2 side-car reads SC_MOBILE_CFG / the file itself.)
export CALYPSO_SIM_CFG="$MS1_CFG"

# --- TRX BRIDGE mode (CALYPSO_BRIDGE=pont): the in-house bridge is the transceiver
# The bridge (pont/pont.py) presents itself as a TRX-UDP transceiver to
# osmo-bts-trx (5700/5701/5702), decodes the DL bursts into L2 -> GSMTAP
# 4730/4731 towards the QEMU model, and encodes the UL from the sidebands
# /dev/shm/calypso_* -> TRXD -> BTS. It NEEDS osmo-bts-trx on the other side:
# qosmo/60-bts.sh launches it, and the barrier below waits for it before
# launching the bridge.
if [ "${CALYPSO_BRIDGE:-}" = pont ]; then
    export CALYPSO_BRIDGE
    # ── THE BRIDGE COMES FROM THE REPO ─────────────────────────────────────
    # $HERE is the directory of THIS script: the bridge always travels with
    # it, never a copy outside the repo (which would drift silently from
    # pont/pont.py). PONT_PY remains available to try a variant, as an
    # explicit choice.
    # grgsm setup: its bridge is pont.py (pont_dsp.py is the DSP setup's,
    # launched by c54x_exe/run.sh). See pont/pont.py.
    _PONT="${PONT_PY:-$HERE/pont/pont.py}"

    # ── THE BRIDGE MUST KNOW WHICH CELL IT WORKS ON ─────────────────────────
    # pont.py does the channel coding/decoding between the QEMU Calypso and
    # the BTS. It reads PONT_ARFCN and PONT_BSIC from its environment.
    #
    # The BSIC is not decorative: its low part (BCC) IS the training sequence
    # of the dedicated channels. With a wrong BSIC the correlation fails and
    # the blocks do not decode: the mobile sends its RACH, the network
    # answers, and the Immediate Assignment is never handed to the Calypso.
    #
    # They are taken from the radio plan published by generate_configs.sh,
    # with the same fallbacks as the mobiles.
    export PONT_ARFCN="${PONT_ARFCN:-${PLAN_ARFCN:-$MS_ARFCN1}}"
    export PONT_BSIC="${PONT_BSIC:-${PLAN_BSIC:-$(( MS_OP_ID * 7 % 64 ))}}"
    printf '  %spont TRX%s : cellule ARFCN %s BSIC %s\n' \
        "${C_DIM:-}" "${C_Z:-}" "$PONT_ARFCN" "$PONT_BSIC"
    # ARM THE LAUNCHER ONLY ON A REAL START.
    # This block runs BEFORE the `case "$ACTION"` below. On `--stop` (as on
    # --list/--status/--check-paths) the deferred launcher must not be armed:
    # `run.sh --stop` would kill it at once. A bridge ALREADY ALIVE is
    # stopped by the teardown (`f:pont/pont.py` in _td_patterns) and by
    # mod_teardown_stop.
    if [ "$ACTION" != start ]; then
        printf '  %spont TRX%s : non arme (action=%s, pas un demarrage)\n' \
               "${C_DIM:-}" "${C_Z:-}" "$ACTION"
    elif [ -r "$_PONT" ]; then
        # SINGLETON: kill a previous bridge, otherwise it holds 5700-5702 and
        # the run.sh teardown fails ("restes du run precedent : port:5700...").
        pkill -f "$_PONT" 2>/dev/null || true
        # KILLALL of the bench's python3.
        # The named pattern above misses any bridge launched under another
        # path (PONT_PY override, a .bak backup), which would make the
        # teardown fail on "port:5700 port:5701 port:5702".
        # WHAT IT TAKES DOWN, besides the bridge: fake_trx.py (the MS#2
        # transceiver), sms-interop-relay.py (inter-operator SMS routing,
        # OUTSIDE the run.sh stack so not relaunched automatically),
        # gsm_sniff.py and the tmux pane scripts. Acceptable HERE because this
        # is the path of a START (ACTION=start): the run.sh teardown stops
        # everything two seconds later anyway. Do NOT repeat this in a run.sh
        # module, where it would kill the timestamp filter of the current run.
        # CALYPSO_NO_KILLALL=1 to skip it.
        if [ "${CALYPSO_NO_KILLALL:-0}" != "1" ]; then
            printf '  %spont TRX%s : python3 du banc termines (fake_trx, pont, airmesh, relais SMS, modem AT)\n' "${C_DIM:-}" "${C_Z:-}"
            killall_python -9 || true
        fi
        sleep 1
        printf '  %spont TRX%s : transceiver TRX-UDP d osmo-bts-trx (pont/pont.py)\n' "${C_DIM:-}" "${C_Z:-}"
        # DEFERRED LAUNCH: run.sh first does its teardown (which checks that
        # 5700-5702 are FREE). So bind only afterwards, otherwise we block
        # ourselves.
        # LOG OUTSIDE LOG_DIR: run.sh archives/erases LOG_DIR during its
        # teardown; a pont.log opened before would end up on a DELETED inode
        # (invisible output, "(deleted)" in /proc/<pid>/fd/1). /dev/shm
        # survives.
        # setsid: the bridge must survive the end of the start-native shell.
        # The barrier waits for an EVENT, not a duration (the teardown time
        # depends on the size of the archived logs): osmo-bts-trx, the
        # bridge's TRX-UDP peer, only starts AFTER the teardown, so its
        # presence proves the ports are ours.
        # It waits for BOTH edges: the disappearance (the teardown happened -
        # without --stop the osmo-bts-trx of the PREVIOUS run is still there
        # and pgrep would succeed at once), then the appearance (the stack is
        # back up). With --stop the first edge is already crossed.
        ( _n=0
          while [ "$_n" -lt 180 ] && pgrep -x osmo-bts-trx >/dev/null 2>&1; do
              _n=$((_n + 1)); sleep 1
          done
          _dispar=$_n
          while [ "$_n" -lt 180 ] && ! pgrep -x osmo-bts-trx >/dev/null 2>&1; do
              _n=$((_n + 1)); sleep 1
          done
          if [ "$_n" -ge 180 ]; then
              echo "[pont] osmo-bts-trx jamais (re)vu apres 180 s - demarrage quand meme"
          else
              echo "[pont] osmo-bts-trx parti a ${_dispar}s puis revu a ${_n}s - la pile est debout, on binde"
          fi
          sleep 1
          pkill -f "$_PONT" 2>/dev/null; sleep 1
          exec setsid python3 -u "$_PONT" ) >/dev/shm/pont.log 2>&1 &
        disown $! 2>/dev/null || true
        printf '  %spont: journal%s /dev/shm/pont.log (hors LOG_DIR, efface par le teardown)\n' "${C_DIM:-}" "${C_Z:-}"
    else
        printf '  pont introuvable (%s)\n' "$_PONT"
    fi
fi

# --- BURST MESH (--air-mesh): the radio medium becomes shared ---------------
# Two nodes otherwise talk at the top of the stack - a SIP trunk, an SMS
# relay, M3UA towards a hub - each keeping its radio sealed: the mobile of
# operator 1 CANNOT hear the BTS of operator 2. Here the burst crosses:
# pont/airmesh.py takes what passes on the local fake_trx and exchanges it
# with the peers. See the airmesh.py header for details - notably why TWO
# transceiver slots are needed, and how they are obtained without modifying
# a line of qosmo.
if [ "${AIR_MESH:-0}" = "1" ]; then
    _AIRMESH="${AIRMESH_PY:-${HERE}/pont/airmesh.py}"
    [ -f "$_AIRMESH" ] || _AIRMESH=/opt/GSM/osmo-operator/pont/airmesh.py
    if [ ! -f "$_AIRMESH" ]; then
        printf '  %sair-mesh%s : airmesh.py introuvable - maillage de bursts non lance\n' "${C_KO:-}" "${C_Z:-}"
    else
        # TWO MORE MOBILES THAN THE BENCH HAS. fake_trx creates one
        # transceiver per declared mobile; airmesh takes the last two and
        # tunes them differently (one as a mobile, the other as a BTS).
        # Without this +2 there is no free slot and airmesh stays silent.
        _NMS_REEL="${N_MS:-2}"
        N_MS=$(( _NMS_REEL + 2 )); export N_MS
        _BBP="${BB_BASE_PORT:-6700}"; _BBS="${BB_PORT_STEP:-3}"
        _TRX_MS=$((  _BBP + (_NMS_REEL + 1 - 1) * _BBS ))   # slot N+1
        _TRX_BTS=$(( _BBP + (_NMS_REEL + 2 - 1) * _BBS ))   # slot N+2

        # The peers come from the WAN table: every node that is not us.
        _PAIRS=""
        for _tok in ${WAN_NODES:-}; do
            _pid="${_tok%%:*}"; _rest="${_tok#*:}"; _pip="${_rest%%:*}"
            [ -n "$_pid" ] && [ -n "$_pip" ] || continue
            [ "$_pid" = "${NODE_ID:-1}" ] && continue
            _PAIRS="$_PAIRS --pair ${_pid}:${_pip}:${AIRMESH_PORT:-4739}"
        done

        printf '  %sair-mesh%s   noeud %s  arfcn %s  emplacements TRXD %s et %s  pairs:%s\n' \
            "${C_DIM:-}" "${C_Z:-}" "${NODE_ID:-1}" "${ARFCN:-1}" \
            "$_TRX_MS" "$_TRX_BTS" "${_PAIRS:- aucun}"

        # Wait until fake_trx has BOUND the slot, not for a duration: it only
        # starts after the run.sh teardown, whose length depends on the size
        # of the archived logs. A fixed delay would make this launch a race -
        # same barrier as the bridge, just above.
        ( _n=0
          while [ "$_n" -lt 180 ] && ! ss -uln 2>/dev/null | grep -q ":$(( _TRX_MS + 1 ))\b"; do
              _n=$((_n + 1)); sleep 1
          done
          if [ "$_n" -ge 180 ]; then
              echo "[airmesh] emplacement $(( _TRX_MS + 1 )) jamais ouvert par fake_trx apres 180 s"
              echo "[airmesh] verifiez que le banc tourne bien avec N_MS=${N_MS} (deux de plus que ${_NMS_REEL})"
              exit 1
          fi
          echo "[airmesh] fake_trx a ouvert nos emplacements apres ${_n} s"
          sleep 1
          # shellcheck disable=SC2086
          exec setsid python3 -u "$_AIRMESH" \
              --node "${NODE_ID:-1}" --arfcn "${ARFCN:-1}" \
              --port "${AIRMESH_PORT:-4739}" \
              --trx-ms "$_TRX_MS" --trx-bts "$_TRX_BTS" \
              --topologie "${HERE}/data/air-mesh.txt" \
              $_PAIRS ) >/dev/shm/airmesh.log 2>&1 &
        printf '  %sair-mesh: journal%s /dev/shm/airmesh.log\n' "${C_DIM:-}" "${C_Z:-}"
    fi
fi

# --- 6. summary ---------------------------------------------------------------
banner
printf '  %sprofil%s     %s (%s)\n' "$C_DIM" "$C_Z" "$CALYPSO_PROFILE" "$MODE"
printf '  %senviron.%s   %s\n' "$C_DIM" "$C_Z" \
    "$(case "$RUNTIME_ENV" in docker) echo "conteneur docker" ;; vm) echo "machine virtuelle" ;; *) echo "machine physique" ;; esac)"
if [ -n "$NODE_ID" ]; then
    printf '  %snoeud%s      %s  %s(%s)%s\n' "$C_DIM" "$C_Z" "$NODE_ID" "$C_DIM" "${NODE_ID_SRC:-?}" "$C_Z"
else
    printf '  %snoeud%s      %s\n' "$C_DIM" "$C_Z" "aucun - identite SS7 inchangee"
fi
printf '  %srun.sh%s     %s\n' "$C_DIM" "$C_Z" "$RUN_SH"
[ -z "${FIRMWARE_ELF:-}" ] || printf '  %sfirmware%s   %s%s\n' "$C_DIM" "$C_Z" "$FIRMWARE_ELF" \
    "${FIRMWARE_SRC:+ (FIRMWARE_SRC)}"
# IN --dsp, MS#1 IS NOT THE GENERATED FILE.
# The fork's `l2` module is removed from the plan: /root/.osmocom/bb/mobile.cfg
# is opened by nobody, and the running mobile is the DSP bench's
# (mobile_pont.cfg, VTY 4347). The summary names that file and that port.
if [ "$DSP_BANC" = 1 ] && [ "${OSMO_TRX:-0}" = 1 ]; then
    printf '  %sMS#1%s       non lance : le Calypso de QEMU est le TRX de la BTS#0 (--osmo-trx : trx.highram.elf + transceiver, %s)\n' \
        "$C_DIM" "$C_Z" "$(trx_ts_desc)"
elif [ "$DSP_BANC" = 1 ]; then
    _ms1_cfg="${MOBILE_CFG:-$(dirname "$BANC_DSP")/mobile_pont.cfg}"
    _ms1_vty="$(sed -n 's/^ *bind 127.0.0.1 \([0-9]*\).*/\1/p' "$_ms1_cfg" 2>/dev/null | head -1)"
    printf '  %sMS#1%s       %s  IMSI %s  ARFCN %s  VTY %s  %s(banc DSP)%s\n' \
        "$C_DIM" "$C_Z" "$_ms1_cfg" "$(ms_imsi 1)" "$MS_ARFCN1" "${_ms1_vty:-?}" "$C_DIM" "$C_Z"
    printf '  %s           %s non lance (module l2 retire du plan)%s\n' \
        "$C_DIM" "$MS1_CFG" "$C_Z"
else
    printf '  %sMS#1%s       %s  IMSI %s  ARFCN %s  VTY 4247\n' "$C_DIM" "$C_Z" "$MS1_CFG" "$(ms_imsi 1)" "$MS_ARFCN1"
fi
# THE MOBILE VTY PORT IS PUBLISHED, NOT GUESSED. In --dsp the mobile listens
# on 4347 (mobile_pont.cfg), otherwise on 4247 - and everything that opens
# "the mobile console" (launch.sh --vty, the osmo-panel.py inset, the
# osmo-egprs-web dashboard for the Kc and the bb1 VTY) reads it from
# /run/osmo-banc/ms1-vty (session tools) or from the systemd environment
# (OSMO_BB1_VTY_PORT, read by server.js when the dashboard restarts, below).
# Erased at stop.
MS1_VTY_PORT="${_ms1_vty:-4247}"
# THE MOBILE LOG IS PUBLISHED THE SAME WAY. It lives under LOG_DIR (qosmo,
# run_modules/70-l2.sh: "mobile ... >>LOG_DIR/mobile.log"), and in --dsp under
# the c54x_exe RUNDIR (run.sh: RUNDIR/mobile.log, /tmp/c54x-pont by default).
# LOG_DIR follows the launching uid (XDG_RUNTIME_DIR), so the real path is
# written to /run/osmo-banc/mobile-log and pushed into the systemd environment
# (OSMO_MOBILE_LOG) for the osmo-fft-snap.py inset. Erased at stop, with
# ms1-vty.
# --bts --ms / --ms-magnetite: the phone is INSTANCE 2 of run.sh
# (14-demarrage.sh, INSTANCE=2 AIR=1), its RUNDIR is /tmp/c54x-pont2;
# /tmp/c54x-pont is the TRX's, without mobile.
_ms1_rundir="${RUNDIR:-/tmp/c54x-pont}"
[ "${OSMO_TRX:-0}" = 1 ] && [ "${MS_AIR:-0}" = 1 ] && _ms1_rundir="${RUNDIR:-/tmp/c54x-pont2}"
MS1_LOG_NOM="mobile.log"
if [ "$DSP_BANC" = 1 ] && [ -n "${MS_MAGNETITE:-}" ]; then
    # Magnetite: no L23 mobile, the phone log is the L1/TI stack trace of rvinterf
    MS1_LOG="$_ms1_rundir/rvinterf.log"
    MS1_LOG_NOM="rvinterf"
elif [ "$DSP_BANC" = 1 ]; then
    MS1_LOG="$_ms1_rundir/mobile.log"
else
    MS1_LOG="$LOG_DIR/mobile.log"
fi
# Exported: the tmux ms1 window (qosmo tmux_modules/bench.sh) follows the
# phone log (rvinterf with Magnetite) instead of an empty mobile.log.
export MS1_LOG MS1_LOG_NOM
if [ "$ACTION" = "start" ] && [ "$DRY" -ne 1 ]; then
    mkdir -p /run/osmo-banc 2>/dev/null && chmod 755 /run/osmo-banc 2>/dev/null
    printf '%s\n' "$MS1_VTY_PORT" > /run/osmo-banc/ms1-vty 2>/dev/null && chmod 644 /run/osmo-banc/ms1-vty 2>/dev/null
    printf '%s\n' "$MS1_LOG" > /run/osmo-banc/mobile-log 2>/dev/null && chmod 644 /run/osmo-banc/mobile-log 2>/dev/null
    command -v systemctl >/dev/null 2>&1 && systemctl set-environment "OSMO_BB1_VTY_PORT=$MS1_VTY_PORT" "OSMO_MOBILE_LOG=$MS1_LOG" 2>/dev/null || true
fi
printf '  %sMS#2%s       %s  IMSI %s  ARFCN %s  VTY 4248\n' "$C_DIM" "$C_Z" "$MS2_CFG" "$(ms_imsi 2)" "$MS_ARFCN2"
printf '  %sjournaux%s   %s\n' "$C_DIM" "$C_Z" "$LOG_DIR"
printf '  %s%-10s%s %s\n' "$C_DIM" "$MS1_LOG_NOM" "$C_Z" "$MS1_LOG"
printf '  %schiffrement%s %s\n' "$C_DIM" "$C_Z" "$ENCRYPTION"
printf '\n'
# --- 7. actions delegated to run.sh -------------------------------------------
RUN_ARGS=()
[ "$DRY" -eq 1 ]     && RUN_ARGS+=(--dry-run)
[ "$FORCE" -eq 1 ]   && RUN_ARGS+=(--force)
[ "$VERBOSE" -eq 1 ] && RUN_ARGS+=(--verbose)
RUN_ARGS+=(--profile "$CALYPSO_PROFILE")
# --restart goes into RUN_ARGS, where it is visible in --dry-run and in the
# line printed just before the exec.
# CALYPSO_NO_RESTART=1 to start without resetting.
[ "${CALYPSO_NO_RESTART:-0}" = "1" ] || RUN_ARGS+=(--restart)
# run.sh already reads CALYPSO_NO_ATTACH (run.sh:8), but a variable is not
# visible in --dry-run nor in the line printed just before the exec: the
# option carries the same setting where one looks for it.
[ "${CALYPSO_NO_ATTACH:-0}" = "1" ] && RUN_ARGS+=(--no-attach)
# --icount and --assembly-logs towards run.sh, hence 40-qemu.sh (--grgsm
# path; in --dsp the qemu module is removed, c54x_exe/run.sh reads
# QEMU_ICOUNT and ASSEMBLY_LOGS itself). Same -d / -dfilter as the DSP bench.
case "${QEMU_ICOUNT:-}" in ''|0|off) ;; *) RUN_ARGS+=("--icount=$QEMU_ICOUNT") ;; esac
if [ "${ASSEMBLY_LOGS:-0}" = 1 ]; then
    RUN_ARGS+=(--asm)
    # in_asm alone by default: exec,nochain (one line per executed block)
    # makes the ARM about 150 times slower and breaks the attach, see the
    # --assembly-logs help.
    export QEMU_ASM_FLAGS="${ASSEMBLY_LOGS_FLAGS:-in_asm}"
    [ -n "${ASSEMBLY_LOGS_FILTRE:-}" ] && export QEMU_ASM_FILTRE="$ASSEMBLY_LOGS_FILTRE"
fi
# ── The tmux sessions of a previous run ─────────────────────────────────────
# The run.sh teardown stops the processes but leaves the tmux session up. At
# the next start, its pane module RECREATES its windows in the surviving
# session: there are then TWO windows named "all", and tmux can no longer
# resolve the target (`tmux split-window -t calypso:all` -> "can't find
# window: all"); the splits fail and the barrier reports missing panes.
#
# So the sessions of the previous run are erased with it. Three conventions
# coexist depending on the launcher, all are covered; none needs to exist.
purge_sessions_tmux() {
    local n=0 s
    for s in calypso gapk osmo; do
        if tmux has-session -t "$s" 2>/dev/null; then
            tmux kill-session -t "$s" 2>/dev/null && n=$((n + 1))
        fi
    done
    if tmux -S /tmp/osmocom_tmux has-session -t osmocom 2>/dev/null; then
        tmux -S /tmp/osmocom_tmux kill-session -t osmocom 2>/dev/null && n=$((n + 1))
    fi
    [ "$n" -gt 0 ] && printf '  %ssessions tmux%s   %s session(s) du run precedent effacee(s)\n' \
        "${C_DIM:-}" "${C_Z:-}" "$n"
    return 0
}


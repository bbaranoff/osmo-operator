# 14-demarrage.sh - part of start.sh (hand-off to run.sh and the DSP bench)
# Sourced by start.sh in the main shell: same order, same variables.
if [ "$DSP_BANC" = 1 ]; then
    # ── THE FORK BRINGS UP EVERYTHING EXCEPT THE CALYPSO CHAIN ─────────────
    # The fork runs its usual plan; only the four modules that c54x_exe
    # provides (qemu, pty, osmocon, l2) are skipped, and the DSP bench is then
    # launched with its five steps. --no-attach is mandatory: without it the
    # fork attaches to tmux and control never comes back here.
    #
    # The bench settings come from the bench itself (c54x_exe/run_real.sh):
    #   INSNS                    instruction budget per frame (see below)
    #   LOCKSTEP=1               QEMU only advances the frame once the DSP has
    #                            finished the previous one; otherwise it skips
    #                            3 frames out of 4
    #   IQ=none                  no synthetic cell: the bursts come from the
    #                            real BTS, through pont.py
    #   CALYPSO_BSP_STREAM=1     one TS0 burst per frame, in FN order
    #   CALYPSO_RHEA_DMA_XFER=1  without it the API page is never filled:
    #                            no SB, no BCCH, no SI
    # Everything stays overridable: only what the operator did not set is set.
    export MODE=dsp PONT=1
    # --osmo-trx: transceiver instead of mobile, no bridge (c54x_exe/run.sh
    # forces PONT=0 itself; it is set here for the dry-run).
    if [ "${OSMO_TRX:-0}" = 1 ]; then export OSMO_TRX PONT=0; fi
    # ARM asm trace, read by c54x_exe/run.sh (step 2, QEMU -d).
    export ASSEMBLY_LOGS="${ASSEMBLY_LOGS:-0}" ASSEMBLY_LOGS_FLAGS ASSEMBLY_LOGS_FILTRE
    : "${IQ:=none}";        export IQ
    # INSNS is only a ceiling (the DSP stops at its IDLE, c54x_exe/src/pont.c
    # jouer_trame). TCH decoding needs up to ~87000 insn/frame with osmocom
    # layer1; below that the decoding spills over the next frame and corrupts
    # the speech Viterbi state. The real C54x has ~480000 cycles per frame.
    # Magnetite (--ms-magnetite): the TI firmware needs far more than osmocom
    # in TCH: at 120000 the DSP task queue overflows (d_error_status 20h/28h),
    # L1 sees its results late, restarts the DSP and the call to 600 drops
    # (Assignment Failure). 480000 leaves no unfinished tick.
    if [ -n "${MS_MAGNETITE:-}" ]; then : "${INSNS:=480000}"; fi
    : "${INSNS:=120000}";   export INSNS
    : "${LOCKSTEP:=1}";     export LOCKSTEP
    : "${CALYPSO_BSP_STREAM:=1}";    export CALYPSO_BSP_STREAM
    : "${CALYPSO_RHEA_DMA_XFER:=1}"; export CALYPSO_RHEA_DMA_XFER
    # TCH-VOICE in l1phy (ROM vocoder), not in gapk. The ROM profile of
    # /etc/default/osmo-banc (scripts/dsp-rom-max.sh: BANC_VOCODEUR=rom,
    # CALYPSO_VSP=1 and the vocoder emulator flags) is loaded here so that a
    # manual launch gets the same profile as osmo-banc.service; the
    # environment always wins. l1phy is the default: run.sh derives
    # mobile_pont_rom.cfg from it (config_vocodeur_rom).
    # BANC_VOCODEUR=hote switches back to gapk.
    if [ -r /etc/default/osmo-banc ]; then
        while IFS='=' read -r _k _v; do
            case "$_k" in ''|\#*|*[!A-Za-z0-9_]*) continue ;; esac
            [ -n "${!_k+x}" ] || export "$_k=$_v"
        done < /etc/default/osmo-banc
        unset _k _v
    fi
    : "${BANC_VOCODEUR:=rom}"; export BANC_VOCODEUR
    # --gapk with --ms-magnetite: no L23 mobile for GAPK, the voice is coded by
    # the bridge (pont/voix_hote.py, libgsm); the DSP only does the channel
    # (CALYPSO_VSP=0).
    if [ "$BANC_VOCODEUR" = hote ] && [ -n "${MS_MAGNETITE:-}" ]; then
        : "${PONT_VOIX_HOTE:=1}"; export PONT_VOIX_HOTE
    fi
    : "${CALYPSO_VSP:=1}";     export CALYPSO_VSP
    # The rest of the --vocodeur-rom profile, even without
    # /etc/default/osmo-banc: the FR codec emulator flags and PONT_UL_RAW_TCH.
    # Without them the ROM receives the microphone but codes the silence
    # frame, and the 600 echo test stays mute. Same values as
    # scripts/dsp-rom-max.sh profile --vocodeur-rom (the default).
    if [ "$BANC_VOCODEUR" = rom ]; then
        for _kv in CALYPSO_NORM_TC=0 CALYPSO_C54X_BCTC_NORM=1 PONT_UL_RAW_TCH=1 \
                   CALYPSO_C54X_BCD_CARRY=1 CALYPSO_C54X_OVM_LOGIQUE=1 CALYPSO_MAC=1 \
                   CALYPSO_C54X_BCD_TC=1 CALYPSO_C54X_BCTC_COMBO=1; do
            _k="${_kv%%=*}"; [ -n "${!_k+x}" ] || export "$_kv"
        done
        unset _kv _k
    fi
    RUN_ARGS+=(--skip "$DSP_MODULES_RETIRES" --no-attach)
    if [ $DRY -eq 1 ]; then
        say_begin "Transmission a run.sh puis au banc DSP"
        say_end " -- " "$C_DIM" "Transmission a run.sh puis au banc DSP" "dry-run"
        printf '  1. CALYPSO_PROFILE=%s bash %s %s\n' "$CALYPSO_PROFILE" "$RUN_SH" "${RUN_ARGS[*]}"
        printf '  2. MODE=dsp PONT=%s IQ=%s INSNS=%s LOCKSTEP=%s BANC_VOCODEUR=%s%s%s bash %s\n' \
            "$PONT" "$IQ" "$INSNS" "$LOCKSTEP" "$BANC_VOCODEUR" \
            "${QEMU_ICOUNT:+ QEMU_ICOUNT=$QEMU_ICOUNT}" \
            "$([ "${ASSEMBLY_LOGS:-0}" = 1 ] && echo " ASSEMBLY_LOGS=1")" "$BANC_DSP"
        [ "${OSMO_TRX:-0}" = 1 ] && printf '     OSMO_TRX=1 : trx.highram.elf + transceiver --no-sync (pas de mobile, pas de pont) ; %s\n' "$(trx_ts_desc)"
        [ "${OSMO_TRX_TS1:-0}" = 1 ] && printf '     OSMO_TRX_TS1=1 : INSTANCE=3 OSMO_TRX_PHONE=2 bash %s   (le 2e Calypso TRX, TS1, avant le transceiver)\n' "$BANC_DSP"
        # Classic BTS (--bts-classic or default): the mobile is on the bridge,
        # Magnetite through FIRMWARE_FLASH.
        [ "${OSMO_TRX:-0}" != 1 ] && printf '     BTS classique : osmo-bts-trx <-> pont_dsp.py ; mobile %s\n' \
            "$([ -n "${MS_MAGNETITE:-}" ] && echo "Magnetite (FIRMWARE_FLASH=$MAGNETITE_FLASH)" || echo "osmocom-bb (mobile + layer1)")"
        [ "${OSMO_TRX:-0}" = 1 ] && [ "${MS_AIR:-0}" = 1 ] && printf '  3. INSTANCE=2 AIR=1 MODE=dsp %sbash %s   (le mobile par l air, quand le firmware trx est en mode BTS)\n' "${MS_MAGNETITE:+FIRMWARE_FLASH=$MAGNETITE_FLASH }" "$BANC_DSP"
        exit 0
    fi
    # The instance 1 mobile reads mobile_pont.cfg as is (run.sh only rewrites
    # the stick for instances 2+): align its stick ARFCN with the plan's cell,
    # otherwise FBSB fails in a loop in the multi-operator containers.
    _cfg_pont="$(dirname "$BANC_DSP")/mobile_pont.cfg"
    _arfcn_pont="${PLAN_ARFCN:-${MS_ARFCN1:-${ARFCN:-1}}}"
    if [ -w "$_cfg_pont" ] && [[ "$_arfcn_pont" =~ ^[0-9]+$ ]]; then
        sed -i "s|^\([[:space:]]*\)stick [0-9]*\$|\1stick ${_arfcn_pont}|" "$_cfg_pont"
    fi
    # Same template, same gap for the SIM: imsi/ki/rplmn are taken from
    # mobile.cfg, the card that start-docker generates per operator, so the HLR
    # of the operator's container knows the IMSI with its auth data.
    _sim_src="/root/.osmocom/bb/mobile.cfg"
    if [ -w "$_cfg_pont" ] && [ -r "$_sim_src" ]; then
        for _k in imsi "ki comp128" rplmn; do
            _l="$(grep -m1 -E "^[[:space:]]+${_k} " "$_sim_src")" || continue
            _l="${_l//|/\\|}"
            sed -i "s|^[[:space:]]\+${_k} .*\$|${_l}|" "$_cfg_pont"
        done
    fi
    unset _cfg_pont _arfcn_pont _sim_src _k _l
    audio_start
    say_begin "Transmission a run.sh (sans $DSP_MODULES_RETIRES)"
    if ! env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" "${RUN_ARGS[@]}"; then
        say_end " KO " "$C_KO" "Transmission a run.sh" "le plan du fork a echoue, banc DSP non lance"
        exit 1
    fi
    say_end " OK " "$C_OK" "Transmission a run.sh" "profil=$CALYPSO_PROFILE, chaine Calypso laissee au banc DSP"
    say_begin "Banc DSP C54x"
    say_end " OK " "$C_OK" "Banc DSP C54x" "$BANC_DSP  (INSNS=$INSNS LOCKSTEP=$LOCKSTEP IQ=$IQ$([ "${OSMO_TRX:-0}" = 1 ] && echo " OSMO_TRX=1 : trx.highram.elf + transceiver, $(trx_ts_desc)"))"
    # Full hand-off: this process becomes c54x_exe/run.sh (five steps, then it
    # returns; the logs stay in /tmp/c54x-pont). MODE=dsp is exported just
    # above and overrides the profile's.
    # --sap: the "sim sap" copy of mobile_pont.cfg, for the bench only.
    # --bts --ms: instance 1 (the BTS radio) first, then, once the trx
    # firmware has switched to BTS mode (osmo-bts-trx sent POWERON:
    # "BTS MODE: 7 514" in osmocon.log), instance 2 (the mobile + the air),
    # which takes over.
    if [ "${OSMO_TRX:-0}" = 1 ] && [ "${MS_AIR:-0}" = 1 ]; then
        bash "$BANC_DSP" || exit 1
        say_begin "Mobile par l'air (instance 2)"
        _ok=0
        for _i in $(seq 1 "${OSMO_TRX_BTS_ATTENTE:-150}"); do
            grep -aq 'BTS MODE: [0-9]* [1-9]' /tmp/c54x-pont/osmocon.log 2>/dev/null && { _ok=1; break; }
            sleep 1
        done
        if [ "$_ok" = 1 ]; then
            say_end " OK " "$C_OK" "Mobile par l'air (instance 2)" "firmware trx en mode BTS apres ${_i}s ; INSTANCE=2 AIR=1 $BANC_DSP"
        else
            say_end " !! " "$C_KO" "Mobile par l'air (instance 2)" "le firmware trx n'est pas en mode BTS (osmo-bts-trx absente ?) ; on lance quand meme"
        fi
        sleep 10
        # Explicit OSMO_TRX=0: OSMO_TRX=1 is exported (the TRX is instance 1)
        # and instance 2 must not inherit it (it would start a second
        # transceiver on the same UDP port). The over-the-air mobile runs the
        # stock layer1 (the profile's FIRMWARE_ELF is dropped; an explicit
        # FIRMWARE_SRC keeps precedence).
        # --ms-magnetite: FIRMWARE_FLASH (exported at parsing) replaces layer1
        # for instance 2.
        exec env -u FIRMWARE_ELF -u FIRMWARE_BIN ${FIRMWARE_SRC:+FIRMWARE_ELF="$FIRMWARE_ELF"} \
            ${MS_MAGNETITE:+FIRMWARE_FLASH="$MAGNETITE_FLASH"} \
            INSTANCE=2 AIR=1 OSMO_TRX=0 ${SAP_DSP_MOBILE_CFG:+MOBILE_CFG="$SAP_DSP_MOBILE_CFG"} bash "$BANC_DSP"
    fi
    exec env ${MS_MAGNETITE:+FIRMWARE_FLASH="$MAGNETITE_FLASH"} ${SAP_DSP_MOBILE_CFG:+MOBILE_CFG="$SAP_DSP_MOBILE_CFG"} bash "$BANC_DSP"
fi


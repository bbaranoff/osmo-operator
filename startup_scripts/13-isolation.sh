# 13-isolation.sh - part of start.sh (cpu isolation and priorities of the bench)
# Sourced by start.sh in the main shell: same order, same variables.
#
# ISOLATION (default; --no-isolation or ISOLATION=0 to skip): c54x_exe/isoler.sh on
#   - the chain (c54x_exe, qosmo, osmocon, mobile) on its reserved cores, SCHED_FIFO; qosmo has its own core
#   - the bridge (pont_dsp.py / air.py) alone on its own core
#   - the core network (osmo-stp/hlr/mgw/msc/bsc/ggsn/sgsn, sip-connector, asterisk, BTS, PCU) on its cpus
#   - the desktop and every other service on what is left
#   - the kernel's housekeeping (unbound workqueues, movable kernel threads) on the desktop's cpus
#   - the guard c54x-garde keeps SCHED_FIFO without freezing the machine: a real-time thread that never
#     sleeps (> 90 % of its cpu for 5 s) goes back to SCHED_OTHER nice -10, a kernel stall or Tctl > 95 °C
#     puts all of them back (journalctl -t c54x-garde; GARDE=0 for none)
# It is done BEFORE the core starts (its units take their slice at start) and completed after the fork's
# plan (banc_apres_lancement, called by 14-demarrage.sh) for what is launched outside systemd: the BTS, a
# qosmo started by the fork. It stays in place after --stop: c54x_exe/isoler.sh off gives the cpus back
# (nothing survives a reboot). The layout follows the number of cores of the machine; the desktop keeps
# BUREAU logical cpus (4 when the bench still has four cores then, 2 otherwise). BUREAU / CPUS / CPUS_RESEAU /
# FIFO: see isoler.sh.
#
# NICE (always, isolation or not; an empty value = leave alone):
#   NICE_RESEAU=-5   the core network: a runtime drop-in Nice= on its units, renice for the daemons
#                    launched outside systemd (the BTS keeps its SCHED_RR 1 on top of it)
#   RT_NICE=-10      the chain, by c54x_exe/run.sh when it is not SCHED_FIFO (no isolation)
#   NICE_AUTRES=10   the desktop tools of the bench (panel, fft, conky...): RT_RENICE_AUTRES of run.sh
: "${ISOLATION:=1}"
: "${ISOLER_SH:=$(dirname "${BANC_DSP:-$GSM_ROOT/c54x_exe/run.sh}")/isoler.sh}"
NICE_RESEAU="${NICE_RESEAU--5}"
NICE_AUTRES="${NICE_AUTRES-10}"
BANC_UNITES_RESEAU="${RESEAU_UNITES:-osmo-stp osmo-hlr osmo-mgw osmo-msc osmo-bsc osmo-ggsn osmo-sgsn osmo-pcu osmo-bts-trx osmo-sip-connector asterisk}"
BANC_PROCS_RESEAU="${BANC_PROCS_RESEAU:-$BANC_UNITES_RESEAU osmo-trx-uhd osmo-trx-lms trxcon}"
banc_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }

# Nice= of the core units, as a runtime drop-in (/run: gone at reboot), read at their next start
banc_nice_unites() {
    local u d
    for u in $BANC_UNITES_RESEAU; do
        d="/run/systemd/system/$u.service.d"
        if [ -n "$NICE_RESEAU" ] && [ "$(systemctl show -p LoadState --value "$u.service" 2>/dev/null)" = loaded ]; then
            banc_root mkdir -p "$d" && printf '# start.sh (13-isolation.sh)\n[Service]\nNice=%s\n' "$NICE_RESEAU" | banc_root tee "$d/50-banc-nice.conf" >/dev/null
        else
            banc_root rm -f "$d/50-banc-nice.conf" 2>/dev/null
        fi
    done
    banc_root systemctl daemon-reload
}
# After the fork's plan: what runs outside systemd gets its cpus (isoler.sh adopter) and its nice
banc_apres_lancement() {
    local u pids
    if [ "$ISOLATION" = 1 ] && [ -r /run/c54x-isol.env ]; then
        banc_root env RESEAU_UNITES="$BANC_PROCS_RESEAU" bash "$ISOLER_SH" adopter 2>&1 | sed 's/^/  /'
    fi
    [ -n "$NICE_RESEAU" ] || return 0
    pids="$(for u in $BANC_PROCS_RESEAU; do pgrep -x -- "${u:0:15}"; done | tr '\n' ' ')"
    # shellcheck disable=SC2086
    [ -z "${pids// /}" ] || banc_root renice -n "$NICE_RESEAU" -p $pids >/dev/null 2>&1 || true
}

if [ "$ACTION" = start ] && [ "$DRY" -eq 0 ]; then
    say_begin "Isolation des cpus et priorites"
    banc_nice_unites
    [ -n "$NICE_AUTRES" ] && export RT_RENICE_AUTRES="${RT_RENICE_AUTRES:-$NICE_AUTRES}"
    _nice="nice : coeur de reseau ${NICE_RESEAU:--}, chaine ${RT_NICE--10} (hors FIFO), outils du bureau ${RT_RENICE_AUTRES:--}"
    if [ "$ISOLATION" != 1 ]; then
        say_end " -- " "$C_DIM" "Isolation des cpus" "desactivee (--no-isolation) ; $_nice"
    elif [ ! -x "$ISOLER_SH" ]; then
        say_end "WARN" "$C_SK" "Isolation des cpus" "$ISOLER_SH absent ; $_nice"
    elif _isol="$(banc_root env RESEAU_UNITES="$BANC_UNITES_RESEAU" bash "$ISOLER_SH" on 2>&1)"; then
        # shellcheck disable=SC1091
        say_end " OK " "$C_OK" "Isolation des cpus" "$( . /run/c54x-isol.env; [ -n "$ISOL_CPUS_DSP" ] && echo -n "dsp $ISOL_CPUS_DSP, qosmo $ISOL_CPUS_QEMU, reste de la chaine $ISOL_CPUS_RESTE" || echo -n "chaine $ISOL_CPUS"; echo ", pont ${ISOL_CPUS_PONT:--}, coeur de reseau ${ISOL_CPUS_CN:--}, bureau $ISOL_AUTRES") ; $_nice"
        printf '       %s-> %s status | off%s\n' "$C_DIM" "$ISOLER_SH" "$C_Z"
    else
        say_end "WARN" "$C_SK" "Isolation des cpus" "isoler.sh on a echoue, le banc demarre sans ; $_nice"
        printf '%s\n' "$_isol" | sed 's/^/       /' >&2
    fi
    unset _isol _nice
fi

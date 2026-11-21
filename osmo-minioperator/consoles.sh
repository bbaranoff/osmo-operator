#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# consoles.sh - "Three consoles, one phone call": one tmux session, three panes.
# ─────────────────────────────────────────────────────────────────────────────
#   window "consoles"     1. Harvard shell of the C54x DSP (c54x_exe/harvard.sh repl: d@ d_task_d ...)
#                         2. gdb-multiarch on the ARM layer1 (QEMU gdbstub 127.0.0.1:1234)
#                         3. OsmocomBB mobile VTY (telnet 127.0.0.1 4247, "enable" sent)
#   window "stack"        ./run-dsp.sh (the whole stack), then a shell
#
# Each pane waits for its service before connecting, and reconnects when you
# leave it (q / quit / Ctrl-]). The wait NEVER connects to the port: a mere
# connection to the QEMU gdbstub stops the ARM (gdbstub/system.c: vm_stop on
# open). So it looks at listening sockets (ss), not at "who answers".
#
#   ./consoles.sh              creates the session (if needed) and attaches to it
#   ./consoles.sh --pane X     content of one pane (dsp | gdb | vty), internal use
# Variables: CONSOLES_SESSION (demo), TTYD=1 (browser access: ttyd in front of the session,
#             port TTYD_PORT=7681, a single client), off by default.
# ─────────────────────────────────────────────────────────────────────────────
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${CONSOLES_SESSION:-demo}"
GSM_ROOT="${GSM_ROOT:-/opt/GSM}"

# Values taken from the launchers, not chosen here:
#   c54x_exe/run.sh : DSP_SOCK, DSP_SHM, RUNDIR=/tmp/c54x-pont, GDB_STUB=1234,
#                     FIRMWARE_ELF=$_FW/layer1.highram.elf (_FW=/opt/GSM/firmware/board/compal_e88)
#   configs/mobile.cfg: "bind 127.0.0.1 4247" (mobile VTY)
C54X="${C54X:-$GSM_ROOT/c54x_exe}"
QOSMO="${QOSMO:-$GSM_ROOT/qosmo}"
DSP_SOCK=/tmp/calypso_dsp.sock
DSP_SHM=/dev/shm/calypso_api_ram
MOBILE_LOG=/tmp/c54x-pont/mobile.log
GDB_STUB=1234
VTY_PORT=4247
FIRMWARE_ELF="${FIRMWARE_ELF:-$GSM_ROOT/firmware/board/compal_e88/layer1.highram.elf}"
# The ELF was built in /opt/GSM/osmocom-bb/src/target/firmware (DW_AT_comp_dir),
# its sources are those of the firmware repo (/opt/GSM/firmware, same commit as the ELF).
FW_DWARF_DIR=/opt/GSM/osmocom-bb/src/target/firmware
FW_SRC="${FW_SRC:-$GSM_ROOT/firmware}"

gras() { printf '\033[1m%s\033[0m\n' "$*"; }

# ecoute <port>: a TCP socket listening on this port (without connecting to it)
ecoute() { ss -ltnH 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"; }

# attendre <description> <command...>: busy wait, one dot per second
attendre() {
    local quoi="$1"; shift
    "$@" && return 0
    printf 'waiting for %s ' "$quoi"
    until "$@"; do printf '.'; sleep 1; done
    echo " ok"
}

# gdb and the VTY also wait for the mobile to attach (max 300 s, as in
# verif.sh): stopping the ARM during the cell search would delay it, and
# "call" before the LU fails.
attendre_lu() {
    local n=0
    grep -q 'LOCATION UPDATING ACCEPT' "$MOBILE_LOG" 2>/dev/null && return 0
    printf 'waiting for LOCATION UPDATING ACCEPT in %s ' "$MOBILE_LOG"
    until grep -q 'LOCATION UPDATING ACCEPT' "$MOBILE_LOG" 2>/dev/null; do
        n=$((n + 1)); [ "$n" -ge 300 ] && { echo " (no LU after 300 s, going on)"; return 0; }
        printf '.'; sleep 1
    done
    echo " ok"
}

relancer() { echo; gras "[$1] ended. Press Enter to reconnect."; read -r _ || sleep 2; }

panneau_dsp() {
    while :; do
        clear; gras "1. C54x DSP: Harvard shell (API RAM $DSP_SHM)"
        attendre "DSP c54x_exe --arm ($DSP_SOCK, $DSP_SHM)" \
            sh -c "[ -S '$DSP_SOCK' ] && [ -e '$DSP_SHM' ]"
        echo "try:  d@ d_task_d    d@ W0    d@ R0    d@ noms d_task    aide"
        "$C54X/harvard.sh" repl
        relancer dsp
    done
}

panneau_gdb() {
    while :; do
        clear; gras "2. ARM: gdb on layer1 ($FIRMWARE_ELF)"
        attendre "QEMU gdbstub listening on 127.0.0.1:$GDB_STUB" ecoute "$GDB_STUB"
        attendre_lu
        echo "the target is running (continue &):  stop -> bt -> go     list l1a_l23_handler     help_osmo"
        # Same options as qosmo/tools/gdb-telnet.py (telnet console 44444), run directly
        # in the pane so substitute-path can be added. Only one gdb client at a time
        # on the stub: while this gdb is attached, "telnet 0 44444" and the
        # harvard.sh gdb command cannot attach to it.
        local panneau=()   # qosmo's osmocom panel (help_osmo, stop, go, fn, ndb...)
        [ -f "$QOSMO/tools/cmd.gdb" ] && panneau=(-x "$QOSMO/tools/cmd.gdb")
        OSMO_GDB_TOOLS="$QOSMO/tools" gdb-multiarch -q -nx \
            -iex 'set pagination off' -iex 'set confirm off' \
            -iex 'set height 0' -iex 'set width 0' \
            -iex "set substitute-path $FW_DWARF_DIR $FW_SRC" \
            -ex 'set architecture armv5te' \
            -ex "target remote 127.0.0.1:$GDB_STUB" \
            -ex 'continue &' \
            "${panneau[@]}" \
            "$FIRMWARE_ELF"
        relancer gdb
    done
}

panneau_vty() {
    while :; do
        clear; gras "3. OsmocomBB mobile: VTY telnet 127.0.0.1:$VTY_PORT"
        attendre "mobile VTY listening on 127.0.0.1:$VTY_PORT" ecoute "$VTY_PORT"
        attendre_lu
        echo "call:  call 1 600   (then: hangup 1)"
        # "call" is in the enable node: type it for the user once telnet has
        # started (the keystrokes wait in the tty if telnet has not read yet).
        ( sleep 1; tmux send-keys -t "$TMUX_PANE" 'enable' Enter ) &
        telnet 127.0.0.1 "$VTY_PORT"
        relancer vty
    done
}

case "${1:-}" in
    --pane)
        # UTF-8 locale for the panes only (not for run-dsp.sh): without it the
        # Python of cmd.gdb (demo-layer1.py) fails on its em dashes (ascii codec).
        export LANG=C.UTF-8 LC_ALL=C.UTF-8
        case "${2:-}" in
            dsp) panneau_dsp ;; gdb) panneau_gdb ;; vty) panneau_vty ;;
            *) echo "usage: $0 --pane dsp|gdb|vty" >&2; exit 2 ;;
        esac; exit ;;
    -h|--help) sed -n '4,20p' "$0"; exit 0 ;;
esac

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    # "stack" window first: the stack starts while the panes wait.
    tmux -u new-session -d -s "$SESSION" -n stack -x 200 -y 50 -c "$HERE" \
        "bash -c '\"$HERE/run-dsp.sh\"; exec bash'"
    tmux set-option -t "$SESSION" -g mouse on >/dev/null
    tmux set-option -t "$SESSION" -g remain-on-exit off >/dev/null
    tmux new-window -t "$SESSION" -n consoles -c "$HERE" "\"$HERE/consoles.sh\" --pane dsp"
    tmux split-window -t "$SESSION:consoles" -h -c "$HERE" "\"$HERE/consoles.sh\" --pane gdb"
    tmux split-window -t "$SESSION:consoles.1" -v -c "$HERE" "\"$HERE/consoles.sh\" --pane vty"
    tmux select-pane -t "$SESSION:consoles.2"
    tmux select-window -t "$SESSION:consoles"
fi

# Browser access (optional): ttyd serves the same tmux session. -W: writable
# (ttyd >= 1.7 is read-only otherwise); -m 1: a single client, one instance per
# user. No authentication: docker-run.sh publishes the port on 127.0.0.1 only.
if [ "${TTYD:-0}" = 1 ]; then
    if command -v ttyd >/dev/null; then
        ttyd -W -m 1 -p "${TTYD_PORT:-7681}" tmux -u attach -t "$SESSION" >/tmp/ttyd.log 2>&1 &
        gras "ttyd: http://127.0.0.1:${TTYD_PORT:-7681}/ (log /tmp/ttyd.log)"
    else
        gras "TTYD=1 but ttyd is missing from the image"
    fi
fi

if [ -t 0 ] && [ -t 1 ]; then
    tmux -u attach -t "$SESSION"
    # Detached (C-b d): a shell, the stack keeps running.
    gras "tmux session \"$SESSION\" detached (the stack is running): tmux attach -t $SESSION to come back"
    exec bash
fi
# No terminal (docker run -d): keep the container alive while the session exists.
while tmux has-session -t "$SESSION" 2>/dev/null; do sleep 5; done

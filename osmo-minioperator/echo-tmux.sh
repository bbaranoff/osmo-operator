#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# echo-tmux.sh - "hello 40c3" echo test in a tmux session (not the container's default command).
#   left          echotest.py: call to 600, ">>> say: hello 40c3" on entering Echo(),
#                 SPEAK (mic) and ECHO (return) indicators, records the GSM tracks in /root/echo
#                 (echo.cast, dl.wav downlink, ul.wav uplink, echo.wav both; never the raw mic)
#   top right     mobile.log: LU, service, call states (CC), cell loss
#   bottom right  pont.log: clock to the BTS (IND CLOCK) and transmitter on/off
# Prerequisites: the stack running (./run-dsp.sh) and host audio (./docker-run.sh).
#   ./echo-tmux.sh                 ./echo-tmux.sh --duree 25      (arguments passed to echotest.py)
# Ctrl-C in the left pane stops the test; "C-b d" detaches, "tmux kill-session -t echo" closes.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S=echo
ARGS=$(printf ' %q' "$@")
tmux kill-session -t "$S" 2>/dev/null
tmux new-session -d -s "$S" -x "$(tput cols 2>/dev/null || echo 200)" -y "$(tput lines 2>/dev/null || echo 50)" \
  "python3 $HERE/echotest.py$ARGS; echo; read -rp 'Press Enter to close the session ' _; tmux kill-session -t $S"
tmux split-window -h -t "$S" "tail -n 0 -F /tmp/c54x-pont/mobile.log 2>/dev/null | grep -a --line-buffered -E 'LOCATION UPDATING|CM SERVICE|gsm48_cc.c:[0-9]+ new state|no cell available|LOS during' | sed -u 's/\x1b\[[0-9;]*m//g' | cut -c12-130"
tmux split-window -v -t "$S" "tail -n 0 -F /tmp/c54x-pont/pont.log 2>/dev/null | grep -a --line-buffered -E 'IND CLOCK|CTRL POWER'"
tmux set -t "$S" pane-border-status top >/dev/null
tmux select-pane -t "$S:0.0" -T 'echotest.py (hello 40c3)'
tmux select-pane -t "$S:0.1" -T 'mobile.log: call'
tmux select-pane -t "$S:0.2" -T 'pont.log: clock to the BTS'
tmux set-window-option -t "$S" main-pane-width "$(( $(tput cols 2>/dev/null || echo 200) * 55 / 100 ))" >/dev/null
tmux select-layout -t "$S" main-vertical >/dev/null
tmux select-pane -t "$S:0.0"
exec tmux attach -t "$S"

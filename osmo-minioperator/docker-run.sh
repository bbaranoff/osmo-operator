#!/usr/bin/env bash
# Copyright (C) 2026 Bastien Baranoff
# SPDX-License-Identifier: GPL-3.0-or-later
# docker-run.sh - starts the container with host audio: the PulseAudio socket
# is mounted at /run/pulse/native (without it the call is mute). Arguments are
# passed as is to the container (default: bash). PULSE_SOCK=<path> forces the socket.
set -eu
IMG="${IMG:-osmo-minioperator}"
# No --privileged: NET_ADMIN + /dev/net/tun for osmo-ggsn (TUN),
# SYS_NICE for the DSP's real-time priority (run.sh, RT_NICE),
# SYS_PTRACE for harvard.sh (stop/go/dsp read the DSP registers in /proc/<pid>/mem).
# --init: a real PID 1 reaps the stack's finished processes.
args=(--rm -it --init --cap-add NET_ADMIN --cap-add SYS_NICE --cap-add SYS_PTRACE --device /dev/net/tun)

# Order: PULSE_SOCK (forced), system PulseAudio, then session socket
# (PipeWire / pipewire-pulse on laptops: /run/user/<uid>/pulse/native).
uid="${SUDO_UID:-$(id -u)}"
for s in ${PULSE_SOCK:-} /run/pulse/native /var/run/pulse/native "/run/user/$uid/pulse/native"; do
    if [ -S "$s" ]; then
        args+=(-v "$(readlink -f "$s"):/run/pulse/native")
        echo "docker-run.sh: host audio via $s" >&2
        break
    fi
done
case " ${args[*]} " in
    *pulse/native*) ;;
    *) echo "docker-run.sh: no PulseAudio socket on the host, the call will be mute" >&2 ;;
esac

# Session PulseAudio (not system-wide): the user's cookie is needed too.
home="$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)"
[ -r "$home/.config/pulse/cookie" ] && args+=(-v "$home/.config/pulse/cookie:/root/.config/pulse/cookie:ro")
[ -d /dev/snd ] && args+=(--device /dev/snd)

# TTYD=1: the consoles in the browser too (ttyd, no authentication: port
# published on 127.0.0.1 only). TTYD_PORT (7681) changes the port, on both sides.
if [ "${TTYD:-0}" = 1 ]; then
    p="${TTYD_PORT:-7681}"
    args+=(-e TTYD=1 -e "TTYD_PORT=$p" -p "127.0.0.1:$p:$p")
    echo "docker-run.sh: consoles also on http://127.0.0.1:$p/" >&2
fi

exec docker run "${args[@]}" "$IMG" "$@"

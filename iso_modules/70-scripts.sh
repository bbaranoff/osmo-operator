#!/bin/bash
# iso_modules/70-scripts.sh - steps 7/7b: project scripts, WAN, NetworkManager
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).

# ── Step 7: project scripts and the start-native.sh launcher ────────────────
echo -e "${GREEN}[7/9] Scripts projet et adaptation ISO...${NC}"
# ── A single repository tree: /opt/GSM/osmo-operator ───────────────────────
# All launchers, links, aliases and units point to this tree (full clone with
# .git, updated at step [5a/9] and by osmo-update). If the clone could not be
# fetched, it is filled from the build repository instead, at the same path.
P="$ROOTFS/opt/GSM/osmo-operator"
if [ ! -x "$P/start-native.sh" ]; then
    echo -e "  ${YELLOW}!${NC} /opt/GSM/osmo-operator sans lanceur (image perimee, clone impossible)"
    echo -e "    -> remplissage depuis le depot de construction ${CYAN}${DIR}${NC}"
    mkdir -p "$P"
    # --exclude .git: do not fake a repository; osmo-update will rebuild it.
    tar -C "$DIR" --exclude=.git --exclude='*.iso' -cf - . | tar -C "$P" -xf -
    find "$P" -name "*.sh" -exec chmod +x {} \;
fi
if [ ! -x "$P/start-native.sh" ]; then
    echo -e "  ${RED}✗${NC} start-native.sh introuvable - l'ISO n'aura pas de lanceur" >&2
    exit 1
fi
ln -sf /opt/GSM/osmo-operator/start-native.sh "$ROOTFS/usr/local/bin/osmo-start-native" 2>/dev/null || true
ln -sf /opt/GSM/osmo-operator/start-native.sh "$ROOTFS/usr/local/bin/osmo-start-direct" 2>/dev/null || true  # legacy name
# Default wallpaper (80-chroot.sh reads it from THIS tree): installed from the
# build repository so that an unpushed tree still ships it.
[ -f "$DIR/configs/gsm-lab-wallpaper.jpg" ] \
    && install -Dm644 "$DIR/configs/gsm-lab-wallpaper.jpg" "$P/configs/gsm-lab-wallpaper.jpg"
# Plain background (same scene as the overlay, see tools/paysage-render.py).
[ -f "$DIR/configs/gsm-lab-fond.jpg" ] \
    && install -Dm644 "$DIR/configs/gsm-lab-fond.jpg" "$P/configs/gsm-lab-fond.jpg"
# Two-state background (tools/osmo-fond.py): the city alone when idle
# (gsm-lab-ville.jpg, schema default), the city with the antenna while a bench
# is running (gsm-lab-antenne.jpg), cross-faded.
for _bg in gsm-lab-ville.jpg gsm-lab-antenne.jpg; do
    [ -f "$DIR/configs/$_bg" ] && install -Dm644 "$DIR/configs/$_bg" "$P/configs/$_bg"
done
unset _bg
ln -sf /opt/GSM/osmo-operator/tools/osmo-fond.py "$ROOTFS/usr/local/bin/osmo-fond" 2>/dev/null || true
# osmo-op: selects which operator the overlay and Conky show (arrows, from
# the command line). Also bound by iso_modules/80-chroot.sh to
# Ctrl+AltGr+Right / Ctrl+AltGr+Left.
ln -sf /opt/GSM/osmo-operator/tools/osmo-op.sh "$ROOTFS/usr/local/bin/osmo-op" 2>/dev/null || true
ln -sf /opt/GSM/osmo-operator/tools/osmo-drivers.sh "$ROOTFS/usr/local/bin/osmo-drivers" 2>/dev/null || true
ln -sf /opt/GSM/osmo-operator/tools/overlay-draw.py "$ROOTFS/usr/local/bin/overlay-draw" 2>/dev/null || true
# Emulated C123 window (qosmo screen + keypad) in PATH: the c123 alias of
# /etc/profile.d/98-osmo-banc-aliases.sh only exists in login shells; the link
# works everywhere else (Alt+F2, sudo, scripts).
ln -sf /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py "$ROOTFS/usr/local/bin/c123" 2>/dev/null || true
ln -sf /opt/GSM/osmo-operator/tools/osmo-c123-gtk.py "$ROOTFS/usr/local/bin/osmo-c123" 2>/dev/null || true
# Bench aliases (banc-rssi, banc-trx, banc-mobile, c123-1...): the profile.d
# file for login shells, and the same names as real commands (tools/osmo-banc-cmd.sh).
install -Dm644 "$P/scripts/osmo-banc-aliases.sh" "$ROOTFS/etc/profile.d/98-osmo-banc-aliases.sh"
bash "$P/tools/osmo-banc-cmd.sh" --install "$ROOTFS/usr/local/bin" >/dev/null
# Adds /root/gnuarm/install/bin to PATH when present (--gnuarm add-on);
# inert while the toolchain is absent.
install -Dm644 "$P/scripts/osmo-gnuarm-profile.sh" "$ROOTFS/etc/profile.d/97-osmo-gnuarm.sh"
# Apply the repo patches (patches/, via tools/osmo-patches-apply.sh) to the
# rootfs trees, outside the chroot (GPRS layer1, osmocon...). With gnuarm,
# "cd /opt/GSM/osmocom-bb/src && make" then builds the whole tree.
OSMO_PATCHES_QUIET=1 GSM_ROOT="$ROOTFS/opt/GSM" REPO="$P" bash "$P/tools/osmo-patches-apply.sh" "$ROOTFS/opt/GSM" || true
# WAN WireGuard (wiki/WAN.md): "wg 1" (hub 10.99.0.1), "wg N ..." (10.99.0.N),
# a profile.d function that passes through to the real wg; osmo-wg for sudo and
# scripts. Keys are generated on the machine at the first "wg N", NEVER in the
# image (they would be shared).
install -Dm644 "$P/scripts/osmo-wg-profile.sh" "$ROOTFS/etc/profile.d/97-osmo-wg.sh"
ln -sf /opt/GSM/osmo-operator/tools/osmo-wg.sh "$ROOTFS/usr/local/bin/osmo-wg" 2>/dev/null || true
if [ -f "$DIR/launch/osmo-launch.sh" ]; then
    cp "$DIR/launch/osmo-launch.sh" "$ROOTFS/opt/osmo-launch.sh" && chmod +x "$ROOTFS/opt/osmo-launch.sh"
    ln -sf /opt/osmo-launch.sh "$ROOTFS/usr/local/bin/osmo-launch"
fi
echo -e "  ${GREEN}✓${NC} lanceurs -> ${CYAN}/opt/GSM/osmo-operator${NC} (arbre unique, avec .git)"

# /etc/osmocom/gapk-start.sh comes from the Docker image (COPY scripts/.) and
# lib/audio.sh prefers it over scripts/gapk-start.sh: always align it with the
# repo copy (idempotent), so a cached image cannot ship an outdated one.
if [ -f "$P/scripts/gapk-start.sh" ]; then
    install -d "$ROOTFS/etc/osmocom"
    install -m 755 "$P/scripts/gapk-start.sh" "$ROOTFS/etc/osmocom/gapk-start.sh"
    echo -e "  ${GREEN}✓${NC} /etc/osmocom/gapk-start.sh aligne sur scripts/ (superviseur gapk sans emetteur en doublon)"
fi

# ── Voice in the image: io-tch-format and the mobile audio buffer ───────────
# Same fix as update.sh, applied to the ROOTFS by scripts/voix-forks.sh (which
# documents the details). Both settings live in qosmo (run_modules, cfgs),
# copied as-is from the reference image by 50-injection-image.sh.
#
#   io-tch-format rtp: otherwise the mobile reads/writes TCH frames in the TI
#   Calypso layout, while pont.py encodes them with libosmocoding in RTP/RFC3551
#   layout. The template cfgs/mobile_group1.cfg is what matters:
#   run_modules/20-mobile-cfg.sh copies it over ~/.osmocom/bb/ at every start.
#
#   CALYPSO_PULSE_LATENCY_MSEC: the mobile writes one 20 ms GSM frame per
#   snd_pcm_writei; a too-short buffer makes every write return -EPIPE and
#   pq_alsa.c silently re-prepares the PulseAudio stream. Set to 320 ms.
if [ -x "$P/scripts/voix-forks.sh" ]; then
    # Do not put color codes in a sed replacement: GNU sed reads \0 in
    # '\033[0;32m' as "whole match". Lines are re-read and printed with echo -e.
    "$P/scripts/voix-forks.sh" "$ROOTFS" | while IFS= read -r _l; do
        case "$_l" in
            "  [voix]"*) echo -e "  ${GREEN}✓${NC}${_l#"  [voix]"}" ;;
            *)           echo "$_l" ;;
        esac
    done
fi

# ── WAN: node table fixed in the image ──────────────────────────────────────
if [ "$ISO_WAN" = "1" ]; then
    echo -e "${GREEN}[7b/9] WAN - table des noeuds embarquee...${NC}"
    # shellcheck source=network/wan-nodes.sh
    . "$DIR/network/wan-nodes.sh"
    WAN_OPS="$ISO_WAN_OPS"
    if [ -n "$ISO_WAN_NODES" ]; then
        wan_nodes_parse "$ISO_WAN_NODES" || exit 1
        WAN_NODE_ID="${ISO_WAN_ID:-0}"
    else
        # Interactive build: same questions as ./launch/start-docker.sh --wan.
        # The node number asked here is only a default: each machine booting the ISO
        # identifies itself by its IP.
        WAN_NODE_ID="${ISO_WAN_ID:-0}"
        wan_nodes_prompt || exit 1
    fi
    wan_nodes_validate || exit 1
    WAN_AUTO=1 WAN_CONF_FILE="$ROOTFS/etc/osmo-wan.conf" wan_nodes_save
    wan_nodes_summary
    echo -e "  ${GREEN}✓${NC} /etc/osmo-wan.conf fige dans l'ISO (WAN_AUTO=1)"
    echo -e "  ${CYAN}Au boot :${NC} start-native.sh applique le WAN tout seul ;"
    echo -e "  ${CYAN}sans --wan a la construction, l'ISO n'a AUCUN WAN.${NC}"
else
    echo -e "  ${CYAN}[7b/9] WAN non embarque (--wan absent) - ISO autonome${NC}"
fi

# ── Step 9 prep: files the chroot cannot write itself ───────────────────────
# The chroot script is passed to "bash -c" in SINGLE quotes: a single
# apostrophe in its body would end the string. Files containing quotes (quoted
# heredocs, nested shell commands) are therefore written HERE, into the rootfs;
# the chroot only enables them.

# NetworkManager drives the desktop, not the packet core: without this rule NM
# takes over apn0 or a GGSN tun and drops a subscriber's data session as
# "unconfigured".
mkdir -p "$ROOTFS/etc/NetworkManager/conf.d"
cat > "$ROOTFS/etc/NetworkManager/conf.d/10-osmo-networkd.conf" <<'NMCONF'
# Written by build-iso.sh. NetworkManager manages the physical NICs and the
# desktop; packet-core interfaces are left to systemd-networkd and the bench
# scripts.
[main]
plugins=keyfile

[keyfile]
unmanaged-devices=interface-name:apn*;interface-name:tun*;interface-name:veth*;interface-name:docker*;interface-name:br-*;interface-name:osmo*
NMCONF

# Firefox comes from Mozilla's .deb, installed in the chroot by 80-chroot.sh.

# End of module: `. file` returns the status of its LAST command and
# build-iso.sh runs under set -e. A module ending with a false test
# ("[ ... ] && { ...; }") would abort everything silently. Always 0 here.
true

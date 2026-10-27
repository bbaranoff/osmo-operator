#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# update.sh - per-session catch-up of an installed osmo-operator machine, then
# the "SMS delivered" session animation.
#
# Everything that belongs to the build (cloning repos, apt packages, services)
# is done by build-iso.sh. This script only replays, idempotently and offline,
# what an already installed machine would otherwise miss after a git pull:
#   - desktop icons (absolute Icon= paths, metadata::trusted, icon cache);
#   - osmo-multi.service: Wants= instead of Requires=osmo-banc.service;
#   - QEMU mobile template (c54x_exe/mobile_pont.cfg) aligned on PLAN_ARFCN;
#   - launchers and .desktop entries: overlay-draw, postmarketOS phone, deka,
#     4G/LTE and smartphone UI (tools/osmo-lte-install.sh,
#     tools/osmo-pmos-install.sh), Wireshark (root, bench filters),
#     /usr/local/bin launchers of tools/osmo-extras-install.sh,
#     osmo-start-native / osmo-start-direct, the "?" help page (osmo-info);
#   - systemd: services/osmo-banc.service, web consoles (osmo-egprs-web,
#     open5gs-webui) enabled unless masked, "no telecom service at boot"
#     policy applied once (tools/osmo-telecom-boot.sh), osmo-* units run as
#     the session user instead of the missing "osmocom" account;
#   - osmo-desktop-panel wrapper (desktop widgets, Conky);
#   - Firefox from the Mozilla deb repository when no browser is present;
#   - session user added to the docker group;
#   - audio: /etc/osmocom/gapk-start.sh, Asterisk 600 echo test, PulseAudio
#     echo canceller and speech-dispatcher sink; srsUE log levels;
#   - voice settings in the qosmo forks (scripts/voix-forks.sh);
#   - gnuarm profile, gcc alternatives, c123 and banc-* commands, WireGuard;
#   - patches/*.patch applied to the /opt/GSM trees (tools/osmo-patches-apply.sh).
#
# Usage:
#   sudo ./update.sh            run the catch-up steps, then play the animation
#   sudo ./update.sh --quiet    run the catch-up steps only (exit code 0)
#   ./update.sh -h | --help     print this header
#
# On the ISO, /etc/profile.d/99-osmo-sms.sh calls it once per session, after
# the keyboard choice (alphabetical order of /etc/profile.d). Most steps need
# root and are skipped silently otherwise. Without a tty, the result is shown
# in a zenity window when a display is available; otherwise the script exits
# 0 silently.
# ══════════════════════════════════════════════════════════════════════════════
set -u

# Called from /etc/profile.d and from desktop launchers, where the current
# directory is not the repository: move there before touching anything.
cd "$(dirname "$(readlink -f "$0")")" || true

case "${1:-}" in
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# ── DESKTOP ICONS, RE-INSTALLED AT EVERY SESSION ────────────────────────────
# "Icon=<name>" is resolved through the hicolor icon-theme cache, and a name
# that does not resolve is silently replaced by a blank page by GNOME/DING.
# The shortcuts therefore carry Icon= with an absolute path; the theme copy
# (plus a cache refresh) only serves the application menu. Idempotent.
osmo_reposer_icones() {
    [ "$(id -u)" -eq 0 ] || return 0        # without root: nothing to do
    local src=/opt/GSM/osmo-operator/data
    local dst=/usr/share/osmo-operator/icons
    [ -d "$src" ] || return 0

    install -d "$dst" 2>/dev/null || return 0
    local ic
    for ic in osmo-launch osmo-multi osmo-tutorial; do
        [ -f "$src/$ic.svg" ] || continue
        cp -f "$src/$ic.svg" "$dst/$ic.svg" 2>/dev/null || continue
        chmod 644 "$dst/$ic.svg" 2>/dev/null || true
        # The theme copy serves the application MENU, which still resolves
        # icons by name; the desktop uses the absolute path.
        install -d /usr/share/icons/hicolor/scalable/apps 2>/dev/null || true
        cp -f "$src/$ic.svg" \
              "/usr/share/icons/hicolor/scalable/apps/$ic.svg" 2>/dev/null || true
    done
    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true

    # Icon= as an absolute path: no theme, no cache, no silent fallback.
    # The shortcuts live in the menu and on each account's desktop (Bureau or
    # Desktop, whichever the locale names); every copy carries the same line.
    # All accounts are covered, not only a hard-coded "osmocom".
    local f b d
    for d in /usr/share/applications /root/Bureau /root/Desktop \
             /home/*/Bureau /home/*/Desktop; do
        [ -d "$d" ] || continue
        for b in osmo-launch osmo-multi osmo-tutorial; do
            f="$d/$b.desktop"
            [ -f "$f" ] || continue
            grep -q "^Icon=$dst/$b.svg\$" "$f" && continue
            sed -i "s|^Icon=.*|Icon=$dst/$b.svg|" "$f" 2>/dev/null || true
        done
    done

    # A desktop .desktop file only shows its name and icon when it is
    # executable AND carries metadata::trusted. That attribute lives in the
    # OWNER's gvfs session metadata, never in the file: a `gio set` run by root
    # sets it for root only, so it is set through the owner's account and
    # session bus (runuser), as _trust_desktop() in addition.sh does.
    local _own _uid _bus
    for d in "$HOME/Bureau" "$HOME/Desktop" /root/Bureau /root/Desktop \
             /home/*/Bureau /home/*/Desktop; do
        [ -d "$d" ] || continue
        _own="$(stat -c '%U' "$d" 2>/dev/null)"; [ -n "$_own" ] || _own=root
        _uid="$(id -u "$_own" 2>/dev/null)" || continue
        _bus="/run/user/$_uid/bus"
        for f in "$d"/*.desktop; do
            [ -f "$f" ] || continue
            chown "$_own" "$f" 2>/dev/null || true
            chmod +x "$f" 2>/dev/null || true
            if [ -S "$_bus" ] && command -v runuser >/dev/null 2>&1; then
                runuser -u "$_own" -- env XDG_RUNTIME_DIR="/run/user/$_uid" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=$_bus" \
                    gio set -t string "$f" metadata::trusted true 2>/dev/null || true
            else
                gio set -t string "$f" metadata::trusted true 2>/dev/null || true
            fi
        done
        # DING does not re-read metadata on the fly: touching the directory
        # forces a rescan.
        touch "$d" 2>/dev/null || true
    done
    update-desktop-database /usr/share/applications 2>/dev/null || true
    return 0
}
osmo_reposer_icones

# ── osmo-multi.service MUST NOT DIE WHEN THE NATIVE BENCH IS RECYCLED ───────
# start-multi.sh stops and restarts osmo-banc at every launch. With
# Requires=osmo-banc.service that explicit stop would propagate to osmo-multi
# itself during its ExecStart; Wants= keeps the boot order (After=) without
# propagating the stop.
osmo_corriger_multi_natif() {
    [ "$(id -u)" -eq 0 ] || return 0
    local unit=/etc/systemd/system/osmo-multi.service
    [ -f "$unit" ] || return 0
    grep -q '^Requires=osmo-banc\.service$' "$unit" || return 0
    sed -i 's/^Requires=osmo-banc\.service$/Wants=osmo-banc.service/' "$unit"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl daemon-reload 2>/dev/null || true
    fi
    echo "[OK] osmo-multi.service : Requires=osmo-banc -> Wants (plus de suicide au recyclage du natif)."
    return 0
}
osmo_corriger_multi_natif

# ── THE QEMU MOBILE MUST LOOK FOR THE CELL ON THE RADIO PLAN'S ARFCN ─────────
# The BSC of the multi containers transmits on PLAN_ARFCN, but the QEMU mobile
# of instance 1 reads c54x_exe/mobile_pont.cfg as is (run.sh only rewrites
# "stick" for instances 2+). Align the template on the radio plan:
# radio-plan.env, then ARFCN of globals.conf, then 1. Idempotent.
osmo_aligner_arfcn_qemu() {
    local cfg arfcn
    arfcn="$( . /etc/osmocom/radio-plan.env 2>/dev/null; echo "${PLAN_ARFCN:-}")"
    [ -n "$arfcn" ] || arfcn="$(sed -n 's/^ARFCN="\{0,1\}\([0-9]*\)"\{0,1\}$/\1/p' \
        "$(dirname "$(readlink -f "$0")")/globals.conf" 2>/dev/null | tail -1)"
    [[ "$arfcn" =~ ^[0-9]+$ ]] || arfcn=1
    for cfg in /opt/GSM/c54x_exe/mobile_pont.cfg; do
        [ -w "$cfg" ] || continue
        grep -qE "^[[:space:]]*stick ${arfcn}\$" "$cfg" \
            && ! grep -qE "^[[:space:]]*no (p|e)-gsm\$" "$cfg" && continue
        # The template only enables DCS (no p-gsm / no e-gsm): a stick on an
        # unsupported 900 MHz ARFCN makes gsm322_cs_powerscan loop at 100% CPU,
        # so the P/E-GSM bands are enabled as well.
        sed -i -e "s|^\([[:space:]]*\)stick [0-9]*\$|\1stick ${arfcn}|" \
            -e "s|^\([[:space:]]*\)no \([pe]-gsm\)\$|\1\2|" "$cfg"
        echo "[OK] $cfg : stick ${arfcn} (ARFCN du plan radio), bandes P/E-GSM actives."
    done
    return 0
}
osmo_aligner_arfcn_qemu

# ── THE OVERLAY PAINT TOOL ON ALREADY INSTALLED MACHINES ────────────────────
# tools/overlay-draw.py and its launcher: symlink, icon, absolute icon path.
# Idempotent.
osmo_poser_peinture() {
    [ "$(id -u)" -eq 0 ] || return 0
    local d=/opt/GSM/osmo-operator
    local py="$d/tools/overlay-draw.py"
    [ -f "$py" ] || return 0
    chmod 755 "$py" 2>/dev/null || true
    ln -sf "$py" /usr/local/bin/overlay-draw 2>/dev/null || true
    if [ -f "$d/data/osmo-paint.svg" ]; then
        install -d /usr/share/osmo-operator/icons \
                   /usr/share/icons/hicolor/scalable/apps 2>/dev/null || true
        cp -f "$d/data/osmo-paint.svg" /usr/share/osmo-operator/icons/osmo-paint.svg 2>/dev/null || true
        cp -f "$d/data/osmo-paint.svg" /usr/share/icons/hicolor/scalable/apps/osmo-paint.svg 2>/dev/null || true
        chmod 644 /usr/share/osmo-operator/icons/osmo-paint.svg 2>/dev/null || true
    fi
    if [ -f "$d/data/desktop/osmo-paint.desktop" ]; then
        install -m644 "$d/data/desktop/osmo-paint.desktop" \
                /usr/share/applications/osmo-paint.desktop 2>/dev/null || true
        sed -i "s|^Icon=.*|Icon=/usr/share/osmo-operator/icons/osmo-paint.svg|" \
            /usr/share/applications/osmo-paint.desktop 2>/dev/null || true
    fi
    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null || true
    update-desktop-database /usr/share/applications 2>/dev/null || true
    return 0
}
osmo_poser_peinture

# ── THE postmarketOS PHONE ON ALREADY INSTALLED MACHINES ────────────────────
# The bench phone is a postmarketOS/Phosh VM (tools/osmo-pmos.sh). The ISO and
# addition.sh (through tools/osmo-extras-install.sh) install its launcher and
# icon; this replays it on installed machines and removes the obsolete
# Waydroid launcher. Idempotent.
osmo_poser_pmos() {
    [ "$(id -u)" -eq 0 ] || return 0
    local d=/opt/GSM/osmo-operator
    [ -f "$d/tools/osmo-pmos.sh" ] || return 0
    chmod 755 "$d/tools/osmo-pmos.sh" 2>/dev/null || true
    cat > /usr/local/bin/osmo-pmos <<'PM'
#!/bin/bash
# osmo-pmos - the bench's postmarketOS phone (see tools/osmo-pmos.sh).
exec "${OSMO_REPO:-/opt/GSM/osmo-operator}/tools/osmo-pmos.sh" "$@"
PM
    chmod 755 /usr/local/bin/osmo-pmos 2>/dev/null || true
    cat > /usr/share/applications/osmo-pmos.desktop <<'PMD'
[Desktop Entry]
Type=Application
Name=Telephone (postmarketOS)
Comment=Le telephone du banc - Phosh, ModemManager, appels et SMS reels
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --tty --root --title "Telephone (postmarketOS)" -- /usr/local/bin/osmo-pmos up
Icon=phone
Terminal=false
Categories=Network;Telephony;
Keywords=postmarketos;phosh;telephone;sms;appel;modem;
Actions=Etat;Arreter;

[Desktop Action Etat]
Name=Etat du telephone
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --root --keep-open --title "Etat du telephone" -- /usr/local/bin/osmo-pmos status

[Desktop Action Arreter]
Name=Arreter le telephone
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --root --close-on-exit --title "Arret du telephone" -- /usr/local/bin/osmo-pmos stop
PMD
    chmod 644 /usr/share/applications/osmo-pmos.desktop 2>/dev/null || true
    # The two pmbootstrap launchers: tools/osmo-pmos-qemu.sh (the VM, format
    # smartphone|tablette as argument) and tools/osmo-pmos-setup.sh (modem and
    # voice, VM running). The matching pmbootstrap patch,
    # patches/pmbootstrap-osmo-bench-qemu.patch, applies to the user's
    # pmbootstrap, not here.
    local s
    for s in qemu setup; do
        [ -f "$d/tools/osmo-pmos-$s.sh" ] \
            && install -m 755 "$d/tools/osmo-pmos-$s.sh" "/usr/local/bin/osmo-pmos-$s" 2>/dev/null
    done
    # Two formats, two icons: Phosh lays itself out according to the screen
    # QEMU gives it (OSMO_PMOS_RES, read by the pmbootstrap patch), and that
    # size cannot change under a running session, so the format is chosen at
    # launch through two entries.
    local f n r
    for f in smartphone:720x1440 tablette:1280x800; do
        n="${f%%:*}"; r="${f#*:}"
        cat > "/usr/share/applications/osmo-pmos-$n.desktop" <<PMD
[Desktop Entry]
Type=Application
Name=postmarketOS - $n (banc)
Comment=Le telephone du banc, modem et voix branches tout seuls, en format $n ($r) - modem branche sur le banc GSM
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --tty --title "Telephone du banc (VM)" -- env OSMO_PMOS_RES=$r /usr/local/bin/osmo-pmos-qemu
Icon=$([ "$n" = tablette ] && echo video-display || echo phone)
Terminal=false
Categories=Network;Telephony;System;
Keywords=postmarketos;pmos;qemu;modem;gsm;telephone;$n;
Actions=Arreter;Setup;SansModem;

[Desktop Action Arreter]
Name=Arreter le telephone (osmo-pmos-qemu stop)
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --close-on-exit --title "Arret du telephone" -- /usr/local/bin/osmo-pmos-qemu stop

[Desktop Action Setup]
Name=Rebrancher le modem et la voix (osmo-pmos-setup)
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --tty --title "Modem et voix du telephone" -- /usr/local/bin/osmo-pmos-setup

[Desktop Action SansModem]
Name=Demarrer sans modem (VM nue)
Exec=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py --tty --title "Telephone du banc (VM)" -- env OSMO_PMOS_RES=$r OSMO_PMOS_MODEM=0 /usr/local/bin/osmo-pmos-qemu
PMD
        chmod 644 "/usr/share/applications/osmo-pmos-$n.desktop" 2>/dev/null || true
    done
    rm -f /usr/local/bin/osmo-waydroid /usr/share/applications/osmo-waydroid.desktop 2>/dev/null || true
    update-desktop-database /usr/share/applications 2>/dev/null || true
    echo "  [telephone] osmo-pmos pose (VM postmarketOS ; « osmo-pmos install » la premiere fois)"
    echo "  [telephone] deux formats au lancement : smartphone (720x1440) et tablette (1280x800)"
    echo "  [telephone] « osmo-pmos-qemu stop » (ou le clic droit de l icone) arrete la VM et debranche le modem"
    return 0
}
osmo_poser_pmos

# ── DEKA: A STOP ACTION ON THE ICON'S RIGHT CLICK ───────────────────────────
# addition.sh (--opencl) installs deka.desktop; it is rewritten here only to
# add the "Arreter deka" menu action (deka-start.sh --stop), and only when deka
# is installed. The main click still starts deka.
osmo_poser_deka() {
    local dsk=/usr/share/applications/deka.desktop
    [ -x /usr/local/bin/osmo-deka-anim ] || [ -f "$dsk" ] || return 0
    local icon=/usr/share/osmo-operator/icons/deka.svg
    [ -f "$icon" ] || icon=deka
    local gtk=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py
    cat > "$dsk" <<DEKADSK
[Desktop Entry]
Type=Application
Name=deka
Name[fr]=deka
Comment=Monte les tables et lance les workers deka
Comment[fr]=Monte les tables et lance les workers deka
Exec=/usr/local/bin/osmo-deka-anim
Icon=$icon
Terminal=false
Categories=System;Utility;
Keywords=deka;tables;workers;opencl;
Actions=Arreter;

[Desktop Action Arreter]
Name=Arreter deka
Name[fr]=Arreter deka
Exec=$gtk --root --title "Arret deka" -- /root/deka/deka-start.sh --stop
DEKADSK
    chmod 644 "$dsk" 2>/dev/null || true
    update-desktop-database /usr/share/applications 2>/dev/null || true
    echo "  [deka] icone : clic = demarrer, clic droit « Arreter deka » = stop (workers + demontages)"
}
osmo_poser_deka

# ── 4G AND THE SMARTPHONE UI: CATCH-UP ──────────────────────────────────────
# Same sources as addition.sh and the ISO (tools/osmo-lte-install.sh,
# tools/osmo-pmos-install.sh). Nothing is compiled here: repository configs
# (existing ones are not overwritten), the osmo-lte / osmo-epc /
# open5gs-epc.sh launchers, the /opt/user_interface/pmos layout and its PPP
# kernel (from the .deb cache or GitHub). Missing binaries come from the cached
# .deb files; otherwise run "osmo-lte-install --build".
osmo_poser_lte() {
    local d=/opt/GSM/osmo-operator
    if [ -f "$d/tools/osmo-lte-install.sh" ]; then
        # shellcheck source=tools/osmo-lte-install.sh
        DIR="$d" . "$d/tools/osmo-lte-install.sh"
        osmo_lte_install --debs --configs --launchers 2>&1 | sed 's/^/  [4G]/'
    fi
    if [ -f "$d/tools/osmo-pmos-install.sh" ]; then
        # shellcheck source=tools/osmo-pmos-install.sh
        DIR="$d" . "$d/tools/osmo-pmos-install.sh"
        osmo_pmos_install 2>&1 | sed 's/^/  [telephone]/'
    fi
}
osmo_poser_lte

# ── WIRESHARK: AN ICON THAT ALREADY LISTENS TO THE BENCH ────────────────────
# tools/osmo-wireshark-root.sh: root through pkexec, immediate LTE + SCTP + GSM
# capture, 2G + 4G + phone display filter (signalling, call, SMS, data;
# heartbeats removed) and filter buttons in root's profile. "wireshark" on the
# command line links to it. The dock favourite (org.wireshark.Wireshark, which
# cannot capture) is replaced by ours in every open session; favourites live
# in the user's dconf, not root's. The ISO does the same in 80-chroot.
osmo_poser_wireshark() {
    [ "$(id -u)" -eq 0 ] || return 0
    local d=/opt/GSM/osmo-operator
    [ -f "$d/tools/osmo-wireshark-root.sh" ] || return 0
    install -m 755 "$d/tools/osmo-wireshark-root.sh" /usr/local/bin/osmo-wireshark-root
    ln -sfn /usr/local/bin/osmo-wireshark-root /usr/local/bin/wireshark
    cat > /usr/share/applications/osmo-wireshark-root.desktop <<'WSD'
[Desktop Entry]
Type=Application
Name=Wireshark (banc)
GenericName=Analyseur reseau
Comment=Wireshark en root, capture immediate du banc, filtre 2G + 4G + telephone (signalisation, appel, SMS, data) sans les battements de coeur ; boutons Banc / 2G / 4G / Appel / SMS / Data / Attach
Exec=/usr/local/bin/osmo-wireshark-root %f
Icon=org.wireshark.Wireshark
Terminal=false
StartupNotify=true
Categories=Network;Monitor;
Keywords=wireshark;capture;pcap;reseau;lte;sctp;gsm;gsmtap;2g;4g;sms;appel;
WSD
    chmod 644 /usr/share/applications/osmo-wireshark-root.desktop
    update-desktop-database /usr/share/applications 2>/dev/null || true
    # The favourite, in every open GNOME session.
    local u uid bus
    for u in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $2}'); do
        uid="$(id -u "$u" 2>/dev/null)" || continue
        bus="/run/user/$uid/bus"; [ -S "$bus" ] || continue
        sudo -u "$u" DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" python3 - <<'PY' 2>/dev/null || true
import subprocess, ast
g = ["gsettings", "get", "org.gnome.shell", "favorite-apps"]
cur = ast.literal_eval(subprocess.run(g, capture_output=True, text=True).stdout.strip() or "[]")
neu = [a for a in cur if a not in ("org.wireshark.Wireshark.desktop", "wireshark.desktop", "wireshark-root.desktop")]
if "osmo-wireshark-root.desktop" not in neu:
    i = next((k for k, a in enumerate(cur) if a in ("org.wireshark.Wireshark.desktop", "wireshark.desktop")), len(neu))
    neu.insert(min(i, len(neu)), "osmo-wireshark-root.desktop")
if neu != cur:
    subprocess.run(["gsettings", "set", "org.gnome.shell", "favorite-apps", repr(neu)], check=False)
PY
    done
    echo "  [wireshark] osmo-wireshark-root pose (LTE + SCTP + GSM, root par pkexec) ; « wireshark » y mene ; favori du dock remplace"
    return 0
}
osmo_poser_wireshark

# ── THE /usr/local/bin LAUNCHERS (osmo-dino-play, osmo-youtube...) ──────────
# They are installed by tools/osmo-extras-install.sh (addition.sh and the ISO);
# replay its launcher function alone so installed machines follow the
# repository. Idempotent, no apt, no network.
osmo_reposer_lanceurs() {
    [ "$(id -u)" -eq 0 ] || return 0
    local ex=/opt/GSM/osmo-operator/tools/osmo-extras-install.sh
    [ -f "$ex" ] || return 0
    # shellcheck source=tools/osmo-extras-install.sh
    ( . "$ex" && _osmo_extras_lanceurs ) >/dev/null 2>&1 \
        && echo "  [bureau] lanceurs /usr/local/bin reposes (osmo-dino-play, osmo-pmos...)" \
        || true
    return 0
}
osmo_reposer_lanceurs

# ── osmo-start-direct -> start-native.sh ────────────────────────────────────
# /usr/local/bin/osmo-start-direct on an installed machine may still point to
# the removed start-direct.sh: repoint it and install osmo-start-native next
# to it. Idempotent.
osmo_reposer_lien_start_native() {
    [ "$(id -u)" -eq 0 ] || return 0
    local t=/opt/GSM/osmo-operator/start-native.sh l
    [ -f "$t" ] || return 0
    for l in /usr/local/bin/osmo-start-native /usr/local/bin/osmo-start-direct; do
        [ "$(readlink "$l" 2>/dev/null)" = "$t" ] || ln -sf "$t" "$l"
    done
    return 0
}
osmo_reposer_lien_start_native

# ── osmo-banc.service: THE INSTALLED UNIT FOLLOWS THE REPOSITORY ─────────────
# Re-install services/osmo-banc.service when it differs from the installed
# copy; a machine without the unit is left alone.
osmo_reposer_unite_banc() {
    [ "$(id -u)" -eq 0 ] || return 0
    local src=/opt/GSM/osmo-operator/services/osmo-banc.service dst=/etc/systemd/system/osmo-banc.service
    [ -f "$src" ] && [ -f "$dst" ] || return 0
    cmp -s "$src" "$dst" && return 0
    install -m644 "$src" "$dst" && systemctl daemon-reload 2>/dev/null || true
    return 0
}
osmo_reposer_unite_banc

# ── NO TELECOM SERVICE AT BOOT: APPLIED ONCE ─────────────────────────────────
# tools/osmo-telecom-boot.sh is run once (marker file) so that a service the
# operator re-enables afterwards (systemctl enable osmo-banc) is not disabled
# again at every update.
osmo_politique_telecom_boot() {
    [ "$(id -u)" -eq 0 ] || return 0
    local m=/var/lib/osmo-operator/telecom-boot-v1 t=/opt/GSM/osmo-operator/tools/osmo-telecom-boot.sh
    [ -e "$m" ] || [ ! -f "$t" ] && return 0
    bash "$t" && mkdir -p "${m%/*}" && date -Is > "$m"
    return 0
}
osmo_politique_telecom_boot

# ── THE DOCK'S "?": HELP PAGE SERVED OVER HTTP, FIRST FAVOURITE ─────────────
# Installs /usr/local/bin/osmo-info (dashboard on port 8080, local fallback),
# the help page in both locations, and osmo-info.desktop as first favourite of
# every open session (snap Firefox cannot open file:// pages).
osmo_poser_aide() {
    [ "$(id -u)" -eq 0 ] || return 0
    local R=/opt/GSM/osmo-operator u uid bus
    [ -f "$R/configs/info.html" ] || return 0
    install -m755 "$R/tools/osmo-info" /usr/local/bin/osmo-info 2>/dev/null || true
    install -D -m644 "$R/configs/info.html" /usr/share/osmo-operator/info.html
    [ -d /opt/GSM/osmo-egprs-web/web ] && cp -f "$R/configs/info.html" /opt/GSM/osmo-egprs-web/web/info.html
    install -m644 "$R/data/desktop/osmo-info.desktop" /usr/share/applications/osmo-info.desktop
    update-desktop-database /usr/share/applications 2>/dev/null || true
    for u in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $2}'); do
        uid="$(id -u "$u" 2>/dev/null)" || continue
        bus="/run/user/$uid/bus"; [ -S "$bus" ] || continue
        sudo -u "$u" DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" python3 - <<'PY' 2>/dev/null || true
import subprocess, ast
g = ["gsettings", "get", "org.gnome.shell", "favorite-apps"]
cur = ast.literal_eval(subprocess.run(g, capture_output=True, text=True).stdout.strip() or "[]")
neu = ["osmo-info.desktop"] + [a for a in cur if a != "osmo-info.desktop"]
if neu != cur:
    subprocess.run(["gsettings", "set", "org.gnome.shell", "favorite-apps", repr(neu)], check=False)
PY
    done
    return 0
}
osmo_poser_aide

# ── INTERACTIVE DESKTOP: CATCH-UP OF THE osmo-desktop-panel WRAPPER ──────────
# The widget launcher (/usr/local/bin/osmo-desktop-panel) is baked into the
# image by iso_modules/85-installeur-bureau.sh; the widgets (osmo-topzone.py,
# osmo-launcher.py, osmo-ts-probe.py) arrive by git pull. The wrapper is
# re-installed when it lacks osmo_vivant (widgets tracked per display).
# Exact mirror of iso_modules/85-installeur-bureau.sh.
osmo_reposer_bureau_interactif() {
    [ "$(id -u)" -eq 0 ] || return 0
    local w=/usr/local/bin/osmo-desktop-panel
    [ -f "$w" ] || return 0
    grep -q 'osmo_vivant' "$w" 2>/dev/null && return 0
    cat > "$w" <<'PANEL'
#!/bin/sh
# osmo-desktop-panel - keeps the inset and Conky alive for the whole session.
REPO=/opt/GSM/osmo-operator
export OSMO_REPO="$REPO"
# The LAB GSM banner is not baked into the wallpaper: osmo-topzone.py renders
# it live. Tell the wallpaper renderer.
export OSMO_LIVE_BANNER=1

# ── A WIDGET LEFT OVER FROM THE PREVIOUS SESSION IS NOT A WIDGET ────────────
# A conky or python widget from a previous X session may still be running with
# an old DISPLAY (e.g. :0 while GNOME restarted on :1): it cannot paint
# anything, but "pgrep -x conky" would count it as alive and nothing would be
# restarted. Only processes looking at OUR display count; the others are
# killed, they can no longer serve anyone.
osmo_vivant() {
    _trouve=1
    for _p in $(pgrep "$@" 2>/dev/null); do
        _d="$(tr '\0' '\n' < "/proc/$_p/environ" 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)"
        # Kill ONLY what was read and looks elsewhere. An unreadable environ,
        # or one without DISPLAY, proves nothing: that process counts as
        # alive - confusing "absent" with "invisible" would spawn a duplicate
        # of each widget on every pass.
        if [ -n "$_d" ] && [ "$_d" != "$DISPLAY" ]; then kill "$_p" 2>/dev/null
        else _trouve=0
        fi
    done
    return $_trouve
}
# The watcher must not outlive its own X server: otherwise the old one keeps
# running next to the new one and restarts into the void forever.
osmo_display_vivant() {
    [ -n "$DISPLAY" ] || return 0          # no named display: cannot judge
    _n="${DISPLAY#*:}"; _n="${_n%%.*}"
    [ -S "/tmp/.X11-unix/X$_n" ]
}

# ── CONKY ARROWS ON THE KEYBOARD: Ctrl+AltGr+Left / Right ───────────────────
# A gschema.override does NOT apply to a RELOCATABLE schema, so the shortcut
# is written here, in the session, once per boot: the only place that runs
# UNDER the user's account, where gsettings writes into their dconf.
# <Mod5> is ISO_Level3_Shift, i.e. AltGr (xmodmap -pm confirms it).
osmo_raccourci() {
    command -v gsettings >/dev/null 2>&1 || return 0
    _k=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding
    _p=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
        "['$_p/osmo-op-next/','$_p/osmo-op-prev/']" 2>/dev/null || return 0
    gsettings set "$_k:$_p/osmo-op-next/" name 'osmo-operator : arret suivant (Conky)' 2>/dev/null
    gsettings set "$_k:$_p/osmo-op-next/" command '/usr/local/bin/osmo-op --next' 2>/dev/null
    gsettings set "$_k:$_p/osmo-op-next/" binding '<Control><Mod5>Right' 2>/dev/null
    gsettings set "$_k:$_p/osmo-op-prev/" name 'osmo-operator : arret precedent (Conky)' 2>/dev/null
    gsettings set "$_k:$_p/osmo-op-prev/" command '/usr/local/bin/osmo-op --prev' 2>/dev/null
    gsettings set "$_k:$_p/osmo-op-prev/" binding '<Control><Mod5>Left' 2>/dev/null
}
osmo_raccourci

# Conky must find the GNOME desktop already painted (own_window_type
# desktop), otherwise it ends up behind the wallpaper.
sleep 6
while osmo_display_vivant; do
    osmo_vivant -f "$REPO/tools/osmo-panel.py" || \
        "$REPO/tools/osmo-panel.py" >>/tmp/osmo-panel.log 2>&1 &
    osmo_vivant -f "$REPO/tools/osmo-dino.py" || \
        "$REPO/tools/osmo-dino.py" >>/tmp/osmo-dino.log 2>&1 &
    # Timeslot activity probe (osmo-bsc conf + VTY) for the banner
    osmo_vivant -f "$REPO/tools/osmo-ts-probe.py" || \
        "$REPO/tools/osmo-ts-probe.py" >>/tmp/osmo-ts-probe.log 2>&1 &
    # Live LAB GSM top zone (blinking timeslots + app welcome)
    osmo_vivant -f "$REPO/tools/osmo-topzone.py" || \
        "$REPO/tools/osmo-topzone.py" >>/tmp/osmo-topzone.log 2>&1 &
    # The categorised launcher bar at the bottom

    osmo_vivant -f "$REPO/tools/osmo-launcher.py" || \
        "$REPO/tools/osmo-launcher.py" >>/tmp/osmo-launcher.log 2>&1 &
    osmo_vivant -x conky || \
        conky --daemonize -c "$REPO/configs/conky/osmo-conky.conf" >>/tmp/osmo-conky.log 2>&1
    sleep 5
done
PANEL
    chmod 755 "$w"
    # restart: kill the old wrapper, the autostart (or the loop) picks up the new one
    pkill -f /usr/local/bin/osmo-desktop-panel 2>/dev/null || true
    echo "  [bureau] wrapper osmo-desktop-panel remis a jour (zone LAB GSM vivante, barre de lancement, widgets suivis par display)"
    return 0
}
osmo_reposer_bureau_interactif

# ── THE TWO WEB CONSOLES, ENABLED BY DEFAULT (NATIVE SIDE) ──────────────────
# The ISO enables them at build time (iso_modules/60-dashboard.sh,
# iso_modules/82-services.sh); installed machines get the missing units here.
# `systemctl mask` is the way to opt out: a plain `disable` is undone at the
# next update, a masked unit is left alone.
# Neither unit is STARTED here: osmo-egprs-web follows the bench (PartOf=
# osmo-banc.service) and open5gs-webui has nothing to serve until the WebUI is
# built ("osmo-lte-install --webui").
osmo_activer_consoles_web() {
    [ "$(id -u)" -eq 0 ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local u src dst etat
    for u in osmo-egprs-web open5gs-webui; do
        src="$REPO/services/$u.service"
        dst="/etc/systemd/system/$u.service"
        [ -f "$src" ] || continue
        etat="$(systemctl is-enabled "$u" 2>/dev/null)"
        [ "$etat" = masked ] && continue          # masked by hand: respected
        if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
            install -m644 "$src" "$dst"
            systemctl daemon-reload 2>/dev/null || true
            echo "  [web] unite $u.service posee depuis le depot"
        fi
        if [ "$etat" != enabled ]; then
            systemctl enable "$u" >/dev/null 2>&1 \
                && echo "  [web] $u.service active au demarrage" \
                || echo "  [web] $u.service : activation impossible"
        fi
    done
    return 0
}
osmo_activer_consoles_web

# ── FIREFOX ─────────────────────────────────────────────────────────────────
# The dashboard and fft-web open in a browser. Recent images ship Mozilla's
# .deb, in which case this does nothing. Otherwise the Mozilla repository is
# set up and the package installed; the Ubuntu "firefox" package is not a
# fallback, it pulls snapd.
osmo_installer_firefox() {
    [ "$(id -u)" -eq 0 ] || return 0
    command -v firefox >/dev/null 2>&1 && return 0
    command -v apt-get >/dev/null 2>&1 || return 0
    echo "[*] Installation de Firefox (deb Mozilla)..."
    if [ ! -s /etc/apt/keyrings/packages.mozilla.org.asc ]; then
        install -d -m0755 /etc/apt/keyrings
        curl -fsSL --retry 3 https://packages.mozilla.org/apt/repo-signing-key.gpg \
             -o /etc/apt/keyrings/packages.mozilla.org.asc || {
            echo "[WARN] packages.mozilla.org injoignable - Firefox non installe."
            return 0
        }
    fi
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list
    printf "Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n" \
        > /etc/apt/preferences.d/mozilla
    apt-get update -qq 2>/dev/null || true
    if DEBIAN_FRONTEND=noninteractive apt-get install -y firefox >/dev/null 2>&1; then
        echo "[OK] Firefox installe (deb Mozilla)."
    else
        echo "[WARN] Firefox non installe (reseau ?)."
    fi
    return 0
}
osmo_installer_firefox

# ── THE SESSION ACCOUNT MUST SEE DOCKER ─────────────────────────────────────
# Conky (tools/conky-osmo-status.sh) and the panel (tools/osmo-panel.py) run
# under the SESSION account and probe each containerised operator with
# "docker exec"; without the docker group the probe reports every operator as
# stopped. The group is set at installation (users.conf, defaultGroups) and by
# addition.sh (_docker_groupe_session); this covers installed machines.
# Same user detection as addition.sh: SUDO_USER, then PKEXEC_UID, then the
# owner of an active session bus (update.sh is launched by an icon via pkexec
# as well as by sudo).
osmo_docker_groupe_session() {
    [ "$(id -u)" -eq 0 ] || return 0
    getent group docker >/dev/null 2>&1 || return 0
    local u uid bus vus=""
    for u in "${SUDO_USER:-}" \
             "$([ -n "${PKEXEC_UID:-}" ] && getent passwd "$PKEXEC_UID" | cut -d: -f1)"; do
        [ -n "$u" ] && [ "$u" != root ] && getent passwd "$u" >/dev/null 2>&1 && { vus="$u"; break; }
    done
    if [ -z "$vus" ]; then
        for bus in /run/user/*/bus; do
            [ -S "$bus" ] || continue
            uid="${bus#/run/user/}"; uid="${uid%/bus}"
            [ "$uid" = 0 ] && continue
            u="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)"
            [ -n "$u" ] && vus="$vus $u"
        done
    fi
    for u in $vus; do
        id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx docker && continue
        usermod -aG docker "$u" 2>/dev/null || continue
        echo "[OK] $u ajoute au groupe docker (le Conky et l encart voient les conteneurs)."
        echo "     Effectif au prochain login de $u."
    done
}
osmo_docker_groupe_session

# ── osmo-* UNITS: User=osmocom -> SESSION ACCOUNT (CATCH-UP) ────────────────
# Mirror of addition.sh (_osmo_unites_user_session). The upstream .service
# files (osmo-bsc/bts-trx/bts-virtual/msc) set User=osmocom / Group=osmocom,
# and that account does not exist natively (iso_modules/52-qemu.sh removes it)
# -> 217/USER, silent Restart=always crash loop. A drop-in
# /etc/systemd/system/<unit>.d/ hands the units to the session account; the
# upstream .service stays intact. Same user detection as
# osmo_docker_groupe_session.
osmo_unites_user_session() {
    [ "$(id -u)" -eq 0 ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local u uid bus grp unit base d n=0 vus=""
    for u in "${SUDO_USER:-}" \
             "$([ -n "${PKEXEC_UID:-}" ] && getent passwd "$PKEXEC_UID" | cut -d: -f1)"; do
        [ -n "$u" ] && [ "$u" != root ] && getent passwd "$u" >/dev/null 2>&1 && { vus="$u"; break; }
    done
    if [ -z "$vus" ]; then
        for bus in /run/user/*/bus; do
            [ -S "$bus" ] || continue
            uid="${bus#/run/user/}"; uid="${uid%/bus}"
            [ "$uid" = 0 ] && continue
            u="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)"
            [ -n "$u" ] && { vus="$u"; break; }
        done
    fi
    [ -n "$vus" ] && getent passwd "$vus" >/dev/null 2>&1 || vus=root
    grp="$(id -gn "$vus" 2>/dev/null || echo "$vus")"
    for unit in /lib/systemd/system/osmo-*.service /etc/systemd/system/osmo-*.service; do
        [ -f "$unit" ] || continue
        grep -qE '^(User|Group)=osmocom$' "$unit" || continue
        base="$(basename "$unit")"; d="/etc/systemd/system/$base.d"
        mkdir -p "$d"
        printf '[Service]\nUser=%s\nGroup=%s\n' "$vus" "$grp" > "$d/00-session-user.conf"
        n=$((n+1))
    done
    [ "$n" -gt 0 ] || return 0
    systemctl daemon-reload 2>/dev/null || true
    # osmocom state/log directories -> session account, otherwise "Unable to
    # create file /var/log/osmocom/*.log" and the .cfg parse fails (status=1).
    for _d in /var/log/osmocom /var/lib/osmocom /run/osmocom; do
        [ -e "$_d" ] && chown -R "$vus:$grp" "$_d" 2>/dev/null || true
    done
    for base in osmo-msc osmo-bsc osmo-bts-trx osmo-bts-virtual; do
        systemctl cat "$base" >/dev/null 2>&1 || continue
        systemctl reset-failed "$base" 2>/dev/null || true
        systemctl try-restart "$base" 2>/dev/null || true
    done
    echo "[OK] unites osmo-* rendues au compte de session ($vus) - sinon User=osmocom -> 217/USER."
    return 0
}
osmo_unites_user_session

# ── THE 600 ECHO TEST SOUNDS BAD: THE GAPK SUPERVISOR ───────────────────────
# lib/audio.sh prefers /etc/osmocom/gapk-start.sh, a COPY installed by the
# Dockerfile/ISO that git pull does not touch: re-install it from
# scripts/gapk-start.sh, kill a stray osmo-gapk transmitter (the mobile's
# gapk io-handler already carries the uplink) and restart the supervisor
# (tmux session "gapk") so it reads the new version.
osmo_poser_correctif_audio() {
    [ "$(id -u)" -eq 0 ] || return 0
    # NB: two separate 'local' statements: under 'set -u', bash evaluates all
    # right-hand sides of one 'local' before assigning the first one.
    local d=/opt/GSM/osmo-operator
    local src="$d/scripts/gapk-start.sh" dst=/etc/osmocom/gapk-start.sh
    [ -f "$src" ] || return 0
    if [ -d /etc/osmocom ] && ! cmp -s "$src" "$dst"; then
        install -m 755 "$src" "$dst" && echo "[OK] $dst repose depuis scripts/ (emetteur RTP en doublon retire)"
    fi
    # A running osmo-gapk is the old TX (the mobile never starts one): stop it.
    pkill -x osmo-gapk 2>/dev/null && echo "[OK] osmo-gapk en doublon arrete"
    rm -f /var/run/gapk-tx.pid /var/run/gapk-rx.pid
    # The supervisor is only restarted when it already runs: off bench, nothing to do.
    if tmux has-session -t gapk 2>/dev/null; then
        local log_dir; log_dir="$(tmux list-panes -t gapk -F '#{pane_start_command}' 2>/dev/null \
                                 | grep -oE 'tee [^ ]+/gapk-auto.log' | awk '{print $2}' | xargs -r dirname)"
        [ -n "$log_dir" ] || log_dir="${LOG_DIR:-/run/user/0/osmo-nitb/logs}"
        local sock="${PULSE_SOCK:-/var/run/pulse/native}"
        tmux kill-session -t gapk 2>/dev/null || true
        rm -f /var/run/gapk-auto.lock
        [ -x "$dst" ] || dst="$src"
        tmux new-session -d -s gapk \
            "GAPK_ALSA_DEV=gsm_out GAPK_ALSA_DEV_IN=gsm_in PULSE_SERVER=unix:${sock} bash '$dst' auto gsm gsm_out gsm_in 2>&1 | tee ${log_dir}/gapk-auto.log" \
            && echo "[OK] superviseur gapk relance (tmux gapk, journal ${log_dir}/gapk-auto.log)"
    fi
    # ── The 600 from the phone: no announcement before the echo ──
    # configs/extensions.conf skips the announcement when ECHO_NO_PROMPT=1
    # (set by osmo-phonesim-banc.py); the live copy /etc/asterisk/extensions.conf
    # is only regenerated at start-up, so it is patched here and reloaded.
    local ext=/etc/asterisk/extensions.conf
    if [ -f "$ext" ] && ! grep -q 'ECHO_NO_PROMPT' "$ext"; then
        sed -i '/^exten => 600,1,NoOp(=== ECHO TEST/,/^ same => n,Hangup()/{
            s|^ same => n,Playback(demo-echotest)$| same => n,GotoIf($["${ECHO_NO_PROMPT}" = "1"]?echo)\n same => n,Playback(demo-echotest)|
            s|^ same => n,Echo()$| same => n(echo),Echo()|
        }' "$ext" && echo "[OK] $ext : le 600 saute son annonce pour le banc (ECHO_NO_PROMPT)"
    fi
    # The echo test announcement, replayed on the mobile leg (Dial ...rT${DIAL_OPTS};
    # the bench sets DIAL_OPTS=A(demo-echotest) for 600): [internal] context only.
    if [ -f "$ext" ] && ! grep -q 'rT\${DIAL_OPTS}' "$ext"; then
        sed -i '/^\[internal\]/,/^\[/{s|^ same => n,Dial(PJSIP/${EXTEN}@gsm_msc,,rT)$| same => n,Dial(PJSIP/${EXTEN}@gsm_msc,,rT${DIAL_OPTS})|}' "$ext" \
            && echo "[OK] $ext : annonce de l echo test sur la patte du mobile (DIAL_OPTS)"
    fi
    command -v asterisk >/dev/null 2>&1 && asterisk -rx "dialplan reload" >/dev/null 2>&1 || true
    # The bench modem (osmo-phonesim-banc.py --connect) runs from the repository
    # but does not re-read its code: restart it exactly as osmo-pmos-setup.sh
    # launched it, so it picks up ECHO_NO_PROMPT.
    local bpid
    bpid="$(pgrep -f '[o]smo-phonesim-banc.py --connect' | head -1)"
    if [ -n "$bpid" ]; then
        local bargs; bargs="$(tr '\0' ' ' <"/proc/$bpid/cmdline" 2>/dev/null | sed 's/.*osmo-phonesim-banc.py //')"
        kill "$bpid" 2>/dev/null; sleep 1
        setsid nohup env OSMO_AT_LOG_OFONO=/tmp/osmo-at-vm.log \
            "$d/tools/osmo-phonesim-banc.py" $bargs >>/tmp/osmo-phonesim-vm-root.log 2>&1 </dev/null &
        sleep 3
        pgrep -f '[o]smo-phonesim-banc.py --connect' >/dev/null 2>&1 \
            && echo "[OK] modem du banc relance ($bargs) - journal /tmp/osmo-phonesim-vm-root.log" \
            || echo "[!!] le modem du banc ne s est pas relance : osmo-pmos-setup pour le rebrancher"
    fi
    # ── Saturated, bassy microphone: the echo canceller's analog AGC ──
    # module-echo-cancel (webrtc) drives the microphone gain and makes it pump
    # (see tools/osmo-pmos-setup.sh). If the canceller still runs without
    # aec_args, reload it identically with the analog AGC disabled and move
    # the VM's streams back onto it.
    export PULSE_SERVER="${PULSE_SERVER:-unix:/var/run/pulse/native}"
    # Only a WEBRTC canceller without aec_args: speex (the default, lib/audio.sh)
    # has none and must not be switched to webrtc.
    if command -v pactl >/dev/null 2>&1 && pactl list short modules 2>/dev/null | grep module-echo-cancel | grep -q aec_method=webrtc \
       && ! pactl list short modules 2>/dev/null | grep module-echo-cancel | grep -q analog_gain_control=0; then
        local ecm mic hp so si
        ecm="$(pactl list short modules | awk '/module-echo-cancel/ {print $1; exit}')"
        mic="$(pactl list short modules | grep module-echo-cancel | grep -oE 'source_master=[^ ]+' | cut -d= -f2)"
        hp="$(pactl list short modules | grep module-echo-cancel | grep -oE 'sink_master=[^ ]+' | cut -d= -f2)"
        if [ -n "$mic" ] && [ -n "$hp" ]; then
            pactl unload-module "$ecm" 2>/dev/null
            pactl load-module module-echo-cancel aec_method=webrtc source_master="$mic" sink_master="$hp" \
                source_name=osmo_mic_ec sink_name=osmo_hp_ec \
                'aec_args="analog_gain_control=0 digital_gain_control=1 noise_suppression=1 high_pass_filter=1"' \
                source_properties=device.description=Micro_sans_echo sink_properties=device.description=HP_sans_echo >/dev/null 2>&1 \
                && echo "[OK] annuleur d echo recharge sans AGC analogique (micro fixe a 25 %)"
            pactl set-default-source osmo_mic_ec 2>/dev/null; pactl set-default-sink osmo_hp_ec 2>/dev/null
            for so in $(pactl list source-outputs 2>/dev/null | awk '/Source Output #/{id=$3} /media.name = "combine"/{print id}' | tr -d '#'); do
                pactl move-source-output "$so" osmo_mic_ec 2>/dev/null; done
            for si in $(pactl list sink-inputs 2>/dev/null | awk '/Sink Input #/{id=$3} /media.name = "combine"/{print id}' | tr -d '#'); do
                pactl move-sink-input "$si" osmo_hp_ec 2>/dev/null; done
            pactl set-source-mute "$mic" 0 2>/dev/null; pactl set-source-volume "$mic" 25% 2>/dev/null
            pactl set-source-mute osmo_mic_ec 0 2>/dev/null; pactl set-source-volume osmo_mic_ec 25% 2>/dev/null
        fi
    fi
    # ── speech-dispatcher's dummy message in the speakers ──
    # See lib/audio.sh (osmo_tts_off): create the discard sink if missing and
    # move any open speech-dispatcher stream onto it.
    if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
        pactl list short sinks 2>/dev/null | grep -qw osmo_tts_off \
            || pactl load-module module-null-sink sink_name=osmo_tts_off format=s16le rate=8000 channels=1 sink_properties=device.description=TTS_off >/dev/null 2>&1
        for si in $(pactl list sink-inputs 2>/dev/null | awk '/Sink Input #/{id=$3} /application.name = "speech-dispatcher/{print id}' | tr -d '#'); do
            pactl move-sink-input "$si" osmo_tts_off 2>/dev/null && echo "[OK] flux speech-dispatcher detourne des haut-parleurs (osmo_tts_off)"
        done
    fi
    return 0
}
osmo_poser_correctif_audio

# ── THE DESKTOP srsUE CONSOLE: 4G LOGS ──────────────────────────────────────
# osmo-lte.sh sets --log.filename=/tmp/osmo-lte-ue.log and the console in
# /tmp/osmo-lte-ue.console. Set NAS to info (no hex dump) in an already
# installed ue.conf (osmo-lte-install --configs does not overwrite it without
# --force) and restart the osmo-fft-snap panel, which reads its paths at
# start-up. The UE itself is not restarted: the levels apply at the next
# "osmo-lte restart".
osmo_poser_journaux_lte() {
    [ "$(id -u)" -eq 0 ] || return 0
    local f
    for f in /root/.config/srsran/ue.conf /home/*/.config/srsran/ue.conf; do
        [ -f "$f" ] || continue
        grep -q '^nas_hex_limit *= *0' "$f" && continue
        sed -i -e '/^rrc_level *= *info$/d' -e '/^nas_level *= *info$/d' \
               -e '/^\[log\]/,/^\[/{s/^\(all_level *= *warning\)$/\1\nnas_level = info\nnas_hex_limit = 0/}' \
               -e 's|^filename *= */tmp/ue\.log$|filename = /tmp/osmo-lte-ue.log|' "$f" \
            && echo "[OK] $f : NAS en info (console srsUE du bureau)"
    done
    if systemctl is-active --quiet osmo-fft-snap 2>/dev/null; then
        systemctl try-restart osmo-fft-snap 2>/dev/null && echo "[OK] encart osmo-fft-snap relance (console srsUE)"
    fi
    return 0
}
osmo_poser_journaux_lte

# ── TCH FRAME FORMAT AND MOBILE BUFFER, IN THE FORKS ────────────────────────
# Two vital voice settings live in repositories that the update re-fetches
# (qosmo-grgsm, qosmo-dsp; "git reset --hard FETCH_HEAD"), so git pull on
# osmo-operator cannot carry them:
#
#  1. "io-tch-format rtp" in the forks' cfgs/mobile_group1.cfg, the template
#     that run.sh (run_modules/20-mobile-cfg.sh) copies over
#     ~/.osmocom/bb/mobile_group1.cfg at every start. Without it the mobile
#     uses the Texas Instruments TCH frame layout while pont.py encodes
#     RTP/RFC3551 with libosmocoding: no counter complains, the voice is
#     robotic.
#
#  2. CALYPSO_PULSE_LATENCY_MSEC in run_modules/70-l2.sh and
#     68-sidecar-mobile.sh. The mobile writes one 20 ms GSM frame per
#     snd_pcm_writei; with a too short ALSA-PulseAudio buffer every write
#     returns -EPIPE and the PulseAudio stream is torn down and rebuilt 50
#     times per second. 200 ms or more is enough (start-native.sh exports 320).
#
# scripts/voix-forks.sh is the only place that applies both settings; it is
# also called by the osmo-update service (after its fetch) and by
# iso_modules/70-scripts.sh (on the rootfs).
# Check: `grep io-tch-format ~/.osmocom/bb/mobile_group1.cfg` after a start,
# and the mobile's sink-input index must stay fixed during a call
# (`pactl list short sink-inputs`, two readings 1 s apart).
osmo_poser_voix_forks() {
    [ "$(id -u)" -eq 0 ] || return 0
    local s=/opt/GSM/osmo-operator/scripts/voix-forks.sh
    [ -x "$s" ] || return 0
    "$s" | sed 's/^  \[voix\]/[OK]/'
    return 0
}
osmo_poser_voix_forks

# ── gnuarm, GCC ALTERNATIVES, c123 AND banc-*: CATCH-UP ─────────────────────
# What build-iso.sh (70-scripts, 80-chroot) and the native install set up,
# replayed on an installed machine. No apt, no network: only compilers already
# present enter the alternatives.
#   - /etc/profile.d/97-osmo-gnuarm.sh: /root/gnuarm/install/bin in PATH
#     (arm-elf-gcc 4.5.2 from addition.sh --gnuarm), no effect while absent;
#   - update-alternatives gcc: gcc-9 (90), gcc-11 (110), gcc-13 (130). An
#     existing choice (update-alternatives --config gcc) is kept; on creation,
#     gcc-13, the kernel compiler, for DKMS;
#   - c123 / osmo-c123 and the bench commands (banc-rssi, banc-trx, c123-1...)
#     in /usr/local/bin, 98-osmo-banc-aliases.sh in profile.d;
#   - /usr/local/bin/osmo-glava (a copy, not a link) aligned on tools/osmo-glava.sh.
osmo_poser_outils_banc() {
    [ "$(id -u)" -eq 0 ] || return 0
    local r=/opt/GSM/osmo-operator v
    [ -d "$r" ] || return 0
    [ -f "$r/scripts/osmo-gnuarm-profile.sh" ] \
        && install -m644 "$r/scripts/osmo-gnuarm-profile.sh" /etc/profile.d/97-osmo-gnuarm.sh
    [ -f "$r/scripts/osmo-banc-aliases.sh" ] \
        && install -m644 "$r/scripts/osmo-banc-aliases.sh" /etc/profile.d/98-osmo-banc-aliases.sh
    # WAN WireGuard ("wg 1", "wg N ..."); the package itself needs apt: native install / ISO
    [ -f "$r/scripts/osmo-wg-profile.sh" ] \
        && install -m644 "$r/scripts/osmo-wg-profile.sh" /etc/profile.d/97-osmo-wg.sh \
        && ln -sf "$r/tools/osmo-wg.sh" /usr/local/bin/osmo-wg
    [ -x "$r/tools/osmo-banc-cmd.sh" ] && bash "$r/tools/osmo-banc-cmd.sh" --install /usr/local/bin >/dev/null
    for v in c123 osmo-c123; do
        [ "$(readlink "/usr/local/bin/$v" 2>/dev/null)" = "$r/tools/osmo-c123-gtk.py" ] \
            || ln -sf "$r/tools/osmo-c123-gtk.py" "/usr/local/bin/$v"
    done
    [ -f /usr/local/bin/osmo-glava ] && [ -f "$r/tools/osmo-glava.sh" ] \
        && ! cmp -s "$r/tools/osmo-glava.sh" /usr/local/bin/osmo-glava \
        && install -m755 "$r/tools/osmo-glava.sh" /usr/local/bin/osmo-glava \
        && echo "  [bureau] osmo-glava aligne sur le depot (systemctl --user restart glava)"
    # gcc-9 / gcc-11 / gcc-13 alternatives (single definition: tools/osmo-gcc-alternatives.sh)
    [ -x "$r/tools/osmo-gcc-alternatives.sh" ] && bash "$r/tools/osmo-gcc-alternatives.sh"
    return 0
}
osmo_poser_outils_banc

# ── PATCHES FOR THE /opt/GSM TREES (patches/) ───────────────────────────────
# The trees installed by the ISO (osmocom-bb, osmo-trx...) receive the
# repository patches: idempotent, offline. With gnuarm (addition.sh --gnuarm),
# "cd /opt/GSM/osmocom-bb/src && make" then builds the GPRS layer1.
osmo_poser_correctifs() {
    [ "$(id -u)" -eq 0 ] || return 0
    local r=/opt/GSM/osmo-operator
    [ -x "$r/tools/osmo-patches-apply.sh" ] || return 0
    OSMO_PATCHES_QUIET=1 bash "$r/tools/osmo-patches-apply.sh" /opt/GSM 2>/dev/null | sed 's/^ */[OK] /'
    return 0
}
osmo_poser_correctifs

case "${1:-}" in
    --quiet) exit 0 ;;
esac

# Remove a stale global http.version setting if still present (see Dockerfile).
git config --global --unset http.version 2>/dev/null || true


# ── WITHOUT A TERMINAL: A GTK WINDOW ────────────────────────────────────────
# Launched from the desktop icon the script never has a tty; the catch-up
# steps above are already done when we get here. With a display server the
# result is shown through zenity (no cursor sequences outside a terminal);
# without terminal or display (cron, ssh without X, /etc/profile.d on a
# console) exit silently with code 0. zenity comes with the desktop variant
# (build-iso.sh installs it): its absence means an image without a desktop.
if [ ! -t 1 ]; then
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v zenity >/dev/null 2>&1; then
        # --pulsate, not a percentage: there is no progress left to measure.
        # --auto-close so the window leaves with the stream, no button to click.
        {
            echo "# Recherche de la cellule (ARFCN)..." ; sleep 0.6
            echo "# Raccourcis du bureau reposes."      ; sleep 0.6
            echo "# Envoi du SMS de test..."            ; sleep 0.6
        } | zenity --progress --pulsate --auto-close --no-cancel \
                   --title="osmo-operator - mise a jour" \
                   --width=420 --text="Mise a jour en cours..." 2>/dev/null
        zenity --info --title="osmo-operator" --width=420 \
               --text="<b>SMS delivered</b> - MT end-to-end\n\nMessage : Bastien phone home\n\nLes raccourcis du bureau ont ete reposes." \
               2>/dev/null
    fi
    exit 0
fi

printf '\033[?25l'
trap 'printf "\033[?25h"' EXIT

ph='\033[1;33m☎\033[0m'
bars=('\033[2m▁▁▁\033[0m' '\033[1;32m▃\033[0m\033[2m▁▁\033[0m' '\033[1;32m▃▅\033[0m\033[2m▁\033[0m' '\033[1;32m▃▅▇\033[0m')
for b in "${bars[@]}"; do
    printf '\r  %b %b  \033[36mscanning ARFCN...\033[0m   ' "$ph" "$b"
    sleep 0.12
done
for ((p=0; p<=20; p++)); do
    printf '\r\033[K  %b %*s\033[1;36m✉\033[0m%*s %b' "$ph" "$p" '' "$((20-p))" '' "$ph"
    sleep 0.04
done
printf '\r\033[K  %b%21s%b  \033[1;32m✓ SMS delivered - MT end-to-end Message : Bastien phone home\033[0m\n' "$ph" '' "$ph"

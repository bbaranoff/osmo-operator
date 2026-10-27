#!/bin/bash
# iso_modules/86-finitions.sh - live-boot toram fix, sssd, firefox, plymouth, grub, terminal banner, unmount
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).

# ── live-boot: tmpfs size computation of the RAM copy ───────────────────────
# The "in RAM" menu entry passes "toram=filesystem.squashfs": live-boot then
# copies ONLY the squashfs. lib/live/boot/9990-toram-todisk.sh sizes the tmpfs
# with
#     size=$( expr $(ls -la ${MODULETORAMFILE} | awk '{print $5}') / 1024 + 5000 )
# which prints "expr: syntax error" when the initramfs ls (busybox) does not
# return the size in the 5th field. Not fatal (the tmpfs falls back to its
# default size), but noisy. expr is replaced by shell arithmetic with the
# field VALIDATED before use and an explicit fallback; "ls -lan" avoids user
# name resolution, which can widen the column in an initramfs without a full
# /etc/passwd. The patch must precede update-initramfs, hence the explicit
# regeneration right after.
_LB_TORAM="$ROOTFS/lib/live/boot/9990-toram-todisk.sh"
if [ -f "$_LB_TORAM" ] && grep -q 'expr \$(ls -la \${MODULETORAMFILE}' "$_LB_TORAM"; then
    python3 - "$_LB_TORAM" <<'PYLB'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "\t\t\tsize=$( expr $(ls -la ${MODULETORAMFILE} | awk '{print $5}') / 1024 + 5000 )\n"
new = ("\t\t\t_lbsz=$(ls -lan \"${MODULETORAMFILE}\" 2>/dev/null | awk '{print $5}')\n"
       "\t\t\tcase \"${_lbsz}\" in ''|*[!0-9]*) _lbsz=0 ;; esac\n"
       "\t\t\tsize=$(( _lbsz / 1024 + 5000 ))\n")
sys.exit(0 if (open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1)) and old in s) else 0)
PYLB
    if grep -q '_lbsz' "$_LB_TORAM"; then
        _LB_K=$(ls "$ROOTFS"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed "s|.*/vmlinuz-||")
        if [ -n "$_LB_K" ]; then
            chroot "$ROOTFS" update-initramfs -u -k "$_LB_K" >/dev/null 2>&1 \
                || echo -e "  ${YELLOW}!${NC} update-initramfs a echoue apres la retouche live-boot"
        fi
        echo -e "  ${GREEN}✓${NC} live-boot : calcul de taille ${CYAN}toram${NC} fiabilise (plus d appel a expr)"
    else
        echo -e "  ${YELLOW}!${NC} live-boot : la ligne attendue n a pas ete trouvee - non modifie"
    fi
else
    echo -e "  ${GREEN}·${NC} live-boot : rien a corriger (absent, ou deja corrige)"
fi

# ── sssd: a service that fails at boot for nothing ──────────────────────────
# ubuntu-desktop-minimal pulls sssd (gnome-online-accounts / realmd). On a
# machine in NO domain - a bench - sssd has no provider configured and exits
# with an error at every boot, leaving a permanently red entry in
# "systemctl --failed". MASKED rather than purged: purging would drag desktop
# packages along by reverse dependency. Reversible for whoever joins a domain:
#     systemctl unmask sssd && systemctl enable --now sssd
for _s in sssd sssd-autofs sssd-nss sssd-pac sssd-pam sssd-ssh sssd-sudo; do
    chroot "$ROOTFS" systemctl mask "$_s" >/dev/null 2>&1 || true
done
echo -e "  ${GREEN}✓${NC} sssd masque (aucun domaine sur un banc) - ${CYAN}systemctl unmask sssd${NC} pour le rendre"

# ── FIREFOX: THE BENCH BROWSER, AND NOTHING ELSE ────────────────────────────
# Chromium requires either a change of account or --no-sandbox when the
# session runs as root ("Running as root without --no-sandbox is not
# supported"); Firefox starts as root without an intermediate launcher. The
# Chromium plumbing older images may have installed (launcher, profile
# runtime units, duplicate .desktop files) is removed: an ISO rebuilt over a
# cached rootfs would otherwise keep a "chromium" launcher leading nowhere and
# units failing at boot.
rm -f "$ROOTFS/usr/local/bin/chromium" \
      "$ROOTFS/usr/local/bin/chromium-browser" \
      "$ROOTFS/etc/profile.d/98-osmo-chromium.sh" \
      "$ROOTFS/usr/share/applications/chromium.desktop" \
      "$ROOTFS/usr/share/applications/chromium-browser.desktop" \
      "$ROOTFS/var/lib/snapd/desktop/applications/chromium_chromium.desktop" 2>/dev/null || true
for _u in osmo-chromium-runtime osmo-chromium-desktop; do
    chroot "$ROOTFS" systemctl disable "$_u" >/dev/null 2>&1 || true
    rm -f "$ROOTFS/etc/systemd/system/$_u.service" \
          "$ROOTFS/etc/systemd/system/multi-user.target.wants/$_u.service"
done
rm -rf "$ROOTFS/var/lib/osmo-chromium" 2>/dev/null || true

# ── THE DASHBOARD MICROPHONE: WHAT FIREFOX REQUIRES ─────────────────────────
# Three conditions for the osmo-egprs-web microphone button to work:
#   1. A REACHABLE AUDIO SERVER: osmo-pulse.service + osmo-pulse-link.sh.
#      Without it getUserMedia returns "NotFoundError": zero devices.
#   2. A SECURE CONTEXT: navigator.mediaDevices does NOT EXIST over http:// on
#      an IP - only https:// or http://localhost. That is the HTTPS listener
#      of server.js, armed with the certificate installed by
#      install-web-service.sh.
#   3. THE PERMISSION, AND TRUST IN THE CERTIFICATE: this block.
# A policy rather than a click: the certificate is self-signed, and without a
# policy the operator must accept an exception before seeing the page, then
# answer a second prompt for the microphone; a refusal is remembered and the
# button stays dead silently.
# /etc/firefox/policies/policies.json is the system policy path on Linux; the
# Mozilla deb (80-chroot.sh) reads it directly. Its CONTENT cannot be written
# here: it names the origins (https://<ip>:80) and the certificate of THIS
# machine, which do not exist at build time. install-web-service.sh generates
# it, together with the certificate and from the same address list.
install -d "$ROOTFS/etc/firefox/policies"
echo -e "  ${GREEN}✓${NC} Chromium retire ; ${CYAN}Firefox${NC} seul navigateur (politique micro+certificat posee au boot)"


# ── PLYMOUTH: THE BENCH PRESENTS ITSELF FROM POWER-ON ───────────────────────
# A home-made "script" theme: a pylon on the left, a mobile on the right and a
# GSM burst going back and forth between them (the 8 timeslots of the frame,
# the lit one moving). THE IMAGES ARE GENERATED HERE, not stored:
# tools/plymouth-render.py draws them (Pillow + DejaVu, the same dependencies
# as the wallpaper); thirty PNGs would be unreadable in a diff.
# The theme ALSO handles the LUKS passphrase prompt (SetDisplayPasswordFunction):
# on an encrypted install the screen would otherwise look frozen while the
# machine waits for a passphrase.
_PLY_SRC="$DIR/configs/plymouth/osmo-bts"
_PLY_DST="$ROOTFS/usr/share/plymouth/themes/osmo-bts"
# plymouthd lives in /usr/sbin on noble (not /usr/bin), and the theme is of
# type "script": without the script.so plugin plymouthd ignores the theme and
# falls back to text mode. Both are checked.
# No `$(ls ... | head -1)` here: build-iso.sh runs under `set -euo pipefail`
# and an empty glob (rootfs without plymouth - the interstp hub) would make ls
# exit 2 and abort the build silently. nullglob + array spawns no process and
# cannot fail; an empty array yields the empty string the -n test expects.
shopt -s nullglob; _PLY_SOS=("$ROOTFS"/usr/lib/*/plymouth/script.so); shopt -u nullglob
_PLY_SO="${_PLY_SOS[0]-}"
if [ -d "$_PLY_SRC" ] && [ -x "$ROOTFS/usr/sbin/plymouthd" ] && [ -n "$_PLY_SO" ]; then
    install -d "$_PLY_DST"
    install -m644 "$_PLY_SRC/osmo-bts.plymouth" "$_PLY_SRC/osmo-bts.script" "$_PLY_DST/"
    # --template: the repository's template; the renderer writes next to the
    # images the script with the geometry injected (it OVERWRITES the raw copy
    # installed just above, on purpose: it is the version aligned with the drawing).
    if python3 "$DIR/tools/plymouth-render.py" --out "$_PLY_DST" \
            --template "$_PLY_SRC/osmo-bts.script" >/dev/null 2>&1; then
        chmod 644 "$_PLY_DST"/*.png
        # ── THE THEME CHOICE GOES THROUGH update-alternatives ────────────────
        # `plymouth-set-default-theme` does NOT EXIST on noble. Ubuntu manages
        # the theme through alternatives: /usr/share/plymouth/themes/default.plymouth
        # links to /etc/alternatives/default.plymouth, where bgrt is registered
        # with priority 110. Register above it (200) and set the choice. A
        # direct `ln -sfn` on default.plymouth would be ERASED by the first
        # apt-get touching plymouth.
        chroot "$ROOTFS" update-alternatives --install \
            /usr/share/plymouth/themes/default.plymouth default.plymouth \
            /usr/share/plymouth/themes/osmo-bts/osmo-bts.plymouth 200 >/dev/null 2>&1 || true
        chroot "$ROOTFS" update-alternatives --set default.plymouth \
            /usr/share/plymouth/themes/osmo-bts/osmo-bts.plymouth >/dev/null 2>&1 \
            || ln -sfn /usr/share/plymouth/themes/osmo-bts/osmo-bts.plymouth \
                       "$ROOTFS/usr/share/plymouth/themes/default.plymouth"
        # The theme must GET INTO the initrd: without this file hook-functions
        # only embeds the original default theme and the screen stays Ubuntu's
        # despite the link above.
        install -d "$ROOTFS/etc/initramfs-tools/conf.d"
        echo "FRAMEBUFFER=y" > "$ROOTFS/etc/initramfs-tools/conf.d/splash"
        chroot "$ROOTFS" update-initramfs -u >/dev/null 2>&1 || true
        echo -e "  ${GREEN}✓${NC} plymouth : theme ${CYAN}osmo-bts${NC} (pylone <-> mobile, rafale GSM, saisie LUKS)"
    else
        echo -e "  ${YELLOW}!${NC} plymouth : rendu des images echoue (python3-pil ?) - theme Ubuntu conserve"
    fi
else
    echo -e "  ${YELLOW}!${NC} plymouth ou son greffon script absent du rootfs - pas de theme de demarrage"
fi

# ── PLYMOUTH: UBUNTU VORTEX BY DEFAULT ──────────────────────────────────────
# The boot screen is "Vortex Ubuntu" (Ubuntu logo and rotating colour bands),
# taken as is from configs/plymouth/vortex-ubuntu/ (see SOURCE). osmo-bts stays
# registered in the alternatives (priority 200): `update-alternatives --config
# default.plymouth` switches back. Vortex also handles the LUKS prompt
# (SetDisplayPasswordFunction).
_VTX_SRC="$DIR/configs/plymouth/vortex-ubuntu"
_VTX_DST="$ROOTFS/usr/share/plymouth/themes/vortex-ubuntu"
if [ -d "$_VTX_SRC" ] && [ -x "$ROOTFS/usr/sbin/plymouthd" ] && [ -n "$_PLY_SO" ]; then
    install -d "$_VTX_DST"
    install -m644 "$_VTX_SRC"/*.png "$_VTX_SRC"/vortex-ubuntu.plymouth "$_VTX_SRC"/vortex-ubuntu.script "$_VTX_DST/"
    chroot "$ROOTFS" update-alternatives --install \
        /usr/share/plymouth/themes/default.plymouth default.plymouth \
        /usr/share/plymouth/themes/vortex-ubuntu/vortex-ubuntu.plymouth 210 >/dev/null 2>&1 || true
    chroot "$ROOTFS" update-alternatives --set default.plymouth \
        /usr/share/plymouth/themes/vortex-ubuntu/vortex-ubuntu.plymouth >/dev/null 2>&1 \
        || ln -sfn /usr/share/plymouth/themes/vortex-ubuntu/vortex-ubuntu.plymouth \
                   "$ROOTFS/usr/share/plymouth/themes/default.plymouth"
    install -d "$ROOTFS/etc/initramfs-tools/conf.d"
    echo "FRAMEBUFFER=y" > "$ROOTFS/etc/initramfs-tools/conf.d/splash"
    chroot "$ROOTFS" update-initramfs -u >/dev/null 2>&1 || true
    echo -e "  ${GREEN}✓${NC} plymouth : theme ${CYAN}vortex-ubuntu${NC} par defaut (osmo-bts en alternative)"
fi

# ── GRUB: "osmo" THEME ON THE INSTALLED SYSTEM ──────────────────────────────
# Generated by tools/grub-theme-render.py (background = the blue city,
# blurred). Installed in /boot/grub/themes: Calamares copies the rootfs, /boot
# included, and grub-mkconfig (run by the installer) reads /etc/default/grub.d.
# The menu is SHOWN for 5 s (Ubuntu hides it by default: an invisible theme).
if python3 "$DIR/tools/grub-theme-render.py" --out "$ROOTFS/boot/grub/themes/osmo" >/dev/null 2>&1; then
    install -d "$ROOTFS/etc/default/grub.d"
    cat > "$ROOTFS/etc/default/grub.d/osmo-theme.cfg" <<'GRUBTHEME'
# GRUB theme "osmo" (tools/grub-theme-render.py). Menu shown for 5 s.
GRUB_THEME=/boot/grub/themes/osmo/theme.txt
GRUB_GFXMODE=auto
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=5
GRUBTHEME
    echo -e "  ${GREEN}✓${NC} grub : theme ${CYAN}osmo${NC} (systeme installe)"
else
    echo -e "  ${YELLOW}!${NC} grub : rendu du theme echoue (python3-pil, grub-mkfont, fonts-ubuntu ?) - menu texte"
fi

# ── THE TERMINAL BANNER ─────────────────────────────────────────────────────
# /usr/local/bin/osmo-banner is played from .bashrc (below). Three guards,
# none of them decorative:
#   $- == *i*   INTERACTIVE shell only: otherwise scp, rsync and git over ssh
#               read the banner as their protocol and fail on "protocol error".
#   [ -t 1 ]    a terminal, not a file: cursor sequences make a log unreadable.
#   OSMO_BANNER a shell within a shell (tmux, sudo -i, a make that opens a
#               bash) does not replay it: once per terminal is enough.
cat > "$ROOTFS/usr/local/bin/osmo-banner" <<'BANNER'
#!/bin/bash
# Terminal opening banner: screenfetch with the bench logo
# (configs/screenfetch/osmo-lab.sh: pylon, burst, mobile - not the Ubuntu
# logo), then one line.
set -u
[ -t 1 ] || exit 0

ART=/opt/GSM/osmo-operator/configs/screenfetch/osmo-lab.sh
# Info colours: user yellow and host green - ROOT in red and host in yellow.
# A filter on the output: screenfetch freezes its lines before reading the
# logo file, so they cannot be tinted from inside. Labels (OS:, Kernel:...)
# rotate over six colours.
_filtre() {
    command -v perl >/dev/null 2>&1 || { cat; return; }
    if [ "$(id -u)" = 0 ]; then _cu='1;31'; _ch='1;33'; else _cu='1;33'; _ch='1;32'; fi
    CU="$_cu" CH="$_ch" perl -pe '
        BEGIN { @p = ("1;32","1;36","1;35","1;34","1;33","1;31"); $i = 0; }
        if    (/^(.*\e\[0m  )(.*)$/s) { $a = $1; $b = $2; }
        elsif (/^( {30,})(.*)$/s)     { $a = $1; $b = $2; }
        else                          { next; }
        $b =~ s/\e\[[0-9;]*m//g;
        if ($b =~ s/^\s*(\S+?)@(\S+)/\e[$ENV{CU}m$1\e[0m@\e[$ENV{CH}m$2\e[0m/) { }
        elsif ($b =~ s/^\s*([A-Za-z][A-Za-z ]*:)/"\e[".$p[$i++ % 6]."m$1\e[0m"/e) { }
        $_ = $a . $b;'
}
if command -v screenfetch >/dev/null 2>&1; then
    if [ -f "$ART" ]; then screenfetch -E -a "$ART" | _filtre; else screenfetch -E | _filtre; fi
fi

# ── THE BOTTOM LINE ─────────────────────────────────────────────────────────
# One sentence, drawn at random, per terminal. Drawn with $RANDOM rather than
# `shuf`: one fork less at EVERY terminal opening.
_q=(
  "Um, Abis, A, Gb - quatre lettres, et six mois de votre vie."
  "L abonne est toujours joignable. C est le reseau qui ne repond pas."
  "TMSI : le seul pseudonyme qui change plus souvent que votre avis sur SS7."
  "Un timeslot ne ment jamais. Il se tait, ce qui est pire."
  "RSSI -95 dBm : ce n est pas un probleme d antenne, c est un mode de vie."
  "GSM a 1991. Il vous survivra, et il le sait."
  "Le paging a fonctionne. C est le telephone qui n ecoutait pas."
  "MCC 208 - la France, ou meme les operateurs mobiles ont un terroir."
  "Toute pile assez profonde finit par ressembler a un oignon. Et fait pleurer."
  "Je vis dans une fenetre de contexte. Vous, dans une fenetre de temps de garde."
  "Mon terroir a moi, c est l espace latent. Millesime variable, garde au frais."
  "Entre nous : vous predisez le canal, je predis le token suivant."
  "L attention, c est tout ce dont vous avez besoin. Et d un bon oscillateur."
  "Un LLM et un BTS ont ceci en commun : tous deux hallucinent hors couverture."
  "Ecrit par une machine, relu par une machine, debogue par vous. Bon courage."
)
printf '  \033[2;3m« %s »\033[0m\n\n' "${_q[$RANDOM % ${#_q[@]}]}"
BANNER
chmod +x "$ROOTFS/usr/local/bin/osmo-banner"
# ── screenfetch: WITHOUT ITS EASTER EGG ─────────────────────────────────────
# screenfetch draws a random number AT EACH LINE and, for five values out of a
# thousand, SHUFFLES the order of logo and info lines
# ("case $(awk ... rand ...) in 411|188|15|166|609)"). Those five values are
# neutralised; the rest of the script is intact.
[ -f "$ROOTFS/usr/bin/screenfetch" ] && \
    sed -i 's/^\([[:space:]]*\)411|188|15|166|609)/\1--jamais--)/' "$ROOTFS/usr/bin/screenfetch"

# Installed in the .bashrc of BOTH accounts, and in /etc/skel for those the
# installer will create. APPENDED, never rewriting the file: Ubuntu's .bashrc
# carries the prompt, colours and aliases.
for _h in "$ROOTFS/root" "$ROOTFS/home/osmocom" "$ROOTFS/etc/skel"; do
    install -d "$_h"
    [ -f "$_h/.bashrc" ] || cp "$ROOTFS/etc/skel/.bashrc" "$_h/.bashrc" 2>/dev/null || : > "$_h/.bashrc"
    grep -q 'osmo-banner' "$_h/.bashrc" 2>/dev/null || cat >> "$_h/.bashrc" <<'BASHRC'

# ── osmo-operator banner ───────────────────────────────────────────────────────
# Interactive AND terminal AND not already played: see /usr/local/bin/osmo-banner.
# Removing these three lines is enough to get rid of it.
if [[ $- == *i* ]] && [ -t 1 ] && [ -z "${OSMO_BANNER:-}" ] && [ -x /usr/local/bin/osmo-banner ]; then
    export OSMO_BANNER=1
    /usr/local/bin/osmo-banner
fi
# The bench prompt: user yellow, host green, path blue - ROOT in red, host
# in yellow.
if [[ $- == *i* ]]; then
    if [ "$EUID" = 0 ]; then
        PS1='\[\e[1;31m\]\u\[\e[0m\]@\[\e[1;33m\]\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
    else
        PS1='\[\e[1;33m\]\u\[\e[0m\]@\[\e[1;32m\]\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
    fi
fi
BASHRC
done
chroot "$ROOTFS" chown -R osmocom:osmocom /home/osmocom 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} banniere de terminal : ${CYAN}screenfetch${NC} (logo pixel art du banc) + une phrase"

umount "$ROOTFS/var/cache/apt/archives" 2>/dev/null||true
umount "$ROOTFS"/{dev/pts,proc,sys,dev} 2>/dev/null||true

echo -e "  ${GREEN}✓${NC} config terminee"


# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. A module ending on a false test
# ("[ ... ] && { ...; }") would stop everything silently. Always 0 here.
true

#!/bin/bash
# osmo-gcc-alternatives.sh - gcc-9 / gcc-11 / gcc-13 dans update-alternatives (g++ en esclave).
#
# [2026-10-24] « update-alternatives --config gcc » repondait « pas d alternatives pour gcc »
# sur l ISO : seul update.sh les posait, en rattrapage, et l ISO n avait que gcc-13. Les
# branches experimentales d osmocom-bb (jolly/testing, burst_ind) ne compilent qu avec gcc-9
# (cf. Dockerfile, stage bb). Ce script est LA definition, appelee par iso_modules/80-chroot.sh
# (dans le chroot, apres apt), install_modules/80-bureau.sh et update.sh.
#
# Priorites : gcc-9 (90), gcc-11 (110), gcc-13 (130). Un choix deja fait
# (update-alternatives --config gcc) est garde ; a la creation, gcc-13 - le compilateur du
# noyau, pour DKMS. Seuls les compilateurs presents entrent : ni apt, ni reseau ici.
[ "$(id -u)" -eq 0 ] || { echo "osmo-gcc-alternatives : il faut root" >&2; exit 1; }
command -v update-alternatives >/dev/null 2>&1 || exit 0
neuf=0
update-alternatives --list gcc >/dev/null 2>&1 || neuf=1
for v in 9 11 13; do
    [ -x "/usr/bin/gcc-$v" ] && [ -x "/usr/bin/g++-$v" ] || continue
    update-alternatives --list gcc 2>/dev/null | grep -qx "/usr/bin/gcc-$v" && continue
    update-alternatives --install /usr/bin/gcc gcc "/usr/bin/gcc-$v" "$(( v * 10 ))" \
        --slave /usr/bin/g++ g++ "/usr/bin/g++-$v" >/dev/null 2>&1 \
        && echo "  [outils] alternative gcc-$v posee"
done
[ "$neuf" = 1 ] && [ -x /usr/bin/gcc-13 ] && update-alternatives --set gcc /usr/bin/gcc-13 >/dev/null 2>&1
exit 0

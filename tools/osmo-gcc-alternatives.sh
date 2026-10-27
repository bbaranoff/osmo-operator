#!/bin/bash
# osmo-gcc-alternatives.sh - gcc-9 / gcc-11 / gcc-13 in update-alternatives (g++ as slave).
#
# The experimental osmocom-bb branches (jolly/testing, burst_ind) only build with gcc-9
# (see Dockerfile, stage bb). This script is THE definition, called by
# iso_modules/80-chroot.sh (in the chroot, after apt), install_modules/80-bureau.sh and
# update.sh.
#
# Priorities: gcc-9 (90), gcc-11 (110), gcc-13 (130). A choice already made
# (update-alternatives --config gcc) is kept; on creation, gcc-13 - the kernel compiler,
# for DKMS. Only the compilers present are registered: no apt, no network here.
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

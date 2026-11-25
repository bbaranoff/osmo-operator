# iso_modules/80-chroot.d/35-gcc.sh - alternatives gcc 9 / 11 / 13.
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

# ── GCC alternatives ────────────────────────────────────────────────────────
# Same as the Docker image (gcc-9 90, gcc-11 110) plus gcc-13, the noble
# compiler, as DEFAULT (130): it built the kernel, and DKMS (NVIDIA driver via
# ubuntu-drivers, osmo-drivers) builds modules with "gcc".
#   update-alternatives --config gcc      choose (g++ follows as a slave)
#   update-alternatives --set gcc /usr/bin/gcc-9
for _v in 9 11 13; do
    [ -x "/usr/bin/gcc-$_v" ] && [ -x "/usr/bin/g++-$_v" ] || continue
    update-alternatives --install /usr/bin/gcc gcc "/usr/bin/gcc-$_v" "$(( _v * 10 ))" \
        --slave /usr/bin/g++ g++ "/usr/bin/g++-$_v"
done
unset _v
[ -x /usr/bin/gcc-13 ] && update-alternatives --set gcc /usr/bin/gcc-13
echo "  [chroot] alternatives gcc : $(update-alternatives --list gcc 2>/dev/null | xargs) (defaut $(readlink -f /usr/bin/gcc))"

true

# iso_modules/80-chroot.d/90-finitions.sh - certificats, dumpcap, initramfs, menage apt.
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).


# ── CA certificates: final check ────────────────────────────────────────────
# The store was regenerated at the start of this chroot; just check it is
# not empty.
if [ -s /etc/ssl/certs/ca-certificates.crt ]; then
    echo "  certificats : $(grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/ca-certificates.crt) autorites dans /etc/ssl/certs"
else
    echo "  WARN: /etc/ssl/certs/ca-certificates.crt vide - le TLS echouera dans l image"
fi

if command -v dumpcap >/dev/null 2>&1; then
    composant dumpcap-caps setcap cap_net_raw,cap_net_admin+eip "$(command -v dumpcap)"
fi

KERNEL=$(ls /boot/vmlinuz-* | sort -V | tail -1 | sed "s|/boot/vmlinuz-||")
update-initramfs -u -k "$KERNEL"

# Remove deb-src.list: its Sources indexes (~80 MB) were only needed for the
# gnuradio build-dep and would be loaded into RAM by the first apt-get update
# on a toram live. No "apt-get clean" when /var/cache/apt/archives is the
# bind-mounted host cache: only indexes and binary caches are removed.
if [ "${ISO_APT_CACHE_BOUND:-0}" = "1" ]; then
    rm -f /var/cache/apt/*.bin; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
else
    apt-get clean; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
fi
rm -f /etc/apt/sources.list.d/deb-src.list

true

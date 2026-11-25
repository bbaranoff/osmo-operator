# iso_modules/80-chroot.d/45-gnuradio.sh - build-dep gnuradio, ld.so.conf /usr/local/lib.
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

# build-dep gnuradio: all GNU Radio dependencies (boost, fftw, gmp, log4cpp,
# volk...) needed by the custom gnuradio/gr-gsm in /usr/local. The Sources
# indexes are already present (deb-src.list written before apt-get update).
# The hub has no gr-gsm: no deb-src, no build-dep.
if [ -s /etc/apt/sources.list.d/deb-src.list ]; then
    composant gnuradio-builddep net_retry apt-fast build-dep -y $APT_OPTS gnuradio
fi

echo "/usr/local/lib" > /etc/ld.so.conf.d/osmocom.conf
ldconfig

true

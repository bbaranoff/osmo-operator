# osmo-gnuarm-profile.sh - the osmocom-bb gnuarm toolchain in the PATH (sourced:
# /etc/profile.d/97-osmo-gnuarm.sh)
# arm-elf-gcc 4.5.2 (binutils, newlib) lives in /root/gnuarm/install/bin, installed by the
# --gnuarm supplement (tools/osmo-firmwares-install.sh, copy of the osmocom-bb-trx image).
# The supplement builds pass this PATH to make; here it applies to every login shell:
# « cd osmocom-bb/src && make firmware » finds arm-elf-gcc without exporting anything.
# GNUARM_DIR relocates the toolchain. Without the directory (supplement not installed),
# nothing changes.
_osmo_gnuarm_bin="${GNUARM_DIR:-/root/gnuarm}/install/bin"
if [ -d "$_osmo_gnuarm_bin" ]; then
    case ":$PATH:" in
        *":$_osmo_gnuarm_bin:"*) ;;
        *) PATH="$PATH:$_osmo_gnuarm_bin"; export PATH ;;
    esac
fi
unset _osmo_gnuarm_bin

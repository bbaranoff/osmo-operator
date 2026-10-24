# osmo-gnuarm-profile.sh - la chaine gnuarm d osmocom-bb dans le PATH (a sourcer : /etc/profile.d/97-osmo-gnuarm.sh)
# [2026-10-24] arm-elf-gcc 4.5.2 (binutils, newlib) vit dans /root/gnuarm/install/bin, pose par le
# supplement --gnuarm (tools/osmo-firmwares-install.sh, copie de l image osmocom-bb-trx). Les
# compilations du supplement passaient deja ce PATH a make ; ici il vaut pour tout shell de
# connexion : « cd osmocom-bb/src && make firmware » trouve arm-elf-gcc sans rien exporter.
# GNUARM_DIR deplace la chaine. Sans le repertoire (supplement non pose), rien ne change.
_osmo_gnuarm_bin="${GNUARM_DIR:-/root/gnuarm}/install/bin"
if [ -d "$_osmo_gnuarm_bin" ]; then
    case ":$PATH:" in
        *":$_osmo_gnuarm_bin:"*) ;;
        *) PATH="$PATH:$_osmo_gnuarm_bin"; export PATH ;;
    esac
fi
unset _osmo_gnuarm_bin

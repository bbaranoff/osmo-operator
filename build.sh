#!/bin/bash
set -euo pipefail

# 0. Parsing des arguments
NO_CACHE=""
LITE=0
for arg in "$@"; do
    case "$arg" in
        --no-cache)
            NO_CACHE="--no-cache"
            ;;
        --lite)
            LITE=1
            ;;
        -h|--help)
            echo "Usage: sudo $0 [--no-cache] [--lite]"
            echo "  --no-cache   Force la reconstruction complete de l'image (paquets propres)."
            echo "  --lite       Construit EN PLUS osmocom-nitb:lite : la meme pile, sans les"
            echo "               arbres de sources de /opt/GSM (~4 Go sur 11). Voir Dockerfile.lite."
            exit 0
            ;;
        *)
            echo -e "\033[0;33m[WARN] Argument inconnu ignore : $arg\033[0m"
            ;;
    esac
done

# 1. Verification des privileges ROOT
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[0;31m[ERREUR] Ce script doit etre lance en tant que root (sudo).\033[0m"
   exit 1
fi

echo "--- Preparation complete de l'hote (SDR & Docker) ---"

# 2. Installation de Docker (si non present)
if ! command -v docker &> /dev/null; then
    echo "[*] Docker n'est pas installe. Installation en cours..."
    apt-get update
    apt-get install -y docker.io docker-compose-v2
fi

# 3. Installation des dependances critiques sur l'hote
# SCTP est vital pour les protocoles de signalisation Osmocom
echo "[*] Installation de SCTP, TUN et D-Bus sur l'hote..."
apt-get update
apt-get install -y lksctp-tools libsctp-dev dbus uml-utilities libusb-1.0-0-dev \
     wireshark linphone* gnome-terminal whiptail expect netcat-openbsd \
     telnet iproute2 pulseaudio-utils

# 4. Chargement des modules noyau
echo "[*] Chargement des modules noyau (SCTP & TUN)..."
modprobe sctp
modprobe tun

# Verification du module SCTP (lecture directe de /proc/modules : pas de tube,
# donc pas de SIGPIPE/pipefail, et ancrage sur le nom de module exact)
if grep -q '^sctp ' /proc/modules; then
    echo -e "\033[0;32m[OK] Module SCTP charge sur l'hote.\033[0m"
else
    echo -e "\033[0;31m[ERREUR] Impossible de charger SCTP.\033[0m"
fi

# 5. Lancement du build Docker
echo "--- Lancement du build de l'image osmocom-nitb ---"
if [[ -n "$NO_CACHE" ]]; then
    echo "[*] Mode --no-cache actif : reconstruction complete, paquets propres."
fi
if docker build $NO_CACHE . -t osmocom-nitb; then
    echo -e "\033[0;32m[OK] Image osmocom-nitb construite avec succes.\033[0m"
else
    echo -e "\033[0;31m[ERREUR] Le build Docker a echoue.\033[0m"
    exit 1
fi

# 6. Image lite : la meme pile, sans les arbres de sources
# osmocom-nitb embarque /opt/GSM - les arbres de construction de gnuradio,
# gr-gsm, qemu, libosmocore... 4 Go sur 11, qui ont servi a COMPILER et ne
# servent plus a rien ensuite : ce qui tourne vit dans /usr/local.
# Dockerfile.lite les retire et aplatit le resultat (voir son entete : effacer
# dans une couche de plus ne rend aucun espace).
if [[ "$LITE" -eq 1 ]]; then
    echo "--- Lancement du build de l'image osmocom-nitb:lite ---"
    if docker build $NO_CACHE -f Dockerfile.lite --build-arg BASE=osmocom-nitb \
                   . -t osmocom-nitb:lite; then
        echo -e "\033[0;32m[OK] Image osmocom-nitb:lite construite.\033[0m"
        docker images --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}' \
            | grep -E '^\s+osmocom-nitb:(latest|lite)' || true
    else
        echo -e "\033[0;31m[ERREUR] Le build de l'image lite a echoue.\033[0m"
        exit 1
    fi
fi

#!/bin/bash
# init-crypthome.sh - initialises the second disk as LUKS2 and moves /home onto it.
#
#   sudo /root/init-crypthome.sh [/dev/partition] [--key-file=F] [--yes]
#
# NOT THE NORMAL PATH. On a machine installed from the ISO, /home is encrypted
# BY THE INSTALLER: installer/calamares/modules/partition.conf splits the disk
# into root + /home and encrypts only /home; crypthome-postinstall wires it up.
#
# This script covers the case Calamares does not: encrypting a SECOND DISK
# added to an already installed machine. It refuses any partition of the root
# disk.
#
# Without argument, the candidate partition is deduced - there must be exactly
# one, otherwise the script stops and lists them.
#
# THIS SCRIPT WIPES THE TARGET PARTITION. It refuses to run if the partition
# contains anything but lost+found, if it is mounted, or if it already carries
# a LUKS header - and it asks for a confirmation typed in full.
#
# What it does, in order: encrypts the partition, copies the current content
# of /home onto it, leaves the old /home in place (unlock-home moves it aside
# at next boot), writes /etc/crypttab and /etc/fstab with "noauto" (unlock-home
# mounts after asking), and enables unlock-home.service.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

CONF=/etc/default/crypthome
. "$CONF"
MAPPER="${CRYPTHOME_NAME:-crypthome}"
MOUNT="${CRYPTHOME_MOUNT:-/home}"
OWNER="${CRYPTHOME_OWNER:-}"
TMP=/mnt/crypthome-init

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}A lancer en root.${NC}" >&2; exit 1; }

# ── OPTIONS ─────────────────────────────────────────────────────────────────
#   --key-file=F  passphrase read from F instead of being asked. For scripted
#                 installations. The file must NOT outlive the script: the
#                 caller deletes it.
#   --yes, -y     no confirmation. For non-interactive calls only; the script
#                 WIPES the target partition.
KEYFILE=""
SANS_QUESTION=0
_args=()
for _a in "$@"; do
    case "$_a" in
        --key-file=*) KEYFILE="${_a#--key-file=}" ;;
        --yes|-y)     SANS_QUESTION=1 ;;
        -*)           echo -e "${RED}Option inconnue : $_a${NC}" >&2; exit 2 ;;
        *)            _args+=("$_a") ;;
    esac
done
set -- ${_args[@]+"${_args[@]}"}
if [ -n "$KEYFILE" ] && [ ! -r "$KEYFILE" ]; then
    echo -e "${RED}--key-file : $KEYFILE illisible.${NC}" >&2; exit 1
fi

# ── WHICH PARTITION ─────────────────────────────────────────────────────────
# Nothing is guessed silently: this script WIPES its target. Without argument
# it keeps only the partitions meeting ALL the conditions - not on the root
# disk, not mounted, no LUKS header, not iso9660/swap/EFI - and exactly one
# must remain for it to go on by itself.
disque_racine="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)"
candidates() {
    local p pk
    for p in $(lsblk -lnpo NAME,TYPE | awk '$2=="part"{print $1}'); do
        pk="$(lsblk -no PKNAME "$p" 2>/dev/null | head -1)"
        [ "$pk" = "$disque_racine" ] && continue
        findmnt -S "$p" >/dev/null 2>&1 && continue
        cryptsetup isLuks "$p" 2>/dev/null && continue
        case "$(blkid -o value -s TYPE "$p" 2>/dev/null)" in
            iso9660|swap|vfat) continue ;;
        esac
        echo "$p"
    done
}

if [ "$#" -ge 1 ]; then
    DEV="$1"
else
    mapfile -t _cand < <(candidates)
    if [ "${#_cand[@]}" -eq 1 ]; then
        DEV="${_cand[0]}"
        echo -e "${YELLOW}Partition candidate unique retenue : ${CYAN}$DEV${NC}"
    elif [ "${#_cand[@]}" -eq 0 ]; then
        echo -e "${RED}Aucune partition candidate.${NC}" >&2
        echo    "Il en faut une hors du disque de la racine (${disque_racine:-?})," >&2
        echo    "non montee et sans en-tete LUKS. Creez-la, puis relancez :" >&2
        echo    "  $0 /dev/<partition>" >&2
        exit 1
    else
        echo -e "${RED}Plusieurs partitions candidates - precisez laquelle :${NC}" >&2
        lsblk -po NAME,SIZE,FSTYPE,LABEL "${_cand[@]}" >&2
        echo    "  $0 /dev/<partition>" >&2
        exit 1
    fi
fi

# ── CHECKS ──────────────────────────────────────────────────────────────────
[ -b "$DEV" ] || { echo -e "${RED}$DEV n'est pas une partition.${NC}" >&2; exit 1; }

if findmnt -S "$DEV" >/dev/null 2>&1; then
    echo -e "${RED}$DEV est monte. Demontez-le d'abord.${NC}" >&2; exit 1
fi

if cryptsetup isLuks "$DEV" 2>/dev/null; then
    echo -e "${RED}$DEV porte deja un en-tete LUKS.${NC}" >&2
    echo    "Si c'est un essai precedent a refaire, effacez-le sciemment :" >&2
    echo    "  cryptsetup erase $DEV && wipefs -a $DEV" >&2
    exit 1
fi

# The partition must be empty. Checked for real by mounting it read-only: a
# blkid saying "ext4" does not tell whether it holds data.
if blkid "$DEV" >/dev/null 2>&1; then
    mkdir -p "$TMP"
    if mount -o ro "$DEV" "$TMP" 2>/dev/null; then
        reste="$(find "$TMP" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit)"
        df -h "$TMP" | tail -1
        umount "$TMP"
        if [ -n "$reste" ]; then
            echo -e "${RED}$DEV contient des donnees (par ex. $(basename "$reste")).${NC}" >&2
            echo    "Ce script ne formate que des partitions vides. Sauvegardez et videz-la." >&2
            exit 1
        fi
    fi
    rmdir "$TMP" 2>/dev/null || true
fi

taille="$(lsblk -dno SIZE "$DEV" | tr -d ' ')"
echo
echo -e "${BOLD}Initialisation du disque chiffre${NC}"
echo -e "  partition      : ${CYAN}$DEV${NC} ($taille)"
echo -e "  deviendra      : ${CYAN}$MOUNT${NC} (LUKS2 + ext4, mappe sur /dev/mapper/$MAPPER)"
echo -e "  compte a home  : ${CYAN}$OWNER${NC}"
echo -e "  au demarrage   : ${CYAN}\"decrypt $MOUNT -passphrase- or Enter\"${NC}, Entree a vide n'empeche pas de demarrer"
echo -e "  ${YELLOW}le contenu actuel de $MOUNT sera recopie dessus ; l original reste en place${NC}"
echo -e "  ${YELLOW}et part dans /var/backups/ au redemarrage, avant le montage${NC}"
echo
echo -e "${RED}${BOLD}TOUT CE QUE CONTIENT $DEV SERA DETRUIT.${NC}"
if [ "$SANS_QUESTION" = 1 ]; then
    echo -e "${YELLOW}--yes : confirmation passee.${NC}"
else
    read -r -p "Tapez OUI en majuscules pour continuer : " accord
    [ "$accord" = "OUI" ] || { echo "Abandon."; exit 1; }
fi

# ── THE OWNER ACCOUNT'S SESSION ─────────────────────────────────────────────
# Copying a home while its session runs gives a slightly inconsistent copy:
# dconf, browser history and cache files are rewritten continuously. Harmless
# HERE: the original is not deleted, it is moved aside intact at next boot,
# and what matters is the (static) keyring.
#
# THE SESSION IS NOT KILLED: this script is often run from a terminal that is
# PART of it; closing it between luksFormat and the copy would leave a half
# filled encrypted disk. The real switch happens at next boot, when nobody
# holds /home - unlock-home then moves the old content aside.
if [ -n "$OWNER" ] && loginctl list-sessions --no-legend 2>/dev/null | grep -qw "$OWNER"; then
    echo -e "${YELLOW}Session de $OWNER ouverte : la copie sera prise a chaud.${NC}"
    echo -e "${YELLOW}L original n est pas efface - il sera mis de cote au redemarrage.${NC}"
fi

# ── 1. ENCRYPTION ───────────────────────────────────────────────────────────
echo
echo -e "${GREEN}[1/7]${NC} Creation du conteneur LUKS2 sur $DEV."
echo -e "      ${BOLD}Choisissez une phrase de passe longue.${NC} Elle ne se recupere pas :"
echo -e "      perdue, le contenu du disque l'est aussi."
if [ -n "$KEYFILE" ]; then
    cryptsetup luksFormat --type luks2 --label crypthome --batch-mode \
               --key-file="$KEYFILE" "$DEV"
else
    cryptsetup luksFormat --type luks2 --label crypthome "$DEV"
fi

echo
if [ -n "$KEYFILE" ]; then
    echo -e "${GREEN}[2/7]${NC} Ouverture du volume."
else
    echo -e "${GREEN}[2/7]${NC} Ouverture du volume (retapez la phrase de passe)."
fi
if [ -n "$KEYFILE" ]; then
    cryptsetup open --key-file="$KEYFILE" "$DEV" "$MAPPER"
else
    cryptsetup open "$DEV" "$MAPPER"
fi

UUID="$(cryptsetup luksUUID "$DEV")"
echo -e "      UUID LUKS : ${CYAN}$UUID${NC}"

# ── 3. FILE SYSTEM ──────────────────────────────────────────────────────────
echo -e "${GREEN}[3/7]${NC} Formatage ext4."
mkfs.ext4 -q -L crypthome "/dev/mapper/$MAPPER"

# ── 4. COPY OF /home ────────────────────────────────────────────────────────
echo -e "${GREEN}[4/7]${NC} Recopie du contenu actuel de $MOUNT."
mkdir -p "$TMP"
mount "/dev/mapper/$MAPPER" "$TMP"
# -aHAX: hard links, ACLs and extended attributes included - a home without
# its ACLs and xattrs ends up with subtly wrong permissions.
# --sparse: without it, sparse files (VM and disk images) are copied holes
# included, zero by zero.
# -x: mount points are not crossed; what is mounted UNDER the home belongs to
# another disk.
# --info=progress2 only on a terminal: run by systemd, the progress bar would
# write tens of thousands of lines to the journal.
_rs=(-aHAX --sparse -x)
[ -t 1 ] && _rs+=(--info=progress2)
rsync "${_rs[@]}" "$MOUNT"/ "$TMP"/
# Root's keyring lives here and nowhere else: /root/.local/share/keyrings is
# a link to this directory.
install -d -m 0700 "$TMP/.crypthome/root-keyrings"
chown -R root:root "$TMP/.crypthome"
sync
umount "$TMP"
rmdir "$TMP"

# ── 5. WIRING ───────────────────────────────────────────────────────────────
echo -e "${GREEN}[5/7]${NC} Ecriture de la configuration."
sed -i "s|^CRYPTHOME_UUID=.*|CRYPTHOME_UUID=\"$UUID\"|" "$CONF"

# crypttab: "noauto" - systemd must ask NOTHING by itself at boot; unlock-home
# asks the question and opens the volume.
sed -i "/^$MAPPER[[:space:]]/d" /etc/crypttab
printf '%-22s %-40s %-10s %s\n' "$MAPPER" "UUID=$UUID" "none" "luks,noauto" >> /etc/crypttab

# fstab: "noauto" for the same reason, and "nofail" as a safety net - an entry
# failing at boot on a system without the disk must not drop the machine into
# rescue mode.
sed -i "\|^[^#].*[[:space:]]$MOUNT[[:space:]]|d" /etc/fstab
printf '%-42s %-14s %-7s %s %s %s\n' \
    "/dev/mapper/$MAPPER" "$MOUNT" "ext4" "defaults,noauto,nofail" "0" "2" >> /etc/fstab

# ── 6. THE OLD /home ────────────────────────────────────────────────────────
# Left untouched on purpose: processes hold it right now (usually the session
# this script runs from). unlock-home moves it to /var/backups at next boot,
# BEFORE mounting the encrypted disk - the only moment nobody uses it.
echo -e "${GREEN}[6/7]${NC} Ancien $MOUNT laisse en place ; il sera mis de cote au redemarrage."

# ── 7. ENABLING ─────────────────────────────────────────────────────────────
echo -e "${GREEN}[7/7]${NC} Activation du service de demarrage."
systemctl daemon-reload
systemctl enable unlock-home.service >/dev/null
/usr/local/sbin/refresh-owner-apps >/dev/null
# "splash" stays on the kernel command line: unlock-home quits plymouth itself
# just before asking the question on the console.

cryptsetup close "$MAPPER"

echo
echo -e "${GREEN}${BOLD}Termine.${NC}"
echo -e "  Au prochain demarrage : ${CYAN}\"decrypt $MOUNT -passphrase- or Enter\"${NC}"
echo -e "  Taper la phrase (affichee en ${CYAN}****${NC}) monte $MOUNT et ouvre la session de $OWNER,"
echo -e "  avec son trousseau ; Firefox et les applications a secrets tourneront sous lui."
echo -e "  ${CYAN}Entree${NC} a vide (ou attendre ${CRYPTHOME_TIMEOUT:-60} s) demarre sans : la session root"
echo -e "  s'ouvre normalement, les memes applications tournent sans secrets."
echo
echo -e "  Apres coup, dans un terminal : ${CYAN}unlock-home${NC} / ${CYAN}lock-home${NC}"
echo -e "  Au redemarrage, l ancien $MOUNT part dans ${CYAN}/var/backups/home-avant-chiffrement-*${NC}"
echo -e "  - a effacer une fois le dechiffrement verifie."
echo
echo -e "  ${YELLOW}Verifiez le dechiffrement AVANT d'effacer la sauvegarde.${NC}"
exit 0

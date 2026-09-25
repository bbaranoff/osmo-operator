#!/bin/bash
# init-crypthome.sh - initialise le second disque en LUKS2 et y deplace /home.
#
#   sudo /root/init-crypthome.sh [/dev/partition]
#
# CE N EST PLUS LE CHEMIN NORMAL. [2026-09-25] Sur une machine installee depuis
# l ISO, /home est chiffre PAR L INSTALLEUR : partition.conf decoupe le disque
# en racine + /home et ne chiffre que /home, crypthome-postinstall raccorde le
# tout. Rien a lancer apres coup, et pas de basculement etale sur deux
# demarrages.
#
# Ce script sert au cas que Calamares ne couvre pas : chiffrer un SECOND DISQUE
# ajoute a une machine deja installee. Il refuse d ailleurs toute partition du
# disque de la racine.
#
# Sans argument, la partition candidate est deduite - et il doit n'y en avoir
# qu'une, sinon le script s'arrete et les affiche.
#
# CE SCRIPT EFFACE LA PARTITION VISEE. Il refuse de tourner si elle contient
# autre chose que lost+found, si elle est montee, ou si elle porte deja un
# en-tete LUKS - et il demande une confirmation tapee en toutes lettres.
#
# Ce qu'il fait, dans l'ordre : chiffre la partition, y recopie le contenu
# actuel de /home, met l'ancien /home de cote, cable /etc/crypttab et
# /etc/fstab en "noauto" (c'est unlock-home qui monte, apres avoir demande),
# et active unlock-home.service.
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
#   --key-file=F  phrase de passe lue dans F au lieu d etre demandee. Pour les
#                 installations scriptees. Le fichier ne doit PAS survivre au
#                 script : c est a l appelant de l effacer.
#   --yes         pas de confirmation. A reserver a un appel non interactif ;
#                 le script EFFACE la partition qu il vise.
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

# ── QUELLE PARTITION ────────────────────────────────────────────────────────
# Rien n'est devine en silence : ce script EFFACE ce qu'il vise. Sans argument
# il ne retient que les partitions qui remplissent TOUTES les conditions - pas
# sur le disque de la racine, non montee, sans en-tete LUKS, ni iso9660 ni swap
# ni EFI - et il faut qu'il n'en reste qu'une pour qu'il aille plus loin seul.
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

# ── VERIFICATIONS ───────────────────────────────────────────────────────────
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

# Le disque doit etre vide. On regarde VRAIMENT, en montant en lecture seule :
# un blkid qui dit "ext4" ne dit pas s'il y a 900 Go de donnees dedans.
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
echo -e "  au demarrage   : question ${CYAN}\"Dechiffrer $MOUNT ? [o/N]\"${NC}, \"non\" n'empeche pas de demarrer"
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

# ── LA SESSION DU COMPTE PROPRIETAIRE DOIT ETRE FERMEE ──────────────────────
# Recopier un home pendant que sa session tourne donne une copie incoherente :
# le trousseau, dconf et les profils de navigateur sont reecrits en continu.
# ── LA SESSION DU COMPTE PROPRIETAIRE ───────────────────────────────────────
# Recopier un home pendant que sa session tourne donne une copie un peu
# flottante : dconf, l historique du navigateur et les fichiers de cache sont
# reecrits en continu. Ce n est pas grave ICI - l original n est pas efface, il
# est mis de cote intact au demarrage suivant, et c est le trousseau (statique)
# qui compte.
#
# ON NE TUE PAS LA SESSION. Ce script est souvent lance depuis un terminal qui
# EN FAIT PARTIE : la fermer, c est se couper le tapis sous les pieds, entre
# luksFormat et la recopie, et laisser un disque chiffre a moitie rempli. Le
# vrai basculement se fait au demarrage suivant, quand personne ne tient /home
# - c est unlock-home qui evacue alors l ancien contenu.
if [ -n "$OWNER" ] && loginctl list-sessions --no-legend 2>/dev/null | grep -qw "$OWNER"; then
    echo -e "${YELLOW}Session de $OWNER ouverte : la copie sera prise a chaud.${NC}"
    echo -e "${YELLOW}L original n est pas efface - il sera mis de cote au redemarrage.${NC}"
fi

# ── 1. CHIFFREMENT ──────────────────────────────────────────────────────────
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

# ── 3. SYSTEME DE FICHIERS ──────────────────────────────────────────────────
echo -e "${GREEN}[3/7]${NC} Formatage ext4."
mkfs.ext4 -q -L crypthome "/dev/mapper/$MAPPER"

# ── 4. RECOPIE DE /home ─────────────────────────────────────────────────────
echo -e "${GREEN}[4/7]${NC} Recopie du contenu actuel de $MOUNT."
mkdir -p "$TMP"
mount "/dev/mapper/$MAPPER" "$TMP"
# -aHAX : liens durs, ACL et attributs etendus compris - un home sans ses ACL
# ni ses xattrs revient a des permissions subtilement fausses, qu'on ne
# decouvre qu'a l'usage.
#
# --sparse : SANS LUI, les fichiers creux sont recopies TROUS COMPRIS, zero par
# zero. Mesure le 2026-09-15 sur un home de 6,6 Go : 19 Go a l'arrivee, les
# 12 Go d'ecart venant d'une seule image QEMU de pmbootstrap (16 Go annonces,
# 3,9 Go reellement alloues). Les machines virtuelles et les images disque sont
# la regle dans un home d'operateur, pas l'exception.
#
# -x : on ne franchit pas les points de montage. Ce qui est monte SOUS le home
# appartient a un autre disque ; le recopier ici le dupliquerait, et pas au bon
# endroit.
#
# --info=progress2 seulement sur un terminal : lance par systemd, sa barre de
# progression ecrit des dizaines de milliers de lignes dans le journal.
_rs=(-aHAX --sparse -x)
[ -t 1 ] && _rs+=(--info=progress2)
rsync "${_rs[@]}" "$MOUNT"/ "$TMP"/
# Le trousseau de root vit ici, et nulle part ailleurs : /root/.local/share/
# keyrings est un lien vers ce repertoire.
install -d -m 0700 "$TMP/.crypthome/root-keyrings"
chown -R root:root "$TMP/.crypthome"
sync
umount "$TMP"
rmdir "$TMP"

# ── 5. CABLAGE ──────────────────────────────────────────────────────────────
echo -e "${GREEN}[5/7]${NC} Ecriture de la configuration."
sed -i "s|^CRYPTHOME_UUID=.*|CRYPTHOME_UUID=\"$UUID\"|" "$CONF"

# crypttab : "noauto" - systemd ne doit RIEN demander de lui-meme au boot,
# c'est unlock-home qui pose la question et ouvre le volume.
sed -i "/^$MAPPER[[:space:]]/d" /etc/crypttab
printf '%-22s %-40s %-10s %s\n' "$MAPPER" "UUID=$UUID" "none" "luks,noauto" >> /etc/crypttab

# fstab : "noauto" pour la meme raison, et "nofail" en ceinture - une entree
# qui echoue au boot sur un systeme sans le disque ne doit pas basculer la
# machine en mode secours.
sed -i "\|^[^#].*[[:space:]]$MOUNT[[:space:]]|d" /etc/fstab
printf '%-42s %-14s %-7s %s %s %s\n' \
    "/dev/mapper/$MAPPER" "$MOUNT" "ext4" "defaults,noauto,nofail" "0" "2" >> /etc/fstab

# ── 6. L'ANCIEN /home ────────────────────────────────────────────────────
# On n y touche pas, et ce n est pas un oubli : des processus le tiennent en ce
# moment meme (la session depuis laquelle ce script tourne, le plus souvent).
# C est unlock-home qui l evacuera vers /var/backups au demarrage suivant,
# AVANT de monter le disque chiffre - le seul instant ou personne ne l occupe.
echo -e "${GREEN}[6/7]${NC} Ancien $MOUNT laisse en place ; il sera mis de cote au redemarrage."

# ── 7. ACTIVATION ───────────────────────────────────────────────────────────
echo -e "${GREEN}[7/7]${NC} Activation du service de demarrage."
systemctl daemon-reload
systemctl enable unlock-home.service >/dev/null
/usr/local/sbin/refresh-owner-apps >/dev/null
# "splash" cache la question du demarrage : plymouth prend l'ecran et une
# question en clair y est illisible. On garde "quiet", le boot reste sobre.
sed -i -E "s/(GRUB_CMDLINE_LINUX_DEFAULT=['\"][^'\"]*)[[:space:]]*splash/\\1/" /etc/default/grub
update-grub >/dev/null 2>&1 || true

cryptsetup close "$MAPPER"

echo
echo -e "${GREEN}${BOLD}Termine.${NC}"
echo -e "  Au prochain demarrage : ${CYAN}\"Dechiffrer $MOUNT ? [o/N]\"${NC}"
echo -e "  Repondre ${CYAN}o${NC} puis la phrase de passe monte $MOUNT et donne a $OWNER son"
echo -e "  trousseau ; Firefox et les applications a secrets tourneront sous lui."
echo -e "  Repondre ${CYAN}n${NC} (ou attendre ${CRYPTHOME_TIMEOUT:-60} s) demarre sans : la session root"
echo -e "  s'ouvre normalement, les memes applications tournent sans secrets."
echo
echo -e "  Apres coup, dans un terminal : ${CYAN}unlock-home${NC} / ${CYAN}lock-home${NC}"
echo -e "  Au redemarrage, l ancien $MOUNT part dans ${CYAN}/var/backups/home-avant-chiffrement-*${NC}"
echo -e "  - a effacer une fois le dechiffrement verifie."
echo
echo -e "  ${YELLOW}Verifiez le dechiffrement AVANT d'effacer la sauvegarde.${NC}"
exit 0

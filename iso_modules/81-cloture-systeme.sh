#!/bin/bash
# iso_modules/81-cloture-systeme.sh - etape 8b : cloture ldd depuis l image, reseau, osmo-update
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Etape 8b : Reequilibrage sur build.sh - cloture de dependances ldd ────────
# L'image osmocom-run (produite par build.sh + Dockerfile) est l'environnement
# qui MARCHE. Au lieu de se fier aux versions apt du rootfs (skew -> crash
# logging libosmocore), on copie depuis le conteneur la cloture .so EXACTE de
# tous les binaires osmo + calypso-ipc-device, en ecrasant les libs apt. On
# exclut la famille glibc/loader (identique en jammy, ne pas clobber ld.so).
echo -e "${GREEN}[8b/9] Cloture de dependances COMPLETE depuis ${CYAN}${ISO_RUN_IMAGE}${NC}${GREEN} (toute l'install)...${NC}"
# On ldd TOUS les ELF (executables + toutes les .so) de l'install custom :
# /usr/local/bin (osmo), /opt/GSM (qemu, ipc-device, gr-gsm), /root/.env (venv
# python : bindings gnuradio/gr-gsm + leurs deps boost/log4cpp/volk/fftw...).
# => toutes les deps natives finissent dans l'ISO, plus de "import gsm" qui rate.
docker run --rm --entrypoint bash \
    -e OSMO_LDD_ROOTS="$([ "$ISO_ROLE" = "interstp" ] && echo "/usr/local/bin /usr/local/lib" || echo "/usr/local/bin /opt/GSM /root/.env")" \
    "$ISO_RUN_IMAGE" -c '
    set -e
    find ${OSMO_LDD_ROOTS:-/usr/local/bin /opt/GSM /root/.env} -type f \( -executable -o -name "*.so*" \) 2>/dev/null \
      | while read -r b; do ldd "$b" 2>/dev/null; done \
      | grep -oE "/[^ ]+\.so[^ ]*" | sort -u \
      | grep -vE "/(ld-linux[^/]*|ld|libc|libm|libpthread|libdl|librt|libresolv)\.so" \
      | while read -r f; do realpath "$f" 2>/dev/null; done | sort -u \
      | tar -czf - -T - 2>/dev/null
' > "$WORK/closure.tar.gz" || true
if [ -s "$WORK/closure.tar.gz" ]; then
    tar -xzf "$WORK/closure.tar.gz" -C "$ROOTFS" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} $(tar -tzf "$WORK/closure.tar.gz" 2>/dev/null | wc -l) libs injectees (Docker)"
else
    echo -e "  ${YELLOW}cloture vide - on garde les libs apt${NC}"
fi

# Priorite /usr/local/lib (libosmo* custom) + purge de tout doublon systeme.
# NB: pas de `| grep` ici - sous set -euo pipefail un grep sans correspondance
# (cas normal: aucun doublon) renverrait 1 et tuerait le script avant l'ISO.
echo "/usr/local/lib" > "$ROOTFS/etc/ld.so.conf.d/00-osmocom-local.conf"
find "$ROOTFS/usr/lib" "$ROOTFS/lib" -maxdepth 4 -name 'libosmo*.so*' -delete 2>/dev/null || true
chroot "$ROOTFS" ldconfig 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} /usr/local/lib prioritaire + ldconfig"

# ── Configuration systeme ──────────────────────────────────────────────────
echo "osmo-egprs" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost osmo-egprs
::1       localhost
EOF

mkdir -p "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/20-dhcp.network" <<'EOF'
[Match]
Name=en* eth*
[Network]
DHCP=yes
# ── Adresses heritees du plan docker, en /32 ────────────────────────────────
# Elles servent aux configs de l'image qui nomment encore 172.20.x (passerelle
# du backbone, cible gsmtap...) : sans elles, un demon qui s'y lie ne demarre
# pas. On les garde donc - mais sans revendiquer de reseau.
#
# POURQUOI /32 ET PLUS /24
# Un /24 fait croire a la machine que TOUT 172.20.0.0/24 est sur son lien. Elle
# l'ARP alors sur le LAN au lieu de le router. Sur un banc mixte VM + docker,
# les conteneurs de l'hote deviennent injoignables : "ip route add
# 172.20.0.0/24 via <hote>" est refuse d'un "File exists", et le trafic part
# dans le vide. Le /32 garde l'adresse locale sans fermer la porte au routage.
#
# 172.20.0.11 est RETIREE : c'est l'adresse du PREMIER CONTENEUR operateur. Une
# VM qui la porte se repond a elle-meme et ne joint jamais le conteneur - la
# panne la plus deroutante du lot, puisque tout repond en local.
#
# La route /16 disparait pour la meme raison : elle couvrait le plan docker
# entier et primait sur toute route plus fine vers l'hote.
#
# [2026-08-29] LES ADRESSES PRIVEES NE SONT PLUS ICI.
# Elles y etaient sous [Match] Name=en* eth*, donc posees sur TOUTE carte qui
# repond au motif - et le motif ne dit rien de celle qui porte reellement le
# reseau. Sur une VM a plusieurs interfaces, l'adresse se retrouvait sur le NAT
# pendant que le pont, lui, ne l'avait pas : un pair visait 192.168.2.10 sans
# trouver personne, alors que "ip addr" la montrait bien presente - ailleurs.
# systemd-networkd ne sait pas exprimer « la carte qui a la route par defaut » :
# c'est une propriete d'execution. C'est osmo-ip-plan.service qui les pose
# maintenant, avec repli sur la boucle locale quand aucune carte ne mene nulle
# part (voir network/osmo-ip-plan.sh).
EOF
# docker RETIRE de la liste : son service n'existe plus (ISO natif) et 'systemctl
# enable' valide tous les units d'abord → un seul manquant faisait AVORTER l'enable
# de systemd-networkd/resolved → enp3s0 sans IP au boot. On active chaque unit
# separement pour qu'un eventuel echec n'empeche pas les autres.
chroot "$ROOTFS" systemctl enable systemd-networkd 2>/dev/null||true
chroot "$ROOTFS" systemctl enable systemd-resolved 2>/dev/null||true

# ── DNS : NE PAS EMBARQUER LE resolv.conf DE L HOTE DE CONSTRUCTION ─────────
# [2026-09-04] 80-chroot.sh copie /etc/resolv.conf de l hote dans le rootfs pour
# que l apt du chroot ait un DNS. Sur un hote Ubuntu, ce fichier est le STUB de
# systemd-resolved : « nameserver 127.0.0.53 », une adresse qui n a de sens que
# si systemd-resolved tourne. Il partait tel quel dans l image, en fichier
# ordinaire - et la machine demarree n avait pas systemd-resolved (paquet a part
# sur noble, ajoute depuis dans PKGS). Resultat : personne derriere 127.0.0.53,
# et TOUTE resolution echouait par « Temporary failure in name resolution »,
# sur une machine dont l IP marchait parfaitement (route par defaut, ping vers
# une IP nue, tout allait). Le fond d ecran ne trouvait plus son strip, apt ne
# trouvait plus ses depots, et l on cherchait une panne de reseau qui n existait
# pas.
#
# On remet donc le lien standard d Ubuntu vers le stub. Il pointe vers un
# fichier de /run que systemd-resolved ecrit a chaque demarrage ; le paquet
# etant maintenant installe ET active (ci-dessus), quelqu un ecoute bien
# derriere. Sans le lien, le fichier fige de l hote resterait prioritaire.
ln -sfn ../run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
# Filet : si systemd-resolved ne demarrait pas, /run/.../stub-resolv.conf serait
# absent et le lien pendouillerait - donc AUCUN DNS. On laisse une copie de
# secours que NetworkManager ou un operateur peut remettre en place.
printf '# Repli hors systemd-resolved : cp %s /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
' \
    /etc/resolv.conf.secours > "$ROOTFS/etc/resolv.conf.secours"
echo -e "  ${GREEN}✓${NC} DNS : /etc/resolv.conf -> stub systemd-resolved (repli /etc/resolv.conf.secours)"

# ── Les adresses privees du noeud, posees a l'EXECUTION ─────────────────────
# Voir network/osmo-ip-plan.sh : il choisit la carte qui fournit reellement
# Internet, y pose 192.168.<noeud+1>.1 et .10, et retombe sur 127.0.0.66 sur lo
# quand aucune carte ne mene nulle part - de sorte que les configurations qui
# nomment une adresse privee trouvent TOUJOURS quelque chose de local, au lieu
# d'echouer au bind sur une adresse absente.
install -Dm755 "$DIR/network/osmo-ip-plan.sh" "$ROOTFS/usr/local/sbin/osmo-ip-plan.sh"
cat > "$ROOTFS/etc/systemd/system/osmo-ip-plan.service" <<'IPPLAN'
[Unit]
Description=Adresses privees du noeud sur la carte qui fournit Internet
# APRES networkd-wait-online : avant, aucune route par defaut n'existe encore et
# le script conclurait "aucune carte" a chaque demarrage - le repli loopback
# serait la regle au lieu de l'exception.
After=network-online.target systemd-networkd.service
Wants=network-online.target
Before=osmo-egprs-web.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/osmo-ip-plan.sh --apply

[Install]
WantedBy=multi-user.target
IPPLAN
# Rejoue a chaque changement de lien : un cable rebranche, un Wi-Fi qui prend le
# relais, et la carte qui fournit Internet n'est plus la meme. Sans ca, les
# adresses restaient sur l'ancienne - presentes, et injoignables.
mkdir -p "$ROOTFS/etc/networkd-dispatcher/routable.d"
cat > "$ROOTFS/etc/networkd-dispatcher/routable.d/50-osmo-ip-plan" <<'IPHOOK'
#!/bin/sh
exec /usr/local/sbin/osmo-ip-plan.sh --apply
IPHOOK
chmod +x "$ROOTFS/etc/networkd-dispatcher/routable.d/50-osmo-ip-plan"
chroot "$ROOTFS" systemctl enable osmo-ip-plan 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} osmo-ip-plan : ${CYAN}192.168.$(( ${ISO_NODE:-1} + 1 )).1/.10${NC} sur la carte Internet, repli ${CYAN}127.0.0.66${NC}"

# live-boot ecrit /root/etc/network/interfaces dans la racine montee au boot.
# Sans ifupdown, /etc/network/ n'existe pas -> "/init: can't create
# /root/etc/network/interfaces: nonexistent directory". On cree le dossier + un
# interfaces minimal (loopback). systemd-networkd gere le reseau ; ce fichier
# n'est lu par personne (ifupdown absent), il satisfait juste le hook live-boot.
mkdir -p "$ROOTFS/etc/network"
cat > "$ROOTFS/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
EOF

# ── Animation SMS a l'ouverture de session ─────────────────────────────────
# [2026-08-27] Ce qui vivait ici : osmo-update.service, qui a CHAQUE demarrage
# telechargeait update.sh depuis GitHub et l'executait - lequel effacait puis
# reclonait osmo-operator et osmo-egprs-web, resynchronisait qosmo-grgsm et installait
# socat a coups d'apt. Le contenu de la machine etait donc decide au boot par le
# reseau, et sans reseau il ne restait rien des arbres effaces.
#
# Tout cela se fait ICI, une fois, a la construction : les trois depots partent
# dans l'image AVEC leur .git (etapes [5a/9] et [5b/9]), qosmo-grgsm avec son
# build/ compile, les paquets sont installes dans le rootfs (etape 5), et le
# service du dashboard est pose plus bas. Du update.sh il ne reste que ce qui
# exige un terminal et quelqu'un devant : l'animation SMS.
#
# Elle est jouee par le PROFIL, pas par un service : un oneshot systemd tourne
# avant qu'un terminal existe, et sa sortie part dans un log que personne ne lit.
# /etc/profile.d est source dans l'ordre alphabetique - 01-osmo-disclaimer.sh
# d'abord, 99-osmo-sms.sh ensuite : l'utilisateur lit ce qu'il peut lancer, puis
# le SMS arrive. Et le fichier est ECRIT DANS L'IMAGE, donc present quand le
# shell developpe son "for i in /etc/profile.d/*.sh" : c'est precisement ce qui
# manquait a l'ancienne version, posee trop tard par un service, et qui
# l'obligeait a armer un declencheur separe sur /dev/tty1.
install -Dm755 "$DIR/update.sh" "$ROOTFS/usr/local/sbin/osmo-sms.sh"
cat > "$ROOTFS/etc/profile.d/99-osmo-sms.sh" <<'EOF'
# 99-osmo-sms.sh - pose par build-iso.sh. Joue l'arrivee d'un SMS, une fois par
# demarrage. Source APRES 01-keyboard-setup.sh (ordre alphabetique).
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac      # session interactive seulement
[ -x /usr/local/sbin/osmo-sms.sh ] || return 0
# /run est un tmpfs que le noyau recree vide a chaque demarrage : l'animation se
# rejoue a chaque boot, mais pas a chaque tty ni a chaque "su -".
[ -e /run/osmo-sms.done ] && return 0
: > /run/osmo-sms.done
/usr/local/sbin/osmo-sms.sh
EOF
chmod +x "$ROOTFS/etc/profile.d/99-osmo-sms.sh"
echo -e "  ${GREEN}✓${NC} animation SMS a l'ouverture de session (99-osmo-sms.sh)"

# ── /usr/local/bin/osmo-update : la mise a jour, EN PLACE, par git ─────────
# [2026-08-27] L'ancien mecanisme n'etait pas une mise a jour, c'etait un
# remplacement : effacer /opt/GSM/osmo-operator et /opt/GSM/osmo-egprs-web, recloner
# depuis GitHub, a chaque demarrage. Il fallait un reseau pour demarrer, ce qui
# tournait n'etait jamais ce que l'ISO portait, et tout ce qui avait ete pose
# dans un arbre disparaissait au boot suivant.
#
# Les trois depots partent maintenant dans l'image AVEC leur .git : il y a donc
# un HEAD auquel se comparer, et la mise a jour redevient ce qu'elle doit etre -
# un fetch et une avance rapide. Rien n'est efface, rien n'est reclone, et une
# machine sans reseau garde exactement ce avec quoi elle a ete gravee.
cat > "$ROOTFS/usr/local/bin/osmo-update" <<'OSMOUPD'
#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# osmo-update - met a jour, en place, les depots embarques dans l'image.
#
#   osmo-update              les trois depots
#   osmo-update qosmo-grgsm  un seul (osmo-operator | osmo-egprs-web | qosmo-grgsm | qosmo-dsp)
#   osmo-update --check      dit ce qui est en retard, n'ecrit rien
#   osmo-update --quiet      sans couleurs ni fioritures (journal, cron)
#   osmo-update --boot       mode demarrage : --quiet, journalise, sort toujours 0
#
# Ce qu'il ne fait PAS, deliberement : effacer un arbre, recloner un depot,
# installer un paquet. Une machine qui demarre n'a rien a aller chercher.
# ══════════════════════════════════════════════════════════════════════════════
set -u

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
CHECK=0; QUIET=0; BOOT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check)   CHECK=1 ;;
        --quiet)   QUIET=1 ;;
        --boot)    BOOT=1; QUIET=1 ;;
        -h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "option inconnue : $1" >&2; exit 2 ;;
        *)         break ;;
    esac
    shift
done
[ "$QUIET" = "1" ] && { G=''; Y=''; R=''; C=''; B=''; N=''; }

# Au demarrage personne ne lit l'ecran : la sortie part dans le journal, et le
# code de retour ne doit jamais retarder ni bloquer multi-user.target.
if [ "$BOOT" = "1" ]; then
    exec >>/var/log/osmo-update.log 2>&1
    echo "===== osmo-update (boot) $(date '+%F %T') ====="
fi

[ "$(id -u)" -eq 0 ] || { echo "Root requis." >&2; exit 1; }

# nom|chemin - les chemins que cherchent deja start-direct.sh, le dashboard et
# environnement/paths.env. En changer un ici ne deplacerait pas ceux qui les lisent.
REPOS="osmo-operator|/opt/GSM/osmo-operator
osmo-egprs-web|/opt/GSM/osmo-egprs-web
qosmo-grgsm|/opt/GSM/qosmo-grgsm
qosmo-dsp|/opt/GSM/qosmo-dsp"

WANT="${1:-}"
rc=0; web_moved=0; forks_moved=""

while IFS='|' read -r name dir; do
    [ -n "$name" ] || continue
    [ -z "$WANT" ] || [ "$WANT" = "$name" ] || continue
    found=1
    printf "  ${B}%-16s${N} ${C}%s${N}\n" "$name" "$dir"

    if [ ! -d "$dir" ]; then
        printf "    ${R}✗${N} absent - l'image ne le portait pas\n"; rc=1; continue
    fi
    if [ ! -d "$dir/.git" ]; then
        # On ne reclone pas par-dessus : ce serait effacer un arbre dont on ne
        # sait pas ce qu'il contient. On le dit, et on passe.
        printf "    ${Y}⚠${N} pas de depot (.git absent) - laisse tel quel\n"; rc=1; continue
    fi

    br="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)" || br=""
    [ -n "$br" ] || br=main

    # Un depot livre en --depth 1 est GREFFE : son unique commit n'a pas de
    # parent, donc rien de ce que le serveur renvoie n'a d'ancetre commun avec
    # lui. Le refetcher en --depth 1 garde cette propriete (et le depot reste
    # leger) ; un depot complet, lui, se fetch complet - sinon on lui ferait
    # perdre l'ancestralite qui permet justement l'avance rapide.
    if git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
        fetch_ok=$(git -C "$dir" fetch --depth 1 --quiet origin "$br" 2>/dev/null && echo 1)
    else
        fetch_ok=$(git -C "$dir" fetch --quiet origin "$br" 2>/dev/null && echo 1)
    fi
    if [ -z "${fetch_ok:-}" ]; then
        printf "    ${Y}⚠${N} fetch impossible (reseau ?) - copie locale conservee\n"; rc=1; continue
    fi

    local_h="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    remote_h="$(git -C "$dir" rev-parse FETCH_HEAD 2>/dev/null)"
    if [ "$local_h" = "$remote_h" ]; then
        printf "    ${G}✓${N} deja a jour - %s\n" "$(git -C "$dir" log -1 --format='%h %s')"
        continue
    fi
    if [ "$CHECK" = "1" ]; then
        printf "    ${Y}→${N} en retard : %s -> %s\n" "${local_h:0:7}" "${remote_h:0:7}"
        continue
    fi

    # Trois cas, et un seul refus. Le refus porte sur le TRAVAIL LOCAL, jamais
    # sur l'historique : c'est la difference avec l'ancien "rm -rf puis clone",
    # qui effacait sans distinguer.
    if git -C "$dir" merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null \
       && git -C "$dir" merge --ff-only FETCH_HEAD >/dev/null 2>&1; then
        # 1. Avance rapide : on est en retard sur la meme branche.
        printf "    ${G}✓${N} %s\n" "$(git -C "$dir" log -1 --format='%h %s')"
        [ "$name" = "osmo-egprs-web" ] && web_moved=1
        case "$name" in qosmo-*) forks_moved="$forks_moved $name" ;; esac
    elif [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
        # 2. Pas d'ancetre commun (depot greffe par --depth 1) mais arbre propre :
        #    il n'y a rien a perdre, on aligne sur le serveur.
        if git -C "$dir" reset --hard FETCH_HEAD >/dev/null 2>&1; then
            printf "    ${G}✓${N} aligne sur origin/%s - %s\n" "$br" "$(git -C "$dir" log -1 --format='%h %s')"
            [ "$name" = "osmo-egprs-web" ] && web_moved=1
            case "$name" in qosmo-*) forks_moved="$forks_moved $name" ;; esac
        else
            printf "    ${Y}⚠${N} alignement impossible - arbre inchange\n"; rc=1
        fi
    else
        # 3. Des fichiers ont ete modifies ici : on ne touche a rien, on le dit.
        printf "    ${Y}⚠${N} modifications locales - rien n'a ete ecrase\n"
        printf "       a la main : ${C}git -C %s status${N}\n" "$dir"
        rc=1
    fi
done <<REPOEOF
$REPOS
REPOEOF

if [ -z "${found:-}" ]; then
    echo "depot inconnu : $WANT  (osmo-operator | osmo-egprs-web | qosmo-grgsm | qosmo-dsp)" >&2
    exit 2
fi

# Un fork qui avance peut changer tools/qosmo-launch : le lanceur installe
# (/usr/local/bin/<fork>, celui que 40-qemu.sh appelle) est recompile sur place.
# C pur, libc seule, quelques secondes ; sans gcc on le dit et on laisse
# l'ancien binaire, qui reste valide (40-qemu.sh retombe sinon sur QEMU_BIN).
for f in $forks_moved; do
    src="/opt/GSM/$f/tools/qosmo-launch"
    [ -f "$src/qosmo-launch.c" ] || continue
    if command -v gcc >/dev/null 2>&1 && make -s -C "$src" install >/dev/null 2>&1; then
        printf "  ${G}✓${N} lanceur %s recompile (/usr/local/bin/%s)\n" "$f" "$f"
    else
        printf "  ${Y}⚠${N} lanceur %s non recompile (gcc/make ?) - l'ancien reste en place\n" "$f"
    fi
done

# Le dashboard tourne en service : un depot avance ne change rien tant que le
# demon fait tourner l'ancien server.js.
if [ "$web_moved" = "1" ]; then
    [ -f /opt/GSM/osmo-egprs-web/package.json ] && \
        (cd /opt/GSM/osmo-egprs-web && npm install --production >/dev/null 2>&1 || true)
    systemctl try-restart osmo-egprs-web >/dev/null 2>&1 || true
    printf "  ${G}✓${N} dashboard relance\n"
fi

[ "$BOOT" = "1" ] && exit 0
exit $rc
OSMOUPD
chmod +x "$ROOTFS/usr/local/bin/osmo-update"

# Au demarrage : apres le reseau, sans le bloquer. Type=oneshot + un ExecStart
# qui sort toujours 0 en mode --boot : une machine hors ligne demarre pareil.
cat > "$ROOTFS/etc/systemd/system/osmo-update.service" <<'EOF'
[Unit]
Description=osmo-operator - mise a jour des depots embarques (git, en place)
Wants=network-online.target
After=network-online.target systemd-networkd-wait-online.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/osmo-update --boot
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-update 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} osmo-update (/usr/local/bin, + service au demarrage : git fetch, jamais de reclone)"

# ── QEMU_BIN apres le reclone : build/qemu-system-arm dans l'arbre qosmo-grgsm ──
# [2026-08-27] Deux decisions justes, prises separement, se contredisent :
#
# L'arbre qosmo-grgsm part maintenant entier - .git et build/ compris - donc
# QEMU_BIN est resolu des la gravure, et ce service n'a rien a faire. Il est la
# pour le seul cas ou l'arbre perdrait son build/ : quelqu'un qui le reclone a
# la main, ou qui remplace /opt/GSM/qosmo-grgsm par un checkout frais. Sans build/,
# environnement/paths.env resout QEMU_BIN a un chemin inexistant et la pile
# s'arrete des le premier module :
#     [FAIL] Prerequisite checks (dépendances introuvables : QEMU_BIN)
# — alors que le binaire est la, dans /usr/local/bin.
#
# On recree donc le seul chemin que paths.env cherche, apres le reclone. Un lien
# symbolique, pas une copie : le binaire fait ~30 Mo et l'ISO tient en RAM.
# "build/" est la premiere ligne du .gitignore de qemu : le "git clean -fd" des
# synchronisations suivantes (wipe=0, incremental) ne l'efface pas - seul un
# clone frais le ferait, et ce service repasse a chaque demarrage.
cat > "$ROOTFS/usr/local/sbin/osmo-qemu-link.sh" <<'QLINK'
#!/bin/bash
# osmo-qemu-link.sh - rend QEMU_BIN resolvable apres le reclone de qosmo-grgsm.
# Voir build-iso.sh, etape [6/9], pour le pourquoi.
set -u
SRC="${OSMO_QEMU_BIN:-/usr/local/bin/qemu-system-arm}"
TREE="${OSMO_QEMU_SRC:-/opt/GSM/qosmo-grgsm}"
LNK="$TREE/build/qemu-system-arm"

# Pas de binaire (image inter-STP) ou pas d'arbre (reclone impossible, reseau
# coupe) : il n'y a rien a relier, et ce n'est pas ce service qui le dira.
[ -x "$SRC" ] || { echo "osmo-qemu-link: $SRC absent - rien a faire"; exit 0; }
[ -d "$TREE" ] || { echo "osmo-qemu-link: $TREE absent - rien a faire"; exit 0; }

# Un VRAI build compile sur place gagne toujours : on ne remplace qu'un lien
# (le notre) ou un chemin vide.
if [ -e "$LNK" ] && [ ! -L "$LNK" ]; then
    echo "osmo-qemu-link: $LNK est un vrai fichier - laisse tel quel"
    exit 0
fi

mkdir -p "$TREE/build"
ln -sfn "$SRC" "$LNK"
echo "osmo-qemu-link: $LNK -> $SRC"

# ── Lanceurs C (tools/qosmo-launch) : ce que 40-qemu.sh appelle ─────────────
# [2026-09-03] /usr/local/bin/<fork> est recompile s'il manque ou si la source
# de l'arbre est plus recente (reclone, osmo-update). Le fork qosmo-dsp n'a
# pas de lien possible : son QEMU porte le modele C54x, il doit etre dans son
# propre build/ ; on le dit si ce n'est pas le cas.
for fork in qosmo-grgsm qosmo-dsp; do
    src="/opt/GSM/$fork/tools/qosmo-launch"
    [ -f "$src/qosmo-launch.c" ] || continue
    if [ ! -x "/usr/local/bin/$fork" ] || [ "$src/qosmo-launch.c" -nt "/usr/local/bin/$fork" ]; then
        if command -v gcc >/dev/null 2>&1 && make -s -C "$src" install >/dev/null 2>&1; then
            echo "osmo-qemu-link: lanceur /usr/local/bin/$fork (re)compile"
        else
            echo "osmo-qemu-link: lanceur $fork non compile (gcc/make absents ?) - 40-qemu.sh retombe sur QEMU_BIN"
        fi
    fi
done
if [ -d /opt/GSM/qosmo-dsp ] && [ ! -x /opt/GSM/qosmo-dsp/build/qemu-system-arm ]; then
    echo "osmo-qemu-link: qosmo-dsp sans build/qemu-system-arm - --dsp indisponible (ninja -C /opt/GSM/qosmo-dsp/build qemu-system-arm)"
fi
QLINK
chmod +x "$ROOTFS/usr/local/sbin/osmo-qemu-link.sh"

cat > "$ROOTFS/etc/systemd/system/osmo-qemu-link.service" <<'EOF'
[Unit]
Description=osmo-operator - QEMU_BIN dans l'arbre qosmo-grgsm + lanceurs qosmo-grgsm/qosmo-dsp
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/osmo-qemu-link.sh
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-qemu-link 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} osmo-qemu-link (QEMU_BIN relie apres le reclone de qosmo-grgsm ; lanceurs qosmo-grgsm/qosmo-dsp recompiles si besoin)"



# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true

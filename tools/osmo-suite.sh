#!/bin/bash
# ~/suite - LA SUITE : ce qu il reste a faire sur ce poste, fait dans l ordre.
#
#   ~/suite          regarde ou en est la machine et fait l etape suivante
#   ~/suite etat     dit seulement ou elle en est (ne fait rien)
#
# Chaque outil demande lui-meme la phrase de /home (rien ne s ecrit sans elle) :
# ce script ne la voit pas et ne la garde pas. Il enchaine seulement :
#   1. valider la session, reconstruire l initramfs s il est en retard -> redemarrer
#   2. apres le redemarrage : sceller le TPM, valider                  -> redemarrer
#   3. plus rien a faire : l etat du poste, et ce qui reste a ta main
set -u
R=/media/root-ro
rouge() { printf '\033[1;31m%s\033[0m\n' "$*"; }
vert()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
titre() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
SEUL=0; [ "${1:-}" = etat ] && SEUL=1

# ── ou en est la machine ─────────────────────────────────────────────────────
scripts_en_retard() {      # un script de la session n est pas encore sur le disque
    local f
    for f in /usr/local/sbin/unlock-home /usr/local/sbin/lock-home /usr/local/sbin/osmo-tpm /usr/local/sbin/osmo-racine-live \
             /usr/local/sbin/osmo-empreinte /usr/local/sbin/osmo-total /usr/local/sbin/osmo-diffs /usr/local/bin/osmo-tpm-bienvenue; do
        [ -e "$f" ] || continue
        cmp -s "$f" "$R$f" || { echo "${f##*/}"; return 0; }
    done
    return 1
}
initramfs_en_retard() {    # il n embarque pas ce que les scripts du disque produiraient aujourd hui
    local i="$R/boot/initrd.img-$(uname -r)" rl="$R/usr/local/sbin/osmo-racine-live" p n f
    [ -e "$i" ] && [ -e "$rl" ] || return 1
    for p in "HOOK:$R/etc/initramfs-tools/hooks/osmo-boite" "SCRIPT:$R/etc/initramfs-tools/scripts/local-bottom/osmo-boite"; do
        n="${p%%:*}"; f="${p#*:}"
        # le crochet et le script d initramfs tels que osmo-racine-live les ecrirait
        sed -n "/cat > \"\$$n\" <<'$n'/,/^$n\$/p" "$rl" | sed '1d;$d' | cmp -s - "$f" || return 0
        [ "$f" -nt "$i" ] && return 0
    done
    for f in "$R/usr/local/sbin/osmo-total" "$R/usr/local/sbin/osmo-valider-appliquer"; do
        [ -e "$f" ] && [ "$f" -nt "$i" ] && return 0
    done
    return 1
}
tpm_pose()     { [ -e /etc/osmo-tpm/actif ]; }
tpm_reconnu()  { [ -e /run/osmo-tpm/reconnu ]; }
tpm_en_clair() { sudo sh -c 'ls /media/home-ro/.osmo-diffs/tpm/secret /media/home-ro/.osmo-diffs/tpm/graine /media/home-ro/.osmo-diffs/tpm/pcrs 2>/dev/null | grep -q .'; }
non_valide()   { sudo /usr/local/sbin/osmo-racine-live etat 2>/dev/null | grep -qE 'NON validee|changement\(s\) depuis'; }

etat() {
    titre "Etat du poste"
    mountpoint -q /root    && vert  "/root        : dans le volume chiffre" || rouge "/root        : celui du disque, en clair (apres le prochain demarrage)"
    mountpoint -q /opt/log && vert  "/opt/log     : dans le volume chiffre" || rouge "/opt/log     : pas encore monte depuis /home (apres le prochain demarrage)"
    if sudo test -e /media/home-ro/.osmo-diffs/signature.cle && ! sudo test -e /var/lib/osmo-diffs/signature.cle; then
        vert  "signature    : cle dans /home, plus sur la boite"
    else
        rouge "signature    : cle encore sur la boite (elle demenage a la prochaine validation)"
    fi
    if sudo sh -c 'ls -A /media/root-ro/root 2>/dev/null | grep -qE "^\.claude(\.json)?$|^\.bash_history$"'; then
        rouge "/root disque : encore l ancien etat de root en clair (nettoye a la validation qui suit le redemarrage)"
    else
        vert  "/root disque : nettoye"
    fi
    sudo /usr/local/sbin/osmo-empreinte signature 2>&1 | sed 's/^osmo-empreinte : /             /'
    sudo /usr/local/sbin/osmo-tpm etat 2>&1 | sed 's/^/             /'
    tpm_pose && tpm_en_clair && rouge "             phrase secrete et PIN encore en clair dans /home (remplaces par le coffre au prochain « sceller »)"
    r="$(scripts_en_retard)" && rouge "scripts      : $r (et peut-etre d autres) pas encore sur le disque"
    initramfs_en_retard && rouge "initramfs    : plus ancien que ses scripts"
    return 0
}

redemarrer() {
    echo
    read -r -p "Redemarrer maintenant ? [o/N] " rep
    case "$rep" in o|O|oui|OUI) sudo systemctl reboot ;; *) echo "Quand tu veux : systemctl reboot  - puis relance ~/suite" ;; esac
}
valider() {
    titre "Valider la session (phrase de /home)"
    /usr/local/bin/osmo-valider-session --maintenant || { rouge "validation non faite : on s arrete la"; exit 1; }
}

if [ "$SEUL" = 1 ]; then etat; exit 0; fi

# ── etape 1 : le disque n a pas encore les scripts, ou l initramfs est en retard
if r="$(scripts_en_retard)" || initramfs_en_retard; then
    titre "Etape 1 : mettre les scripts sur le disque${r:+ ($r...)}"
    if scripts_en_retard >/dev/null; then valider; fi
    if initramfs_en_retard; then
        titre "Reconstruire l initramfs (phrase de /home)"
        sudo /usr/local/sbin/osmo-racine-live actualiser || { rouge "initramfs non reconstruit : on s arrete la"; exit 1; }
    fi
    vert "Etape 1 faite."
    tpm_pose && echo "Au redemarrage : le PIN est demande ; s il n y a pas de phrase ensuite, c est attendu (l initramfs a change) : reponds OUI."
    redemarrer
    exit 0
fi

# ── etape 2 : le TPM n a pas reconnu ce demarrage, ou garde encore ses secrets en clair
if tpm_pose && { ! tpm_reconnu || tpm_en_clair; }; then
    titre "Etape 2 : sceller le TPM sur ce demarrage (phrase de /home)"
    echo "A faire seulement si tu sais pourquoi ce demarrage n a pas montre ta phrase"
    echo "(initramfs reconstruit a l etape 1, ou premiere pose)."
    read -r -p "Sceller ? [o/N] " rep
    case "$rep" in
        o|O|oui|OUI) sudo /usr/local/sbin/osmo-tpm sceller || { rouge "scellement non fait : on s arrete la"; exit 1; } ;;
        *) echo "Rien de scelle."; exit 0 ;;
    esac
    valider
    vert "Etape 2 faite. Au prochain demarrage : ton PIN, puis ta phrase."
    redemarrer
    exit 0
fi

# ── etape 3 : il reste peut-etre une session a valider ; sinon, plus rien
if non_valide; then
    read -r -p "La session a des changements non ecrits. Valider maintenant ? [o/N] " rep
    case "$rep" in o|O|oui|OUI) valider ;; esac
fi
etat
titre "Ce qui reste a ta main"
echo "- changer la phrase de /home, puis : sudo osmo-empreinte phrase-changee"
echo "  (l ancienne cle de signature a pu survivre sur le SSD : c est ce qui ferme ce point)"
echo "- renouveler les jetons qui ont vecu en clair : Claude (reconnexion), GitHub (gh auth login)"
echo "- si tu veux une nouvelle phrase secrete et un nouveau PIN : sudo osmo-tpm poser --secret"

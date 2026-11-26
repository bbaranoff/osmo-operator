#!/bin/bash
# ~/suite - LA SUITE : ce qu il reste a faire sur ce poste, fait dans l ordre.
# Fait pour quelqu un qui ne connait pas la machine : il dit ce qu il fait, pose
# le moins de questions possible, et la bonne reponse est toujours Entree.
#
#   icone « La suite » du bureau, ou ~/suite
#                    regarde ou en est la machine et fait l etape suivante
#   ~/suite etat     dit seulement ou elle en est (ne fait rien)
#   ~/suite stop     annule la reprise prevue au prochain demarrage
#
# S IL RESTE QUELQUE CHOSE APRES UN REDEMARRAGE, il se relance tout seul : a
# l etape 1 il pose une entree de demarrage de session, qui ouvre une fenetre
# avec la suite a l arrivee du bureau - UNE fois : elle se retire en se
# lancant. (Ce retrait est garde par la validation de cette session-la ; une
# session non validee ne laisse aucune trace, donc la fenetre reviendrait.)
#
# Chaque outil demande lui-meme la phrase de /home (rien ne s ecrit sans elle) :
# ce script ne la voit pas et ne la garde pas. Il enchaine seulement :
#   1. enregistrer la session, refaire le demarrage s il est en retard -> redemarrer
#   2. apres le redemarrage : le TPM reapprend la machine, on enregistre -> redemarrer
#   3. plus rien a faire : l etat du poste
set -u
R=/media/root-ro
rouge() { printf '\033[1;31m%s\033[0m\n' "$*"; }
vert()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
titre() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
AUTO="$HOME/.config/autostart/osmo-suite.desktop"
MOI="$(readlink -f "$0")"
G=/opt/GSM/osmo-operator/tools/osmo-gtk-run.py
REPRISE=0

# oui QUESTION : Entree ou « o » = oui ; « n » = non
oui() {
    local rep
    read -r -p "$1 [Entree = oui, n = non] " rep || rep=n
    case "$rep" in n|N|non|NON|Non) return 1 ;; *) return 0 ;; esac
}
# non QUESTION : il faut taper « oui » en toutes lettres (ce qui ne doit pas se faire par reflexe)
non() {
    local rep
    read -r -p "$1 [taper oui, sinon Entree] " rep || rep=""
    case "$rep" in oui|OUI|Oui) return 0 ;; *) return 1 ;; esac
}
fenetre() {    # ce script, dans une fenetre du banc
    if [ -x "$G" ]; then exec python3 "$G" --tty --keep-open --title "La suite" -- "$MOI" "$@"
    elif command -v gnome-terminal >/dev/null 2>&1; then exec gnome-terminal -- bash -c "'$MOI' $*; echo; read -r -p 'Entree pour fermer' _"
    fi
    exit 0
}

# la reprise au prochain demarrage : posee par l etape 1, retiree des qu elle a servi
prevoir_reprise() {
    mkdir -p "${AUTO%/*}" && cat > "$AUTO" <<EOF
[Desktop Entry]
Type=Application
Name=La suite
Exec=$MOI auto
OnlyShowIn=GNOME;
NoDisplay=true
X-GNOME-Autostart-Phase=Applications
X-GNOME-Autostart-Delay=2
EOF
}
case "${1:-}" in
    stop)    rm -f "$AUTO"; echo "La suite ne se relancera pas toute seule au prochain demarrage."; exit 0 ;;
    auto)    rm -f "$AUTO"; fenetre reprise ;;     # a l arrivee du bureau, une fois
    icone)   fenetre ;;                            # l icone du bureau
    reprise) REPRISE=1 ;;
esac
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

# une ligne par point : vert = bon, rouge = pas encore
point() { if [ "$1" = 0 ]; then vert "  [bon]         $2"; else rouge "  [pas encore]  $3"; fi; }
etat() {
    local c r
    titre "Ou en est ce poste"
    echo "(le mot de passe demande ici est celui de ton compte, pour lire l etat de la machine)"
    mountpoint -q /root;    point $? "Les affaires de l administrateur sont a l abri (chiffrees)." \
                                     "Les affaires de l administrateur seront a l abri apres un redemarrage."
    mountpoint -q /opt/log; point $? "Les journaux du banc sont a l abri (chiffres)." \
                                     "Les journaux du banc seront a l abri apres un redemarrage."
    sudo sh -c 'test -e /media/home-ro/.osmo-diffs/signature.cle && ! test -e /var/lib/osmo-diffs/signature.cle'
    point $? "La cle qui signe le disque est rangee dans la partie chiffree." \
             "La cle qui signe le disque sera rangee au prochain enregistrement."
    sudo sh -c 'ls -A /media/root-ro/root 2>/dev/null | grep -qE "^\.claude(\.json)?$|^\.bash_history$"'; c=$?
    point $(( c == 0 ? 1 : 0 )) "Le disque ne garde plus rien de personnel en clair." \
             "Le disque garde encore d anciens fichiers personnels en clair (nettoyes a l enregistrement qui suit le redemarrage)."
    sudo /usr/local/sbin/osmo-empreinte signature 2>/dev/null | grep -q 'signature de l empreinte : valide'
    point $? "Le disque n a pas ete modifie en ton absence (sa signature est bonne)." \
             "LA SIGNATURE DU DISQUE N EST PAS BONNE : ne continue pas, demande de l aide."
    if tpm_pose; then
        tpm_reconnu; point $? "La puce de securite (TPM) a reconnu la machine a ce demarrage." \
                              "La puce de securite (TPM) n a pas reconnu ce demarrage (normal juste apres l etape 1)."
        tpm_en_clair; c=$?
        point $(( c == 0 ? 1 : 0 )) "Ta phrase secrete et ton PIN sont proteges par ta phrase de /home." \
                 "Ta phrase secrete et ton PIN seront mieux proteges apres l etape 2."
    else
        rouge "  [pas encore]  La puce de securite (TPM) ne surveille pas le demarrage de ce poste."
    fi
    r="$(scripts_en_retard)"; c=$?
    point $(( c == 0 ? 1 : 0 )) "Les programmes du poste sont a jour sur le disque." \
             "Des programmes du poste ne sont pas encore sur le disque (etape 1)."
    return 0
}

redemarrer() {
    echo
    if oui "Redemarrer la machine maintenant ?"; then
        echo "A l extinction, l ecran noir te demandera ta phrase de /home : tape-la."
        sleep 3
        sudo systemctl reboot
    else
        echo "D accord. Redemarre quand tu veux (menu en haut a droite) ; la suite reprendra toute seule."
    fi
}
valider() {
    titre "Enregistrer ton travail sur le disque"
    echo "Tape ta phrase de /home quand on te la demande (rien ne s affiche pendant que tu tapes)."
    /usr/local/bin/osmo-valider-session --maintenant || { rouge "L enregistrement n a pas ete fait. Rien n est casse : relance « La suite » pour reessayer."; exit 1; }
}

if [ "$SEUL" = 1 ]; then etat; exit 0; fi

echo "LA SUITE : je regarde ou en est ce poste et je fais ce qu il reste a faire."
echo "Tu n as qu a repondre aux questions ; Entree suffit presque toujours."

# ── etape 1 : le disque n a pas encore les programmes, ou le demarrage est en retard
if r="$(scripts_en_retard)" || initramfs_en_retard; then
    titre "Etape 1 sur 2 : mettre le poste a jour sur le disque"
    echo "Je vais enregistrer la session, puis refaire le demarrage de la machine si besoin."
    echo "Ta phrase de /home sera demandee une ou deux fois. Cela prend deux ou trois minutes."
    oui "On y va ?" || { echo "Rien n a ete fait."; exit 0; }
    # la suite reprendra toute seule apres le redemarrage (posee AVANT d enregistrer,
    # pour que l enregistrement la garde)
    prevoir_reprise
    valider
    if initramfs_en_retard; then
        titre "Refaire le demarrage de la machine"
        echo "Tape encore ta phrase de /home (environ une minute ensuite)."
        sudo /usr/local/sbin/osmo-racine-live actualiser || { rouge "Le demarrage n a pas ete refait. Rien n est casse : relance « La suite » pour reessayer."; exit 1; }
    fi
    vert "Etape 1 terminee."
    echo
    echo "IL FAUT MAINTENANT REDEMARRER. Au redemarrage :"
    if tpm_pose; then
        echo "  1. ton PIN te sera demande : tape-le ;"
        echo "  2. cette fois, ta phrase secrete ne s affichera PAS et un avertissement rouge"
        echo "     apparaitra : C EST NORMAL cette fois (le demarrage vient d etre refait)."
        echo "     Tape OUI, puis ta phrase de /home ;"
        echo "  3. une fenetre « La suite » s ouvrira toute seule a l arrivee du bureau."
    else
        echo "  tape ta phrase de /home comme d habitude ; « La suite » s ouvrira toute seule."
    fi
    redemarrer
    exit 0
fi

# ── etape 2 : le TPM n a pas reconnu ce demarrage, ou garde encore ses secrets en clair
rm -f "$AUTO"
if tpm_pose && { ! tpm_reconnu || tpm_en_clair; }; then
    titre "Etape 2 sur 2 : la puce de securite reapprend la machine"
    if [ "$REPRISE" = 1 ] || tpm_reconnu; then
        echo "Le demarrage a ete refait a l etape 1 : il est normal que ta phrase secrete"
        echo "n ait pas ete affichee. La puce (TPM) doit maintenant retenir ce nouveau demarrage."
        echo "Ta phrase de /home sera demandee deux fois (une vingtaine de secondes a chaque fois)."
        oui "On y va ?" || { echo "Rien n a ete fait. Relance « La suite » quand tu veux."; exit 0; }
    else
        rouge "ATTENTION. La machine n a pas affiche ta phrase secrete a ce demarrage,"
        rouge "et ce n est PAS a la suite d une etape faite par ce programme."
        echo "Si tu n as rien change toi-meme (mise a jour, « poser »), quelqu un a peut-etre"
        echo "touche a la machine : dans le doute, ne continue pas et demande de l aide."
        non "Je sais pourquoi, la puce doit retenir ce demarrage :" || { echo "Rien n a ete fait."; exit 0; }
    fi
    sudo /usr/local/sbin/osmo-tpm sceller || { rouge "La puce n a rien retenu. Rien n est casse : relance « La suite » pour reessayer."; exit 1; }
    valider
    vert "Etape 2 terminee."
    echo
    echo "Dernier redemarrage. Cette fois : ton PIN, puis TA PHRASE SECRETE doit s afficher."
    echo "Si elle s affiche, tout est en place. Si elle ne s affiche pas, ne tape rien et demande de l aide."
    redemarrer
    exit 0
fi

# ── plus rien a faire
if non_valide && oui "Tu as du travail non enregistre dans cette session. L enregistrer maintenant ?"; then valider; fi
etat
echo
vert "Il n y a plus rien a faire ici."
titre "Trois choses que personne ne peut faire a ta place"
echo "1. Changer ta phrase de /home (l ancienne a pu laisser une trace sur le disque) :"
echo "     sudo cryptsetup luksChangeKey /dev/disk/by-uuid/$(. /etc/default/crypthome 2>/dev/null; echo "${CRYPTHOME_UUID:-...}")"
echo "     sudo osmo-empreinte phrase-changee"
echo "2. Te reconnecter a Claude et a GitHub (leurs anciens jetons ont ete lisibles) :"
echo "     claude        puis        gh auth login"
echo "3. Si tu veux une nouvelle phrase secrete et un nouveau PIN :"
echo "     sudo osmo-tpm poser --secret"

w_no_contacts() {
    # [2026-09-06] CE QUE CETTE COMMANDE NE FAIT PLUS. Elle revoquait
    # READ_CONTACTS et posait un refus AppOps par-dessus : Fossify Messages
    # refuse alors d ouvrir l ecran « nouvelle conversation » (« The app could
    # not access your contacts ») - on ne pouvait meme plus composer un numero
    # a la main. Et surtout, une version precedente allait jusqu a VIDER le
    # carnet : sur un compte Google synchronise, la suppression est remontee au
    # serveur. On ne touche plus jamais aux donnees.
    #
    # Ce qui reste : couper la synchro des contacts vers Android. Sur un banc,
    # le carnet est vide et aucune suggestion n apparait - c est suffisant, et
    # c est reversible d un mot.
    _ril_need_root || return 1
    waydroid shell -- sh -c '
        pm disable-user --user 0 com.google.android.contacts 2>/dev/null
        cmd appops set com.google.android.gms WRITE_CONTACTS deny 2>/dev/null' >/dev/null 2>&1
    _ok "synchro des contacts coupee (le carnet Android reste vide)"
    _warn "les donnees ne sont PAS touchees ; pour revenir en arriere :"
    _warn "  waydroid shell -- pm enable com.google.android.contacts"
}

#!/bin/bash
# osmo-waydroid.sh - LE TELEPHONE ANDROID DU BANC.
#
# Waydroid fait tourner un Android (LineageOS) en conteneur LXC sur la session
# graphique. Il n a PAS de modem : pas de RIL, pas de reseau mobile dans
# Android. Ce que ce script met en place, c est le RACCORD MOBILE - Android
# d un cote, la pile telephonie de l hote (oFono, branchee sur le banc GSM) de
# l autre, et tools/osmo-ofono-bridge.py au milieu qui porte les SMS et les
# appels de l un vers l autre (cf. l entete de ce fichier-la pour ce que le
# pont sait et ne sait pas faire).
#
#   osmo-waydroid ril-install <pack>   le VRAI RIL dans Android (voir plus bas)
#   osmo-waydroid ril-status  ce qui manque encore au RIL
#   osmo-waydroid telephony-on  les permissions telephonie (moitie du chemin)
#   osmo-waydroid fdroid      F-Droid (magasin libre, aucun compte a creer)
#   osmo-waydroid sms-app     Fossify Messages en appli SMS (pas de compte Google)
#   osmo-waydroid no-contacts coupe les suggestions de contacts (SMS + appels)
#   osmo-waydroid phone-app   Fossify Phone en composeur, epingle au dock
#   osmo-waydroid dock        epingle telephone + SMS au dock de l hote
#   osmo-waydroid app-install <apk|url>   poser une appli Android
#   osmo-waydroid install     paquets + depot + waydroid init (une fois)
#   osmo-waydroid start       conteneur + session + fenetre Android (telephone)
#   osmo-waydroid phone [WxH] la fenetre au format telephone (defaut 480x960)
#   osmo-waydroid bridge      le pont oFono <-> Android (SMS + appels)
#   osmo-waydroid data-up     route la data d Android par le banc  [voir plus bas]
#   osmo-waydroid data-down   defait ce routage
#   osmo-waydroid status      ou en est chaque morceau
#   osmo-waydroid stop        session, conteneur et pont
#
# LE VRAI RIL, LUI, EXISTE - et c est mieux que le pont. [2026-09-06] Quectel
# publie un RIL Android x86_64 pour Android 13 (« Android RIL and GNSS driver
# for Android 13 on x86-64 », driver V3.6.35 : libril.so, libreference-ril.so,
# librilutils.so, gps.default.so, HAL HIDL IRadio@1.1::IRadio/slot1, propriete
# gsm.version.ril-impl). L image Waydroid d ici est justement LineageOS 20 /
# Android 13 / x86_64 : la cible exacte. Avec un modem Quectel (EC25) branche,
# Android retrouve une VRAIE pile telephonie - composeur, Messages, barres de
# reseau - au lieu des notifications du pont. Ce que l image a deja et ce qui
# manque :
#
#   deja la : /vendor/lib64/libril.so, libreference-ril.so, librilutils.so
#   manque  : le binaire rild (/vendor/bin/hw/rild), le fragment VINTF qui
#             declare IRadio, le service init qui lance rild sur le port AT,
#             les permissions android.hardware.telephony.*, et le passage du
#             /dev/ttyUSB* de l hote dans le conteneur LXC.
#
# « ril-install » pose tout ca a partir du pack Quectel (distribue par message
# prive sur le forum : on ne peut pas le telecharger, il faut le fournir), dans
# l overlay Waydroid pour que ca survive aux mises a jour de l image. Le pont
# oFono reste utile sans modem Quectel, ou quand le RIL n est pas installe.
#
# LA DATA N EST PAS ENCORE EN SERVICE. Le banc n etablit pas de contexte PDP
# aujourd hui : « data-up » est donc CABLE mais ne s allume pas tout seul, et
# il refuse proprement tant que le pont n a pas publie une interface data dans
# /run/osmo-ril/state.json. Le jour ou le contexte monte (osmo-ggsn + apn0 cote
# banc, ConnectionContext cote oFono), « osmo-ofono-bridge.py --data » publie
# l interface et « data-up » n a plus qu a poser le NAT depuis waydroid0.
set -u

REPO="${OSMO_REPO:-/opt/GSM/osmo-operator}"
BRIDGE="$REPO/tools/osmo-ofono-bridge.py"
RUN="${OSMO_RIL_DIR:-/run/osmo-ril}"
STATE="$RUN/state.json"
WAYNET="${OSMO_WAYDROID_NET:-192.168.240.0/24}"   # le pont waydroid0 par defaut
WAYLIB="${OSMO_WAYDROID_LIB:-/var/lib/waydroid}"
OVL="$WAYLIB/overlay"                            # superpose au rootfs Android
BASEPROP="$WAYLIB/waydroid_base.prop"
LXCCFG="$WAYLIB/lxc/waydroid/config"
# Le port AT que rild ouvrira. [2026-09-06] SUR CE BANC, L EC25 C EST oFONO :
# il n y a pas de dongle, le modem est tools/osmo-ril-atmodem.py, adosse a
# oFono, qui publie son pseudo-terminal ici. Sur un banc avec un vrai Quectel,
# OSMO_RIL_TTY=/dev/ttyUSB2 (le port AT de l EC25 : 0=DM, 1=NMEA, 2=AT, 3=modem).
RIL_TTY="${OSMO_RIL_TTY:-/run/osmo-ril/at-pty}"
# LE FORMAT TELEPHONE. « show-full-ui » ouvre l ecran Android a la resolution de
# la session, ce qui donne une dalle de bureau plein cadre - pas un telephone.
# Waydroid dimensionne sa fenetre par persist.waydroid.width/height : on pose un
# 480x960 (9:18, l allure d un mobile) et on coupe le multi-fenetre, qui sort au
# contraire les applis Android en fenetres separees facon bureau.
# Le journal de session : ecrit par le compte du bureau, donc pas dans un
# fichier que root aurait cree avant lui (« Permission denied »).
SESSION_LOG="${OSMO_WAYDROID_SESSION_LOG:-/tmp/osmo-waydroid-session-$(id -un).log}"
PHONE_W="${OSMO_WAYDROID_W:-480}"
PHONE_H="${OSMO_WAYDROID_H:-960}"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
_say()  { echo -e "  ${CYAN}→${NC} $*"; }
_ok()   { echo -e "      ${GREEN}✓${NC} $*"; }
_warn() { echo -e "      ${YELLOW}!${NC} $*"; }
_err()  { echo -e "      ${RED}✗${NC} $*"; }

# ── INSTALLATION ────────────────────────────────────────────────────────────
w_install() {
    _say "paquets"
    if command -v waydroid >/dev/null 2>&1; then
        _ok "waydroid deja present"
    else
        # Le paquet n est dans Ubuntu que depuis peu ; sinon le depot amont.
        if ! $SUDO apt-get install -y --no-install-recommends waydroid >/dev/null 2>&1; then
            _say "depot amont waydroid"
            $SUDO apt-get install -y --no-install-recommends ca-certificates curl >/dev/null 2>&1
            curl -fsSL https://repo.waydro.id | $SUDO bash >/dev/null 2>&1 \
                && $SUDO apt-get install -y waydroid >/dev/null 2>&1
        fi
        command -v waydroid >/dev/null 2>&1 && _ok "waydroid installe" || { _err "waydroid indisponible"; return 1; }
    fi
    # ofono : l autre bout du raccord.
    dpkg -s ofono >/dev/null 2>&1 || $SUDO apt-get install -y --no-install-recommends ofono >/dev/null 2>&1
    dpkg -s ofono >/dev/null 2>&1 && _ok "ofono present" || _warn "ofono absent - le pont n aura pas de modem"

    _say "image Android"
    if [ -f /var/lib/waydroid/waydroid.cfg ]; then
        _ok "waydroid deja initialise"
    else
        # VANILLA : pas de services Google. Un banc GSM n a rien a envoyer a
        # Google, et GAPPS demande en plus un enregistrement d appareil.
        $SUDO waydroid init -s VANILLA && _ok "image initialisee" || { _err "waydroid init a echoue"; return 1; }
    fi
    $SUDO systemctl enable --now waydroid-container >/dev/null 2>&1 \
        && _ok "conteneur active" || _warn "service waydroid-container non active"
}

# ── LE FORMAT TELEPHONE ─────────────────────────────────────────────────────
_phone_props() {
    # Deux chemins, parce que ces proprietes se posent AVANT que la session
    # existe : waydroid_base.prop est relu a chaque demarrage (c est lui qui
    # compte), « waydroid prop set » ne marche que session en marche mais evite
    # d avoir a la relancer.
    local kv k v
    for kv in "persist.waydroid.width=$PHONE_W" \
              "persist.waydroid.height=$PHONE_H" \
              "persist.waydroid.multi_windows=false"; do
        k="${kv%%=*}"; v="${kv#*=}"
        if [ -w "$BASEPROP" ] || [ "$(id -u)" -eq 0 ]; then
            if grep -q "^$k=" "$BASEPROP" 2>/dev/null; then
                $SUDO sed -i "s|^$k=.*|$k=$v|" "$BASEPROP"
            else
                echo "$k=$v" | $SUDO tee -a "$BASEPROP" >/dev/null
            fi
        fi
        waydroid prop set "$k" "$v" >/dev/null 2>&1
    done
}

w_phone() {
    # « osmo-waydroid phone 540x1140 » pour une autre taille.
    if [ -n "${1:-}" ]; then
        PHONE_W="${1%%x*}"; PHONE_H="${1##*x}"
    fi
    _say "format telephone ${PHONE_W}x${PHONE_H}"
    _phone_props
    _ok "proprietes posees"
    # La taille est lue au demarrage de la session : on la relance.
    if waydroid status 2>/dev/null | grep -qi "session.*RUNNING"; then
        _say "relance de la session pour reprendre la taille"
        waydroid session stop >/dev/null 2>&1
        sleep 2
    fi
    w_start
}

# ── SESSION ─────────────────────────────────────────────────────────────────
w_start() {
    command -v waydroid >/dev/null 2>&1 || { _err "waydroid absent (osmo-waydroid install)"; return 1; }
    _phone_props
    $SUDO systemctl start waydroid-container >/dev/null 2>&1
    if waydroid status 2>/dev/null | grep -qi "session.*RUNNING"; then
        _ok "session deja en marche"
    else
        _say "session"
        (waydroid session start >"$SESSION_LOG" 2>&1 &)
        for _ in $(seq 1 30); do
            waydroid status 2>/dev/null | grep -qi "session.*RUNNING" && break
            sleep 1
        done
        waydroid status 2>/dev/null | grep -qi "session.*RUNNING" \
            && _ok "session en marche" || _warn "session lente a demarrer (cf. $SESSION_LOG)"
    fi
    _say "fenetre Android"
    (waydroid show-full-ui >>"$SESSION_LOG" 2>&1 &)
    _ok "IHM lancee"
}

# ── LE PONT ─────────────────────────────────────────────────────────────────
w_bridge() {
    pgrep -f "[o]smo-ofono-bridge\.py" >/dev/null 2>&1 && { _ok "pont deja en marche"; return 0; }
    _say "ofonod"
    $SUDO systemctl start ofono >/dev/null 2>&1 || $SUDO ofonod >/dev/null 2>&1 &
    sleep 1
    _say "pont oFono <-> Android"
    $SUDO mkdir -p "$RUN" && $SUDO chmod 0777 "$RUN"
    ($SUDO "$BRIDGE" >>/tmp/osmo-ril.log 2>&1 &)
    sleep 2
    if pgrep -f "[o]smo-ofono-bridge\.py" >/dev/null 2>&1; then
        _ok "pont en place (journal : /tmp/osmo-ril.log)"
    else
        _err "le pont s est arrete - derniere ligne :"
        tail -n 3 /tmp/osmo-ril.log 2>/dev/null | sed 's/^/        /'
    fi
}

# ── LA DATA (cablee, pas encore en service) ─────────────────────────────────
_data_iface() {
    [ -f "$STATE" ] || return 1
    /usr/bin/python3 - "$STATE" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1])).get("data") or {}
except Exception:
    sys.exit(1)
print(d.get("interface") or "")
PY
}

w_data_up() {
    local dev; dev="$(_data_iface || true)"
    if [ -z "${dev:-}" ]; then
        _warn "aucune interface data publiee par le pont"
        _warn "le banc n etablit pas encore de contexte PDP : lancer d abord"
        _warn "  sudo $BRIDGE --data   (il publiera l interface dans $STATE)"
        return 1
    fi
    _say "routage waydroid0 -> $dev"
    $SUDO sysctl -qw net.ipv4.ip_forward=1
    $SUDO iptables -t nat -C POSTROUTING -s "$WAYNET" -o "$dev" -j MASQUERADE 2>/dev/null \
        || $SUDO iptables -t nat -A POSTROUTING -s "$WAYNET" -o "$dev" -j MASQUERADE
    $SUDO iptables -C FORWARD -i waydroid0 -o "$dev" -j ACCEPT 2>/dev/null \
        || $SUDO iptables -A FORWARD -i waydroid0 -o "$dev" -j ACCEPT
    $SUDO iptables -C FORWARD -i "$dev" -o waydroid0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
        || $SUDO iptables -A FORWARD -i "$dev" -o waydroid0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    _ok "Android sort par $dev"
}

w_data_down() {
    local dev; dev="$(_data_iface || true)"
    [ -z "${dev:-}" ] && { _warn "rien a defaire"; return 0; }
    $SUDO iptables -t nat -D POSTROUTING -s "$WAYNET" -o "$dev" -j MASQUERADE 2>/dev/null
    $SUDO iptables -D FORWARD -i waydroid0 -o "$dev" -j ACCEPT 2>/dev/null
    $SUDO iptables -D FORWARD -i "$dev" -o waydroid0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    _ok "routage retire"
}

# ── POSER UNE APPLI ─────────────────────────────────────────────────────────
# [2026-09-06] LE PIEGE DES DEUX COMPTES. « waydroid shell » exige root, alors
# que « waydroid app ... » parle au bus de SESSION et doit tourner sous le
# compte du bureau : lance en root, « app launch » meurt sur
# « org.freedesktop.DBus.Error.NoReply ». On accepte donc les deux et on
# redescend au compte de la session quand il le faut.
_wayd_user() {
    # Le compte qui tient la session Waydroid (celui du bureau).
    waydroid status 2>/dev/null | sed -n 's/^Session user:[[:space:]]*\([^(]*\).*/\1/p' | tr -d ' \r'
}

w_app_install() {
    local src="${1:-}"
    [ -n "$src" ] || { _err "usage: osmo-waydroid app-install <fichier.apk|url>"; return 2; }
    local apk="$src"
    case "$src" in
        http://*|https://*)
            apk="/tmp/osmo-apk-$$.apk"
            _say "telechargement"
            curl -fsSL -m 300 -o "$apk" "$src" || { _err "telechargement impossible"; return 1; }
            ;;
    esac
    [ -f "$apk" ] || { _err "$apk introuvable"; return 1; }
    chmod 644 "$apk"
    _say "installation dans Android"
    # « app install » interroge le bus de SESSION : lance en root il repond
    # « WayDroid session is stopped » alors que la session tourne tres bien
    # sous le compte du bureau. On redescend donc a ce compte-la.
    local out u; u="$(_wayd_user)"
    if [ -n "$u" ] && [ "$u" != "$(id -un)" ]; then
        local uid; uid="$(id -u "$u")"
        out="$(su "$u" -c "XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus waydroid app install '$apk'" 2>&1)"
    else
        out="$(waydroid app install "$apk" 2>&1)"
    fi
    # Le succes est muet ; on ne se fie donc pas au code de retour mais a ce que
    # le package manager dit ensuite.
    case "$out" in
        *"session is stopped"*) _err "session Waydroid arretee (osmo-waydroid start)"; return 1 ;;
        *Failure*|*Error*|*error*|*Exception*) _err "installation refusee :"; echo "$out" | tail -n 3 | sed 's/^/        /'; return 1 ;;
    esac
    _ok "$(basename "$apk") installe"
    [ "$apk" != "$src" ] && rm -f "$apk"
    return 0
}

w_fdroid() {
    # F-Droid : le magasin libre, aucun compte a creer - c est la reponse quand
    # on ne veut pas se connecter aux services Google pour poser une appli.
    if waydroid shell -- pm list packages 2>/dev/null | grep -q org.fdroid.fdroid; then
        _ok "F-Droid deja installe"
    else
        w_app_install "https://f-droid.org/F-Droid.apk" || return 1
    fi
    local u; u="$(_wayd_user)"
    if [ -n "$u" ] && [ "$u" != "$(id -un)" ]; then
        su "$u" -c "XDG_RUNTIME_DIR=/run/user/$(id -u "$u") DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$u")/bus waydroid app launch org.fdroid.fdroid" >/dev/null 2>&1 &
    else
        waydroid app launch org.fdroid.fdroid >/dev/null 2>&1 &
    fi
    _ok "F-Droid lance"
}

w_sms_app() {
    # [2026-09-06] UNE APPLI SMS QUI NE DEMANDE PAS DE COMPTE. L image GAPPS
    # arrive avec Google Messages, qui exige une connexion Google et tourne
    # indefiniment sur son ecran de sign-in. Fossify Messages (F-Droid, libre,
    # aucun compte) fait le meme travail et parle a la MEME pile : le provider
    # SMS d Android, donc le RIL des qu il est la. On la pose, on lui donne le
    # role SMS, et on eteint Google Messages.
    local vc apk
    _say "Fossify Messages (F-Droid)"
    vc="$(curl -s -m 20 https://f-droid.org/api/v1/packages/org.fossify.messages \
          | sed -n 's/.*"suggestedVersionCode":\([0-9]*\).*/\1/p')"
    [ -n "$vc" ] || { _err "F-Droid injoignable"; return 1; }
    w_app_install "https://f-droid.org/repo/org.fossify.messages_$vc.apk" || return 1
    _say "role SMS"
    waydroid shell -- sh -c 'cmd role add-role-holder android.app.role.SMS org.fossify.messages;
        settings put secure sms_default_application org.fossify.messages;
        pm disable-user --user 0 com.google.android.apps.messaging' >/dev/null 2>&1
    _ok "Fossify Messages est l appli SMS par defaut, Google Messages eteint"
    w_dock
    _warn "elle n affichera des SMS qu avec une pile radio : voir ril-install"
}

w_no_contacts() {
    # [2026-09-06] PAS DE SUGGESTIONS DE CONTACTS. Sur un banc, on compose des
    # numeros du reseau (100102...), pas des noms : la complétion de contacts
    # dans l appli SMS et dans le composeur ne fait que gener. Le levier est la
    # permission READ_CONTACTS - sans elle, aucune suggestion n est possible.
    # Mais la revoquer ne suffit pas : le titulaire du role SMS la recoit
    # AUTOMATIQUEMENT (flag GRANTED_BY_ROLE), donc elle revient toute seule. On
    # pose donc aussi un refus AppOps, qui prime sur la permission accordee et
    # survit au ré-octroi par le role.
    local apps="org.fossify.messages com.google.android.apps.messaging com.android.dialer com.google.android.dialer com.android.contacts"
    waydroid shell -- sh -c "
        for p in $apps; do
            pm list packages | grep -q \"package:\$p\" || continue
            for perm in android.permission.READ_CONTACTS android.permission.WRITE_CONTACTS android.permission.GET_ACCOUNTS; do
                pm revoke \"\$p\" \"\$perm\" 2>/dev/null
            done
            cmd appops set \"\$p\" READ_CONTACTS deny 2>/dev/null
        done" >/dev/null 2>&1
    _ok "suggestions de contacts coupees (SMS et composeur)"
    _warn "a relancer apres ril-install : le composeur arrive avec le RIL"
}

w_dock() {
    # Waydroid ecrit un .desktop par appli Android installee dans
    # ~/.local/share/applications/waydroid.<paquet>.desktop : le dock de l hote
    # sait donc les lancer comme n importe quelle appli. On y epingle le
    # telephone et les SMS. (Sur une image neuve, la meme paire est deja dans
    # les favoris par defaut - iso_modules/80-chroot.sh ; ici on rattrape une
    # machine deja installee.) Une entree dont le .desktop manque est ignoree
    # par GNOME, sans trou dans le dock.
    local u; u="$(_wayd_user)"; [ -n "$u" ] || u="$(id -un)"
    local uid; uid="$(id -u "$u")"
    su "$u" -c "XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus bash -s" <<'DOCK'
cur="$(gsettings get org.gnome.shell favorite-apps)"
for d in waydroid.org.fossify.phone.desktop waydroid.org.fossify.messages.desktop; do
    case "$cur" in *"$d"*) continue ;; esac
    cur="${cur%]}, '$d']"
    cur="${cur/#\[, /[}"
done
gsettings set org.gnome.shell favorite-apps "$cur"
DOCK
    _ok "telephone et SMS epingles au dock"
}

w_phone_app() {
    # L appli d appel, meme logique que sms-app : Fossify Phone (F-Droid, pas
    # de compte). Le role DIALER, lui, ne s accorde qu une fois la telephonie
    # vivante - sans pile radio Android repond « Failed » ; on pose donc aussi
    # le reglage direct, et ril-install rejouera le role.
    local vc
    _say "Fossify Phone (F-Droid)"
    vc="$(curl -s -m 20 https://f-droid.org/api/v1/packages/org.fossify.phone \
          | sed -n 's/.*"suggestedVersionCode":\([0-9]*\).*/\1/p')"
    [ -n "$vc" ] || { _err "F-Droid injoignable"; return 1; }
    w_app_install "https://f-droid.org/repo/org.fossify.phone_$vc.apk" || return 1
    waydroid shell -- sh -c 'cmd role add-role-holder android.app.role.DIALER org.fossify.phone;
        settings put secure dialer_default_application org.fossify.phone' >/dev/null 2>&1
    _ok "Fossify Phone pose comme composeur"
    w_dock
}

# ── LE VRAI RIL : LE PACK QUECTEL DANS L IMAGE ANDROID ──────────────────────
# On ne touche JAMAIS au rootfs de l image (il est remplace a chaque OTA) : tout
# passe par /var/lib/waydroid/overlay, que Waydroid superpose au demarrage. Un
# « waydroid upgrade » garde donc le RIL.
_ril_need_root() { [ "$(id -u)" -eq 0 ] || { _err "a lancer en root (sudo)"; return 1; }; }

_ril_classer() {
    # Un pack Quectel arrive soit deja arborescent (vendor/..., system/...),
    # soit en vrac. Arborescent : on recopie tel quel. En vrac : on range chaque
    # fichier a la place qu Android lui demande.
    local src="$1"
    if [ -d "$src/vendor" ] || [ -d "$src/system" ]; then
        _say "pack arborescent : recopie dans l overlay"
        cp -a "$src"/vendor "$OVL"/ 2>/dev/null
        cp -a "$src"/system "$OVL"/ 2>/dev/null
        return 0
    fi
    _say "pack en vrac : rangement"
    mkdir -p "$OVL/vendor/lib64/hw" "$OVL/vendor/bin/hw" \
             "$OVL/vendor/etc/init" "$OVL/vendor/etc/vintf/manifest"
    local f b
    find "$src" -type f | while read -r f; do
        b="$(basename "$f")"
        case "$b" in
            rild)            install -m755 "$f" "$OVL/vendor/bin/hw/$b" ;;
            gps.default.so)  install -m644 "$f" "$OVL/vendor/lib64/hw/$b" ;;
            *ril*.so)        install -m644 "$f" "$OVL/vendor/lib64/$b" ;;
            *.rc)            install -m644 "$f" "$OVL/vendor/etc/init/$b" ;;
            *manifest*.xml)  install -m644 "$f" "$OVL/vendor/etc/vintf/manifest/$b" ;;
            *)               _warn "ignore : $b" ;;
        esac
    done
}

_ril_completer() {
    # Les dossiers de l overlay : _ril_classer les cree quand on installe un
    # pack, mais l installation du RIL maison n y passe pas.
    mkdir -p "$OVL/vendor/etc/init" "$OVL/vendor/etc/vintf/manifest" \
             "$OVL/vendor/lib64/hw" "$OVL/vendor/bin/hw" \
             "$OVL/system/etc/permissions"
    # Ce que le pack ne fournit pas toujours : le service init, le fragment
    # VINTF, les permissions telephonie. On ne pose que ce qui manque - un
    # fichier du pack fait toujours autorite.
    local rc="$OVL/vendor/etc/init/osmo-rild.rc"
    if ls "$OVL"/vendor/etc/init/*.rc >/dev/null 2>&1 && [ ! -f "$rc" ]; then
        _ok "service init fourni par le pack"
    else
        # Le tty tel que le CONTENEUR le voit : LXC monte le pseudo-terminal de
        # l hote sous ce nom (cf. _ril_lxc_tty).
        local dev_in="/dev/${RIL_TTY##*/}"
        cat > "$rc" <<RC
# osmo-rild.rc - lance le RIL sur le port AT du modem.
#   -l  la bibliotheque d implementation (celle de l image, qui parle AT)
#   --  ce qui suit est pour ELLE : -d <tty>, le modem adosse a oFono
# user root et non radio : le pseudo-terminal vient de l hote, ses droits ne
# suivent pas les uid d Android.
service vendor.ril-daemon ${RILD_BIN:-/vendor/bin/hw/rild} -l /vendor/lib64/libreference-ril.so -- -d $dev_in
    # [2026-09-06] class hal : les HAL demarrent AVANT le framework, et c est
    # exactement ce qu il faut. Le framework decide au demarrage s il y a une
    # radio ; s il ne trouve rien, il n instancie pas la telephonie et n y
    # revient jamais - com.android.phone ne redemarre meme plus. Le RIL doit
    # donc etre servi quand system_server se leve.
    # (Le « service declare mais pas servi » qu on a longtemps observe n etait
    # pas un probleme d ordre mais de threads : voir joinRpcThreadpool dans
    # tools/rild/osmo-rild.c.)
    class hal
    user root
    group radio cache inet misc audio log readproc wakelock
    capabilities BLOCK_SUSPEND NET_ADMIN NET_RAW
    # sa sortie part dans le journal noyau : c est le seul moyen de lire ce que
    # rild raconte avant que le framework ne le voie (dmesg cote hote).
    stdio_to_kmsg
RC
        chmod 644 "$rc"
        _ok "service init pose ($rc)"
    fi

    local mf="$OVL/vendor/etc/vintf/manifest/osmo-radio.xml"
    if ls "$OVL"/vendor/etc/vintf/manifest/*.xml >/dev/null 2>&1 && [ ! -f "$mf" ]; then
        _ok "manifest VINTF fourni par le pack"
    else
        mkdir -p "$(dirname "$mf")"
        cat > "$mf" <<'MF'
<manifest version="1.0" type="device">
    <hal format="hidl">
        <name>android.hardware.radio</name>
        <transport>hwbinder</transport>
        <fqname>@1.1::IRadio/slot1</fqname>
        <fqname>@1.1::ISap/slot1</fqname>
    </hal>
</manifest>
MF
        chmod 644 "$mf"
        _ok "manifest VINTF pose (IRadio@1.1)"
    fi

    # Sans ces permissions, le framework Android ne demarre meme pas la
    # telephonie : pas de composeur, pas de provider sms. Meme pose que
    # « telephony-on », qui sert quand on n a pas (encore) le pack.
    w_telephony_on >/dev/null
    _ok "permissions telephonie posees"
}

_ril_props() {
    # waydroid_base.prop est relu a chaque demarrage de session : c est la que
    # les proprietes du RIL doivent vivre, pas dans l image.
    local k v
    for kv in "rild.libpath=/vendor/lib64/libreference-ril.so" \
              "rild.libargs=-d $RIL_TTY" \
              "ro.telephony.default_network=9" \
              "ro.radio.noril=0" \
              "vendor.osmo.ril=1"; do
        k="${kv%%=*}"; v="${kv#*=}"
        if grep -q "^$k=" "$BASEPROP" 2>/dev/null; then
            sed -i "s|^$k=.*|$k=$v|" "$BASEPROP"
        else
            echo "$k=$v" >> "$BASEPROP"
        fi
    done
    _ok "proprietes RIL dans $(basename "$BASEPROP")"
}

_ril_lxc_tty() {
    # Le conteneur n a que les nodes que Waydroid lui donne ; le port AT du
    # modem n en fait pas partie.
    #
    # [2026-09-06] ATTENTION AU LIEN. /run/osmo-ril/at-pty est un LIEN vers un
    # /dev/pts/N qui change a chaque demarrage du modem : monter le lien ne
    # servirait a rien (LXC monterait le lien, pas le terminal). On resout donc
    # le lien MAINTENANT et on reecrit la ligne a chaque fois - c est aussi
    # pourquoi il faut relancer la session Waydroid apres avoir relance le
    # modem AT.
    if [ ! -f "$LXCCFG" ]; then
        _warn "pas de config LXC ($LXCCFG) - waydroid init d abord"
        return 1
    fi
    local real; real="$(readlink -f "$RIL_TTY" 2>/dev/null || echo "$RIL_TTY")"
    if [ ! -e "$real" ]; then
        _warn "port AT absent ($RIL_TTY) - lancer osmo-ril-atmodem.py d abord"
        return 1
    fi
    local dev_in="dev/${RIL_TTY##*/}"
    sed -i "\#^lxc.mount.entry = .* $dev_in #d" "$LXCCFG"
    printf '# osmo : le port AT du modem (oFono), pour le RIL\nlxc.mount.entry = %s %s none bind,create=file,optional 0 0\n' \
        "$real" "$dev_in" >> "$LXCCFG"
    _ok "$real monte dans le conteneur en /$dev_in"
}

w_telephony_on() {
    # [2026-09-06] MESURE SUR LE BANC. L image Waydroid MAINLINE n embarque
    # AUCUNE permission android.hardware.telephony : le framework demarre donc
    # sans telephonie, et « content://sms » n existe pas - c est ce qui faisait
    # repondre « Could not find provider: sms » a l insertion des SMS du pont,
    # AVANT toute histoire de compte Google. Poser le fichier de permissions
    # dans l overlay suffit a faire apparaitre les features (verifie : pm list
    # features les liste toutes), et com.android.providers.telephony,
    # com.android.phone et com.android.server.telecom sont bien installes et
    # actifs. MAIS l authority « sms » reste introuvable a l execution tant qu
    # il n y a pas de pile radio : le TelephonyProvider ne se publie pas sans
    # RIL. Cette commande est donc une MOITIE du chemin - l autre moitie est
    # ril-install (le pack Quectel) ou un vrai modem. Sans elle, meme le RIL
    # installe ne servirait a rien.
    _ril_need_root || return 1
    [ -d "$WAYLIB" ] || { _err "waydroid pas initialise"; return 1; }
    mkdir -p "$OVL/system/etc/permissions"
    cat > "$OVL/system/etc/permissions/osmo-telephony.xml" <<'PM'
<permissions>
    <feature name="android.hardware.telephony" />
    <feature name="android.hardware.telephony.gsm" />
    <feature name="android.hardware.telephony.radio.access" />
    <feature name="android.hardware.telephony.subscription" />
    <feature name="android.hardware.telephony.calling" />
    <feature name="android.hardware.telephony.messaging" />
    <feature name="android.hardware.telephony.data" />
</permissions>
PM
    chmod 644 "$OVL/system/etc/permissions/osmo-telephony.xml"
    _ok "permissions telephonie posees dans l overlay"
    _warn "relancer la session pour qu Android les relise :"
    _warn "  osmo-waydroid stop && osmo-waydroid start"
    _warn "le provider sms n apparaitra qu avec un RIL (ril-install)"
}

w_ril_install() {
    _ril_need_root || return 1
    local src="${1:-}"
    # [2026-09-06] SANS PACK QUECTEL, C EST POSSIBLE AUSSI. L image Waydroid a
    # deja libril.so (HIDL, contre android.hardware.radio@1.0/@1.1 - les seules
    # versions qu elle possede) et libreference-ril.so ; il ne lui manquait que
    # le binaire rild. tools/rild/ le compile (osmo-rild). Sans argument, on
    # installe celui-la ; avec un dossier, on prend le pack fourni.
    if [ -z "$src" ]; then
        local own="$REPO/tools/rild/osmo-rild"
        [ -x "$own" ] || {
            _err "osmo-rild pas compile : voir $REPO/tools/rild/build.sh"
            _warn "ou : osmo-waydroid ril-install <dossier du pack Quectel>"
            return 2
        }
        [ -d "$WAYLIB" ] || { _err "waydroid pas initialise"; return 1; }
        _say "installation du RIL maison"
        mkdir -p "$OVL/vendor/bin/hw"
        install -m755 "$own" "$OVL/vendor/bin/hw/osmo-rild"
        _ok "osmo-rild pose dans l overlay"
        RILD_BIN="/vendor/bin/hw/osmo-rild"
        _ril_completer
        _ril_props
        _ril_lxc_tty
        _say "relancer la session pour que l overlay soit repris :"
        _warn "  osmo-waydroid stop && osmo-waydroid start"
        return 0
    fi
    [ -d "$src" ] || {
        _err "usage: osmo-waydroid ril-install [dossier du pack Quectel]"
        _warn "sans argument : le RIL compile par tools/rild/build.sh"
        return 2
    }
    [ -d "$WAYLIB" ] || { _err "waydroid pas initialise (osmo-waydroid install)"; return 1; }

    _say "verification de l image Android"
    local rel; rel="$(waydroid shell -- getprop ro.build.version.release 2>/dev/null | tr -d '\r\n ')"
    case "$rel" in
        13) _ok "Android $rel (cible du pack)" ;;
        "") _warn "session arretee - verification d Android sautee" ;;
        *)  _warn "Android $rel : le pack vise Android 13, ca peut ne pas charger" ;;
    esac

    _ril_classer "$src"
    _ril_completer
    _ril_props
    _ril_lxc_tty
    _say "relancer la session pour que l overlay soit repris :"
    _warn "  osmo-waydroid stop && osmo-waydroid start"
}

w_ril_status() {
    _say "image"
    waydroid shell -- getprop ro.build.version.release 2>/dev/null | sed 's/^/        Android /'
    waydroid shell -- getprop gsm.version.ril-impl 2>/dev/null | sed 's/^/        RIL /'
    _say "fichiers dans l overlay"
    local f
    for f in vendor/bin/hw/rild vendor/lib64/libreference-ril.so \
             vendor/etc/init/osmo-rild.rc vendor/etc/vintf/manifest/osmo-radio.xml \
             system/etc/permissions/osmo-telephony.xml; do
        [ -e "$OVL/$f" ] && _ok "$f" || _warn "$f manquant"
    done
    _say "raccord oFono (le modem du banc)"
    if pgrep -f "[o]smo-phonesim-banc\.py" >/dev/null 2>&1; then
        _ok "modem du banc en marche (TCP 12345)"
    else
        _warn "modem du banc arrete - il est lance par start-direct.sh"
    fi
    /usr/bin/python3 - <<'PYST' 2>/dev/null || _warn "oFono ne repond pas"
from gi.repository import Gio, GLib
c = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
try:
    pr = dict(c.call_sync("org.ofono", "/osmo", "org.ofono.Modem", "GetProperties",
                          None, None, Gio.DBusCallFlags.NONE, 5000, None).unpack()[0])
except GLib.Error:
    print("        modem /osmo absent d oFono")
else:
    ifs = list(pr.get("Interfaces", []))
    print("        /osmo : Powered=%s Online=%s" % (pr.get("Powered"), pr.get("Online")))
    print("        interfaces : %s" % ", ".join(i.rsplit(".", 1)[-1] for i in ifs))
    if "org.ofono.NetworkRegistration" in ifs:
        n = dict(c.call_sync("org.ofono", "/osmo", "org.ofono.NetworkRegistration",
                             "GetProperties", None, None, Gio.DBusCallFlags.NONE,
                             5000, None).unpack()[0])
        print("        reseau : %s %s (%s-%s)" % (n.get("Status"), n.get("Name"),
                                                  n.get("MobileCountryCode"),
                                                  n.get("MobileNetworkCode")))
PYST
    _say "pty pour rild"
    if [ -e /run/osmo-ril/at-pty ]; then
        _ok "/run/osmo-ril/at-pty -> $(readlink -f /run/osmo-ril/at-pty)"
    else
        _warn "absent (osmo-ril-atmodem.py arrete)"
    fi

    _say "port AT pour rild"
    [ -e "$RIL_TTY" ] && _ok "$RIL_TTY present" || _warn "$RIL_TTY absent"
    _say "tty dans le conteneur"
    grep -q "dev/${RIL_TTY##*/} " "$LXCCFG" 2>/dev/null && _ok "passe" || _warn "pas passe"
    _say "radio dans Android"
    waydroid shell -- sh -c 'getprop | grep -E "gsm\.(sim|network)" | head -n 5' 2>/dev/null | sed 's/^/        /'
}

# ── ETAT ────────────────────────────────────────────────────────────────────
w_status() {
    _say "waydroid"
    if command -v waydroid >/dev/null 2>&1; then
        waydroid status 2>&1 | sed 's/^/        /'
    else
        _err "absent"
    fi
    _say "ofono"
    if pgrep -x ofonod >/dev/null 2>&1; then
        _ok "ofonod en marche"
        [ -x /usr/share/ofono/scripts/list-modems ] && \
            /usr/share/ofono/scripts/list-modems 2>/dev/null | head -n 12 | sed 's/^/        /'
    else
        _warn "ofonod arrete"
    fi
    _say "pont"
    if pgrep -f "[o]smo-ofono-bridge\.py" >/dev/null 2>&1; then
        _ok "en marche"
        [ -f "$STATE" ] && sed 's/^/        /' "$STATE" && echo
    else
        _warn "arrete"
    fi
    _say "data"
    local dev; dev="$(_data_iface || true)"
    [ -n "${dev:-}" ] && _ok "interface $dev" || _warn "pas encore en service (attendu : le banc n a pas de PDP)"
}

w_stop() {
    pkill -f osmo-ofono-bridge.py 2>/dev/null && _ok "pont arrete" || _warn "pont deja arrete"
    waydroid session stop >/dev/null 2>&1 && _ok "session arretee" || _warn "session deja arretee"
    $SUDO systemctl stop waydroid-container >/dev/null 2>&1 && _ok "conteneur arrete"
}

case "${1:-status}" in
    install)     w_install ;;
    ril-install) shift; w_ril_install "${1:-}" ;;
    ril-status)  w_ril_status ;;
    telephony-on) w_telephony_on ;;
    app-install) shift; w_app_install "${1:-}" ;;
    fdroid)      w_fdroid ;;
    sms-app)     w_sms_app ;;
    no-contacts) w_no_contacts ;;
    phone-app)   w_phone_app ;;
    dock)        w_dock ;;
    start)     w_start ;;
    phone)     shift; w_phone "${1:-}" ;;
    bridge)    w_bridge ;;
    up)        w_start && w_bridge ;;
    data-up)   w_data_up ;;
    data-down) w_data_down ;;
    status)    w_status ;;
    stop)      w_stop ;;
    *) echo "usage: $(basename "$0") {install|start|phone [WxH]|bridge|up|ril-install <pack>|ril-status|telephony-on|app-install <apk>|fdroid|sms-app|no-contacts|phone-app|dock|data-up|data-down|status|stop}"; exit 2 ;;
esac

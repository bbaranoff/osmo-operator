# 13-adresses.sh - partie de start.sh (lignes 2944-3312 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
if [ "$DRY" -eq 0 ] && [ "${CALYPSO_NO_AUTOSTOP:-0}" != 1 ]; then
    say_begin "Arret de la pile avant demarrage"
    banc_dsp_arreter >/dev/null 2>&1 || true
    banc_dsp_arreter_instances
    bash "$RUN_SH" --stop --profile "$CALYPSO_PROFILE" >/dev/null 2>&1 || true
    declare -F purge_sessions_tmux >/dev/null && purge_sessions_tmux
    if [ "${CALYPSO_STOP_KILL_PYTHON:-1}" != 0 ]; then
        killall_python -TERM || true
    fi
    # SAP : les serveurs softSIM (demo_server.rb) et leur socket. CALYPSO_STOP_KILL_SOFTSIM=0 le desactive.
    if [ "${CALYPSO_STOP_KILL_SOFTSIM:-1}" != 0 ]; then
        kill_softsim || true
    fi
    say_end " OK " "$C_OK" "Arret de la pile avant demarrage"
fi

# --- 7sexies. Socket PCU (BTS <-> osmo-pcu) ------------------------------------
# Les sockets d'un run precedent restent sur le disque ; le PCU, lui, doit
# trouver le socket du BTS principal (/tmp/pcu_bts). Le harnais supprime les
# orphelins avant le lancement et affiche l'etat, pour qu'un GPRS muet se lise.
PCU_SOCK_SH="$HERE/network/pcu-socket.sh"
if [ "$DRY" -eq 0 ] && [ -r "$PCU_SOCK_SH" ]; then
    say_begin "Socket PCU"
    if bash "$PCU_SOCK_SH" --fix > "${LOG_DIR:-/tmp}/pcu-socket.log" 2>&1; then
        say_end " OK " "$C_OK" "Socket PCU" "voir ${LOG_DIR:-/tmp}/pcu-socket.log"
    else
        say_end " KO " "$C_KO" "Socket PCU" "suppression d'un orphelin impossible - voir ${LOG_DIR:-/tmp}/pcu-socket.log"
    fi
fi

# --- 7septies. Sortie Internet de l'APN (NAT apn0 -> carte qui route) ----------
APN_NAT_SH="$HERE/network/apn-nat.sh"
if [ "$DRY" -eq 0 ] && [ -r "$APN_NAT_SH" ]; then
    say_begin "Sortie Internet APN (NAT)"
    if bash "$APN_NAT_SH" > "${LOG_DIR:-/tmp}/apn-nat.log" 2>&1; then
        say_end " OK " "$C_OK" "Sortie Internet APN" "voir ${LOG_DIR:-/tmp}/apn-nat.log"
    else
        say_end " KO " "$C_KO" "Sortie Internet APN" "voir ${LOG_DIR:-/tmp}/apn-nat.log"
    fi
fi

# --- 8. lancement : exec run.sh -----------------------------------------------
# ── LES ADRESSES QUE LES CONFIGS RECLAMENT DOIVENT EXISTER ──────────────────
# Un demon qui se lie a une adresse absente ne demarre pas, et il le dit dans
# SON journal, pas dans le notre :
#     osmo-ggsn : « gtp bind-ip 192.168.2.10 » -> adresse introuvable localement
#     osmo-sgsn : « listen 192.168.2.10 23000 » -> idem
# Ces adresses viennent du generateur de gabarits (op_private_ip), pas du
# reseau : rien ne les pose. Elles etaient figees dans 20-dhcp.network cote ISO,
# donc absentes de toute machine montee autrement - et la panne se lisait comme
# un defaut de coeur paquet.
#
# osmo-ip-plan.sh les EXTRAIT des configs plutot que de les recalculer (le plan
# peut venir d'un autre generateur que le notre), choisit la carte qui fournit
# reellement Internet, et retombe sur la boucle locale quand aucune ne mene
# nulle part. Il ne fait rien dans une image de ce depot (OSMO_IMAGE=1) : la,
# c'est start-docker.sh / compose qui adresse. Un conteneur quelconque est traite en natif.
if [ "$ACTION" = "start" ] && [ "$DRY" -ne 1 ]; then
    IPPLAN="$HERE/network/osmo-ip-plan.sh"
    if [ -r "$IPPLAN" ]; then
        say_begin "Adresses privees du noeud"
        _ipout="$(OSMOCOM_CFG="${OSMOCOM_CFG:-/etc/osmocom}" \
                  OSMO_WAN_NODE="${NODE_ID:-${OSMO_WAN_NODE:-}}" \
                  bash "$IPPLAN" --apply 2>&1)" || true
        say_end " OK " "$C_OK" "Adresses privees du noeud" \
            "$(printf '%s' "$_ipout" | tail -1 | sed 's/^osmo-ip-plan : //')"
    fi
fi

# ── LE TABLEAU DE BORD REDEMARRE AVEC LE BANC ────────────────────────────────
# [2026-09-09] GESTE SYMETRIQUE DE CELUI DE `stop)` (voir plus haut, ~l.1455).
# Depuis le 04/09 le chemin d arret coupe osmo-egprs-web.service, pour ne plus
# laisser un :8080 qui repond devant une pile morte. Mais RIEN ne le rallumait :
# l unite est PartOf=osmo-banc.service, or le lancement direct ne passe pas par
# osmo-banc. Consequence mesuree le 09/09 : apres un --stop suivi d un
# demarrage direct, le dashboard restait eteint pour de bon.
# Ce n est pas qu un tableau de bord qui manque : c est LUI qui sert /psd, donc
# tools/osmo-fft-snap.py interrogeait en boucle un port muet et la FFT du fond
# d ecran ne se mettait plus a jour. Le symptome ne designait pas sa cause.
# (fft-web/fft_web.py, lui, sert le 8081 : c est un autre serveur, il n est pas
# concerne par ce bloc.)
# --no-block, comme a l arret : on ne se bloque pas sur systemd. `restart` et
# pas `start` : si une instance survit d un run precedent, on la reprend au lieu
# de la laisser servir l etat d avant.
# CALYPSO_NO_DASHBOARD=1 desactive ce demarrage.
if [ "$ACTION" = "start" ] && [ "$DRY" -ne 1 ] && [ "${CALYPSO_NO_DASHBOARD:-0}" != 1 ]; then
    say_begin "Tableau de bord (:8080)"
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        if systemctl --no-block restart osmo-egprs-web.service 2>/dev/null; then
            say_end " OK " "$C_OK" "Tableau de bord (:8080)" "osmo-egprs-web.service"
        else
            say_end " -- " "$C_KO" "Tableau de bord (:8080)" "unite absente ou refusee"
        fi
    elif [ -r /opt/GSM/osmo-egprs-web/server.js ] && command -v node >/dev/null 2>&1; then
        # Hors systemd (conteneur) : lancement direct, comme le fait osmo-launch.sh.
        pkill -f "osmo-egprs-web/server.js" 2>/dev/null || true
        ( cd /opt/GSM/osmo-egprs-web && setsid node server.js \
            >>"${LOG_DIR:-/tmp}/web-dashboard.log" 2>&1 </dev/null & )
        say_end " OK " "$C_OK" "Tableau de bord (:8080)" "node server.js"
    else
        say_end " -- " "$C_KO" "Tableau de bord (:8080)" "ni systemd ni node/server.js"
    fi
fi

# ── LA FICHE DU NOEUD : LE RESULTAT DU RUN ───────────────────────────────────
# [2026-09-04] /etc/osmocom/mynode<N>.conf (network/node-conf.sh) : ce qu'un
# autre noeud doit savoir pour joindre celui-ci (--wan mynode<N>.conf). Ecrite
# ici, une fois l'identite SS7, l'adresse et l'indicatif definitivement poses.
# start-multi.sh la reecrit quand les conteneurs sont montes (--gen-conf).
if [ "$ACTION" = "start" ] && [ "$DRY" -ne 1 ]; then
    . "$HERE/network/wan-nodes.sh" 2>/dev/null
    . "$HERE/network/node-conf.sh" 2>/dev/null
    _nc_node="${NODE_ID:-${WAN_NODE_ID:-}}"; [[ "${_nc_node:-0}" =~ ^[1-9]$ ]] || _nc_node=1
    [ "${WAN_NODE_COUNT:-0}" -gt 0 ] || wan_nodes_load "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" 2>/dev/null || true
    _nc_out="$(node_conf_path "$_nc_node")"
    if node_conf_write "$_nc_out" "$_nc_node" "${NODE_OP:-1}" "${HUB_IP:-${OSMO_HUB_IP:-}}" 2>/dev/null; then
        say_end " OK " "$C_OK" "Fiche du noeud $_nc_node" "$_nc_out  (pour un autre noeud : --wan $(basename "$_nc_out"))"
    else
        say_end " -- " "$C_DIM" "Fiche du noeud" "non ecrite ($_nc_out)"
    fi
fi

# ── LE RACCORD MOBILE : oFONO = LE MODEM DU BANC ────────────────────────────
# [2026-09-07] Le telephone du banc - la VM postmarketOS/Phosh - est le MEME
# abonne que le mobile osmocom-bb : 100101. Son ModemManager ne parle qu a un
# modem AT ; ce banc n a pas de dongle, le modem est donc ecrit ici. La VM se
# branche directement sur osmo-phonesim-banc.py (mode --connect, cf.
# tools/osmo-pmos.sh) ; oFono, lui, reste utile a l hote - il donne osmo-call
# et osmo-sms-send, et un second modem AT pour la mise au point.
#
#   tools/osmo-phonesim-banc.py   le modem AT du banc, cote oFono (TCP 12345,
#                                 plugin phonesim). Il lit le reseau sur le VTY
#                                 d osmo-bsc, envoie les SMS par le VTY
#                                 d osmo-msc, passe les appels par Asterisk, et
#                                 recoit les SMS en ESME SMPP (port 2775).
#   tools/osmo-ril-atmodem.py     le modem AT que rild consommera, adosse a
#                                 oFono. Il publie son pty dans
#                                 /run/osmo-ril/at-pty.
#
# Rien de tout ca n est indispensable au banc : si oFono manque, on le dit et on
# continue. Le banc doit demarrer meme sans le telephone Android.
if [ "$ACTION" = "start" ] && [ "$DRY" -ne 1 ] && [ "${OSMO_RACCORD_MOBILE:-1}" = "1" ]; then
    say_begin "Raccord mobile (oFono)"
    _rm_detail=""
    if ! command -v ofonod >/dev/null 2>&1; then
        say_end " -- " "$C_DIM" "Raccord mobile (oFono)" "ofono absent - ignore"
    else
        # 1. oFono doit savoir ou trouver le modem du banc.
        if ! grep -q '^\[osmo\]' /etc/ofono/phonesim.conf 2>/dev/null; then
            printf '\n[osmo]\nAddress=127.0.0.1\nPort=12345\n' >> /etc/ofono/phonesim.conf
            _rm_detail="phonesim.conf pose"
        fi
        # 2. le compte AMI : c est par lui que le modem fait naitre les appels
        #    (la CLI d Asterisk n a pas « channel originate » ici, le module
        #    res_clioriginate n est pas charge - modules.conf est en autoload=no).
        if [ -d /etc/asterisk/manager.d ] && [ ! -f /etc/asterisk/manager.d/osmo.conf ]; then
            install -m640 "$HERE/configs/manager-osmo.conf" \
                /etc/asterisk/manager.d/osmo.conf 2>/dev/null && \
                { chown asterisk:asterisk /etc/asterisk/manager.d/osmo.conf 2>/dev/null || true; }
            asterisk -rx "manager reload" >/dev/null 2>&1 || true
            _rm_detail="${_rm_detail:+$_rm_detail, }compte AMI pose"
        fi
        # 3. le modem du banc, PUIS oFono (l ordre compte : ofonod cherche le
        #    modem au demarrage et n y revient pas de lui-meme).
        pgrep -f "$HERE/tools/osmo-phonesim-banc.py" >/dev/null 2>&1 || \
        # [2026-09-22] LANCEMENT HORS TABLE DES JOBS.
        # `setsid` detache la SESSION, pas le job : bash gardait ces aides dans
        # sa table et annoncait leur mort par un
        #     ./start-native.sh: line NNNN: <pid> Killed setsid ...
        # asynchrone, qui tombait par-dessus le prompt apres un --stop
        # (killall_python les tue). `disown` n'y suffit pas de facon fiable en
        # shell non interactif. Le sous-shell, lui, est sur : bash ne voit que
        # LUI comme job, il rend la main tout de suite avec 0, et le petit-fils
        # est adopte par init -- plus personne ne le surveille ni ne le signale.
        # `</dev/null` en prime : aucune de ces aides ne lit le terminal, et
        # sans cela elles restent rattachees a son entree.
        # [2026-09-22] LA VTY DU MOBILE N'EST PAS TOUJOURS 4247.
        # osmo-phonesim-banc.py retombe sur OSMO_MOB_VTY_PORT=4247, la valeur de
        # /root/.osmocom/bb/mobile.cfg. En --dsp le mobile qui tourne est celui
        # du banc (mobile_pont.cfg, VTY 4347) : le modem parlait a un port que
        # personne n'ecoute, donc pas de reseau, pas d'appel, pas de SMS par
        # oFono -- sans la moindre erreur, il se contentait de ne jamais voir le
        # mobile. On lui passe le port reellement lie, lu dans le fichier.
            ( setsid env OSMO_MOB_VTY_PORT="${_ms1_vty:-4247}" \
                  "$HERE/tools/osmo-phonesim-banc.py" \
                  </dev/null >>/tmp/osmo-phonesim.log 2>&1 & )
        sleep 1
        systemctl restart ofono >/dev/null 2>&1 || true
        sleep 3
        # 4. allumer le modem : oFono le laisse eteint tant qu on ne demande rien.
        /usr/bin/python3 - <<'PYON' >/dev/null 2>&1 || true
from gi.repository import Gio, GLib
import time
c = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
for prop in ("Powered", "Online"):
    try:
        c.call_sync("org.ofono", "/osmo", "org.ofono.Modem", "SetProperty",
                    GLib.Variant("(sv)", (prop, GLib.Variant("b", True))),
                    None, Gio.DBusCallFlags.NONE, 25000, None)
    except GLib.Error:
        pass
    time.sleep(2)
PYON
        # 5. le modem AT virtuel (le pty que consomme un RIL, ou un modem de
        #    mise au point pour tools/at-cmd.py).
        #    /usr/bin/python3 EN DUR, et non le shebang « env python3 ».
        #    [2026-09-07] Releve sur le banc : ce programme ne demarrait plus
        #    du tout depuis des heures -
        #        File ".../osmo-ril-atmodem.py", line 43, in <module>
        #          from gi.repository import Gio, GLib
        #        ModuleNotFoundError: No module named 'gi'
        #    - et le seul endroit ou ca se voyait etait /tmp/osmo-ril.log, que
        #    personne ne lit. La cause n est pas le paquet : PyGObject est bien
        #    la, cote SYSTEME. C est le PATH du banc, qui place le venv
        #    (/root/.env/bin) en tete : « env python3 » y trouve un interprete
        #    qui n a pas les liaisons GObject, et jamais celui du systeme. Meme
        #    raison que le bloc PYON ci-dessus, qui appelle deja /usr/bin/python3.
        pgrep -f "$HERE/tools/osmo-ril-atmodem.py" >/dev/null 2>&1 || \
        # [2026-09-22] LANCEMENT HORS TABLE DES JOBS.
        # `setsid` detache la SESSION, pas le job : bash gardait ces aides dans
        # sa table et annoncait leur mort par un
        #     ./start-native.sh: line NNNN: <pid> Killed setsid ...
        # asynchrone, qui tombait par-dessus le prompt apres un --stop
        # (killall_python les tue). `disown` n'y suffit pas de facon fiable en
        # shell non interactif. Le sous-shell, lui, est sur : bash ne voit que
        # LUI comme job, il rend la main tout de suite avec 0, et le petit-fils
        # est adopte par init -- plus personne ne le surveille ni ne le signale.
        # `</dev/null` en prime : aucune de ces aides ne lit le terminal, et
        # sans cela elles restent rattachees a son entree.
            ( setsid /usr/bin/python3 "$HERE/tools/osmo-ril-atmodem.py" \
                  </dev/null >>/tmp/osmo-ril.log 2>&1 & )
        sleep 1
        if pgrep -f "$HERE/tools/osmo-phonesim-banc.py" >/dev/null 2>&1; then
            say_end " OK " "$C_OK" "Raccord mobile (oFono)" \
                "modem /osmo${_rm_detail:+ - $_rm_detail} ; pty RIL : /run/osmo-ril/at-pty"
        else
            say_end " -- " "$C_DIM" "Raccord mobile (oFono)" "modem du banc non demarre (cf. /tmp/osmo-phonesim.log)"
        fi
    fi
fi

# ── LE BANC DSP : REGLAGES MESURES, PUIS PASSAGE DE MAIN ───────────────────
# Les valeurs viennent du banc, pas d'un choix de style (c54x_exe/run_real.sh
# les porte depuis le 2026-09-21, run.sh les documente une a une) :
#   INSNS=200000             plafond d'instructions par trame (voir plus bas)
#   LOCKSTEP=1               QEMU n'avance la trame que quand le DSP a fini la
#                            precedente ; sans lui QEMU saute 3 trames sur 4
#   IQ=none                  aucune cellule synthetique : les bursts viennent
#                            de la vraie BTS, par pont.py
#   CALYPSO_BSP_STREAM=1     un burst TS0 par trame, dans l'ordre des FN
#   CALYPSO_RHEA_DMA_XFER=1  sans lui la page API n'est jamais remplie : pas de
#                            SB, pas de BCCH, pas de SI
# Tout reste surchargeable : on ne pose que ce que l'operateur n'a pas dit.

# ── SAP : LA SIM SERVIE AU MOBILE SUR LE SOCKET SAP (--sap) ─────────────────
# Serveur demo_server.rb du depot softSIM (/opt/GSM/softsim, shim Ruby 3.2+ :
# File.exists?, Fixnum), lance AVANT la pile : le mobile (sim sap) s y connecte
# au demarrage et y reste (patch 0002 : le serveur sert le client suivant apres
# une deconnexion, donc un redemarrage de la baseband ne demande rien).
#   type pcsc : la carte du lecteur PC/SC (HID Omnikey 6121, sysmoISIM-SJA5 ;
#               gem smartcard). La carte doit porter l IMSI/Ki du MS#1 (ou son
#               abonne doit etre dans le HLR) : tools/osmo-sim.sh verifier.
#   type sim  : la SIM logicielle sim-op1.xml, regeneree a chaque lancement
#               (IMSI du MS#1 ; COMP128v1 avec SOFTSIM_KI = Ki du MS#1, patch 0001).
# En DSP, le MS#1 qui tourne est celui de c54x_exe (mobile_pont.cfg, sim test) :
# on en derive $BB_DIR/mobile_pont_sap.cfg (sim sap, sap-socket) et le banc le
# recoit par MOBILE_CFG (SAP_DSP_MOBILE_CFG, a lui seul). Variables :
# SOFTSIM_DIR, SAP_SOCK, SAP_TYPE, SAP_FILE, SAP_LOG, SAP_VERBOSITY, SOFTSIM_KI.
# le python qui a pyscard : celui du venv pySim (le PATH de root commence par
# /root/.env, le venv du pont, sans pyscard), sinon celui du systeme
sap_python() {
    local p="${PYSIM_VENV:-/opt/GSM/pysim-venv}/bin/python3"
    [ -x "$p" ] || p=/usr/bin/python3
    printf '%s' "$p"
}
sap_carte_presente() {
    "$(sap_python)" - <<'PYSC' 2>/dev/null
import sys
try:
    from smartcard.System import readers
except Exception:
    sys.exit(2)
for r in readers():
    try:
        c = r.createConnection(); c.connect(); c.disconnect(); sys.exit(0)
    except Exception:
        pass
sys.exit(1)
PYSC
}
sap_lecteur() {
    "$(sap_python)" -c 'from smartcard.System import readers; print(str(readers()[0]))' 2>/dev/null | sed "s/ \[.*//"
}
SAP_DSP_MOBILE_CFG=""
start_sap() {
    [ "${SAP_MODE:-0}" = 1 ] || return 0
    local sdir="${SOFTSIM_DIR:-/opt/GSM/softsim}" sock="${SAP_SOCK:-/tmp/osmocom_sap}"
    local log="${SAP_LOG:-/tmp/osmo-sap.log}" type="${SAP_TYPE:-auto}" file="" detail=""
    local shim=/usr/local/share/softsim/ruby_compat.rb
    [ -f "$shim" ] || shim="$HERE/tools/softsim/ruby_compat.rb"
    say_begin "SIM via SAP"
    if [ ! -f "$sdir/src/demo_server.rb" ] || ! command -v ruby >/dev/null 2>&1; then
        say_end " KO " "$C_KO" "SIM via SAP" "softSIM ou ruby absent ($sdir) : sudo $HERE/tools/osmo-sim-install.sh"
        return 1
    fi
    if [ "$type" = auto ]; then
        if sap_carte_presente; then type=pcsc; else type=sim; fi
    fi
    case "$type" in
        pcsc)
            if ! sap_carte_presente; then
                say_end " KO " "$C_KO" "SIM via SAP" "aucune carte dans un lecteur PC/SC (pcscd actif ? Omnikey branche ? tools/osmo-sim.sh lecteur)"
                return 1
            fi
            if ! ruby -e 'require "smartcard"' >/dev/null 2>&1; then
                say_end " KO " "$C_KO" "SIM via SAP" "gem smartcard absent : sudo $HERE/tools/osmo-sim-install.sh"
                return 1
            fi
            detail="carte du lecteur $(sap_lecteur)" ;;
        sim)
            file="${SAP_FILE:-$sdir/src/sim-op1.xml}"
            # le Ki du MS#1, celui que 21-abonnes-hlr met dans le HLR (COMP128v1)
            export SOFTSIM_KI="${SOFTSIM_KI:-$(ms_ki 1 | tr -d ' ')}"
            detail="SIM logicielle $file (IMSI $(ms_imsi 1))" ;;
        *)
            say_end " KO " "$C_KO" "SIM via SAP" "SAP_TYPE=$type inconnu (pcsc, sim, auto)"
            return 1 ;;
    esac
    # En DSP : la copie de mobile_pont.cfg en « sim sap », pour le banc seul.
    if [ "${DSP_BANC:-0}" = 1 ]; then
        local _src="${MOBILE_CFG:-$(dirname "$BANC_DSP")/mobile_pont.cfg}" _dst="$BB_DIR/mobile_pont_sap.cfg"
        if [ -r "$_src" ]; then
            sed -e "s#^\([[:space:]]*\)sim \(test\|reader\)\$#\1sim sap#" \
                -e "s|^\([[:space:]]*\)sap-socket .*|\1sap-socket $sock|" \
                -e "s|^\([[:space:]]*\)stick [0-9]*\$|\1stick ${PLAN_ARFCN:-${ARFCN:-1}}|" "$_src" > "$_dst.tmp" \
                && mv -f "$_dst.tmp" "$_dst"
            grep -q "^[[:space:]]*sap-socket " "$_dst" \
                || sed -i "s|^\([[:space:]]*\)layer2-socket .*|&\n\1sap-socket $sock|" "$_dst"
            SAP_DSP_MOBILE_CFG="$_dst"
            detail="$detail ; MS#1 $_dst"
        else
            say_end " KO " "$C_KO" "SIM via SAP" "config du MS#1 du banc DSP illisible : $_src"
            return 1
        fi
    fi
    if [ $DRY -eq 1 ]; then
        say_end " -- " "$C_DIM" "SIM via SAP" "dry-run : type $type, ruby -r$shim demo_server.rb --unix $sock${file:+ --file $file} ($detail)"
        return 0
    fi
    # sim-op1.xml est regenere a chaque lancement : le serveur le reecrit a chaque
    # deconnexion du client, et un fichier ancien garderait l ICCID / le PLMN d avant.
    if [ "$type" = sim ] && [ -z "${SAP_FILE:-}" ] && [ -f "$sdir/src/sim.xml" ] && [ -f "$HERE/tools/softsim/make_sim_op1.py" ]; then
        python3 "$HERE/tools/softsim/make_sim_op1.py" "$sdir/src/sim.xml" "$sdir/src/sim-op1.xml" \
            --imsi "$(ms_imsi 1)" >/dev/null 2>&1 || true
        [ -f "$file" ] || file="$sdir/src/sim.xml"
    fi
    rm -f "$sock"
    local args=(--type "$type" --socket unix --unix "$sock" --verbosity "${SAP_VERBOSITY:-3}")
    [ "$type" = sim ] && args+=(--file "$file")
    ( cd "$sdir/src" && nohup ruby -r"$shim" demo_server.rb "${args[@]}" >"$log" 2>&1 & )
    for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.2; done
    if [ -S "$sock" ]; then
        say_end " OK " "$C_OK" "SIM via SAP" "type $type : $detail ; socket $sock, journal $log"
    else
        say_end " KO " "$C_KO" "SIM via SAP" "pas de socket $sock : voir $log"
        return 1
    fi
}
start_sap || { echo "SAP demande (--sap) mais non lance" >&2; exit 1; }


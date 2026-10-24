# 06-banc-dsp-menu.sh - partie de start.sh (lignes 844-1511 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
banc_dsp() {
    MODE=dsp bash "$BANC_DSP" "$@"
}
banc_dsp_arreter() {
    [ -x "$BANC_DSP" ] || return 0
    banc_dsp --stop "$@"
}
# [2026-10-20 22:35] TOUTES les instances Calypso (INSTANCE=N : /tmp/c54x-pontN, le mobile par l'air = 2,
# le telephone 2 du TRX = 3, les essais = 4...). run.sh --stop (instance 1) entraine deja 2 et 3 ; ceci
# ramasse le reste, puis les orphelins par leur nom (c54x_exe, QEMU Calypso, transceiver) : un c54x_exe
# de l'instance 2 vieux de 19 minutes etait encore la apres deux relances.
# [2026-10-21] banc-rssi (instance 4) et Magnetite (/dev/shm/magnetite, QEMU « -M calypso » comme le banc)
# sont SEPARES : on n'arrete ni l'un ni l'autre ici. Les pid proteges sont lus dans leurs fichiers pid,
# les pkill ci-dessous passent par ce filtre au lieu de tuer tout ce qui matche.
banc_dsp_pids_proteges() {
    cat /tmp/c54x-pont4/*.pid /dev/shm/magnetite/*.pid 2>/dev/null | tr '\n' ' '
}
banc_dsp_tuer_sauf_proteges() {
    local nom p garde
    garde=" $(banc_dsp_pids_proteges) "
    # pgrep -x : nom du processus (comm), pas la ligne de commande : un shell qui contient ce texte n'est pas vise
    for nom in "$@"; do
        for p in $(pgrep -x -- "$nom" 2>/dev/null); do
            case "$garde" in *" $p "*) ;; *) kill "$p" 2>/dev/null || true ;; esac
        done
    done
}
banc_dsp_arreter_instances() {
    local d n
    for d in /tmp/c54x-pont[0-9]*; do
        [ -d "$d" ] || continue
        n="${d#/tmp/c54x-pont}"
        [ "$n" = 4 ] && continue                     # banc-rssi : arret par banc-rssi-stop seulement
        ls "$d"/*.pid >/dev/null 2>&1 || continue
        [ -x "$BANC_DSP" ] && INSTANCE="$n" AIR=1 OSMO_TRX=0 MODE=dsp bash "$BANC_DSP" --stop >/dev/null 2>&1 || true
        rm -f "$d"/*.pid
    done
    banc_dsp_tuer_sauf_proteges 'c54x_exe --arm' 'qemu-system-arm -M calypso' 'transceiver -l /tmp/osmocom_l2'
    for k in /tmp/calypso_keys[0-9]*.sock /tmp/osmocom_l2_[0-9]*; do
        case "$k" in /tmp/calypso_keys4.sock|/tmp/osmocom_l2_4) continue ;; esac
        rm -f "$k" 2>/dev/null
    done
    return 0
}

# --- 2b. lanceur C de QEMU (qosmo) --------------------------------------------
# [2026-09-03] QEMU n'est plus appele directement par 40-qemu.sh : l'arbre qosmo
# porte un lanceur C, tools/qosmo-launch, installe dans /usr/local/bin/qosmo. Il fixe les defauts qui marchent (machine calypso + ROMs DSP,
# -cpu arm946, -gdb tcp::1234, -serial pty x2, -monitor unix:$RUN_DIR/...),
# lit l1s/last_rach dans l'ELF, et publie des liens stables vers les pty
# ($RUN_DIR/modem.pty pour osmocon, $RUN_DIR/irda.pty). Options : --bind,
# --trx-port, --iq-tee, --l1ctl, --monitor, --gdb (voir `qosmo --help`).
# Le nom est passe a run.sh par QOSMO_LAUNCHER ; s'il manque, 40-qemu.sh
# retombe sur la ligne qemu-system-arm historique - on le dit, sans bloquer.
say_begin "Lanceur QEMU"
: "${QOSMO_LAUNCHER:=/usr/local/bin/${CALYPSO_FORK:-qosmo}}"
export QOSMO_LAUNCHER
if [ -x "$QOSMO_LAUNCHER" ]; then
    say_end " OK " "$C_OK" "Lanceur QEMU" "$QOSMO_LAUNCHER ($("$QOSMO_LAUNCHER" -V 2>/dev/null | head -1))"
elif [ -f "$RUN_ROOT/tools/qosmo-launch/qosmo-launch.c" ] && command -v gcc >/dev/null 2>&1 \
     && make -s -C "$RUN_ROOT/tools/qosmo-launch" install >/dev/null 2>&1 && [ -x "$QOSMO_LAUNCHER" ]; then
    say_end " OK " "$C_OK" "Lanceur QEMU" "$QOSMO_LAUNCHER (compile a l'instant depuis $RUN_ROOT/tools/qosmo-launch)"
else
    say_end "WARN" "$C_SK" "Lanceur QEMU" "$QOSMO_LAUNCHER absent : 40-qemu.sh appellera qemu-system-arm directement"
    printf '       %s-> make -C %s/tools/qosmo-launch install%s\n' "$C_DIM" "$RUN_ROOT" "$C_Z"
fi
# ══ --menu : on DEMANDE, au lieu de deviner ════════════════════════════════
# Le lanceur resout tout seul le profil, le noeud, l'inter-STP, le WAN. C'est ce
# qu'il faut pour une ISO qui demarre sans personne devant. Mais devant un banc,
# la meme resolution silencieuse oblige a relire le script pour savoir ce qui a
# ete choisi - et a relancer avec les bonnes options quand ce n'etait pas ca.
#
# Ce menu ne CHANGE aucune regle : il PRE-REMPLIT chaque question avec la valeur
# que le lanceur aurait prise seul, et n'ecrit que ce que l'operateur modifie.
# Valider tout sans rien toucher donne donc exactement le lancement par defaut.
#
# Il s'efface de lui-meme quand personne ne peut repondre (pas de terminal,
# --dry-run, NO_MENU=1 que start-docker.sh pose devant un conteneur) : une question
# sans lecteur, c'est un lancement qui se fige sans le dire.
menu_interactif() {
    [ "${MENU_MODE:-0}" -eq 1 ] || return 0
    [ "${NO_MENU:-0}" = "1" ] && return 0
    [ "$DRY" -eq 1 ] && return 0
    [ -t 0 ] || { printf "  %smenu%s       ignore : pas de terminal\n" "${C_DIM:-}" "${C_Z:-}"; return 0; }

    local has_wt=0
    command -v whiptail >/dev/null 2>&1 && has_wt=1

    # Une question, une valeur par defaut, une reponse. Sans whiptail on
    # retombe sur read : une ISO minimale n'a pas toujours newt.
    _ask() {   # $1 = titre  $2 = question  $3 = defaut
        local rep
        if [ "$has_wt" -eq 1 ]; then
            rep="$(whiptail --title "$1" --inputbox "$2" 11 70 "$3" 3>&1 1>&2 2>&3)" || rep="$3"
        else
            printf "  %s [%s] : " "$2" "$3" >&2
            read -r rep </dev/tty || rep=""
        fi
        printf "%s" "${rep:-$3}"
    }
    _yesno() { # $1 = titre  $2 = question  $3 = defaut (0=oui 1=non)
        if [ "$has_wt" -eq 1 ]; then
            if [ "$3" -eq 0 ]; then whiptail --title "$1" --yesno "$2" 10 70; else
                whiptail --title "$1" --defaultno --yesno "$2" 10 70; fi
            return $?
        fi
        local d="o" rep
        [ "$3" -eq 0 ] || d="n"
        printf "  %s [%s] : " "$2" "$d" >&2
        read -r rep </dev/tty || rep=""
        case "${rep:-$d}" in [oOyY]*) return 0 ;; *) return 1 ;; esac
    }

    # Un choix parmi une liste FERMEE. `_ask` est une saisie libre : elle
    # convient a un numero de noeud, pas a « gr-gsm ou DSP », ou toute frappe
    # hors liste part en lancement casse. whiptail --radiolist rend le jeton
    # choisi ; sans newt, on numerote et on lit un chiffre.
    #   $1 titre  $2 question  $3 defaut  $4.. = jeton libelle jeton libelle...
    _menu() {
        local titre="$1" q="$2" def="$3"; shift 3
        local rep
        if [ "$has_wt" -eq 1 ]; then
            local args=() j l
            while [ $# -gt 0 ]; do
                j="$1"; l="$2"; shift 2
                if [ "$j" = "$def" ]; then args+=("$j" "$l" ON); else args+=("$j" "$l" OFF); fi
            done
            rep="$(whiptail --title "$titre" --radiolist "$q" 15 74 4 "${args[@]}" 3>&1 1>&2 2>&3)" || rep="$def"
        else
            local -a jetons=() i=1
            printf "  %s\n" "$q" >&2
            while [ $# -gt 0 ]; do
                jetons+=("$1")
                printf "    %d) %-12s %s\n" "$i" "$1" "$2" >&2
                shift 2; i=$((i+1))
            done
            printf "  choix [%s] : " "$def" >&2
            read -r rep </dev/tty || rep=""
            case "$rep" in
                ''|*[!0-9]*) rep="$def" ;;
                *) rep="${jetons[$((rep-1))]:-$def}" ;;
            esac
        fi
        printf "%s" "${rep:-$def}"
    }

    printf "  %smenu%s       --menu : les defauts proposes sont ceux du lancement automatique\n" \
        "${C_DIM:-}" "${C_Z:-}"

    # ── 1. QUI FAIT LA COUCHE 1 ──────────────────────────────────────────────
    # Le premier choix, parce qu il commande le second : le DSP n a que faire
    # d une seconde station de base.
    _L1="$(_menu "Couche 1" \
        "Qui demodule ?\n\n  DSP     (defaut) le C54x execute la mask-ROM TI et decode lui-meme :\n          le mobile campe (SI1-4) et fait sa mise a jour de localisation.\n  gr-gsm  la pile va jusqu a l appel voix. Le DSP ne tourne pas." \
        "$([ "${DSP_MODE:-0}" = 1 ] && echo c54x_exe || echo grgsm_exe)" \
        c54x_exe  "DSP C54x hors QEMU, mask-ROM TI (defaut)" \
        grgsm_exe "couche 1 gr-gsm dans qosmo (pile complete)")"
    case "$_L1" in c54x_exe) DSP_MODE=1 ;; *) DSP_MODE=0 ;; esac

    # ── 2. TOPOLOGIE : SEUL OU HYBRIDE ───────────────────────────────────────
    # Meme axe que CALYPSO_PROFILE, dit dans les termes du banc :
    #   seul     = profil `qemu`         -> une BTS, un QEMU
    #   hybride  = profil `faketrx-qemu` -> + side-car fake_trx et un MS#2
    # Le defaut suit le choix ci-dessus : hybride en gr-gsm, seul en DSP.
    _topo_def=hybride
    [ "${DSP_MODE:-0}" = 1 ] && _topo_def=seul
    [ "$PROFILE" = qemu ] && _topo_def=seul
    _topo="$(_menu "Topologie" \
        "Combien de stations de base ?\n\n  seul     une BTS et un QEMU. C est ce qu il faut pour le DSP.\n  hybride  + un side-car fake_trx et un second mobile, pour que\n           MS#2 appelle MS#1 sans sortir de la maquette." \
        "$_topo_def" \
        seul    "une BTS, un QEMU" \
        hybride "+ side-car fake_trx et MS#2")"
    case "$_topo" in
        seul)    PROFILE=qemu ;;
        hybride) PROFILE=faketrx-qemu ;;
    esac
    PROFILE_CHOISI=1
    unset _topo _topo_def

    # Les autres profils (faketrx seul, noproc) restent joignables, mais en
    # ligne de commande : les proposer ici alourdirait le choix courant.
    PROFILE="$(_ask "Profil" \
        "Profil de pile retenu (modifiable) :\n  faketrx-qemu = hybride   qemu = seul\n  faketrx  noproc  aussi acceptes" \
        "$PROFILE")"

    # Le noeud est deja resolu plus haut (--node, environnement, /etc/osmo-role,
    # table WAN) : on propose CE resultat, pas un 1 arbitraire.
    NODE_ID="$(_ask "Noeud SS7" \
        "Numero de ce noeud (1-9). Il fixe le point code 1.<noeud><op>.<role>,\nle routing context et les MSISDN <noeud>00<op><rang>." \
        "${NODE_ID:-1}")"
    NODE_OP="$(_ask "Operateur" "Operateur porte par ce noeud (1-9) :" "${NODE_OP:-1}")"
    HUB_IP="$(_ask "Inter-STP" \
        "Adresse du hub SS7 (vide = ne pas toucher au remote-ip en place) :" \
        "${HUB_IP:-$(awk -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' "${ROLE_FILE:-/etc/osmo-role}" 2>/dev/null)}")"

    _yesno "WAN" "Monter le maillage WAN entre noeuds ?" "$([ "${WAN_MESH:-0}" -eq 1 ] && echo 0 || echo 1)" \
        && WAN_MESH=1 || WAN_MESH=0

    _yesno "Configurations" \
        "Regenerer /etc/osmocom et /etc/asterisk depuis les gabarits ?\n\nLa pile sera ARRETEE, les fichiers sauvegardes, puis reecrits\navec l'identite du noeud ci-dessus." \
        "$([ "${REGEN_GABARITS:-0}" -eq 1 ] && echo 0 || echo 1)" \
        && REGEN_GABARITS=1 || REGEN_GABARITS=0

    printf "  %smenu%s       profil=%s  noeud=%s  op=%s  hub=%s  wan=%s  regen=%s\n" \
        "${C_DIM:-}" "${C_Z:-}" "$PROFILE" "${NODE_ID:-?}" "$NODE_OP" \
        "${HUB_IP:-inchange}" "$WAN_MESH" "$REGEN_GABARITS"
}
menu_interactif

# Profil → mapping vers les profils attendus par run.sh
case "$PROFILE" in
    faketrx-qemu|hybrid) CALYPSO_PROFILE=hybrid;   MODE=faketrx-qemu ;;
    faketrx)             CALYPSO_PROFILE=faketrx;  MODE=faketrx ;;
    qemu)                CALYPSO_PROFILE=calypso;  MODE=qemu ;;
    noproc|core)         CALYPSO_PROFILE=core;     MODE=noproc; RUN_NO_PROCESS=1 ;;
    *)                   CALYPSO_PROFILE=hybrid;   MODE=faketrx-qemu; PROFILE=faketrx-qemu ;;
esac
export CALYPSO_PROFILE MODE
export RUN_NO_PROCESS="${RUN_NO_PROCESS:-0}"
export ENCRYPTION MS_COUNT HOST_IP
# RAND passe en prefixe (ex. `RAND=0 ./start-native.sh`) force le defi
# d'authentification, via le gate getenv("RAND") des patchs osmo-hlr + osmo-msc.
# Le RAND doit atteindre LES DEUX process : osmo-hlr le tire dans le vecteur
# (SRES/Kc calcules sur RAND=0 -> LU acceptee) et osmo-msc l'envoie. RAND pose
# sur osmo-msc SEUL -> mismatch -> LU reject. RAND absent -> reseau normal.
# core_svc_start (run.sh) lance ces demons de deux facons, on couvre les deux :
#   - enfant direct (setsid, pas de systemd) -> heritent de l'env : on exporte.
#   - service systemd -> `systemctl start` N'herite PAS de l'env : drop-in
#     transient /run/systemd/system/<unit>.service.d/rand.conf + daemon-reload.
[ -n "${RAND:-}" ] && export RAND
if command -v systemctl >/dev/null 2>&1; then
    _rand_changed=0
    for _u in osmo-hlr osmo-msc; do
        systemctl cat "$_u" >/dev/null 2>&1 || continue
        _dd="/run/systemd/system/$_u.service.d"
        [ -f "$_dd/rand.conf" ] && _rand_changed=1
        if [ -n "${RAND:-}" ]; then
            mkdir -p "$_dd" 2>/dev/null \
                && printf '[Service]\nEnvironment=RAND=%s\n' "$RAND" > "$_dd/rand.conf" \
                && _rand_changed=1
        else
            rm -f "$_dd/rand.conf" 2>/dev/null || true
        fi
    done
    [ "$_rand_changed" = 1 ] && systemctl daemon-reload 2>/dev/null || true
    # rebondir seulement si le forcage change, et HLR AVANT MSC pour que le MSC
    # reprenne des vecteurs a RAND=0 ; un run normal sans RAND ne touche a rien.
    if [ -n "${RAND:-}" ] || [ "$_rand_changed" = 1 ]; then
        for _u in osmo-hlr osmo-msc; do
            systemctl is-active --quiet "$_u" 2>/dev/null && systemctl restart "$_u" 2>/dev/null || true
        done
    fi
    unset _u _dd _rand_changed
fi
# Client de couche 2 : l'option de ligne de commande ECRASE tout, et elle est
# EXPORTEE -- une valeur posee sans export ne traverse pas jusqu'a run.sh,
# defaut deja paye sur ENCRYPTION (cf. generate_configs.sh).
if [ -n "${L2_CLIENT_CHOISI:-}" ]; then
    CALYPSO_L2_CLIENT="$L2_CLIENT_CHOISI"
fi
export CALYPSO_L2_CLIENT="${CALYPSO_L2_CLIENT:-mobile}"
# ── LE TAMPON DU GREFFON ALSA-PULSEAUDIO DU `mobile` ────────────────────────
# [2026-09-09] 240 ms, PAS 80. Le mecanisme est celui deja documente dans
# qosmo/run_modules/70-l2.sh (« DESCENDANT MUET ») : le `mobile` ecrit une
# trame GSM (160 echantillons, 20 ms) par `snd_pcm_writei`, et si le tampon du
# greffon est trop court chaque ecriture rend -EPIPE ; pq_alsa.c y repond par
# un `snd_pcm_prepare()` muet, qui DEMONTE ET REMONTE le flux PulseAudio.
# Le 80 ms retenu a l epoque ne tient plus des qu un consommateur lit
# gsm_audio.monitor (notre bouclage vers les haut-parleurs) : la latence
# minimale du sink monte a 26 ms et les remontages reviennent. Mesure du jour,
# ecrivain cadence a 20 ms comme le mobile, 10 s, sur ce banc :
#     80 ms -> 16 remontages   120 -> 19   160 -> 1   200 -> 0   240 -> 0
# Pendant un vrai appel c etait 50 remontages par seconde : flux detruit a
# chaque trame, « voix saturee et pas belle ». 240 ms = 12 trames GSM, le
# premier palier stable (200) avec de la marge pour la gigue sous charge.
# La variable est exportee ICI parce que update.sh re-fetch qosmo :
# son defaut interne peut repartir a 80, celui-ci gagne (`:=`).
# JUGE, pendant un appel etabli : l index du sink-input du mobile doit rester
# FIXE (`pactl list short sink-inputs`, deux releves a 1 s d intervalle).
export CALYPSO_PULSE_LATENCY_MSEC="${CALYPSO_PULSE_LATENCY_MSEC:-320}"
export LOG_DIR RUN_DIR
# --- 2c. firmware ARM : FIRMWARE_SRC ----------------------------------------
# Les deux lanceurs (qosmo/run.sh via bench.env, c54x_exe/run.sh) lisent
# FIRMWARE_ELF / FIRMWARE_BIN dans l environnement. FIRMWARE_SRC est le nom
# que les scripts de packaging emploient (build-debs.sh, 71-debs-banc.sh) ;
# on l accepte ici aussi pour qu un appel
#     FIRMWARE_SRC=/chemin/layer1.xxx.elf ./start-native.sh
# charge ce firmware-la dans QEMU. Un fichier = l ELF lui-meme ; un dossier =
# l arborescence firmware/ (FIRMWARE_DIR, board/<carte>/ en dessous).
# FIRMWARE_ELF explicite garde la main.
if [ -n "${FIRMWARE_SRC:-}" ]; then
    if [ -f "$FIRMWARE_SRC" ]; then
        : "${FIRMWARE_ELF:=$FIRMWARE_SRC}"
    elif [ -d "$FIRMWARE_SRC" ]; then
        : "${FIRMWARE_DIR:=$FIRMWARE_SRC}"
        export FIRMWARE_DIR
    else
        printf '  %sFIRMWARE_SRC introuvable : %s%s\n' "$C_SK" "$FIRMWARE_SRC" "$C_Z" >&2
    fi
fi
if [ -n "${FIRMWARE_ELF:-}" ]; then
    # Le .bin a cote de l ELF s il existe (qosmo --bin, c54x_exe) ; sinon on
    # laisse les lanceurs appliquer leur propre defaut.
    [ -n "${FIRMWARE_BIN:-}" ] || [ ! -r "${FIRMWARE_ELF%.elf}.bin" ] || FIRMWARE_BIN="${FIRMWARE_ELF%.elf}.bin"
    export FIRMWARE_ELF FIRMWARE_BIN
fi
# --- 3. validation des chemins critiques --------------------------------------
say_begin "Validation des chemins"
path_ok=1
_check() {
    local name="$1" val="${!1:-}"
    if [ -z "$val" ]; then
        printf '\n       %s%s non defini%s\n' "$C_DIM" "$name" "$C_Z"
        path_ok=0
    elif [ -e "$val" ]; then
        :
    else
        printf '\n       %s%s introuvable : %s%s\n' "$C_DIM" "$name" "$val" "$C_Z"
        path_ok=0
    fi
}
# Variables optionnelles selon le profil ; on ne bloque que si presentes et cassees
# (DSP_PROM0 retire : ROM plus generee depuis le merge `sans-dsp` de
#  qosmo — cf. run.sh --check-paths et run_modules/00-prereqs.sh.)
for v in QEMU_BIN FIRMWARE_ELF OSMOCON; do
    # `[ -n x ] && _check || true` avalait le verdict : _check pouvait poser
    # path_ok=0 sans que la boucle ne le laisse remonter. Forme explicite.
    if [ -n "${!v:-}" ]; then _check "$v"; fi
done
if [ $path_ok -eq 1 ]; then
    say_end " OK " "$C_OK" "Validation des chemins"
else
    say_end "WARN" "$C_SK" "Validation des chemins" "certains chemins manquent (run.sh verifiera)"
fi
# --- 4. generation des configs mobile -----------------------------------------
# MS#1 (QEMU / mobile principal) et MS#2 (faketrx side-car) pour le profil hybrid.
BB_DIR="/root/.osmocom/bb"
mkdir -p "$BB_DIR"
# Sources possibles pour le template mobile
MS_TEMPLATE=""
for t in \
    "${OQC_ROOT:-}/cfgs/mobile_group1.cfg" \
    "$RUN_ROOT/cfgs/mobile_group1.cfg" \
    "$HERE/configs/mobile.cfg.template" \
    "$HERE/configs/mobile.cfg" \
    "$BB_DIR/mobile_group1.cfg" \
    "$BB_DIR/mobile.cfg"
do
    if [ -f "$t" ]; then MS_TEMPLATE="$t"; break; fi
done
# La SIM du MS : « sap » pour le MS#1 quand --sap est demande (son socket est
# celui du serveur SAP, SAP_SOCK), « test » (la SIM de test du gabarit) sinon.
ms_sim_mode() {
    if [ "${SAP_MODE:-0}" = 1 ] && [ "$1" = "${SAP_SOCK:-/tmp/osmocom_sap}" ]; then echo sap; else echo test; fi
}
generate_mobile_cfg() {
    local dest="$1" vty_port="$2" l2sock="$3" sapsock="$4" arfcn="$5" imsi="$6" ki="$7"
    # [2026-08-08] Peripheriques ALSA PAR MOBILE. Le template porte
    # gsm_out/gsm_in pour tout le monde ; laisser ca remettrait les deux
    # mobiles sur le meme sink et la meme source, c'est-a-dire la boucle
    # audio qu'on vient d'ouvrir (cf /etc/asound.conf).
    local aout="${8:-gsm_out}" ain="${9:-gsm_in}"
    # [2026-08-08] GARDE-FOU : la liste de templates contient $BB_DIR/mobile.cfg,
    # qui est aussi une DESTINATION. Si c'est lui qui est retenu, `sed "$tpl" >
    # "$dest"` avec tpl == dest fait tronquer le fichier par le shell AVANT que
    # sed ne le lise : on produit un mobile.cfg VIDE et le mobile ne demarre plus.
    # On bascule alors sur le template de secours plutot que de se detruire.
    local tpl="$MS_TEMPLATE"
    if [ -n "$tpl" ] && [ "$tpl" -ef "$dest" ] 2>/dev/null; then
        printf '\n       %sMS_TEMPLATE == destination (%s) : template de secours%s\n' \
            "$C_DIM" "$dest" "$C_Z"
        tpl=""
    fi
    if [ -n "$tpl" ]; then
        # le gabarit porte « sim sap » : seul le MS#1 de --sap le garde
        # (delimiteur # : le | de s|..| casserait l alternance \| de sed)
        local _sim_sed=(-e "s#^\([[:space:]]*\)sim \(sap\|test\|reader\)\$#\1sim $(ms_sim_mode "$sapsock")#")
        sed \
            -e "s|bind 127.0.0.1 424[0-9]|bind 127.0.0.1 ${vty_port}|" \
            -e "s|layer2-socket /tmp/osmocom_l2[_0-9]*|layer2-socket ${l2sock}|" \
            -e "s|sap-socket /tmp/osmocom_sap[_0-9]*|sap-socket ${sapsock}|" \
            "${_sim_sed[@]}" \
            -e "s|stick [0-9]*|stick ${arfcn}|" \
            -e "s|^\([[:space:]]*\)imsi .*|\1imsi ${imsi}|" \
            -e "s|^\([[:space:]]*\)imei .*|\1imei $(rand_imei) 0|" \
            -e "s|^\([[:space:]]*\)ki .*|\1ki comp128 ${ki}|" \
            -e "s|alsa-output-dev .*|alsa-output-dev ${aout}|" \
            -e "s|alsa-input-dev .*|alsa-input-dev ${ain}|" \
            "$tpl" > "$dest"
    else
        # Template minimal de secours
        cat > "$dest" <<EOF
!
! mobile.cfg genere par start-native.sh (secours)
!
log stderr
 logging color 1
 logging print category 1
 logging timestamp 0
!
line vty
 no login
 bind 127.0.0.1 ${vty_port}
!
ms 1
 layer2-socket ${l2sock}
 sap-socket ${sapsock}
 sim $(ms_sim_mode "$sapsock")
 imsi ${imsi}
 ki comp128 ${ki}
 network-selection-mode auto
 stick ${arfcn}
!
EOF
    fi
    _ms_cfg_garantir_tch "$dest" "$aout" "$ain"
    _ms_cfg_garantir_log "$dest"
}

# ── LE BLOC tch-voice, GARANTI, QUEL QUE SOIT LE GABARIT ────────────────────
# [2026-09-09] MS#2 SORTAIT SANS « io-tch-format rtp ». Le gabarit retenu par
# la boucle ci-dessus est le PREMIER trouve, et c'est presque toujours
# qosmo/cfgs/mobile_group1.cfg - un fichier d'un autre depot, que
# update.sh refetche, et qui ne porte pas cette ligne. Le sed de generation ne
# fait que SUBSTITUER : ce qui manque au gabarit manque au resultat. MS#1
# l'avait (son fichier est ecrit ailleurs, 3192 octets), MS#2 non (2423).
#
# Sans cette ligne, le mobile lit et ecrit ses trames TCH dans la disposition
# Texas Instruments des vrais Calypso, alors que pont.py les code avec
# libosmocoding, c'est-a-dire en disposition RTP/RFC3551 (33 octets ouverts
# par la signature 0xD). Les deux bouts ne se comprennent alors DANS AUCUN
# SENS, aucun compteur ne bronche, et le son sort robotise (cf. le commentaire
# de configs/mobile.cfg, mesure du 27/08 : anneau descendant « d2 2c fd a2 »
# contre anneau montant « 83 00 05 e1 ... ff ff ff ff », une trame a champs).
#
# On ne corrige donc pas le gabarit - il ne nous appartient pas - on garantit
# le resultat : les quatre reglages de tch-voice sont poses ici, et le bloc
# entier est cree s'il manque (le gabarit de secours ci-dessus n'en a aucun).
# MS_TCH_FORMAT pour un banc qui voudrait autre chose que « rtp ».
_ms_cfg_garantir_tch() {
    local dest="$1" aout="${2:-gsm_out}" ain="${3:-gsm_in}" fmt="${MS_TCH_FORMAT:-rtp}"
    [ -f "$dest" ] || return 0
    awk -v aout="$aout" -v ain="$ain" -v fmt="$fmt" '
        BEGIN { vu = 0; dedans = 0 }
        # Le bloc existe : on pose nos quatre reglages en tete, une seule fois.
        /^[[:space:]]*tch-voice[[:space:]]*$/ && !vu {
            vu = 1; dedans = 1
            print " tch-voice"
            print "  io-handler gapk"
            print "  io-tch-format " fmt
            print "  alsa-output-dev " aout
            print "  alsa-input-dev " ain
            next
        }
        # Dans le bloc : on retire les anciennes copies de CES quatre lignes,
        # on garde tout le reste - les autres reglages comme les commentaires,
        # qui portent ici la mesure du 27/08 et valent mieux que le code.
        dedans {
            if ($0 ~ /^[[:space:]][[:space:]]+(io-handler|io-tch-format|alsa-output-dev|alsa-input-dev)([[:space:]]|$)/) next
            if ($0 ~ /^[[:space:]][[:space:]]+[a-z]/ || $0 ~ /^[!#]/) { print; next }
            dedans = 0
        }
        # Pas de bloc du tout : on le pose juste avant « no shutdown ».
        /^[[:space:]]*no shutdown[[:space:]]*$/ && !vu {
            vu = 1
            print " tch-voice"
            print "  io-handler gapk"
            print "  io-tch-format " fmt
            print "  alsa-output-dev " aout
            print "  alsa-input-dev " ain
        }
        { print }
    ' "$dest" > "${dest}.tch" 2>/dev/null && mv -f "${dest}.tch" "$dest" || rm -f "${dest}.tch"
}
# ── LE BLOC log stderr, GARANTI, DE LA MEME FORME PARTOUT ───────────────────
# [2026-10-19] LE JOURNAL DU MOBILE N'AVAIT PAS LA MEME FORME SELON LE GABARIT.
# qosmo/cfgs/mobile_group1.cfg et c54x_exe/mobile_pont.cfg portent un « log
# stderr » (couleur, horodatage, categorie) ; configs/mobile.cfg n'en porte
# AUCUN - seul le « log gsmtap ». Le fichier pose dans /root/.osmocom/bb
# dependait donc du gabarit retenu en premier, et mobile.log sortait tantot
# avec ses couleurs et son horodatage a 17 chiffres (ce que l'encart
# osmo-fft-snap.py et rapport-run.sh savent lire), tantot avec les defauts de
# libosmocore plus le masque -d de qosmo. On pose ici LE bloc, une fois, quel
# que soit le gabarit : les sept categories que suit le banc en debug, couleur
# par sous-systeme, horodatage compact. ATTENTION aux deux horodatages de
# libosmocore 1.12 : « logging timestamp 1 » = ctime (« Mon Oct 19 10:10:03
# 2026 », 25 colonnes, constate le 19/10 sur le banc DSP) ; « logging print
# extended-timestamp 1 » = YYYYMMDDhhmmssnnn (17 chiffres, triable, et le seul
# que tail_lines() de l'encart sait retirer). C'est le second qu'on pose. Le
# bloc gsmtap, lui, n'est pas touche.
MS_LOG_STDERR_BLOC=' logging filter all 1
 logging color 1
 logging timestamp 0
 logging print extended-timestamp 1
 logging print category 1
 logging level mm debug
 logging level rr debug
 logging level cc debug
 logging level sms debug
 logging level plmn debug
 logging level sim debug
 logging level sap debug'
_ms_cfg_garantir_log() {
    local dest="$1" existe=0
    [ -f "$dest" ] || return 0
    # On sait AVANT de lire si le bloc existe : dans mobile_group1.cfg, « line
    # vty » precede « log stderr », et une seule passe inserait un second bloc
    # devant line vty avant de tomber sur le premier (constate au test).
    grep -q '^log stderr[[:space:]]*$' "$dest" && existe=1
    awk -v bloc="$MS_LOG_STDERR_BLOC" -v existe="$existe" '
        BEGIN { vu = 0; dedans = 0 }
        # Le bloc existe : on le remplace en entier, une seule fois.
        /^log stderr[[:space:]]*$/ && !vu {
            vu = 1; dedans = 1
            print "log stderr"; print bloc
            next
        }
        dedans {
            if ($0 ~ /^[[:space:]]+[a-z]/) next     # ancienne ligne du bloc
            dedans = 0                               # « ! » ou autre : fin du bloc
        }
        # Pas de bloc : on le pose devant le premier « log gsmtap », sinon
        # devant « line vty ».
        /^(log gsmtap|line vty)([[:space:]]|$)/ && !existe && !vu {
            vu = 1
            print "log stderr"; print bloc; print "!"
        }
        { print }
        END { if (!vu) { print "!"; print "log stderr"; print bloc; print "!" } }
    ' "$dest" > "${dest}.log" 2>/dev/null && mv -f "${dest}.log" "$dest" || rm -f "${dest}.log"
}
# ⚠️ [2026-08-08, resolu le 26/08] LE RUN N'UTILISE PAS mobile.cfg POUR MS#1.
# Le mobile Calypso tourne avec
#     mobile -c /root/.osmocom/bb/mobile_group1.cfg
# alors qu'on ne generait ici que mobile.cfg. mobile_group1.cfg, lui, est COPIE
# tel quel par qosmo (run_modules/20-mobile-cfg.sh, depuis $QEMU_TREE/cfgs) :
# un fichier statique, jamais derive de l'operateur. Il porte donc l'identite de
# l'operateur 1 - IMSI 001010001000001, ARFCN 514 - quel que soit l'operateur.
#
# Constate sur le banc, operateur 2 : le HLR attend 002010002000001, la BTS
# emet sur 516, et le mobile se presentait avec 001010001000001 sur 514.
#     Mobile Subscriber of MS '1':
#      IMSI: 001010001000001
#      Status: U2_NOT_UPDATED  IMSI detached  LAI: invalid
#      Registered PLMN: MCC-MNC 001-01
# Tout le reste etait juste - clefs, MSISDN, point codes, ARFCN des BTS - et
# l'abonne restait detache, parce que la seule carte SIM qui compte n'etait
# generee nulle part.
#
# On ecrit donc MS#1 dans LES DEUX fichiers. mobile.cfg reste la reference
# (d'autres modules la lisent), mobile_group1.cfg est celui que le lanceur
# ouvre. Verifier lequel tourne, avant de croire un reglage pose ici :
#     pgrep -a mobile
# ── IMSI et Ki des MS : le plan du HLR, pas celui de l'operateur 1 ──────────
# Ces valeurs etaient ecrites EN DUR sur le PLMN de l'operateur 1 (001-01) et
# sur son numero d'abonne. Sur l'operateur 2, dont le reseau diffuse un autre
# MCC, le mobile presentait donc l'IMSI d'un abonne d'un autre pays : ni le MSC
# ni le HLR n'ont de fiche a ce numero, le Location Updating reste sans reponse,
# et l'on cherche la panne dans la BTS alors que la pile entiere est debout.
# Le plan est celui de start-docker.sh (section "HLR subscribers") :
#     IMSI = MCC MNC <operateur sur 4 chiffres> <index du MS sur 6 chiffres>
#     Ki   = 00112233445566778899aabbccdd <index du MS> <operateur>
# MCC et MNC sont relus dans la configuration REELLEMENT deployee - c'est elle
# que la BTS diffuse - et non redevines a partir d'une convention.
MS_OP_ID="${OPERATOR_ID:-1}"
MS_MCC="$(awk '$1=="network" && $2=="country" && $3=="code" {print $4; exit}' /etc/osmocom/osmo-bsc.cfg 2>/dev/null || true)"
MS_MNC="$(awk '$1=="mobile" && $2=="network" && $3=="code" {print $4; exit}' /etc/osmocom/osmo-bsc.cfg 2>/dev/null || true)"
# ── LES REPLIS SUIVENT LE PLAN, ILS NE L INVENTENT PAS ──────────────────────
# [2026-08-31] Ces deux lignes se declenchent quand osmo-bsc.cfg n est pas
# encore lisible (configs pas regenerees a cet instant), et elles etaient
# fausses toutes les deux :
#
#   MS_MNC="01"  en dur : l operateur 2 heritait du MNC de l operateur 1, et
#   ms_imsi() produisait 001|01|0002|000001 - MNC d un operateur, identifiant
#   d un autre. Ces abonnes-la arrivaient dans le HLR SANS MSISDN ni IMEI
#   ("none" / "-------------"), a cote des bons : le VLR ne pouvait les
#   rattacher a personne. Rien ne signalait l incoherence.
#
#   MS_MCC=<op sur 3 chiffres> : aurait donne MCC 002 pour l operateur 2,
#   alors que TOUT le banc est en 001 - c est le PLMN d essai, commun a tous
#   les operateurs, et c est le MNC qui les distingue.
#
# Le plan reel, verifie dans /var/tmp/osmo-annuaire.csv :
#   op 1 -> 001|01   op 2 -> 001|02   op 3 -> 001|03
# [2026-10-18] Au premier lancement d'une installation fraiche, osmo-bsc.cfg est
# encore le gabarit : on y lit les MARQUEURS __MCC__ / __MNC__, que la suite
# ecrivait tels quels dans les mobile_*.cfg (« imsi __MCC____MNC__0001000002 »,
# refuse par mobile : MS#2 ne demarrait pas) et exportait a run.sh. Seuls des
# chiffres comptent ; sinon, le repli ci-dessous.
[[ "$MS_MCC" =~ ^[0-9]{3}$ ]] || MS_MCC=""
[[ "$MS_MNC" =~ ^[0-9]{2,3}$ ]] || MS_MNC=""
[ -n "$MS_MCC" ] || MS_MCC="001"
[ -n "$MS_MNC" ] || MS_MNC="$(printf '%02d' "$MS_OP_ID")"
ms_imsi() { printf '%s%s%04d%06d' "$MS_MCC" "$MS_MNC" "$MS_OP_ID" "$1"; }

# ── LE QUATRIEME PROVISIONNEUR ──────────────────────────────────────────────
# run.sh embarque son propre module d'abonnes (run_modules/21-abonnes-hlr.sh,
# dans qosmo). Il calcule son IMSI comme MCC+MNC+operateur+rang - la meme
# formule que nous - mais lit MCC et MNC dans /etc/osmocom/osmo-msc.cfg via un
# chemin qui n'aboutit pas toujours ; il retombe alors sur ses defauts, 001 et
# 01. Sur l'operateur 2 il fabriquait donc 001010002000001 : un abonne que
# personne ne presente, avec en prime un MSISDN de l'ancien plan (20001), qui
# RETIENT ce numero et empeche le bon abonne de le recuperer.
#
# Il honore MCC et MNC depuis l'environnement. En les posant, son IMSI devient
# exactement celui que start-docker.sh a deja provisionne - et son propre controle
# d'etat (mod_abonnes_hlr_status) le trouve present, donc il ne fait rien.
# On neutralise ainsi un doublon par son idempotence, sans toucher a qosmo.
# [2026-10-24] SANS « ${MNC:-...} » : 03-affichage.sh a deja source globals.conf
# (MNC="01"), qui l emportait sur la config deployee - l op2 recreait
# 001010002000001 a chaque demarrage (sans auth, MSISDN refuse), visible en
# rouge dans les abonnes du conky. MS_MCC/MS_MNC SONT la config deployee.
export MCC="$MS_MCC"
export MNC="$MS_MNC"

# ── Le plan radio : on le LIT, on ne le recalcule pas ───────────────────────
# generate_configs.sh l'ecrit dans /etc/osmocom/radio-plan.env en meme temps
# que les configurations. Le relire ici garantit que le mobile s'accorde sur
# ce que la BTS diffuse VRAIMENT - et non sur une formule recopiee qui finira
# par diverger, comme l'ont fait l'unit-id, l'ARFCN et l'IMSI avant elle.
# Les replis restent, pour un banc monte sans ce fichier.
if [ -r /etc/osmocom/radio-plan.env ]; then
    # shellcheck disable=SC1091
    . /etc/osmocom/radio-plan.env
    printf '  %splan radio%s  lu dans /etc/osmocom/radio-plan.env\n' "${C_DIM:-}" "${C_Z:-}"
fi

# ── Les deux canaux radio, et a qui chaque MS s'accroche ────────────────────
# MS#1 et MS#2 avaient leur ARFCN ecrit EN DUR, 514 et 516 : les valeurs de
# l'operateur 1, et de lui seul. Sur l'operateur 2 la BTS principale passe a
# 516 et le side-car y restait aussi : deux cellules sur la meme frequence,
# leurs bursts melanges dans un milieu ou fake_trx apparie par frequence.
# Le mobile envoyait ses RACH, aucune Immediate Assignment ne revenait, et
# MS#1 restait accroche a 514 ou plus rien n'emettait.
#
# MS#1 suit la BTS principale, dont l'ARFCN est lu dans la configuration
# REELLEMENT deployee - c'est le BSC qui en decide et qui l'impose a la BTS
# par OML, donc c'est la qu'est la verite.
MS_ARFCN1="${PLAN_ARFCN:-}"
[ -n "$MS_ARFCN1" ] || MS_ARFCN1="$(awk '/^ bts 0$/{b=1} b && /^ *arfcn /{print $2; exit}' /etc/osmocom/osmo-bsc.cfg 2>/dev/null || true)"
# Meme garde que pour MCC/MNC : un gabarit pas encore regenere donne __ARFCN__.
[[ "$MS_ARFCN1" =~ ^[0-9]+$ ]] || MS_ARFCN1=""
[ -n "$MS_ARFCN1" ] || MS_ARFCN1=$(( 512 + MS_OP_ID * 2 ))

# MS#2 suit le side-car. Celui-la, c'est NOUS qui le decidons : le module
# 13-sidecar-cfg.sh de qosmo lit SC_ARFCN et SC_UNIT_ID dans
# l'environnement (run_modules/_lib/radio.sh : « : "${SC_ARFCN:=516}" »).
# Les poser ici evite de modifier qosmo, et garde une seule source par
# valeur - les memes formules que generate_configs.sh.
export SC_ARFCN="${SC_ARFCN:-${PLAN_ARFCN_BTS1:-$(( 612 + MS_OP_ID * 2 ))}}"
export SC_UNIT_ID="${SC_UNIT_ID:-${PLAN_UNIT_ID_BTS1:-$(( 6000 + MS_OP_ID * 10 + 2 ))}}"
MS_ARFCN2="$SC_ARFCN"
ms_ki()   { printf '00 11 22 33 44 55 66 77 88 99 aa bb cc dd %02x %02x' "$1" "$MS_OP_ID"; }

# IMEI tire au hasard, cle de Luhn calculee - un par MS, jamais deux identiques
# dans une meme trace.
rand_imei() {
    local body d i sum=0 dbl parity
    body="35892500$(printf '%06d' "$(( (RANDOM << 15 | RANDOM) % 1000000 ))")"
    for (( i = ${#body} - 1; i >= 0; i-- )); do
        d=${body:i:1}
        parity=$(( (${#body} - 1 - i) % 2 ))
        if [ "$parity" -eq 0 ]; then
            dbl=$(( d * 2 )); [ "$dbl" -gt 9 ] && dbl=$(( dbl - 9 ))
            sum=$(( sum + dbl ))
        else
            sum=$(( sum + d ))
        fi
    done
    printf '%s%d' "$body" "$(( (10 - sum % 10) % 10 ))"
}


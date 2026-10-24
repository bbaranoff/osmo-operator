# 14-demarrage.sh - partie de start.sh (lignes 3313-3442 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
if [ "$DSP_BANC" = 1 ]; then
    # ── LE FORK MONTE TOUT, MOINS LA CHAINE CALYPSO ────────────────────────
    # [2026-09-22] Deux versions ratees avant celle-ci, toutes deux pour la
    # meme raison -- avoir voulu remplacer le pipeline au lieu de s'y inserer :
    #   1. RUN_SH = c54x_exe/run.sh : la pile osmocom ne montait plus du tout
    #      (coeur, BTS, side-car, tmux sont des run_modules du fork) ;
    #   2. delegation a c54x_exe/run_real.sh : meme probleme, plus un verdict
    #      « ECHEC : aucun SI lu » imprime apres zero seconde d'observation.
    # Ici le fork joue son plan habituel, on lui retire seulement les quatre
    # modules que c54x_exe assure (qemu, pty, osmocon, l2), et le banc DSP est
    # lance ensuite avec ses cinq etapes. --no-attach est indispensable : sans
    # lui le fork s'attache a tmux et on ne reprend jamais la main.
    #
    # Les reglages du banc viennent du banc, pas d'un choix de style
    # (c54x_exe/run_real.sh les porte depuis le 2026-09-21) :
    #   INSNS=200000             plafond d'instructions par trame (voir plus bas)
    #   LOCKSTEP=1               QEMU n'avance la trame que quand le DSP a fini
    #                            la precedente ; sans lui il saute 3 trames sur 4
    #   IQ=none                  pas de cellule synthetique : les bursts
    #                            viennent de la vraie BTS, par pont.py
    #   CALYPSO_BSP_STREAM=1     un burst TS0 par trame, dans l'ordre des FN
    #   CALYPSO_RHEA_DMA_XFER=1  sans lui la page API n'est jamais remplie :
    #                            pas de SB, pas de BCCH, pas de SI
    # Tout reste surchargeable : on ne pose que ce que l'operateur n'a pas dit.
    export MODE=dsp PONT=1
    # [2026-10-19] --osmo-trx : transceiver a la place de mobile, pas de pont
    # (c54x_exe/run.sh force PONT=0 lui-meme ; on le dit ici pour le dry-run).
    if [ "${OSMO_TRX:-0}" = 1 ]; then export OSMO_TRX PONT=0; fi
    # [2026-09-23] Trace asm de l'ARM, lue par c54x_exe/run.sh (etape 2, QEMU -d).
    export ASSEMBLY_LOGS="${ASSEMBLY_LOGS:-0}" ASSEMBLY_LOGS_FLAGS ASSEMBLY_LOGS_FILTRE
    : "${IQ:=none}";        export IQ
    # [2026-09-23] 60000 -> 200000, puis 120000 (TCH mesure jusqu a 87000 insn/trame). Le budget n'est qu'un plafond (le DSP
    # s'arrete a son IDLE, c54x_exe/src/pont.c jouer_trame) ; a 60000 le
    # decodage TCH debordait sur la trame suivante (« insn=58524 occupe »), le
    # Viterbi de la parole (0x9a7c, ST TRN,*AR6+ jusqu'a 0x2d23) passait sur
    # data[0x2d0d] apres sa reinitialisation par 0xe68a, et le CALLD 0xea0c
    # ecrasait SP (« SP-CORRUPT pc=0xeac9 »). Le vrai C54x a ~480000 cycles par
    # trame. Capture gdb du 2026-09-23 15:07.
    # [2026-10-22] Magnetite (--ms-magnetite) : 480000. Le firmware TI en TCH demande bien plus que
    # l'osmocom : a 120000 la file des taches du DSP debordait (d_error_status 20h/28h), la L1 voyait
    # ses resultats en retard (« > COM »), relancait le DSP et l'appel au 600 tombait (Assignment
    # Failure). Rejeu tools/rejeu_banc de l'appel de 10:58 : 120000 -> ticks non finis des fn%26=10,
    # 240000 -> 5, 480000 -> 0. Le vrai C54x a ~480000 cycles par trame.
    if [ -n "${MS_MAGNETITE:-}" ]; then : "${INSNS:=480000}"; fi
    : "${INSNS:=120000}";   export INSNS
    : "${LOCKSTEP:=1}";     export LOCKSTEP
    : "${CALYPSO_BSP_STREAM:=1}";    export CALYPSO_BSP_STREAM
    : "${CALYPSO_RHEA_DMA_XFER:=1}"; export CALYPSO_RHEA_DMA_XFER
    # [2026-10-18] TCH-VOICE EN l1phy, PLUS EN gapk. Le profil ROM de
    # /etc/default/osmo-banc (scripts/dsp-rom-max.sh : BANC_VOCODEUR=rom,
    # CALYPSO_VSP=1 et les drapeaux d'emulateur du vocodeur) n'etait lu que par
    # osmo-banc.service. Lance a la main, start-native.sh passait run.sh sans
    # BANC_VOCODEUR, et le mobile tournait sur mobile_pont.cfg brut, en gapk.
    # On charge donc le profil ici - l'environnement gagne toujours - puis
    # l1phy par defaut : run.sh en derive mobile_pont_rom.cfg (config_vocodeur_rom).
    # BANC_VOCODEUR=hote pour revenir a gapk.
    if [ -r /etc/default/osmo-banc ]; then
        while IFS='=' read -r _k _v; do
            case "$_k" in ''|\#*|*[!A-Za-z0-9_]*) continue ;; esac
            [ -n "${!_k+x}" ] || export "$_k=$_v"
        done < /etc/default/osmo-banc
        unset _k _v
    fi
    : "${BANC_VOCODEUR:=rom}"; export BANC_VOCODEUR
    # [2026-10-22] --gapk avec --ms-magnetite : pas de mobile L23 pour GAPK, la voix est codee par le pont
    # (pont/voix_hote.py, libgsm) ; le DSP ne fait plus que le canal (CALYPSO_VSP=0).
    if [ "$BANC_VOCODEUR" = hote ] && [ -n "${MS_MAGNETITE:-}" ]; then
        : "${PONT_VOIX_HOTE:=1}"; export PONT_VOIX_HOTE
    fi
    : "${CALYPSO_VSP:=1}";     export CALYPSO_VSP
    # [2026-10-18] ET LE RESTE DU PROFIL --vocodeur-rom, MEME SANS
    # /etc/default/osmo-banc. Sur acer (10.99.0.2) le fichier n'existait pas :
    # BANC_VOCODEUR=rom et CALYPSO_VSP=1 venaient d'ici, mais pas les drapeaux
    # d'emulateur du codec FR ni PONT_UL_RAW_TCH. La ROM recevait bien le micro
    # (crete UL 2200 sur le port VSP) et codait... la trame de silence
    # (pont : « TCH ul rom P=0 »), l'echo test du 600 restait muet. Memes
    # valeurs que scripts/dsp-rom-max.sh profile --vocodeur-rom (le defaut).
    if [ "$BANC_VOCODEUR" = rom ]; then
        for _kv in CALYPSO_NORM_TC=0 CALYPSO_C54X_BCTC_NORM=1 PONT_UL_RAW_TCH=1 \
                   CALYPSO_C54X_BCD_CARRY=1 CALYPSO_C54X_OVM_LOGIQUE=1 CALYPSO_MAC=1 \
                   CALYPSO_C54X_BCD_TC=1 CALYPSO_C54X_BCTC_COMBO=1; do
            _k="${_kv%%=*}"; [ -n "${!_k+x}" ] || export "$_kv"
        done
        unset _kv _k
    fi
    RUN_ARGS+=(--skip "$DSP_MODULES_RETIRES" --no-attach)
    if [ $DRY -eq 1 ]; then
        say_begin "Transmission a run.sh puis au banc DSP"
        say_end " -- " "$C_DIM" "Transmission a run.sh puis au banc DSP" "dry-run"
        printf '  1. CALYPSO_PROFILE=%s bash %s %s\n' "$CALYPSO_PROFILE" "$RUN_SH" "${RUN_ARGS[*]}"
        printf '  2. MODE=dsp PONT=%s IQ=%s INSNS=%s LOCKSTEP=%s BANC_VOCODEUR=%s%s%s bash %s\n' \
            "$PONT" "$IQ" "$INSNS" "$LOCKSTEP" "$BANC_VOCODEUR" \
            "${QEMU_ICOUNT:+ QEMU_ICOUNT=$QEMU_ICOUNT}" \
            "$([ "${ASSEMBLY_LOGS:-0}" = 1 ] && echo " ASSEMBLY_LOGS=1")" "$BANC_DSP"
        [ "${OSMO_TRX:-0}" = 1 ] && printf '     OSMO_TRX=1 : trx.highram.elf + transceiver --no-sync (pas de mobile, pas de pont) ; %s\n' "$(trx_ts_desc)"
        [ "${OSMO_TRX_TS1:-0}" = 1 ] && printf '     OSMO_TRX_TS1=1 : INSTANCE=3 OSMO_TRX_PHONE=2 bash %s   (le 2e Calypso TRX, TS1, avant le transceiver)\n' "$BANC_DSP"
        # [2026-10-21] BTS classique (--bts-classic ou defaut) : le mobile est sur le pont, Magnetite par FIRMWARE_FLASH
        [ "${OSMO_TRX:-0}" != 1 ] && printf '     BTS classique : osmo-bts-trx <-> pont_dsp.py ; mobile %s\n' \
            "$([ -n "${MS_MAGNETITE:-}" ] && echo "Magnetite (FIRMWARE_FLASH=$MAGNETITE_FLASH)" || echo "osmocom-bb (mobile + layer1)")"
        [ "${OSMO_TRX:-0}" = 1 ] && [ "${MS_AIR:-0}" = 1 ] && printf '  3. INSTANCE=2 AIR=1 MODE=dsp %sbash %s   (le mobile par l air, quand le firmware trx est en mode BTS)\n' "${MS_MAGNETITE:+FIRMWARE_FLASH=$MAGNETITE_FLASH }" "$BANC_DSP"
        exit 0
    fi
    # [2026-10-24] Le mobile de l'instance 1 lit mobile_pont.cfg tel quel (run.sh ne
    # reecrit le stick que pour les instances 2+) : gabarit a 514, cellule du plan a 1
    # dans les conteneurs du multi -> FBSB result=255 en boucle. On l'aligne ici.
    _cfg_pont="$(dirname "$BANC_DSP")/mobile_pont.cfg"
    _arfcn_pont="${PLAN_ARFCN:-${MS_ARFCN1:-${ARFCN:-1}}}"
    if [ -w "$_cfg_pont" ] && [[ "$_arfcn_pont" =~ ^[0-9]+$ ]]; then
        sed -i "s|^\([[:space:]]*\)stick [0-9]*\$|\1stick ${_arfcn_pont}|" "$_cfg_pont"
    fi
    # [2026-10-24] Meme gabarit, meme trou pour la SIM : imsi/ki/rplmn restaient
    # ceux de l'op1 (001010001000001, ki ..01 01). Dans le conteneur de l'op2,
    # la HLR ne connait cette IMSI que sans donnees d'auth -> LU reject cause 2.
    # On reprend la carte de mobile.cfg, celle que start-docker genere par operateur.
    _sim_src="/root/.osmocom/bb/mobile.cfg"
    if [ -w "$_cfg_pont" ] && [ -r "$_sim_src" ]; then
        for _k in imsi "ki comp128" rplmn; do
            _l="$(grep -m1 -E "^[[:space:]]+${_k} " "$_sim_src")" || continue
            _l="${_l//|/\\|}"
            sed -i "s|^[[:space:]]\+${_k} .*\$|${_l}|" "$_cfg_pont"
        done
    fi
    unset _cfg_pont _arfcn_pont _sim_src _k _l
    audio_start
    say_begin "Transmission a run.sh (sans $DSP_MODULES_RETIRES)"
    if ! env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" "${RUN_ARGS[@]}"; then
        say_end " KO " "$C_KO" "Transmission a run.sh" "le plan du fork a echoue, banc DSP non lance"
        exit 1
    fi
    say_end " OK " "$C_OK" "Transmission a run.sh" "profil=$CALYPSO_PROFILE, chaine Calypso laissee au banc DSP"
    say_begin "Banc DSP C54x"
    say_end " OK " "$C_OK" "Banc DSP C54x" "$BANC_DSP  (INSNS=$INSNS LOCKSTEP=$LOCKSTEP IQ=$IQ$([ "${OSMO_TRX:-0}" = 1 ] && echo " OSMO_TRX=1 : trx.highram.elf + transceiver, $(trx_ts_desc)"))"
    # Hand-off total : ce processus devient c54x_exe/run.sh (cinq etapes, puis
    # il rend la main ; les journaux restent dans /tmp/c54x-pont). MODE=dsp est
    # deja exporte juste au-dessus, il ecrase celui du profil.
    # [2026-10-14] --sap : la copie « sim sap » de mobile_pont.cfg, au banc seul.
    # [2026-10-20] --bts --ms : l'instance 1 (la radio de la BTS) d'abord, puis, quand le
    # firmware trx est passe en mode BTS (osmo-bts-trx a envoye POWERON : « BTS MODE: 7 514 »
    # dans osmocon.log), l'instance 2 (le mobile + l'air), qui prend la main.
    if [ "${OSMO_TRX:-0}" = 1 ] && [ "${MS_AIR:-0}" = 1 ]; then
        bash "$BANC_DSP" || exit 1
        say_begin "Mobile par l'air (instance 2)"
        _ok=0
        for _i in $(seq 1 "${OSMO_TRX_BTS_ATTENTE:-150}"); do
            grep -aq 'BTS MODE: [0-9]* [1-9]' /tmp/c54x-pont/osmocon.log 2>/dev/null && { _ok=1; break; }
            sleep 1
        done
        if [ "$_ok" = 1 ]; then
            say_end " OK " "$C_OK" "Mobile par l'air (instance 2)" "firmware trx en mode BTS apres ${_i}s ; INSTANCE=2 AIR=1 $BANC_DSP"
        else
            say_end " !! " "$C_KO" "Mobile par l'air (instance 2)" "le firmware trx n'est pas en mode BTS (osmo-bts-trx absente ?) ; on lance quand meme"
        fi
        sleep 10
        # [2026-10-20 21:20] OSMO_TRX=0 explicite : OSMO_TRX=1 est exporte (le TRX, c'est l'instance 1) et
        # l'instance 2 en heritait -> firmware trx + second transceiver, « port UDP 5700 deja pris ».
        # Le mobile par l'air est le layer1 d'origine (FIRMWARE_ELF du profil retire : c'est le
        # layer1.highram.elf qui a fait le LU et l'appel du 20/10 21:08 ; FIRMWARE_SRC explicite garde la main).
        # [2026-10-21] --ms-magnetite : FIRMWARE_FLASH (exporte au parsing) remplace le layer1 pour l'instance 2
        exec env -u FIRMWARE_ELF -u FIRMWARE_BIN ${FIRMWARE_SRC:+FIRMWARE_ELF="$FIRMWARE_ELF"} \
            ${MS_MAGNETITE:+FIRMWARE_FLASH="$MAGNETITE_FLASH"} \
            INSTANCE=2 AIR=1 OSMO_TRX=0 ${SAP_DSP_MOBILE_CFG:+MOBILE_CFG="$SAP_DSP_MOBILE_CFG"} bash "$BANC_DSP"
    fi
    exec env ${MS_MAGNETITE:+FIRMWARE_FLASH="$MAGNETITE_FLASH"} ${SAP_DSP_MOBILE_CFG:+MOBILE_CFG="$SAP_DSP_MOBILE_CFG"} bash "$BANC_DSP"
fi


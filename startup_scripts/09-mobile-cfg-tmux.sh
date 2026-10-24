# 09-mobile-cfg-tmux.sh - partie de start.sh (lignes 1542-1911 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
MS1_GROUP_CFG="$BB_DIR/mobile_group1.cfg"
if [ "$MS1_GROUP_CFG" != "$MS1_CFG" ]; then
    generate_mobile_cfg "$MS1_GROUP_CFG" \
        4247 \
        /tmp/osmocom_l2 \
        "${SAP_SOCK:-/tmp/osmocom_sap}" \
        "$MS_ARFCN1" \
        "$(ms_imsi 1)" \
        "$(ms_ki 1)"
    printf '  %sMS#1%s       aussi ecrit dans %s (le fichier que run.sh ouvre)\n' \
        "${C_DIM:-}" "${C_Z:-}" "$MS1_GROUP_CFG"
fi
say_end " OK " "$C_OK" "Generation mobile MS#1" "$MS1_CFG"
say_begin "Generation mobile MS#2 (faketrx)"
MS2_CFG="$BB_DIR/mobile_faketrx_bts1.cfg"
generate_mobile_cfg "$MS2_CFG" \
    4248 \
    /tmp/ms2_l2 \
    /tmp/ms2_sap \
    "$MS_ARFCN2" \
    "$(ms_imsi 2)" \
    "$(ms_ki 2)" \
    gsm_out gsm_in
say_end " OK " "$C_OK" "Generation mobile MS#2 (faketrx)" "$MS2_CFG"
# ── LA SIM EMULEE LIT LE MEME FICHIER QUE LE MOBILE ─────────────────────────
# CALYPSO_SIM_CFG est la SEULE variable d'environnement que lit le modele QEMU
# (hw/arm/calypso/calypso_sim.c) : il y prend la section « test-sim » - imsi et
# ki comp128 - au format de mobile.cfg, donc exactement le fichier MS#1 genere
# ci-dessus. Sans elle, la SIM emulee garde son IMSI par defaut
# (001010000000001), inconnu du HLR provisionne avec le plan. Elle n'etait
# exportee nulle part.
# (MOBILE_CFG_MS1/MS2 et CALYPSO_MS2_CFG, exportes ici jusqu'au 2026-09-02,
#  n'avaient aucun lecteur dans qosmo ; le side-car MS#2 lit
#  SC_MOBILE_CFG / le fichier lui-meme.)
export CALYPSO_SIM_CFG="$MS1_CFG"

# --- Mode PONT TRX (CALYPSO_BRIDGE=pont) : le pont maison est le transceiver --
# Le pont (pont/pont.py) se presente comme transceiver TRX-UDP a osmo-bts-trx
# (5700/5701/5702), decode les bursts DL en L2 -> GSMTAP 4730/4731 vers le
# modele QEMU, et encode l'UL depuis les sidebands /dev/shm/calypso_* -> TRXD
# -> BTS. Il a BESOIN d'osmo-bts-trx en face : c'est qosmo/60-bts.sh qui
# le lance, et la barriere plus bas attend son retour avant de lancer le pont.
if [ "${CALYPSO_BRIDGE:-}" = pont ]; then
    export CALYPSO_BRIDGE
    # ── LE PONT VIENT DU DEPOT, POINT ──────────────────────────────────────
    # Le defaut etait /opt/GSM/pont/pont.py, un chemin HORS DEPOT alimente par un
    # `COPY pont/pont.py` de Dockerfile.run et fige par un `ENV PONT_PY=`. Rien
    # ne le gardait en phase avec pont/pont.py, et rien ne signalait sa derive.
    #
    # CE QUE CA A COUTE, le 2026-08-27 : la copie executee etait restee a une
    # version anterieure de 198 lignes, SANS AUCUN plan SDCCH/8 (ni PLAN_SD8, ni
    # _dcch_plan, ni sacch_dl102). Elle raisonnait sur le SDCCH/4 combine du TS0
    # pendant que le mobile parlait sur SDCCH/8 SS0 du TS1. Pendant deux heures,
    # sans un seul message d erreur : 79 % de CRC fail, montant emis dans la
    # fenetre du /4 (donc hors de celle que la BTS ecoute, avec hors_fenetre=0
    # puisque coherent avec sa propre table), SABM sans reponse, T200 x6, LU en
    # echec, SMS rejete, appel impossible. Restaurer la copie du depot a suffi a
    # retablir le LU complet, chiffrement A5/1 compris, des le premier essai.
    #
    # La copie libre et son COPY sont supprimes ; PONT_PY reste disponible pour
    # qui veut essayer une variante, mais c est alors un choix explicite.
    #
    # [2026-08-30] NITB_ROOT RETIRE DE CE CHEMIN. Le defaut passait par lui, et
    # NITB_ROOT n appartient pas a ce depot : qosmo/environnement/paths.env
    # le pose a "$GSM_ROOT/osmo_egprs" - l ANCIEN nom de cet arbre. Le pont etait
    # donc cherche dans /opt/GSM/osmo_egprs/pont/pont.py, d ou
    # "pont introuvable (/opt/GSM/osmo_egprs/pont/pont.py)" sur un banc ou le
    # fichier est pourtant la, dans le depot. Pire quand ce vieux dossier existe
    # encore : on y trouve une COPIE, et on retombe mot pour mot dans la panne
    # decrite ci-dessus - un pont hors depot qui derive sans que rien ne le dise.
    # $HERE est le repertoire de CE script : le pont voyage avec lui, toujours.
    # [2026-09-23] Montage grgsm : son pont est pont.py (pont_dsp.py est
    # celui du montage DSP, lance par c54x_exe/run.sh). Voir pont/pont.py.
    _PONT="${PONT_PY:-$HERE/pont/pont.py}"

    # ── LE PONT DOIT SAVOIR SUR QUELLE CELLULE IL TRAVAILLE ─────────────────
    # pont.py fait le codage/decodage de canal entre le Calypso de QEMU et la
    # BTS. Il lisait PONT_ARFCN et PONT_BSIC dans son environnement, avec pour
    # defauts 514 et 7 - les valeurs de l'operateur 1. Personne ne les posait.
    #
    # Le BSIC n'est pas decoratif : sa partie basse (BCC) EST la sequence
    # d'apprentissage des canaux dedies. Avec un BSIC faux, la correlation
    # echoue et les blocs ne se decodent pas. Constate sur l'operateur 2, dont
    # la cellule est en ARFCN 516 / BSIC 14 :
    #     dl_bursts=20660 dl_dec=1180 crc_fail=3984
    #     TS0/22 : 0/295        <- la voie ou arrive l'Immediate Assignment
    #     ul_sent=23 rach=23    <- le RACH partait bien
    # Le mobile emettait son RACH, le reseau repondait, et la reponse n'etait
    # jamais rendue au Calypso : "radio resource layer state: connection
    # pending", indefiniment. L'operateur 1 s'en sortait parce que ses valeurs
    # sont justement celles des defauts.
    #
    # On les prend dans le plan radio publie par generate_configs.sh, avec les
    # memes replis que les mobiles.
    export PONT_ARFCN="${PONT_ARFCN:-${PLAN_ARFCN:-$MS_ARFCN1}}"
    export PONT_BSIC="${PONT_BSIC:-${PLAN_BSIC:-$(( MS_OP_ID * 7 % 64 ))}}"
    printf '  %spont TRX%s : cellule ARFCN %s BSIC %s\n' \
        "${C_DIM:-}" "${C_Z:-}" "$PONT_ARFCN" "$PONT_BSIC"
    # [2026-08-16] N'ARMER LE LANCEUR QUE SUR UN VRAI DEMARRAGE.
    # Ce bloc s'execute AVANT le `case "$ACTION"` plus bas. Sur `--stop` (comme
    # sur --list/--status/--check-paths) on armait donc quand meme le lanceur
    # differe, que `run.sh --stop` tuait aussitot - d'ou le "line 450: Killed"
    # crache par bash en plein arret propre. Un arret qui programme un demarrage
    # n'a aucun sens, et le message faisait croire a une panne.
    # Le pont DEJA VIVANT, lui, est bien arrete : le teardown le connait
    # desormais (`f:pont/pont.py` dans _td_patterns) et mod_teardown_stop
    # l'applique aussi.
    if [ "$ACTION" != start ]; then
        printf '  %spont TRX%s : non arme (action=%s, pas un demarrage)\n' \
               "${C_DIM:-}" "${C_Z:-}" "$ACTION"
    elif [ -r "$_PONT" ]; then
        # SINGLETON : tuer un pont precedent, sinon il tient 5700-5702 et le
        # teardown de run.sh echoue ("restes du run precedent : port:5700...").
        pkill -f "$_PONT" 2>/dev/null || true
        # [2026-08-16] KILLALL DEMANDE PAR L'OPERATEUR, et assume.
        # Le motif nominatif ci-dessus rate tout pont lance sous un autre chemin
        # (PONT_PY surcharge, une sauvegarde .bak), et c'est ce qui faisait
        # echouer le teardown sur "port:5700 port:5701 port:5702".
        # ⚠️ CE QUE CA EMPORTE, en plus du pont : fake_trx.py (le transceiver de
        # MS#2), sms-interop-relay.py (routage SMS inter-operateurs, HORS pile
        # run.sh donc non relance automatiquement), gsm_sniff.py et les scripts
        # des panes tmux. C'est acceptable ICI parce qu'on est sur le chemin d'un
        # DEMARRAGE (ACTION=start) : le teardown de run.sh va de toute facon tout
        # arreter deux secondes plus tard. Ne PAS reprendre ce geste dans un
        # module de run.sh, ou il tuerait le filtre d'horodatage du run en cours.
        # CALYPSO_NO_KILLALL=1 pour s'en passer.
        if [ "${CALYPSO_NO_KILLALL:-0}" != "1" ]; then
            printf '  %spont TRX%s : python3 du banc termines (fake_trx, pont, airmesh, relais SMS, modem AT)\n' "${C_DIM:-}" "${C_Z:-}"
            killall_python -9 || true
        fi
        sleep 1
        printf '  %spont TRX%s : transceiver TRX-UDP d osmo-bts-trx (pont/pont.py)\n' "${C_DIM:-}" "${C_Z:-}"
        # LANCEMENT DIFFERE : run.sh fait d'abord son teardown (qui verifie que
        # 5700-5702 sont LIBRES). On ne binde donc qu'apres, sinon on se
        # bloque nous-memes. 25 s = teardown + demarrage des modules.
        # LOG HORS LOG_DIR : run.sh archive/efface LOG_DIR pendant son teardown ;
        # un pont.log ouvert avant se retrouve sur un inode SUPPRIME (sortie
        # invisible, "(deleted)" dans /proc/<pid>/fd/1). /dev/shm survit.
        # setsid : le pont doit survivre a la fin du shell de start-native.
        # [2026-08-16] LE `sleep 25` ETAIT UNE COURSE, PAS UNE BARRIERE.
        # 25 s etait un pari sur la duree du teardown de run.sh. Des que
        # celui-ci archive de gros journaux (mesure : 62 Mo -> ~40 s), le pont
        # se rebindait sur 5700-5702 EN PLEIN teardown, qui echouait alors sur
        # "restes du run precedent : port:5700 port:5701 port:5702" et
        # abandonnait toute la sequence. Le symptome se deplacait avec la
        # taille des journaux, ce qui le faisait passer pour intermittent.
        # On attend maintenant un EVENEMENT et non une duree : osmo-bts-trx,
        # qui est l'interlocuteur TRX-UDP du pont et ne demarre qu'APRES le
        # teardown. Sa presence prouve donc que les ports sont a nous.
        # [2026-08-27] LA BARRIERE ATTEND D'ABORD QU'IL DISPARAISSE.
        # Elle n'attendait que sa PRESENCE, en se fiant a « osmo-bts-trx ne
        # demarre qu'APRES le teardown ». Vrai seulement si l'on a fait --stop
        # avant. Sans --stop, l'osmo-bts-trx du run PRECEDENT est encore la :
        # pgrep reussit immediatement (_n=0), le pont binde 5700-5702 en plein
        # teardown, run.sh le tue derriere (f:pont/pont.py est dans
        # _td_patterns) et rien ne le relance -- « le pont n'a pas de bursts ».
        # On attend donc les DEUX fronts : la disparition (le teardown a bien
        # eu lieu), puis l'apparition (la pile est remontee). Avec --stop le
        # premier front est deja franchi et rien ne change.
        ( _n=0
          while [ "$_n" -lt 180 ] && pgrep -x osmo-bts-trx >/dev/null 2>&1; do
              _n=$((_n + 1)); sleep 1
          done
          _dispar=$_n
          while [ "$_n" -lt 180 ] && ! pgrep -x osmo-bts-trx >/dev/null 2>&1; do
              _n=$((_n + 1)); sleep 1
          done
          if [ "$_n" -ge 180 ]; then
              echo "[pont] osmo-bts-trx jamais (re)vu apres 180 s - demarrage quand meme"
          else
              echo "[pont] osmo-bts-trx parti a ${_dispar}s puis revu a ${_n}s - la pile est debout, on binde"
          fi
          sleep 1
          pkill -f "$_PONT" 2>/dev/null; sleep 1
          exec setsid python3 -u "$_PONT" ) >/dev/shm/pont.log 2>&1 &
        disown $! 2>/dev/null || true
        printf '  %spont: journal%s /dev/shm/pont.log (hors LOG_DIR, efface par le teardown)\n' "${C_DIM:-}" "${C_Z:-}"
    else
        printf '  pont introuvable (%s)\n' "$_PONT"
    fi
fi

# --- MAILLAGE DE BURSTS (--air-mesh) : le milieu radio devient commun ---------
# Jusqu'ici deux noeuds se parlaient tout en haut de la pile - un trunk SIP,
# un relais SMS, du M3UA vers un hub - et chacun gardait sa radio hermetique :
# le mobile de l'operateur 1 ne POUVAIT PAS entendre la BTS de l'operateur 2.
# Ici c'est le burst qui traverse : pont/airmesh.py prend ce qui passe sur le
# fake_trx local et l'echange avec les pairs. Voir l'en-tete d'airmesh.py pour
# le detail - notamment pourquoi il faut DEUX emplacements de transceiver, et
# comment on les obtient sans modifier une ligne de qosmo.
if [ "${AIR_MESH:-0}" = "1" ]; then
    _AIRMESH="${AIRMESH_PY:-${HERE}/pont/airmesh.py}"
    [ -f "$_AIRMESH" ] || _AIRMESH=/opt/GSM/osmo-operator/pont/airmesh.py
    if [ ! -f "$_AIRMESH" ]; then
        printf '  %sair-mesh%s : airmesh.py introuvable - maillage de bursts non lance\n' "${C_KO:-}" "${C_Z:-}"
    else
        # DEUX MOBILES DE PLUS QUE LE BANC N'EN A. fake_trx cree un transceiver
        # par mobile declare ; airmesh prend les deux derniers et les accorde
        # autrement (l'un comme un mobile, l'autre comme une BTS). Sans ce +2,
        # il n'y a aucun emplacement libre et airmesh se tait sans rien dire.
        _NMS_REEL="${N_MS:-2}"
        N_MS=$(( _NMS_REEL + 2 )); export N_MS
        _BBP="${BB_BASE_PORT:-6700}"; _BBS="${BB_PORT_STEP:-3}"
        _TRX_MS=$((  _BBP + (_NMS_REEL + 1 - 1) * _BBS ))   # emplacement N+1
        _TRX_BTS=$(( _BBP + (_NMS_REEL + 2 - 1) * _BBS ))   # emplacement N+2

        # Les pairs viennent de la table WAN : tout noeud qui n'est pas nous.
        _PAIRS=""
        for _tok in ${WAN_NODES:-}; do
            _pid="${_tok%%:*}"; _rest="${_tok#*:}"; _pip="${_rest%%:*}"
            [ -n "$_pid" ] && [ -n "$_pip" ] || continue
            [ "$_pid" = "${NODE_ID:-1}" ] && continue
            _PAIRS="$_PAIRS --pair ${_pid}:${_pip}:${AIRMESH_PORT:-4739}"
        done

        printf '  %sair-mesh%s   noeud %s  arfcn %s  emplacements TRXD %s et %s  pairs:%s\n' \
            "${C_DIM:-}" "${C_Z:-}" "${NODE_ID:-1}" "${ARFCN:-514}" \
            "$_TRX_MS" "$_TRX_BTS" "${_PAIRS:- aucun}"

        # On attend que fake_trx ait BINDE l'emplacement, pas une duree : il ne
        # demarre qu'apres le teardown de run.sh, dont la duree depend de la
        # taille des journaux archives. Une temporisation ferait de ce lancement
        # une course - c'est la lecon du pont, juste au-dessus.
        ( _n=0
          while [ "$_n" -lt 180 ] && ! ss -uln 2>/dev/null | grep -q ":$(( _TRX_MS + 1 ))\b"; do
              _n=$((_n + 1)); sleep 1
          done
          if [ "$_n" -ge 180 ]; then
              echo "[airmesh] emplacement $(( _TRX_MS + 1 )) jamais ouvert par fake_trx apres 180 s"
              echo "[airmesh] verifiez que le banc tourne bien avec N_MS=${N_MS} (deux de plus que ${_NMS_REEL})"
              exit 1
          fi
          echo "[airmesh] fake_trx a ouvert nos emplacements apres ${_n} s"
          sleep 1
          # shellcheck disable=SC2086
          exec setsid python3 -u "$_AIRMESH" \
              --node "${NODE_ID:-1}" --arfcn "${ARFCN:-514}" \
              --port "${AIRMESH_PORT:-4739}" \
              --trx-ms "$_TRX_MS" --trx-bts "$_TRX_BTS" \
              --topologie "${HERE}/data/air-mesh.txt" \
              $_PAIRS ) >/dev/shm/airmesh.log 2>&1 &
        printf '  %sair-mesh: journal%s /dev/shm/airmesh.log\n' "${C_DIM:-}" "${C_Z:-}"
    fi
fi

# --- 6. resume ----------------------------------------------------------------
banner
printf '  %sprofil%s     %s (%s)\n' "$C_DIM" "$C_Z" "$CALYPSO_PROFILE" "$MODE"
printf '  %senviron.%s   %s\n' "$C_DIM" "$C_Z" \
    "$(case "$RUNTIME_ENV" in docker) echo "conteneur docker" ;; vm) echo "machine virtuelle" ;; *) echo "machine physique" ;; esac)"
if [ -n "$NODE_ID" ]; then
    printf '  %snoeud%s      %s  %s(%s)%s\n' "$C_DIM" "$C_Z" "$NODE_ID" "$C_DIM" "${NODE_ID_SRC:-?}" "$C_Z"
else
    printf '  %snoeud%s      %s\n' "$C_DIM" "$C_Z" "aucun - identite SS7 inchangee"
fi
printf '  %srun.sh%s     %s\n' "$C_DIM" "$C_Z" "$RUN_SH"
[ -z "${FIRMWARE_ELF:-}" ] || printf '  %sfirmware%s   %s%s\n' "$C_DIM" "$C_Z" "$FIRMWARE_ELF" \
    "${FIRMWARE_SRC:+ (FIRMWARE_SRC)}"
# [2026-09-22] EN --dsp, MS#1 N'EST PAS LE FICHIER GENERE.
# Le module `l2` du fork est retire du plan : /root/.osmocom/bb/mobile.cfg
# n'est ouvert par personne, et le mobile qui tourne est celui du banc DSP
# (mobile_pont.cfg, VTY 4347). Le resume annoncait le mauvais fichier ET le
# mauvais port -- on allait se connecter a une VTY qui n'existe pas.
if [ "$DSP_BANC" = 1 ] && [ "${OSMO_TRX:-0}" = 1 ]; then
    printf '  %sMS#1%s       non lance : le Calypso de QEMU est le TRX de la BTS#0 (--osmo-trx : trx.highram.elf + transceiver, %s)\n' \
        "$C_DIM" "$C_Z" "$(trx_ts_desc)"
elif [ "$DSP_BANC" = 1 ]; then
    _ms1_cfg="${MOBILE_CFG:-$(dirname "$BANC_DSP")/mobile_pont.cfg}"
    _ms1_vty="$(sed -n 's/^ *bind 127.0.0.1 \([0-9]*\).*/\1/p' "$_ms1_cfg" 2>/dev/null | head -1)"
    printf '  %sMS#1%s       %s  IMSI %s  ARFCN %s  VTY %s  %s(banc DSP)%s\n' \
        "$C_DIM" "$C_Z" "$_ms1_cfg" "$(ms_imsi 1)" "$MS_ARFCN1" "${_ms1_vty:-?}" "$C_DIM" "$C_Z"
    printf '  %s           %s non lance (module l2 retire du plan)%s\n' \
        "$C_DIM" "$MS1_CFG" "$C_Z"
else
    printf '  %sMS#1%s       %s  IMSI %s  ARFCN %s  VTY 4247\n' "$C_DIM" "$C_Z" "$MS1_CFG" "$(ms_imsi 1)" "$MS_ARFCN1"
fi
# [2026-10-12] LE PORT VTY DU MOBILE EST PUBLIE, PAS DEVINE. En --dsp le
# mobile ecoute sur 4347 (mobile_pont.cfg), sinon sur 4247 - et tout ce qui
# ouvre « la console du mobile » (launch.sh --vty, l encart osmo-panel.py, le
# tableau de bord osmo-egprs-web pour le Kc et la VTY bb1) tapait 4247 en
# dur : en DSP, connexion refusee. Le port est ecrit dans
# /run/osmo-banc/ms1-vty (lu par les outils de session) et pousse dans
# l environnement de systemd (OSMO_BB1_VTY_PORT, lu par server.js au
# redemarrage du tableau de bord, plus bas). Efface a l arret.
MS1_VTY_PORT="${_ms1_vty:-4247}"
# [2026-10-19] LE JOURNAL DU MOBILE EST PUBLIE DE LA MEME FACON. Il vit sous
# LOG_DIR (qosmo, run_modules/70-l2.sh : « mobile ... >>LOG_DIR/mobile.log »),
# et en --dsp sous le RUNDIR de c54x_exe (run.sh : RUNDIR/mobile.log, /tmp/
# c54x-pont par defaut). L encart osmo-fft-snap.py tapait /run/user/0/... en
# dur : LOG_DIR suit l uid qui lance (XDG_RUNTIME_DIR), et le cadre restait sur
# « pas encore de journal ». Le chemin reel est ecrit dans
# /run/osmo-banc/mobile-log et pousse dans l environnement de systemd
# (OSMO_MOBILE_LOG). Efface a l arret, avec ms1-vty.
# [2026-10-23] --bts --ms / --ms-magnetite : le telephone est l INSTANCE 2 de run.sh (14-demarrage.sh,
# INSTANCE=2 AIR=1), son RUNDIR est /tmp/c54x-pont2 ; /tmp/c54x-pont est celui du TRX, sans mobile.
_ms1_rundir="${RUNDIR:-/tmp/c54x-pont}"
[ "${OSMO_TRX:-0}" = 1 ] && [ "${MS_AIR:-0}" = 1 ] && _ms1_rundir="${RUNDIR:-/tmp/c54x-pont2}"
MS1_LOG_NOM="mobile.log"
if [ "$DSP_BANC" = 1 ] && [ -n "${MS_MAGNETITE:-}" ]; then
    # [2026-10-22] Magnetite : pas de mobile L23, le journal du telephone est la trace L1/pile TI de rvinterf
    MS1_LOG="$_ms1_rundir/rvinterf.log"
    MS1_LOG_NOM="rvinterf"
elif [ "$DSP_BANC" = 1 ]; then
    MS1_LOG="$_ms1_rundir/mobile.log"
else
    MS1_LOG="$LOG_DIR/mobile.log"
fi
# [2026-10-24] exporte : la fenetre ms1 de tmux (qosmo tmux_modules/bench.sh) suit le journal du telephone
# (rvinterf en Magnetite) au lieu d'un mobile.log vide
export MS1_LOG MS1_LOG_NOM
if [ "$ACTION" = "start" ] && [ "$DRY" -ne 1 ]; then
    mkdir -p /run/osmo-banc 2>/dev/null && chmod 755 /run/osmo-banc 2>/dev/null
    printf '%s\n' "$MS1_VTY_PORT" > /run/osmo-banc/ms1-vty 2>/dev/null && chmod 644 /run/osmo-banc/ms1-vty 2>/dev/null
    printf '%s\n' "$MS1_LOG" > /run/osmo-banc/mobile-log 2>/dev/null && chmod 644 /run/osmo-banc/mobile-log 2>/dev/null
    command -v systemctl >/dev/null 2>&1 && systemctl set-environment "OSMO_BB1_VTY_PORT=$MS1_VTY_PORT" "OSMO_MOBILE_LOG=$MS1_LOG" 2>/dev/null || true
fi
printf '  %sMS#2%s       %s  IMSI %s  ARFCN %s  VTY 4248\n' "$C_DIM" "$C_Z" "$MS2_CFG" "$(ms_imsi 2)" "$MS_ARFCN2"
printf '  %sjournaux%s   %s\n' "$C_DIM" "$C_Z" "$LOG_DIR"
printf '  %s%-10s%s %s\n' "$C_DIM" "$MS1_LOG_NOM" "$C_Z" "$MS1_LOG"
printf '  %schiffrement%s %s\n' "$C_DIM" "$C_Z" "$ENCRYPTION"
printf '\n'
# --- 7. actions deleguees a run.sh --------------------------------------------
RUN_ARGS=()
[ "$DRY" -eq 1 ]     && RUN_ARGS+=(--dry-run)
[ "$FORCE" -eq 1 ]   && RUN_ARGS+=(--force)
[ "$VERBOSE" -eq 1 ] && RUN_ARGS+=(--verbose)
RUN_ARGS+=(--profile "$CALYPSO_PROFILE")
# [2026-08-08] --restart etait ajoute DIRECTEMENT sur la ligne exec, hors de
# RUN_ARGS. Consequence : `--dry-run` affichait une commande SANS --restart puis
# le vrai lancement en ajoutait un. Une simulation qui ne decrit pas ce qui va
# se passer est pire qu'absente. Il entre donc dans RUN_ARGS, ou il est visible.
# CALYPSO_NO_RESTART=1 pour demarrer sans reinitialiser (l'ancien comportement
# n'etait pas atteignable du tout).
[ "${CALYPSO_NO_RESTART:-0}" = "1" ] || RUN_ARGS+=(--restart)
# run.sh lit deja CALYPSO_NO_ATTACH (run.sh:8), mais une variable ne se voit
# pas dans --dry-run ni dans la ligne affichee juste avant l exec : l option
# porte le meme reglage la ou on le cherche.
[ "${CALYPSO_NO_ATTACH:-0}" = "1" ] && RUN_ARGS+=(--no-attach)
# [2026-10-19] --icount et --assembly-logs vers run.sh, donc vers 40-qemu.sh
# (chemin --grgsm ; en --dsp le module qemu est retire, c54x_exe/run.sh lit
# QEMU_ICOUNT et ASSEMBLY_LOGS lui-meme). Memes -d / -dfilter que le banc DSP.
case "${QEMU_ICOUNT:-}" in ''|0|off) ;; *) RUN_ARGS+=("--icount=$QEMU_ICOUNT") ;; esac
if [ "${ASSEMBLY_LOGS:-0}" = 1 ]; then
    RUN_ARGS+=(--asm)
    # [2026-10-19] in_asm seul par defaut : exec,nochain (une ligne par bloc
    # execute, 494 Mo en 90 s) rendait l'ARM 150 fois plus lent et cassait
    # l'attach, voir l'aide de --assembly-logs.
    export QEMU_ASM_FLAGS="${ASSEMBLY_LOGS_FLAGS:-in_asm}"
    [ -n "${ASSEMBLY_LOGS_FILTRE:-}" ] && export QEMU_ASM_FILTRE="$ASSEMBLY_LOGS_FILTRE"
fi
# ── Les sessions tmux d'un run precedent ────────────────────────────────────
# Le teardown de run.sh arrete les processus mais laisse la session tmux
# debout. Au demarrage suivant, son module de panes RECREE ses fenetres dans la
# session survivante : il y a alors DEUX fenetres nommees « all ».
#
# Et deux fenetres de meme nom ne sont pas seulement inesthetiques : tmux ne
# sait plus resoudre la cible. Verifie sur le banc, tmux 3.2a :
#     $ tmux split-window -t calypso:all
#     can't find window: all
# Les trois splits echouent, le module les compte comme "pane refuse par tmux
# (place insuffisante)" - un diagnostic FAUX qui envoie chercher un probleme de
# taille de terminal - et la barriere conclut « la fenetre "all" n'a pas garde
# ses panes ». La cause etait deux fenetres plus haut.
#
# On efface donc les sessions du run precedent avec lui. Trois conventions
# cohabitent selon le lanceur, on les couvre toutes ; aucune n'a besoin
# d'exister.
purge_sessions_tmux() {
    local n=0 s
    for s in calypso gapk osmo; do
        if tmux has-session -t "$s" 2>/dev/null; then
            tmux kill-session -t "$s" 2>/dev/null && n=$((n + 1))
        fi
    done
    if tmux -S /tmp/osmocom_tmux has-session -t osmocom 2>/dev/null; then
        tmux -S /tmp/osmocom_tmux kill-session -t osmocom 2>/dev/null && n=$((n + 1))
    fi
    [ "$n" -gt 0 ] && printf '  %ssessions tmux%s   %s session(s) du run precedent effacee(s)\n' \
        "${C_DIM:-}" "${C_Z:-}" "$n"
    return 0
}


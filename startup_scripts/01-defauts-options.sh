# 01-defauts-options.sh - partie de start.sh (lignes 41-542 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.

# ── LE NOMBRE D'ABONNES NE PASSE PAS PAR ~/.bashrc ──────────────────────────
# [2026-09-04] /etc/osmocom/coeur.env (N_MS, ecrit par build-iso.sh) n'etait
# charge que par /root/.bashrc - donc SEULEMENT dans un shell interactif de
# root. Depuis l'icone (launch.sh -> pkexec), depuis une unite systemd ou
# depuis start-multi.sh, personne ne le lisait : run_modules/21-abonnes-hlr.sh
# retombait sur N_MS=1, le HLR n'avait que 100101, et le second mobile se
# faisait creer a la volee par « subscriber-create-on-demand 5 » avec un
# MSISDN aleatoire a cinq chiffres (31804) et SANS Ki - donc injoignable et
# rejete a l'authentification. On le charge ici, une fois pour toutes ; le
# « := » du fichier laisse gagner un N_MS=3 pose dans l'environnement.
if [ -f "${OSMOCOM_CFG:-/etc/osmocom}/coeur.env" ]; then
    set -a; . "${OSMOCOM_CFG:-/etc/osmocom}/coeur.env"; set +a
fi
# --- options ------------------------------------------------------------------
DRY=0 VERBOSE=0 ACTION=start PROFILE="${CALYPSO_PROFILE:-faketrx-qemu}" FORCE=0
# [2026-10-14] SAP desactive par defaut : la SIM du mobile est la SIM de test.
# --sap : la SIM est SERVIE au mobile (sim sap) par le serveur SAP de softSIM,
# lance ici avant la pile. SAP_TYPE : pcsc = la carte du lecteur PC/SC (HID
# Omnikey, sysmoISIM programmee par tools/osmo-sim.sh), sim = la SIM logicielle
# sim-op1.xml (IMSI du MS#1, COMP128v1, Ki du HLR), auto = pcsc si une carte
# est dans un lecteur, sinon sim. SAP_SOCK : le socket (celui de MS#1).
: "${SAP_MODE:=0}"
: "${SAP_TYPE:=auto}"
: "${SAP_SOCK:=/tmp/osmocom_sap}"
# 1 des que l'operateur a nomme un profil (--profile, ou le mode en positionnel).
# Sert a --dsp, qui choisit `qemu` SEULEMENT si personne n'a choisi avant lui.
PROFILE_CHOISI=0
[ -n "${CALYPSO_PROFILE:-}" ] && PROFILE_CHOISI=1
# WAN : jamais par defaut. --wan (ou WAN_AUTO=1 dans /etc/osmo-wan.conf, ce que
# pose une ISO construite avec --wan) le monte avant de passer la main a run.sh.
WAN_MESH=0
# Ce que la table retiendra (WAN_AUTO_SAVE, network/wan-nodes.sh) : 1 seulement
# si c'est WAN_AUTO=1 qui monte le WAN ; un --wan sur la ligne vaut pour CE
# lancement et laisse WAN_AUTO=0, pour que le suivant demarre sans WAN.
WAN_AUTO_KEEP=0
# Inter-STP (hub SS7) lance en standalone a cote du WAN : auto = seulement si le
# hub n'existe pas encore sur le reseau (ni adresse locale, ni reponse ping).
# --interstp force, --no-interstp passe. Un seul hub pour tout le WAN : sur le
# noeud qui ne le porte pas, le hub distant est reconnu et laisse en place.
INTERSTP=auto
# --wan FICHIER : fiches de noeuds a importer (network/node-conf.sh).
WAN_IMPORT_FILES=()
# --regen-conf : la table WAN est reconstruite DE ZERO. La table en place
# (/etc/osmo-wan.conf) survit aux relances et garde les noeuds qu'on y a vus un
# jour ; un pair eteint y laisse une route qui passe PROHIB au STP. On met la
# table de cote (sauvegarde horodatee) et on repart de ce que la ligne donne
# (--wan-nodes), des fiches (--wan FICHIER) ou de la question interactive.
REGEN_WAN_CONF=0
# --payload-ism : le TEXTE des SMS part par radio ISM, le reste (signalisation,
# SS7, SIP) par IP comme --wan. PAYLOAD_ISM_LINK = backend si donne (--payload-ism=serial).
PAYLOAD_ISM=0
PAYLOAD_ISM_LINK=""
GEN_CONF_OUT=""
# --virtualbox : monte le segment et les VM avant le WAN. Refuse si l'on tourne
# DANS une VM - c'est l'hote qui pilote VirtualBox (le script le verifie).
VBOX_INTERCO=0
VBOX_NODES=""
VBOX_HOST_NODE=1
# --node : le numero de CE noeud, choisi au lancement et pas a la construction.
# C'est ce qui permet une ISO unique pour les neuf noeuds.
NODE_ID=""
NODE_OP=1
HUB_IP=""
# Les gabarits ne sont PAS regeneres par defaut : run.sh le ferait au demarrage
# et effacerait l'identite SS7 posee juste avant. --regen retablit l'ancien
# comportement pour qui veut repartir des gabarits.
REGEN_GABARITS=0
# --menu : demande les choix au lieu de les deviner. Voir le bloc « Menu » plus bas.
MENU_MODE=0
# ── LA COUCHE 1 PAR DEFAUT : LE DSP ──────────────────────────────────────────
# [2026-10-01] Le banc demarre en DSP (c54x_exe, mask-ROM TI) sans qu on le
# demande : c est le banc qu on veut voir au premier clic, en service comme en
# terminal, en standalone comme sous osmo-multi (qui lance le natif par
# osmo-banc.service, donc par ce defaut). --grgsm remet la couche 1 gr-gsm.
# L environnement gagne (DSP_MODE=0 ./start-native.sh), comme pour le reste.
# Si c54x_exe n est pas la, le banc retombe sur gr-gsm et le dit (plus bas).
: "${DSP_MODE:=1}"
usage() {
    cat <<'USAGE'
Usage : ./start-native.sh [options] [mode]
  Modes (profils) :
    faketrx-qemu   coeur + BTS#0 QEMU + BTS#1 faketrx (defaut)
    faketrx        coeur + fake_trx + trxcon + mobile
    qemu           pipeline Calypso QEMU seul
    noproc         coeur seul (no-process)
    core           alias noproc
    hybrid         alias faketrx-qemu
  Options :
    --docker            banc en conteneurs : passe la main a
                        launch/start-docker.sh avec les autres arguments
    --dsp               (defaut) banc DSP C54x : le TMS320C54x tourne hors QEMU
                        (/opt/GSM/c54x_exe, mask-ROM TI) et decode lui-meme
                        FCCH/SCH/BCCH ; aucun decodeur gr-gsm n'est lance.
                        Le mobile campe (SI1-4, lai=001-01-1) et fait sa mise
                        a jour de localisation. La pile monte comme en mode
                        grgsm (meme profil hybride, coeur, BTS, side-car) ;
                        seuls les modules qemu,pty,osmocon,l2 sont retires et
                        repris par c54x_exe/run.sh. BANC_DSP=none pour n'avoir
                        que la pile.
    --grgsm             couche 1 gr-gsm dans QEMU (qosmo) + pont grgsm_exe
                        (l ancien defaut ; DSP_MODE=0 dans l environnement vaut pareil)
    --bts-classic       [2026-10-21] (alias : --bts-classique) la BTS CLASSIQUE : osmo-bts-trx parle a pont/pont_dsp.py
                        (TRXD 5700-5702), sans Calypso TRX dans QEMU ; le mobile emule
                        (QEMU + c54x_exe, MODE=dsp) est branche sur le pont. C'est le montage
                        par defaut de --dsp, nomme ; OSMO_TRX=0 force (meme si l environnement
                        l exporte). Exclusif avec --bts / --ts.
                            ./start-native.sh --bts-classic [--ms]           mobile osmocom-bb
                            ./start-native.sh --bts-classic --ms-magnetite   le C139 Magnetite
    --bts               [2026-10-20] (alias : --osmo-trx) le Calypso de QEMU est le
                        TRANSCEIVER de la BTS#0 : firmware trx.highram.elf
                        (osmocom-bb-transceiver, appli « trx ») + appli hote
                        `transceiver` (L1CTL -> TRXD 5700-5702) a la place de
                        mobile et du pont ; osmo-bts-trx s'y branche comme sur le
                        pont. Implique --dsp (c54x_exe/run.sh, OSMO_TRX=1). Par
                        defaut UN Calypso sert TS0 et TS1 (OSMO_TRX_TCH=1, masques
                        0x03) ; voir --ts.
    --ts N              [2026-10-20] intervalles de temps du TRX Calypso (implique --bts) :
                            --ts 1   TS0 seul (CCCH + SDCCH/4, pas d'appel) : OSMO_TRX_TCH=0
                            --ts 2   TS0 + TS1, UN CALYPSO PAR INTERVALLE : le TS1 (TCH/F,
                                     les appels) est servi par un deuxieme telephone TRX
                                     (c54x_exe/run.sh OSMO_TRX_TS1=1, instance 3,
                                     transceiver -2 -L /tmp/osmocom_l2_3) ; le premier
                                     garde le TS0 seul (OSMO_TRX_TCH=0). [21/10] PAS D'APPEL
                                     dans ce mode : le fn du 2e telephone n'est pas aligne
                                     (TCH descendant a ~80 bits faux, ASSIGNMENT FAILURE).
                            --ts 2/1 TS0 + TS1 par UN SEUL Calypso (OSMO_TRX_TCH=1, masques
                                     0x03, OSMO_TRX_TS1=0) : le montage qui a passe un
                                     appel audible le 20/10 21:08.
                        Sans --ts : comme --ts 2/1 (21/10 ; du 20/10 23:10 au 21/10 c'etait --ts 2).
    --ms                [2026-10-20] le telephone emule est un MOBILE. Seul (ou sans
                        option) : le montage habituel, mobile + pont vers osmo-bts-trx.
                        AVEC --bts : un DEUXIEME Calypso (c54x_exe/run.sh INSTANCE=2,
                        alias banc-mobile) campe sur le premier par l'air (pont/air.py) ;
                        il est lance quand le firmware trx est en mode BTS.
                            ./start-native.sh --bts          la radio de la BTS seule
                            ./start-native.sh --bts --ms     la BTS et le mobile, par l'air
    --ms-magnetite      [2026-10-21] comme --ms, mais le mobile est le VRAI firmware TI :
                        FreeCalypso Magnetite (cible c139, config hybrid-ui-vo, compile
                        avec le TMS470 sous Wine ; doc/magnetite.md) en flash a la place
                        du layer1 osmocom-bb (c54x_exe/run.sh FIRMWARE_FLASH=...). Pile
                        L23 et interface dans le firmware : pas d'osmocon ni de mobile,
                        rvinterf decode les traces, ecran couleur du C139 dans
                        tools/osmo-c123-gtk.py --modele c139. MAGNETITE_FLASH=<image>
                        (defaut /opt/GSM/firmware/magnetite/c139-flash.img).
                            ./start-native.sh --bts --ms-magnetite   la BTS et le C139 Magnetite, par l'air
                            ./start-native.sh --ms-magnetite         le C139 Magnetite seul, par le pont
    --vocoder-rom       [2026-10-22] DEFAUT. Le codec FR de la mask-ROM du DSP vocode (port voix
                        SP0 modelise, CALYPSO_VSP=1, pont/vsp_audio.py) : BANC_VOCODEUR=rom.
                        Le C54x emule doit alors tenir le temps reel AVEC le codec.
    --gapk              [2026-10-22] Le vocodeur tourne sur l'hote (osmo-gapk dans le mobile L23) :
                        BANC_VOCODEUR=hote, CALYPSO_VSP=0, TCH montant code par l'hote
                        (PONT_UL_RAW_TCH=0). Le DSP ne fait plus que le canal : il tient le temps
                        reel. Mobile osmocom seulement : le firmware TI (--ms-magnetite) vocode
                        toujours dans la ROM.
    --sap, --softsim    SIM via SAP : serveur softSIM (Ruby, /opt/GSM/softsim) sur
                        /tmp/osmocom_sap, lance avant la pile ; le MS#1 passe en
                        « sim sap ». Sert la carte du lecteur PC/SC (HID Omnikey,
                        sysmoISIM : tools/osmo-sim.sh programmer) si une carte y
                        est, sinon la SIM logicielle sim-op1.xml (IMSI du MS#1).
    --sap=pcsc          SIM via SAP : la carte du lecteur, obligatoirement
                        (--omnikey, --sim-reader : pareil)
    --sap=sim           SIM via SAP : la SIM logicielle, meme avec une carte
    --no-sap            pas de SIM via SAP (la SIM de test du mobile), par defaut
    --launcher <bin>    lanceur C de QEMU a utiliser (defaut : /usr/local/bin/qosmo).
                        Il remplace l'appel direct a qemu-system-arm : memes
                        defauts, sockets et pty publies (<RUN_DIR>/modem.pty),
                        osmocon direct. Se compile dans
                        /opt/GSM/qosmo/tools/qosmo-launch (make ALIAS=qosmo install).
    --list              affiche le plan (delegue a run.sh --list)
    --dry-run           deroule sans effet de bord
    --profile <nom>     force le profil
    --stop              arrete la pile (delegue a run.sh --stop)
    --status            interroge l'etat (delegue a run.sh --status)
    --force             relance meme les modules deja demarres
    --verbose           montre la sortie des modules
    --assembly-logs     trace asm de l'ARM emule (= ASSEMBLY_LOGS=1) : QEMU
                        -d in_asm -D /var/tmp/c54x-pont/qemu-asm.log (lien
                        /tmp/c54x-pont/qemu-asm.log ; ASSEMBLY_LOGS_DIR change le
                        dossier, sur le disque : /tmp est un tmpfs de 4,7 Go),
                        chaque bloc une fois, a sa traduction, PLUS l'anneau des
                        blocs executes (plugin TCG qosmo/tools/qosmo-tbring) :
                        64 Gio creux dans le meme dossier (qemu-tbring), le PC de
                        chaque bloc execute, chaines compris, relu a chaud par
                        tbring-dump -n 500 -e <elf> -a qemu-asm.log. Rien de texte
                        dans la boucle : l'ARM garde son rythme. ASSEMBLY_LOGS_RING=0
                        coupe l'anneau. ASSEMBLY_LOGS_FLAGS
                        change les -d, ASSEMBLY_LOGS_FILTRE pose un -dfilter (ex.
                        0x00820000+0x40000). ASSEMBLY_LOGS_FLAGS=in_asm,exec,nochain
                        journalise aussi chaque execution en texte (150 Mo/s,
                        20 Go en 130 s ; QEMU_LOG_BUFFERED=4 Mio vide a chaque
                        arret de la VM) ; avant la correction de cpu_idle_park
                        du 2026-10-19 (qosmo calypso_trx.c) :
                        l'ARM passe de 0,4 a 62 ms par trame, le DSP en pas-a-pas
                        suit, l'horloge du pont (pont/trx.py) descend jusqu'a
                        PONT_HORLOGE_MAX x le temps reel (16 avec ASSEMBLY_LOGS=1,
                        4 sinon) et les IND CLOCK attendent la reprise de la BTS
                        (osmo-bts-trx s'arrete au-dela de 50 trames de pause).
                        Les temporisateurs de mobile (T3210 20 s) et du reseau
                        (T3101) restent muraux : a 14 x, l'attach peut encore
                        buter dessus. Runs du 2026-10-19 02:06 et 02:20.
    --icount[=SPEC]     QEMU avec -icount SPEC (defaut : auto ; = QEMU_ICOUNT),
                        en --dsp (c54x_exe) comme en --grgsm (run_modules/40-qemu).
    --no-attach         ne s'attache pas a tmux a la fin (= CALYPSO_NO_ATTACH=1 ;
                        c'est ce que pose osmo-banc.service : personne devant)
    --check-paths       verifie les dependances declarees
    --wan               monte le WAN a N noeuds (1 a 9) AVANT run.sh et demande :
                          nombre de noeuds, IP de chaque noeud, indicatif de
                          chaque noeud, numero du noeud construit par ce lancement
    --wan mynode1.conf [--wan mynode3.conf ...]
                        WAN a partir des FICHES des autres noeuds (ecrites par
                        leur run : /etc/osmocom/mynode<N>.conf). Ce noeud est
                        ajoute a la table avec son adresse locale ; aucune
                        question. Le maillage SIP + SMS suit comme avec --wan.
    --gen-conf [FICHIER] ecrit la fiche de CE noeud (defaut
                        /etc/osmocom/mynode<N>.conf) SANS lancer le banc. Le
                        run l'ecrit de toute facon, juste avant run.sh.
    --wan-nodes "1:IP:IND ..."   meme chose sans question (scriptable)
    --wan-id N          numero du noeud local (sinon deduit des IP locales)
    --wan-conf FICHIER  table a lire/ecrire (defaut /etc/osmo-wan.conf)
    --regen-conf        reconstruit la table WAN DE ZERO (implique --wan) : la
                        table en place est sauvegardee puis effacee, on repart
                        de --wan-nodes / des fiches / de la question. A utiliser
                        quand un pair eteint laisse une route PROHIB au STP.
    --payload-ism[=BACKEND]
                        le TEXTE des SMS entre noeuds part par une liaison RADIO
                        en bande ISM ; tout le reste (signalisation, SS7, SIP)
                        reste sur IP, comme --wan (a combiner avec --wan). Le
                        relais met un jeton dans le TCP et le texte sur la radio.
                        BACKEND = serial|exec|fifo|loopback. Sans BACKEND, lit la
                        section [payload] deja ecrite par network/setup-payload-ism.sh.
                        Peripherique/commandes par l'env : ISM_SERIAL, ISM_TX,
                        ISM_RX, ISM_TX_CMD, ISM_RX_CMD. Voir wiki/Payload-ISM.md.
    --node N            numero de CE noeud, 1 a 9. DEDUIT AUTOMATIQUEMENT s'il
    --menu              demande les choix au lieu de les deviner : profil,
                        noeud, operateur, inter-STP, WAN, regeneration des
                        configs. Les valeurs proposees sont
                        celles que le lanceur aurait prises tout seul, donc
                        valider sans rien changer equivaut a ne pas passer
                        l'option. Sans terminal, l'option est ignoree.
    --regen             regenere les configs depuis les gabarits (par defaut on
                        CONSERVE celles deja en place : run.sh les ecraserait)
                        est omis : environnement, puis /etc/osmo-role, puis la
                        table WAN comparee aux adresses locales. Cette option
                        ne sert qu'a forcer. Reecrit son identite SS7
                        (point codes 1.<noeud><op>.<role>, routing contexts) et
                        pointe son ASP sur l'inter-STP. Une seule ISO suffit
                        alors pour les neuf noeuds - le numero se choisit ici.
    --op N              operateur porte par ce noeud (defaut 1)
    --hub-ip ADRESSE    inter-STP a joindre (defaut : selon docker ou VM ; natif : 192.168.1.49)
    --interstp          lance le inter-STP en standalone sur ce noeud (force)
    --no-interstp       ne lance pas le inter-STP (defaut : auto, avec --wan)
    --air-mesh[=PORT]   maillage de BURSTS entre noeuds : le milieu radio
                        devient commun et un mobile peut entendre - et choisir -
                        la BTS d'un autre noeud. Les pairs viennent de la table
                        WAN, la portee de data/air-mesh.txt. Declare deux
                        mobiles de plus pour s'y brancher (voir pont/airmesh.py).
    --virtualbox[=N]    WAN entre CETTE machine et N-1 VM VirtualBox (implique
                        --wan). A lancer depuis l'hote, pas depuis une VM.
    --vbox-node N       numero de noeud porte par cette machine (defaut 1)
    --mobile            client de couche 2 = mobile (defaut) -- pile L2/L3
                        complete derriere le firmware QEMU
    --ccch_scan         client de couche 2 = ccch_scan -- ecoute le CCCH
    --bcch_scan         client de couche 2 = bcch_scan -- releve les BCCH
    --cell_log          client de couche 2 = cell_log -- journal de cellules
                        Ces quatre-la sont EXCLUSIFS et ECRASENT le mobile de
                        QEMU : ils prennent sa socket L1CTL et sa VTY.
    -h, --help          cette aide

  Sans --wan : aucun WAN. Avec --wan le profil reste faketrx-qemu (hybride,
  1 faketrx + 1 QEMU Calypso), qui est deja le defaut de ce script.
  Composer <indicatif><numero> joint ce numero sur le noeud correspondant.
Toute variable CALYPSO_* passee en prefixe est transmise a run.sh / QEMU :
  CALYPSO_LANG=en ./start-native.sh       CALYPSO_NO_ATTACH=1 ./start-native.sh
USAGE
}
while [ $# -gt 0 ]; do
    case "$1" in
        --list)        ACTION=list ;;
        --dry-run)     DRY=1 ;;
        --profile)     if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                           printf '%s\n\n' "--profile attend un nom de profil" >&2
                           usage >&2; exit 2
                       fi
                       PROFILE="$2"; PROFILE_CHOISI=1; shift ;;
        --stop)        ACTION=stop ;;
        --status)      ACTION=status ;;
        --force)       FORCE=1 ;;
        --verbose)     VERBOSE=1 ;;
        --assembly-logs) ASSEMBLY_LOGS=1 ;;
        --icount)      QEMU_ICOUNT=auto; export QEMU_ICOUNT ;;
        --icount=*)    QEMU_ICOUNT="${1#*=}"; export QEMU_ICOUNT ;;
        # [2026-09-04] Equivalent de CALYPSO_NO_ATTACH=1, en option de ligne de
        # commande pour que l'unite systemd le dise sur son ExecStart. Avant, cette
        # option n'existait pas : posee sur ExecStart elle tombait dans « option
        # inconnue » (exit 2), et posee ailleurs dans l'unite elle cassait la ligne
        # qui la portait (ConditionPathExists=... --no-attach : chemin inexistant,
        # unite jamais lancee).
        --no-attach)   CALYPSO_NO_ATTACH=1; export CALYPSO_NO_ATTACH ;;
        --check-paths) ACTION=checkpaths ;;
        --wan)         WAN_MESH=1
                       # --wan FICHIER : la fiche d'un autre noeud (network/node-conf.sh).
                       if [ -n "${2:-}" ] && [ -f "$2" ]; then WAN_IMPORT_FILES+=("$2"); shift; fi ;;
        --gen-conf)    ACTION=genconf
                       if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then GEN_CONF_OUT="$2"; shift; fi ;;
        --gen-conf=*)  ACTION=genconf; GEN_CONF_OUT="${1#*=}" ;;
        # [2026-09-22] --dsp ne change NI de fork NI de profil : la pile monte
        # exactement comme en mode grgsm (coeur, BTS, side-car, tmux), et seuls
        # les quatre modules de la chaine Calypso (qemu, pty, osmocon, l2) sont
        # remis a /opt/GSM/c54x_exe, ou le C54x tourne hors QEMU sur la mask-ROM
        # TI. [2026-09-25] Les forks qosmo-dsp/qosmo-grgsm sont retires : un
        # seul arbre QEMU, /opt/GSM/qosmo (run.sh et run_modules y sont), et la
        # couche 1 est c54x_exe (--dsp) ou gr-gsm + grgsm_exe (--grgsm).
        --dsp)         DSP_MODE=1 ;;
        --grgsm)       DSP_MODE=0 ;;
        # [2026-10-19] --osmo-trx : le banc DSP lance trx.highram.elf et l appli
        # hote transceiver (voir c54x_exe/run.sh, OSMO_TRX=1) ; implique --dsp.
        --osmo-trx|--bts) DSP_MODE=1; OSMO_TRX=1; export OSMO_TRX; BTS_TRX_CHOISI="$1" ;;
        # [2026-10-21] --bts-classic : osmo-bts-trx <-> pont_dsp.py, pas de Calypso TRX (voir l'aide)
        --bts-classic|--bts-classique) DSP_MODE=1; BTS_CLASSIC=1 ;;
        # [2026-10-20] --ts N : 1 = TS0 seul ; 2 = TS0 + TS1, un Calypso TRX par intervalle
        # (OSMO_TRX_TS1=1 : instance 3 pour le TS1). Implique --bts. Exporte plus bas (export_trx_ts).
        --ts)          if [ $# -lt 2 ] || ! [[ "${2:-}" =~ ^(1|2|2/1)$ ]]; then
                           printf '%s\n\n' "--ts attend 1 (TS0 seul), 2 (TS0 + TS1, un Calypso par intervalle) ou 2/1 (TS0 + TS1, un seul Calypso)" >&2
                           usage >&2; exit 2
                       fi
                       OSMO_TRX_TS="$2"; DSP_MODE=1; OSMO_TRX=1; export OSMO_TRX; BTS_TRX_CHOISI=--ts; shift ;;
        --ts=*)        OSMO_TRX_TS="${1#*=}"
                       [[ "$OSMO_TRX_TS" =~ ^(1|2|2/1)$ ]] || { printf '%s\n\n' "--ts attend 1, 2 ou 2/1 (recu : $OSMO_TRX_TS)" >&2; usage >&2; exit 2; }
                       DSP_MODE=1; OSMO_TRX=1; export OSMO_TRX; BTS_TRX_CHOISI=--ts ;;
        # [2026-10-20] --ms : sans --bts c'est le defaut (mobile + pont) ; avec --bts, l'instance 2 par l'air
        --ms)          MS_AIR=1 ;;
        # [2026-10-21] --ms-magnetite : --ms avec le firmware TI (Magnetite) en flash, voir l'aide
        --ms-magnetite) MS_AIR=1; MS_MAGNETITE=1
                       MAGNETITE_FLASH="${MAGNETITE_FLASH:-/opt/GSM/firmware/magnetite/c139-flash.img}"
                       [ -r "$MAGNETITE_FLASH" ] || { printf '%s\n' "--ms-magnetite : image flash absente : $MAGNETITE_FLASH (doc/magnetite.md : build fc-magnetite c139 hybrid-ui-vo)" >&2; exit 2; }
                       # [2026-10-21 11:10] PAS d'export ici : exporte, FIRMWARE_FLASH atteignait aussi l'instance 1
                       # (la radio de la BTS) qui bootait Magnetite au lieu du firmware trx. Il n'est passe qu'au
                       # mobile (exec ci-dessous).
                       # [2026-10-21 23:20] MS_MAGNETITE, lui, EST exporte : qosmo/run_modules/08-gabarits.sh regenere
                       # les gabarits dans run.sh (autre bash), et sans lui generate_configs.sh posait SDCCH8 au TS1
                       # (__TS1_PCHAN_BTS0__) : IMM ASS sur TS1, SABM de Magnetite sur TS0, LU en Timeout.
                       export MS_MAGNETITE
                       ;;
        # [2026-10-22] vocodeur : la ROM du DSP (defaut, 14-demarrage.sh) ou GAPK sur l'hote. Exportes ici :
        # /etc/default/osmo-banc (BANC_VOCODEUR=rom, CALYPSO_VSP=1, PONT_UL_RAW_TCH=1) ne remplit que le vide.
        --vocoder-rom|--vocodeur-rom) BANC_VOCODEUR=rom; CALYPSO_VSP=1; export BANC_VOCODEUR CALYPSO_VSP ;;
        --gapk|--vocodeur-hote) BANC_VOCODEUR=hote; CALYPSO_VSP=0; PONT_UL_RAW_TCH=0
                       export BANC_VOCODEUR CALYPSO_VSP PONT_UL_RAW_TCH ;;
        --sap)         SAP_MODE=1; export SAP_MODE ;;
        --sap=*)       SAP_MODE=1; SAP_TYPE="${1#*=}"; export SAP_MODE SAP_TYPE ;;
        --softsim)     SAP_MODE=1; export SAP_MODE ;;   # alias de --sap
        --omnikey|--sim-reader) SAP_MODE=1; SAP_TYPE=pcsc; export SAP_MODE SAP_TYPE ;;
        --no-sap)      SAP_MODE=0; export SAP_MODE ;;
        --launcher)    QOSMO_LAUNCHER="${2:-}"; export QOSMO_LAUNCHER; shift ;;
        --launcher=*)  QOSMO_LAUNCHER="${1#*=}"; export QOSMO_LAUNCHER ;;
        --wan=*)       WAN_MESH=1
                       if [ -f "${1#*=}" ]; then WAN_IMPORT_FILES+=("${1#*=}"); else WAN_NODES="${1#*=}"; fi ;;
        --wan-nodes)   WAN_MESH=1; WAN_NODES="${2:-}"; shift ;;
        --wan-nodes=*) WAN_MESH=1; WAN_NODES="${1#*=}" ;;
        --wan-id)      WAN_MESH=1; WAN_NODE_ID="${2:-}"; shift ;;
        --wan-id=*)    WAN_MESH=1; WAN_NODE_ID="${1#*=}" ;;
        --wan-conf)    WAN_CONF_FILE="${2:-}"; shift ;;
        --wan-conf=*)  WAN_CONF_FILE="${1#*=}" ;;
        --payload-ism)   PAYLOAD_ISM=1; export PAYLOAD_ISM ;;
        --payload-ism=*) PAYLOAD_ISM=1; PAYLOAD_ISM_LINK="${1#*=}"; export PAYLOAD_ISM ;;
        --virtualbox)   WAN_MESH=1; VBOX_INTERCO=1 ;;
        --virtualbox=*) WAN_MESH=1; VBOX_INTERCO=1; VBOX_NODES="${1#*=}" ;;
        --vbox-node)    VBOX_HOST_NODE="${2:-1}"; shift ;;
        --vbox-node=*)  VBOX_HOST_NODE="${1#*=}" ;;
        --node)         NODE_ID="${2:-}"; shift ;;
        --node=*)       NODE_ID="${1#*=}" ;;
        --air-mesh)     AIR_MESH=1 ;;
        --air-mesh=*)   AIR_MESH=1; AIRMESH_PORT="${1#*=}" ;;
        --regen)        REGEN_GABARITS=1 ;;
        --regen-conf)   WAN_MESH=1; REGEN_WAN_CONF=1 ;;
        --menu)         MENU_MODE=1 ;;
        --op)           NODE_OP="${2:-1}"; shift ;;
        --op=*)         NODE_OP="${1#*=}" ;;
        --hub-ip)       HUB_IP="${2:-}"; shift ;;
        --hub-ip=*)     HUB_IP="${1#*=}" ;;
        --interstp)     INTERSTP=1 ;;
        --no-interstp)  INTERSTP=0 ;;
        # MS GPRS (modem osmocom-bb) en second MS du fake_trx du side-car, avec
        # son PCU (/tmp/pcu_bts2) : qosmo run_modules/{58,61,69,71}.
        # [2026-10-16] INACTIF par defaut : le banc demarre sans data (full ROM
        # DSP seul, voix/SMS). --gprs-modem remonte le lot data a la demande.
        --gprs-modem)    MODEM_GPRS=1 ;;
        --no-gprs-modem) MODEM_GPRS=0 ;;
        --mobile|--ccch_scan|--bcch_scan|--cell_log)
                       # run_modules/70-l2.sh gere deja les quatre clients via
                       # CALYPSO_L2_CLIENT ; il manquait de quoi les choisir.
                       # Un seul a la fois : ils se disputeraient la socket
                       # L1CTL (/tmp/osmocom_l2) et la VTY 4247, et le second
                       # lance resterait muet pour toujours.
                       _l2c="${1#--}"
                       if [ -n "${L2_CLIENT_CHOISI:-}" ] && \
                          [ "$L2_CLIENT_CHOISI" != "$_l2c" ]; then
                           printf '%s\n\n' \
                             "--$_l2c et --$L2_CLIENT_CHOISI sont exclusifs : un seul client de couche 2" >&2
                           usage >&2; exit 2
                       fi
                       L2_CLIENT_CHOISI="$_l2c" ;;
        -h|--help)     usage; exit 0 ;;
        faketrx-qemu|faketrx|qemu|noproc|core|hybrid)
            PROFILE="$1"; PROFILE_CHOISI=1
            [ "$PROFILE" = "hybrid" ] && PROFILE=faketrx-qemu
            [ "$PROFILE" = "core" ]   && PROFILE=noproc
            ;;
        *) printf 'option inconnue : %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# [2026-10-21] --bts-classic : la BTS est osmo-bts-trx + pont_dsp.py ; un OSMO_TRX=1 herite de
# l'environnement ne doit pas rallumer le Calypso TRX. --ms / --ms-magnetite restent valables : sans
# OSMO_TRX, 14-demarrage.sh branche le mobile (ou Magnetite, FIRMWARE_FLASH) sur le pont.
if [ "${BTS_CLASSIC:-0}" = 1 ]; then
    if [ -n "${BTS_TRX_CHOISI:-}" ]; then
        printf '%s\n\n' "--bts-classic et $BTS_TRX_CHOISI sont exclusifs : BTS classique (pont_dsp.py) ou Calypso TRX" >&2
        usage >&2; exit 2
    fi
    OSMO_TRX=0; export OSMO_TRX
fi

# [2026-10-20] --ts N -> variables de c54x_exe/run.sh (OSMO_TRX=1). Sans --ts, run.sh garde son defaut
# (OSMO_TRX_TCH=1 : un Calypso, TS0 + TS1, masques 0x03). trx_ts_desc : le libelle des resumes.
export_trx_ts() {
    # [2026-10-21] 2/1 et le defaut : un seul Calypso pour TS0 + TS1 (le seul montage qui passe un appel) ;
    # 2 : un Calypso par intervalle (LU OK, appels KO : fn du telephone 2 non aligne).
    case "${OSMO_TRX_TS:-}" in
        1)      export OSMO_TRX_TCH=0 OSMO_TRX_TS1=0 ;;
        2)      export OSMO_TRX_TCH=0 OSMO_TRX_TS1=1 ;;
        2/1|"") export OSMO_TRX_TCH=1 OSMO_TRX_TS1=0 ;;
    esac
}
trx_ts_desc() {
    if [ "${OSMO_TRX_TS1:-0}" = 1 ]; then
        printf 'TS0 + TS1 par un 2e Calypso (--ts 2 : OSMO_TRX_TS1=1, instance %s, transceiver -2)' "${OSMO_TRX_TS1_INSTANCE:-3}"
    elif [ "${OSMO_TRX_TCH:-0}" = 0 ]; then
        printf 'TS0 seul (--ts 1 : OSMO_TRX_TCH=0, masque 0x01)'
    else
        printf 'TS0 + TS1 par un seul Calypso (OSMO_TRX_TCH=1, masques 0x03)'
    fi
}
export_trx_ts

# Le lot GPRS du side-car (fake_trx --trx, second PCU, trxcon + modem) lit
# MODEM_GPRS dans l'environnement de run.sh : exporte ici, 0 (sans data) par
# defaut, 1 avec --gprs-modem. L'environnement gagne (MODEM_GPRS=1 ./start-native.sh).
export MODEM_GPRS="${MODEM_GPRS:-0}"

# --- --dsp garde le profil par defaut ----------------------------------------
# [2026-09-22] --dsp forcait le profil `qemu` (pipeline Calypso seul, sans
# side-car), au motif qu'un banc DSP n'a pas a dependre d'une seconde station
# de base. Retire : le banc DSP doit monter la MEME pile que le mode grgsm,
# side-car compris, et c'est l'hybride qui est le defaut. Un profil nomme
# explicitement gagne toujours, comme avant.

# --- ou tourne-t-on ? ---------------------------------------------------------
# La question n'est pas cosmetique : le plan d'adressage EN DEPEND.
#   docker  → l'inter-STP est le conteneur osmo-inter-stp (172.20.0.10), le
#             noeud a deja son IP quand les demons demarrent.
#   VM/ISO  → l'inter-STP est une machine a part (192.168.1.49 sur le banc,
#             ou une host-only 192.168.56.x selon le montage), et l'adresse
#             du noeud vient du DHCP : elle peut manquer au lancement.
# Prendre l'un pour l'autre donne un ASP qui ne s'attache jamais, avec pour
# seule trace un "connection refused" vers une adresse inexistante ici.
#
# /.dockerenv seul ne suffit pas - il est vrai dans n'importe quel conteneur.
# On exige aussi /etc/docker-entrypoint-cmd, que scripts/entrypoint.sh depose :
# c'est ce couple qui identifie un conteneur DE CE DEPOT.
detect_runtime_env() {
    if [ -f /.dockerenv ] && [ -f /etc/docker-entrypoint-cmd ]; then
        echo docker; return
    fi
    if [ -f /.dockerenv ] || grep -qa 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
        echo docker; return
    fi
    # systemd-detect-virt SORT EN CODE 1 quand il ne trouve rien. Un
    # "$(cmd || echo none)" produit alors DEUX lignes - la sortie "none" du
    # programme, plus celle du repli - et aucun motif ne correspond : une
    # machine physique se retrouvait classee "vm". On ignore le code de
    # sortie et on ne garde que la premiere ligne.
    local v
    v="$(systemd-detect-virt 2>/dev/null | head -1)" || true
    v="${v:-none}"
    case "$v" in
        oracle|kvm|qemu|vmware|microsoft|xen|bochs|parallels) echo vm ;;
        none|"") echo bare ;;
        *) echo vm ;;
    esac
}
RUNTIME_ENV="${RUNTIME_ENV:-$(detect_runtime_env)}"

# --- quel noeud sommes-nous ? --------------------------------------------------
# Le numero de noeud decide des point codes, du routing context et de l'indicatif.
# Le taper a chaque lancement est une occasion de se tromper - et une erreur ici
# ne se voit pas : la pile demarre, elle presente simplement au hub l'adresse SS7
# d'un autre noeud. On le deduit donc, et on DIT d'ou vient la reponse.
#
# Ordre, du plus explicite au plus deduit. Le premier qui repond gagne :
#   1. --node passe en ligne de commande
#   2. l'environnement - c'est ainsi que start-docker.sh le transmet au conteneur
#   3. /etc/osmo-role, fige dans l'image par build-iso.sh --node N
#   4. la table WAN : l'adresse de ce noeud y figure, et nous l'avons
#   5. rien - on ne touche alors PAS a l'identite SS7, plutot que d'en inventer une
# Renvoie "numero|origine". Pas deux variables : la fonction est appelee dans
# une substitution de commande, donc dans un SOUS-SHELL - toute variable qu'elle
# poserait y resterait, et l'appelant n'afficherait "?" qu'apres coup.
detect_node_id() {
    local n

    n="${WAN_NODE_ID:-${OSMO_WAN_NODE:-}}"
    if [[ "$n" =~ ^[1-9]$ ]]; then echo "${n}|environnement"; return 0; fi

    if [ -r /etc/osmo-role ]; then
        n="$(awk -F= '/^OSMO_WAN_NODE=/{print $2}' /etc/osmo-role 2>/dev/null | tr -d ' \r')"
        if [[ "$n" =~ ^[1-9]$ ]]; then echo "${n}|/etc/osmo-role"; return 0; fi
    fi

    # La table WAN et nos propres adresses : c'est la source la plus fiable en VM,
    # ou une seule ISO sert les neuf noeuds et ou seule l'IP les distingue.
    local conf="${WAN_CONF_FILE:-/etc/osmo-wan.conf}"
    if [ -r "$conf" ] && [ -r "$HERE/network/wan-nodes.sh" ]; then
        n="$(
            # Sous-shell : wan-nodes.sh pose des variables et des tableaux qu'on
            # ne veut pas voir deborder dans le lanceur.
            set +u
            . "$HERE/network/wan-nodes.sh" 2>/dev/null || exit 0
            WAN_NODE_ID=0
            wan_nodes_load "$conf" 2>/dev/null || exit 0
            wan_nodes_detect_self 2>/dev/null || exit 0
            printf '%s' "$WAN_NODE_ID"
        )"
        if [[ "$n" =~ ^[1-9]$ ]]; then echo "${n}|table WAN (IP locale)"; return 0; fi
    fi

    return 1
}


#!/bin/bash
# iso_modules/52-qemu.sh - etape 5b/5c/5d : QEMU, firmware, toast, lanceurs, configs
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── qosmo : arbre ELAGUE + binaire installe ──────────────────────────────
# Deux choses distinctes, et l'ISO a besoin des DEUX :
#   - l'arbre qosmo (run.sh, run_modules/, environnement/) :
#     c'est LUI le mode qemu de start-direct.sh. Il reste dans l'image, prive de
#     .git et de build/ (voir plus bas).
#   - le binaire qemu-system-arm, installe dans /usr/local/bin, et relie depuis
#     l'arbre sous le nom que paths.env cherche (build/qemu-system-arm).
QEMU_BUILD_LOCAL="${OSMO_QEMU_BUILD:-${OSMO_QEMU_SRC:-/opt/GSM/qosmo}/build}"
# --arm : un build QEMU de l hote est un binaire x86, il n a rien a faire dans
# un rootfs arm64. Seul le binaire venu de l image (arm64) compte.
[ "${ISO_ARCH:-amd64}" = "amd64" ] || QEMU_BUILD_LOCAL="/nonexistent/arm64-pas-de-build-hote"
echo -e "${GREEN}[5b/9] Installation QEMU (artefacts seuls, depuis ${QEMU_BUILD_LOCAL})...${NC}"
# L'elagage est HORS de la condition, et l'absence du binaire est FATALE. Avant,
# les deux etaient dans la branche "binaire present" : sur une machine ou QEMU
# n'avait pas ete recompile - le cas courant - on tombait dans le repli, qui se
# contentait d'un avertissement jaune, et l'arbre venu du docker cp
# ($CID:/opt/GSM) partait tel quel dans le squashfs, build/ compris : 1,7 Go
# dans une ISO qui tient en RAM. Le message passait inapercu au milieu d'une
# heure de construction, et la taille de l'ISO etait le seul indice.
# Echouer ici coute une relance ; ne pas echouer coute une ISO inutilisable
# (sans qemu-system-arm, MS#1 ne demarre pas) et deux fois plus lourde.
# ── qosmo : l'arbre part ENTIER, .git et build/ compris ─────────────────
# [2026-08-27] L'effacement pur ("rm -rf $ROOTFS/opt/GSM/qosmo") reglait le
# poids, mais retirait de l'image le depot dont run.sh, run_modules/ et
# environnement/ SONT le mode qemu : l'ISO ne savait plus emuler le Calypso par
# elle-meme et dependait, a CHAQUE demarrage, d'un reclone GitHub par
# osmo-update.service. Pas de reseau au boot = pas de MS. Et l'arbre reclone
# arrivait sans build/, donc sans QEMU_BIN : la pile s'arretait au premier
# module alors que le binaire etait la, dans le PATH.
#
# On ne retire donc plus RIEN de cet arbre :
#   - .git (96 Mo) : c'est lui qui fait la difference entre une mise a jour
#     incrementale (git fetch) et un reclone complet. Sans .git, update.sh
#     n'avait pas le choix : il effacait et reclonait a chaque demarrage.
#   - build/ (1,5 Go d'objets) : il porte le qemu-system-arm COMPILE, celui que
#     environnement/paths.env cherche sous $QEMU_TREE/build/qemu-system-arm.
#     L'arbre embarque est donc utilisable tel quel, sans reseau et sans lien.
#
# Ce que ca coute : ~1,6 Go de plus dans le squashfs (moins une fois compresse).
# A surveiller si l'ISO doit tenir en RAM (toram).
# ── OSMO_QEMU_SRC : L'ARBRE LOCAL PREND LE PAS, QUAND ON LE DEMANDE ─────────
# [2026-08-30] L'image docker clone qosmo depuis GitHub (Dockerfile:433).
# Un correctif fait ICI, dans l'arbre local, ne partait donc PAS dans l'ISO --
# il fallait le pousser sur GitHub d'abord, et rien ne le disait. C'est ainsi
# que les correctifs du shunt DSP (publication du Kc depuis le NDB) auraient pu
# etre "appliques" et absents de l'image produite.
# OSMO_QEMU_SRC=/chemin force desormais l'arbre local, en remplacant celui de
# l'image. Sans la variable, rien ne change : l'image fait foi, comme avant.
QSRC="$ROOTFS/opt/GSM/qosmo"
if [ -n "${OSMO_QEMU_SRC:-}" ] && [ -d "$OSMO_QEMU_SRC" ]; then
    rm -rf "$QSRC"
    mkdir -p "$ROOTFS/opt/GSM"
    cp -a "$OSMO_QEMU_SRC" "$QSRC"
    echo -e "  ${GREEN}✓${NC} qosmo FORCE depuis ${CYAN}${OSMO_QEMU_SRC}${NC} (OSMO_QEMU_SRC) ($(du -sh "$QSRC" | cut -f1))"
elif [ -d "$QSRC" ]; then
    echo -e "  ${GREEN}✓${NC} qosmo conserve ENTIER ($(du -sh "$QSRC" | cut -f1), .git + build/ compris)"
else
    # L'image ne l'avait pas : on prend l'arbre de l'hote, entier lui aussi.
    QSRC_HOST="${OSMO_QEMU_SRC:-/opt/GSM/qosmo}"
    if [ -d "$QSRC_HOST" ]; then
        mkdir -p "$ROOTFS/opt/GSM"
        cp -a "$QSRC_HOST" "$QSRC"
        echo -e "  ${GREEN}✓${NC} qosmo repris de l'hote ${CYAN}${QSRC_HOST}${NC} ($(du -sh "$QSRC" | cut -f1))"
    else
        echo -e "  ${YELLOW}!${NC} qosmo introuvable (ni image, ni hote) - l'ISO n'aura pas le mode qemu" >&2
    fi
fi

# ── Les anciens forks quittent le rootfs ────────────────────────────────────
# [2026-09-25] L'image docker clone encore qosmo-grgsm et qosmo-dsp (Dockerfile),
# et 50-injection-image.sh recopie tout /opt/GSM et /usr/local/bin de l'image :
# les deux arbres (~1,6 Go avec build/), le prefixe qemu-dsp-install et leurs
# lanceurs arrivaient donc dans l'ISO sans que plus rien ne les lise. Le lien
# /opt/GSM/calypso_dsp.txt de l'image pointait dans qosmo-grgsm ; il est repose
# plus bas sur c54x_exe/rom.
for _old in qosmo-grgsm qosmo-dsp qemu-dsp-install; do
    [ -e "$ROOTFS/opt/GSM/$_old" ] || continue
    rm -rf "$ROOTFS/opt/GSM/$_old"
    echo -e "  ${GREEN}✓${NC} ancien arbre ${CYAN}/opt/GSM/$_old${NC} retire du rootfs"
done
rm -f "$ROOTFS"/usr/local/bin/qosmo-grgsm "$ROOTFS"/usr/local/bin/qosmo-dsp \
      "$ROOTFS"/usr/local/bin/qosmo-grgsm-launch "$ROOTFS"/usr/local/bin/qosmo-dsp-launch
[ -L "$ROOTFS/opt/GSM/calypso_dsp.txt" ] && [ ! -e "$ROOTFS/opt/GSM/calypso_dsp.txt" ] \
    && rm -f "$ROOTFS/opt/GSM/calypso_dsp.txt"

# ── c54x_exe et grgsm_exe : les deux couches 1 hors QEMU ────────────────────
# [2026-09-25] Les forks qosmo-dsp et qosmo-grgsm sont remplaces par UN arbre
# QEMU, /opt/GSM/qosmo (run.sh, run_modules, cfgs, environnement y ont ete
# repris), et deux executables qui compilent les sources de qosmo :
#   c54x_exe   le DSP TMS320C54x sur la mask-ROM TI (start-direct.sh --dsp,
#              BANC_DSP = /opt/GSM/c54x_exe/run.sh)
#   grgsm_exe  la couche 1 gr-gsm hors QEMU (pont : /usr/local/bin/grgsm_exe)
# OSMO_C54X_SRC / OSMO_GRGSM_EXE_SRC forcent un arbre local, comme
# OSMO_QEMU_SRC pour qosmo. Non fatal : sans c54x_exe, seul --dsp manque.
# ⚠️ c54x_exe se compile en -march=native : le binaire de l'hote peut ne pas
# tourner sur la machine qui boote l'ISO (make -C /opt/GSM/c54x_exe la-bas).
for _e in c54x_exe grgsm_exe; do
    case "$_e" in
        c54x_exe)  _esrc="${OSMO_C54X_SRC:-}" ;;
        grgsm_exe) _esrc="${OSMO_GRGSM_EXE_SRC:-}" ;;
    esac
    _edst="$ROOTFS/opt/GSM/$_e"
    if [ -n "$_esrc" ] && [ -d "$_esrc" ]; then
        rm -rf "$_edst"; mkdir -p "$ROOTFS/opt/GSM"
        cp -a "$_esrc" "$_edst"
        echo -e "  ${GREEN}✓${NC} $_e FORCE depuis ${CYAN}${_esrc}${NC} ($(du -sh "$_edst" | cut -f1))"
    elif [ -d "$_edst" ]; then
        echo -e "  ${GREEN}✓${NC} $_e : arbre de l image conserve ($(du -sh "$_edst" | cut -f1))"
    elif [ -d "/opt/GSM/$_e" ]; then
        mkdir -p "$ROOTFS/opt/GSM"
        cp -a "/opt/GSM/$_e" "$_edst"
        echo -e "  ${GREEN}✓${NC} $_e repris de l hote ${CYAN}/opt/GSM/$_e${NC} ($(du -sh "$_edst" | cut -f1))"
    else
        echo -e "  ${YELLOW}!${NC} $_e introuvable (ni image, ni hote)" >&2
        continue
    fi
    if [ -x "$_edst/$_e" ]; then
        echo -e "  ${GREEN}✓${NC} $_e : binaire ${CYAN}/opt/GSM/$_e/$_e${NC} present"
    else
        echo -e "  ${YELLOW}!${NC} $_e : binaire ABSENT - make -C /opt/GSM/$_e avant de graver" >&2
    fi
    # Les petits lanceurs /usr/local/bin/<exe> (bash) de l'hote.
    if [ -x "/usr/local/bin/$_e" ] && [ ! -e "$ROOTFS/usr/local/bin/$_e" ]; then
        install -Dm755 "/usr/local/bin/$_e" "$ROOTFS/usr/local/bin/$_e"
        echo -e "  ${GREEN}✓${NC} lanceur ${CYAN}/usr/local/bin/$_e${NC} (repris de l'hote)"
    fi
done

# ── ROMs du DSP TMS320C54x : sans elles, --dsp ne demarre pas ─────────────────
# [2026-09-03] Sept dumps du silicium (PROM0..3, DROM, PDROM, Registers), lus
# par c54x_exe sous son --rom-dir (defaut /opt/GSM). ~330 Ko.
# [2026-09-25] Ils ne sont dans AUCUN depot : on les prend sur l'hote, dans
# /opt/GSM puis dans /opt/GSM/c54x_exe/rom (copie de secours, non suivie par
# git, avec calypso_dsp.txt). Non fatal.
_ROM_SRC="${OSMO_DSP_ROM_DIR:-/opt/GSM}"
_ROM_SECOURS=/opt/GSM/c54x_exe/rom
_rom_ok=0; _rom_miss=""
for _r in PROM0 PROM1 PROM2 PROM3 DROM PDROM Registers; do
    if [ -f "$_ROM_SRC/calypso_dsp.$_r.bin" ]; then
        install -Dm644 "$_ROM_SRC/calypso_dsp.$_r.bin" "$ROOTFS/opt/GSM/calypso_dsp.$_r.bin"
        _rom_ok=$((_rom_ok + 1))
    elif [ -f "$_ROM_SECOURS/calypso_dsp.$_r.bin" ]; then
        install -Dm644 "$_ROM_SECOURS/calypso_dsp.$_r.bin" "$ROOTFS/opt/GSM/calypso_dsp.$_r.bin"
        _rom_ok=$((_rom_ok + 1))
    elif [ -f "$ROOTFS/opt/GSM/calypso_dsp.$_r.bin" ]; then
        _rom_ok=$((_rom_ok + 1))
    else
        _rom_miss="$_rom_miss $_r"
    fi
done
# calypso_dsp.txt (listing de la ROM) : /opt/GSM/calypso_dsp.txt pointait dans
# l'ancien qosmo-grgsm ; il pointe maintenant sur la copie de c54x_exe/rom.
if [ -f "$ROOTFS/opt/GSM/c54x_exe/rom/calypso_dsp.txt" ]; then
    ln -sfn /opt/GSM/c54x_exe/rom/calypso_dsp.txt "$ROOTFS/opt/GSM/calypso_dsp.txt"
elif [ -f "$_ROM_SECOURS/calypso_dsp.txt" ]; then
    install -Dm644 "$_ROM_SECOURS/calypso_dsp.txt" "$ROOTFS/opt/GSM/calypso_dsp.txt"
fi
if [ -z "$_rom_miss" ]; then
    echo -e "  ${GREEN}✓${NC} ROMs DSP : ${CYAN}/opt/GSM/calypso_dsp.{PROM0..3,DROM,PDROM,Registers}.bin${NC} (7/7)"
elif [ -d "$ROOTFS/opt/GSM/c54x_exe" ]; then
    echo -e "  ${YELLOW}!${NC} ROMs DSP incompletes (${_rom_ok}/7, manquent :${_rom_miss}) - OSMO_DSP_ROM_DIR=/chemin ; --dsp ne demarrera pas" >&2
fi

# ── Firmware Calypso : /opt/GSM/firmware, et rien d'autre ───────────────────
# [2026-08-28] Il y avait ici un bloc qui remplacait $QSRC/target/firmware par
# un lien vers /opt/GSM/firmware. Il reparait une coquille vide laissee dans
# l'arbre qosmo, sur laquelle la premiere branche de
# environnement/paths.env tombait, d'ou :
#
#   [FAIL] FIRMWARE_ELF (/opt/GSM/qosmo/target/firmware/board/compal_e88/layer1.highram.elf)
#
# La cause a ete traitee a sa source : paths.env (et local.env) du depot qemu
# ne connaissent plus qu'un seul chemin, $GSM_ROOT/firmware. Il n'y a donc plus
# de coquille a reparer, et poser le lien reintroduirait justement le deuxieme
# arbre qu'on vient de supprimer. Constate sur le banc 192.168.1.7 : ce lien
# n'existait meme pas sur l'ISO gravee, et le run chargeait deja
# /opt/GSM/firmware/board/compal_e88/layer1.highram.elf sans lui.
#
# Reste ce qui a de la valeur : verifier que le firmware EST dans le rootfs.
# Sans lui, l'ISO demarre et le MS ne part pas.
FW_ELF="board/compal_e88/layer1.highram.elf"
if [ -e "$ROOTFS/opt/GSM/firmware/$FW_ELF" ]; then
    echo -e "  ${GREEN}✓${NC} firmware : ${CYAN}/opt/GSM/firmware/${FW_ELF}${NC} (source unique ; FIRMWARE_ELF resolu)"
else
    echo -e "  ${YELLOW}!${NC} /opt/GSM/firmware/${FW_ELF} absent du rootfs - FIRMWARE_ELF restera non resolu" >&2
fi
# [2026-09-03] Le firmware est interchangeable (compal_e86, gta0x, ...) : les
# lanceurs lisent l1s/last_rach dans l'ELF choisi par FIRMWARE_ELF, plus besoin
# de nm ni d'adresses figees. On dit quels boards l'image embarque, pour que
# « FIRMWARE_ELF=.../board/X/layer1.highram.elf » ne soit pas une devinette.
_boards=""
for _b in "$ROOTFS"/opt/GSM/firmware/board/*/layer1.highram.elf; do
    [ -f "$_b" ] || continue
    _boards="$_boards $(basename "$(dirname "$_b")")"
done
[ -n "$_boards" ] && echo -e "  ${GREEN}✓${NC} boards layer1 embarques :${CYAN}${_boards}${NC}"

# ── Firmware audio TI TAS2781 (ampli Lenovo Legion 7) ───────────────────────
# Le codec TAS2781 des Legion 7 ne sort AUCUN son tant que son firmware n est
# pas dans /lib/firmware : le pilote snd_soc_tas2781 le reclame au chargement
# et reste muet sinon. On le pose dans le rootfs (donc /lib/firmware du systeme
# installe), pas dans le /lib/firmware de l hote de build. Non fatal : une image
# sans ce binaire boote quand meme, seul l audio du Legion manque.
_TAS_URL="https://github.com/bbaranoff/sound_firmware_lenovo_legion_7/raw/refs/heads/main/TIAS2781RCA2.bin"
install -d "$ROOTFS/lib/firmware"
if [ "${ISO_ARCH:-amd64}" != "amd64" ]; then
    echo -e "  ${CYAN}·${NC} firmware TAS2781 (Legion 7, x86) : sans objet sur le Pi"
elif wget -qO "$ROOTFS/lib/firmware/TIAS2781RCA2.bin" "$_TAS_URL"; then
    echo -e "  ${GREEN}✓${NC} firmware audio : ${CYAN}/lib/firmware/TIAS2781RCA2.bin${NC} (TAS2781, Legion 7)"
else
    rm -f "$ROOTFS/lib/firmware/TIAS2781RCA2.bin"
    echo -e "  ${YELLOW}!${NC} TIAS2781RCA2.bin non telecharge (reseau ?) - audio Legion 7 muet" >&2
fi

# ── toast : codec GSM 06.10 (quut.com), absent du paquet libgsm1 ─────────────
# libgsm1 fournit la lib, pas le binaire toast/untoast/tcat. On compile les
# sources SOUS $ROOTFS/opt/GSM (donc /opt/GSM du systeme installe) et on pose le
# binaire dans $ROOTFS/usr/local/bin (/usr/local/bin du systeme). La compilation
# tourne sur l hote de build ; l ISO etant amd64 sur hote amd64, le binaire est
# bon. Non fatal : sans reseau ou sans toolchain, l ISO se construit sans toast.
_GSM_VER=gsm-1.0.24
_GSM_DIR=gsm-1.0-pl24   # le tarball se decompresse SOUS ce nom
_GSM_URL="https://www.quut.com/gsm/${_GSM_VER}.tar.gz"
if [ -x "$ROOTFS/usr/local/bin/toast" ]; then
    echo -e "  ${GREEN}✓${NC} toast deja dans le rootfs (image ?)"
elif [ "${ISO_ARCH:-amd64}" != "$(dpkg --print-architecture)" ]; then
    echo -e "  ${CYAN}·${NC} toast : compile DANS le chroot ${ISO_ARCH} plus loin (82-arm-natif), pas sur l hote"
elif ! command -v make >/dev/null 2>&1 || ! command -v cc >/dev/null 2>&1; then
    echo -e "  ${YELLOW}!${NC} toast non compile : gcc/make absents de l hote de build" >&2
else
    install -d "$ROOTFS/opt/GSM" "$ROOTFS/usr/local/bin"
    if ( cd "$ROOTFS/opt/GSM" \
         && wget -qO "${_GSM_VER}.tar.gz" "$_GSM_URL" \
         && tar xzf "${_GSM_VER}.tar.gz" \
         && cd "$_GSM_DIR" \
         && { make >/dev/null 2>&1 || true; } \
         && { [ -x bin/toast ] || make toast >/dev/null 2>&1 || true; } \
         && [ -x bin/toast ] ); then
        for _b in toast untoast tcat; do
            [ -e "$ROOTFS/opt/GSM/${_GSM_DIR}/bin/$_b" ] \
                && install -m755 "$ROOTFS/opt/GSM/${_GSM_DIR}/bin/$_b" "$ROOTFS/usr/local/bin/$_b"
        done
        echo -e "  ${GREEN}✓${NC} toast : ${CYAN}/usr/local/bin/toast${NC} (sources : /opt/GSM/${_GSM_DIR})"
    else
        echo -e "  ${YELLOW}!${NC} compilation de toast echouee (reseau ?) - ISO sans toast" >&2
    fi
fi

# ── Datadir QEMU : le lien que reclame la RELOCALISATION ────────────────────
# [2026-08-28] Diagnostique en direct sur un banc lite (192.168.1.7), ou la
# sequence mourait sur :
#
#   [FAIL] Emulator serial PTY (QEMU (pid ...) s'est arrete avant d'allouer son PTY)
#   qemu-system-arm: could not read keymap file: 'en-us'
#
# Le bloc "Keymaps QEMU" plus bas copie bien les keymaps - dans
# /usr/local/share/qemu/keymaps. Or QEMU ne les y cherche JAMAIS, et le fichier
# etait present en trois exemplaires sur la machine pendant que QEMU jurait ne
# pas le trouver.
#
# La raison tient a get_relocated_path() : QEMU ne prend PAS son
# CONFIG_QEMU_FIRMWAREPATH tel quel. Il en deduit un chemin RELATIF a son
# bindir de compilation, puis l'applique au repertoire ou le binaire se trouve
# REELLEMENT. Ici :
#
#   compile avec   prefix=/opt/GSM/qemu-install   (donc bin/ et share/qemu/ y sont)
#   execute depuis /opt/GSM/qosmo/build/qemu-system-arm   (run.sh -> QEMU_BIN)
#   QEMU cherche   /opt/GSM/qosmo/share/qemu   <- n'existait pas
#
# Le prefix compile n'est alors plus jamais consulte. Mesure faite sur le banc,
# meme binaire, meme machine :
#
#   sans lien : "could not read keymap file: 'en-us'"   rc=1  (QEMU meurt)
#   avec lien : aucune erreur                           rc=124 (tue par timeout,
#                                                        donc il tournait)
#
# Le lien <exec_dir>/../share/qemu est le SEUL qui repare : l'autre candidat de
# QEMU, <exec_dir>/pc-bios, a ete teste sur le banc et laisse l'erreur intacte.
QINST="$ROOTFS/opt/GSM/qemu-install/share/qemu"
if [ -d "$QSRC" ] && [ -d "$QINST/keymaps" ]; then
    if [ -e "$QSRC/share/qemu/keymaps/en-us" ]; then
        echo -e "  ${GREEN}✓${NC} datadir QEMU : ${CYAN}/opt/GSM/qosmo/share/qemu${NC} deja resolu"
    else
        mkdir -p "$QSRC/share"
        rm -rf "$QSRC/share/qemu"
        ln -sfn /opt/GSM/qemu-install/share/qemu "$QSRC/share/qemu"
        echo -e "  ${GREEN}✓${NC} datadir QEMU : ${CYAN}/opt/GSM/qosmo/share/qemu${NC} -> /opt/GSM/qemu-install/share/qemu (keymap 'en-us' resolu)"
    fi
elif [ -d "$QSRC" ] && [ "$ISO_ROLE" != "interstp" ]; then
    echo -e "  ${YELLOW}!${NC} /opt/GSM/qemu-install/share/qemu/keymaps absent - QEMU mourra sur 'could not read keymap file'" >&2
fi

# Le binaire vient peut-etre DEJA de l'image : "docker cp $CID:/usr/local/bin/."
# (plus haut) copie /usr/local/bin/qemu-system-arm dans le rootfs, et c'est
# exactement celui que le conteneur utilise pour emuler le Calypso. Exiger en
# plus un build sur l'HOTE faisait echouer la construction sur une machine ou
# QEMU n'a jamais ete recompile - le cas courant - alors que l'ISO aurait ete
# parfaitement utilisable. On ne garde le caractere fatal que pour le vrai
# probleme : aucun binaire, ni sur l'hote, ni dans l'image.
#
# Le pc-bios n'est pas necessaire ici : dans l'image, ni /usr/local/share/qemu
# ni /usr/local/share/qemu-firmware n'existent, et la machine Calypso demarre
# sans fichier de firmware QEMU (elle charge sa propre ROM). Les recopier
# couterait 303 Mo dans une ISO qui tient en RAM.
ROOTFS_QEMU="$ROOTFS/usr/local/bin/qemu-system-arm"
if [ ! -x "$QEMU_BUILD_LOCAL/qemu-system-arm" ] \
   && [ ! -x "$ROOTFS_QEMU" ] && [ "$ISO_ROLE" != "interstp" ]; then
    echo -e "${RED}${BOLD}[5b/9] qemu-system-arm introuvable${NC}" >&2
    echo -e "  ${YELLOW}Ni build local : ${QEMU_BUILD_LOCAL}/qemu-system-arm${NC}" >&2
    echo -e "  ${YELLOW}Ni binaire venu de l'image : ${ROOTFS_QEMU}${NC}" >&2
    echo -e "  ${YELLOW}L'image d'operateur emule le Calypso : sans ce binaire elle n'a pas de MS.${NC}" >&2
    echo -e "  ${YELLOW}Trois issues : compiler qosmo, pointer OSMO_QEMU_BUILD sur un build${NC}" >&2
    echo -e "  ${YELLOW}existant, ou reconstruire l'image docker qui, elle, porte le binaire.${NC}" >&2
    exit 1
fi
if [ ! -x "$QEMU_BUILD_LOCAL/qemu-system-arm" ] && [ -x "$ROOTFS_QEMU" ]; then
    # strip de l hote : x86 seulement (le binutils de l hote ne lit pas l aarch64 ;
    # le binaire arm64 est garde tel quel, symboles compris).
    [ "${ISO_ARCH:-amd64}" = "$(dpkg --print-architecture)" ] && strip --strip-unneeded "$ROOTFS_QEMU" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} qemu-system-arm repris de l'image ($(du -h "$ROOTFS_QEMU" | cut -f1)), pas de build hote necessaire"
elif [ -x "$QEMU_BUILD_LOCAL/qemu-system-arm" ]; then
    qpfx="$(sed -n 's/^prefix=//p' "$QEMU_BUILD_LOCAL/config-host.mak" 2>/dev/null)"
    qpfx="${qpfx:-/usr/local}"

    if DESTDIR="$ROOTFS" ninja -C "$QEMU_BUILD_LOCAL" install >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} qemu installe dans ${ROOTFS}${qpfx} (ninja install, pas de sources)"
    else
        # repli : binaire + firmwares/keymaps strictement necessaires
        install -Dm755 "$QEMU_BUILD_LOCAL/qemu-system-arm" "$ROOTFS$qpfx/bin/qemu-system-arm"
        install -d "$ROOTFS$qpfx/share/qemu"
        cp -a "$QEMU_BUILD_LOCAL/pc-bios/." "$ROOTFS$qpfx/share/qemu/" 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} qemu-system-arm + pc-bios copies dans ${ROOTFS}${qpfx} (repli manuel)"
    fi
    strip --strip-unneeded "$ROOTFS$qpfx/bin/qemu-system-arm" 2>/dev/null || true
else
    # Seul le hub arrive ici : il ne fait que router du M3UA, il n'a pas de MS a
    # emuler. Pour l'operateur, le test ci-dessus a deja arrete la construction.
    echo -e "  ${CYAN}Role inter-STP : pas de QEMU (aucun MS a emuler)${NC}"
fi
# ── Lanceur C qosmo : ce que 40-qemu.sh appelle ──────────
# [2026-09-03] Chaque fork porte tools/qosmo-launch/qosmo-launch.c, compile dans
# SON dossier (make) et installe dans /usr/local/bin sous le nom du fork. Sans
# lui, run.sh retombe sur qemu-system-arm direct : l'ISO marche, mais sans les
# liens pty stables ni les options reseau/sockets. On construit sur l'hote (C
# pur, libc seule, aucun warning sous -Wall -Wextra) et on copie ; a defaut de
# source, on reprend le binaire deja installe sur l'hote. Jamais fatal.
if [ "$ISO_ROLE" != "interstp" ]; then
    for fork in qosmo; do
        lsrc=""
        for c in "/opt/GSM/$fork/tools/qosmo-launch" "$ROOTFS/opt/GSM/$fork/tools/qosmo-launch"; do
            [ -f "$c/qosmo-launch.c" ] && { lsrc="$c"; break; }
        done
        if [ "${ISO_ARCH:-amd64}" != "$(dpkg --print-architecture)" ]; then
            # Compilation croisee : ni gcc de l hote ni binaire de l hote, ce
            # serait du x86. Le lanceur est compile dans le chroot (82-arm-natif)
            # s il n est pas deja venu de l image.
            if [ -x "$ROOTFS/usr/local/bin/$fork" ]; then
                echo -e "  ${GREEN}✓${NC} lanceur ${CYAN}/usr/local/bin/$fork${NC} (deja dans l'image ${ISO_ARCH})"
            else
                echo -e "  ${CYAN}·${NC} lanceur $fork : compile dans le chroot ${ISO_ARCH} plus loin"
            fi
        elif [ -n "$lsrc" ] && command -v gcc >/dev/null 2>&1 \
           && make -s -C "$lsrc" ALIAS="$fork" TREE="/opt/GSM/$fork" "$fork" >/dev/null 2>&1 && [ -x "$lsrc/$fork" ]; then
            install -Dm755 "$lsrc/$fork" "$ROOTFS/usr/local/bin/$fork"
            echo -e "  ${GREEN}✓${NC} lanceur ${CYAN}/usr/local/bin/$fork${NC} (compile depuis $lsrc)"
        elif [ -x "/usr/local/bin/$fork" ]; then
            install -Dm755 "/usr/local/bin/$fork" "$ROOTFS/usr/local/bin/$fork"
            echo -e "  ${GREEN}✓${NC} lanceur ${CYAN}/usr/local/bin/$fork${NC} (repris de l'hote)"
        elif [ -x "$ROOTFS/usr/local/bin/$fork" ]; then
            echo -e "  ${GREEN}✓${NC} lanceur ${CYAN}/usr/local/bin/$fork${NC} (deja dans l'image)"
        else
            echo -e "  ${YELLOW}!${NC} lanceur $fork absent (ni source, ni binaire) : run.sh appellera qemu-system-arm directement" >&2
        fi
        # ── Console gdb en telnet (44-gdb-telnet.sh) : le panneau cmd.gdb ─────
        # tools/gdb-telnet.py sert `telnet localhost 44444` -> gdb-multiarch sur le
        # gdbstub ARM, cible en marche ; il source tools/cmd.gdb, GENERE par
        # tools/gdb_cmd.sh (68 commandes osmocom : dsp, sb, tasks, fake_sb,
        # trace_frames, help_osmo...). On le regenere dans l'arbre embarque pour
        # qu'il corresponde au gdb_cmd.sh qui part. gdb-multiarch et telnet sont
        # dans PKGS (role operateur), il n'y a rien d'autre a installer.
        if [ -f "$ROOTFS/opt/GSM/$fork/tools/gdb_cmd.sh" ]; then
            if (cd "$ROOTFS/opt/GSM/$fork/tools" && bash ./gdb_cmd.sh >/dev/null 2>&1) \
               && [ -s "$ROOTFS/opt/GSM/$fork/tools/cmd.gdb" ]; then
                echo -e "  ${GREEN}✓${NC} gdb telnet ${CYAN}$fork${NC} : tools/cmd.gdb genere ($(grep -c '^define ' "$ROOTFS/opt/GSM/$fork/tools/cmd.gdb") commandes), serveur 44-gdb-telnet.sh"
            else
                echo -e "  ${YELLOW}!${NC} $fork : tools/gdb_cmd.sh n'a pas produit cmd.gdb - la console telnet marchera sans le panneau" >&2
            fi
        fi
    done
fi
# ── QEMU_BIN dans l'arbre : le lien, SEULEMENT si le binaire n'y est pas ───
# environnement/paths.env du depot qemu resout QEMU_BIN a
# $QEMU_TREE/build/qemu-system-arm. L'arbre embarque le porte deja (build/ part
# entier) : dans ce cas on ne touche a RIEN - un "ln -sf" par-dessus remplacerait
# le binaire compile par un lien, c'est-a-dire l'effacerait.
# Le lien ne sert qu'au cas contraire (arbre venu d'ailleurs, build/ absent) :
# sans lui, run.sh s'arrete des le premier module -
#     [FAIL] Prerequisite checks (dépendances introuvables : QEMU_BIN)
# - alors que le binaire est la, dans /usr/local/bin.
# osmo-qemu-link.service (etape [6/9]) applique la meme regle a chaque demarrage.
if [ -d "$QSRC" ] && [ ! -e "$QSRC/build/qemu-system-arm" ]; then
    qbin=""
    for c in "$ROOTFS/usr/local/bin/qemu-system-arm" \
             "$ROOTFS${qpfx:-/usr/local}/bin/qemu-system-arm"; do
        [ -x "$c" ] && { qbin="${c#$ROOTFS}"; break; }
    done
    if [ -n "$qbin" ]; then
        mkdir -p "$QSRC/build"
        ln -sfn "$qbin" "$QSRC/build/qemu-system-arm"
        echo -e "  ${GREEN}✓${NC} QEMU_BIN : ${CYAN}/opt/GSM/qosmo/build/qemu-system-arm${NC} -> ${CYAN}${qbin}${NC}"
    elif [ "$ISO_ROLE" != "interstp" ]; then
        echo -e "  ${YELLOW}!${NC} binaire QEMU introuvable dans le rootfs - QEMU_BIN restera non resolu" >&2
    fi
elif [ -e "$QSRC/build/qemu-system-arm" ]; then
    echo -e "  ${GREEN}✓${NC} QEMU_BIN : ${CYAN}/opt/GSM/qosmo/build/qemu-system-arm${NC} (binaire compile de l'arbre)"
fi

# ── Keymaps QEMU : 917 ko qui decident si la machine demarre ────────────────
# [2026-08-27] Le commentaire du bloc d'installation ci-dessus dit vrai pour le
# pc-bios - 303 Mo
# de ROMs (bios.bin, edk2, efi-*.rom) que la machine Calypso n'ouvre jamais,
# elle charge la sienne. Il est FAUX pour les keymaps, qui ne sont pas du
# firmware : l'interface graphique les lit a l'initialisation, machine Calypso
# comprise. Sans $prefix/share/qemu/keymaps, qemu-system-arm ecrit
#     qemu-system-arm: could not read keymap file: 'en-us'
# et s'arrete AVANT le premier cycle. Vu de start-direct.sh, ca donne
#     [FAIL] Calypso emulator (QEMU) (started but never ready)
# c'est-a-dire une ISO sans MS - la panne exacte que le bloc precedent veut
# eviter. On copie donc les keymaps SEULES : 917 ko, pas 303 Mo.
if [ "$ISO_ROLE" != "interstp" ]; then
    if [ -d "$ROOTFS/usr/local/share/qemu/keymaps" ]; then
        echo -e "  ${GREEN}✓${NC} keymaps QEMU deja en place (${CYAN}/usr/local/share/qemu/keymaps${NC})"
    else
        qkm=""
        for c in "$QEMU_BUILD_LOCAL/pc-bios/keymaps" \
                 "$QSRC/pc-bios/keymaps" \
                 "$ROOTFS/opt/GSM/qemu-install/share/qemu/keymaps" \
                 "$ROOTFS/usr/share/qemu/keymaps" \
                 /usr/local/share/qemu/keymaps \
                 /usr/share/qemu/keymaps; do
            [ -d "$c" ] && { qkm="$c"; break; }
        done
        if [ -n "$qkm" ]; then
            mkdir -p "$ROOTFS/usr/local/share/qemu"
            cp -a "$qkm" "$ROOTFS/usr/local/share/qemu/"
            echo -e "  ${GREEN}✓${NC} keymaps QEMU ($(du -sh "$ROOTFS/usr/local/share/qemu/keymaps" | cut -f1)) copiees depuis ${CYAN}${qkm}${NC}"
        else
            # Pas fatal : le binaire peut avoir ete configure avec un autre
            # prefixe, ou une version future ne plus les lire. Mais c'est la
            # premiere chose a regarder si QEMU "demarre puis s'arrete".
            echo -e "  ${YELLOW}!${NC} keymaps QEMU introuvables - si QEMU s'arrete au demarrage," >&2
            echo -e "  ${YELLOW}  cherchez \"could not read keymap file\" dans logs/qemu.log${NC}" >&2
        fi
    fi
fi

echo -e "${GREEN}[5c/9] Ajustements osmocom dans le rootfs...${NC}"
echo -e "${GREEN}[5d/9] Patch configs ISO...${NC}"

# LA MEME recette que sur $TEMP_CONFIG, rejouee sur le rootfs. Elle est
# idempotente : ce qui est deja juste ne bouge pas. On la rejoue quand meme
# parce que /etc/osmocom du rootfs vient de l'IMAGE docker (docker cp a
# l'etape 5), pas de $TEMP_CONFIG - l'image peut porter des fichiers que la
# substitution n'a pas traverses.
apply_native_post_patches "$ROOTFS/etc" "$ISO_OP_ID" "$ISO_N_MS" "$HOST_IP" \
    "${ISO_NODE:-1}" "${ISO_WAN_TMP:-/nonexistent}" "$SGSN_GTP_IP" "$HLR_IP"

if [ -f "$ROOTFS/etc/osmocom/run.sh" ]; then
    chmod +x "$ROOTFS/etc/osmocom/run.sh"
else
    # Garde-fou : sous set -e, un run.sh absent tuait la construction tout au
    # bout de l'etape 5. Le fichier vient de l'image, pas du depot : s'il
    # manque, c'est l'image qu'il faut regarder, pas une heure de build qu'il
    # faut perdre.
    echo -e "  ${YELLOW}!${NC} /etc/osmocom/run.sh absent de l'image ${CYAN}${ISO_SRC_IMAGE}${NC}"
fi

echo -e "  ${GREEN}✓${NC} retouches natives rejouees sur le rootfs (SGSN, MSC, sms-routing, run.sh)"
mkdir -p "$ROOTFS/usr/bin"
# ── /usr/local/bin AUSSI DANS /usr/bin, MAIS JAMAIS SUR UN BINAIRE DE DPKG ──
# [2026-09-04] Ce `cp -a` recopiait TOUT /usr/local/bin dans /usr/bin. Or
# /usr/local/bin contient le wrapper tcpdump (l'image l'apporte en 50-injection,
# 83-espace-ram.sh le repose) - et le wrapper, lui, appelle /usr/bin/tcpdump.
# Recopie par-dessus le vrai binaire, il s'appelait donc LUI-MEME, indefiniment.
# L'apt de l'etape 8 ne rattrapait rien : le paquet etant deja installe dans
# l'image, dpkg n'avait aucune raison de reecrire le fichier.
#
# Ce que ca donnait sur la machine demarree, et pourquoi ca ne ressemblait pas a
# un probleme de tcpdump : run_modules/75-gsmtap.sh attend son pcap, ne le voit
# jamais venir, et rend "[FAIL] GSMTAP capture (pcap)". run.sh sort alors en 1
# (nb_fail > 0) ; osmo-banc.service est un oneshot, donc systemd conclut a un
# service en echec et SIGKILL tout le cgroup - la pile entiere, montee et
# fonctionnelle, tuee par une capture reseau.
#
# On ne copie donc que ce qui n'appartient a AUCUN paquet. La liste des fichiers
# de dpkg se lit directement dans le rootfs : pas de chroot (qui ne marcherait
# pas en construction croisee arm64), pas de dpkg-query.
_ubin_dpkg="$WORK/usr-bin-dpkg.txt"
cat "$ROOTFS"/var/lib/dpkg/info/*.list 2>/dev/null \
    | grep '^/usr/bin/' | sort -u > "$_ubin_dpkg" || true
for _f in "$ROOTFS/usr/local/bin/"*; do
    [ -e "$_f" ] || continue
    _b="${_f##*/}"
    if grep -qxF "/usr/bin/$_b" "$_ubin_dpkg"; then
        echo -e "  ${YELLOW}!${NC} /usr/bin/$_b appartient a un paquet - laisse intact (${CYAN}/usr/local/bin/$_b${NC} le precede dans le PATH)"
        continue
    fi
    cp -a "$_f" "$ROOTFS/usr/bin/" 2>/dev/null || true
done

mkdir -p "$ROOTFS/root/.osmocom/bb"
if [ -f "$ROOTFS/opt/GSM/osmo-operator/mobile.cfg" ]; then
    cp "$ROOTFS/opt/GSM/osmo-operator/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
elif [ -f "$ROOTFS/opt/GSM/osmo-operator/configs/mobile.cfg" ]; then
    cp "$ROOTFS/opt/GSM/osmo-operator/configs/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
elif [ -f "$ROOTFS/etc/osmocom/mobile.cfg" ]; then
    cp "$ROOTFS/etc/osmocom/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
fi

# ── PAS D'UTILISATEUR osmocom : ROOT, ET RIEN D'AUTRE ───────────────────────
# L'image portait un compte "osmocom" force a l'UID 0 (usermod -o -u 0). Un
# compte qui EST root sans le dire coute plus qu'il ne rapporte :
#   - GDM refuse toute session pour l'uid 0, il fallait donc neutraliser la
#     regle PAM "user != root" pour qu'un autologin sur ce compte aboutisse ;
#   - deux noms pour le meme uid donnent deux HOME (/home/osmocom et /root) et
#     donc deux .osmocom/bb : les mobiles ecrits dans l'un, lus dans l'autre ;
#   - "ls -l" affiche tantot root tantot osmocom pour un meme proprietaire,
#     selon l'ordre de /etc/passwd - de quoi chercher longtemps un probleme de
#     droits qui n'existe pas.
# Cette image tourne en root, assume : on SUPPRIME le compte et on rend les
# unites systemd a root. Les .service viennent des paquets Osmocom amont, qui
# posent "User=osmocom / Group=osmocom" ; sans compte, ils echouent au
# demarrage sur "Failed to determine user credentials" - un demon qui ne part
# pas, et rien dans son propre journal pour le dire.
sed -i -e 's/^User=osmocom$/User=root/' -e 's/^Group=osmocom$/Group=root/' \
       "$ROOTFS/lib/systemd/system"/osmo-*.service \
       "$ROOTFS/etc/systemd/system"/osmo-*.service 2>/dev/null || true

chroot "$ROOTFS" userdel -r osmocom 2>/dev/null || true
chroot "$ROOTFS" groupdel osmocom  2>/dev/null || true
rm -rf "$ROOTFS/home/osmocom"
# /var/lib/osmocom (bases HLR, etats GTP) et /var/log/osmocom appartenaient au
# compte supprime : sans ce chown ils gardent un UID orphelin, et l'ecriture
# echoue des le premier demarrage ("Unable to create file").
chown -R 0:0 "$ROOTFS/root/.osmocom" "$ROOTFS/var/lib/osmocom" \
             "$ROOTFS/var/log/osmocom" 2>/dev/null || true

# Le compte "osmocom" de l image Docker etait un alias d UID 0 : on le retire
# ici ; le VRAI compte osmocom, non privilegie, est recree en 8d.
echo -e "  ${GREEN}✓${NC} alias uid-0 osmocom retire (unites osmo-* rendues a root) + /usr/bin + mobile.cfg prets"


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true

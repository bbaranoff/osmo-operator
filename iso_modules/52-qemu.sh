#!/bin/bash
# iso_modules/52-qemu.sh - steps 5b/5c/5d: QEMU, firmware, toast, launchers, configs
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).
#
# Environment:
#   OSMO_QEMU_SRC=<dir>        use this local qosmo tree instead of the image's
#   OSMO_QEMU_BUILD=<dir>      host QEMU build dir (default: <qosmo>/build)
#   OSMO_C54X_SRC=<dir>        local c54x_exe tree to embed
#   OSMO_GRGSM_EXE_SRC=<dir>   local grgsm_exe tree to embed
#   OSMO_DSP_ROM_DIR=<dir>     where to find the calypso_dsp.*.bin ROM dumps

# ── qosmo: full tree + installed binary ─────────────────────────────────────
# The ISO needs BOTH:
#   - the qosmo tree (run.sh, run_modules/, environnement/): it IS the qemu
#     mode of start-native.sh;
#   - the qemu-system-arm binary, found by paths.env as build/qemu-system-arm.
QEMU_BUILD_LOCAL="${OSMO_QEMU_BUILD:-${OSMO_QEMU_SRC:-/opt/GSM/qosmo}/build}"
# --arm: a host QEMU build is an x86 binary, useless in an arm64 rootfs.
# Only the (arm64) binary from the image counts.
[ "${ISO_ARCH:-amd64}" = "amd64" ] || QEMU_BUILD_LOCAL="/nonexistent/arm64-pas-de-build-hote"
echo -e "${GREEN}[5b/9] Installation QEMU (artefacts seuls, depuis ${QEMU_BUILD_LOCAL})...${NC}"
# ── qosmo tree: embedded WHOLE, .git and build/ included ────────────────────
#   - .git lets update.sh do an incremental git fetch instead of a reclone;
#   - build/ holds the compiled qemu-system-arm that environnement/paths.env
#     expects at $QEMU_TREE/build/qemu-system-arm, so the tree works offline.
# Known limitation: this adds ~1.6 GB to the squashfs; watch it for toram boots.
# OSMO_QEMU_SRC=<dir> replaces the image's tree (cloned from GitHub by the
# Dockerfile) with a local one, so unpushed fixes reach the ISO. Without it,
# the image tree is used.
QSRC="$ROOTFS/opt/GSM/qosmo"
if [ -n "${OSMO_QEMU_SRC:-}" ] && [ -d "$OSMO_QEMU_SRC" ]; then
    rm -rf "$QSRC"
    mkdir -p "$ROOTFS/opt/GSM"
    cp -a "$OSMO_QEMU_SRC" "$QSRC"
    echo -e "  ${GREEN}✓${NC} qosmo FORCE depuis ${CYAN}${OSMO_QEMU_SRC}${NC} (OSMO_QEMU_SRC) ($(du -sh "$QSRC" | cut -f1))"
elif [ -d "$QSRC" ]; then
    echo -e "  ${GREEN}✓${NC} qosmo conserve ENTIER ($(du -sh "$QSRC" | cut -f1), .git + build/ compris)"
else
    # Not in the image: take the host tree, also whole.
    QSRC_HOST="${OSMO_QEMU_SRC:-/opt/GSM/qosmo}"
    if [ -d "$QSRC_HOST" ]; then
        mkdir -p "$ROOTFS/opt/GSM"
        cp -a "$QSRC_HOST" "$QSRC"
        echo -e "  ${GREEN}✓${NC} qosmo repris de l'hote ${CYAN}${QSRC_HOST}${NC} ($(du -sh "$QSRC" | cut -f1))"
    else
        echo -e "  ${YELLOW}!${NC} qosmo introuvable (ni image, ni hote) - l'ISO n'aura pas le mode qemu" >&2
    fi
fi

# ── Remove the obsolete forks from the rootfs ───────────────────────────────
# The docker image still clones qosmo-grgsm and qosmo-dsp, and
# 50-injection-image.sh copies all of /opt/GSM and /usr/local/bin: drop those
# trees, the qemu-dsp-install prefix and their launchers. A dangling
# /opt/GSM/calypso_dsp.txt link is removed; it is set again below to c54x_exe/rom.
for _old in qosmo-grgsm qosmo-dsp qemu-dsp-install; do
    [ -e "$ROOTFS/opt/GSM/$_old" ] || continue
    rm -rf "$ROOTFS/opt/GSM/$_old"
    echo -e "  ${GREEN}✓${NC} ancien arbre ${CYAN}/opt/GSM/$_old${NC} retire du rootfs"
done
rm -f "$ROOTFS"/usr/local/bin/qosmo-grgsm "$ROOTFS"/usr/local/bin/qosmo-dsp \
      "$ROOTFS"/usr/local/bin/qosmo-grgsm-launch "$ROOTFS"/usr/local/bin/qosmo-dsp-launch
[ -L "$ROOTFS/opt/GSM/calypso_dsp.txt" ] && [ ! -e "$ROOTFS/opt/GSM/calypso_dsp.txt" ] \
    && rm -f "$ROOTFS/opt/GSM/calypso_dsp.txt"

# ── c54x_exe and grgsm_exe: the two layer-1 implementations outside QEMU ─────
#   c54x_exe   TMS320C54x DSP on the TI mask ROM (start-native.sh --dsp,
#              BANC_DSP = /opt/GSM/c54x_exe/run.sh)
#   grgsm_exe  gr-gsm layer 1 outside QEMU (bridge: /usr/local/bin/grgsm_exe)
# OSMO_C54X_SRC / OSMO_GRGSM_EXE_SRC force a local tree, like OSMO_QEMU_SRC.
# Not fatal: without c54x_exe only --dsp is missing.
# Known limitation: c54x_exe is built with -march=native, so the host binary may
# not run on the machine booting the ISO (run make -C /opt/GSM/c54x_exe there).
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
    # Small bash launchers /usr/local/bin/<exe> from the host.
    if [ -x "/usr/local/bin/$_e" ] && [ ! -e "$ROOTFS/usr/local/bin/$_e" ]; then
        install -Dm755 "/usr/local/bin/$_e" "$ROOTFS/usr/local/bin/$_e"
        echo -e "  ${GREEN}✓${NC} lanceur ${CYAN}/usr/local/bin/$_e${NC} (repris de l'hote)"
    fi
done

# ── TMS320C54x DSP ROMs: required by --dsp ──────────────────────────────────
# Seven silicon dumps (PROM0..3, DROM, PDROM, Registers), ~330 KB, read by
# c54x_exe from its --rom-dir (default /opt/GSM). They are in no repository:
# taken from the host, $OSMO_DSP_ROM_DIR (default /opt/GSM) then
# /opt/GSM/c54x_exe/rom (untracked backup copy, with calypso_dsp.txt). Not fatal.
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
# calypso_dsp.txt (ROM listing): /opt/GSM/calypso_dsp.txt points to the copy
# in c54x_exe/rom.
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

# ── Calypso firmware: /opt/GSM/firmware only ────────────────────────────────
# environnement/paths.env (and local.env) of qosmo only know
# $GSM_ROOT/firmware; do not add a firmware link inside the qosmo tree.
# Just check that the firmware is in the rootfs: without it the ISO boots but
# the MS does not start.
FW_ELF="board/compal_e88/layer1.highram.elf"
if [ -e "$ROOTFS/opt/GSM/firmware/$FW_ELF" ]; then
    echo -e "  ${GREEN}✓${NC} firmware : ${CYAN}/opt/GSM/firmware/${FW_ELF}${NC} (source unique ; FIRMWARE_ELF resolu)"
else
    echo -e "  ${YELLOW}!${NC} /opt/GSM/firmware/${FW_ELF} absent du rootfs - FIRMWARE_ELF restera non resolu" >&2
fi
# The firmware is interchangeable (compal_e86, gta0x, ...): the launchers read
# l1s/last_rach from the ELF selected by FIRMWARE_ELF. List the embedded boards
# so that FIRMWARE_ELF=.../board/X/layer1.highram.elf is not guesswork.
_boards=""
for _b in "$ROOTFS"/opt/GSM/firmware/board/*/layer1.highram.elf; do
    [ -f "$_b" ] || continue
    _boards="$_boards $(basename "$(dirname "$_b")")"
done
[ -n "$_boards" ] && echo -e "  ${GREEN}✓${NC} boards layer1 embarques :${CYAN}${_boards}${NC}"

# ── TI TAS2781 audio firmware (Lenovo Legion 7 amplifier) ───────────────────
# The snd_soc_tas2781 driver stays silent until its firmware is in
# /lib/firmware. Installed into the rootfs (not the build host). Not fatal:
# without it only the Legion 7 audio is missing.
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

# ── toast: GSM 06.10 codec (quut.com), not shipped by libgsm1 ───────────────
# libgsm1 provides the library, not toast/untoast/tcat. The sources are built
# under $ROOTFS/opt/GSM and the binaries installed into $ROOTFS/usr/local/bin.
# Built on the build host, so only when host and ISO architectures match
# (otherwise in the chroot, 82-arm-natif). Not fatal: no network or toolchain
# means no toast.
_GSM_VER=gsm-1.0.24
_GSM_DIR=gsm-1.0-pl24  # the tarball unpacks under this name
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

# ── QEMU datadir: link required by QEMU path relocation ─────────────────────
# QEMU does not use CONFIG_QEMU_FIRMWAREPATH as-is (get_relocated_path()): it
# makes it relative to its build-time bindir and applies it to the directory
# the binary actually runs from:
#   built with    prefix=/opt/GSM/qemu-install
#   run from      /opt/GSM/qosmo/build/qemu-system-arm   (run.sh -> QEMU_BIN)
#   QEMU looks in /opt/GSM/qosmo/share/qemu
# Without the <exec_dir>/../share/qemu link QEMU dies with
# "could not read keymap file: 'en-us'"; <exec_dir>/pc-bios does not help.
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

# The binary may already come from the image (docker cp of /usr/local/bin
# above): a host build is not required. Fatal only if there is no binary at
# all, neither on the host nor in the image.
# pc-bios is not needed: the Calypso machine loads its own ROM, and copying
# it would add 303 MB to an ISO that runs from RAM.
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
    # Host strip: x86 only (host binutils cannot read aarch64; the arm64 binary
    # is kept as-is, with symbols).
    [ "${ISO_ARCH:-amd64}" = "$(dpkg --print-architecture)" ] && strip --strip-unneeded "$ROOTFS_QEMU" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} qemu-system-arm repris de l'image ($(du -h "$ROOTFS_QEMU" | cut -f1)), pas de build hote necessaire"
elif [ -x "$QEMU_BUILD_LOCAL/qemu-system-arm" ]; then
    qpfx="$(sed -n 's/^prefix=//p' "$QEMU_BUILD_LOCAL/config-host.mak" 2>/dev/null)"
    qpfx="${qpfx:-/usr/local}"

    if DESTDIR="$ROOTFS" ninja -C "$QEMU_BUILD_LOCAL" install >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} qemu installe dans ${ROOTFS}${qpfx} (ninja install, pas de sources)"
    else
        # Fallback: binary + strictly required firmware/keymaps
        install -Dm755 "$QEMU_BUILD_LOCAL/qemu-system-arm" "$ROOTFS$qpfx/bin/qemu-system-arm"
        install -d "$ROOTFS$qpfx/share/qemu"
        cp -a "$QEMU_BUILD_LOCAL/pc-bios/." "$ROOTFS$qpfx/share/qemu/" 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} qemu-system-arm + pc-bios copies dans ${ROOTFS}${qpfx} (repli manuel)"
    fi
    strip --strip-unneeded "$ROOTFS$qpfx/bin/qemu-system-arm" 2>/dev/null || true
else
    # Only the hub gets here: it just routes M3UA and has no MS to emulate.
    # For the operator role the check above already aborted the build.
    echo -e "  ${CYAN}Role inter-STP : pas de QEMU (aucun MS a emuler)${NC}"
fi
# ── qosmo C launcher: called by 40-qemu.sh ──────────────────────────────────
# tools/qosmo-launch/qosmo-launch.c is built in its directory (make) and
# installed as /usr/local/bin/<fork>. Without it run.sh calls qemu-system-arm
# directly: the ISO works, but without stable pty links nor network/socket
# options. Built on the host (plain C, libc only), else the binary already
# installed on the host is reused. Never fatal.
if [ "$ISO_ROLE" != "interstp" ]; then
    for fork in qosmo; do
        lsrc=""
        for c in "/opt/GSM/$fork/tools/qosmo-launch" "$ROOTFS/opt/GSM/$fork/tools/qosmo-launch"; do
            [ -f "$c/qosmo-launch.c" ] && { lsrc="$c"; break; }
        done
        if [ "${ISO_ARCH:-amd64}" != "$(dpkg --print-architecture)" ]; then
            # Cross build: neither host gcc nor host binary (both x86). The launcher is
            # built in the chroot (82-arm-natif) unless it came with the image.
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
        # ── gdb console over telnet (44-gdb-telnet.sh): the cmd.gdb panel ─────
        # tools/gdb-telnet.py serves `telnet localhost 44444` -> gdb-multiarch on the
        # ARM gdbstub; it sources tools/cmd.gdb, GENERATED by tools/gdb_cmd.sh
        # (osmocom commands: dsp, sb, tasks, fake_sb, trace_frames, help_osmo...).
        # Regenerated in the embedded tree to match the shipped gdb_cmd.sh.
        # gdb-multiarch and telnet are in PKGS (operator role).
        if [ -f "$ROOTFS/opt/GSM/$fork/tools/gdb_cmd.sh" ]; then
            # GDB_CMD_HERE: the path cmd.gdb will have INSIDE THE IMAGE, not the build
            # rootfs path (otherwise `source /var/tmp/iso-build-NNN/rootfs/...`).
            if (cd "$ROOTFS/opt/GSM/$fork/tools" && GDB_CMD_HERE="/opt/GSM/$fork/tools" bash ./gdb_cmd.sh >/dev/null 2>&1) \
               && [ -s "$ROOTFS/opt/GSM/$fork/tools/cmd.gdb" ]; then
                echo -e "  ${GREEN}✓${NC} gdb telnet ${CYAN}$fork${NC} : tools/cmd.gdb genere ($(grep -c '^define ' "$ROOTFS/opt/GSM/$fork/tools/cmd.gdb") commandes), serveur 44-gdb-telnet.sh"
            else
                echo -e "  ${YELLOW}!${NC} $fork : tools/gdb_cmd.sh n'a pas produit cmd.gdb - la console telnet marchera sans le panneau" >&2
            fi
        fi
    done
fi
# ── QEMU_BIN in the tree: link ONLY if the binary is missing ────────────────
# environnement/paths.env resolves QEMU_BIN to $QEMU_TREE/build/qemu-system-arm.
# If the embedded tree already has it (build/ shipped whole), touch nothing:
# an "ln -sf" over it would replace the compiled binary with a link.
# Otherwise (tree without build/) link it to /usr/local/bin, or run.sh stops
# at its first module with "[FAIL] Prerequisite checks (... QEMU_BIN)".
# osmo-qemu-link.service (step [6/9]) applies the same rule at every boot.
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

# ── QEMU keymaps: required for the machine to start ─────────────────────────
# Unlike pc-bios (303 MB of ROMs the Calypso machine never opens), keymaps are
# read by the UI at init, Calypso machine included. Without
# $prefix/share/qemu/keymaps, qemu-system-arm prints
#     qemu-system-arm: could not read keymap file: 'en-us'
# and exits before the first cycle (start-native.sh: "[FAIL] Calypso emulator
# (QEMU) (started but never ready)"). So copy the keymaps only (~917 KB).
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
            # Not fatal: the binary may use another prefix, or a future version may not
            # read them. But this is the first thing to check if QEMU starts then exits.
            echo -e "  ${YELLOW}!${NC} keymaps QEMU introuvables - si QEMU s'arrete au demarrage," >&2
            echo -e "  ${YELLOW}  cherchez \"could not read keymap file\" dans logs/qemu.log${NC}" >&2
        fi
    fi
fi

echo -e "${GREEN}[5c/9] Ajustements osmocom dans le rootfs...${NC}"
echo -e "${GREEN}[5d/9] Patch configs ISO...${NC}"

# SAME recipe as on $TEMP_CONFIG, replayed on the rootfs (idempotent):
# /etc/osmocom in the rootfs comes from the docker IMAGE (docker cp at step 5),
# not from $TEMP_CONFIG, so it may hold files the substitution never saw.
apply_native_post_patches "$ROOTFS/etc" "$ISO_OP_ID" "$ISO_N_MS" "$HOST_IP" \
    "${ISO_NODE:-1}" "${ISO_WAN_TMP:-/nonexistent}" "$SGSN_GTP_IP" "$HLR_IP"

if [ -f "$ROOTFS/etc/osmocom/run.sh" ]; then
    chmod +x "$ROOTFS/etc/osmocom/run.sh"
else
    # Guard: under set -e a missing run.sh would abort the build. The file comes
    # from the image, not the repo: if it is missing, check the image.
    echo -e "  ${YELLOW}!${NC} /etc/osmocom/run.sh absent de l'image ${CYAN}${ISO_SRC_IMAGE}${NC}"
fi

echo -e "  ${GREEN}✓${NC} retouches natives rejouees sur le rootfs (SGSN, MSC, sms-routing, run.sh)"
mkdir -p "$ROOTFS/usr/bin"
# ── /usr/local/bin ALSO in /usr/bin, but NEVER over a dpkg-owned binary ─────
# /usr/local/bin holds wrappers (e.g. tcpdump, which calls /usr/bin/tcpdump):
# copying one over the real binary would make it call itself forever, and
# apt would not repair it. Only files owned by NO package are copied. The dpkg
# file lists are read straight from the rootfs (no chroot, which would not
# work for an arm64 cross build; no dpkg-query).
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

# ── NO osmocom user: root only ──────────────────────────────────────────────
# The image had an "osmocom" account forced to UID 0 (usermod -o -u 0), which
# breaks GDM autologin, yields two HOMEs (two .osmocom/bb) and confusing
# ownership. The account is DELETED and the systemd units are given back to
# root: the upstream Osmocom .service files set "User=osmocom / Group=osmocom"
# and would otherwise fail with "Failed to determine user credentials".
sed -i -e 's/^User=osmocom$/User=root/' -e 's/^Group=osmocom$/Group=root/' \
       "$ROOTFS/lib/systemd/system"/osmo-*.service \
       "$ROOTFS/etc/systemd/system"/osmo-*.service 2>/dev/null || true

chroot "$ROOTFS" userdel -r osmocom 2>/dev/null || true
chroot "$ROOTFS" groupdel osmocom  2>/dev/null || true
rm -rf "$ROOTFS/home/osmocom"
# /var/lib/osmocom (HLR databases, GTP state) and /var/log/osmocom belonged to
# the deleted account: without this chown, writes fail at first boot
# ("Unable to create file").
chown -R 0:0 "$ROOTFS/root/.osmocom" "$ROOTFS/var/lib/osmocom" \
             "$ROOTFS/var/log/osmocom" 2>/dev/null || true

# The Docker image's "osmocom" account was a UID 0 alias and is removed here;
# the real, unprivileged osmocom account is recreated at step 8d.
echo -e "  ${GREEN}✓${NC} alias uid-0 osmocom retire (unites osmo-* rendues a root) + /usr/bin + mobile.cfg prets"

# End of module: `. file` returns the status of its LAST command and
# build-iso.sh runs under set -e. A module ending with a false test
# ("[ ... ] && { ...; }") would abort everything silently. Always 0 here.
true

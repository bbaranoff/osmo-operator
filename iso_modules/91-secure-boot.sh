#!/bin/bash
# iso_modules/91-secure-boot.sh - ISO Secure Boot (shim + grub signes) ou grub-mkrescue
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# --arm : pas de shim ni de xorriso sur le Pi.
if [ "${ISO_ARCH:-amd64}" = "arm64" ]; then return 0; fi

# ══════════════════════════════════════════════════════════════════════════════
# SECURE BOOT - pourquoi cette etape ne peut pas rester grub-mkrescue
# ══════════════════════════════════════════════════════════════════════════════
# grub-mkrescue CONSTRUIT son BOOTX64.EFI a la volee, a partir des modules de
# l'hote. Ce binaire n'est signe par personne. Sur une machine dont le Secure
# Boot est actif, le firmware refuse de le charger et n'affiche qu'une erreur de
# certificat - "Verification failed: (0x1A) Security Violation", ou pire un
# ecran qui retombe au menu de boot sans un mot. L'ISO etait donc inutilisable
# partout ou l'on ne peut pas desactiver Secure Boot dans le firmware, ce qui
# est le cas de la plupart des machines d'entreprise et de beaucoup de portables
# recents.
#
# LA CHAINE DE CONFIANCE, et pourquoi chaque maillon est celui-la :
#
#   firmware --(cle Microsoft)--> shimx64.efi.signed   paquet shim-signed
#            --(cle Canonical)--> gcdx64.efi.signed    paquet grub-efi-amd64-signed
#            --(cle Canonical)--> vmlinuz              linux-image-generic (deja signe)
#
# shim est le SEUL maillon signe par Microsoft, dont la cle est dans a peu pres
# tous les firmwares du marche. Il porte la cle Canonical et valide ce qu'il
# charge ensuite. On ne le fabrique pas : on copie celui du paquet.
#
# gcdx64 ET NON grubx64 - c'est le detail qui coute une soiree. Les deux sont
# signes par Canonical, mais leur PREFIXE compile differe :
#     grubx64.efi.signed  -> prefixe /EFI/ubuntu, cherche sa configuration sur
#                            la partition EFI ; sur une ISO elle n'y est pas, et
#                            GRUB tombe sur son invite "grub>" sans un message.
#     gcdx64.efi.signed   -> prefixe /boot/grub RELATIF AU MEDIUM DE BOOT, la
#                            variante faite pour l'optique. Il trouve donc
#                            $ISOROOT/boot/grub/grub.cfg, celui qu'on vient
#                            d'ecrire, sans stub ni duplication.
# On garde tout de meme un stub en /EFI/ubuntu/grub.cfg sur l'ESP : il ne sert
# que si le repli sur grubx64 s'est declenche, et il ne coute que 60 octets.
#
# CE QUE CETTE ETAPE NE FAIT PAS : signer quoi que ce soit. Aucune cle privee
# n'est manipulee, rien n'est a enroler par l'utilisateur (pas de MokManager a
# la premiere ouverture). On assemble des binaires deja signes par Microsoft et
# Canonical - c'est exactement ce que fait une ISO Ubuntu officielle.
#
# LE BIOS N'EST PAS ABANDONNE. L'image El Torito i386-pc est construite ici par
# grub-mkimage au format i386-pc-eltorito (celui qui embarque deja cdboot.img),
# et la MBR hybride par --grub2-mbr : une machine sans UEFI demarre comme avant.
#
# REPLI. Si un maillon manque sur l'hote (paquet non installe, architecture
# autre), on retombe sur grub-mkrescue - l'ISO d'avant, qui demarre partout SAUF
# en Secure Boot. On le DIT, en clair : une ISO non signee qui se presente comme
# signee, c'est une panne au premier deploiement.

SB_SHIM=""
for c in /usr/lib/shim/shimx64.efi.signed \
         /usr/lib/shim/shimx64.efi.signed.latest \
         /usr/lib/shim/shimx64.efi; do
    [ -f "$c" ] && { SB_SHIM="$c"; break; }
done
# gcdx64 d'abord (prefixe /boot/grub, fait pour l'optique), grubx64 en repli.
SB_GRUB="" ; SB_GRUB_KIND=""
for c in /usr/lib/grub/x86_64-efi-signed/gcdx64.efi.signed:gcd \
         /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed:grub; do
    [ -f "${c%:*}" ] && { SB_GRUB="${c%:*}"; SB_GRUB_KIND="${c##*:}"; break; }
done
SB_MM=""
for c in /usr/lib/shim/mmx64.efi.signed /usr/lib/shim/mmx64.efi; do
    [ -f "$c" ] && { SB_MM="$c"; break; }
done

# Le noyau doit l'etre aussi : shim valide GRUB, GRUB valide le noyau. Un
# vmlinuz non signe s'arrete sur "you need to load the kernel first" ou sur un
# refus de shim_lock, APRES le menu - donc la ou l'on ne soupconne plus l'ISO.
# Les noyaux Ubuntu "generic" le sont ; un noyau maison, non. On regarde la
# signature plutot que de faire confiance au nom du paquet.
SB_KERNEL_SIGNED=0
if command -v sbverify &>/dev/null; then
    sbverify --list "$ISOROOT/boot/vmlinuz" &>/dev/null && SB_KERNEL_SIGNED=1
elif grep -qa '~Module signature appended~\|sbat\|Canonical Ltd\. Secure Boot' "$ISOROOT/boot/vmlinuz" 2>/dev/null; then
    SB_KERNEL_SIGNED=1
fi

SECURE_BOOT_OK=0
if [ -n "$SB_SHIM" ] && [ -n "$SB_GRUB" ] && command -v mmd &>/dev/null; then
    echo -e "${GREEN}[9/9] ISO Secure Boot (shim + grub signes)...${NC}"
    echo -e "  shim : ${CYAN}${SB_SHIM}${NC}"
    echo -e "  grub : ${CYAN}${SB_GRUB}${NC} (${SB_GRUB_KIND})"

    # ── La partition systeme EFI ────────────────────────────────────────────
    # FAT16, et un PLANCHER DE 16 Mo. Le contenu ne pese que ~4 Mo (shim ~1 Mo,
    # grub signe ~2,3 Mo, MokManager ~0,9 Mo), mais FAT16 exige au moins 4085
    # clusters : mkfs.vfat refuse en dessous, avec
    #     mkfs.vfat: Attempting to create a too small or a too large filesystem
    # et l'etape entiere retombait alors en silence sur le repli non signe.
    # 16 Mo a 2 Ko par cluster (-s 4) font 8192 clusters - au large, et 16 Mo
    # sur une ISO de plusieurs Go ne se voient pas.
    SB_ESP="$WORK/efi.img"
    SB_KB=$(( ( $(stat -Lc%s "$SB_SHIM") + $(stat -Lc%s "$SB_GRUB") \
              + $( [ -n "$SB_MM" ] && stat -Lc%s "$SB_MM" || echo 0 ) ) / 1024 + 2048 ))
    [ "$SB_KB" -lt 16384 ] && SB_KB=16384
    rm -f "$SB_ESP"
    mkfs.vfat -F 16 -s 4 -n OSMOEFI -C "$SB_ESP" "$SB_KB" >/dev/null

    mmd   -i "$SB_ESP" ::/EFI ::/EFI/BOOT ::/EFI/ubuntu
    mcopy -i "$SB_ESP" "$SB_SHIM" ::/EFI/BOOT/BOOTX64.EFI
    mcopy -i "$SB_ESP" "$SB_GRUB" ::/EFI/BOOT/grubx64.efi
    [ -n "$SB_MM" ] && mcopy -i "$SB_ESP" "$SB_MM" ::/EFI/BOOT/mmx64.efi

    # Stub : DERNIER RECOURS de la configuration embarquee dans gcdx64 - elle
    # finit par "source $cmdpath/grub.cfg", et $cmdpath est le repertoire d'ou
    # le firmware a charge le binaire, donc /EFI/BOOT sur cette ESP. Il sert
    # aussi tel quel au repli grubx64 (prefixe /EFI/ubuntu).
    #
    # "search --set=root" ne touche PAS a la variable quand il echoue : on vise
    # donc une variable a nous, encore vide, pour pouvoir tester le resultat -
    # et on le DIT quand rien n'est trouve, plutot que de rendre la main a une
    # invite "grub>" que personne ne sait interpreter.
    cat > "$WORK/esp-grub.cfg" <<'ESPCFG'
search --no-floppy --file --set=osmodev /.disk/info
if [ -z "$osmodev" ]; then
    search --no-floppy --file --set=osmodev /boot/grub/grub.cfg
fi
if [ -n "$osmodev" ]; then
    set root=$osmodev
    set prefix=($osmodev)/boot/grub
    configfile ($osmodev)/boot/grub/grub.cfg
fi
echo "GRUB : ni /.disk/info ni /boot/grub/grub.cfg trouves sur les disques vus."
echo "Le medium n'est probablement pas lisible par le firmware a ce stade."
ESPCFG
    mcopy -i "$SB_ESP" "$WORK/esp-grub.cfg" ::/EFI/ubuntu/grub.cfg
    mcopy -i "$SB_ESP" "$WORK/esp-grub.cfg" ::/EFI/BOOT/grub.cfg

    # ── LE MEME ARBRE, AUSSI DANS L'ISO9660 ─────────────────────────────────
    # L'ESP appendue suffit a demarrer depuis un DVD ou une cle ecrite en mode
    # image (dd, Rufus en mode DD). Elle ne suffit PAS a la methode la plus
    # repandue sous Windows : formater la cle en FAT et y COPIER le contenu de
    # l'ISO. Cette copie ne voit que l'ISO9660, ou /EFI/BOOT n'existerait pas -
    # la cle ne demarre alors pas en UEFI, sans que rien n'explique pourquoi.
    # C'est exactement ce que xorriso previent :
    #     WARNING : EFI boot equipment is provided but no directory /EFI/BOOT
    #     WARNING : will emerge in the ISO filesystem.
    # Quelques Mo dupliques ; les ISO Ubuntu font de meme.
    mkdir -p "$ISOROOT/EFI/BOOT"
    cp "$SB_SHIM" "$ISOROOT/EFI/BOOT/BOOTX64.EFI"
    cp "$SB_GRUB" "$ISOROOT/EFI/BOOT/grubx64.efi"
    [ -n "$SB_MM" ] && cp "$SB_MM" "$ISOROOT/EFI/BOOT/mmx64.efi"
    cp "$WORK/esp-grub.cfg" "$ISOROOT/EFI/BOOT/grub.cfg"
    mkdir -p "$ISOROOT/EFI/ubuntu"
    cp "$WORK/esp-grub.cfg" "$ISOROOT/EFI/ubuntu/grub.cfg"

    # ── L'amorce BIOS, construite ici puisqu'on n'appelle plus grub-mkrescue ──
    # i386-pc-eltorito embarque deja cdboot.img : cette image est directement
    # utilisable comme -eltorito-boot, pas de concatenation a faire.
    SB_BIOS="$WORK/eltorito.img"
    grub-mkimage -O i386-pc-eltorito -p /boot/grub -o "$SB_BIOS" \
        biosdisk iso9660 part_msdos part_gpt fat ext2 normal linux configfile \
        search search_label search_fs_uuid search_fs_file loopback gzio \
        all_video gfxterm videotest videoinfo test echo ls minicmd sleep \
        halt reboot chain 2>/dev/null

    if [ -s "$SB_BIOS" ]; then
        # -eltorito-alt-boot separe les deux entrees du catalogue : la premiere
        # (BIOS) et la seconde (UEFI). "--interval:appended_partition_2" designe
        # la partition qu'on ajoute juste apres, sans la copier deux fois dans
        # l'image.
        xorriso -as mkisofs -iso-level 3 \
            -volid "$LABEL" \
            -full-iso9660-filenames \
            -eltorito-boot boot/grub/eltorito.img \
                -no-emul-boot -boot-load-size 4 -boot-info-table \
                --eltorito-catalog boot/grub/boot.cat \
                --grub2-boot-info \
                --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
            -eltorito-alt-boot \
                -e --interval:appended_partition_2:all:: \
                -no-emul-boot \
            -append_partition 2 0xef "$SB_ESP" \
            -appended_part_as_gpt \
            -o "$OUTPUT" \
            -graft-points "$ISOROOT" "/boot/grub/eltorito.img=$SB_BIOS" \
            && SECURE_BOOT_OK=1
    fi

    if [ "$SECURE_BOOT_OK" = "1" ]; then
        if [ "$SB_KERNEL_SIGNED" = "1" ]; then
            echo -e "  ${GREEN}✓${NC} ISO signee Secure Boot : shim -> grub -> noyau, chaine complete"
        else
            echo -e "  ${YELLOW}⚠${NC}  shim et grub sont signes, mais la signature du NOYAU n'a pas"
            echo -e "     pu etre confirmee ($ISOROOT/boot/vmlinuz). Si le boot s'arrete APRES"
            echo -e "     le menu GRUB, c'est la : installez sbsigntool pour le verifier, ou"
            echo -e "     utilisez un noyau linux-image-generic non recompile."
        fi
    else
        echo -e "  ${YELLOW}⚠${NC}  assemblage Secure Boot echoue - repli sur grub-mkrescue"
    fi
else
    echo -e "${YELLOW}[9/9] Secure Boot indisponible sur cet hote :${NC}"
    [ -z "$SB_SHIM" ] && echo -e "     shim absent  -> apt install ${CYAN}shim-signed${NC}"
    [ -z "$SB_GRUB" ] && echo -e "     grub signe absent -> apt install ${CYAN}grub-efi-amd64-signed${NC}"
    command -v mmd &>/dev/null || echo -e "     mtools absent -> apt install ${CYAN}mtools dosfstools${NC}"
fi

if [ "$SECURE_BOOT_OK" != "1" ]; then
# Repli : l'ancienne recette, mot pour mot. Elle produit une ISO qui demarre en
# BIOS et en UEFI sans Secure Boot - c'est ce qu'on avait avant, et c'est mieux
# que pas d'ISO du tout.
#
# Wrapper: inject -iso-level 3 (multi-extent, lifts the 4 GiB single-file cap)
# into grub-mkrescue's internal `xorriso -as mkisofs` call.
XORRISO_WRAP="$WORK/xorriso-iso-level3"
cat > "$XORRISO_WRAP" <<'EOF'
#!/bin/sh
if [ "$1" = "-as" ] && [ "$2" = "mkisofs" ]; then
    shift 2
    exec xorriso -as mkisofs -iso-level 3 "$@"
fi
exec xorriso "$@"
EOF
chmod +x "$XORRISO_WRAP"

    grub-mkrescue --xorriso="$XORRISO_WRAP" -o "$OUTPUT" "$ISOROOT" \
        --product-name "osmo-operator $VERSION" -- -volid "$LABEL"
    if command -v isohybrid &>/dev/null; then
        isohybrid --uefi "$OUTPUT"
    fi
    echo -e "  ${YELLOW}!${NC} ISO NON signee : elle ne demarrera pas si Secure Boot est actif."
    echo -e "    Desactivez-le dans le firmware, ou construisez sur un hote qui a"
    echo -e "    ${CYAN}shim-signed${NC} et ${CYAN}grub-efi-amd64-signed${NC}."
fi

if [ ! -f "$OUTPUT" ]; then
    echo -e "${RED}Creation de l'ISO echouee - rien n'a ete ecrit${NC}"
    exit 1
fi


#!/bin/bash
# osmo-vm-porte.sh - test the installed bench (two systems, porte TPM, black
# box) in a VM: QEMU + UEFI Secure Boot (OVMF, Microsoft keys) + a software
# TPM 2.0 (swtpm). The VM keeps its disk, firmware variables and TPM state in
# WORK (default /var/tmp/osmo-vm-porte), so install once, then boot again.
#
#   osmo-vm-porte.sh installer ISO     boot the ISO, install with Calamares
#                                      (« Chiffrer le systeme », page
#                                      « Demarrage » : code TPM)
#   osmo-vm-porte.sh demarrer          boot the installed disk
#   osmo-vm-porte.sh fouiller CLE.bin  while the VM runs (root session reached
#                                      through the porte): dump the guest RAM
#                                      and look for the TOTP key - copy it
#                                      first from nirvana's system
#                                      (/etc/osmo-porte/secret.bin). Expected:
#                                      not found (it never leaves the TPM).
#   osmo-vm-porte.sh effacer           remove the VM (disk, variables, TPM)
#
# What to check, in order:
#   1. first porte boot: « code TPM : AUCUN », Enter, passphrase -> nirvana;
#      sudo osmo-porte sceller; sudo osmo-porte qr (or oathtool --totp=sha256)
#   2. reboot: the porte code == the phone's / oathtool's
#   3. Esc at the porte -> root live: cat /sys/kernel/security/lockdown
#      (expected [integrity] or [confidentiality]); osmo-vm-porte.sh fouiller
#   4. change one byte of the EFI menu from root's session
#      (/boot/efi/EFI/ubuntu/grub.cfg: mount the EFI partition) and reboot:
#      the code must be « AUCUN »
#   5. GRUB entry « consulter la boite noire » after setting its passphrase
set -u
W="${OSMO_VM_WORK:-/var/tmp/osmo-vm-porte}"
CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
VARS0=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
log() { echo "osmo-vm-porte : $*"; }

prerequis() {
    local m=""
    for c in qemu-system-x86_64 swtpm; do command -v "$c" >/dev/null || m="$m $c"; done
    [ -f "$CODE" ] && [ -f "$VARS0" ] || m="$m ovmf"
    [ -z "$m" ] || { log "manque :$m (apt install qemu-system-x86 swtpm ovmf)"; exit 1; }
    [ -e /dev/kvm ] || log "ATTENTION : pas de /dev/kvm - tres lent"
}

preparer() {
    mkdir -p "$W/tpm"
    [ -f "$W/disque.qcow2" ] || qemu-img create -q -f qcow2 "$W/disque.qcow2" 64G
    [ -f "$W/vars.fd" ] || cp "$VARS0" "$W/vars.fd"
    if ! [ -S "$W/swtpm.sock" ] || ! pgrep -f "swtpm.*$W/swtpm.sock" >/dev/null; then
        rm -f "$W/swtpm.sock"
        swtpm socket --tpm2 --tpmstate dir="$W/tpm" \
            --ctrl type=unixio,path="$W/swtpm.sock" --log file="$W/swtpm.log" --daemon \
            || { log "swtpm n a pas demarre"; exit 1; }
    fi
}

lancer() {   # lancer [QEMU ARGS...]
    exec qemu-system-x86_64 -name osmo-vm-porte \
        -machine q35,smm=on,accel=kvm:tcg -cpu host -smp 4 -m 8G \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
        -drive if=pflash,format=raw,unit=1,file="$W/vars.fd" \
        -chardev socket,id=chrtpm,path="$W/swtpm.sock" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
        -drive file="$W/disque.qcow2",if=virtio,format=qcow2 \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -device virtio-vga -display gtk \
        -monitor unix:"$W/monitor.sock",server,nowait \
        "$@"
}

case "${1:-}" in
    installer)
        prerequis; iso="${2:?usage : osmo-vm-porte.sh installer ISO}"
        [ -f "$iso" ] || { log "$iso absent"; exit 1; }
        preparer
        lancer -cdrom "$iso" -boot order=d,menu=on
        ;;
    demarrer)
        prerequis; preparer
        [ -f "$W/disque.qcow2" ] || { log "pas de disque : osmo-vm-porte.sh installer ISO"; exit 1; }
        lancer -boot menu=on
        ;;
    fouiller)
        cle="${2:?usage : osmo-vm-porte.sh fouiller CLE.bin}"
        [ -S "$W/monitor.sock" ] || { log "la VM ne tourne pas"; exit 1; }
        command -v socat >/dev/null || { log "socat requis"; exit 1; }
        rm -f "$W/memoire.elf"
        log "copie de la RAM de la VM (8 Go)..."
        printf 'dump-guest-memory %s\n' "$W/memoire.elf" | socat - UNIX-CONNECT:"$W/monitor.sock" >/dev/null
        while sleep 2; do
            printf 'info dump\n' | socat - UNIX-CONNECT:"$W/monitor.sock" 2>/dev/null | grep -q 'completed\|Status: none' && break
        done
        python3 - "$W/memoire.elf" "$cle" <<'PY'
import base64, mmap, sys
mem, cle = sys.argv[1], open(sys.argv[2], 'rb').read()
motifs = {"cle brute": cle,
          "cle base32": base64.b32encode(cle).rstrip(b"="),
          "cle hex": cle.hex().encode()}
with open(mem, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
    trouve = False
    for nom, motif in motifs.items():
        i = m.find(motif)
        print("%-11s : %s" % (nom, "TROUVEE a l'octet %d" % i if i >= 0 else "absente"))
        trouve |= i >= 0
print("RESULTAT :", "ECHEC - la cle est en memoire" if trouve else "OK - la cle n'est nulle part en RAM")
PY
        rm -f "$W/memoire.elf"
        ;;
    effacer)
        pkill -f "swtpm.*$W/swtpm.sock" 2>/dev/null
        rm -f "$W/disque.qcow2" "$W/vars.fd" "$W/swtpm.sock" "$W/monitor.sock" "$W/swtpm.log"
        rm -rf "${W:?}/tpm"
        log "VM effacee ($W)"
        ;;
    *)
        sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac

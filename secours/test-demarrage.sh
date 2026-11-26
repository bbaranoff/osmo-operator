#!/bin/bash
# secours/test-demarrage.sh ISO [DISQUE] - la cle de secours demarree dans
# QEMU, SECURE BOOT ACTIF avec les cles Microsoft (OVMF *.secboot + VARS *.ms) :
# shim, GRUB et le noyau doivent passer. L entree « console serie » est
# choisie au clavier (moniteur QEMU), la procedure lue sur le port serie.
#
#   sans DISQUE : la cle doit dire « Secure Boot actif » puis ne trouver aucun
#                 poste (rien n est attache) ;
#   avec DISQUE (image ou peripherique, ouvert en LECTURE SEULE) : la
#                 procedure complete, le rapport est affiche.
# KVM si /dev/kvm est la, sinon emulation (plus lent : le runner GitHub).
# Code de sortie 0 si ce qui est attendu a ete vu.
set -u
ISO="${1:?usage : test-demarrage.sh ISO [DISQUE]}"
DISQUE="${2:-}"
T="$(mktemp -d)"
trap 'kill "$(cat "$T/pid" 2>/dev/null)" 2>/dev/null; rm -rf "$T"' EXIT

code=""; vars=""
for c in /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd; do [ -f "$c" ] && { code="$c"; break; }; done
for v in /usr/share/OVMF/OVMF_VARS_4M.ms.fd /usr/share/OVMF/OVMF_VARS.ms.fd; do [ -f "$v" ] && { vars="$v"; break; }; done
[ -n "$code" ] && [ -n "$vars" ] || { echo "OVMF avec Secure Boot introuvable (paquet ovmf)" >&2; exit 2; }
cp "$vars" "$T/vars.fd"
accel=(-machine q35,smm=on); [ -w /dev/kvm ] && accel+=(-enable-kvm)
disque=(); [ -n "$DISQUE" ] && disque=(-drive "file=$DISQUE,format=raw,if=virtio,readonly=on")
[ -n "$DISQUE" ] && case "$DISQUE" in *.qcow2) disque=(-drive "file=$DISQUE,format=qcow2,if=virtio");; esac

qemu-system-x86_64 "${accel[@]}" -m 3072 -smp 2 -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,file="$code",readonly=on \
    -drive if=pflash,format=raw,unit=1,file="$T/vars.fd" \
    -drive file="$ISO",media=cdrom,readonly=on "${disque[@]}" \
    -display none -serial file:"$T/serie.log" -monitor unix:"$T/mon",server,nowait -boot d >/dev/null 2>&1 &
echo $! > "$T/pid"

# le menu GRUB (5 s), puis la troisieme entree : console serie
for _ in $(seq 1 240); do grep -q "executed automatically" "$T/serie.log" 2>/dev/null && break; sleep 0.5; done
for k in down down ret; do echo "sendkey $k" | socat - UNIX-CONNECT:"$T/mon" >/dev/null; sleep 0.3; done
for _ in $(seq 1 240); do grep -q "Ton choix" "$T/serie.log" 2>/dev/null && break; sleep 5; done

propre() { sed 's/\x1b\[[0-9;]*[mHJK]//g' "$T/serie.log" | tr -d '\r'; }
propre | sed -n '/OSMO-SECOURS/,/osmo-secours termine/p' | grep -v '^\s*$\|EXT4-fs\|random:'
ok=1
propre | grep -q "OSMO-SECOURS" || { echo "ECHEC : la procedure n a pas demarre" >&2; ok=0; }
propre | grep -q "Secure Boot actif" || { echo "ECHEC : Secure Boot pas vu actif" >&2; ok=0; }
if [ -z "$DISQUE" ]; then
    propre | grep -q "pas de poste securise trouve" || { echo "ECHEC : sans disque, la cle aurait du ne rien trouver" >&2; ok=0; }
else
    propre | grep -qE "CONFORME|COMPROMISSION" || { echo "ECHEC : pas de verdict sur le disque" >&2; ok=0; }
fi
[ "$ok" = 1 ] && echo "TEST DE DEMARRAGE REUSSI (Secure Boot, chaine signee, procedure lancee)"
[ "$ok" = 1 ]

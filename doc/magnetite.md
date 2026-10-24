# FreeCalypso Magnetite dans qosmo (le vrai firmware TI, cible Motorola C139)

[2026-10-21] Le firmware ARM d'origine (TI TCS211, recompile par le projet FreeCalypso
Magnetite de Mychaela Falconia) tourne dans l'emulateur Calypso du depot (qosmo) a la place
de la layer1 osmocom-bb : Nucleus, la pile GSM L23 de TI, l'interface BMI, les traces RVTMUX.
Le telephone emule devient un **C139** (ecran couleur 96x64 sur uWire, meme clavier Compal
que le C123), parce que c'est la seule cible Mot C1xx pour laquelle Magnetite a une
configuration avec interface (`c139 hybrid-ui-vo`) ; le C11x/C123 n'a qu'un pseudo-modem AT.

## 1. Sources et chaine de compilation

Magnetite ne se compile **pas** avec gcc (ni /root/gnuarm) : tout l'arbre (sources, `.s` en
syntaxe TI, blobs `.lib` COFF, Nucleus) exige le compilateur TI TMS470 1.22e, un binaire
Windows qu'on fait tourner sous Wine.

```
/root/.env/bin/hg clone https://hg.themyscira.org/fc-magnetite /opt/GSM/fc-magnetite
/root/.env/bin/hg clone https://hg.themyscira.org/freecalypso-tools /opt/GSM/fc-host-tools   # rvinterf, fc-shell, fc-fsio
dpkg --add-architecture i386 && apt-get update && apt-get install -y wine64 wine32:i386
# environnement TI (compilateur, cygwin, perl, java) : ftp.freecalypso.org/pub/GSM/TI_src/wine/installed-env.tar.xz
mkdir -p ~/.wine/drive_c && tar xJf installed-env.tar.xz -C ~/.wine/drive_c && wineboot -u
gcc -O2 -o /usr/local/bin/nowhine nowhine.c      # wrapper qui tait les plaintes de wine (meme repertoire FTP)
cd /opt/GSM/fc-magnetite && (cd helpers && make) && ./configure.sh c139 hybrid-ui-vo
cd build-c139-hybrid-ui-vo && make -j4           # ~1 min, 4 cl470 sous Wine en parallele
```

Resultat : `fwimage.bin` (2 Mo, a flasher a 0x10000) et `flash-script`. Les copies sont dans
`/opt/GSM/fc-wine-dl` (env Wine) et `/opt/GSM/fc-dl` (bootloader).

## 2. L'image flash

Sur un C1xx le boot ROM est hors circuit : le CPU demarre a 0 dans la flash, ou le bootloader
Compal (version FreeCalypso `compal-flash-boot-for-fc.bin`, 8 Ko) saute a 0x10058. L'image de
4 MiB pour qosmo est assemblee ainsi (`/opt/GSM/firmware/magnetite/c139-flash.img`) :

```
img = 0xFF * 4 MiB ; img[0:8192] = compal-flash-boot-for-fc.bin ; img[0x10000:] = fwimage.bin
```

Le FFS (systeme de fichiers du firmware) vit dans cette flash a 0x3C0000 (3 secteurs de 64 Ko).

## 3. Ce qu'il a fallu changer dans qosmo

| fichier | changement |
|---|---|
| `hw/arm/calypso/calypso_uwire.c` (nouveau) | controleur uWire 0xFFFE4000 + ecran C139 (mots de 9 bits sur CS0, fenetre 0x10-0x15, RGB565) ; publie `/dev/shm/calypso_lcd` avec le magic `C139LCD` ; propriete `c139-lcd`, posee par `CALYPSO_LCD=c139` |
| `calypso_mb.c` | sans `-kernel` et avec `-drive if=pflash` : pas de vecteurs factices, demarrage a 0 ; flash identifiee Intel 0x88C4 (28F320C3B, celle des C139, reconnue par `ffs/board/dev.c`) |
| `calypso_soc.c` | `flash_boot` : l'ecriture de CNTL_ARM_CLK ne remappe plus l'IRAM a 0 (Magnetite y ecrit 0x40 : l'IRAM pleine de zeros recouvrait la flash) |
| `hw/ssi/calypso_spi.c` | la vraie trame TWL3025 (bit 0 lecture, registre en 5..1, donnee en 15..6, reponse dans RX_LSB), STATUS = RE_ST et WE_ST, CTRL bit 0 ou 1 declenche, VRPCSTS = ONBSTS (bouton ON relache : TI attend sa liberation en boucle) |
| `calypso_trx.c` | le TDMA (IRQ trame = tick Nucleus) demarre au premier `TP_Enable` : TI n'ecrit jamais TPU_INT_CTRL |
| `target/arm/tcg/hflags.c` | plus de fault d'alignement en ARMv4 (le driver flash TI ecrit un demi-mot a l'adresse impaire 0x5555, comme sur ARM7TDMI) |

Le CPU doit etre **ti925t** (ARMv4T). Avec arm946 (ARMv5) le `pop {pc}` des trampolines Thumb
de TI interworke vers ARM et plante au premier appel.

## 4. Lancer

Seul, avec la couche 1 gr-gsm de qosmo (pas de DSP) :

```
scripts/magnetite-c139.sh start        # QEMU + rvinterf ; RUNDIR /dev/shm/magnetite ; flash de travail persistante
scripts/magnetite-c139.sh gtk          # la fenetre : photo du C139, ecran couleur, touches cliquables
scripts/magnetite-c139.sh traces       # rvinterf.log (traces L1, GPF, Riviera decodees)
scripts/magnetite-c139.sh fsio ls /    # fc-fsio sur le socket de rvinterf (voir points ouverts)
scripts/magnetite-c139.sh stop         # FLASH_RESET=1 au start suivant pour repartir d'un FFS vierge
```

Sur le banc DSP (c54x_exe, la ROM du DSP emulee) : `c54x_exe/run.sh` avec
`FIRMWARE_FLASH=/opt/GSM/firmware/magnetite/c139-flash.img` (CPU ti925t, `CALYPSO_LCD=c139`,
rvinterf a l'etape 3 a la place d'osmocon, pas de mobile a l'etape 4 ; air ou pont inchanges).
`start-native.sh --ms-magnetite` le pose : comme `--ms`, mais le mobile est Magnetite
(`--bts --ms-magnetite` : la BTS en instance 1, le C139 Magnetite en instance 2 par l'air).

La fenetre : `tools/osmo-c123-gtk.py --modele c139 [--instance N]` (auto : le magic de l'ecran
partage). Photo `data/c139.jpg` (Raimond Spekking, Wikimedia Commons, CC BY-SA 4.0, credit
dans `data/c139.txt`), zones `data/c139-zones.json` (`--calibrate` pour les reprendre).

## 5. Etat au 21/10/2026 (fin de journee)

Corrections d'emulation ajoutees dans l'apres-midi (toutes dans qosmo, non commitees) :

- `target/arm/tcg/translate.c` gen_bx : en ARMv4T un BX vers l'etat ARM ignore le bit 1
  (TI int.s fait « bx pc » en Thumb a une adresse 2 mod 4 : cible (pc+4) & ~3). Sans ca,
  prefetch abort dans INT_DisableIRQ depuis le gestionnaire de veille, et le HISR timer de
  Nucleus ne tournait plus jamais (sleeps longs, UART RX, SIM tous geles). C'etait LA cause.
- `hw/char/calypso_uart.c` : IT de reveil RX (SCR[4] / SSR[1]) du driver TI, plus de stub
  romload en boot flash ; `CALYPSO_UART_DEBUG=1` trace IER/SCR/rx.
- `hw/arm/calypso/calypso_sim.c` : ATR livre en mode manuel (CONF1 SCLKEN/SRSTLEV), IT TX
  apres chaque octet, octet de procedure T=0 pour les commandes de lecture, reponses de la
  carte differees de 1,5 ms, reponse SELECT conforme GSM 11.11 (carte 3 V, CHV1 desactive) ;
  nouvel ATR a chaque warm reset. Resultat : le firmware lit SST, AD, IMSI, LOCI, Kc...
  puis le MMI affiche « SIM Invalid » (a elucider : sans reseau, ou IMEI absent du FFS).
- `hw/ssi/calypso_spi.c` : VRPCSIM renvoie RSIMRSU (regulateur SIM pret).
- `hw/arm/calypso/calypso_mb.c` : flash 16 bits en boot flash, identifiants places pour que
  drv.c lise 0x0089 / 0x88C4 : le FFS reconnait la flash (« ffs not formatted »).
  `fc-fsio format /` efface et programme les 3 blocs (trace pflash OK) puis le firmware
  finit dans os_SystemError : a reprendre (relecture apres programmation ? erreur FFS ?).
- fc-fsio / fc-shell fonctionnent (ETM par rvinterf) : `scripts/magnetite-c139.sh fsio ls /`.

Outils : `QEMU_GDB=1 [QEMU_GDB_WAIT=1]` (stub gdb tcp::1240, gdb-multiarch, adresses dans
fwimage.map ; les points d'arret perturbent le firmware, preferer in_asm ou le vidage des
taches Nucleus par le moniteur : TCD_Created_Tasks_List 0x80cd60), `QEMU_TRACE='pflash_*'`,
`QEMU_DEBUG_FLAGS=int,in_asm`. Un build DISABLE_SLEEP=1 existe (build-c139-hybrid-ui-vo-nosleep,
image c139-flash-sleep.img = build normal) mais n'est pas necessaire depuis le correctif gen_bx.

--ms-magnetite : corrige a 11:10, la flash Magnetite n'est passee qu'au mobile (instance 2),
le TRX de la BTS garde le firmware trx (run.sh refuse FIRMWARE_FLASH avec OSMO_TRX=1).
La fenetre GTK bascule seule en C139 quand l'ecran partage change de magic, se relance avec
/usr/bin/python3 si gi manque.

[2026-10-24] « SIM Invalid » elucide (qosmo `calypso_sim.c`) : l'IT TX etait levee aussitot l'octet ecrit, l'en-tete
partait en quelques us et l'ACK arrivait 1,5 ms apres le premier octet. `SIM_Command_Base` ecrit le premier octet puis
seulement passe `moderx` a 6 : une tache SIM preemptee entre les deux rangeait l'ACK comme SW1, finissait en
SIM_ERR_WAIT et renvoyait un en-tete que l'emulateur prenait pour les donnees (`SELECT 0xa0a4`, puis `CLA=00 INS=00`
-> 6D00 a perpetuite). Correctifs : IT TX apres un temps caractere (`CALYPSO_SIM_US_OCTET`), et un silence de plus
de 500 ms au milieu d'un APDU le resynchronise.

Points ouverts : os_SystemError au format du FFS ; accrochage reseau sur le
banc (--bts --ms-magnetite) jamais observe jusqu'au LU ; DSP reel « occupe boot ».

# Lancer le téléphone émulé à la main, processus par processus

> Version du 2026-10-03. Retour : [Telephone-emule](Telephone-emule.md).
>
> Chaque commande est celle que **construit** `c54x_exe/run.sh` (montage DSP, appelé par
> `osmo-operator/start-direct.sh`), variables **dépliées** avec les valeurs que pose
> `start-direct.sh` en DSP. Les lignes citées sont celles du 2026-10-03. Base : `c54x_exe/LAUNCH.md`.

Convention : un terminal par processus (ou `&` + redirection comme ci-dessous). Journaux dans
`/tmp/c54x-pont/` comme `run.sh` (`run.sh:42`).

```bash
mkdir -p /tmp/c54x-pont
```

## Variables communes (montage DSP)

`start-direct.sh` les exporte avant de passer la main à `c54x_exe/run.sh` (bloc « LE BANC DSP :
RÉGLAGES MESURÉS, PUIS PASSAGE DE MAIN ») ; `run.sh:57` en déduit `CALYPSO_PONT_LOCKSTEP=1`.
Elles sont héritées par **tous** les processus suivants :

```bash
export CALYPSO_BSP_STREAM=1        # un burst TS0 par trame, dans l'ordre des FN
export CALYPSO_RHEA_DMA_XFER=1     # sans lui : pas de SB, pas de BCCH, pas de SI
export CALYPSO_PONT_LOCKSTEP=1     # QEMU n'avance la trame que quand le DSP a fini (run.sh:50-57)
```

---

## Étape 0 — votre réseau (supposé installé)

Le téléphone n'en lance rien. Ordre du banc : STP, HLR, MGW, MSC, BSC (`qosmo/run_modules/10…14`),
puis la BTS (`60-bts.sh`). Avec systemd, comme `c54x_exe/run_real.sh` :

```bash
for u in osmo-hlr osmo-stp osmo-msc osmo-mgw osmo-bsc; do systemctl is-active --quiet "$u" || systemctl start "$u"; done
systemctl restart osmo-bts-trx
```

Sans systemd, la BTS se lance comme `qosmo/run_modules/60-bts.sh:49` :

```bash
osmo-bts-trx -c /etc/osmocom/osmo-bts-trx.cfg
```

**Passer à la suite quand** : la VTY de la BTS répond (`telnet 127.0.0.1 4241`, port VTY par défaut
d'osmo-bts — **À CONFIRMER** pour votre config) et le BSC a accepté l'OML (`show bts 0` sur la VTY
BSC 4242). La BTS envoie déjà ses commandes TRXC vers 5701 ; personne ne répond encore, c'est
normal : le pont (étape 5) les recevra.

Vérifier : `ss -ulnp | grep -E ':580[0-2]'` → osmo-bts-trx sur 5800-5802 (défaut d'osmo-bts-trx,
`pont/trx.py:184` y renvoie l'horloge).

---

## Étape 1 — `c54x_exe --arm` (le DSP)

Nettoyage préalable (`run.sh:96-99`) :

```bash
rm -f /dev/shm/calypso_api_ram /tmp/calypso_dsp.sock /dev/shm/calypso_tch_cfg
```

Commande (`run.sh:102`, avec `INSNS=120000` de start-direct.sh, `IQ=none`, `AMP=30000`, `VERB=-v`) :

```bash
cd /opt/GSM/c54x_exe
CALYPSO_IQDUMP_FCCH=1 CALYPSO_BSP_ATTENTE_MS=40 \
  ./c54x_exe --arm --insns 120000 --iq none --amp 30000 -v > /tmp/c54x-pont/dsp.log 2>&1 &
echo $! > /tmp/c54x-pont/dsp.pid
```

- Publie `/dev/shm/calypso_api_ram` et `/tmp/calypso_dsp.sock` ; écoute **UDP 6702** (BSP) (`LAUNCH.md:42-45`).
- ROM lue dans `/opt/GSM` (`--rom-dir`, `src/main.c:105`).

**Passer à la suite quand** (`run.sh:104`, attente 5 s) :

```bash
test -S /tmp/calypso_dsp.sock && grep -a "en attente de l'ARM" /tmp/c54x-pont/dsp.log
# pont : en attente de l'ARM sur /tmp/calypso_dsp.sock (API RAM : /dev/shm...)
ss -ulnp | grep 6702
```

---

## Étape 2 — QEMU / qosmo (l'ARM + layer1 osmocom-bb)

Commande (`run.sh:121-136`, `GDB=1`, `GDB_STUB=1234`, `MONITOR=/tmp/qemu-monitor-pont.sock`) :

```bash
rm -f /tmp/qemu-monitor-pont.sock
CALYPSO_PONT_RETRY_DIV=64 CALYPSO_DSP_EXTERN=1 \
  /opt/GSM/qosmo/build/qemu-system-arm -M calypso -cpu arm946 -display none -parallel none \
    -serial pty -serial pty -monitor unix:/tmp/qemu-monitor-pont.sock,server,nowait \
    -gdb tcp:127.0.0.1:1234 \
    -kernel /opt/GSM/firmware/board/compal_e88/layer1.highram.elf > /tmp/c54x-pont/qemu.log 2>&1 &
echo $! > /tmp/c54x-pont/qemu.pid
```

Console gdb optionnelle (`run.sh:138-142`) — le chemin par défaut de `run.sh:48` est mort, prendre celui de qosmo :

```bash
python3 /opt/GSM/qosmo/tools/gdb-telnet.py --port 44444 --stub 1234 \
  --elf /opt/GSM/firmware/board/compal_e88/layer1.highram.elf > /tmp/c54x-pont/gdb.log 2>&1 &
```

**Passer à la suite quand** (`run.sh:143-145`, attente 10 s) :

```bash
grep -a "label serial0" /tmp/c54x-pont/qemu.log          # char device redirected to /dev/pts/N (label serial0)
grep -a "pont DSP : API RAM partagee" /tmp/c54x-pont/qemu.log
```

Puis extraire le pty du modem (`run.sh:149`) :

```bash
sed -n 's/.*redirected to \(\/dev\/pts\/[0-9]*\) (label serial0).*/\1/p' /tmp/c54x-pont/qemu.log | head -1 > /tmp/c54x-pont/modem.pty
cat /tmp/c54x-pont/modem.pty
```

Côté DSP doivent apparaître `RESET #1 ... pc=0xff80` puis `DSP boote (premier IDLE)`
(`LAUNCH.md:97`, `src/pont.c:1608,1921`) ; ils peuvent n'arriver qu'une fois le firmware chargé
(étape 3) — **À CONFIRMER** l'instant exact. Autres lignes QEMU attendues (`LAUNCH.md:89-96`) :
`[trx] pont DSP : RESET_DSP relache par le firmware -> PONT_RESET`,
`[trx] pont DSP : le TDMA du firmware prend le relais du timer de boot`.

Vérifier la machine : `printf 'info status\n' | socat - UNIX-CONNECT:/tmp/qemu-monitor-pont.sock` → `VM status: running`.

---

## Étape 3 — `osmocon` (romload + relais L1CTL)

Commande (`run.sh:161-164`) :

```bash
rm -f /tmp/osmocom_l2
stdbuf -oL -eL /opt/GSM/osmocom-bb/src/host/osmocon/osmocon -m romload -i 100 \
  -p "$(cat /tmp/c54x-pont/modem.pty)" -s /tmp/osmocom_l2 \
  /opt/GSM/firmware/board/compal_e88/layer1.highram.bin > /tmp/c54x-pont/osmocon.log 2>&1 &
echo $! > /tmp/c54x-pont/osmocon.pid
```

**Passer à la suite quand** (`run.sh:165`, attente 30 s ; `LAUNCH.md:118-119`) :

```bash
grep -a "your code is running now" /tmp/c54x-pont/osmocon.log
# Received ident ack / Progress: 100% / Received branch ack, your code is running now!
test -S /tmp/osmocom_l2
```

Le dernier printf du firmware se lit aussi au moniteur (`LAUNCH.md:98-99`) :
`printf 'xp /96bx 0x008305f0\n' | nc -U /tmp/qemu-monitor-pont.sock` → `DSP API Version: 0x4e2a 0x491a`.

---

## Étape 4 — `mobile` (couches 2/3)

Commande (`run.sh:177-191`, `L23_SYNC_RETRIES_SELECTION=8` en DSP) :

```bash
ss -ltn | grep -q ':4347 ' && echo "VTY 4347 deja prise"      # run.sh:178-181
L23_SYNC_RETRIES_SELECTION=8 stdbuf -oL mobile -c /opt/GSM/c54x_exe/mobile_pont.cfg \
  > /tmp/c54x-pont/mobile.log 2>&1 &
echo $! > /tmp/c54x-pont/mobile.pid
```

**Passer à la suite quand** : le processus vit après 2 s (`run.sh:192-193`) ; dans les 5 s, côté
osmocon : `L1CTL_PM_REQ`, `L1CTL_RESET_REQ: FULL!`, `L1CTL_FBSB_REQ (arfcn=514 …)` (`LAUNCH.md:135-137`).
Sans pont : `FBSB RESP: result=255` en boucle, attendu (`LAUNCH.md:138`).

Vérifier : `telnet 127.0.0.1 4347` puis `show ms`.

---

## Étape 5 — `pont_dsp.py` (BTS ↔ DSP)

Commande (`run.sh:200-206` : le pont est lancé depuis la racine d'osmo-operator, avec
`--dsp-port 6702`, **sans** `--no-record` car `PONT_AIRREC=1`) :

```bash
cd /opt/GSM/osmo-operator
PONT_BSC_CFG=/etc/osmocom/osmo-bsc.cfg PONT_ARFCN=514 PONT_BSIC=7 \
  python3 pont/pont_dsp.py --dsp-port 6702 > /tmp/c54x-pont/pont.log 2>&1 &
echo $! > /tmp/c54x-pont/pont.pid
```

`PONT_BSC_CFG`, `PONT_ARFCN`, `PONT_BSIC` valent ici leurs défauts (`pont/config.py:46-52`) ; à
adapter à **votre** cellule. L'enregistrement I/Q écrit dans `/root/record.cfile` par défaut
(`config.py:81`) : ajoutez `--no-record` si vous ne le voulez pas.

**Passer à la suite quand** (`run.sh:206`, attente 10 s) :

```bash
grep -a "pont TRX : ports" /tmp/c54x-pont/pont.log
# pont TRX : ports 5700/5701/5702, ARFCN 514, BSIC 7, avance UL 3 trames
grep -a "horloge armee" /tmp/c54x-pont/pont.log     # BTS 127.0.0.1 : horloge armee vers le port 5800
grep -a "CTRL " /tmp/c54x-pont/pont.log | head      # commandes TRXC de la BTS (POWERON, RXTUNE…)
```

puis des lignes `STATS fn=… | DL bursts=N` avec N qui croît (`LAUNCH.md:157-158`).

> **Bruit (optionnel)** : pour dégrader le descendant, lancer `c54x_exe` avec `CALYPSO_BSP_PORT=16702`
> et `python3 /opt/GSM/qosmo/tools/injecteur_bruit.py --cible dsp --mode ber --ber 0.01` **avant** ce
> pont (il prend 6702) ; `run.sh` le fait avec `BRUIT_MODE=…` (étape b). Voir [Injecteur-bruit](Injecteur-bruit.md).

---

## Étape 6 — vérifier le service

| Quoi | Commande | Attendu | Source |
|---|---|---|---|
| SI lus | `grep -a "New SYSTEM INFORMATION" /tmp/c54x-pont/mobile.log` | SI 1, 2, 3, 4… | `run_real.sh` |
| LAI | `grep -aoE "lai=[0-9]+-[0-9]+-[0-9]+" /tmp/c54x-pont/mobile.log \| tail -1` | `lai=001-01-<votre LAC>` | `run_real.sh` |
| RACH émis | `grep -a "\[montant\] RACH" /tmp/c54x-pont/dsp.log` ; `grep -ao 'UL bursts=[0-9]* tard=[0-9]* rach=[0-9]*' /tmp/c54x-pont/pont.log` | `rach` > 0 | `run_real.sh`, `LAUNCH.md:66-67` |
| camp | `show ms` (VTY 4347) | `C3 camped normally` | `tests/modules/60-camp.sh:10` |
| LU | `grep -a "LOCATION UPDATING ACCEPT" mobile.log` ; `show ms` | `MM idle, normal service` ; IMSI dans `show subscriber cache` (VTY MSC 4254) | `run_real.sh`, `tests/modules/70-attache.sh:9-10` |
| appel | VTY 4347 : `enable`, `call 1 600` (600 = écho du banc ; votre numéro sinon) | `call control state: ACTIVE` dans `show ms` ; `call 1 hangup` | `tests/modules/_lib.sh:48,83`, `90-appel.sh:15,22` |
| A5/1 | `dsp.log` : `[montant] TCH : le firmware poste la tache 13 …` | | `LAUNCH.md:68-69` |

## Arrêt et nettoyage

Ordre inverse : pont, mobile, osmocon, gdb, QEMU, DSP, puis purge (`run.sh:210-237`) :

```bash
for n in pont mobile osmocon gdb qemu dsp; do kill "$(cat /tmp/c54x-pont/$n.pid 2>/dev/null)" 2>/dev/null; done
sleep 1
rm -f /dev/shm/calypso_api_ram /tmp/calypso_dsp.sock /tmp/osmocom_l2 /tmp/qemu-monitor-pont.sock \
      /tmp/c54x-pont/modem.pty /tmp/osmocom_sap /tmp/ms_data /dev/shm/calypso_horloge \
      /dev/shm/calypso_rach /dev/shm/calypso_sdcch_ul /dev/shm/calypso_tch_facch_ul \
      /dev/shm/calypso_tch_sacch_ul /dev/shm/calypso_tch_ul /dev/shm/calypso_tch_cfg
```

Pourquoi chaque fichier compte : un `/tmp/ms_data` resté fait échouer le bind du mobile suivant
sans le dire ; un `calypso_horloge` resté asservit le pont sur une session morte (`run.sh:218-227`).

---

## Variante : montage gr-gsm, à la main

Mêmes étapes **sans l'étape 1** et sans les trois `export` du haut (`run.sh:92-93,113`) :

- **Étape 2** : la même commande QEMU **sans** `CALYPSO_DSP_EXTERN=1` ni `CALYPSO_PONT_*` ;
  attendre `backend gr-gsm` dans qemu.log (`run.sh:146-147`) :
  `[l1] backend gr-gsm : GSMTAP udp/4730, SCH udp/4731`. QEMU écoute alors UDP 4730/4731.
- **Étape 3** : identique.
- **Étape 4** : `mobile -c <cfg>` **sans** `L23_SYNC_RETRIES_SELECTION` (`run.sh:186-189`) ; config en
  `io-tch-format rtp` (voir [Installer-grgsm_exe](Installer-grgsm_exe.md), **À CONFIRMER**).
- **Étape 5** : `cd /opt/GSM/osmo-operator && python3 pont/pont.py > /tmp/c54x-pont/pont.log 2>&1 &`
  (`run.sh:37-38,201-204` ; refuse `--dsp-port`, `pont.py:25-26`). Dans le banc complet,
  `start-direct.sh` attend qu'osmo-bts-trx soit (re)vu puis lance `setsid python3 -u pont/pont.py`
  vers `/dev/shm/pont.log`.
- Attendu côté pont : `pont TRX : ports 5700/5701/5702, ARFCN 514, BSIC 7`, puis
  `STATS fn=… | DL bursts=N`.

## Correspondance avec les scripts

| Étape | `c54x_exe/run.sh` | `qosmo/run_modules` (montage gr-gsm via start-direct.sh) |
|---|---|---|
| DSP | `etape1` `:92-106` | — |
| QEMU | `etape2` `:108-153` | `40-qemu.sh:44-89` (via lanceur `/usr/local/bin/qosmo` si présent) |
| osmocon | `etape3` `:155-170` | `50-osmocon.sh:36-42` (`-d tr` en plus) |
| mobile | `etape4` `:172-195` | `70-l2.sh:65` (`mobile -c $cfg -d $CALYPSO_MOBILE_DEBUG`) |
| pont | `etape5` `:197-208` | `start-direct.sh` bloc `CALYPSO_BRIDGE=pont` |
| BTS | — (votre réseau) | `60-bts.sh:49` |

En DSP, `start-direct.sh` joue le plan de qosmo **sans** `qemu,pty,osmocon,l2`
(`DSP_MODULES_RETIRES`, `start-direct.sh:602`) puis `exec` `c54x_exe/run.sh` : c'est exactement
étape 0 (le plan de qosmo monte le réseau et la BTS) puis étapes 1 à 5.

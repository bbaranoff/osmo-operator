# `services/` — unités systemd

Les unités du projet, rassemblées ici plutôt que dispersées entre la racine et
`scripts/`. Elles sont installées par le `Dockerfile` (image) et par `build-iso.sh`
(support bootable) ; l'installation native ne les active pas.

| Unité | Rôle |
|---|---|
| `osmo-bts-trx.service` | station de base, transceiver TRX |
| `osmo-egprs-web.service` | console web d'exploitation |
| `osmo-banc.service` | le banc GSM autonome (`start-native.sh`) ; pile dans tmux `calypso` |
| `osmo-multi.service` | le banc multi-opérateur (`start-multi.sh`) ; `Requires=osmo-banc` |
| `osmo-dsp-rom-max.service` | à la demande : le workflow « la ROM fait le maximum » (`scripts/dsp-rom-max.sh`) : profil ROM max dans `/etc/default/osmo-banc` (persistant), banc DSP, échelle `tests/banc-max.sh --dsp`, bilan ROM/hôte |
| `osmo-egprs-dsp.service` | le workflow EGPRS (`scripts/egprs-dsp.sh`) : BTS 2 virtuelle EGPRS + `osmo-pcu` + modem GPRS osmocom-bb, par-dessus le banc DSP ; `Requires=osmo-banc` |

**Ni l'une ni l'autre n'est activée au boot** (depuis le 2026-09-05 : une
machine fraîchement installée démarre sur son bureau, pas sur une pile radio
qu'on n'a pas encore configurée). Elles sont *posées* par l'ISO et par
`addition.sh` ; c'est l'opérateur qui démarre son banc — par l'icône du bureau,
par `launch.sh`, ou :

```bash
systemctl start osmo-banc         # une session
systemctl enable --now osmo-banc  # et à chaque démarrage
```

Pour graver une image qui les active quand même :
`./build-iso.sh --banc --multi` (ou `OSMO_ISO_BANC=1 OSMO_ISO_MULTI=1`), et
`OSMO_MULTI_ENABLE=1 ./addition.sh` sur une machine déjà installée.

Reprendre la main sur le banc lancé en service :

```bash
tmux attach -t calypso            # Ctrl-b d pour détacher, le banc continue
journalctl -u osmo-banc -f        # sortie de start-native.sh / run.sh
systemctl restart osmo-banc       # un banc neuf ; launch.sh (icône) fait pareil puis s'attache
systemctl start osmo-multi        # ajoute les conteneurs + inter-STP (docker requis)
```

Le DSP est le défaut (start-native.sh, 2026-10-01). Options durables : `OSMO_BANC_ARGS="--grgsm"` dans `/etc/default/osmo-banc`
(`OSMO_MULTI_ARGS` dans `/etc/default/osmo-multi`). `launch.sh --dsp` les pose
pour la session via `systemctl set-environment`. Avec `--dsp`, osmo-banc lance
aussi `c54x_exe/run.sh` après le plan du fork (hand-off par `exec`) ;
`systemctl stop` / `./start-native.sh --stop` arrêtent le banc DSP même sans
`--dsp`. Le mobile a alors sa VTY sur le port **4347**, et non 4247.

Les unités sous `contrib/systemd/` appartiennent à QEMU en amont et ne relèvent
pas de ce dossier.

Installer à la main :

```bash
sudo cp services/osmo-bts-trx.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now osmo-bts-trx
```

## `osmo-egprs-dsp` — le workflow EGPRS

`scripts/egprs-dsp.sh` monte, étape par étape, la donnée paquet sur le banc :
preflight (ROM TI 7/7, `c54x_exe`, `modem`), configs GPRS dans `/etc/osmocom`
(`configs/gprs/`, la BTS 2 re-insérée dans `osmo-bsc.cfg` après chaque
`--regen`), `osmo-banc` (chaîne DSP), l'abonné du modem au HLR, la cellule
EGPRS virtuelle (`osmo-bts-virtual` + `osmo-pcu` sur `/tmp/pcu_bts3`), puis le
modem (`virtphy` + `modem`) : GPRS attach, contexte PDP, ping vers `apn0`
depuis le netns `msgprs`. Les démons sont des unités transitoires
(`systemd-run`) : `osmo-bts-virtual-gprs`, `osmo-pcu-gprs`, `osmo-virtphy-gprs`,
`osmo-modem-gprs`.

**La porte DSP.** Le firmware `layer1` Calypso ne traite pas `L1CTL_GPRS_*`
(aucun PDCH sur l'ARM émulé, quoi que sache la ROM) : le script le détecte et
met le modem sur `virtphy`, dans la même PLMN/LAC/RA que le mobile DSP qui campe
sur la BTS 0. `EGPRS_L1=dsp` (ou `--l1 dsp`) prépare l'autre chemin — `modem` à
la place de `mobile` dans `c54x_exe/run.sh` via `MOBILE=`/`MOBILE_CFG=` dans
`/etc/default/osmo-banc` — pour le jour où le firmware l'ouvrira. La ROM
Calypso ne module qu'en GMSK : GPRS CS-1..4 au mieux sur le C54x, le 8-PSK
reste au modem virtuel.

```bash
systemctl enable --now osmo-egprs-dsp     # au boot, après osmo-banc (--dsp dans /etc/default/osmo-banc)
scripts/egprs-dsp.sh check                # preflight + configs, ne lance rien
scripts/egprs-dsp.sh status               # unités, mm-context et pdp-context du SGSN, TBF du PCU
scripts/egprs-dsp.sh stop [--all]         # la cellule et le modem (--all : le banc aussi)
journalctl -u osmo-egprs-dsp -u osmo-modem-gprs -u osmo-pcu-gprs -f
```

## `osmo-dsp-rom-max` — la ROM fait le maximum

`scripts/dsp-rom-max.sh run` pose le profil ROM max dans `/etc/default/osmo-banc`
(RACH, SDCCH/SACCH montants et bursts finaux par la ROM, A5 descendant par la
ROM, rien « en conserve »), redémarre `osmo-banc` en `--dsp`, joue l'échelle de
`/opt/GSM/tests/banc-max.sh --dsp --continue` (LU, SMS, appel, couverture) et
relit `couverture.txt` : ce que la ROM a fait, ce qui est resté à l'hôte malgré
le profil, et ce qui n'a pas encore de chemin ROM (FACCH et SACCH-en-TCH
montants, parole montante, A5 montant au fn de l'air, vocodage).
`--fw-gprs` prend le firmware `layer1.highram.gprs.elf` (PDCH, `L1CTL_GPRS_*`).
L'unité est posée mais pas activée : le profil persiste, la campagne se lance.

```bash
systemctl start osmo-dsp-rom-max          # ou : scripts/dsp-rom-max.sh run
scripts/dsp-rom-max.sh report             # relire le dernier bilan
scripts/dsp-rom-max.sh profile            # poser le profil seul
```

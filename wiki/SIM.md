# SIM : la carte du banc dans un lecteur HID Omnikey, et softSIM

Le mobile du banc (`mobile`, osmocom-bb) n'a pas de lecteur de carte : sa SIM est
soit la **SIM de test** du fichier de configuration (`sim test`, IMSI et Ki écrits
en clair, le défaut), soit une SIM **servie sur un socket** par le protocole SAP
(*SIM Access Profile*, `sim sap`). C'est ce second chemin que `start-direct.sh --sap`
monte, avec le serveur SAP de [softSIM](https://gitea.osmocom.org/sim-card/softsim)
(Ruby), qui sait servir deux choses :

| type | ce que le mobile voit | quand |
|---|---|---|
| **pcsc** | la **vraie carte** du lecteur PC/SC : une sysmoISIM-SJA5 dans un HID OMNIKEY 6121 | une carte est dans le lecteur |
| **sim** | la **SIM logicielle** `sim-op1.xml` (IMSI du MS#1, COMP128v1 avec le Ki du HLR) | pas de carte |

`--sap` choisit tout seul (pcsc si une carte est présente, sinon sim) ; `--sap=pcsc`
(`--omnikey`) et `--sap=sim` forcent. Sans `--sap`, rien ne change : SIM de test.

## 1. Installer

```bash
sudo tools/osmo-sim-install.sh        # ou : sudo ./addition.sh --sim
```

Pose, sans rien casser si c'est déjà là : `pcscd` + `libccid` (le démon PC/SC et le
pilote CCID de l'Omnikey), `pcsc-tools`/`opensc` (voir le lecteur et l'ATR), Ruby +
`ruby-libxml` + le gem `smartcard` (softSIM en lecteur), **pySim** d'Osmocom dans
`/opt/GSM/pysim-venv` (depuis son git : le « pySim » de PyPI est un autre projet),
et softSIM lui-même dans `/opt/GSM/softsim` avec les patches de `tools/softsim/`.
L'ISO fait la même chose (`iso_modules/51-softsim.sh` + `80-chroot.sh`,
`--no-softsim` pour s'en passer).

Vérifié le 2026-10-14 : OMNIKEY 6121 (USB `076b:6632`), sysmoISIM-SJA5, ATR
`3b9f96801f878031e073fe211b674a357530350265f8`, Ruby 3.2.3, gem smartcard 0.5.6, sysmo-usim-tool 190c95b.

## 2. Voir la carte

```bash
tools/osmo-sim.sh lecteur     # les lecteurs, l'ATR, le type de carte, ICCID, IMSI
tools/osmo-sim.sh lire        # tout (pySim-read) : PLMN, SMSP, ACC, services…
tools/osmo-sim.sh shell       # pySim-shell interactif (ADM1 passée si connue)
```

## 3. Programmer la carte au plan du banc

Le banc provisionne ses abonnés dans osmo-hlr avec un plan fixe
(`qosmo/run_modules/21-abonnes-hlr.sh`, `start-direct.sh` section `ms_imsi`) :

| | MS#1 de l'opérateur 1 |
|---|---|
| IMSI | `001 01 0001 000001` → `001010001000001` |
| Ki | `00112233445566778899aabbccdd` + MS + opérateur → `…dd0101` |
| algorithme | COMP128v1 (`aud2g comp128v1`) |
| MSISDN | nœud×100000 + opérateur×100 + MS → `100101` |

Pour que la carte s'enregistre, elle doit porter **exactement** cette identité :

```bash
tools/osmo-sim.sh programmer --dry-run          # montre, n'écrit rien
tools/osmo-sim.sh programmer --adm1 12345678    # écrit (demande confirmation)
tools/osmo-sim.sh programmer --ms 2 --op 1      # un autre MS du plan
tools/osmo-sim.sh verifier                      # carte = plan ? HLR ? prête pour --sap ?
```

Ce qu'il écrit passe par l'outil de sysmocom, **sysmo-usim-tool**
(`/opt/GSM/sysmo-usim-tool/sysmo-isim-tool.sja5.py`, posé par l'installeur) : IMSI,
longueur du MNC, Ki (2G/3G/4G5G), **algorithme 2G COMP128v1** (3G Milenage), OPc ;
puis il relit algorithme et Ki (`-t -k`). C'est lui qui sait poser l'algorithme :
`pySim-prog` n'écrit que le Ki et la carte resterait en Milenage, le HLR répondrait
*authentication failed*. Sans l'outil (ou `OSMO_SIM_PYSIM_PROG=1`), repli sur
`pySim-prog` (ICCID conservé, IMSI, PLMN, nom, SMSP, MSISDN, Ki) puis `pySim-shell`
pour l'octet d'algorithme `0x11` dans `DF.SYSTEM/EF.SIM_AUTH_KEY` (6f20) et
`ADF.USIM/EF.USIM_AUTH_KEY_2G` (af22).

Fait le 2026-10-14 sur la carte 8949440000001549193 : `verifier` dit « prête ».

### La clé ADM1

Écrire sur une sysmoISIM demande la clé **ADM1 de cette carte** (8 chiffres), que
sysmocom fournit avec la carte (fichier de données de la commande). **Trois essais
faux bloquent la carte pour de bon** : le script ne devine jamais, il refuse sans
clé. Où la mettre, dans l'ordre où elle est cherchée :

1. `--adm1 K` sur la ligne de commande ;
2. `OSMO_SIM_ADM1=K` dans l'environnement ;
3. `/etc/osmocom/sim-adm1` (`chmod 600`) : une ligne, ou `ICCID clé` par ligne
   pour plusieurs cartes ;
4. `~/.config/osmo/sim-adm1`.

### Une carte qu'on ne veut pas reprogrammer

Elle garde son IMSI et son Ki : il faut alors les déclarer au HLR.

```bash
tools/osmo-sim.sh hlr --creer --ki <Ki de la carte>     # abonné créé par le VTY (4258)
```

(`hlr` sans `--creer` dit seulement si le HLR connaît l'IMSI lu sur la carte.)

## 4. Lancer

```bash
./start-direct.sh --sap            # carte présente → pcsc ; sinon SIM logicielle
./start-direct.sh --sap=pcsc       # la carte, obligatoirement
./start-direct.sh --dry-run --sap  # ce qui serait fait, sans rien lancer
```

`start_sap` tourne **avant** la pile : il lance `demo_server.rb` (softSIM) sur
`/tmp/osmocom_sap` (`SAP_SOCK`), journal `/tmp/osmo-sap.log` (`SAP_LOG`,
`SAP_VERBOSITY=3` : connexion, carte prête, chaque APDU horodatée), et le mobile
s'y connecte au démarrage. Le serveur sert le client suivant après une déconnexion
(patch `0002`) : un redémarrage de la baseband ne demande rien.

En mode DSP (le défaut), le MS#1 qui tourne est celui de c54x_exe
(`mobile_pont.cfg`, `sim test`) : `--sap` en dérive
`/root/.osmocom/bb/mobile_pont_sap.cfg` (`sim sap`, `sap-socket`) et le passe au
banc par `MOBILE_CFG`. En mode grgsm, c'est `mobile.cfg` généré depuis
`configs/mobile.cfg` (`sim sap` dans le gabarit, remis en `sim test` sans `--sap`)
qui le porte ; le MS#2 reste en SIM de test.

`./start-direct.sh --stop` arrête aussi le serveur SAP ; un démarrage le relance
toujours à neuf (il est tué avec le reste dans « Arrêt de la pile avant démarrage »).

Servir la carte à la main, sans la pile (pour voir les APDU) :

```bash
tools/osmo-sim.sh sap              # premier plan, Ctrl-C pour arrêter
```

## 5. Ce que les patches corrigent

| fichier | quoi |
|---|---|
| `tools/softsim/0001-simos-comp128v1-a38.patch` | SIM logicielle : COMP128v1 avec `SOFTSIM_KI` (n'importe quel RAND du HLR), READ RECORD, `--file` transmis, boucle d'acceptation |
| `tools/softsim/0002-sap-serve-next-client.patch` | le serveur sert le client suivant au lieu de sortir |
| `tools/softsim/0003-sap-log-timestamps.patch` | APDU nommées et horodatées (ms) dans le journal |
| `tools/softsim/0004-pcsc-disconnect-idempotent.patch` | mode pcsc : `disconnect` appelé deux fois par client (DISCONNECT_REQ puis fermeture du socket) plantait le serveur sur un handle nul, le mobile ne pouvait plus se reconnecter |
| `tools/softsim/ruby_compat.rb` | Ruby ≥ 3.2 : `File.exists?`, `Fixnum` |
| `tools/softsim/make_sim_op1.py` | `sim-op1.xml` : IMSI, ICCID valide, PLMN, SPN depuis le `sim.xml` de démonstration |
| `patches/osmocom-bb-plmn-a6-reinsert.patch` | mobile : SIM réinsérée sans RPLMN (reconnexion SAP), la recherche de PLMN finissait « unhandled » |
| `patches/osmocom-bb-sim-plmn-from-bcd.patch` | mobile : PLMNsel/FPLMN de la SIM lus avec la bonne fonction (000-00 avant) |

Les deux patches osmocom-bb sont appliqués par `install_modules/40-patches.sh`
(natif) et le `Dockerfile` ; `mobile` doit être recompilé après.

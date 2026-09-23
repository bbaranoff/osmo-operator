# Etat des lieux et reste a faire

Derniere mise a jour : 2026-09-23 (HEAD `00e6502`). Les sections 1 a 3 (SS7,
numerotation) sont inchangees depuis le 2026-08-26 (lab alors a l'arret,
conteneurs `Exited (127)`), sauf le point 4 des bloquants. Nouvelle section 0
pour le banc radio.

## 0. Banc radio — etat au 2026-09-23

| montage | etat |
|---|---|
| grgsm (defaut) | montage de reference (L1 gr-gsm dans QEMU) ; etat du TCH : `pont/README.md` |
| `--dsp` (c54x_exe) | FB/SB/BCCH decodes par la mask-ROM, camp SI1-4 lai=001-01-1, LU ACCEPT (MSC `timer geran X1 30`, 23/09) ; A5 descendant par le coprocesseur XIO modelise ; appels TCH **en validation** |

`--dsp` a change de nature entre le 22 et le 23/09 : il ne choisit plus de fork.
Le fork monte toute la pile en profil hybride avec
`--skip qemu,pty,osmocon,l2 --no-attach`, puis `exec c54x_exe/run.sh` lance les
cinq etapes du banc DSP : `c54x_exe --arm`, QEMU `/opt/GSM/qosmo`, osmocon, le
mobile (`mobile_pont.cfg`, VTY 4347) et `pont/pont_dsp.py`.

Le pont a deux points d'entree : `pont.py` (grgsm) et `pont_dsp.py`
(`pont.dsp.main`). `pont_uncipher.py` a ete ajoute puis retire le meme jour. En
DSP, le pont ne dechiffre le DL que si `PONT_DSP_DECHIFFRE=1` ; le TCH n'est plus
qu'une annonce, le BSP suit la tache du firmware ; l'horloge est asservie en
boucle fermee (`PONT_MARGE_DL` 16, `PONT_AVANCE_MIN` 10). Detail :
`pont/README.md` § 0 et § 8.

Appels TCH en `--dsp` : bascule suivie par la tache firmware ; crash SP
(`RPT *(lk)`, `c54x_exec.c`) et pointeur SACCH `0x3d89` (MVKD/MVDK, garde
`[garde-3d89]` dans `c54x_mem.c`) corriges dans le coeur C54x
(`qosmo/hw/arm/calypso/l1-dsp`, compile dans c54x_exe),
**a confirmer sur le banc** ; UA perdu / SABM repetes corriges dans
`pont/dsp/clock.py` apres le releve de 19:06, **pas encore revalides**.

Audio : PulseAudio allege a chaque start ; le passage a speex a ete annule,
webrtc reste le defaut, `AUDIO_PENDANT_APPEL` vaut 0.

Incoherences du code, hors doc, non corrigees :

- l'en-tete de `globals.conf` dit encore qu'il ecrase l'environnement ;
- le commentaire d'`audio_start` dans `start-direct.sh` et celui de
  `lib/audio.sh:239` (« SPEEX PAR DEFAUT ») annoncent speex, alors que
  `lib/audio.sh:131` pose `AUDIO_AEC_METHOD:=webrtc` ;
- `INSNS` vaut 120000 dans `start-direct.sh`, son bloc de commentaires dit
  200000, le defaut de `c54x_exe/run.sh` est 80000 (son en-tete dit 200000).

A faire :

- [ ] rejouer un appel en `--dsp` : lire « marge DL reelle » dans `pont.log`
      (moyenne >= ~10) et « [garde-3d89] » dans `dsp.log` (attendu : aucune) ;
- [ ] aligner `INSNS` entre `start-direct.sh` (120000) et `c54x_exe/run.sh` (80000).

## 1. Ce qui est fait et verifie

### Correctifs du depot

| Fichier | Correctif | Verifie |
|---|---|---|
| `start.sh` | `asound.conf` : Docker avait cree un REPERTOIRE a la place du fichier, le mount echouait (`not a directory`). Le repertoire parasite est supprime avant la copie, la copie est verifiee, sinon repli propre sur `ALSA_*=default`. | oui, `bash -n` + repertoire nettoye |
| `start.sh` | `--hub-ip` et `--node-per-op` posent `WAN_MESH=1` : sans cela le plan de point codes retombait sur le plan LOCAL (1.1.2 / 1.2.2, rctx 150 / 250), identique sur chaque machine du WAN. | syntaxe ; **a rejouer sur le lab** |
| `start.sh` | le rang d'operateur passe a `start-direct.sh` (`--op N`) au lieu de `--op 1` fige : `set-node-id.sh` reecrivait les configs de l'operateur 2 avec l'identite de l'operateur 1. | syntaxe ; **a rejouer** |
| `start.sh` | garde-fou : `--node-per-op` refuse un numero de noeud hors de 1..9 avec un message qui dit quoi faire. | syntaxe ; **a rejouer** |
| `checks/_mode.sh` | decouverte du hub distant (env des conteneurs puis `osmo-stp.cfg`), point codes libres au format ITU 3-8-3, sonde d'association SCTP. | oui, sur le lab |
| `checks/ss7_check.sh` | mode WAN : « Container absent » remplace par « hub distant + lien M3UA/SCTP », matrice de connectivite reactivee, route par defaut enfin verifiee. | oui : 19 pass, 0 warn |
| `checks/wan_ss7_check.sh` | le hub parle SCTP : la sonde `nc -z 2908` (TCP) rendait « injoignable » sur un lien parfait. Remplacee par l'association SCTP reelle. `HUB_IP` lu dans les conteneurs. | oui : 25 ok, 0 echec |
| `checks/operator_summary.sh` | section « hub distant » quand il ne figure pas dans le dump. | oui |

### Console SS7 (`navigation/`)

14 modules, ~4300 lignes de Python, sans dependance. Schema navigable aux
fleches, VTY par noeud (Echap ferme la session), ASP M3UA reel sur le hub,
operations MAP, repondeur, diagnostic, tests.

Verifie sur le lab en marche :

- schema rendu et navigation spatiale (pilotage sous pty) ;
- VTY OsmoBSC ouvert, commande envoyee, sortie reelle, Echap ferme ;
- ASP M3UA : ASPUP / RKM / ASPAC -> `ASP_ACTIVE` sur `192.168.1.49:2908` ;
- DAUD : `DAVA` sur les 6 point codes du lab, `DUNA` sur un PC inexistant ;
- aller-retour MAP complet : `sendRoutingInfoForSM 600101` -> `IMSI
  001010001000001`, a travers le hub ;
- `ss7-diag.py` : 25 ok ;
- `test-console.sh` : 10 tests passes avec le lab a l'arret (3 ignores), un
  journal par commande.

### Ce que le lab nous a appris (garde dans le code, avec le pourquoi)

- le hub REFUSE le parametre « Service Indicators » d'une routing key ;
- il faut PROPOSER son routing context, sinon deux ASP recoivent le meme et,
  en `traffic-mode override`, le dernier vole le trafic du premier ;
- le DATA doit partir sur le flux SCTP 1 (le 0 est reserve a la gestion) ;
- une association venue de l'HOTE n'est servie que ~3 s, puis expire vers 35 s :
  la console renouvelle son lien avant chaque echange.

## 2. Ce que l'audit de la numerotation a trouve

Quatre cartographies (point codes, abonnes, indicatifs WAN, identifiants
reseau) confrontees aux sources. **12 problemes bloquants**, dont 3 corriges
ci-dessus. Les 9 autres, par ordre d'urgence :

### Bloquants, non corriges

1. **Le MSISDN n'encode aucun noeud** — `600000 + op*100 + rang`, et le Ki n'en
   depend pas non plus. Deux noeuds portent le meme `600101` avec le meme Ki ;
   seul l'IMSI (via le MCC) les separe. Des qu'un chemin oublie de prefixer
   l'indicatif, il tombe sur l'homonyme local. `start.sh:1436-1437`.
2. **ISO : meme IMSI, meme MSISDN, meme Ki sur tous les noeuds** — `build-iso.sh`
   fige `MCC=001 MNC=01 op_id=1`, ce qui contredit `op_mcc() = noeud`.
   `build-iso.sh:289-290,369-373`.
3. **`--node-per-op` : l'operateur 2 d'un noeud distant est injoignable** — ses
   MSISDN sont `600201` mais le maillage ne genere que `_<ind>6001XX`.
   `network/setup-wan-mesh.sh:602,763` vs `start.sh:1678`.
4. ~~**`globals.conf` ecrase l'environnement**~~ — **corrige cote
   `start-direct.sh` le 2026-09-22** : les variables posees non vides par
   l'appelant sont reposees apres la lecture de `globals.conf`, qui n'a pas ete
   modifie. Reste : l'en-tete de `globals.conf` dit toujours « ecrasent leur
   homonyme », et `generate_configs.sh` n'est pas concerne.
   `start-direct.sh:457-490`, `globals.conf:8-11`.
5. **ARFCN / BSIC / LAC / CI ne dependent que de l'operateur** — deux noeuds
   diffusent `ARFCN 514 / BSIC 7 / LAC 0x0001 / CI 6001`. `generate_configs.sh:287-306`.
6. **Le garde-fou `_gc_warn_perop` ne tourne jamais** sur le chemin reel (mode
   source) et teste `N_OPERATORS`, que `start.sh` ne lit nulle part.
7. **La plage RTP du MGW (4002-16001) recouvre tous les ports de service** du
   conteneur, VTY compris. `configs/osmo-mgw.cfg:70-71`.
8. **`node_nops` : repli mort** — `WAN_NOPS[id]=1` est toujours pose, donc un
   pair est toujours vu a 1 operateur. `network/wan-nodes.sh:109-120`.
9. **La grille d'AS du hub est indexee par RANG, pas par numero de noeud** — une
   table `1: 3: 5:` produit `as-n1 as-n2 as-n3`. `helpers/create_interop.sh:118-130`.

### Serieux, notables

- trois replis divergents pour MCC/MNC (`start-direct.sh`, `run_modules/21`,
  `scripts/sms-routing-setup.sh`) ;
- seules 2 routes SMS locales generees quel que soit `OP_MS` ;
- `checks/diag-stp-operator.sh` et `wan_ss7_check.sh` figent l'operateur a 1 ;
- deux identites de noeud pour la meme machine en `--node-per-op` ;
- aucun routage par global title (tout est en PC/SSN 254).

## 3. Reste a faire

### Priorite 1 — rejouer ce qui est corrige

- [ ] relancer le lab et verifier les 3 correctifs `start.sh` :
      `sudo ./start.sh --wan --operators 2 --hub-ip 192.168.1.49`
      puis `./navigation/ss7-diag.py` (attendu : 2 PC distincts par operateur,
      rctx distincts, aucun `DUNA` sur les PC du lab) ;
- [ ] `./navigation/test-console.sh` lab en marche (les 3 sections ignorees
      doivent passer).

### Priorite 2 — numerotation

- [ ] trancher le plan MSISDN : y encoder le noeud, ou assumer que l'indicatif
      est le seul discriminant et verifier CHAQUE chemin qui le retire ;
- [ ] `build-iso.sh` : deriver MCC/MNC/op_id du `--node`, comme `start.sh` ;
- [ ] `generate_configs.sh` : indexer ARFCN / BSIC / LAC / CI par noeud ;
- [x] `globals.conf` : l'environnement non vide gagne, cote `start-direct.sh`
      (2026-09-22) ;
- [ ] corriger l'en-tete de `globals.conf`, qui dit encore l'inverse ;
- [ ] `network/wan-nodes.sh` : ne poser `WAN_NOPS` que si le champ existe.

### Priorite 3 — outillage

- [ ] `checks/diag-stp-operator.sh` : ne plus figer l'operateur 1 ;
- [ ] console : bornes du repondeur (plusieurs operateurs, choix du SSN) ;
- [ ] console : rejouer un script exporte (`navigation/scripts/`) depuis le
      schema.

## 4. Points d'attention

- `navigation/` appartient a `nirvana:nirvana` ; `start.sh` reste `root:root`
  comme avant.
- Sauvegardes : `start.sh.bak.20260826-221924` (asound) et
  `start.sh.bak.*-numerotation` (les 3 correctifs), `checks/*.bak`.
- L'audit complet (phase 2 et 3 du workflow) n'a pas ete rejoue : seules les
  quatre cartographies ont abouti. Leurs conclusions sont resumees ici.

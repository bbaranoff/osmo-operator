# Etat des lieux et reste a faire

Derniere mise a jour : 2026-09-23 (HEAD `226203d`, runs du banc DSP de 20:22
et 20:32). Les sections 1 a 3 (SS7, numerotation) sont inchangees depuis le
2026-08-26 (lab alors a l'arret, conteneurs `Exited (127)`), sauf le point 4
des bloquants. Nouvelle section 0 pour le banc radio.

## 0. Banc radio — etat au 2026-09-23

| montage | etat |
|---|---|
| grgsm (defaut) | montage de reference (L1 gr-gsm dans QEMU) ; etat du TCH : `pont/README.md` |
| `--dsp` (c54x_exe) | FB/SB/BCCH decodes par la mask-ROM, camp SI1-4 lai=001-01-1, LU ACCEPT (MSC `timer geran X1 30`, 23/09) ; A5 descendant par le coprocesseur XIO modelise ; appels TCH aboutis (echo 600, mobile a mobile) et SMS MO/MT le 23/09 20:22, voir ci-dessous ; B_BFI sur toutes les trames de parole |

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
(`qosmo/hw/arm/calypso/l1-dsp`, compile dans c54x_exe) : **confirme au run
de 20:22** (deux appels complets sans LOS, aucune ligne `[garde-3d89]` dans
`dsp.log`), **mais un LOS sur le premier appel du run de 20:32** (ci-dessous) ;
UA perdu / SABM repetes corriges dans `pont/dsp/clock.py` apres le releve de
19:06 : **confirme au run de 20:22** (aucun « SABM frame with information not
allowed » au BSC, marge DL reelle moyenne +22.3 a +38.9).

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

- [x] rejouer un appel en `--dsp` : fait le 23/09 20:22 et 20:32, marge DL
      reelle moyenne >= 22 sur les deux runs, aucune ligne `[garde-3d89]` ;
- [ ] trancher B_BFI : comparer bit a bit les 33 octets livres par la ROM aux
      trames emises par la BTS (RTP du MGW ou decodage du pont) ;
- [ ] LOS du 20:32:45 : SACCH du TCH perdu en entier pendant 15 s ;
- [ ] SACCH/8 : `fn % 102` des blocs jetes contre ceux acceptes ;
- [ ] aligner `INSNS` entre `start-direct.sh` (120000) et `c54x_exe/run.sh` (80000).

### Runs du banc DSP du 2026-09-23, 20:22 et 20:32

Mobile du pont (DSP) = MS 1, IMSI 001010001000001, MSISDN 100101 ; l'autre
mobile = 100102. Journaux : `osmo-*.log` (run 20:22 seulement, 20:22:09 a
20:24:56), archives du pont `20260923-202448` et `20260923-203413`.

Ce qui marche (constate) :

- LU du mobile DSP 20:22:41 -> 20:22:45, liberation propre 20:22:47 ;
- appel MO 100101 -> 600 (echo Asterisk) : ASSIGNMENT COMPLETE 20:22:54 sur
  TCH/F TN=2, ACTIVE 20:22:55, DISCONNECT 20:23:27 (osmo-sip-connector :
  `NORM_CALL_CLEAR`). Pont : TCH dl=1607 ul=1601 trames, perdus=11. Parole
  audible dans les deux sens (GAPK FR sur l'hote, decodage canal TCH/F
  descendant par la mask-ROM) ;
- appel mobile a mobile 100102 -> 100101 via osmo-sip-connector : paging
  20:24:20, ASSIGNMENT COMPLETE 20:24:25, ACTIVE 20:24:28, release normal
  20:24:32 ;
- SMS MO 100102 -> MT 100101 (20:23:49-55) et MO 100101 -> MT 100102
  (20:24:05-09), CP-ACK et RP-ACK recus par le MSC ;
- A5/1 sur les **cinq** etablissements du mobile DSP (`pont.log` « chiffrement
  descendant confirme » a 20:22:45, 20:22:53, 20:23:53, 20:24:04, 20:24:24 :
  LU, appel 600, SMS MT, SMS MO, appel MT) ;
- BSP dedie : `stockes=1751 joues=1752 manques=0 perdues=0` (20:22) ;
  `stockes=6298 joues=6293 manques=0 perdues=0` (20:32) ;
- temps reel : 29513 trames sur la session 20:22 ;
- run 20:32 : second appel ACTIVE 20:33:39 -> DISCONNECT 20:34:06, propre.

Anomalies ouvertes, par ordre d'importance :

1. **B_BFI sur toutes les trames de parole** (le point qui borne les claims).
   20:22 : les 40 etats `a_dd` echantillonnes (21 x c214, 18 x c204,
   1 x 8084) ont le bit 2 = B_BFI. 20:32, sonde etendue : `vues=2200
   bfi=2200` ; sur les 42 releves, `err` (a_dd_0[2], erreurs rapportees par la
   ROM) vaut 0 sur les 19 x c214 du debut d'appel, 15 a 93 sur les 23
   autres. Les trames sont
   donc reellement degradees et le FR reste intelligible (le firmware ne
   remonte pas le BFI). Signal (BSP, IQ, egalisation) ou coeur C54x (Viterbi,
   recodage) : non tranche. Qualite de la parole **non mesuree**.
2. **LOS a 20:32:45 sur le premier appel du run 20:32** : ACTIVE 20:32:30,
   puis 408 blocs jetes de 20:32:30 a 20:32:45 (54 a 111 bit errors), dont
   32 SACCH : `LOSS counter for ACCH` 31 -> 0 jusqu'au « LOS during dedicated
   mode ». Le SACCH du TCH est perdu en entier ; l'appel suivant (20:33:39) n'en perd presque aucun. Cause non
   trouvee.
3. **SACCH descendant du SDCCH/8** : 30 blocs jetes par le mobile sur le run
   20:22, dont 18 SACCH (« LOSS counter for ACCH », 15 hors TCH) ; LU : 5
   SACCH jetes sur ~10 en 5 s, ~la moitie. Suspect : la table 45.002 du BSP
   pour le SACCH/8 (alternance sur deux multitrames de 51).
4. **UI SAPI 0 sur le TCH** : BSC 20:22:54, lchan(0-0-2-TCH_F-0)
   {WAIT_RLL_RTP_ESTABLISH} « SAPI=0 UNIT DATA INDICATION: unimplemented
   Abis RLL message ». UI avec charge (une UI de longueur 0 serait jetee par
   libosmocore). Non localisee, non bloquante.
5. **Horloge du pont** : avance visee au plafond de 40 a 20:22:37, 20:22:56,
   20:32:06, 20:32:40, 20:33:45 (avance BTS mesuree -25 a -29) ; marge DL
   reelle min +0 a la premiere mesure de chaque run, +6 puis +4 juste apres le
   LOS de 20:32:45. Moyenne 22 a 39 ailleurs, pas de perte associee.
6. Mineures : `MM_EVENT_NO_CELL_FOUND` x2 a 20:24:08 (resynchronisation apres
   le SMS sortant) ; MSC 20:24:26 « Duplicate DTAP » sur la reponse au paging.

Pas des anomalies :

- les echecs CRC du **moniteur TCH descendant du pont** (appel 600 : 30 sur
  les 32 premieres trames, 40 -> 45 en conversation, 103 a la fin) : la BTS
  n'a rien a mettre sur le TCH tant que le RTP ne coule pas ; decodage du
  pont, independant du DSP ;
- le `ko=376` de la sonde `[a_dd]` (B_FIRE1) : sans sens defini sur la parole ;
- la fin du run 20:22 a 20:24:52 : arret volontaire (« SIGINT received » de la BTS, rapporte
  au BSC).

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

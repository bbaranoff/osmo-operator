# Chiffrement A5, Kc et SACCH — ce qui a été mesuré, et pourquoi c'est écrit ainsi

Ce document est un **compte rendu de mesure**, pas une présentation. Il existe
parce que chacune des pannes ci-dessous s'est présentée comme « le pont a des
CRC » — un compteur global qui ne distingue rien — et qu'il a fallu à chaque
fois remonter d'un symptôme identique à des causes sans rapport entre elles.

Tout ce qui est chiffré ici vient des journaux du banc. Les hypothèses écartées
sont conservées : elles étaient plausibles, et les réécarter coûte moins cher que
les redécouvrir.

---

## 1. Le Kc — trois écrivains, aucun arbitrage

### Le symptôme

`/dev/shm/calypso_kc` à 32 zéros. `A5=non` sur la totalité du canal dédié.
`SOUS-VOIE ACTIVE : clair 50/277  chiffre 0/96` — **zéro** bloc chiffré décodé
sur 96. Tout ce qui suit le CIPHERING MODE COMMAND rate le CRC, SDCCH puis TCH
(qui conserve le chiffrement après l'ASSIGNMENT COMMAND). D'où des CRC qui
n'apparaissent qu'au deuxième appel : le premier passe en clair, le second
trouve un réseau qui chiffre.

### La cause

Trois producteurs écrivaient le même fichier, sans le moindre arbitrage :

| # | écrivain | état |
|---|---|---|
| 1 | `osmocon` | hors dépôt, **efface** le fichier sur `DM_EST_REQ` |
| 2 | `l1ctl_sock.c` (QEMU) | chemin mort — le socket l1ctl est orphelin, le mobile parle à osmocon |
| 3 | `calypso_dsp_shunt.c` | **n'existait pas** |

Le troisième est le point clé. `pont.py` documentait `shunt_publish_kc` depuis le
27/08 et avait mis `PONT_KC_RETENTION=0` *sur la foi de son existence*. Or
`grep shunt_publish_kc` ne rendait rien dans tout `qosmo-grgsm`. On avait donc
coupé le dernier filet en se fiant à un producteur imaginaire.

Le dernier qui écrit gagne — et c'est l'effaceur.

### Pourquoi osmocon effaçait

osmocon est le multiplexeur série entre le mobile et le firmware. Il
**espionnait** `L1CTL_CRYPTO_REQ` au passage et en profitait pour publier la clé.
C'était la seule façon de la sortir à l'époque.

Mais un espion voit passer la clé, pas sa fin de vie : il doit la **deviner**. Il
la devinait sur `DM_EST_REQ` et `DM_REL_REQ`. L'intention est juste pour le
RELEASE, **fausse pour l'ESTABLISH** : le mobile émet aussi un `DM_EST_REQ` pour
ouvrir un lien *supplémentaire* sur un canal **déjà chiffré** (le SAPI 3 du SMS,
un ré-établissement LAPDm). La clé disparaissait en pleine session.

### Le correctif

Un format commun ne règle pas une course — c'était l'erreur de la première passe.
Il faut séparer les **autorités** :

* **La source autoritaire a son propre fichier.** `calypso_dsp_shunt.c` publie
  `/dev/shm/calypso_kc_l1` depuis `d_a5mode` et `a_kc[4]` du NDB, c'est-à-dire ce
  que le **firmware** a réellement chargé dans le DSP
  (`calypso/dsp.c:dsp_load_ciph_param`). Aucun autre écrivain ne connaît ce
  chemin. La course disparaît au lieu d'être arbitrée.
* **Le patch osmocon est retiré** du `Dockerfile`, désappliqué, et osmocon
  reconstruit. Il n'écrit plus rien. Le patch reste dans `patches/` à titre
  documentaire.
* `pont.py` lit `calypso_kc_l1` en priorité et ne retombe sur l'historique que
  s'il est absent — **jamais un mélange des deux**, sous peine de réintroduire la
  course.

### Les offsets NDB ne se devinent pas

`d_a5mode` et `a_kc` sont résolus **du DWARF du firmware vivant**, via
`tools/ndb-offsets.py`, comme les six autres champs. Valeurs au 2026-08-30 :
`d_a5mode=0x1ce`, `a_kc=0x2ce`.

C'est ici que le repli par `#define` est le plus dangereux : un offset faux ne
produit pas d'erreur, il produit une **clé fausse**. `osmo_a5` accepte n'importe
quels 8 octets et rend un keystream. Le trafic se « déchiffre » alors en bruit,
et le CRC accuse la radio.

Même piège sur l'ordre des octets : le firmware range la clé **à l'envers, et par
mots** — `a_kc[0] = key[7] | key[6]<<8` … `a_kc[3] = key[1] | key[0]<<8`. Il faut
défaire les **deux** inversions.

### Preuve de fonctionnement

```
KC : couche 1 EN CLAIR (d_a5mode=0, seq=1)
KC : A5/1 actif, Kc=29365ddd5623c400 (NDB d_a5mode@0x1ce a_kc@0x2ce, seq=2)
KC : couche 1 EN CLAIR (d_a5mode=0, seq=3)
KC : A5/1 actif, Kc=29365ddd5623c400 (seq=4)   …
```

Côté pont : `clair 21/21`, `chiffre 62/69`.

---

## 2. La rétention du Kc — trois marqueurs faux, puis le bon critère

Quatre tentatives, dont **trois miennes ou héritées, et fausses**. Elles sont
listées parce que chacune paraît raisonnable jusqu'à la mesure qui la tue.

| marqueur de relâchement | pourquoi c'est faux |
|---|---|
| `seq` de `calypso_dcch_cfg` | ne bouge pas du LU à l'appel (`chan_nr` reste 0x41) → clé retenue **indéfiniment**, A5 appliqué à un canal qui démarre en clair → UA brouillée, T200 ×6, appel mort |
| SABM montante | une SABM ne veut **pas** dire « on repart en clair » : un ré-établissement LAPDm sur canal chiffré en est une, le SAPI 3 du SMS aussi. Mesuré : 11 lâchers en pleine session |
| `algo=0` d'un producteur autoritaire | `d_a5mode` décrit **notre** L1, pas le **réseau**. Le firmware appelle `dsp_load_ciph_param(0, NULL)` à chaque resynchronisation (`sync.c:419`), donc **pendant** la bascule SDCCH→TCH. Lâcher là, c'est cesser de déchiffrer l'ASSIGNMENT COMMAND elle-même |

Le troisième est instructif : il a produit, en une ligne de journal chacun, la
cause **et** l'effet.

```
Kc LACHE (la couche 1 declare le clair (seq=7))
TCH arme TN=2 depuis 5 s SANS ASSIGNMENT COMPLETE : le mobile n'a pas bascule
```

Le DSP étant shunté, **c'est le pont qui déchiffre pour le firmware**. Le mobile
ne recevait donc jamais l'ordre de basculer.

### La règle retenue

> La fin de vie d'une clé est un **événement réseau**, pas un état local.

Les trois marqueurs conservés le sont tous : `IMMEDIATE ASSIGNMENT` (seul octroi
d'un canal **neuf**, qui démarre toujours en clair), `CHANNEL RELEASE` sur SDCCH,
`CHANNEL RELEASE` sur FACCH. La rétention (`PONT_KC_RETENTION`, défaut `1`) ne
compense plus l'effaceur d'osmocon — il n'existe plus — mais la fenêtre pendant
laquelle notre L1 est en clair alors que le réseau chiffre encore.

---

## 3. `unsupported SAPI` — deux diagnostics faux, un vrai défaut trouvé en chemin

### Le symptôme

Côté mobile, en boucle :

```
DLLAPD lapdm.c Received frame for unsupported SAPI 6!
DRR    gsm48_rr.c:4390 Radio link is released
DMNCC  mnccms.c:714    Call has been released (cause 16)
```

SAPI 6 n'existe pas en LAPDm (0 = signalisation, 3 = SMS).

### Une fausse piste, gardée parce qu'elle était convaincante

Première explication : l'en-tête L1 du SACCH (2 octets) ne serait pas retiré, et
LAPDm lirait l'octet de **puissance ordonnée** comme octet d'adresse. Le
comptage collait parfaitement — 33 SAPI invalides pour exactement 33 blocs SACCH
tentés (`TS1/32 : 30/33`), et les quatre valeurs observées se rangeaient dans les
paliers de puissance.

**C'était faux.** Le tampon réellement présenté commence par `07` :
`(0x07 >> 2) & 7` = **SAPI 1** — une valeur jamais observée. Une corrélation de
comptage n'est pas une preuve tant que l'arithmétique du mécanisme ne suit pas.

Vérifié au passage, et négatif aussi : la table `mf_sdcch8_0` du firmware est
conforme au 05.02 (`MF_F_SACCH` bien posé à `fn%102 ∈ [32,35]`), et
`prim_rx_nb.c:122` en tire correctement `link_id = 0x40`. **Aucun patch firmware
n'était nécessaire** — c'est précisément ce que la mesure a évité.

### Deuxième explication : le SI du camp — réfutée elle aussi

`lapdm_rx_ph_data_ind` calcule `sapi = (l2h[0] >> 2) & 7`. Les valeurs observées
correspondent à des premiers octets dans `0x08–0x1B`, soit la forme d'un **octet
de pseudo-longueur** de bloc BCCH — `(L << 2) | 1`, donc `SAPI = L & 7` :

| SI | L | 1er octet | `L & 7` | SAPI observé |
|---|---|---|---|---|
| SI1 / SI2 | 21 | `0x55` | 5 | 5 (×2) |
| SI3 | 18 | `0x49` | 2 | 2 (×2) |
| SI4 | 12 | `0x31` | 4 | 4 (×1) |
| — | 22 | `0x59` | 6 | 6 (×28) |

Ce ne sont pas des blocs SACCH : ce sont les **SI du camp**, injectés dans `a_cd`
pendant le canal dédié. Le rapport de forces, mesuré :

| écrivain de `a_cd` | occurrences |
|---|---|
| `DCCH-SACCH #` (présentation légitime) | **3** |
| `DISPATCH ALLC → SI3 a_cd[3..14]` | **29 483** |

`DCCH-GARDE` doit empêcher exactement cela. Elle s'armait bien, mais se levait
sur un **TTL de fraîcheur de blocs** (`dcch_guard_tick`, ~2 s) rafraîchi
uniquement par le **descendant** — donc par notre chance de décodage. Trois blocs
sur tout le run : entre deux, le TTL expirait, la garde concluait « canal fini »,
et le camp reprenait `a_cd`.

```
DCCH-GARDE : ARMEE  -- SI du camp supprime dans a_cd
DCCH-GARDE : levee (peremption) -- SI du camp retabli     ← ×4, canal bien vivant
```

C'est **la même erreur de raisonnement** qu'aux §1 et §2 : déduire un événement de
cycle de vie (« le canal est fini ») d'un symptôme local (« je n'ai rien décodé
depuis 2 s »). Sur un banc où le décodage est imparfait, les deux sont confondus
en permanence, et la garde se retourne contre le canal qu'elle protège.

### Le correctif — et ce qu'il a prouvé, ce qu'il n'a pas prouvé

La garde est rafraîchie par le **montant dédié** (`d_task_u` ∈ {12 DUL, 13 TCHT,
14 TCHA}) : le mobile qui émet sur son canal dédié prouve que ce canal existe,
indépendamment de notre décodage.

**Mesuré, et le correctif fait ce qu'il annonce** — sonde du site de présentation
(`CAMP: a_cd<-SI`), et non celle du point d'injection, qui continue d'imprimer en
amont de la garde :

| | avant | après |
|---|---|---|
| `CAMP: a_cd<-SI` pendant le dédié | flot continu | **0** |
| `levee (peremption)` | ×4 | **0** |

**Mais les SAPI invalides ont AUGMENTÉ : 33 → 52.** Le SI du camp n'était donc
pas leur source. La cause reste **inconnue** — c'est le deuxième diagnostic faux
sur ce même symptôme, après celui des paliers de puissance. Le correctif de la
garde est conservé parce qu'il corrige un défaut réel et démontré ; il ne corrige
simplement pas celui-là.

### Entretenir n'est pas armer

La première version **armait** la garde depuis le montant. `task_u` vaut 12/13/14
bien au-delà du canal dédié (621 / 1954 / 81 sur le run) : la garde s'est armée à
6 % du journal et n'a **jamais** été levée — `CAMP: a_cd<-SI` = 0 sur les 94 %
restants, et 27 lignes de sélection de cellule côté mobile. C'est trait pour trait
la famine de SI que ce TTL existait pour éviter (commentaire du 2026-08-12), et
qu'on réintroduisait en croyant la contourner.

Corrigé : l'**armement** reste au descendant (`set_dcch_active`), seul signal lié
à un bloc dédié réel ; le montant ne fait que **repousser la péremption** d'une
garde déjà armée. Le TTL reste court (~2 s) — c'est lui qui rend le camp au mobile
dès la fin du canal, et l'allonger l'affame. Le montant couvre les trous *pendant*
le canal ; le TTL tranche *après*.

## 3bis. Identité n'est pas instance — la cause du 2ᵉ appel

### La mesure

Un LU suivi de **deux appels**, tous trois sur SDCCH/8 SS0 :

```
DCCH #1 : chan_nr=0x41 -> SDCCH/8 SS=0 TN=1 (vu sur DATA_IND)     ← et c'est tout
/dev/shm/calypso_dcch_cfg : seq=1
```

**Trois canaux dédiés successifs, un seul appris.**

### La cause

```c
/* l1ctl_sock.c */
if (kind >= 0 && chan_nr != last_chan_nr) {
    dcch_seq++;
    ... écrit /dev/shm/calypso_dcch_cfg ...
    calypso_dsp_shunt_set_dcch(kind, ss);
}
```

La mise à jour ne se déclenche que si `chan_nr` **change**. Or le BSC réalloue
volontiers la même sous-voie : un second appel qui retombe sur SDCCH/8 SS0
présente le même `chan_nr = 0x41`. Rien ne se passe — ni nouveau `dcch_seq`, ni
`set_dcch()`. Le shunt reste configuré sur l'**instance précédente** : fenêtre de
présentation `a_cd` périmée pour le canal courant.

`chan_nr` **est** l'identité du canal ; il ne porte aucun numéro d'instance. On ne
peut donc pas comparer plus finement — il faut **oublier** l'identité quand le
canal se termine.

### Le correctif

`calypso_l1ctl_dcch_forget()` remet `last_chan_nr` à `0xFF`. Elle est appelée par
la garde `DCCH` au moment où celle-ci conclut à la fin du canal — et la mesure
montre que la garde, elle, cycle correctement (**4** paires `ARMEE`/`levee` sur ce
run). C'est donc elle qui sait, et c'est d'elle qu'on prévient.

La prochaine établissement redéclenche alors, même à `chan_nr` égal.

### Confirmation par le réseau, et par la mesure d'après

Le BSC voit la même chose par l'autre bout — il réutilise tout, jusqu'à l'objet :

```
lchan(0-0-2-TCH_F-0)[0x5e7e3da21f50]   ×7    (jamais TS3..TS7, sur six TCH/F)
lchan(0-0-1-SDCCH8-0)[0x5e7e3da21e20]  ×4    (jamais SS1..SS7, sur huit)
lchan(0-0-1-SDCCH8-0){ESTABLISHED}: ERROR INDICATION
    cause=SABM frame with information not allowed in this state   ×4
```

Le mobile réémet un SABM sur un lien que le BSC tient pour établi : il n'a jamais
vu l'UA. Puis `EQUIPMENT FAILURE: Timeout` et `rll_ready=no`.

**La réutilisation n'est pas le défaut, c'est le révélateur.** Rien dans le GSM ne
l'interdit, et l'allocateur reprend naturellement le premier canal libre : avec un
seul mobile, c'est toujours le même. Un réseau réel ferait pareil — donc ce défaut
frapperait *tous* les deuxièmes appels, partout. Ce n'est pas un artefact de banc.

Après correctif :

```
DCCH #1 : chan_nr=0x41 -> SDCCH/8 SS=0 TN=1
DCCH #2 : chan_nr=0x41 -> SDCCH/8 SS=0 TN=1     ← MEME chan_nr, et pourtant appris
dcch_cfg : seq=2      identite oubliee : x1      DCCH-GARDE : ARMEE x2, levee x1
```

### Le motif, pour la quatrième fois

Déduire un **événement** (« canal neuf ») d'une **comparaison d'état**
(« `chan_nr` a changé ») au lieu de l'événement lui-même. Exactement comme :
osmocon devinant la fin de vie du Kc sur `DM_EST_REQ` (§1), les trois marqueurs
de relâchement (§2), et la garde concluant « canal fini » sur un TTL de fraîcheur
de décodage (§3). Quand ce dépôt se trompe, c'est presque toujours de cette
façon-là.

---

## 4. Le remplissage de C0 compté comme échec

`osmo-bts` remplit **tous** les timeslots de C0 avec le dummy burst
(`scheduler_trx.c`) pour tenir la puissance de la balise. Un canal dédié inactif
reçoit donc du remplissage en continu.

Le filtre `_is_dummy()` existait pour le xcch — avec sa mesure : *515 blocs de
remplissage comptés en `crc_fail`, 76 % d'échec annoncés sur une radio saine*.
**Le chemin TCH ne l'avait jamais eu** : `dl_dispatch` fait `return` sur la
branche TCH avant d'atteindre le filtre.

Le traçage `PONT_TCH_TRACE=1` a montré la même cause sous **deux signatures**,
selon que le Kc était disponible ou non :

| phase | entrée du Viterbi | `ne` |
|---|---|---|
| pas de Kc | dummy brut, motif **figé** | `0`, constant |
| Kc arrivé | dummy **chiffré**, clé variant par trame | ~50 |

`ne=0` avec `rc=-1` ne s'obtient pas sur du bruit : c'est la signature d'une
entrée constante. Le filtre est posé **avant** l'`a5_apply`, pour la même raison
que côté xcch — le dummy n'est jamais chiffré, et le passer au keystream le
rendrait méconnaissable.

---

## 5. `CALYPSO_CANNED=1` ne cannait rien

`shunt_parse_canned()` attend une **liste de jetons** :
`FBDET,TOA,PM,SNR,ANGLE,CRC | FULL | ALL | NONE`.

`start-direct.sh` posait `CALYPSO_CANNED=1` depuis toujours. `1` n'est aucun de
ces jetons : il tombait dans le `else`, sortait un `token inconnu '1' ignore`
noyé dans le démarrage, et le masque restait **vide** :

```
CALYPSO_CANNED (dette fabriquée EXPLICITE) : FBDET=0 TOA=0 PM=0 SNR=0 ANGLE=0 CRC=0
```

Le banc tournait avec **rien de canné** pendant que sa configuration affichait
l'inverse.

Corrigé des deux côtés — et les deux comptent : `start-direct.sh` pose désormais
`FULL`, **et** le parseur accepte `1/ON/YES/TRUE` et `0/OFF/NO/FALSE`. Une
variable booléenne qui veut dire « rien » au lieu de « tout » est un piège ;
changer la valeur sans changer le parseur l'aurait laissé armé.

---

## 6. Hypothèses écartées

Conservées pour ne pas être réexplorées.

| hypothèse | verdict |
|---|---|
| Plan SDCCH/8 mal implémenté | **non** — `PLAN_SD8` est conforme au 05.02 : blocs à `4·ss`, SACCH/C8 à 32/36/40/44 avec report `+51` pour SS4..7, UL à `+15` |
| Trame idle (`m26=25`) empoisonnant la fenêtre TCH | **non** — `tch_dl_burst` écarte `m26 in (12, 25)`, et `gap=0` sur tout le run |
| Alias SACCH 32/83 en `fn%51` | **non** — filtré sur la 102-multitrame : `(k[1] % 102) != plan.sacch_dl102[_act]` |
| TCH resté armé après l'appel | **non** — compteurs figés sur cinq intervalles après `DESARME` |
| `_TBL_SOFT` écrasant deux encodages | **non pour ce symptôme** — le DL TRXD arrive en bits durs `0x00/0x01`. La fragilité reste réelle (une table, deux encodages : `0x01` et `0xFF` donnent tous deux `-127`) mais n'est pas la cause |

---

## 7. Reste ouvert

* **`unsupported SAPI` côté mobile** — 38 sur le run LU + 2 appels. Ni l'en-tête
  L1 du SACCH (§3, réfuté), ni le SI du camp (§3, réfuté par la mesure). Source
  toujours inconnue : chercher qui d'autre atteint `a_cd`, ou si le firmware
  relit un bloc périmé faute de rafraîchissement (`B_BLUD`).
* **CRC résiduels** — `chiffre 62/69`, soit 7 échecs sur le SDCCH chiffré, plus
  3 sur le SACCH. Non isolés.
* **TCH** — l'histogramme rend `octets[00:928]` : les 928 octets de la fenêtre
  sont à **zéro**. Ce ne sont ni des dummy bursts (motif non nul, désormais
  filtrés) ni du bruit : le timeslot ne porte rien. Vraisemblablement en aval du
  mobile qui ne bascule pas, donc à revoir **après** le correctif SACCH.

---

## Outils de diagnostic

| variable | effet |
|---|---|
| `PONT_TCH_TRACE=1` | une ligne par bloc TCH/F en échec : `fn/m26/idx/acc` (alignement), `A5` (déchiffrement et clé), `rc/ne/nb` (décodeur), et l'**histogramme des octets** de la fenêtre |
| `PONT_KC_RETENTION=0` | désactive la rétention, pour comparer |
| `PONT_A5=1..3` | force l'algorithme au lieu de suivre celui du Kc |
| `CALYPSO_CANNED=NONE` | rien de canné, tout réel |

Lecture des compteurs : `ne` est le nombre d'erreurs binaires, `nb` le nombre
**total** de bits (378 pour TCH/FS — constant, ce n'est pas un compteur
d'erreurs). `ne=0` avec `rc=-1` signale une entrée constante, pas une radio
saine.

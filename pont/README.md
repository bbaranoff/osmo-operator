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

## 3. Le SACCH — l'en-tête L1 n'est pas retiré

### Le symptôme

Côté mobile, en boucle :

```
DLLAPD lapdm.c Received frame for unsupported SAPI 6!
DRR    gsm48_rr.c:4390 Radio link is released
DMNCC  mnccms.c:714    Call has been released (cause 16)
```

SAPI 6 n'existe pas en LAPDm (0 = signalisation, 3 = SMS).

### La démonstration

`lapdm_rx_ph_data_ind` calcule `sapi = (l2h[0] >> 2) & 7`, donc sur **l'octet
d'adresse**. Pour un bloc SACCH, il ne saute les 2 octets d'en-tête L1 que si le
drapeau SACCH (`link_id & 0x40`) est posé.

L'octet 0 de l'en-tête L1 SACCH porte la **puissance ordonnée** (bits 0-4), et
elle varie en permanence (`CTRL SETPOWER` en continu dans le journal du pont) :

| puissance | `(p >> 2) & 7` | SAPI observé | occurrences |
|---|---|---|---|
| 24–27 | 6 | 6 | 28 |
| 20–23 | 5 | 5 | 2 |
| 16–19 | 4 | 4 | 1 |
| 8–11 | 2 | 2 | 2 |

**Total 33.** Le pont a tenté exactement **33** blocs SACCH (`TS1/32 : 30/33`).

Les quatre valeurs de SAPI ne sont pas du bruit : ce sont les **paliers de
puissance**. C'est ce qui transforme une corrélation de comptage en preuve.

### Ce que ce n'est pas

Le contenu est **bien formé**. Le tampon du shunt, journalisé :

```
07 00 | 03 03 49 | 06 1d ...
 L1     addr ctrl len   PD=RR  SI5
```

⚠️ Le commentaire de `calypso_dsp_shunt.c:1607` attend `[4]` = début du L3, donc
un format B4 **sans** octet de longueur. C'est **faux** : le SACCH descendant
porte bien un octet de longueur (`0x49` = 18). Le format observé est le bon ;
c'est le commentaire qui trompera la prochaine lecture.

### Conséquence

Le mobile ne traite **aucun** SACCH : ni rapport de mesure, ni supervision de
lien. Le réseau finit par lâcher le lien radio. **C'est ce qui bloque le deuxième
appel — pas le Kc.**

> **Non corrigé à ce jour.** Le correctif touche la façon dont le firmware est
> averti qu'un bloc est du SACCH (drapeau `link_id & 0x40`).

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

* **SACCH** — le drapeau `link_id & 0x40` (§3). C'est le blocage du 2ᵉ appel.
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

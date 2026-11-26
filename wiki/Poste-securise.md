# Un poste réparable, traçable et réversible : sécurisation et disponibilité d'un banc installé

## Résumé

Le système est **en clair et en lecture seule** ; chaque session tourne **en RAM**.
Rien n'atteint le disque sans une phrase de passe. Tout ce qui l'atteint est
**journalisé dans une boîte noire que la machine remplit sans pouvoir la relire**, et
chaque écriture est **réversible**. Un seul mécanisme — la couche RAM comparée au
disque — sert à sécuriser, à tracer et à revenir en arrière.

## 1. Le problème

Un poste de laboratoire doit rester **réparable** : sortir une trace, lire un journal,
dépanner depuis une clé live sans rien déchiffrer. Chiffrer tout le disque l'interdit.
Le laisser en clair et inscriptible laisse chaque session y déposer ce qu'elle veut,
sans trace ni retour possible.

Objectifs :

- le système reste lisible, les secrets non ;
- une session ne laisse rien sans consentement explicite ;
- ce qui est écrit est tracé, même par une session ensuite effacée ;
- une écriture ratée ou regrettée ne coûte pas la machine.

## 2. Architecture

| Volume | État | Rôle |
|---|---|---|
| EFI | clair | GRUB |
| `/` | clair, **lecture seule** | le système ; les écritures vont dans une couche RAM (overlayroot) |
| boîte noire (5 Gio) | partition en clair, **enregistrements chiffrés** | le journal de toutes les sessions |
| `/home` | **LUKS2** | les données et les secrets ; lui aussi sous une couche RAM |

Deux phrases de passe, aux rôles séparés :

- celle de **`/home`** ouvre les données **et** autorise une écriture sur le disque ;
- celle de **la boîte noire**, différente (celle de `/home` est refusée), ne sert qu'à la
  relire — et à changer la destination de sa copie. Elle est choisie au premier
  démarrage ; la clé privée n'existe jamais en clair.

## 3. Mécanismes

### 3.1 La session en RAM et sa validation

- **En cours de session**, la phrase écrit la session *telle qu'elle est à cet instant*.
  Ce qui suit n'est pas couvert.
- **À l'extinction**, la phrase écrit la session complète.
- **Sans phrase**, l'extinction abandonne ce qui a suivi la dernière validation et dit
  combien de changements sont perdus.

Une écriture montre sa progression : à l'extinction, l'écran REC (`cmatrix`, et en bas,
en rouge, centrée, la barre) ; dans un terminal, une barre sur la ligne.

### 3.2 Écriture atomique et différentielle

1. Seul ce qui diffère du disque est copié à côté de lui, sur le même système de
   fichiers (comparaison par contenu).
2. Une marque `PRET` est synchronisée : c'est le point de validation.
3. Les fichiers sont mis en place par renommage.

Une coupure avant `PRET` laisse le disque intact ; une coupure après est terminée au
démarrage suivant (initramfs pour `/`, à l'ouverture pour `/home`).

### 3.3 Retour arrière

Une écriture ne détruit rien : ce qu'elle remplace ou supprime est déplacé dans un
répertoire de retour daté. Les écritures se défont de la dernière vers la première
(20 niveaux par défaut). La boîte noire garde l'enregistrement d'origine et en reçoit
un nouveau, « défait », avec ce qui a été retiré.

### 3.4 La boîte noire

- Un enregistrement par événement : `valide`, `efface`, `ecrit`, `defait`, `alerte`,
  `copie`.
- Diffs texte du système, une ligne par binaire ; `/home` exclu par défaut.
- **Écrire sans pouvoir lire** : chiffrement `age` vers une clé publique ; la clé privée
  est sous la phrase de la boîte.
- Partition montée en lecture seule pour tous ; seul le script y écrit, le temps d'un
  enregistrement, ensuite rendu immuable.
- Enregistrements chaînés par SHA-256 ; une fin tronquée est détectée au démarrage.
- **Copie distante par SSH, du chiffré uniquement**, vers une machine qui n'accepte que
  des ajouts. La destination ne change qu'avec la phrase de la boîte (le changement
  est lui-même un enregistrement, et le sceau le couvre). Jamais bloquante : machine
  injoignable, les enregistrements attendent — et le démarrage suivant le dit en rouge,
  puis réessaie dès que le réseau répond.

### 3.5 Intégrité du disque

`/` étant en clair, quelqu'un peut y écrire machine éteinte.

- Après chaque écriture : **SHA-256 total de `/` et de `/home`**, posé sur la boîte, avec
  son détail par fichier. Chaque enregistrement porte aussi ces totaux.
- **À chaque démarrage, avant de demander la phrase** : le total de `/` est recalculé et
  comparé. S'il diffère, le détail est lu pour dire quoi, un avertissement rouge occupe
  la console, la boîte reçoit une `alerte`, et la phrase n'est demandée qu'après un
  `OUI` explicite (sinon : démarrage sans `/home`).
- `/home` est comparé dès son ouverture.
- En tâche de fond : relecture du contenu de chaque fichier (dates et inodes maquillés).
- Les totaux sont scellés (HMAC) par une clé gardée dans le `/home` chiffré.

### 3.6 Démarrage mesuré (option)

Un code TOTP à 6 chiffres, à comparer au téléphone **avant** de taper la phrase
(`sudo osmo-tpm poser`, appli enrôlée par QR code).

- Firmware, GRUB, noyau et initramfs sont mesurés (PCR 0, 2, 4, 7, 8, 9).
- L'initramfs, lui-même mesuré, calcule le total du disque et l'ajoute au PCR 13.
- Le TPM ne rend la graine du code que si les sept PCR sont ceux du scellement.
- Le PCR 13 est ensuite étendu de nouveau : plus rien ne peut desceller pendant ce
  démarrage.
- Après une écriture de session, l'objet est rescellé pour le nouveau disque — avec les
  PCR de référence, et seulement si le démarrage courant avait été reconnu.
- Après une mise à jour du noyau, de l'initramfs ou de GRUB : un démarrage sans code,
  attendu, puis `sudo osmo-tpm sceller` — à la main, jamais après un code absent
  qu'on ne s'explique pas.

Un seul noyau, pas de second système, pas de `kexec`. LUKS n'est pas touché : `/home`
reste en LUKS2, sa phrase reste la seule entrée.

**Sans téléphone** : `sudo osmo-tpm poser --secret`. Le TPM garde une phrase choisie par
le propriétaire au lieu d'une graine, et l'affiche à côté de la question de `/home`.

- Un PIN (des chiffres, 6 au moins) est demandé par l'initramfs avant l'affichage. C'est
  le TPM qui le vérifie, en même temps que les PCR : un PIN faux compte contre son
  propre verrouillage (31 essais, puis un toutes les 10 minutes) ; sur une machine
  modifiée, aucun PIN n'est même vérifié.
- Sans PIN, quiconque allume la machine lit la phrase et peut la faire afficher par une
  machine piégée : déconseillé.
- Moins sûr que le code du téléphone, parce qu'une phrase ne change pas. Après un
  démarrage sans phrase qu'on ne s'explique pas : poser de nouveau, phrase et PIN
  nouveaux.
- `poser` et `poser --secret` s'excluent ; reposer l'un remplace l'autre.

`poser`, `sceller` et `oter` écrivent sur le disque : ils demandent d'abord la phrase de
`/home`.

**À l'installation.** La page Options de l'installeur a une case « Poste sécurisé », cochée
par défaut, qui **exige un TPM 2.0** ; décochée, c'est une Ubuntu ordinaire (disque écrit
directement, ni session en RAM, ni boîte noire, ni TPM). Sans TPM 2.0 vu par le noyau, la
case est décochée et grisée, avec la marche à suivre (l'activer dans le BIOS, redémarrer
la clé) ; le travail d'installation revérifie et ne pose jamais le poste sécurisé sans
TPM. L'installeur ne peut pas sceller : les mesures sont celles du démarrage du système
installé, pas de la clé live. Il prépare donc tout (initramfs compris), et la première
ouverture de session affiche une fenêtre d'accueil qui demande la phrase de `/home`, puis
enrôle le téléphone par QR code (seconde case, « code du TPM sur le téléphone », cochée
par défaut, grisée elle aussi sans TPM) ou, case décochée, demande la phrase secrète et le
PIN ; elle prend ensuite l'empreinte, ancre la signature et scelle (`osmo-tpm premier`). Elle revient à chaque ouverture de session tant que ce n'est pas
fait.

### 3.6 bis L'ouverture normale et l'ouverture d'échec

- **Normale** : la phrase tapée au démarrage ouvre le volume. Une question suit, sur la
  console, « Persistant ? [oui/non] » : **tout sauf un non (Entrée, ou pas de réponse en
  20 s) : persistant** — `/home` est monté en écriture directement sur le volume, rien à
  valider, rien d'effacé ; **non (n, N, no, No, NO) : à enregistrer** —
  `/home` reste intact sous une couche RAM, le travail de la session n'y est gardé que s'il
  est enregistré (icône disquette, ou la phrase à l'extinction). Le système (`/`) reste en
  RAM dans les deux cas et s'écrit à l'extinction avec la phrase.
- **Persistant : rien n'est demandé pour oublier.** À l'extinction, pas de « Tout
  oublier ? » : la phrase est demandée pour écrire ce qui a changé dans le système
  (Entrée : ne pas l'écrire — le neuralyseur passe alors avec une lumière verte, puis
  l'avertissement rouge habituel, qui précise que `/home` est déjà écrit), et `/home` est déjà sur le disque. Oublier la session est un
  geste volontaire, l'icône **« Remettre à zéro »** (`osmo-reset demander`), le contraire
  d'« Enregistrer » : on tape `oui`, et à l'extinction `/home` revient à l'état du
  démarrage, le système est effacé. Annulable jusque-là (même icône).
  *Comment* : `unlock-home` prend un instantané du volume (device-mapper) avant de le
  monter ; les anciens blocs que la session réécrit sont gardés **en RAM** (jamais sur un
  disque), au plus `CRYPTHOME_RESET_MO` (défaut : un quart de la mémoire). *Limites* : une
  session qui réécrit plus que cela ne peut plus être remise à zéro (l'icône le dit) ; une
  session qui a enregistré, défait ou changé des secrets non plus (la clé de signature et
  les clés de la boîte vivent dans `/home`) ; pendant la remise à zéro (quelques secondes
  à une minute) il ne faut pas couper la machine — les anciens blocs sont en RAM, un
  volume à moitié remis est un `/home` abîmé.
- **D'échec** : pas de phrase, ou une phrase refusée (trois essais). Un root invité, le
  disque en lecture seule, tout en RAM, rien de personnel, rien de gardé.
- **Une somme de contrôle diffère : pas de root invité.** Dès qu'une alerte d'intégrité
  existe (disque modifié hors session, empreinte non signée, clé de signature changée),
  seul le propriétaire peut continuer : `OUI` à l'alerte puis la phrase de `/home`. Sans
  elle, la machine le dit en rouge, bipe et s'éteint.
- **À l'extinction, les sommes sont recontrôlées** avant toute écriture
  (`osmo-empreinte extinction`). Propre au démarrage et différent à l'extinction : quelque
  chose a écrit sur le disque pendant la session sans la phrase — écran rouge,
  (« YOU HAVE DONE SOMETHING NASTY !!!! » en grosses lettres sur tout l'écran),
  enregistrement dans la boîte noire et bip (tous les volumes de la carte son sont mis au
  maximum, haut-parleur du PC en plus). Une écriture validée reprend et signe l'empreinte :
  elle ne déclenche rien. **La machine ne s'éteint alors pas** : rien n'est écrit sur le
  disque, la session est gardée dans la boîte noire, l'alarme tient l'écran et rebipe ;
  seul le bouton d'alimentation maintenu l'éteint. Une marque reste sur la boîte
  (`alarme`) : le démarrage suivant est une alerte quoi que montre le disque — donc sans
  root invité — jusqu'à une empreinte reprise avec la phrase (`sudo osmo-empreinte prendre`).
  **Le bouton de test**, comme sur un disjoncteur différentiel : l'icône « Test de
  l'alarme » (`osmo-empreinte test-alarme`) la fait sonner pour vérifier qu'elle marche —
  tout de suite sur le bureau (écran rouge et bip à fond, 10 secondes, impossible à
  fermer), ou à la prochaine extinction sur la vraie console (15 secondes, puis
  l'extinction continue). Rien n'est noté, rien n'est retenu.
- Pas de question quand le mode est fixé : `CRYPTHOME_HOME="direct"` ou `"ram"` dans
  `/etc/default/crypthome`, ou l'entrée GRUB « /home en RAM » pour un démarrage. En mode
  « à enregistrer » seulement, `/home` a une empreinte, des retours arrière et sa couche
  dans les points de contrôle.

### 3.6 ter Les états du système, comme du code

Chaque écriture validée du système est un commit : ce qu'elle a remplacé ou supprimé est
gardé. **Ces états passés vivent dans le volume de `/home`** (`.osmo-retour/systeme/`),
pas sur le disque système : dès qu'une écriture est faite, ils y sont rangés et retirés du
disque en clair (`osmo-racine-live ranger` le fait tout de suite, avec la phrase). Qui tient
le disque, ou une session root invitée, n'a donc plus l'historique des fichiers du
système. Pour défaire une écriture, son état est ressorti sur le disque le temps du retour
arrière. Une écriture validée depuis une session invitée (`/home` fermé) reste sur le
disque jusqu'à la prochaine écriture du propriétaire.

**Chaînés et signés.** Chaque état reçoit, au moment où l'écriture qui l'a produit est
validée, une empreinte calculée sur tout son contenu, et un maillon calculé sur celui de
l'état précédent, comme un commit git. Le fichier `CHAINE` (une ligne par état) est signé
avec la clé de l'empreinte, celle que seule la phrase de `/home` déverrouille. Un état
modifié, remplacé ou glissé après coup ne correspond plus à sa ligne, et les lignes ne se
refont pas sans la phrase : `osmo-empreinte etats-verifier` (ou `osmo-boite fsck`, et le
bandeau en tête du navigateur) le dit, sans aucune phrase. Seuls les états que l'écriture
en cours vient de ranger entrent dans la chaîne. *Non couvert* : revenir à une chaîne plus
ancienne avec sa propre signature valide, en retirant les états plus récents — rien hors
de `/home` ne garde la tête de la chaîne. Les dates sont celles de l'horloge de la machine.

Deux façons de s'en servir.

- **Parcourir, comme sur GitHub** : l'icône « États du système » (`osmo-boite web`,
  `osmo-etats`) ouvre une page locale en lecture seule — la liste des écritures par
  session, pour chacune ses fichiers ajoutés, modifiés, supprimés avec leurs diffs,
  l'arborescence du système telle qu'elle était à cet état, chaque fichier tel qu'il était,
  et l'historique d'un fichier. La session en cours (en mémoire, pas encore enregistrée) y
  figure en tête. Elle tourne en root, n'écoute que sur `127.0.0.1`, et chaque adresse
  porte une clé tirée au lancement. Elle refuse de démarrer quand `/home` est fermé
  (session invitée). Les fichiers du propriétaire dans `/home` n'y sont pas.
- **Les mots de git** (`osmo-boite`) : `log`, `show ID` (phrase de la boîte), `status`,
  `diff [chemin]`, `commit` (= Enregistrer), `revert` (= défaire la dernière écriture),
  `checkout N` (= remonter N sessions), `stash` et `merge NOM` (les sessions non validées),
  `reset` (= Remettre à zéro), `fsck` (la chaîne), `bundle DOSSIER` et `gc` (copier, vider).
  Ce n'est pas un dépôt git : la machine écrit la boîte sans pouvoir la lire, ce qu'un
  dépôt ne permet pas ; ce sont les mêmes commandes qu'avant sous des noms connus.

**La boîte à 80 %.** Une boîte pleine ne note plus rien. À partir de 80 % d'occupation, à
l'ouverture de session, une fenêtre demande : en faire une copie (clé USB, autre disque)
puis la vider, la vider sans copie, ou plus tard (`osmo-diffs plein`). La copie est un seul
fichier, toujours chiffré, relu avec la phrase de la boîte. Vider demande la phrase de
`/home` ; les sessions non validées en attente partent avec. La nouvelle chaîne commence
par un enregistrement qui dit combien d'enregistrements sont partis, le nom et l'empreinte
du dernier, et où est la copie.

### 3.7 Deux root

Le disque système est en clair : l'état personnel de root (identifiants de l'assistant,
jeton GitHub, historique, clés) ne doit pas s'y trouver.

- **Root du propriétaire** : `/home` ouvert, `/root` est un répertoire du volume chiffré
  (`/home/.root`), monté par-dessus celui du disque par `unlock-home`. La première fois,
  c'est une copie du `/root` du disque.
- **Root invité** : la session ouverte sans la phrase. Il a le `/root` du disque — les
  outils du banc, rien de personnel — en RAM.
- Plus rien de `/root` n'est écrit sur le disque système, ni par la session du
  propriétaire ni par une session invitée validée après coup.
- `sudo osmo-racine-live root-nettoyer` (une fois, phrase de `/home`) retire du `/root`
  du disque et des retours arrière tout ce que l'image n'y a pas mis. Ce que la boîte
  noire a déjà enregistré y reste, sous sa propre phrase ; les jetons déjà exposés sont à
  renouveler.
- Le root du propriétaire garde tous ses droits : c'est son état qui est enfermé dans le
  chiffré, pas ses pouvoirs. `/etc`, `/var` et `/opt` restent en clair.

Dans le terminal : root du propriétaire en rouge, root invité en vert, compte de session
en bleu foncé gras, nom de machine en gras.

## 4. Modèle de menace

| Menace | Réponse | Limite |
|---|---|---|
| Vol du poste éteint | `/home` en LUKS2 | le système est lisible, par conception |
| Session qui laisse des traces | RAM ; rien sans la phrase | — |
| Écriture discrète en session | diff dans la boîte, même si la session est effacée | root peut détruire la boîte, pas la lire |
| Écriture hors session | empreinte comparée avant la phrase | le contrôle tourne depuis le disque qu'il vérifie |
| Attaquant qui réécrit aussi le contrôle | démarrage mesuré (option) | demande que l'utilisateur regarde le code |
| Destruction de la boîte | copie distante, ajout seul | réseau absent : copie différée, signalée |
| Écriture ratée ou regrettée | atomicité, retour arrière | tout est sur le même disque : ce n'est pas une sauvegarde |

**Hors périmètre** : un root hostile avec la machine en main et le temps de lire le code,
en l'absence de démarrage mesuré.

### 4.1 Tableau des périmètres

Une ligne par donnée : où elle vit, ce qui doit être vrai pour la lire, pour la modifier.
Deux usages. **Audit** : une donnée qui apparaît sur deux lignes avec des conditions
différentes est une fuite de périmètre — c'est la plus faible des deux qui compte.
**Règle** : toute nouvelle fonction ajoute ou modifie une ligne ; si elle abaisse une
condition, cela se voit ici avant d'être écrit.

| Donnée | Où elle vit | Pour la lire | Pour la modifier |
|---|---|---|---|
| Contenu de `/home` | LUKS2 (argon2id, 1 Gio) | phrase home | phrase home |
| `/home` pendant la session (ouverture normale) | LUKS2, écrit directement | phrase home (tapée au démarrage) | idem |
| Anciens blocs de `/home` (pour « Remettre à zéro ») | RAM (tmpfs `/run/osmo-reset`), perdus à l'extinction | root, session ouverte (comme `/home` lui-même) | idem ; remis sur le volume seulement sur ordre (icône, `oui`) |
| Session root invitée | RAM | personne si une somme de contrôle diffère (arrêt) ; sinon quiconque allume | — |
| Changements du système (`/`) pendant la session | RAM | root, session ouverte | idem ; perdus sans phrase home à l'extinction |
| Les mêmes dans la boîte (points de contrôle, sessions non validées) : couche `/` | boîte noire (`attente/`) | phrase boîte | personne |
| Idem, couche `/home` | boîte noire, chiffrée pour la clé du home | phrase home (clé privée dans le volume) | personne |
| Clé du home pour la boîte (privée) | `/home` (LUKS2), sans copie ailleurs | phrase home | phrase home |
| État de root (assistant, jetons, historique) | `/home/.root` | phrase home | phrase home |
| Le même, avant le nettoyage (fait d'office à la première écriture validée) | disque système, retours arrière | **rien** (disque en main) | phrase home |
| Le même, diffs déjà enregistrés | boîte noire (journal) | **phrase boîte** | personne |
| Nos journaux | `/home/.log` (monté sur `/opt/log`) | phrase home | phrase home |
| Journaux vivants d'une exécution | RAM (`$LOG_DIR`) | root, session ouverte | idem |
| Journal des sessions (dates, comptes, totaux) | disque système | rien | phrase home |
| Disque système (`/etc`, `/var`, `/opt`, `/boot`) | en clair | rien | phrase home, sinon détecté (empreinte signée) |
| Secrets du banc (`hlr.db`, clé du webui open5gs) | disque système | **rien** | idem |
| Clé privée de signature de l'empreinte | `/home` (LUKS2), chiffrée en plus par la phrase (scrypt, 1 Gio) | phrase home | phrase home |
| Clé publique de signature | boîte ; ancre TPM (NV `0x1800A50`) ; `/home` | tous | phrase home (secret propriétaire du TPM) |
| Empreinte : totaux et détail de `/` | boîte, en clair, signée | rien | phrase home |
| Empreinte : détail de `/home` | boîte, chiffré | phrase home | phrase home |
| Diffs de session | boîte noire (`age`) | phrase boîte | personne (chaîne ; fin tronquée vue depuis `/home`) |
| Les mêmes, copie de la boîte (`osmo-diffs sauvegarder`) | là où le propriétaire la pose (clé USB) | phrase boîte | qui tient la clé USB (la chaîne le montre) |
| Vider la boîte | — | — | phrase home ; noté en tête de la nouvelle chaîne |
| États passés du système (ce que chaque écriture a remplacé) | `/home` (LUKS2), `.osmo-retour/systeme` | phrase home (page locale `osmo-etats`, clé par lancement, refusée `/home` fermé) | phrase home |
| Chaîne des états (`CHAINE`, `CHAINE.sig`) | `/home` (LUKS2), à côté des états | phrase home | phrase home, saisie (signature) ; retour à une chaîne plus ancienne non détecté |
| Les mêmes, entre l'écriture et le rangement, ou écrits depuis une session invitée | disque système, en clair | **rien** (disque en main) jusqu'au rangement | phrase home |
| Clé de la boîte | boîte, chiffrée (PBKDF2, 600 000) | phrase boîte | phrase boîte |
| Graine du code, ou phrase secrète et PIN | objet scellé du TPM | bonne machine, bon état (et PIN) | rescellement |
| Les mêmes, copie pour resceller, et PCR de référence | `/home`, coffre chiffré par la phrase (scrypt, 1 Gio) | phrase home, saisie | phrase home, saisie |
| Micrologiciel, GRUB, noyau, initramfs, ESP | en clair | rien | détecté si le démarrage mesuré est posé |

**Fuites de périmètre connues** (deux conditions pour une même donnée) :

1. *La phrase home se devinait hors ligne au coût de PBKDF2, pas d'argon2id* : la clé de
   signature était chiffrée avec elle sur la partition de la boîte, en clair. **Corrigé** :
   la clé vit dans le volume `/home`, sous une dérivation à 1 Gio par essai ; celle de la
   boîte est écrasée à la signature suivante. Sur un SSD l'ancien fichier peut survivre :
   seul un changement de la phrase de `/home` ferme vraiment ce point. Reste le secret
   propriétaire du TPM, dérivé de la phrase (PBKDF2, 300 000 tours) : il ne se teste
   qu'en ligne, contre le TPM.
2. *La boîte lisait ce que LUKS protège* (couche RAM de `/home` dans les points de
   contrôle, sous la seule phrase de la boîte). **Corrigé** : cette couche y est chiffrée
   pour une clé dont la moitié privée ne sort pas du volume `/home` ; tant que la clé
   n'existe pas (avant la première écriture validée), la couche n'est pas gardée. Ce que
   la boîte contenait déjà sous l'ancien format y reste.
3. *Root, `/home` ouvert, avait la graine du démarrage mesuré* et pouvait changer les PCR
   de référence. **Corrigé** : graine ou phrase secrète, PIN et PCR de référence sont dans
   un coffre chiffré par la phrase de `/home` ; `qr`, `code`, `sceller` et le
   rescellement la demandent. Les fichiers en clair d'avant sont remplacés au prochain
   `sceller`.
4. *L'état de root d'avant le nettoyage* reste dans la boîte ; sur le disque il est
   retiré d'office (et des retours arrière) à la première écriture validée qui suit sa
   copie dans le volume. Tout secret qui y a vécu est à tenir pour compromis et à changer.
5. *Les secrets du banc sont en clair* dans `/opt` et `/etc`.

## 5. Mesures (un poste, NVMe, 4 cœurs, 18 Go de système)

| Opération | Durée |
|---|---|
| Validation d'une session de 15 600 fichiers | 251 s (boîte 120 s, `/` 111 s, `/home` 19 s) |
| Première empreinte complète (450 000 fichiers lus) | 57 s |
| Empreinte après une écriture (rien à relire) | 18 s |
| Contrôle au démarrage | ≈ 4 s |
| Contrôle complet du contenu | ≈ 30 s |

Coût observé : un enregistrement de 109 Mo pour cette session, sur une boîte de 5 Gio.

## 6. État de validation

| Élément | Vérifié comment |
|---|---|
| Écriture différentielle, retour arrière | bac à sable (overlay réel sur image ext4) |
| Validation en cours de session, `/` et `/home` | **une fois en réel** sur le poste |
| Empreinte, détection, sceau | bac à sable + disque réel (état conforme) |
| Principe TPM (bon disque → secret ; modifié ou verrouillé → refus ; rescellement) | **TPM réel**, PCR d'essai |
| Partie initramfs du TPM | syntaxe + calcul du code sous busybox (vecteur RFC 6238) ; **jamais démarrée** |
| Copie SSH (injoignable : rien ne bloque ; joignable : du chiffré part) | bac à sable, faux `ssh` |
| Page « Options » de l'installeur (cases à cocher) | le job seul, hors de Calamares |
| Extinction réelle, alerte rouge réelle, `defaire` réel | **non testés** |
| Installation par l'ISO avec l'ensemble | **non testée** |

Point ouvert : avant ces travaux, `/home` n'était jamais écrit à l'extinction alors que
`/` l'était ; la cause n'a pas été identifiée. Le chemin est maintenant journalisé sur
le disque (`/var/log/osmo-session.log`).

## 7. Travaux restants

- Essais réels : extinction, alerte, retour arrière, démarrage mesuré, installation
  complète en VM.
- Taille des enregistrements : exclusions ou plafond.
- Durée de l'application d'une écriture (un renommage par fichier, en shell) et de
  l'enregistrement dans la boîte.

## 8. Ce qui est nouveau

Pas les briques — overlay, LUKS, `age`, TPM existent. C'est leur **agencement** :

1. laisser le système en clair *exprès*, et compenser par la lecture seule, la trace et
   l'empreinte ;
2. une trace que la machine écrit sans pouvoir la relire, y compris pour ce qu'elle
   efface ;
3. le consentement par phrase comme seul passage vers le disque, avec une sémantique
   d'instant ;
4. la réversibilité comme propriété de sécurité : une écriture ne détruit jamais.

Les lignes « non testés » de la section 6 sont à mettre à jour au fil des essais réels :
ce sont elles qui décident si ce texte reste un concept ou devient un résultat.

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
`/home`. Dans l'installeur (page Options), l'ancre TPM de la signature et les deux
démarrages mesurés sont trois cases, toutes facultatives ; rien n'est posé par
l'installation, `osmo-tpm etat` dit ce qui reste à faire.

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
| Changements de la session (`/`, `/home`) | RAM | root, session ouverte | idem ; perdus sans phrase home |
| Les mêmes, points de contrôle et sessions non validées | boîte noire (`attente/`) | **phrase boîte** | personne |
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
| Clé de la boîte | boîte, chiffrée (PBKDF2, 600 000) | phrase boîte | phrase boîte |
| Graine du code, ou phrase secrète et PIN | objet scellé du TPM | bonne machine, bon état (et PIN) | rescellement |
| Les mêmes, copie pour resceller | `/home/.osmo-diffs/tpm` | **phrase home** (root, `/home` ouvert) | phrase home |
| Micrologiciel, GRUB, noyau, initramfs, ESP | en clair | rien | détecté si le démarrage mesuré est posé |

**Fuites de périmètre connues** (deux conditions pour une même donnée) :

1. *La phrase home se devinait hors ligne au coût de PBKDF2, pas d'argon2id* : la clé de
   signature était chiffrée avec elle sur la partition de la boîte, en clair. **Corrigé** :
   la clé vit dans le volume `/home`, sous une dérivation à 1 Gio par essai ; celle de la
   boîte est écrasée à la signature suivante. Sur un SSD l'ancien fichier peut survivre :
   seul un changement de la phrase de `/home` ferme vraiment ce point. Reste le secret
   propriétaire du TPM, dérivé de la phrase (PBKDF2, 300 000 tours) : il ne se teste
   qu'en ligne, contre le TPM.
2. *La boîte lit ce que LUKS protège.* Points de contrôle et sessions non validées
   contiennent la couche RAM de `/home` — donc aussi `/home/.root` et `/home/.log` —
   sous la seule phrase de la boîte.
3. *Root, `/home` ouvert, a la graine du démarrage mesuré* (copie gardée pour resceller).
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

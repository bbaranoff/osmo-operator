# Console SS7 - demarrage rapide

Tout vit dans `navigation/`. Aucune dependance : python3 de la distribution
suffit. Rien n'est ecrit en dur : point codes, hub, ports et abonnes sont lus
dans les conteneurs et dans les configurations du depot.

## 1. En trente secondes

    cd /home/nirvana/osmo_egprs
    sudo ./start.sh --wan --operators 2 --hub-ip 192.168.1.49   # le lab
    ./ss7-console.py                                            # le schema

Le schema s'ouvre. On circule **aux fleches**, on ouvre avec **Entree**, on
revient avec **Echap**. `q` quitte.

## 2. Les touches

| Touche | Effet |
|---|---|
| fleches | se deplacer de boite en boite, dans l'espace du schema |
| Entree | ouvrir le menu de l'element selectionne |
| Echap | revenir en arriere ; **dans un VTY : fermer CE VTY** et revenir au schema |
| Tab | element suivant |
| `v` | ouvrir directement le VTY de l'element |
| `s` | scripts SS7 (operations MAP) |
| `a` | audit SS7 (DAUD) d'un point code |
| `c` | connecter / deconnecter le lien M3UA de la console |
| `j` | journal du lien M3UA |
| `r` | relire la topologie |
| `?` | aide |

Dans un VTY : `Entree` envoie, haut/bas rejouent l'historique,
PagePrec/PageSuiv font defiler, `Echap` ferme la session. Les autres VTY
restent ouverts : une session par port, independantes.

## 3. Ce que montre le schema

    CONSOLE SS7 ---M3UA--- INTER-STP (hub)
                                |
                +---------------+---------------+
             OP1 - STP                       OP2 - STP
             1.11.2                          1.21.2
                |                               |
       STP  MSC/VLR  HLR  BSC  BTS  MGW  SGSN  GGSN  ...

Chaque boite de service porte son port VTY. Les couleurs suivent la famille :
SS7, coeur, abonnes, radio, media, data.

## 4. Sans interface : la ligne de commande

    ./ss7-console.py list                 inventaire (PC, hub, SCCP, VTY)
    ./ss7-console.py ops                  catalogue des operations MAP
    ./ss7-console.py vty 1 4258 "show subscribers all"
    ./ss7-console.py audit 1.11.1         le "ping" SS7 (DAUD -> DAVA/DUNA)
    ./ss7-console.py map sri-sm --pc 1.11.6 msisdn=600101 sc_addr=600999
    ./ss7-console.py serve                repondeur MAP (HLR simule)

`vty <n>` accepte le numero d'operateur ou le nom du conteneur.

## 5. Les operations MAP

| Cle | Operation | Opcode | SSN vise |
|---|---|---|---|
| `sri-sm` | sendRoutingInfoForSM | 45 | 6 (HLR) |
| `sri` | sendRoutingInfo | 22 | 6 |
| `ati` | anyTimeInterrogation | 71 | 6 |
| `sai` | sendAuthenticationInfo | 56 | 6 |
| `send-imsi` | sendIMSI | 58 | 6 |
| `psi` | provideSubscriberInfo | 70 | 7 (VLR) |
| `ul` | updateLocation | 2 | 6 |
| `raw` | invoke brut (opcode + parametre hexa) | - | - |

La console est un **vrai** point SS7 : elle s'attache a l'inter-STP en M3UA sur
SCTP, enregistre dynamiquement une routing key pour son point code (RKM), passe
ASP_ACTIVE, puis emet du TCAP/MAP qui traverse le hub comme le trafic des
operateurs. Chaque envoi peut etre exporte en script Python autonome
(`navigation/scripts/<operation>-<horodatage>.py`).

## 6. Le repondeur : un aller-retour MAP complet

Osmocom fait dialoguer MSC et HLR en **GSUP**, pas en MAP : un SRI-SM envoye au
vrai HLR ne trouve personne. Le repondeur comble ce trou en repondant avec les
donnees du VRAI HLR (lues par VTY), a travers le vrai hub.

    # terminal A
    ./ss7-console.py serve
    # terminal B
    ./ss7-console.py map sri-sm --pc 1.11.6 msisdn=600101 sc_addr=600999

    resultat (opcode 45) :
       IMSI                         001010001000001
       Noeud de service             +600101

## 7. Diagnostic et tests

    ./navigation/ss7-diag.py             diagnostic SS7 complet
    ./navigation/ss7-diag.py --rapide    sans M3UA ni MAP
    ./navigation/test-console.sh         teste CHAQUE commande, un log par test

`ss7-diag.py` verifie, dans l'ordre ou une panne se lit : environnement (SCTP),
topologie heritee des configs, STP/MSC/BSC/HLR de chaque operateur, association
SCTP vers le hub, attachement de la console comme ASP, audit de tous les point
codes connus, puis un aller-retour MAP reel. Le code de sortie est le nombre
d'echecs.

`test-console.sh` ecrit un fichier par commande dans
`navigation/logs/<horodatage>/`, plus un `rapport.txt`.

## 8. A savoir sur ce lab

- **Le lien M3UA depuis l'hote ne vit que quelques secondes.** L'inter-STP
  cesse de servir une association venue de l'hote au bout de ~3 s, et
  l'association SCTP expire vers 35 s. La console la renouvelle toute seule
  avant chaque echange (~0,3 s) : c'est invisible, mais cela explique un
  eventuel "pas de reponse" suivi d'un second essai qui marche.
- **Le hub refuse le parametre "Service Indicators"** dans une routing key
  (registration status 9). Il est donc omis.
- **Il faut proposer son propre routing context** : sans cela le hub rend le
  meme contexte a deux ASP differents, et en `traffic-mode override` le dernier
  attache vole le trafic du premier (la destination du premier passe DUNA).
- **Le DATA part sur le flux SCTP 1** : le flux 0 est reserve a la gestion, et
  un DATA dessus est refuse ("Invalid Stream Identifier").
- **Les point codes sont au format ITU 3-8-3** : `a.b.c` avec a et c de 0 a 7,
  b de 0 a 255. `1.11.60` n'existe pas - il serait recu comme `1.15.4`.
- Les point codes de la console (`1.11.7`, `1.11.6`...) laissent des routes
  dynamiques `PROHIB` dans les STP operateur quand elle se ferme : c'est normal,
  elles repassent `avail` au retour.

## 9. Les modules

| Fichier | Role |
|---|---|
| `topo.py` | inventaire : conteneurs, env, `/etc/osmocom/*.cfg`, ports VTY |
| `vty.py` | sessions VTY persistantes par `docker exec` |
| `diagram.py` | le schema et la navigation spatiale aux fleches |
| `tui.py` | l'interface curses (schema, menus, formulaires, VTY) |
| `ber.py` | BER/DER minimal |
| `sccp.py` | SCCP UDT/UDTS, adresses, global titles, TBCD |
| `tcap.py` | TCAP begin/end, invoke, returnResult, returnError, AARQ/AARE |
| `mapops.py` | catalogue MAP : encodeurs, decodeurs, erreurs |
| `m3ua.py` | ASP M3UA sur SCTP : ASPUP, RKM, ASPAC, DATA, battement |
| `ss7.py` | la couche qui relie tout, et le compte rendu lisible |
| `responder.py` | repondeur MAP adosse au vrai HLR |
| `quickcmd.py` | commandes VTY utiles, par demon |
| `ss7-console.py` | point d'entree (schema + sous-commandes) |
| `ss7-diag.py` | diagnostic complet |
| `test-console.sh` | test de chaque commande, avec journaux |

## 10. Depannage

| Symptome | Cause probable |
|---|---|
| `aucun inter-STP connu` | lab arrete, ou `--hub-ip` jamais donne a `start.sh` |
| `le conteneur ... ne tourne pas` | `docker ps` ne le voit plus |
| `VTY ... injoignable` | le demon n'est pas lance dans ce conteneur |
| `Aucune reponse` a un MAP | personne n'ecoute ce SSN : lancez `serve` |
| fleches sans effet | terminal en mode curseur normal - deja gere, sinon `TERM=xterm` |
| `DUNA` sur un point code | l'ASP de cette destination n'est pas attache au hub |

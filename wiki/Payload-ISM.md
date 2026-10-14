# Payload SMS par radio ISM, le reste par IP (`--payload-ism`)

Entre deux machines qui font tourner osmo-operator, `--wan` fait déjà passer par
IP toute la liaison inter-nœud : signalisation SS7, voix SIP, et le relais SMS
(`scripts/sms-interop-relay.py`) qui porte le texte des messages dans un JSON sur
TCP. L'option `--payload-ism` garde tout cela sur IP **sauf le contenu du SMS** :
le texte voyage sur une **liaison radio en bande ISM** (433 / 868 / 915 MHz,
2,4 GHz, sans licence), les deux relais se coordonnant toujours par TCP.

```
         IP (--wan) : SS7, SIP, adresses, MSISDN, IMSI, SC-address, + un JETON
   ┌────────────────────────────────────────────────────────────────┐
Nœud 1                                                             Nœud 2
   │   texte du SMS ────────────── radio ISM ──────────────▶ texte du SMS
   └────────────────────────────────────────────────────────────────┘
```

## Comment ça marche

Le relais SMS extrait déjà le texte du TPDU d'un SMS mobile-originé pour le
réinjecter en mobile-terminé sur l'autre nœud. Avec `--payload-ism` :

1. **Émission.** Le relais tire un jeton de corrélation, émet le texte sur la
   radio ISM estampillé de ce jeton, et n'envoie sur TCP que le jeton (plus les
   adresses). Le champ texte du TCP part vide.
2. **Réception.** L'autre relais reçoit le JSON TCP, voit `payload_via=ism`, et
   attend sur la liaison radio le texte portant ce jeton avant d'injecter le MT.

Si la radio échoue à l'émission, le relais retombe sur IP pour ce SMS (il ne
reste jamais muet). Si le texte n'arrive pas par radio dans le délai
(`recv_timeout`, 30 s par défaut), la réception répond en erreur.

La liaison radio est découplée du matériel : `scripts/ism_payload.py` parle à
l'**interface de données** de ta radio, trame le texte en une ligne JSON avec
CRC32 (une trame tronquée ou corrompue est ignorée), et corrèle par jeton.

## Les backends

On choisit le backend avec `network/setup-payload-ism.sh`, qui écrit la section
`[payload]` de `sms-routing.conf` (lue par le relais).

| backend | pour quoi | mise en place |
|---|---|---|
| `serial` | un module ISM en UART (LoRa, RFM69, CC1101, HC-12…) sur `/dev/tty*` | `sudo ./network/setup-payload-ism.sh --serial /dev/ttyUSB0 --baud 9600` |
| `exec` | un pipeline SDR que tu fournis (HackRF/LimeSDR/USRP + GNU Radio, rtl_433…) | `sudo ./network/setup-payload-ism.sh --exec --tx-cmd … --rx-cmd …` |
| `fifo` | deux tubes nommés, pour brancher ta radio autrement (`socat`…) | `sudo ./network/setup-payload-ism.sh --fifo --tx /tmp/ism_tx --rx /tmp/ism_rx` |
| `loopback` | essayer la chaîne SMS **sans radio**, sur une seule machine | `sudo ./network/setup-payload-ism.sh --loopback` |

Pour le backend `exec`, `setup-payload-ism.sh --exemples` dépose deux gabarits
`/opt/GSM/ism/ism_tx.sh` et `ism_rx.sh` : `ism_tx.sh` reçoit une trame (ligne
JSON) sur son entrée standard et doit l'émettre ; `ism_rx.sh` doit écrire sur sa
sortie standard chaque trame reçue. Tant qu'ils ne sont pas remplis avec ta
chaîne radio, le texte ne traverse pas.

## Lancer

Sur **chaque** nœud, avec le WAN déjà en place :

```bash
# 1. poser la liaison radio (une fois, ou refait par start-direct)
sudo ./network/setup-payload-ism.sh --serial /dev/ttyUSB0 --baud 9600

# 2. lancer le banc : WAN par IP + payload par ISM
sudo ./start-direct.sh --wan --payload-ism
```

`--payload-ism=serial` (ou `=exec`, `=fifo`, `=loopback`) écrit en plus la
section `[payload]` au lancement, avec le périphérique/les commandes pris dans
l'environnement : `ISM_SERIAL`, `ISM_SERIAL_BAUD`, `ISM_TX`, `ISM_RX`,
`ISM_TX_CMD`, `ISM_RX_CMD`. Sans backend, `--payload-ism` réutilise la section
déjà écrite.

Pour revenir au texte par IP : `sudo ./network/setup-payload-ism.sh --off`.

## Vérifier sans radio

```bash
python3 scripts/ism_payload.py --selftest                 # boucle mémoire
python3 scripts/ism_payload.py --selftest --link fifo \
        --tx /tmp/ism_a --rx /tmp/ism_b                   # boucle par tubes
sudo ./network/setup-payload-ism.sh --loopback            # chaîne SMS complète, un nœud
```

L'autotest envoie trois textes (dont 140 octets et des accents) et vérifie le
rejet d'une trame à CRC faux.

## La section `[payload]` de `sms-routing.conf`

```ini
[payload]
mode = ism                 ; ism = texte par radio ; absent/autre = texte par IP
link = serial              ; serial | exec | fifo | loopback
serial = /dev/ttyUSB0      ; (serial) le périphérique UART
; tx = /tmp/osmo_ism_tx    ; (fifo) tube d'émission
; rx = /tmp/osmo_ism_rx    ; (fifo) tube de réception
; tx_cmd = /opt/GSM/ism/ism_tx.sh   ; (exec) commande d'émission
; rx_cmd = /opt/GSM/ism/ism_rx.sh   ; (exec) commande de réception
recv_timeout = 30          ; attente du texte par radio avant échec (s)
```

## Réglementaire

N'émets que sur une bande et une puissance ISM autorisées là où tu es (433 et
868 MHz en Europe, 902-928 MHz en région 2, 2,4 GHz), ou en charge/cage de
Faraday. C'est ta responsabilité d'opérateur du banc.

## Fichiers

| fichier | rôle |
|---|---|
| `scripts/ism_payload.py` | la liaison payload ISM : backends, trame + CRC, corrélation par jeton, autotest |
| `scripts/sms-interop-relay.py` | relais SMS : jeton sur TCP, texte sur la radio quand `[payload] mode=ism` |
| `network/setup-payload-ism.sh` | écrit `[payload]`, pose le débit série, dépose les gabarits SDR, autotest |
| `start-direct.sh` | l'option `--payload-ism[=backend]` |

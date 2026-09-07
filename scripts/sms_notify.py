#!/usr/bin/env python3
"""sms_notify.py - PREVENIR LES MODEMS DU BANC QU UN SMS ARRIVE.

POURQUOI CE FICHIER EXISTE. osmo-msc du banc tourne avec « sms-over-gsup » :
un SM-RP recu de la radio part au HLR (gsm_04_11.c:742) sans jamais passer par
gsm340_rx_tpdu(), donc sans jamais atteindre sms_route_mt_sms() ni le serveur
SMPP. Le « smpp-first » et les « route prefix ... 100101 » de osmo-msc.cfg sont
de la configuration morte tant que sms-over-gsup est la : un ESME lie sur le
port 2775 ne recoit RIEN. Et le MT qui revient par GSUP est pousse directement
a l abonne par la voie radio - le mobile osmocom-bb l a, les modems logiciels
(Android via oFono, la VM postmarketOS via son port serie PCI) ne l ont pas.

D ou cette voie de service : la ou la passerelle decide d une remise locale,
elle previent aussi les modems, qui presentent le message a leur systeme sous
la forme AT attendue. On ne touche pas au chemin GSUP, donc le mobile continue
de recevoir comme avant - c est bien pour cela qu on ne duplique RIEN ici.

Deux emplois :
    import            : from sms_notify import notifier      (dans le relais)
    ligne de commande : sms_notify.py <imsi> <from> <texte>   (send-mt-sms.sh)
"""
import json
import os
import socket
import sys

# Les boites d entree des modems. Le meme programme (osmo-phonesim-banc.py)
# tourne DEUX fois sur ce banc et il lui faut donc deux ports : celui du modem
# d Android (mode ecoute) et celui du modem de la VM (mode --connect).
DEFAUT = "127.0.0.1:12348,127.0.0.1:12349"
TIMEOUT = 2.0


def cibles():
    val = os.environ.get("OSMO_SMS_NOTIFY", DEFAUT)
    out = []
    for morceau in val.split(","):
        morceau = morceau.strip()
        if not morceau:
            continue
        hote, _, port = morceau.rpartition(":")
        try:
            out.append((hote or "127.0.0.1", int(port)))
        except ValueError:
            continue
    return out


def notifier(imsi, sender, text, log=None):
    """Remet une copie du SMS aux modems. Best effort : un modem absent n est
    pas une erreur (la VM peut etre eteinte), on ne leve jamais."""
    charge = (json.dumps({"imsi": imsi, "from": sender, "text": text},
                         ensure_ascii=False) + "\n").encode()
    touches = 0
    for hote, port in cibles():
        try:
            s = socket.create_connection((hote, port), timeout=TIMEOUT)
        except OSError:
            continue                      # pas de modem sur ce port : normal
        try:
            s.sendall(charge)
            touches += 1
        except OSError:
            pass
        finally:
            s.close()
    if log:
        log("modems prevenus : %d" % touches)
    return touches


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("usage: sms_notify.py <imsi> <from> <texte>", file=sys.stderr)
        sys.exit(2)
    n = notifier(sys.argv[1], sys.argv[2], " ".join(sys.argv[3:]))
    print("modems prevenus : %d" % n)

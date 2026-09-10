#!/usr/bin/env python3
# osmo-ts-probe.py - QUI PORTE DES BURSTS, MAINTENANT ? Ecrit l etat des 8
# timeslots que la banniere LAB GSM (configs/conky/labgsm.html, via
# osmo-topzone.py) fait clignoter en orange.
#
# Deux sources :
#   1. LA CONF osmo-bsc : phys_chan_config de chaque timeslot (CCCH+SDCCH4,
#      SDCCH8, TCH/F ...). Donne le TYPE, donc le libelle de chaque case et le
#      fait qu un TCH puisse porter de la VOIX. Cherchee dans, au choix :
#         $OSMO_BSC_CFG, /etc/osmocom/osmo-bsc.cfg, $OSMO_REPO/configs/osmo-bsc.cfg
#   2. LE VTY osmo-bsc (telnet 127.0.0.1 4242, `show lchan summary`) : quels
#      canaux logiques sont ETABLIS, sur quel timeslot, de quel type. Un TCH
#      etabli = de la voix -> le timeslot clignote. Pas de VTY (banc arrete) ->
#      bsc=false, la banniere passe en demonstration.
#
# Sortie : $OSMO_FFT_DIR/timeslots.json (defaut /run/osmo-fft, /tmp en repli
# - voir run_dir(), la MEME regle que le lecteur), reecrit chaque
# seconde, de forme :
#   {"bsc":true,"arfcn":"ARFCN 514 · DCS 1800",
#    "ts":[{"n":0,"type":"CCCH+SDCCH4","active":false,"voice":false}, ...]}
import json
import os
import re
import socket
import sys
import time

REPO = os.environ.get("OSMO_REPO", "/opt/GSM/osmo-operator")
# ── OU ECRIRE : LA MEME REGLE QUE LE LECTEUR, ET RELUE A CHAQUE TOUR ────────
# [2026-09-10] Le repli etait « $XDG_RUNTIME_DIR sinon /tmp », alors que le
# lecteur (tools/osmo-topzone.py) ne regarde QUE $OSMO_FFT_DIR puis /tmp : sans
# /run/osmo-fft, la sonde ecrivait dans /run/user/1001 un fichier que PERSONNE
# n allait lire, et la banniere restait en demonstration sans qu aucune erreur
# ne le dise. Deux chemins pour un seul fichier, c est un de trop : la regle
# est ici et dans osmo-topzone.py, mot pour mot - le premier repertoire qui
# EXISTE ET OU L ON PEUT ECRIRE, entre $OSMO_FFT_DIR et /tmp.
#
# « ou l on peut ecrire » et pas seulement « qui existe » : /run/osmo-fft est
# cree par osmo-fft-snap.service (RuntimeDirectory, 0775, groupe sudo) mais
# tools/osmo-op.sh a longtemps pu le creer avant lui, en 0755 root:root - la
# sonde de la session ne pouvait alors plus jamais y ecrire.
#
# Et la regle est REEVALUEE A CHAQUE ECRITURE : ce repertoire est un
# RuntimeDirectory, il disparait quand l unite s arrete et revient quand elle
# repart. Une sonde qui aurait resolu son chemin une fois pour toutes ecrirait
# ensuite dans le vide jusqu au prochain redemarrage.
RUN_PREFERE = os.environ.get("OSMO_FFT_DIR", "/run/osmo-fft")


def run_dir():
    for d in (RUN_PREFERE, "/tmp"):
        if os.path.isdir(d) and os.access(d, os.W_OK):
            return d
    return "/tmp"
VTY_HOST = os.environ.get("OSMO_BSC_VTY_HOST", "127.0.0.1")
VTY_PORT = int(os.environ.get("OSMO_BSC_VTY_PORT", "4242"))
# [2026-09-06] LA BANNIERE SUIT UNE BTS PRECISE, ET UNE SEULE. Les huit cases
# sont la trame TDMA d UN porteur : celle de la BTS 0, TRX 0 - la BTS du banc.
# La lecture du VTY ne regardait que « Timeslot N » sans se soucier du reste de
# la ligne : sur un banc multi-operateur (plusieurs BTS declarees dans le meme
# osmo-bsc), un canal etabli sur la BTS 1 allumait la case de la BTS 0. Les
# cases suivaient donc « une » BTS, pas LA BTS.
BTS_NR = int(os.environ.get("OSMO_BTS_NR", "0"))
TRX_NR = int(os.environ.get("OSMO_TRX_NR", "0"))


def cfg_path():
    for p in (os.environ.get("OSMO_BSC_CFG"),
              "/etc/osmocom/osmo-bsc.cfg",
              os.path.join(REPO, "configs/osmo-bsc.cfg")):
        if p and os.path.exists(p):
            return p
    return None


def read_types():
    """[(n, phys_chan_config)] du premier trx du premier bts de la conf."""
    p = cfg_path()
    types = {}
    arfcn = None
    if not p:
        return types, arfcn
    try:
        txt = open(p, errors="replace").read()
    except OSError:
        return types, arfcn
    # Le bloc de LA bts suivie (BTS_NR), pas « la premiere venue » : sur une
    # conf multi-BTS les phys_chan_config different d une BTS a l autre, et les
    # libelles des cases doivent etre ceux du porteur qu on affiche.
    blocks = re.split(r'\n\s*bts\s+(\d+)', txt)
    block = txt
    # re.split avec un groupe rend [avant, "0", bloc0, "1", bloc1, ...]
    for i in range(1, len(blocks) - 1, 2):
        if int(blocks[i]) == BTS_NR:
            block = blocks[i + 1]
            break
    else:
        if len(blocks) > 2:
            block = blocks[2]                # pas de BTS_NR : la premiere
    # arfcn de la premiere trx (on ignore un placeholder de template __ARFCN__)
    m = re.search(r'\n\s*arfcn\s+(\d+)', block)
    if m:
        arfcn = m.group(1)
    # premier trx uniquement
    trx0 = re.split(r'\n\s*trx\s+\d+', block)
    scope = trx0[1] if len(trx0) > 1 else block
    for tm in re.finditer(r'\n\s*timeslot\s+(\d+)\s*\n\s*phys_chan_config\s+(\S+)', scope):
        types[int(tm.group(1))] = tm.group(2)
    return types, arfcn


# ── LA CONNEXION VTY QUI RESTE OUVERTE ──────────────────────────────────────
# [2026-09-06] POURQUOI LES TIMESLOTS AVAIENT UNE SECONDE DE RETARD. Chaque
# tour de sonde OUVRAIT une connexion telnet, envoyait la commande, DORMAIT
# 250 ms en esperant que la reponse soit arrivee, puis fermait. Avec la periode
# d une seconde, un canal qui s etablit pouvait mettre plus d une seconde a
# faire clignoter sa case. On garde donc la connexion, et on lit jusqu au
# prompt du VTY au lieu de dormir : la reponse est traitee des qu elle est
# complete, en general en quelques millisecondes.
_PROMPT = re.compile(rb'[\r\n][A-Za-z0-9_.\-]+(?:\([^)]*\))?[>#]\s*$')


class Vty:
    def __init__(self):
        self.s = None

    def _connect(self):
        try:
            self.s = socket.create_connection((VTY_HOST, VTY_PORT), timeout=1.0)
            self.s.settimeout(1.0)
            self._read_until_prompt()          # la banniere d accueil
            return True
        except OSError:
            self.s = None
            return False

    def close(self):
        if self.s is not None:
            try:
                self.s.close()
            except OSError:
                pass
            self.s = None

    def _read_until_prompt(self, limit=262144):
        buf = b""
        while True:
            try:
                chunk = self.s.recv(4096)
            except socket.timeout:
                break                          # on rend ce qu on a
            except OSError:
                self.close()
                return None
            if not chunk:
                self.close()
                return None
            buf += chunk
            if _PROMPT.search(buf) or len(buf) > limit:
                break
        return buf

    def cmd(self, text):
        """Sortie d une commande, ou None si le VTY n est pas joignable."""
        if self.s is None and not self._connect():
            return None
        try:
            self.s.sendall(text.encode() + b"\r\n")
        except OSError:
            self.close()
            if not self._connect():            # une seule reprise
                return None
            try:
                self.s.sendall(text.encode() + b"\r\n")
            except OSError:
                self.close()
                return None
        out = self._read_until_prompt()
        if out is None:
            return None
        return out.decode(errors="replace")


VTY = Vty()


def vty_lchan():
    """Renvoie (ok, {ts: {'active':bool,'voice':bool}}) depuis le VTY osmo-bsc."""
    act = {}
    text = VTY.cmd("show lchan summary")
    if text is None:
        return False, act
    # lignes type : "BTS 0, TRX 0, Timeslot 2, ... Lchan 0, Type TCH/F, State ESTABLISHED ..."
    for line in text.splitlines():
        m = re.search(r'Timeslot\s+(\d+)', line)
        if not m:
            continue
        # La BTS et le TRX de la ligne : une ligne d une autre BTS (ou d un
        # autre porteur) ne concerne pas cette banniere. Une ligne qui ne les
        # nomme pas est gardee - vieux format de sortie, mieux vaut afficher
        # que perdre l information.
        mb = re.search(r'BTS\s+(\d+)', line)
        mx = re.search(r'TRX\s+(\d+)', line)
        if (mb and int(mb.group(1)) != BTS_NR) or (mx and int(mx.group(1)) != TRX_NR):
            continue
        ts = int(m.group(1))
        d = act.setdefault(ts, {"active": False, "voice": False})
        d["active"] = True
        typ = ""
        mt = re.search(r'Type\s+(\S+)', line)
        if mt:
            typ = mt.group(1).upper()
        state = line.upper()
        established = ("ESTABLISHED" in state or "ACTIVE" in state)
        if "TCH" in typ and established:
            d["voice"] = True
    return True, act


def vty_text(cmd):
    """Sortie brute d une commande VTY osmo-bsc, ou None si injoignable."""
    return VTY.cmd(cmd)


def vty_identity():
    """MCC/MNC, A5, arfcn, band LIVE depuis le VTY (le plus a jour). {} si rien."""
    ident = {}
    net = vty_text("show network")
    if net:
        m = re.search(r'Country Code[:\s]+(\d+).*?Network Code[:\s]+(\d+)', net, re.S)
        if m:
            ident["mcc"], ident["mnc"] = m.group(1), m.group(2)
        m = re.search(r'[Ee]ncryption[:\s]+A5/?(\d)', net)
        if m:
            ident["a5"] = m.group(1)
    bts = vty_text("show bts 0")
    if bts:
        m = re.search(r'\bARFCN[:\s]+(\d+)', bts) or re.search(r'\bC0[:\s]+(\d+)', bts)
        if m:
            ident["arfcn"] = m.group(1)
        m = re.search(r'[Bb]and[:\s]+(\S+)', bts)
        if m:
            ident["band"] = m.group(1)
    return ident


def net_from_cfg():
    """Repli : MCC/MNC/A5/band depuis le fichier de conf, placeholders ignores."""
    p = cfg_path()
    out = {}
    if not p:
        return out
    try:
        txt = open(p, errors="replace").read()
    except OSError:
        return out
    def grab(rx, key):
        m = re.search(rx, txt)
        if m and "__" not in m.group(1):
            out[key] = m.group(1)
    grab(r'\n\s*network country code\s+(\S+)', "mcc")
    grab(r'\n\s*mobile network code\s+(\S+)', "mnc")
    grab(r'\n\s*encryption\s+a5\s+(\S+)', "a5")
    grab(r'\n\s*band\s+(\S+)', "band")
    return out


def build():
    types, cfg_arfcn = read_types()
    if not types:
        # defaut raisonnable si pas de conf : la topologie classique du banc
        types = {0: "CCCH+SDCCH4", 1: "SDCCH8", 2: "TCH/F", 3: "TCH/F",
                 4: "TCH/F", 5: "TCH/F", 6: "TCH/F", 7: "TCH/F"}
    ok, act = vty_lchan()
    ts = []
    for n in range(8):
        a = act.get(n, {})
        ts.append({"n": n, "type": types.get(n, "NONE"),
                   "active": bool(a.get("active")), "voice": bool(a.get("voice"))})
    out = {"bsc": ok, "ts": ts}

    # ── LES VALEURS LIVE : ARFCN / IMSI (MCC-MNC) / A5 / bande ───────────────
    # Le VTY prime (etat reel du reseau qui tourne) ; le fichier de conf est le
    # repli ; le template du depot ne compte pas (placeholders __MCC__ ignores).
    ident = {}
    if cfg_arfcn and "__" not in cfg_arfcn:
        ident["arfcn"] = cfg_arfcn
    ident.update(net_from_cfg())
    if ok:
        ident.update(vty_identity())  # le live ecrase le fichier

    band = ident.get("band", "")
    band_txt = ""
    if band:
        b = str(band).upper().replace("DCS", "DCS ").replace("PCS", "PCS ")
        band_txt = " · " + b
    if ident.get("arfcn"):
        out["arfcn"] = "ARFCN %s%s" % (ident["arfcn"], band_txt)
    if ident.get("mcc") and ident.get("mnc"):
        out["imsi"] = "%s-%s" % (str(ident["mcc"]).zfill(3), str(ident["mnc"]).zfill(2))
    if ident.get("a5"):
        out["a5"] = str(ident["a5"])
    return out


def main():
    # 0.25 s : assez court pour que l allumage d un canal se voie « tout de
    # suite » a l oeil, assez long pour ne pas marteler le VTY d osmo-bsc (4
    # « show lchan summary » par seconde sur une connexion deja ouverte).
    period = float(os.environ.get("OSMO_TS_PERIOD", "0.25"))
    try:
        os.makedirs(RUN_PREFERE, exist_ok=True)
    except OSError:
        pass                                  # run_dir() se rabattra sur /tmp
    tmp = None
    dernier = (None, 0.0)                     # (message, quand) - voir plus bas
    while True:
        try:
            out = build()
            dest = os.path.join(run_dir(), "timeslots.json")
            # ── UN TEMPORAIRE PAR PROCESSUS ─────────────────────────────────
            # [2026-09-10] Deux sondes ont tourne en meme temps - un widget
            # rescape d une session X precedente, que le gardien du bureau
            # comptait pour vivant (cf. osmo-desktop-panel, osmo_vivant) - et
            # elles partageaient « timeslots.json.tmp » : chacune renommait le
            # temporaire de l autre, d ou un journal rempli de
            # « [Errno 2] ... .tmp -> ... .json » quatre fois par seconde. Le
            # PID dans le nom rend l ecriture atomique meme a plusieurs.
            tmp = "%s.%d.tmp" % (dest, os.getpid())
            with open(tmp, "w") as f:
                json.dump(out, f)
            os.replace(tmp, dest)
            tmp = None
        except Exception as e:  # noqa: BLE001 - une sonde ne doit jamais mourir
            # Un temporaire orphelin ne doit pas rester dans /run.
            if tmp:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                tmp = None
            # ── LE MEME DEFAUT NE SE DIT PAS QUATRE FOIS PAR SECONDE ────────
            # Une panne durable (repertoire non accessible) noyait le journal
            # sous des milliers de lignes identiques. On dit la premiere, puis
            # une par minute tant que rien ne change.
            msg = "%s (destination %s)" % (e, run_dir())
            now = time.time()
            if msg != dernier[0] or now - dernier[1] > 60:
                print("[ts-probe] %s" % msg, file=sys.stderr, flush=True)
                dernier = (msg, now)
        time.sleep(period)


if __name__ == "__main__":
    main()

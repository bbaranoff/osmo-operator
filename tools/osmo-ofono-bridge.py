#!/usr/bin/env python3
# osmo-ofono-bridge.py - LE RACCORD MOBILE : oFono (l hote) <-> Waydroid (Android).
#
# POURQUOI CE PONT EXISTE. Waydroid fait tourner un Android en conteneur qui,
# tel qu il sort de l image, n a aucune pile radio : pas de service RIL, et pas
# meme les permissions android.hardware.telephony (mesure sur le banc : sans
# elles, « content://sms » n existe pas). Android ne sait pas parler oFono.
#
# [2026-09-06] CE N EST PAS UNE FATALITE, ET LE PONT N EST PAS LA SEULE VOIE.
# Quectel publie un RIL Android x86_64 pour Android 13 (forums.quectel.com,
# driver V3.6.35 : libril.so, libreference-ril.so, gps.default.so, HAL HIDL
# IRadio@1.1) - l image Waydroid d ici est exactement Android 13 x86_64, et
# tools/osmo-waydroid.sh sait l installer (ril-install). Avec ce RIL et un
# modem Quectel, Android retrouve une VRAIE telephonie : composeur, Messages,
# barres de reseau. Le pont ci-dessous reste ce qu on utilise SANS ce materiel,
# ou avant de l avoir : il porte les EVENEMENTS telephonie du banc jusqu a
# Android et rend les commandes disponibles dans l autre sens :
#
#   SMS entrant (oFono IncomingMessage) -> insere dans l inbox Android
#                                          (content://sms/inbox) + notification
#   Appel entrant (VoiceCallManager)    -> notification Android, decrocher /
#                                          raccrocher depuis l hote
#   SMS sortant                         -> osmo-sms-send <numero> <texte>
#   Appel sortant                       -> osmo-call <numero> | osmo-call hangup
#
# L audio de l appel reste cote hote (oFono/le modem), PAS dans Android : le
# conteneur n a pas de chemin voix. C est un banc de demonstration, pas un
# telephone - on montre le trafic reel du reseau GSM dans l IHM Android.
#
# LA DATA. Elle n est pas encore en service sur le banc (pas de contexte PDP
# etabli). Le chemin est neanmoins CABLE ici et dans tools/osmo-waydroid.sh :
# --data active le contexte oFono et publie l interface obtenue pour que
# « osmo-waydroid data-up » y route le pont waydroid0. Sans --data on ne touche
# a rien.
#
# Reglage par variables d environnement :
#   OSMO_OFONO_MODEM    chemin du modem oFono   (defaut: le premier trouve)
#   OSMO_WAYDROID       binaire waydroid        (defaut: waydroid)
#   OSMO_BRIDGE_SPOOL   file des commandes      (defaut: /run/osmo-ril/spool)
#   OSMO_BRIDGE_STATE   etat publie (json)      (defaut: /run/osmo-ril/state.json)
import argparse
import json
import os
import subprocess
import sys
import time

from gi.repository import Gio, GLib

MODEM = os.environ.get("OSMO_OFONO_MODEM", "")
WAYDROID = os.environ.get("OSMO_WAYDROID", "waydroid")
RUN = os.environ.get("OSMO_RIL_DIR", "/run/osmo-ril")
SPOOL = os.environ.get("OSMO_BRIDGE_SPOOL", os.path.join(RUN, "spool"))
STATE = os.environ.get("OSMO_BRIDGE_STATE", os.path.join(RUN, "state.json"))

OFONO = "org.ofono"
IF_MANAGER = "org.ofono.Manager"
IF_MODEM = "org.ofono.Modem"
IF_SMS = "org.ofono.MessageManager"
IF_VOICE = "org.ofono.VoiceCallManager"
IF_CALL = "org.ofono.VoiceCall"
IF_CONN = "org.ofono.ConnectionManager"
IF_CTX = "org.ofono.ConnectionContext"


def log(*a):
    print("[ril]", *a, flush=True)


# ── LE BUS ──────────────────────────────────────────────────────────────────
class Bus:
    """Le strict necessaire de D-Bus systeme, sans dbus-python (absent de
    l image) : Gio suffit et arrive avec PyGObject, deja la pour l encart."""

    def __init__(self):
        self.c = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

    def call(self, path, iface, method, params=None, timeout=20000):
        return self.c.call_sync(OFONO, path, iface, method, params, None,
                                Gio.DBusCallFlags.NONE, timeout, None)

    def subscribe(self, iface, signal, cb, path=None):
        return self.c.signal_subscribe(OFONO, iface, signal, path, None,
                                       Gio.DBusSignalFlags.NONE, cb)


# ── ANDROID ─────────────────────────────────────────────────────────────────
def wayd(*args, quiet=True):
    """Une commande dans le conteneur Android. On ne remonte JAMAIS une erreur
    ici en exception : le conteneur peut etre arrete, le banc doit continuer a
    tourner et a journaliser les SMS quand meme."""
    cmd = [WAYDROID, "shell", "--"] + list(args)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=25)
        if r.returncode != 0 and not quiet:
            log("waydroid shell:", r.stderr.strip() or r.returncode)
        return r.returncode == 0, (r.stdout or "") + (r.stderr or "")
    except FileNotFoundError:
        return False, "waydroid absent"
    except subprocess.TimeoutExpired:
        return False, "waydroid ne repond pas"


def android_notify(title, body, tag):
    ok, out = wayd("cmd", "notification", "post", "-S", "bigtext",
                   "-t", title, tag, body)
    if not ok:
        log("notification non posee :", out.strip()[:120])


_INBOX_OK = None      # None = pas encore essaye, False = pas de provider sur l image


def android_sms_inbox(sender, text, when_ms):
    """Insere le SMS dans la boite de reception d Android.

    [2026-09-06] CE QUI DEPEND DE L IMAGE. Sur l image VANILLA de Waydroid il n
    y a ni telephonie ni provider - la commande repond « Error while accessing
    provider:sms / Could not find provider: sms » (mesure sur le banc). Avec les
    GAPPS, le provider existe et l insertion aboutit : l appli Messages affiche
    alors le SMS comme un message recu ordinaire. On tente donc l insertion, et
    si le provider manque on le retient pour ne plus payer un aller-retour dans
    le conteneur a chaque SMS. La notification, elle, est posee dans tous les
    cas - c est le canal qui marche partout.
    """
    global _INBOX_OK
    if _INBOX_OK is False:
        return False
    ok, out = wayd("content", "insert", "--uri", "content://sms/inbox",
                   "--bind", "address:s:%s" % sender,
                   "--bind", "body:s:%s" % text,
                   "--bind", "date:l:%d" % when_ms,
                   "--bind", "read:i:0",
                   "--bind", "type:i:1")
    if not ok and "provider" in out.lower():
        _INBOX_OK = False
        log("pas de provider sms dans cette image Android (VANILLA) :"
            " on s en tient aux notifications")
        return False
    if not ok:
        log("inbox Android refusee (on garde la notification) :", out.strip()[:120])
        return False
    _INBOX_OK = True
    return True


# ── L ETAT PUBLIE ───────────────────────────────────────────────────────────
def publish(**kw):
    """Ce que le reste du banc lit : l encart, le Conky, osmo-waydroid."""
    try:
        os.makedirs(RUN, exist_ok=True)
        cur = {}
        if os.path.exists(STATE):
            with open(STATE) as f:
                cur = json.load(f)
        cur.update(kw)
        cur["ts"] = int(time.time())
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cur, f)
        os.replace(tmp, STATE)
    except Exception as e:                       # jamais fatal
        log("etat non publie :", e)


# ── LE PONT ─────────────────────────────────────────────────────────────────
class Bridge:
    def __init__(self, bus, modem, with_data=False):
        self.bus = bus
        self.modem = modem
        self.with_data = with_data
        self.calls = {}

    # -- modem
    def power_on(self):
        for prop in ("Powered", "Online"):
            try:
                self.bus.call(self.modem, IF_MODEM, "SetProperty",
                              GLib.Variant("(sv)", (prop, GLib.Variant("b", True))))
            except GLib.Error as e:
                log("modem %s : %s" % (prop, e.message.split(":")[-1].strip()))

    # -- SMS
    def on_sms(self, _c, _s, _p, _i, _sig, params):
        text = params[0]
        info = params[1]
        sender = info.get("Sender", "?")
        when = info.get("LocalSentTime") or info.get("SentTime") or ""
        log("SMS de %s : %s" % (sender, text))
        android_sms_inbox(sender, text, int(time.time() * 1000))
        android_notify("SMS %s" % sender, text, "osmo-sms-%d" % time.time())
        publish(last_sms={"from": sender, "text": text, "when": when})

    # -- appels
    def on_call_added(self, _c, _s, _p, _i, _sig, params):
        path, props = params[0], params[1]
        num = props.get("LineIdentification", "?")
        state = props.get("State", "?")
        self.calls[path] = num
        log("appel %s (%s) %s" % (num, state, path))
        if state == "incoming":
            android_notify("Appel entrant", "%s\nosmo-call answer / osmo-call hangup" % num,
                           "osmo-call")
        publish(call={"number": num, "state": state})

    def on_call_removed(self, _c, _s, _p, _i, _sig, params):
        path = params[0]
        num = self.calls.pop(path, "?")
        log("appel termine %s" % num)
        wayd("cmd", "notification", "post", "-t", "Appel termine", "osmo-call", str(num))
        publish(call={"number": num, "state": "ended"})

    # -- data (cablee, pas allumee : voir l entete)
    def data_up(self):
        try:
            ctxs = self.bus.call(self.modem, IF_CONN, "GetContexts").unpack()[0]
        except GLib.Error as e:
            log("pas de ConnectionManager :", e.message.split(":")[-1].strip())
            return
        if not ctxs:
            log("aucun contexte PDP declare sur le modem")
            return
        path, props = ctxs[0]
        log("contexte %s (apn=%s)" % (path, props.get("AccessPointName", "?")))
        try:
            self.bus.call(path, IF_CTX, "SetProperty",
                          GLib.Variant("(sv)", ("Active", GLib.Variant("b", True))))
            props = self.bus.call(path, IF_CTX, "GetProperties").unpack()[0]
        except GLib.Error as e:
            log("contexte non active :", e.message.split(":")[-1].strip())
            publish(data={"up": False, "error": e.message})
            return
        st = props.get("Settings", {})
        log("data : if=%s addr=%s gw=%s" % (st.get("Interface"), st.get("Address"),
                                            st.get("Gateway")))
        publish(data={"up": True, "interface": st.get("Interface"),
                      "address": st.get("Address"), "gateway": st.get("Gateway"),
                      "dns": st.get("DomainNameServers", [])})

    # -- les commandes venues de osmo-sms-send / osmo-call
    def command(self, line):
        try:
            verb, rest = (line.split(" ", 1) + [""])[:2]
        except ValueError:
            return
        verb = verb.strip().lower()
        if verb == "sms":
            num, _, text = rest.partition(" ")
            if not num or not text:
                log("usage: sms <numero> <texte>")
                return
            try:
                self.bus.call(self.modem, IF_SMS, "SendMessage",
                              GLib.Variant("(ss)", (num, text)))
                log("SMS envoye a %s" % num)
            except GLib.Error as e:
                log("envoi refuse :", e.message.split(":")[-1].strip())
        elif verb == "call":
            try:
                self.bus.call(self.modem, IF_VOICE, "Dial",
                              GLib.Variant("(ss)", (rest.strip(), "default")))
            except GLib.Error as e:
                log("appel refuse :", e.message.split(":")[-1].strip())
        elif verb == "answer":
            for path in list(self.calls):
                try:
                    self.bus.call(path, IF_CALL, "Answer")
                except GLib.Error as e:
                    log("decrochage refuse :", e.message.split(":")[-1].strip())
        elif verb == "hangup":
            try:
                self.bus.call(self.modem, IF_VOICE, "HangupAll")
            except GLib.Error as e:
                log("raccrochage refuse :", e.message.split(":")[-1].strip())
        elif verb == "data-up":
            self.data_up()
        else:
            log("commande inconnue : %s" % line.strip())

    def watch_spool(self):
        """La file : une ligne = une commande. Un fifo serait plus joli mais un
        simple fichier se lit et s ecrit depuis n importe quel script, y compris
        a la main pendant une seance."""
        os.makedirs(RUN, exist_ok=True)
        if not os.path.exists(SPOOL):
            open(SPOOL, "w").close()
            os.chmod(SPOOL, 0o666)

        def tick():
            try:
                with open(SPOOL, "r+") as f:
                    lines = f.read().splitlines()
                    if lines:
                        f.seek(0)
                        f.truncate()
                for line in lines:
                    if line.strip():
                        self.command(line)
            except Exception as e:
                log("file :", e)
            return True

        GLib.timeout_add(500, tick)


def first_modem(bus):
    modems = bus.call("/", IF_MANAGER, "GetModems").unpack()[0]
    if not modems:
        return ""
    return modems[0][0]


def main():
    ap = argparse.ArgumentParser(description="pont oFono <-> Waydroid (appels + SMS)")
    ap.add_argument("--data", action="store_true",
                    help="active aussi le contexte PDP (pas encore en service sur le banc)")
    ap.add_argument("--once", metavar="CMD",
                    help="passe une commande au pont deja lance (sms/call/answer/hangup)")
    args = ap.parse_args()

    if args.once:
        os.makedirs(RUN, exist_ok=True)
        with open(SPOOL, "a") as f:
            f.write(args.once.rstrip("\n") + "\n")
        return 0

    try:
        bus = Bus()
    except GLib.Error as e:
        print("[ril] bus systeme injoignable : %s" % e, file=sys.stderr)
        return 1

    modem = MODEM or first_modem(bus)
    if not modem:
        print("[ril] aucun modem oFono (ofonod demarre ? modem branche ?)", file=sys.stderr)
        publish(modem=None)
        return 1
    log("modem", modem)
    publish(modem=modem)

    br = Bridge(bus, modem, with_data=args.data)
    br.power_on()
    bus.subscribe(IF_SMS, "IncomingMessage", br.on_sms, path=modem)
    bus.subscribe(IF_SMS, "ImmediateMessage", br.on_sms, path=modem)
    bus.subscribe(IF_VOICE, "CallAdded", br.on_call_added, path=modem)
    bus.subscribe(IF_VOICE, "CallRemoved", br.on_call_removed, path=modem)
    br.watch_spool()
    if args.data:
        br.data_up()

    log("pont en place (SMS + appels ; data %s)" % ("demandee" if args.data else "non cablee"))
    GLib.MainLoop().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())

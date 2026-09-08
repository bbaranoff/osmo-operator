#!/usr/bin/env python3
# osmo-ofono-bridge.py - LES APPELS ET LES SMS DU BANC, EN LIGNE DE COMMANDE.
#
# [2026-09-07] CE QUE CE PROGRAMME N EST PLUS. C etait le « raccord mobile »
# vers Waydroid : il portait les SMS et les appels du banc jusqu a un Android
# en conteneur (notification, insertion dans content://sms/inbox), faute d une
# vraie pile radio de ce cote-la. Waydroid est abandonne - le telephone du banc
# est desormais la VM postmarketOS/Phosh, qui a ModemManager et parle AT au
# modem du banc (tools/osmo-phonesim-banc.py --connect). Tout le code Android a
# donc ete retire ; ce qui reste, et qui servait deja, c est le pilotage d oFono
# depuis un terminal ou une icone :
#
#   osmo-sms-send <numero> <texte>   -> org.ofono.MessageManager.SendMessage
#   osmo-call <numero>|answer|hangup -> org.ofono.VoiceCallManager
#
# Lance sans --once, il TIENT la ligne : il journalise les SMS et les appels que
# le banc lui pousse, publie l etat dans /run/osmo-ril/state.json (l encart et
# le Conky le lisent) et execute les commandes deposees dans la file par les
# deux lanceurs ci-dessus.
#
# LA DATA. Elle n est pas encore en service sur le banc (pas de contexte PDP
# etabli). Le chemin est neanmoins CABLE ici : --data active le contexte oFono
# et publie l interface obtenue. Sans --data on ne touche a rien.
#
# Reglage par variables d environnement :
#   OSMO_OFONO_MODEM    chemin du modem oFono   (defaut: le premier trouve)
#   OSMO_BRIDGE_SPOOL   file des commandes      (defaut: /run/osmo-ril/spool)
#   OSMO_BRIDGE_STATE   etat publie (json)      (defaut: /run/osmo-ril/state.json)
import argparse
import json
import os
import sys
import time

from gi.repository import Gio, GLib

MODEM = os.environ.get("OSMO_OFONO_MODEM", "")
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


# ── L ETAT PUBLIE ───────────────────────────────────────────────────────────
def publish(**kw):
    """Ce que le reste du banc lit : l encart et le Conky."""
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
        publish(last_sms={"from": sender, "text": text, "when": when})

    # -- appels
    def on_call_added(self, _c, _s, _p, _i, _sig, params):
        path, props = params[0], params[1]
        num = props.get("LineIdentification", "?")
        state = props.get("State", "?")
        self.calls[path] = num
        log("appel %s (%s) %s" % (num, state, path))
        publish(call={"number": num, "state": state})

    def on_call_removed(self, _c, _s, _p, _i, _sig, params):
        path = params[0]
        num = self.calls.pop(path, "?")
        log("appel termine %s" % num)
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
    ap = argparse.ArgumentParser(description="appels et SMS du banc par oFono")
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

    log("en ligne (SMS + appels ; data %s)" % ("demandee" if args.data else "non cablee"))
    GLib.MainLoop().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())

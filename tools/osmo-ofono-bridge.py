#!/usr/bin/env python3
# osmo-ofono-bridge.py - CALLS AND SMS OF THE BENCH, FROM THE COMMAND LINE.
#
# Drives oFono from a terminal or an icon. The phone of the bench is the
# postmarketOS/Phosh VM, which has ModemManager and talks AT to the modem of
# the bench (tools/osmo-phonesim-banc.py --connect); this program only handles
# the oFono side:
#
#   osmo-sms-send <number> <text>    -> org.ofono.MessageManager.SendMessage
#   osmo-call <number>|answer|hangup -> org.ofono.VoiceCallManager
#
# Started without --once, it HOLDS the line: it logs the SMS and calls the
# bench pushes to it, publishes the state in /run/osmo-ril/state.json (the
# panel and Conky read it) and executes the commands dropped in the queue by
# the two launchers above.
#
# DATA. Not yet in service on the bench (no PDP context established). The path
# is nevertheless WIRED here: --data activates the oFono context and publishes
# the obtained interface. Without --data nothing is touched.
#
# Settings through environment variables:
#   OSMO_OFONO_MODEM    oFono modem path        (default: the first found)
#   OSMO_BRIDGE_SPOOL   command queue           (default: /run/osmo-ril/spool)
#   OSMO_BRIDGE_STATE   published state (json)  (default: /run/osmo-ril/state.json)
#
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


# ── THE BUS ─────────────────────────────────────────────────────────────────
class Bus:
    """The bare minimum of system D-Bus, without dbus-python (absent from the
    image): Gio is enough and comes with PyGObject, already there for the panel."""

    def __init__(self):
        self.c = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

    def call(self, path, iface, method, params=None, timeout=20000):
        return self.c.call_sync(OFONO, path, iface, method, params, None,
                                Gio.DBusCallFlags.NONE, timeout, None)

    def subscribe(self, iface, signal, cb, path=None):
        return self.c.signal_subscribe(OFONO, iface, signal, path, None,
                                       Gio.DBusSignalFlags.NONE, cb)


# ── THE PUBLISHED STATE ─────────────────────────────────────────────────────
def publish(**kw):
    """What the rest of the bench reads: the panel and Conky."""
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


# ── THE BRIDGE ──────────────────────────────────────────────────────────────
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

        # -- calls
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

        # -- data (wired, not enabled: see the header)
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

        # -- commands coming from osmo-sms-send / osmo-call
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
        """The queue: one line = one command. A fifo would be nicer but a plain
        file can be read and written from any script, including by hand during
        a session."""
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

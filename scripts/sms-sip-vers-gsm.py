#!/usr/bin/env python3
# sms-sip-vers-gsm.py - a SIP MESSAGE of a phone of the node, to a GSM number.
#
#   sms-sip-vers-gsm.py <dest msisdn> <From header in base64> <body in base64>
#
# Called by Asterisk ([sms_inscrits] of extensions_inscrits.conf, written by
# osmo-inscription.py). Asterisk runs as « asterisk » and cannot reach the
# SMSC socket: the SMS is handed to the interop relay (sms-interop-relay.py,
# root, TCP 7890), which resolves the IMSI in the HLR and injects the MT.
# The body comes in base64 so that no character of the SMS ever reaches a
# shell. Standard library only.
import base64, json, os, re, socket, subprocess, sys, syslog, time, urllib.error, urllib.request

RELAY = ("127.0.0.1", 7890)
PORT_INSCRIPTION = int(os.environ.get("OSMO_INSCRIPTION_PORT", "8088"))
EXTERIEUR = re.compile(os.environ.get("OSMO_SMS_EXTERIEUR", r"(\+|00)\d{6,15}|0[1-9]\d{8}"))


SIP = re.compile(os.environ.get("OSMO_SMS_SIP_RE", r"3\d{3}"))
AMI_CONF = "/etc/asterisk/manager.d/osmo.conf"


def vers_sip(dest, src, text):
    """Un autre telephone du noeud (3000-3999) : un SIP MESSAGE a CHACUN de ses
    contacts enregistres (AMI MessageSend). « pjsip:3010 » seul ne vise que le
    premier contact, souvent un ancien enregistrement mort."""
    try:
        out = subprocess.run(["asterisk", "-rx", "pjsip show contacts"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    contacts = re.findall(r"Contact:\s+%s/(sips?:\S+)" % re.escape(dest), out)
    if not contacts:
        return False, "%s n est pas en ligne" % dest
    user, secret = "osmo", ""
    try:
        for line in open(AMI_CONF):
            m = re.match(r"\s*\[(\w+)\]", line)
            if m:
                user = m.group(1)
            m = re.match(r"\s*secret\s*=\s*(\S+)", line)
            if m:
                secret = m.group(1)
    except OSError as e:
        return False, "%s illisible (%s)" % (AMI_CONF, e)
    body = text.replace("\r", " ").replace("\n", " ")
    act = "Action: Login\r\nUsername: %s\r\nSecret: %s\r\nEvents: off\r\n\r\n" % (user, secret)
    for n, c in enumerate(contacts):
        act += ("Action: MessageSend\r\nActionID: sms%d\r\nTo: pjsip:%s/%s\r\n"
                "From: \"%s\" <sip:%s@127.0.0.1>\r\nBody: %s\r\n\r\n" % (n, dest, c, src, src, body))
    act += "Action: Logoff\r\n\r\n"
    try:
        with socket.create_connection(("127.0.0.1", int(os.environ.get("OSMO_AMI_PORT", "5038"))), timeout=5) as s:
            s.sendall(act.encode())
            data, fin = b"", time.time() + 5
            while b"Goodbye" not in data and time.time() < fin:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
    except OSError as e:
        return False, "AMI injoignable (%s)" % e
    ok = data.decode("utf-8", "replace").count("Message successfully") or b"Response: Success\r\nActionID: sms" in data
    return bool(ok), "%d contact(s)" % len(contacts)


def main():
    if len(sys.argv) != 4:
        print(__doc__ or "usage: dest from body_b64", file=sys.stderr)
        return 2
    dest = re.sub(r"\D", "", sys.argv[1])
    # the raw From header, in base64: « "x" <sip:3001@host>;tag=… »
    try:
        de = base64.b64decode(sys.argv[2]).decode("utf-8", "replace")
    except ValueError:
        de = sys.argv[2]
    m = re.search(r"sips?:([^@>;]+)", de)
    src = re.sub(r"[^\d+]", "", m.group(1) if m else de)
    if not src:
        syslog.syslog("sms-sip-vers-gsm: expediteur illisible (%r)" % de[:60])
        return 1
    try:
        text = base64.b64decode(sys.argv[3]).decode("utf-8", "replace")
    except ValueError:
        text = ""
    if not dest or not text:
        syslog.syslog("sms-sip-vers-gsm: destinataire ou texte vide")
        return 1
    if SIP.fullmatch(dest):
        ok, quoi = vers_sip(dest, src, text)
        syslog.syslog("sms-sip-vers-gsm: %s -> %s (SIP) : %s, %s" % (src, dest, "ok" if ok else "ECHEC", quoi))
        return 0 if ok else 1
    # Un numero EXTERIEUR (06..., 00..., +...) : par la SIM du telephone proxy,
    # s il y en a un en ligne (osmo-inscription, /proxy/sortant).
    brut = re.sub(r"[^\d+]", "", sys.argv[1])
    if EXTERIEUR.fullmatch(brut):
        try:
            req = urllib.request.Request("http://127.0.0.1:%d/proxy/sortant" % PORT_INSCRIPTION, method="POST",
                                         data=json.dumps({"vers": brut, "de": src, "texte": text}).encode(),
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=8) as r:
                ok = json.loads(r.read().decode() or "{}").get("ok")
        except urllib.error.HTTPError as e:
            ok = False
            syslog.syslog("sms-sip-vers-gsm: %s -> %s (exterieur) : %s" % (src, brut, e.read().decode()[:120]))
        except (OSError, ValueError) as e:
            ok = False
            syslog.syslog("sms-sip-vers-gsm: service proxy injoignable (%s)" % e)
        if ok:
            syslog.syslog("sms-sip-vers-gsm: %s -> %s : en file pour le telephone proxy" % (src, brut))
        return 0 if ok else 1
    msg = {"type": "mt_sms", "dest_msisdn": dest, "from_number": src, "message_text": text}
    try:
        with socket.create_connection(RELAY, timeout=10) as s:
            s.sendall((json.dumps(msg) + "\n").encode())
            rep = b""
            while b"\n" not in rep:
                chunk = s.recv(4096)
                if not chunk:
                    break
                rep += chunk
        r = json.loads(rep.decode() or "{}")
    except (OSError, ValueError) as e:
        syslog.syslog("sms-sip-vers-gsm: relais injoignable (%s)" % e)
        return 1
    ok = r.get("status") == "ok"
    syslog.syslog("sms-sip-vers-gsm: %s -> %s : %s" % (src, dest, "ok" if ok else r.get("reason", "?")))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

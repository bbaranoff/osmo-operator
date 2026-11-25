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
import base64, json, re, socket, sys, syslog

RELAY = ("127.0.0.1", 7890)


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

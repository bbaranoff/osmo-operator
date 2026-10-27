#!/usr/bin/env python3
"""sms_notify.py - notify the bench modems that an SMS arrives.

The bench osmo-msc runs with « sms-over-gsup »: an SM-RP received from the
radio goes to the HLR (gsm_04_11.c) without ever passing through
gsm340_rx_tpdu(), hence without reaching sms_route_mt_sms() nor the SMPP
server. The « smpp-first » and « route prefix ... 100101 » lines of osmo-msc.cfg
are dead configuration as long as sms-over-gsup is there: an ESME bound on port
2775 receives nothing. And the MT coming back over GSUP is pushed directly to
the subscriber over the radio path - the osmocom-bb mobile gets it, the
software modems (Android through oFono, the postmarketOS VM through its PCI
serial port) do not.

Hence this service path: where the gateway decides on a local delivery, it also
notifies the modems, which present the message to their system in the expected
AT form. The GSUP path is untouched, so the mobile keeps receiving as before -
nothing is duplicated here.

Two uses:
    import       : from sms_notify import notifier      (in the relay)
    command line : sms_notify.py <imsi> <from> <text>   (send-mt-sms.sh)
"""
import json
import os
import socket
import sys

# The modem inboxes. The same program (osmo-phonesim-banc.py) runs twice on
# this bench and therefore needs two ports: the Android modem (listen mode) and
# the VM modem (--connect mode).
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
    """Hand a copy of the SMS to the modems. Best effort: a missing modem is
    not an error (the VM may be off), never raises."""
    charge = (json.dumps({"imsi": imsi, "from": sender, "text": text},
                         ensure_ascii=False) + "\n").encode()
    touches = 0
    for hote, port in cibles():
        try:
            s = socket.create_connection((hote, port), timeout=TIMEOUT)
        except OSError:
            continue                      # no modem on this port: normal
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

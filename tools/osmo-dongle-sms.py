#!/usr/bin/env python3
"""
osmo-dongle-sms.py — SMS par un dongle Huawei sur un vrai réseau (ex. Free, mode auto).
Appelé seul, pour tester le dongle ; en service, c'est osmo-dongle-passerelle.py
qui tient le port AT.

  tools/osmo-dongle-sms.py send 0612345678 "test"
  tools/osmo-dongle-sms.py listen          # affiche les SMS entrants (MT)
  tools/osmo-dongle-sms.py list   # SMS stockés sur la SIM
  tools/osmo-dongle-sms.py --smsc +1234 send ...   # force l'adresse SMSC (AT+CSCA)
"""
import argparse
import re
import sys
import time

from huawei_at import ATError, common_args, open_modem


def setup_sms(m, smsc=None):
    m.cmd("AT+CMGF=1")              # mode texte
    m.try_cmd('AT+CSCS="GSM"')
    m.try_cmd('AT+CPMS="SM","SM","SM"')
    if smsc:
        m.cmd(f'AT+CSCA="{smsc}",145')
    m.try_cmd("AT+CSCA?")           # vide => +CMS ERROR 330 à l'envoi
    m.try_cmd("AT+CSMP=17,167,0,0") # SMS-SUBMIT, validité 24 h, DCS 0


def send(m, dest, text, report=False):
    if report:
        m.cmd("AT+CSMP=49,167,0,0")  # SRR=1 : demande d'accusé (+CDS)
        m.cmd("AT+CNMI=2,1,0,1,0")
    t0 = time.time()
    r = m.cmd_prompt(f'AT+CMGS="{dest}"', text, timeout=60)
    mr = next((re.sub(r"\+CMGS:\s*", "", l) for l in r if l.startswith("+CMGS")), "?")
    print(f"[OK] SMS-SUBMIT accepté, MR={mr}, {time.time() - t0:.2f}s")
    if report:
        u = m.wait_urc(timeout=120)
        print(f"[REPORT] {u}" if u else "[REPORT] aucun accusé reçu en 120 s")


def read_index(m, store, idx, delete):
    r = m.cmd(f"AT+CMGR={idx}", timeout=10)
    if r:
        print(f"[SMS {store}:{idx}] {r[0]}\n    {' '.join(r[1:])}")
    if delete:
        m.try_cmd(f"AT+CMGD={idx}")


def listen(m, delete):
    m.cmd("AT+CNMI=2,1,0,1,0")  # +CMTI: "SM",idx pour chaque MT
    print("[..] en écoute, Ctrl-C pour arrêter")
    while True:
        u = m.wait_urc(timeout=1)
        if not u:
            continue
        if u.startswith("+CMTI"):
            mm = re.match(r'\+CMTI:\s*"(\w+)",(\d+)', u)
            if mm:
                read_index(m, mm.group(1), mm.group(2), delete)
        elif u.startswith("+CMT:"):
            hdr, _, body = u.partition("\n")
            print(f"[SMS direct] {hdr}\n    {body}")
        elif u.startswith("+CDS"):
            print(f"[REPORT] {u}")


def list_all(m):
    for l in m.cmd('AT+CMGL="ALL"', timeout=20):
        print(l)


def main():
    p = common_args(argparse.ArgumentParser(description=__doc__,
                                            formatter_class=argparse.RawDescriptionHelpFormatter))
    p.add_argument("--smsc", help="adresse SMSC à forcer (AT+CSCA)")
    sub = p.add_subparsers(dest="action", required=True)
    s = sub.add_parser("send")
    s.add_argument("dest")
    s.add_argument("text")
    s.add_argument("--report", action="store_true", help="demander un status report")
    l = sub.add_parser("listen")
    l.add_argument("--keep", action="store_true", help="ne pas effacer après lecture")
    sub.add_parser("list")
    args = p.parse_args()

    m = open_modem(args)
    try:
        setup_sms(m, args.smsc)
        if args.action == "send":
            send(m, args.dest, args.text, args.report)
        elif args.action == "listen":
            listen(m, delete=not args.keep)
        else:
            list_all(m)
    except ATError as e:
        print(f"[ERR] {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        pass
    finally:
        m.close()


if __name__ == "__main__":
    main()

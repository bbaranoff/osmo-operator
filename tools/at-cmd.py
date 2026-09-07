#!/usr/bin/env python3
# at-cmd.py - PARLER A LA MAIN AU MODEM AT.
#
# Le pendant de tools/osmo-ril-atmodem.py : celui-ci TIENT le role du modem
# (adosse a oFono), celui-la tient le role du RIL. C est l outil pour verifier,
# sans Android et sans rild, que le modem virtuel repond ce qu il faut - et
# c est aussi ce qu on branche sur un VRAI modem (un EC25 sur /dev/ttyUSB2)
# pour comparer les reponses.
#
#   at-cmd.py                      ouvre une session interactive
#   at-cmd.py AT+CREG?             une commande, la reponse, on sort
#   at-cmd.py -d /dev/ttyUSB2 AT+CSQ   sur un modem physique
#   at-cmd.py --sms 100102 "salut"     le dialogue AT+CMGS complet (avec le ^Z)
#   at-cmd.py --call 100102            ATD100102;
#
# Par defaut on parle au modem virtuel, dont le lien est publie dans
# /run/osmo-ril/at-pty.
import argparse
import os
import sys
import termios
import time

DEV = os.environ.get("OSMO_AT_DEV", "/run/osmo-ril/at-pty")


def open_port(dev, baud=115200):
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY)
    try:                                  # un pty n a pas de vitesse, un tty si
        attrs = termios.tcgetattr(fd)
        attrs[0] = attrs[1] = attrs[3] = 0          # iflag, oflag, lflag : brut
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        speed = getattr(termios, "B%d" % baud, termios.B115200)
        attrs[4] = attrs[5] = speed
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
    except termios.error:
        pass
    return fd


def send(fd, line, wait=1.0, quiet=False):
    """Envoie une commande et rend tout ce qui arrive jusqu au silence."""
    os.write(fd, (line + "\r\n").encode())
    return read_until(fd, wait, quiet)


def read_until(fd, wait, quiet=False):
    """Lit jusqu a OK/ERROR, ou jusqu au bout du delai."""
    import select
    out, end = "", time.time() + wait
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if not r:
            continue
        try:
            chunk = os.read(fd, 4096).decode(errors="replace")
        except OSError:
            break
        if not chunk:
            break
        out += chunk
        if not quiet:
            sys.stdout.write(chunk)
            sys.stdout.flush()
        # Une reponse finale : inutile d attendre le reste du delai.
        for fin in ("\r\nOK\r\n", "\r\nERROR\r\n", "+CME ERROR", "+CMS ERROR"):
            if out.endswith(fin) or fin in out[-40:]:
                return out
    return out


def main():
    ap = argparse.ArgumentParser(description="client AT (modem virtuel ou vrai modem)")
    ap.add_argument("cmd", nargs="*", help="commande AT (sinon : session interactive)")
    ap.add_argument("-d", "--device", default=DEV, help="port (defaut %s)" % DEV)
    ap.add_argument("-t", "--timeout", type=float, default=2.0, help="delai de lecture")
    ap.add_argument("--sms", nargs=2, metavar=("NUMERO", "TEXTE"),
                    help="envoie un SMS : AT+CMGF=1, AT+CMGS, le texte, puis Ctrl-Z")
    ap.add_argument("--call", metavar="NUMERO", help="ATD<numero>;")
    ap.add_argument("--hangup", action="store_true", help="ATH")
    ap.add_argument("--status", action="store_true",
                    help="l etat en une passe : CPIN, CFUN, CREG, COPS, CSQ, CLCC")
    a = ap.parse_args()

    if not os.path.exists(a.device):
        print("[at-cmd] %s introuvable - osmo-ril-atmodem.py tourne ?" % a.device,
              file=sys.stderr)
        return 1
    try:
        fd = open_port(a.device)
    except OSError as e:
        print("[at-cmd] %s : %s" % (a.device, e), file=sys.stderr)
        return 1

    try:
        if a.status:
            for c in ("AT", "AT+CPIN?", "AT+CFUN?", "AT+CREG?", "AT+COPS?",
                      "AT+CSQ", "AT+CLCC"):
                print("--- %s" % c)
                send(fd, c, a.timeout)
            return 0
        if a.sms:
            num, text = a.sms
            send(fd, "AT+CMGF=1", a.timeout)
            print('--- AT+CMGS="%s"' % num)
            os.write(fd, ('AT+CMGS="%s"\r\n' % num).encode())
            read_until(fd, 1.0)                     # l invite « > »
            os.write(fd, (text + "\x1a").encode())  # le texte puis Ctrl-Z
            read_until(fd, max(a.timeout, 5.0))
            return 0
        if a.call:
            send(fd, "ATD%s;" % a.call, a.timeout)
            return 0
        if a.hangup:
            send(fd, "ATH", a.timeout)
            return 0
        if a.cmd:
            send(fd, " ".join(a.cmd), a.timeout)
            return 0

        # session interactive
        print("[at-cmd] %s - une commande par ligne, Ctrl-D pour sortir" % a.device)
        while True:
            try:
                line = input("AT> ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                return 0
            if not line:
                continue
            if line.lower() in ("quit", "exit"):
                return 0
            if not line.upper().startswith("AT"):
                line = "AT" + line
            send(fd, line, a.timeout)
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())

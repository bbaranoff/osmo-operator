#!/usr/bin/env python3
# ss7-console.py - point d'entree de la console SS7 de osmo_egprs.
#
#   ./navigation/ss7-console.py                 le schema navigable (fleches)
#   ./navigation/ss7-console.py --list          l'inventaire, en texte
#   ./navigation/ss7-console.py audit 1.11.1    audit SS7 d'un point code
#   ./navigation/ss7-console.py vty 1 4258 "show gsup-connections"
#   ./navigation/ss7-console.py map sri-sm --pc 1.11.1 msisdn=112233445566
#
# Le mode texte sert aux scripts et aux machines sans terminal ; le mode
# schema est celui du quotidien.

import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
if REPO not in sys.path:
    sys.path.insert(0, REPO)

from navigation import mapops, responder as responder_mod, ss7   # noqa: E402
from navigation.ss7 import Ss7Error                                 # noqa: E402
from navigation import topo as topo_mod, vty as vty_mod             # noqa: E402


def cmd_list(topo, args):
    print("Mode          : %s" % ("docker" if topo.docker else "natif"))
    print("Hub inter-STP : %s:%s (%s)" % (
        topo.hub_ip or "-", topo.hub_port,
        "local" if topo.hub_local else "distant"))
    print("PC libre      : %s" % topo.free_point_code())
    for node in topo.operators:
        print("")
        print("%s (%s)" % (node.title, node.name))
        print("  point code  : %s   M3UA local %s   noeud WAN %s"
              % (node.point_code, node.local_m3ua, node.wan_node or "-"))
        print("  hub vu d'ici: %s:%s  routing key %s"
              % (node.hub_ip, node.hub_port, node.routing_ctx))
        for name, addr in sorted(node.sccp.items()):
            if name.startswith("_self_"):
                continue
            print("  sccp %-14s PC %-8s SSN %s" % (name, addr.get("pc") or "-",
                                                   addr.get("ssn") or "-"))
        if node.services:
            print("  VTY : " + ", ".join("%s:%d" % (s.label, s.port)
                                         for s in node.services))
    return 0


def _client(topo, args):
    local = getattr(args, "from_pc", None) or getattr(args, "global_pc", None) \
        or topo.free_point_code()
    client = ss7.Ss7Client(topo.hub_ip, topo.hub_port, local,
                           log=(lambda t: print("  [m3ua] %s" % t)) if args.verbose
                           else None)
    print("Lien M3UA vers %s:%s ..." % (topo.hub_ip or "?", topo.hub_port))
    try:
        print("  etat : %s" % client.connect())
    except (Ss7Error, OSError) as exc:
        raise SystemExit("  impossible : %s" % exc)
    return client


def cmd_audit(topo, args):
    client = _client(topo, args)
    try:
        for pc in args.point_code:
            print("")
            print(client.audit(pc))
    finally:
        client.close()
    return 0


def cmd_map(topo, args):
    if args.operation not in mapops.BY_KEY:
        print("operation inconnue. Disponibles : %s"
              % ", ".join(sorted(mapops.BY_KEY)))
        return 2
    op = mapops.BY_KEY[args.operation]
    values = op.defaults()
    for item in args.params:
        if "=" not in item:
            print("parametre attendu sous la forme cle=valeur : %s" % item)
            return 2
        key, val = item.split("=", 1)
        values[key] = val
    if not args.pc and not args.gt:
        print("il faut --pc (point code) ou --gt (global title)")
        return 2
    client = _client(topo, args)
    try:
        rep = client.send_map(op, values, args.pc or "0.0.0",
                              args.ssn, args.gt or "",
                              route_on_gt=bool(args.gt and not args.pc),
                              timeout=args.timeout)
        print("")
        print(rep)
    finally:
        client.close()
    return 0 if rep.ok else 1


def cmd_vty(topo, args):
    node = args.node
    if node.isdigit():
        node = "osmo-operator-%s" % node
    pool = vty_mod.VtyPool(docker=topo.docker)
    try:
        print(pool.cmd(node, args.port, " ".join(args.command)))
    except vty_mod.VtyError as exc:
        print("VTY %s:%s injoignable : %s" % (node, args.port, exc),
              file=sys.stderr)
        return 1
    finally:
        pool.close_all()
    return 0


def cmd_serve(topo, args):
    node = args.node
    if node and node.isdigit():
        node = "osmo-operator-%s" % node
    rep = responder_mod.MapResponder(
        topo, args.pc or getattr(args, "global_pc", None) or _second_pc(topo),
        args.ssn, node=node,
        msc_number=args.msc_number, log=lambda t: print("  %s" % t, flush=True))
    print("Repondeur MAP : PC %s, SSN %s, donnees du HLR de %s"
          % (rep.local_pc, rep.local_ssn,
             node or (topo.operators[0].name if topo.operators else "-")))
    try:
        print("Etat du lien : %s" % rep.start())
    except Exception as exc:
        print("  impossible de monter le repondeur : %s" % exc, file=sys.stderr)
        return 2
    print("Ctrl-C pour arreter.")
    try:
        while True:
            time.sleep(0.5)
            if rep.asp is not None and rep.asp.state == "deconnecte" \
                    and not rep.running:
                break
    except KeyboardInterrupt:
        print("")
    finally:
        rep.stop()
    return 0


def _second_pc(topo):
    """Un point code distinct de celui que prend la console emettrice : le
    deuxieme de la liste des libres, jamais un increment (le troisieme membre
    d'un point code ITU tient sur 3 bits, .8 n'existe pas)."""
    libres = topo.free_point_codes(2)
    return libres[1] if len(libres) > 1 else libres[0]


def cmd_ops(topo, args):
    for op in mapops.OPERATIONS:
        print("%-10s %-24s opcode %-3s SSN %-3s" % (op.key, op.name, op.opcode, op.ssn))
        print("           %s" % op.summary)
        print("           parametres : %s"
              % ", ".join(p.key for p in op.params))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Console SS7 de osmo_egprs : schema navigable, VTY et MAP.")
    ap.add_argument("--pc", dest="global_pc",
                    help="point code de la console (avant la sous-commande)")
    ap.add_argument("--no-probe", action="store_true",
                    help="ne pas sonder les VTY a la decouverte (plus rapide)")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="journal du lien M3UA")
    sub = ap.add_subparsers(dest="cmd")

    sub.add_parser("list", help="inventaire du lab, en texte")
    sub.add_parser("ops", help="catalogue des operations MAP")

    p = sub.add_parser("audit", help="audit SS7 (DAUD) d'un ou plusieurs PC")
    p.add_argument("point_code", nargs="+")
    p.add_argument("--from-pc", dest="from_pc",
                   help="point code de la console (defaut : calcule)")

    p = sub.add_parser("map", help="emettre une operation MAP")
    p.add_argument("operation")
    p.add_argument("params", nargs="*", help="cle=valeur (n'importe ou)")
    p.add_argument("--from-pc", dest="from_pc",
                   help="point code de la console (defaut : calcule)")
    p.add_argument("--pc", dest="pc", help="point code destination")
    p.add_argument("--ssn", type=int, help="SSN destination")
    p.add_argument("--gt", help="global title destination")
    p.add_argument("--timeout", type=float, default=6.0)

    p = sub.add_parser("serve", help="repondeur MAP (HLR simule) sur le SS7 du lab")
    p.add_argument("--pc", dest="pc", help="point code du repondeur")
    p.add_argument("--ssn", type=int, default=mapops.SSN_HLR,
                   help="SSN ecoute (6 = HLR)")
    p.add_argument("--node", help="operateur dont le HLR fournit les donnees")
    p.add_argument("--msc-number", help="numero rendu comme noeud de service")

    p = sub.add_parser("vty", help="une commande VTY, sans interface")
    p.add_argument("node", help="numero d'operateur ou nom de conteneur")
    p.add_argument("port", type=int)
    p.add_argument("command", nargs="+")

    args, extra = ap.parse_known_args(argv)
    # "map sri-sm --pc 1.11.61 msisdn=100101" : argparse laisse les positionnels
    # qui suivent une option de cote. On les recupere plutot que de les perdre.
    leftovers = [x for x in extra if "=" in x and not x.startswith("-")]
    unknown = [x for x in extra if x not in leftovers]
    if unknown:
        ap.error("arguments inconnus : %s" % " ".join(unknown))
    if leftovers:
        if getattr(args, "cmd", None) == "map":
            args.params = list(getattr(args, "params", [])) + leftovers
        else:
            ap.error("arguments inconnus : %s" % " ".join(leftovers))
    if not hasattr(args, "pc"):
        args.pc = None

    probe = not args.no_probe and args.cmd in (None, "list")
    topo = topo_mod.discover(probe=probe)
    if topo.errors:
        for err in topo.errors:
            print("attention : %s" % err, file=sys.stderr)

    if args.cmd == "list":
        return cmd_list(topo, args)
    if args.cmd == "ops":
        return cmd_ops(topo, args)
    if args.cmd == "audit":
        return cmd_audit(topo, args)
    if args.cmd == "map":
        return cmd_map(topo, args)
    if args.cmd == "serve":
        return cmd_serve(topo, args)
    if args.cmd == "vty":
        return cmd_vty(topo, args)

    if not sys.stdout.isatty():
        print("pas de terminal : utilisez 'list', 'audit', 'map' ou 'vty'.",
              file=sys.stderr)
        return 2
    from navigation import tui
    tui.main(topo)
    return 0


if __name__ == "__main__":
    sys.exit(main())

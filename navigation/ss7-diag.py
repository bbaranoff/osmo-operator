#!/usr/bin/env python3
# ss7-diag.py - diagnostic SS7 complet du lab, depuis l'hote.
#
# Le script se situe TOUT SEUL : il deduit le depot de son propre chemin, et
# la topologie des conteneurs et de leurs configurations. Aucun argument n'est
# necessaire.
#
#   ./navigation/ss7-diag.py               diagnostic complet
#   ./navigation/ss7-diag.py --rapide      sans les tests M3UA/MAP
#   ./navigation/ss7-diag.py --log FICHIER copie integrale dans un fichier
#
# Ce qui est verifie, dans l'ordre ou une panne se lit :
#   1. l'environnement (docker, SCTP, modules) ;
#   2. la topologie heritee des configurations ;
#   3. par operateur : STP, MSC, BSC, HLR - VTY, AS, ASP, routes, SSN ;
#   4. le lien vers l'inter-STP : association SCTP, etat de l'AS ;
#   5. la console comme ASP M3UA : ASPUP, RKM, ASPAC, puis audit de chaque
#      point code connu ;
#   6. un aller-retour MAP reel (sendRoutingInfoForSM) a travers le hub.
#
# Code de sortie = nombre d'echecs.

import argparse
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
if REPO not in sys.path:
    sys.path.insert(0, REPO)

from navigation import mapops, responder as responder_mod, sccp, ss7   # noqa: E402
from navigation import topo as topo_mod, vty as vty_mod                # noqa: E402

G, Y, R, C, B, N = ("\033[0;32m", "\033[1;33m", "\033[0;31m", "\033[0;36m",
                    "\033[1m", "\033[0m")

STATE = {"pass": 0, "warn": 0, "fail": 0, "skip": 0, "log": None}


def out(text=""):
    print(text, flush=True)
    if STATE["log"]:
        STATE["log"].write(re.sub(r"\033\[[0-9;]*m", "", text) + "\n")
        STATE["log"].flush()


def section(title):
    out("")
    out("%s%s%s" % (B, title, N))
    out("-" * 70)


def ok(text):
    STATE["pass"] += 1
    out("  %s✓%s %s" % (G, N, text))


def warn(text):
    STATE["warn"] += 1
    out("  %s!%s %s" % (Y, N, text))


def fail(text):
    STATE["fail"] += 1
    out("  %s✗%s %s" % (R, N, text))


def skip(text):
    STATE["skip"] += 1
    out("  %s-%s %s" % (Y, N, text))


def info(text):
    out("    %s" % text)


def sh(cmd):
    try:
        p = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=30)
        return p.stdout.decode("utf-8", "replace")
    except Exception:
        return ""


# ── 1. environnement ─────────────────────────────────────────────────────────
def check_env():
    section("1. ENVIRONNEMENT")
    if sh("docker ps --format '{{.Names}}'").strip():
        ok("docker repond")
    else:
        warn("docker ne rend aucun conteneur - mode natif, ou docker arrete")
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM, 132)
        s.close()
        ok("SCTP disponible sur l'hote (IPPROTO_SCTP)")
    except Exception as exc:
        fail("SCTP indisponible : %s - le lien M3UA sera impossible" % exc)
        info("modprobe sctp")
    out("    depot   : %s" % REPO)
    out("    python  : %s" % sys.version.split()[0])


# ── 2. topologie ─────────────────────────────────────────────────────────────
def check_topo(topo):
    section("2. TOPOLOGIE (heritee des configurations)")
    if not topo.operators:
        fail("aucun operateur trouve")
        return
    ok("%d operateur(s) : %s" % (len(topo.operators),
                                 ", ".join(n.name for n in topo.operators)))
    if topo.hub_ip:
        ok("inter-STP : %s:%s (%s)" % (topo.hub_ip, topo.hub_port,
                                       "local" if topo.hub_local else "distant"))
    else:
        fail("aucun inter-STP connu - ni conteneur local, ni OSMO_HUB_IP")
    vus = {}
    for node in topo.operators:
        if not node.point_code:
            fail("%s : aucun point code lu dans osmo-stp.cfg" % node.name)
            continue
        if node.point_code in vus:
            fail("%s et %s partagent le point code %s - collision SS7"
                 % (node.name, vus[node.point_code], node.point_code))
        else:
            vus[node.point_code] = node.name
            ok("%s : PC %s, routing key %s, noeud WAN %s"
               % (node.title, node.point_code, node.routing_ctx,
                  node.wan_node or "-"))
        for nom, addr in sorted(node.sccp.items()):
            if nom.startswith("_self_") or not addr.get("pc"):
                continue
            info("%-10s %-10s PC %-8s SSN %s" % (node.title, nom, addr["pc"],
                                                 addr.get("ssn")))
        # Format ITU 3-8-3 : le troisieme membre tient sur 3 bits.
        membres = node.point_code.split(".")
        if len(membres) == 3:
            a, b, c = (int(x) for x in membres)
            if a > 7 or b > 255 or c > 7:
                fail("%s : point code %s hors format ITU 3-8-3 (max 7.255.7)"
                     % (node.title, node.point_code))
    if topo.docker:
        libres = topo.free_point_codes(2)
        info("point codes libres pour la console : %s" % ", ".join(libres))


# ── 3. les demons, par operateur ─────────────────────────────────────────────
def check_nodes(topo, pool):
    for node in topo.operators:
        section("3. %s (%s)" % (node.title, node.name))
        stp = node.service("OsmoSTP") or type("S", (), {"port": 4239})()
        try:
            as_out = pool.cmd(node.name, stp.port, "show cs7 instance 0 as all")
        except vty_mod.VtyError as exc:
            fail("VTY STP (%s) inaccessible : %s" % (stp.port, exc))
            continue
        actifs = len(re.findall(r"AS_ACTIVE", as_out))
        inter = re.search(r"as-inter\s+(\S+)", as_out)
        if inter and inter.group(1) == "AS_ACTIVE":
            ok("as-inter -> hub : ACTIVE")
        elif inter:
            fail("as-inter : %s" % inter.group(1))
        else:
            warn("aucun as-inter declare (pas de lien vers un hub)")
        if actifs >= 2:
            ok("AS actifs sur le STP local : %d" % actifs)
        else:
            warn("AS actifs sur le STP local : %d" % actifs)

        asp_out = pool.cmd(node.name, stp.port, "show cs7 instance 0 asp")
        asp_actifs = len(re.findall(r"ASP_ACTIVE", asp_out))
        (ok if asp_actifs >= 2 else fail)("ASP actifs : %d" % asp_actifs)

        route_out = pool.cmd(node.name, stp.port, "show cs7 instance 0 route")
        if re.search(r"0\.0\.0/0.*avail", route_out):
            ok("route par defaut vers l'inter-STP : presente et avail")
        else:
            fail("route par defaut vers l'inter-STP absente ou indisponible")
        # PROHIB : on distingue une vraie panne (un noeud DU LAB devenu
        # inaccessible) d'une route dynamique laissee par un point code de
        # passage - une console SS7 arretee, un noeud WAN eteint. Les
        # confondre ferait crier au feu a chaque fois qu'on ferme la console.
        connus = set()
        for autre in topo.operators:
            if autre.point_code:
                connus.add(autre.point_code)
            for a in autre.sccp.values():
                if a.get("pc"):
                    connus.add(a["pc"])
        durs, mous = [], []
        for ligne in route_out.split("\n"):
            if "PROHIB" not in ligne:
                continue
            dest = ligne.split("/")[0].strip()
            (durs if dest in connus else mous).append(dest)
        if durs:
            fail("routes PROHIB vers des noeuds du lab : %s" % ", ".join(durs))
        elif mous:
            warn("%d route(s) PROHIB, toutes vers des point codes de passage : %s"
                 % (len(mous), ", ".join(mous)))
            info("dynamiques : elles repasseront avail des que ces PC reviendront")
        else:
            ok("aucune route PROHIB")

        users = pool.cmd(node.name, stp.port, "show cs7 instance 0 users")
        for ssn, nom in ((254, "BSSAP"), (6, "HLR"), (8, "MSC")):
            if re.search(r"\b%d\b" % ssn, users):
                info("SSN %s (%s) enregistre sur le STP" % (ssn, nom))

        # Sans sondage des VTY (--no-probe), on retombe sur les ports usuels
        # plutot que d'annoncer un MSC ou un HLR "absent" qui tourne tres bien.
        def service(daemon, defaut):
            svc = node.service(daemon)
            if svc:
                return svc
            return type("S", (), {"port": defaut, "label": daemon})()

        try:
            msc = service("OsmoMSC", 4254)
            cache = pool.cmd(node.name, msc.port, "show subscriber cache")
            n = len(re.findall(r"IMSI", cache))
            ok("MSC : VTY %s, %d abonne(s) en VLR" % (msc.port, n))
        except vty_mod.VtyError as exc:
            fail("MSC : VTY injoignable (%s)" % exc)

        try:
            hlr = service("OsmoHLR", 4258)
            subs = pool.cmd(node.name, hlr.port, "show subscribers all")
            n = len(re.findall(r"^\s*\d+\s+\d+", subs, re.M))
            gsup = pool.cmd(node.name, hlr.port, "show gsup-connections")
            vlr = "VLR" in gsup
            (ok if n else warn)("HLR : %d abonne(s) provisionne(s)" % n)
            (ok if vlr else fail)("HLR : VLR %s en GSUP"
                                  % ("connecte" if vlr else "absent"))
        except vty_mod.VtyError as exc:
            fail("HLR : VTY injoignable (%s)" % exc)

        try:
            bsc = service("OsmoBSC", 4242)
            bts = pool.cmd(node.name, bsc.port, "show bts")
            up = len(re.findall(r"(?i)OML.*Link.*connected|BTS is in service", bts))
            info("BSC : VTY %s%s" % (bsc.port,
                                     ", %d BTS en service" % up if up else ""))
        except vty_mod.VtyError as exc:
            warn("BSC : VTY injoignable (%s)" % exc)


# ── 4. lien vers le hub, vu des noeuds ───────────────────────────────────────
def check_hub_link(topo):
    section("4. LIEN VERS L'INTER-STP (vu des noeuds)")
    if not topo.hub_ip:
        skip("pas de hub connu")
        return
    port = topo.hub_port
    for node in topo.operators:
        out_ = sh("docker exec %s ss -an --sctp 2>/dev/null" % node.name) \
            if topo.docker else sh("ss -an --sctp")
        if not out_.strip():
            skip("%s : ss --sctp indisponible" % node.title)
            continue
        motif = re.escape("%s:%d" % (topo.hub_ip, port))
        if re.search(r"ESTAB.*%s" % motif, out_):
            ok("%s : association SCTP ETABLIE vers %s:%d"
               % (node.title, topo.hub_ip, port))
        else:
            fail("%s : aucune association SCTP vers %s:%d - l'ASP est DOWN"
                 % (node.title, topo.hub_ip, port))


# ── 5. la console comme ASP ──────────────────────────────────────────────────
def check_console_asp(topo):
    section("5. LA CONSOLE COMME ASP M3UA")
    if not topo.hub_ip:
        skip("pas de hub : aucun lien a monter")
        return None
    pc = topo.free_point_codes(2)[0]
    client = ss7.Ss7Client(topo.hub_ip, topo.hub_port, pc)
    try:
        etat = client.connect()
    except Exception as exc:
        fail("attachement impossible : %s" % exc)
        info("verifiez que %s:%s accepte les ASP dynamiques" % (topo.hub_ip,
                                                                topo.hub_port))
        return None
    if etat == "ASP_ACTIVE":
        ok("ASP actif sur le hub : PC %s, routing context %s"
           % (pc, client.asp.routing_ctx))
    else:
        fail("ASP dans l'etat %s" % etat)
        return client

    cibles = []
    for node in topo.operators:
        if node.point_code:
            cibles.append((node.title + " STP", node.point_code))
        for nom, addr in sorted(node.sccp.items()):
            if not nom.startswith("_self_") and addr.get("pc"):
                cibles.append(("%s %s" % (node.title, nom), addr["pc"]))
    vus = set()
    for label, cible in cibles:
        if cible in vus:
            continue
        vus.add(cible)
        rep = client.audit(cible)
        if rep.ok:
            ok("DAUD %-10s %-8s : joignable a travers le hub" % (label, cible))
        else:
            warn("DAUD %-10s %-8s : %s" % (label, cible, rep.lines[0]))
    return client


# ── 6. aller-retour MAP reel ─────────────────────────────────────────────────
def check_map(topo, client, pool):
    section("6. ALLER-RETOUR MAP (sendRoutingInfoForSM)")
    if client is None:
        skip("pas de lien M3UA")
        return
    if not topo.operators:
        skip("aucun operateur")
        return
    pc_rep = topo.free_point_codes(2)[1]
    node = topo.operators[0]
    rep = responder_mod.MapResponder(topo, pc_rep, mapops.SSN_HLR, node=node.name)
    try:
        rep.start()
    except Exception as exc:
        fail("repondeur MAP impossible a demarrer : %s" % exc)
        return
    abonnes = rep.subscribers()
    if not abonnes:
        skip("aucun abonne dans le HLR de %s : rien a interroger" % node.name)
        rep.stop()
        return
    ok("repondeur MAP en place : PC %s, SSN 6, %d abonne(s) du HLR reel"
       % (pc_rep, len(abonnes)))
    cible = abonnes[0]
    info("interrogation du MSISDN %s (IMSI attendu %s)" % (cible.msisdn, cible.imsi))
    time.sleep(0.5)
    rapport = client.send_map("sri-sm", {"msisdn": cible.msisdn,
                                         "sc_addr": cible.msisdn,
                                         "sm_rp_pri": "1"},
                              dest_pc=pc_rep, timeout=5.0)
    trouve = dict(rapport.result).get("IMSI", "")
    if trouve == cible.imsi:
        ok("MAP complet : SRI-SM -> IMSI %s (le TCAP a bien traverse le hub)"
           % trouve)
    elif rapport.ok:
        warn("reponse MAP recue, mais IMSI inattendu : %s" % trouve)
    else:
        fail("aucune reponse MAP exploitable")
        for ligne in rapport.lines[-6:]:
            info(ligne)
    rep.stop()


def main():
    ap = argparse.ArgumentParser(description="Diagnostic SS7 complet du lab.")
    ap.add_argument("--rapide", action="store_true",
                    help="sauter les tests M3UA et MAP")
    ap.add_argument("--log", help="ecrire aussi le rapport dans ce fichier")
    ap.add_argument("--no-probe", action="store_true",
                    help="ne pas sonder les ports VTY")
    args = ap.parse_args()

    if args.log:
        STATE["log"] = open(args.log, "w")

    out("")
    out("%s============================================================%s" % (C, N))
    out("%s  DIAGNOSTIC SS7 - osmo_egprs - %s%s"
        % (C, time.strftime("%Y-%m-%d %H:%M:%S"), N))
    out("%s============================================================%s" % (C, N))

    check_env()
    topo = topo_mod.discover(probe=not args.no_probe)
    check_topo(topo)
    pool = vty_mod.VtyPool(docker=topo.docker)
    client = None
    try:
        check_nodes(topo, pool)
        check_hub_link(topo)
        if not args.rapide:
            client = check_console_asp(topo)
            check_map(topo, client, pool)
        else:
            section("5-6. M3UA ET MAP")
            skip("ignores (--rapide)")
    finally:
        pool.close_all()
        if client:
            client.close()

    section("RESUME")
    out("  %s%d ok%s   %s%d avertissement(s)%s   %s%d echec(s)%s   %d ignore(s)"
        % (G, STATE["pass"], N, Y, STATE["warn"], N, R, STATE["fail"], N,
           STATE["skip"]))
    if STATE["fail"] == 0 and STATE["warn"] == 0:
        out("  %sLe SS7 du lab est sain de bout en bout.%s" % (G, N))
    elif STATE["fail"] == 0:
        out("  %sPas de panne, mais des points a surveiller.%s" % (Y, N))
    else:
        out("  %sDes elements du SS7 sont en panne (voir ci-dessus).%s" % (R, N))
    out("")
    if STATE["log"]:
        STATE["log"].close()
    return STATE["fail"]


if __name__ == "__main__":
    sys.exit(main())

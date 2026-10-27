# ss7.py - the layer that ties everything together: M3UA + SCCP + TCAP + MAP.
#
# This is the object the console and the scripts use: given an operation from
# the catalogue and a destination (point code, SSN, GT), it builds the UDT,
# sends it on the M3UA link and returns a readable report of what comes back
# - MAP result, MAP error, or SCCP refusal.

import os
import random
import time

from . import m3ua
from . import mapops
from . import sccp
from . import tcap


class Ss7Error(Exception):
    pass


class Report(object):
    def __init__(self):
        self.lines = []
        self.ok = False
        self.raw_tx = b""
        self.raw_rx = b""
        self.result = []

    def add(self, text):
        self.lines.append(text)

    def __str__(self):
        return "\n".join(self.lines)


class Ss7Client(object):
    def __init__(self, hub_ip, hub_port=2908, local_pc="1.11.60",
                 local_ssn=mapops.SSN_MSC, local_gt="", log=None):
        self.hub_ip = hub_ip
        self.hub_port = int(hub_port)
        self.local_pc = local_pc
        self.local_ssn = local_ssn
        self.local_gt = local_gt
        self.asp = None
        self.invoke_id = 1
        self.log_cb = log

    # ── link ─────────────────────────────────────────────────────────────
    @property
    def connected(self):
        return self.asp is not None and self.asp.state == "ASP_ACTIVE"

    @property
    def events(self):
        return self.asp.events if self.asp else []

    def connect(self, register=True):
        if not self.hub_ip:
            raise Ss7Error(
                "aucun inter-STP connu : ni conteneur osmo-inter-stp, ni "
                "OSMO_HUB_IP dans les noeuds. Demarrez le lab, ou donnez "
                "l'adresse du hub avec --hub-ip.")
        self.asp = m3ua.Asp(self.hub_ip, self.hub_port, log=self.log_cb)
        self.asp.bring_up(sccp.pc_to_int(self.local_pc), register=register)
        return self.asp.state

    def fresh(self):
        """A young link before every exchange.

        The lab inter-STP serves an association coming from the host for
        about thirty seconds; past that, messages go nowhere. Rather than
        showing a false "no answer", the link is brought up again - invisible
        for the caller, and the point code does not change."""
        if self.asp is None:
            self.connect()
            return True
        return self.asp.renew()

    def close(self):
        if self.asp:
            self.asp.close()
        self.asp = None

    # ── destination audit (the SS7 "ping") ─────────────────────────────
    def audit(self, point_code, timeout=3.0):
        """DAUD: the STP answers DAVA (reachable) or DUNA (unavailable)."""
        rep = Report()
        if not self.asp:
            rep.add("pas de lien M3UA")
            return rep
        self.fresh()
        val = sccp.pc_to_int(point_code)
        body = m3ua.param(m3ua.P_AFFECTED_PC, bytes([0]) + val.to_bytes(3, "big"))
        if self.asp.routing_ctx is not None:
            body += m3ua.param(m3ua.P_ROUTING_CTX,
                               self.asp.routing_ctx.to_bytes(4, "big"))
        self.asp.send_msg(m3ua.CLS_SSNM, m3ua.DAUD, body)
        msg = self.asp.wait_ctrl({(m3ua.CLS_SSNM, m3ua.DAVA),
                                  (m3ua.CLS_SSNM, m3ua.DUNA),
                                  (m3ua.CLS_SSNM, m3ua.SCON),
                                  (m3ua.CLS_MGMT, m3ua.ERR)}, timeout)
        if msg is None:
            rep.add("DAUD %s : aucune reponse du STP" % point_code)
            return rep
        if msg.typ == m3ua.DAVA and msg.cls == m3ua.CLS_SSNM:
            rep.ok = True
            rep.add("DAVA - le point code %s est JOIGNABLE via le hub" % point_code)
        elif msg.typ == m3ua.DUNA:
            rep.add("DUNA - le point code %s est INACCESSIBLE" % point_code)
        elif msg.typ == m3ua.SCON:
            rep.add("SCON - congestion vers %s" % point_code)
        else:
            rep.add("reponse inattendue : %s" % msg.name)
        return rep

    # ── sending a MAP operation ─────────────────────────────────────────
    def send_map(self, op, values, dest_pc, dest_ssn=None, dest_gt="",
                 route_on_gt=False, timeout=6.0, essais=2):
        if isinstance(op, str):
            op = mapops.BY_KEY[op]
        rep = Report()
        if not self.asp:
            rep.add("pas de lien M3UA - connectez d'abord la console au STP")
            return rep
        self.fresh()

        ssn = int(dest_ssn if dest_ssn is not None else op.ssn)
        param_ber = op.encode(values)
        opcode = int(values.get("opcode", op.opcode) or op.opcode)
        ac = values.get("ac") or op.ac

        otid = os.urandom(4)
        comp = tcap.invoke(self.invoke_id, opcode, param_ber)
        self.invoke_id = (self.invoke_id % 127) + 1
        payload = tcap.begin(otid, comp, ac or None)

        called = sccp.Address(pc=None if route_on_gt else dest_pc, ssn=ssn,
                              gt=dest_gt or None, route_on_ssn=not route_on_gt)
        calling = sccp.Address(pc=self.local_pc, ssn=self.local_ssn,
                               gt=self.local_gt or None,
                               route_on_ssn=not self.local_gt)
        udt = sccp.udt(called, calling, payload)
        rep.raw_tx = udt

        rep.add("Emission")
        rep.add("  operation   : %s (opcode %d)" % (op.name, opcode))
        if ac:
            rep.add("  contexte    : %s" % ac)
        rep.add("  destination : %s" % called)
        rep.add("  origine     : %s" % calling)
        rep.add("  TCAP begin  : otid %s, %d octets" % (otid.hex(), len(payload)))

        self.asp.send_data(sccp.pc_to_int(self.local_pc),
                           sccp.pc_to_int(dest_pc if not route_on_gt else dest_pc),
                           udt)

        deadline = time.time() + timeout
        while time.time() < deadline:
            data = self.asp.recv_data(timeout=max(0.2, deadline - time.time()))
            if data is None:
                continue
            dec = sccp.decode(data["data"])
            rep.raw_rx = data["data"]
            if dec is None:
                continue
            rep.add("")
            rep.add("Reponse recue de PC %s" % m3ua._pc(data["opc"]))
            rep.add("  SCCP : %s" % dec)
            if dec.kind.endswith("UDTS"):
                rep.add("  -> le reseau refuse : %s" % dec.cause_text)
                return rep
            msg = tcap.parse(dec.data)
            if msg is None:
                rep.add("  charge non TCAP : %s" % dec.data.hex())
                return rep
            rep.add("  TCAP : %s" % msg)
            for comp in msg.components:
                if comp.kind == "returnResultLast":
                    rep.ok = True
                    rep.add("  resultat (opcode %s) :" % comp.opcode)
                    for label, value in op.decoder(comp.parameter):
                        rep.add("     %-28s %s" % (label, value))
                        rep.result.append((label, value))
                elif comp.kind == "returnError":
                    rep.add("  ERREUR MAP %s : %s" %
                            (comp.error, mapops.error_name(comp.error)))
                elif comp.kind == "reject":
                    rep.add("  REJECT TCAP : %s" %
                            (comp.parameter.value.hex() if comp.parameter else ""))
                else:
                    rep.add("  composant %s" % comp.kind)
            if msg.kind == "abort":
                rep.add("  ABORT TCAP : %s" % msg.abort_reason)
            return rep

        if essais > 1:
            # The link to the hub only lives a few seconds: a send may fall
            # while one of the two ends renews its association. A second try,
            # on a fresh link, tells "nobody listens" from "bad timing".
            rep.add("")
            rep.add("Pas de reponse - second essai sur un lien neuf ...")
            self.asp.renew(max_age=0)
            suite = self.send_map(op, values, dest_pc, dest_ssn, dest_gt,
                                  route_on_gt, timeout, essais=essais - 1)
            rep.lines.extend([""] + suite.lines)
            rep.ok = suite.ok
            rep.result = suite.result
            return rep
        rep.add("")
        rep.add("Aucune reponse au bout de %.0f s." % timeout)
        rep.add("Sur ce lab, un silence signifie en general qu'aucun demon")
        rep.add("n'ecoute ce SSN : Osmocom parle GSUP entre MSC et HLR, et")
        rep.add("reserve le SCCP a l'interface A (SSN 254).")
        return rep


def default_client(topo, local_pc=None, log=None):
    """Build a client from the discovered topology: hub, port and free point
    code all come from the lab configuration."""
    pc = local_pc or topo.free_point_code()
    gt = ""
    return Ss7Client(topo.hub_ip or "127.0.0.1", topo.hub_port, pc,
                     local_gt=gt, log=log)

# responder.py - the console's MAP responder.
#
# Why: in this lab, Osmocom makes MSC and HLR talk GSUP, not MAP. A
# sendRoutingInfoForSM sent to the real HLR therefore finds nobody listening,
# and SS7 looks silent even though it routes perfectly.
#
# The responder fills that gap: it attaches to the same inter-STP, with its
# own point code and SSN 6 (HLR), and answers MAP interrogations with data
# taken from the REAL HLR through its VTY. The path itself is real: the
# message crosses the SS7 hub like any traffic between operators.
#
#   Terminal A:  ./navigation/ss7-console.py serve --pc 1.11.61
#   Terminal B:  ./navigation/ss7-console.py map sri-sm --pc 1.11.61 \
#                    msisdn=100101 sc_addr=600999

import threading
import time

from . import ber
from . import m3ua
from . import mapops
from . import sccp
from . import tcap
from . import vty as vty_mod

OP_SRI_SM = 45
OP_SRI = 22
OP_SEND_IMSI = 58
OP_SAI = 56
OP_ATI = 71


class Subscriber(object):
    def __init__(self, msisdn, imsi, imei="", nam=""):
        self.msisdn = msisdn
        self.imsi = imsi
        self.imei = imei
        self.nam = nam


class MapResponder(object):
    def __init__(self, topo, local_pc, local_ssn=mapops.SSN_HLR, node=None,
                 hlr_port=4258, msc_number=None, log=None):
        self.topo = topo
        self.local_pc = local_pc
        self.local_ssn = local_ssn
        self.node = node or (topo.operators[0].name if topo.operators else None)
        self.hlr_port = hlr_port
        self.msc_number = msc_number
        self.pool = vty_mod.VtyPool(docker=topo.docker)
        self.asp = None
        self.running = False
        self.thread = None
        self.events = []
        self._log = log
        self._cache = ([], 0.0)

    def log(self, text):
        line = "%s %s" % (time.strftime("%H:%M:%S"), text)
        self.events.append(line)
        del self.events[:-400]
        if self._log:
            self._log(line)

    # ── subscriber data, read from the real HLR ──────────────────────────
    def subscribers(self, max_age=10.0):
        rows, stamp = self._cache
        if rows and (time.time() - stamp) < max_age:
            return rows
        rows = []
        if self.node:
            try:
                out = self.pool.cmd(self.node, self.hlr_port, "show subscribers all")
            except vty_mod.VtyError as exc:
                self.log("HLR injoignable : %s" % exc)
                out = ""
            for line in out.split("\n"):
                parts = line.split()
                if len(parts) >= 3 and parts[0].isdigit() and parts[2].isdigit():
                    rows.append(Subscriber(parts[1], parts[2],
                                           parts[3] if len(parts) > 3 else "",
                                           parts[4] if len(parts) > 4 else ""))
        self._cache = (rows, time.time())
        return rows

    def find(self, msisdn=None, imsi=None):
        for sub in self.subscribers():
            if msisdn and sub.msisdn == str(msisdn).lstrip("+"):
                return sub
            if imsi and sub.imsi == str(imsi):
                return sub
        return None

    # ── link ─────────────────────────────────────────────────────────────
    def start(self):
        self.asp = m3ua.Asp(self.topo.hub_ip, self.topo.hub_port, log=self.log)
        self.asp.bring_up(sccp.pc_to_int(self.local_pc))
        self.running = True
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()
        # The hub only serves an association coming from the host for a few
        # seconds: without this renewal the responder would be unreachable
        # after about ten seconds, with nothing to show for it.
        self.keeper = threading.Thread(target=self._keep_alive, daemon=True)
        self.keeper.start()
        self.log("repondeur MAP actif : PC %s, SSN %d, %d abonne(s) connus"
                 % (self.local_pc, self.local_ssn, len(self.subscribers())))
        return self.asp.state

    def stop(self):
        self.running = False
        if self.asp:
            self.asp.close()
        self.pool.close_all()

    def _keep_alive(self):
        while self.running:
            time.sleep(1.0)
            if not self.running:
                return
            try:
                self.asp.renew(max_age=2.5)
            except Exception as exc:
                self.log("renouvellement impossible : %s" % exc)
                time.sleep(2.0)

    def _loop(self):
        while self.running:
            data = self.asp.recv_data(timeout=0.5)
            if data is None:
                continue
            try:
                self._handle(data)
            except Exception as exc:
                self.log("erreur de traitement : %s: %s" % (type(exc).__name__, exc))

    # ── processing ───────────────────────────────────────────────────────
    def _handle(self, data):
        dec = sccp.decode(data["data"])
        if dec is None or dec.kind not in ("UDT", "XUDT"):
            return
        if dec.called.ssn not in (None, self.local_ssn):
            self.log("recu pour SSN %s, ignore (je suis SSN %d)"
                     % (dec.called.ssn, self.local_ssn))
            return
        msg = tcap.parse(dec.data)
        if msg is None or not msg.components:
            return
        comp = msg.components[0]
        if comp.kind != "invoke":
            return
        self.log("<- %s opcode %s de %s" % (msg.kind, comp.opcode, dec.calling))
        answer = self._answer(comp, msg.app_context)
        if answer is None:
            return
        payload = tcap.end_response(msg.otid, answer, msg.app_context or None)
        called = sccp.Address(pc=dec.calling.pc, ssn=dec.calling.ssn,
                              gt=dec.calling.gt,
                              route_on_ssn=dec.calling.gt is None)
        calling = sccp.Address(pc=self.local_pc, ssn=self.local_ssn)
        udt = sccp.udt(called, calling, payload)
        self.asp.send_data(sccp.pc_to_int(self.local_pc),
                           data["opc"], udt)
        self.log("-> reponse envoyee vers PC %s" % m3ua._pc(data["opc"]))

    @staticmethod
    def _ctx(elem, num):
        """Child carrying context tag [num], shallow first, then deep."""
        if elem is None:
            return None
        for child in elem.children:
            if child.cls == 2 and child.num == num:
                return child
        for child in elem.walk():
            if child.cls == 2 and child.num == num:
                return child
        return None

    def _param_values(self, comp):
        """Numbers and IMSI found in the invoke parameter, IN SEQUENCE ORDER:
        the first field of an SRI-SM is the MSISDN, the third the SMSC
        address - mixing them up would answer about the wrong subscriber."""
        found = {"numbers": [], "digits": []}
        if comp.parameter is None:
            return found
        stack = [comp.parameter]
        while stack:
            elem = stack.pop(0)
            if elem.constructed:
                stack = list(elem.children) + stack
                continue
            raw = elem.value
            if not raw:
                continue
            if raw[0] & 0x80 and len(raw) >= 2:
                found["numbers"].append(mapops.read_address_string(raw))
            digits = sccp.untbcd(raw)
            if digits.isdigit():
                found["digits"].append(digits)
        return found

    def _answer(self, comp, app_context):
        op = comp.opcode
        vals = self._param_values(comp)
        wanted = (vals["numbers"] + vals["digits"] + [""])[0].lstrip("+")
        # Named field when the structure allows it: SRI-SM and SRI carry the
        # MSISDN in [0], the ATI its subscriber identity in [0]/[0-1].
        if op in (OP_SRI_SM, OP_SRI):
            champ = self._ctx(comp.parameter, 0)
            if champ is not None and champ.value:
                wanted = mapops.read_address_string(champ.value).lstrip("+")
        elif op == OP_ATI:
            ident = self._ctx(comp.parameter, 0)
            if ident is not None:
                imsi_champ = self._ctx(ident, 0)
                msisdn_champ = self._ctx(ident, 1)
                if msisdn_champ is not None and msisdn_champ.value:
                    wanted = mapops.read_address_string(msisdn_champ.value).lstrip("+")
                elif imsi_champ is not None and imsi_champ.value:
                    wanted = mapops.read_imsi(imsi_champ.value)

        if op == OP_SRI_SM:
            sub = self.find(msisdn=wanted)
            if sub is None:
                self.log("SRI-SM %s : abonne inconnu" % wanted)
                return tcap.return_error(comp.invoke_id, 1)      # unknownSubscriber
            node_number = self.msc_number or sub.msisdn
            info = ber.ctx(1, mapops.address_string(node_number), constructed=False)
            body = ber.tlv(0x04, mapops.imsi(sub.imsi)) + ber.ctx(0, info)
            self.log("SRI-SM %s -> IMSI %s" % (wanted, sub.imsi))
            return tcap.return_result_last(comp.invoke_id, op, ber.tlv(0x30, body))

        if op == OP_SRI:
            sub = self.find(msisdn=wanted)
            if sub is None:
                return tcap.return_error(comp.invoke_id, 1)
            msrn = self.msc_number or ("99" + sub.msisdn)
            body = ber.ctx(9, mapops.imsi(sub.imsi), constructed=False)
            body += ber.tlv(0x04, mapops.address_string(msrn))
            self.log("SRI %s -> MSRN %s" % (wanted, msrn))
            return tcap.return_result_last(comp.invoke_id, op, ber.tlv(0x30, body))

        if op == OP_SEND_IMSI:
            sub = self.find(msisdn=wanted)
            if sub is None:
                return tcap.return_error(comp.invoke_id, 1)
            self.log("sendIMSI %s -> %s" % (wanted, sub.imsi))
            return tcap.return_result_last(comp.invoke_id, op,
                                           ber.tlv(0x04, mapops.imsi(sub.imsi)))

        if op == OP_ATI:
            sub = self.find(msisdn=wanted) or self.find(imsi=wanted)
            if sub is None:
                return tcap.return_error(comp.invoke_id, 1)
            # locationInformation [0] { vlr-number [1] } - the useful minimum.
            loc = ber.ctx(1, mapops.address_string(self.msc_number or sub.msisdn),
                          constructed=False)
            body = ber.ctx(0, ber.ctx(0, loc))
            self.log("ATI %s -> localisation" % wanted)
            return tcap.return_result_last(comp.invoke_id, op, ber.tlv(0x30, body))

        if op == OP_SAI:
            # No AuC here: say so plainly rather than inventing vectors that
            # would authenticate nowhere.
            self.log("sendAuthenticationInfo : refuse (pas d'AuC dans ce repondeur)")
            return tcap.return_error(comp.invoke_id, 34)          # systemFailure

        self.log("opcode %s non gere -> facilityNotSupported" % op)
        return tcap.return_error(comp.invoke_id, 21)

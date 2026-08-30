# m3ua.py - un ASP M3UA (RFC 4666) en Python, sur SCTP, sans dependance.
#
# La console devient un vrai point SS7 du lab : elle se connecte a l'inter-STP
# (ou au STP d'un operateur), s'annonce (ASPUP), enregistre dynamiquement une
# routing key pour SON point code (RKM - le hub du depot est configure en
# "routing-key-allocation dynamic-permitted", cf. helpers/create_interop.sh),
# passe active (ASPAC), puis emet et recoit du SCCP.
#
# Le lien est du SCTP : socket(AF_INET, SOCK_STREAM, IPPROTO_SCTP). Le PPID
# 3 (M3UA) est pose par sendmsg() - un STP qui filtre sur le PPID jetterait
# sinon nos messages.

import queue
import socket
import struct
import threading
import time

IPPROTO_SCTP = 132
SCTP_SNDRCV = 1          # cmsg type (linux/sctp.h) : 0 = INIT, 1 = SNDRCV
PPID_M3UA = 3

# Decalage des routing contexts de la console : hors de portee du plan du lab
# (n*1000 + o*100 + 50, donc au plus 9950 pour 9 noeuds et 9 operateurs).
CONSOLE_RCTX_BASE = 900000

# Classes et types de messages.
CLS_MGMT, CLS_TRANSFER, CLS_SSNM, CLS_ASPSM, CLS_ASPTM, CLS_RKM = 0, 1, 2, 3, 4, 9
ERR, NTFY = 0, 1
DATA = 1
DUNA, DAVA, DAUD, SCON, DUPU, DRST = 1, 2, 3, 4, 5, 6
ASPUP, ASPDN, BEAT, ASPUP_ACK, ASPDN_ACK, BEAT_ACK = 1, 2, 3, 4, 5, 6
ASPAC, ASPIA, ASPAC_ACK, ASPIA_ACK = 1, 2, 3, 4
REG_REQ, REG_RSP, DEREG_REQ, DEREG_RSP = 1, 2, 3, 4

# Parametres.
P_INFO = 0x0004
P_ROUTING_CTX = 0x0006
P_DIAG = 0x0007
P_HEARTBEAT = 0x0009
P_TRAFFIC_MODE = 0x000B
P_ERROR_CODE = 0x000C
P_STATUS = 0x000D
P_ASP_ID = 0x0011
P_AFFECTED_PC = 0x0012
P_NET_APPEARANCE = 0x0200
P_ROUTING_KEY = 0x0207
P_REG_RESULT = 0x0208
P_LOCAL_RK_ID = 0x020A
P_DPC = 0x020B
P_SERVICE_IND = 0x020C
P_OPC_LIST = 0x020E
P_PROTOCOL_DATA = 0x0210
P_REG_STATUS = 0x0212

MSG_NAMES = {
    (CLS_MGMT, ERR): "ERR", (CLS_MGMT, NTFY): "NTFY",
    (CLS_TRANSFER, DATA): "DATA",
    (CLS_SSNM, DUNA): "DUNA", (CLS_SSNM, DAVA): "DAVA", (CLS_SSNM, DAUD): "DAUD",
    (CLS_SSNM, SCON): "SCON", (CLS_SSNM, DUPU): "DUPU", (CLS_SSNM, DRST): "DRST",
    (CLS_ASPSM, ASPUP): "ASPUP", (CLS_ASPSM, ASPUP_ACK): "ASPUP_ACK",
    (CLS_ASPSM, ASPDN): "ASPDN", (CLS_ASPSM, ASPDN_ACK): "ASPDN_ACK",
    (CLS_ASPSM, BEAT): "BEAT", (CLS_ASPSM, BEAT_ACK): "BEAT_ACK",
    (CLS_ASPTM, ASPAC): "ASPAC", (CLS_ASPTM, ASPAC_ACK): "ASPAC_ACK",
    (CLS_ASPTM, ASPIA): "ASPIA", (CLS_ASPTM, ASPIA_ACK): "ASPIA_ACK",
    (CLS_RKM, REG_REQ): "REG_REQ", (CLS_RKM, REG_RSP): "REG_RSP",
    (CLS_RKM, DEREG_REQ): "DEREG_REQ", (CLS_RKM, DEREG_RSP): "DEREG_RSP",
}

# RFC 4666 3.6.2 - Registration Status.
REG_STATUS = {
    0: "enregistree", 1: "erreur inconnue", 2: "DPC invalide",
    3: "network appearance invalide", 4: "routing key invalide",
    5: "permission refusee", 6: "routage unique impossible",
    7: "routing key non provisionnee", 8: "ressources insuffisantes",
    9: "parametre de routing key non supporte",
    10: "mode de trafic non supporte", 11: "changement de RK refuse",
    12: "routing key deja enregistree",
}

ERROR_CODES = {
    0x01: "Invalid Version", 0x03: "Unsupported Message Class",
    0x04: "Unsupported Message Type", 0x05: "Unsupported Traffic Mode",
    0x06: "Unexpected Message", 0x07: "Protocol Error",
    0x09: "Invalid Stream Identifier", 0x0D: "Refused - Management Blocking",
    0x0E: "ASP Identifier Required", 0x0F: "Invalid ASP Identifier",
    0x11: "Invalid Parameter Value", 0x12: "Parameter Field Error",
    0x13: "Unexpected Parameter", 0x14: "Destination Status Unknown",
    0x15: "Invalid Network Appearance", 0x16: "Missing Parameter",
    0x19: "Invalid Routing Context", 0x1A: "No Configured AS for ASP",
}


def param(tag, value):
    body = struct.pack("!HH", tag, 4 + len(value)) + value
    pad = (-len(body)) % 4
    return body + b"\x00" * pad


def parse_params(raw):
    out = {}
    i = 0
    while i + 4 <= len(raw):
        tag, length = struct.unpack("!HH", raw[i:i + 4])
        if length < 4:
            break
        value = raw[i + 4:i + length]
        out.setdefault(tag, []).append(value)
        i += length + ((-length) % 4)
    return out


def message(cls, typ, params_bytes=b""):
    return struct.pack("!BBBBI", 1, 0, cls, typ, 8 + len(params_bytes)) + params_bytes


class M3uaMessage(object):
    def __init__(self, cls, typ, params):
        self.cls = cls
        self.typ = typ
        self.params = params

    @property
    def name(self):
        return MSG_NAMES.get((self.cls, self.typ), "cls%d/typ%d" % (self.cls, self.typ))

    def first(self, tag):
        vals = self.params.get(tag)
        return vals[0] if vals else None

    def __str__(self):
        return "M3UA %s (%d parametre(s))" % (self.name, len(self.params))


class M3uaError(Exception):
    pass


class Asp(object):
    """ASP M3UA client. Un fil de lecture, une file par usage."""

    def __init__(self, remote_ip, remote_port=2908, local_pc=None,
                 routing_ctx=None, traffic_mode=1, log=None):
        # Duree de vie observee d'une association depuis l'hote vers l'inter-STP
        # du lab : une trentaine de secondes. Passe ce delai, le hub cesse de
        # repondre et l'association SCTP expire cote noyau. On la remonte donc
        # au lieu de faire semblant de tenir un lien permanent (voir renew()).
        self.opened_at = 0.0
        self.remote = (remote_ip, int(remote_port))
        self.local_pc = local_pc
        self.routing_ctx = routing_ctx
        self.traffic_mode = traffic_mode
        self.sock = None
        self.rx = queue.Queue()          # DATA (SCCP) recus
        self.ctrl = queue.Queue()        # messages de controle
        self.events = []                 # journal lisible
        self.reader = None
        self.beater = None
        self.beat_interval = 15.0
        self.running = False
        self.state = "deconnecte"
        self._log = log

    # ── journal ──────────────────────────────────────────────────────────
    def log(self, text):
        stamp = time.strftime("%H:%M:%S")
        self.events.append("%s %s" % (stamp, text))
        del self.events[:-400]
        if self._log:
            try:
                self._log(text)
            except Exception:
                pass

    # ── transport ────────────────────────────────────────────────────────
    def connect(self, timeout=6.0):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM, IPPROTO_SCTP)
        self.sock.settimeout(timeout)
        self.sock.connect(self.remote)
        self.sock.settimeout(1.0)
        self.running = True
        self.opened_at = time.time()
        self.state = "connecte"
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()
        # Battement de coeur M3UA. L'inter-STP ferme l'association d'un ASP
        # silencieux au bout d'une trentaine de secondes : sans ces BEAT, un
        # lien parfaitement etabli tombe tout seul entre deux commandes, et la
        # destination passe DUNA sans rien dans les journaux.
        self.beater = threading.Thread(target=self._beat_loop, daemon=True)
        self.beater.start()
        self.log("SCTP etabli vers %s:%d" % self.remote)

    def _send(self, data, stream=0):
        if not self.sock:
            raise M3uaError("pas de lien SCTP")
        info = struct.pack("HHHIIIIIi", stream, 0, 0, socket.htonl(PPID_M3UA),
                           0, 0, 0, 0, 0)
        try:
            self.sock.sendmsg([data], [(IPPROTO_SCTP, SCTP_SNDRCV, info)])
        except (OSError, ValueError):
            self.sock.sendall(data)

    def send_msg(self, cls, typ, params_bytes=b""):
        raw = message(cls, typ, params_bytes)
        # RFC 4666 1.4.4 : le flux SCTP 0 est RESERVE a la gestion. Le trafic
        # DATA emis dessus se fait refuser avec "Invalid Stream Identifier" -
        # le lien reste up, et les messages disparaissent en silence.
        self._send(raw, stream=(1 if cls == CLS_TRANSFER else 0))
        name = MSG_NAMES.get((cls, typ), "cls%d/typ%d" % (cls, typ))
        if name not in ("DATA", "BEAT"):
            self.log("-> %s" % name)
        return raw

    def _beat_loop(self):
        while self.running:
            for _ in range(int(self.beat_interval * 4)):
                if not self.running:
                    return
                time.sleep(0.25)
            if not self.running:
                return
            try:
                self.send_msg(CLS_ASPSM, BEAT)
            except Exception:
                return

    def _read_loop(self):
        buf = b""
        while self.running:
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not data:
                break
            buf += data
            while len(buf) >= 8:
                ver, res, cls, typ = buf[0], buf[1], buf[2], buf[3]
                length = struct.unpack("!I", buf[4:8])[0]
                if length < 8 or len(buf) < length:
                    break
                body = buf[8:length]
                buf = buf[length:]
                msg = M3uaMessage(cls, typ, parse_params(body))
                self._dispatch(msg)
        self.running = False
        self.state = "deconnecte"
        self.log("lien SCTP ferme")

    def _dispatch(self, msg):
        if msg.cls == CLS_TRANSFER and msg.typ == DATA:
            pd = msg.first(P_PROTOCOL_DATA)
            if pd and len(pd) >= 12:
                opc, dpc = struct.unpack("!II", pd[0:8])
                si, ni, mp, sls = pd[8], pd[9], pd[10], pd[11]
                self.rx.put({"opc": opc, "dpc": dpc, "si": si, "ni": ni,
                             "sls": sls, "data": pd[12:]})
                self.log("<- DATA opc=%s si=%d (%d octets)" %
                         (_pc(opc), si, len(pd) - 12))
            return
        if msg.cls == CLS_ASPSM and msg.typ == BEAT:
            self.send_msg(CLS_ASPSM, BEAT_ACK, param(P_HEARTBEAT,
                                                     msg.first(P_HEARTBEAT) or b""))
            return
        if msg.cls == CLS_ASPSM and msg.typ == BEAT_ACK:
            # Reponse a NOTRE battement : rien a en faire, et surtout pas a
            # laisser s'accumuler dans la file de controle.
            return
        name = msg.name
        detail = ""
        if msg.cls == CLS_MGMT and msg.typ == ERR:
            code = msg.first(P_ERROR_CODE)
            if code:
                val = struct.unpack("!I", code)[0]
                detail = " : %s" % ERROR_CODES.get(val, "code 0x%02x" % val)
        if msg.cls == CLS_SSNM:
            apc = msg.first(P_AFFECTED_PC)
            if apc and len(apc) >= 4:
                detail = " : PC %s" % _pc(struct.unpack("!I", apc[:4])[0])
        self.log("<- %s%s" % (name, detail))
        self.ctrl.put(msg)

    def wait_ctrl(self, wanted, timeout=5.0):
        """Attend un (classe, type) precis. Les autres sont conserves."""
        end = time.time() + timeout
        keep = []
        found = None
        while time.time() < end:
            try:
                msg = self.ctrl.get(timeout=0.2)
            except queue.Empty:
                continue
            if (msg.cls, msg.typ) in wanted:
                found = msg
                break
            keep.append(msg)
        for m in keep:
            self.ctrl.put(m)
        return found

    # ── sequence d'activation ────────────────────────────────────────────
    def asp_up(self, timeout=5.0):
        self.send_msg(CLS_ASPSM, ASPUP)
        msg = self.wait_ctrl({(CLS_ASPSM, ASPUP_ACK), (CLS_MGMT, ERR)}, timeout)
        if msg is None:
            raise M3uaError("pas d'ASPUP_ACK - le STP ne repond pas")
        if msg.cls == CLS_MGMT:
            raise M3uaError("ASPUP refuse par le STP")
        self.state = "ASP_INACTIVE"
        return True

    def register(self, point_code, service_ind=None, rk_id=None, timeout=5.0):
        """RKM : demande dynamique d'une routing key pour NOTRE point code.

        Le parametre "Service Indicators" est OMIS par defaut : l'inter-STP
        d'Osmocom le refuse (registration status 9, "parametre de routing key
        non supporte") et l'enregistrement echoue alors en entier, alors que
        la meme cle sans ce champ passe sans discuter."""
        # L'identifiant local de routing key DOIT etre propre a cette cle :
        # l'inter-STP s'en sert pour reconnaitre une re-registration. Deux ASP
        # qui envoient tous deux l'identifiant 1 se retrouvent dans LE MEME AS
        # (meme routing context), et en traffic-mode override le dernier arrive
        # vole le trafic du premier - la destination du premier devient DUNA.
        # On derive donc l'identifiant du point code demande.
        if rk_id is None:
            rk_id = point_code & 0x00FFFFFF
        # On PROPOSE aussi le routing context, derive du point code. Sans lui,
        # l'inter-STP alloue lui-meme un contexte et rend le MEME a deux ASP
        # differents : le second prend alors la place du premier dans l'AS
        # (traffic-mode override) et le point code du premier passe DUNA. Avec
        # un contexte propre a chaque point code, chacun garde son trafic.
        # Le contexte propose vit dans une plage que le lab n'utilise pas : les
        # noeuds calculent le leur par n*1000 + o*100 + 50 (au plus 9950), et
        # le hub ne distingue pas deux AS qui portent le meme contexte. On
        # ajoute donc un decalage franc au point code plutot que de risquer de
        # tomber sur la routing key d'un operateur.
        rctx = self.routing_ctx if self.routing_ctx is not None else \
            (CONSOLE_RCTX_BASE + (point_code & 0x00FFFFFF))
        dpc = struct.pack("!I", point_code & 0x00FFFFFF)
        rk = param(P_LOCAL_RK_ID, struct.pack("!I", rk_id))
        rk += param(P_ROUTING_CTX, struct.pack("!I", rctx))
        rk += param(P_TRAFFIC_MODE, struct.pack("!I", self.traffic_mode))
        rk += param(P_DPC, dpc)
        if service_ind is not None:
            rk += param(P_SERVICE_IND, bytes([service_ind]))
        self.send_msg(CLS_RKM, REG_REQ, param(P_ROUTING_KEY, rk))
        msg = self.wait_ctrl({(CLS_RKM, REG_RSP), (CLS_MGMT, ERR)}, timeout)
        if msg is None:
            raise M3uaError("pas de REG_RSP - RKM refuse ou non supporte")
        if msg.cls == CLS_MGMT:
            raise M3uaError("REG_REQ rejete (ERR)")
        result = msg.first(P_REG_RESULT)
        status = None
        if result:
            sub = parse_params(result)
            st = sub.get(P_REG_STATUS)
            if st:
                status = struct.unpack("!I", st[0])[0]
            rc = sub.get(P_ROUTING_CTX)
            if rc:
                self.routing_ctx = struct.unpack("!I", rc[0][:4])[0]
        if status not in (0, None):
            raise M3uaError("enregistrement refuse : %s" %
                            REG_STATUS.get(status, status))
        self.log("routing key enregistree : PC %s -> contexte %s (rk id %s)"
                 % (_pc(point_code), self.routing_ctx, rk_id))
        return self.routing_ctx

    def activate(self, timeout=5.0):
        body = param(P_TRAFFIC_MODE, struct.pack("!I", self.traffic_mode))
        if self.routing_ctx is not None:
            body += param(P_ROUTING_CTX, struct.pack("!I", self.routing_ctx))
        self.send_msg(CLS_ASPTM, ASPAC, body)
        msg = self.wait_ctrl({(CLS_ASPTM, ASPAC_ACK), (CLS_MGMT, ERR)}, timeout)
        if msg is None:
            raise M3uaError("pas d'ASPAC_ACK")
        if msg.cls == CLS_MGMT:
            raise M3uaError("ASPAC refuse")
        self.state = "ASP_ACTIVE"
        return True

    @property
    def age(self):
        return time.time() - self.opened_at if self.opened_at else 0.0

    def bring_up(self, point_code, register=True):
        self.last_pc = point_code
        self.last_register = register
        self.connect()
        self.asp_up()
        if register:
            try:
                self.register(point_code)
            except M3uaError as exc:
                # Un STP deja provisionne pour ce PC refuse le RKM : on garde
                # la main, l'activation peut tres bien passer sans.
                self.log("RKM : %s (on continue sans)" % exc)
        self.activate()
        return self.state

    def renew(self, max_age=3.0):
        """Rouvre le lien s'il est mort, ou s'il approche de sa duree de vie.

        Le seuil est court (3 s) : c'est la duree pendant laquelle l'inter-STP
        du lab repond effectivement a une association venue de l'hote. Une
        reconnexion coute environ 0,3 s (SCTP + ASPUP + RKM + ASPAC).

        Rend True si une reconnexion a eu lieu. Le point code et le contexte
        de routage sont les memes : de l'exterieur, rien ne bouge."""
        if self.state == "ASP_ACTIVE" and self.age < max_age:
            return False
        pc = getattr(self, "last_pc", None)
        if pc is None:
            return False
        try:
            self.close()
        except Exception:
            pass
        self.routing_ctx = None
        self.rx = queue.Queue()
        self.ctrl = queue.Queue()
        self.bring_up(pc, getattr(self, "last_register", True))
        self.log("lien renouvele (PC %s)" % _pc(pc))
        return True

    # ── donnees ──────────────────────────────────────────────────────────
    def send_data(self, opc, dpc, payload, si=3, ni=0, sls=0, mp=0):
        pd = struct.pack("!IIBBBB", opc & 0xFFFFFF, dpc & 0xFFFFFF, si, ni, mp, sls)
        pd += payload
        body = b""
        if self.routing_ctx is not None:
            body += param(P_ROUTING_CTX, struct.pack("!I", self.routing_ctx))
        body += param(P_PROTOCOL_DATA, pd)
        self.send_msg(CLS_TRANSFER, DATA, body)
        self.log("-> DATA vers %s (%d octets SCCP)" % (_pc(dpc), len(payload)))

    def recv_data(self, timeout=5.0):
        try:
            return self.rx.get(timeout=timeout)
        except queue.Empty:
            return None

    def close(self):
        self.running = False
        if self.sock:
            try:
                self.send_msg(CLS_ASPTM, ASPIA)
                self.send_msg(CLS_ASPSM, ASPDN)
            except Exception:
                pass
            try:
                self.sock.close()
            except Exception:
                pass
        self.sock = None
        self.state = "deconnecte"


def _pc(val):
    return "%d.%d.%d" % ((val >> 11) & 0x07, (val >> 3) & 0xFF, val & 0x07)

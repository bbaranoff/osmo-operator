# mapops.py - catalogue des operations MAP que la console sait emettre.
#
# Chaque operation declare : son opcode, son contexte applicatif, le SSN de la
# machine a qui elle s'adresse (HLR 6, VLR 7, MSC 8, gsmSCF 147), la liste de
# ses parametres - c'est cette liste que le formulaire de la console affiche -
# et la facon de lire la reponse.
#
# Les encodages suivent 3GPP TS 29.002 (MAP v3).

from . import ber
from . import sccp

# ── types elementaires ────────────────────────────────────────────────────────

def address_string(number, nai=1, npi=1):
    """ISDN-AddressString : un octet nature/plan, puis les chiffres en TBCD.
    nai 1 = international, npi 1 = E.164."""
    digits = "".join(c for c in str(number) if c.isdigit())
    head = 0x80 | ((nai & 0x07) << 4) | (npi & 0x0F)
    return bytes([head]) + sccp.tbcd(digits)


def read_address_string(raw):
    if not raw:
        return ""
    nai = (raw[0] >> 4) & 0x07
    num = sccp.untbcd(raw[1:])
    prefix = "+" if nai == 1 else ""
    return prefix + num


def imsi(value):
    return sccp.tbcd(value)


def read_imsi(raw):
    return sccp.untbcd(raw)


# ── contextes applicatifs MAP (0.4.0.0.1.0.<contexte>.<version>) ──────────────
AC = {
    "networkLocUp": "0.4.0.0.1.0.1.3",
    "roamingNumberEnquiry": "0.4.0.0.1.0.3.3",
    "locationInfoRetrieval": "0.4.0.0.1.0.5.3",
    "infoRetrieval": "0.4.0.0.1.0.14.3",
    "shortMsgGateway": "0.4.0.0.1.0.20.3",
    "shortMsgMT-Relay": "0.4.0.0.1.0.25.3",
    "imsiRetrieval": "0.4.0.0.1.0.26.3",
    "subscriberInfoEnquiry": "0.4.0.0.1.0.28.3",
    "anyTimeInfoEnquiry": "0.4.0.0.1.0.29.3",
}

# ── erreurs MAP ───────────────────────────────────────────────────────────────
MAP_ERRORS = {
    1: "unknownSubscriber", 3: "unknownMSC", 5: "unidentifiedSubscriber",
    6: "absentSubscriberSM", 7: "unknownEquipment", 8: "roamingNotAllowed",
    9: "illegalSubscriber", 10: "bearerServiceNotProvisioned",
    11: "teleserviceNotProvisioned", 12: "illegalEquipment", 13: "callBarred",
    21: "facilityNotSupported", 27: "absentSubscriber",
    31: "subscriberBusyForMT-SMS", 32: "sm-DeliveryFailure",
    33: "messageWaitingListFull", 34: "systemFailure", 35: "dataMissing",
    36: "unexpectedDataValue", 44: "numberChanged", 45: "busySubscriber",
    46: "noSubscriberReply", 49: "forwardingViolation",
    51: "resourceLimitation", 52: "noRoamingNumberAvailable",
    53: "subscriberBusyForMT-SMS", 71: "unknownAlphabet",
    74: "absentSubscriberSM",
}

SSN_HLR, SSN_VLR, SSN_MSC, SSN_SCF = 6, 7, 8, 147


class Param(object):
    """Un champ du formulaire."""

    def __init__(self, key, label, default="", kind="text", help=""):
        self.key = key
        self.label = label
        self.default = default
        self.kind = kind          # text | number | bool | choice
        self.help = help


class Operation(object):
    def __init__(self, key, name, opcode, ac, ssn, params, encoder,
                 decoder=None, summary=""):
        self.key = key
        self.name = name
        self.opcode = opcode
        self.ac = ac
        self.ssn = ssn
        self.params = params
        self.encoder = encoder
        self.decoder = decoder or (lambda elem: [])
        self.summary = summary

    def encode(self, values):
        return self.encoder(values)

    def defaults(self):
        return dict((p.key, p.default) for p in self.params)


# ── encodeurs ─────────────────────────────────────────────────────────────────

def _enc_sri_sm(v):
    body = ber.ctx(0, address_string(v["msisdn"]), constructed=False)
    body += ber.tlv(0x81, b"\xff" if str(v.get("sm_rp_pri", "1")) in
                    ("1", "true", "oui", "True") else b"\x00")
    body += ber.ctx(2, address_string(v.get("sc_addr") or "0"), constructed=False)
    return ber.tlv(0x30, body)


def _enc_sri(v):
    body = ber.ctx(0, address_string(v["msisdn"]), constructed=False)
    itype = {"basicCall": 0, "forwarding": 1}.get(v.get("interrogation", "basicCall"), 0)
    body += ber.tlv(0x83, bytes([itype]))
    body += ber.ctx(6, address_string(v.get("gmsc") or "0"), constructed=False)
    return ber.tlv(0x30, body)


def _enc_ati(v):
    ident = v.get("identity_type", "msisdn")
    if ident == "imsi":
        sub = ber.ctx(0, imsi(v["identity"]), constructed=False)
    else:
        sub = ber.ctx(1, address_string(v["identity"]), constructed=False)
    subscriber = ber.ctx(0, sub)
    req = b""
    if str(v.get("location", "1")) in ("1", "true", "oui"):
        req += ber.ctx(0, b"", constructed=False)          # locationInformation
    if str(v.get("state", "1")) in ("1", "true", "oui"):
        req += ber.ctx(1, b"", constructed=False)          # subscriberState
    requested = ber.ctx(1, req)
    scf = ber.ctx(3, address_string(v.get("scf") or "0"), constructed=False)
    return ber.tlv(0x30, subscriber + requested + scf)


def _enc_sai(v):
    body = ber.ctx(0, imsi(v["imsi"]), constructed=False)
    body += ber.ctx(1, bytes([int(v.get("vectors", 1) or 1)]), constructed=False)
    return ber.tlv(0x30, body)


def _enc_send_imsi(v):
    # L'argument est directement une ISDN-AddressString.
    return ber.tlv(0x04, address_string(v["msisdn"]))


def _enc_psi(v):
    body = ber.ctx(0, imsi(v["imsi"]), constructed=False)
    req = b""
    if str(v.get("location", "1")) in ("1", "true", "oui"):
        req += ber.ctx(0, b"", constructed=False)
    if str(v.get("state", "1")) in ("1", "true", "oui"):
        req += ber.ctx(1, b"", constructed=False)
    body += ber.ctx(2, req)
    return ber.tlv(0x30, body)


def _enc_ul(v):
    body = ber.tlv(0x04, imsi(v["imsi"]))
    body += ber.ctx(1, address_string(v.get("msc") or "0"), constructed=False)
    body += ber.tlv(0x04, address_string(v.get("vlr") or "0"))
    return ber.tlv(0x30, body)


def _enc_raw(v):
    txt = (v.get("hex") or "").replace(" ", "")
    return bytes.fromhex(txt) if txt else b""


# ── lecteurs de resultat ──────────────────────────────────────────────────────

def _walk_pairs(elem, out, path=""):
    """Extraction opportuniste : tout ce qui ressemble a un IMSI ou a un
    numero est rendu lisible, avec le chemin de tags qui l'a produit."""
    for child in (elem.children if elem else []):
        tag = "%s/%s" % (path, child.tagstr())
        if child.constructed:
            _walk_pairs(child, out, tag)
        else:
            raw = child.value
            if not raw:
                out.append((tag, "(vide)"))
                continue
            txt = raw.hex()
            digits = sccp.untbcd(raw)
            if len(raw) >= 3 and raw[0] & 0x80 and digits[1:].isdigit():
                out.append((tag, "numero %s" % read_address_string(raw)))
            elif digits.isdigit() and len(digits) >= 5:
                out.append((tag, "chiffres %s (hex %s)" % (digits, txt)))
            else:
                out.append((tag, txt))
    return out


def _dec_sri_sm(elem):
    res = []
    if elem is None:
        return res
    kids = elem.children
    if kids and not kids[0].constructed:
        res.append(("IMSI", read_imsi(kids[0].value)))
    for e in (elem.walk() if elem else []):
        if e.cls == 2 and e.num == 1 and not e.constructed and e.value:
            res.append(("Noeud de service (networkNode-Number)",
                        read_address_string(e.value)))
    if not res:
        res = _walk_pairs(elem, [])
    return res


def _dec_sri(elem):
    res = []
    for e in (elem.walk() if elem else []):
        if e.cls == 2 and e.num == 5 and not e.constructed and e.value:
            res.append(("MSRN (roamingNumber)", read_address_string(e.value)))
        if e.cls == 0 and e.num == 4 and len(e.value) > 3:
            res.append(("IMSI", read_imsi(e.value)))
    if not res:
        res = _walk_pairs(elem, [])
    return res


def _dec_generic(elem):
    return _walk_pairs(elem, [])


# ── catalogue ─────────────────────────────────────────────────────────────────

OPERATIONS = [
    Operation(
        "sri-sm", "sendRoutingInfoForSM", 45, AC["shortMsgGateway"], SSN_HLR,
        [Param("msisdn", "MSISDN de l'abonne", "", "text",
               "numero appele, en international sans +"),
         Param("sc_addr", "Adresse du SMSC (GT)", "", "text",
               "serviceCentreAddress - l'adresse qui recevra la reponse"),
         Param("sm_rp_pri", "Priorite SM-RP-PRI", "1", "bool", "")],
        _enc_sri_sm, _dec_sri_sm,
        "Demande au HLR ou joindre l'abonne pour lui remettre un SMS "
        "(IMSI + numero du MSC/VLR de service)."),
    Operation(
        "sri", "sendRoutingInfo", 22, AC["locationInfoRetrieval"], SSN_HLR,
        [Param("msisdn", "MSISDN appele", "", "text", ""),
         Param("gmsc", "Adresse du GMSC (GT)", "", "text", ""),
         Param("interrogation", "Type d'interrogation", "basicCall", "choice",
               "basicCall | forwarding")],
        _enc_sri, _dec_sri,
        "Interrogation d'acheminement d'appel : le HLR rend le MSRN, "
        "ou une erreur (absentSubscriber, unknownSubscriber...)."),
    Operation(
        "ati", "anyTimeInterrogation", 71, AC["anyTimeInfoEnquiry"], SSN_HLR,
        [Param("identity", "IMSI ou MSISDN", "", "text", ""),
         Param("identity_type", "Type d'identite", "msisdn", "choice",
               "msisdn | imsi"),
         Param("scf", "Adresse du gsmSCF (GT)", "", "text", ""),
         Param("location", "Demander la localisation", "1", "bool", ""),
         Param("state", "Demander l'etat de l'abonne", "1", "bool", "")],
        _enc_ati, _dec_generic,
        "Localisation a la demande : cellule, VLR, etat de l'abonne. "
        "Un HLR reel la refuse souvent (facilityNotSupported)."),
    Operation(
        "sai", "sendAuthenticationInfo", 56, AC["infoRetrieval"], SSN_HLR,
        [Param("imsi", "IMSI", "", "text", ""),
         Param("vectors", "Nombre de vecteurs", "1", "number", "")],
        _enc_sai, _dec_generic,
        "Demande de triplets/quintuplets d'authentification au HLR/AuC."),
    Operation(
        "send-imsi", "sendIMSI", 58, AC["imsiRetrieval"], SSN_HLR,
        [Param("msisdn", "MSISDN", "", "text", "")],
        _enc_send_imsi, _dec_generic,
        "Resolution MSISDN -> IMSI par le HLR."),
    Operation(
        "psi", "provideSubscriberInfo", 70, AC["subscriberInfoEnquiry"], SSN_VLR,
        [Param("imsi", "IMSI", "", "text", ""),
         Param("location", "Localisation", "1", "bool", ""),
         Param("state", "Etat de l'abonne", "1", "bool", "")],
        _enc_psi, _dec_generic,
        "Demande au VLR l'etat et la position d'un abonne."),
    Operation(
        "ul", "updateLocation", 2, AC["networkLocUp"], SSN_HLR,
        [Param("imsi", "IMSI", "", "text", ""),
         Param("msc", "Numero du MSC (GT)", "", "text", ""),
         Param("vlr", "Numero du VLR (GT)", "", "text", "")],
        _enc_ul, _dec_generic,
        "Mise a jour de localisation - la meme que celle d'un VLR reel. "
        "A n'emettre que sur un lab."),
    Operation(
        "raw", "invoke brut", 0, "", SSN_HLR,
        [Param("opcode", "Opcode MAP", "45", "number", ""),
         Param("ac", "Contexte applicatif (OID)", AC["shortMsgGateway"], "text", ""),
         Param("hex", "Parametre BER en hexa", "", "text",
               "colle tel quel apres l'opcode")],
        _enc_raw, _dec_generic,
        "Pour tout ce qui n'est pas au catalogue : opcode et parametre a la main."),
]

BY_KEY = dict((o.key, o) for o in OPERATIONS)


def error_name(code):
    return MAP_ERRORS.get(code, "erreur MAP %s" % code)

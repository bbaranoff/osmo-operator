# topo.py - inventaire du lab, HERITE des configurations.
#
# Rien n'est ecrit en dur : les point codes, les adresses, les ports et les
# services sont lus la ou ils font foi.
#
#   1. "docker ps"                      -> quels noeuds tournent ici ;
#   2. l'environnement du conteneur     -> OSMO_HUB_IP, WAN_NODE_ID (poses par
#                                          start.sh, cf. --hub-ip / --wan) ;
#   3. /etc/osmocom/*.cfg DANS le noeud -> point code, routing keys, listeners
#                                          M3UA, adresses SCCP, liens vers le
#                                          hub. C'est la configuration REELLE,
#                                          pas le gabarit du depot ;
#   4. /proc/net/tcp DANS le noeud      -> quels VTY ecoutent vraiment, et la
#                                          banniere de chacun dit QUEL demon
#                                          repond (OsmoMSC, OsmoHLR, ...).
#
# Les gabarits de configs/ ne servent que de repli quand aucun noeud ne tourne.

import json
import os
import re
import subprocess

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Sonde poussee dans le noeud : liste les VTY qui ecoutent et lit leur
# banniere. Une seule execution par noeud, tout en parallele.
_PROBE = r'''
import json, socket, sys, threading

def listening():
    ports = set()
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(path) as fh:
                next(fh, None)
                for line in fh:
                    f = line.split()
                    if len(f) < 4 or f[3] != "0A":
                        continue
                    try:
                        p = int(f[1].split(":")[1], 16)
                    except Exception:
                        continue
                    ports.add(p)
        except Exception:
            pass
    return sorted(p for p in ports if 4200 <= p <= 4299)

res = {}
lock = threading.Lock()

def probe(p):
    banner = ""
    try:
        s = socket.create_connection(("127.0.0.1", p), 1.5)
        s.settimeout(1.2)
        data = b""
        try:
            while len(data) < 4096:
                d = s.recv(4096)
                if not d:
                    break
                data += d
                if b"VTY interface" in data:
                    break
        except socket.timeout:
            pass
        s.close()
        for line in data.decode("utf-8", "replace").splitlines():
            if "VTY interface" in line:
                banner = line.strip()
                break
    except Exception:
        return
    with lock:
        res[p] = banner

th = [threading.Thread(target=probe, args=(p,)) for p in listening()]
for t in th:
    t.start()
for t in th:
    t.join(4)
print(json.dumps(res))
'''

# Nom court affiche dans le schema, deduit de la banniere ("OsmoMSC" -> MSC).
_PRETTY = {
    "OsmoSTP": ("STP", "SS7"),
    "OsmoMSC": ("MSC/VLR", "coeur"),
    "OsmoHLR": ("HLR", "abonnes"),
    "OsmoBSC": ("BSC", "radio"),
    "OsmoBTS": ("BTS", "radio"),
    "OsmoMGW": ("MGW", "media"),
    "OsmoPCU": ("PCU", "data"),
    "OsmoSGSN": ("SGSN", "data"),
    "OsmoGGSN": ("GGSN", "data"),
    "OsmoUPF": ("UPF", "data"),
    "OsmoTRX": ("TRX", "radio"),
    "OsmoSIPConnector": ("SIP-CONN", "voix"),
    "OsmoMobile": ("MS", "mobile"),
    "mobile": ("MS", "mobile"),
}

# Repli quand la banniere ne dit rien (VTY muet, demon en cours de demarrage).
_BY_PORT = {
    4238: "OsmoHNBGW", 4239: "OsmoSTP", 4240: "OsmoPCU", 4241: "OsmoBTS",
    4242: "OsmoBSC", 4243: "OsmoMGW", 4245: "OsmoSGSN", 4246: "OsmoGbProxy",
    4247: "OsmoMobile", 4248: "OsmoMobile", 4249: "OsmoSIPConnector",
    4250: "OsmoBTS", 4251: "OsmoMSC", 4254: "OsmoMSC", 4255: "OsmoMGW",
    4256: "OsmoUECUPS", 4257: "OsmoE1D", 4258: "OsmoHLR", 4259: "OsmoUPF",
    4260: "OsmoTRX", 4267: "OsmoGGSN",
}


def sh(args, timeout=20):
    try:
        out = subprocess.run(args, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=timeout)
        return out.stdout.decode("utf-8", "replace")
    except Exception:
        return ""


class Service(object):
    """Un demon joignable par VTY sur un noeud."""

    def __init__(self, node, port, daemon, label, family):
        self.node = node
        self.port = int(port)
        self.daemon = daemon
        self.label = label
        self.family = family

    def __repr__(self):
        return "<Service %s:%s %s>" % (self.node, self.port, self.label)


class Node(object):
    """Un noeud du lab : conteneur operateur, ou hub inter-STP."""

    def __init__(self, name, role, index=None):
        self.name = name            # nom du conteneur, ou "local"
        self.role = role            # "operator" | "interstp"
        self.index = index          # numero d'operateur
        self.point_code = ""        # 1.11.2
        self.hub_ip = ""            # adresse de l'inter-STP vu par ce noeud
        self.hub_port = 2908
        self.local_m3ua = 2905
        self.routing_ctx = None     # routing key vers le hub
        self.wan_node = ""
        self.services = []          # [Service]
        self.sccp = {}              # nom -> {"pc":..., "ssn":..., "ri":...}
        self.env = {}
        self.cfg = {}               # fichier -> texte

    @property
    def title(self):
        if self.role == "interstp":
            return "INTER-STP"
        return "OP%s" % (self.index if self.index is not None else "?")

    def service(self, daemon):
        for s in self.services:
            if s.daemon == daemon:
                return s
        return None

    def __repr__(self):
        return "<Node %s pc=%s svc=%d>" % (self.name, self.point_code, len(self.services))


class Topology(object):
    def __init__(self):
        self.docker = True
        self.nodes = []
        self.hub_ip = ""
        self.hub_port = 2908
        self.hub_local = False
        self.repo = REPO
        self.errors = []

    @property
    def operators(self):
        return [n for n in self.nodes if n.role == "operator"]

    @property
    def hub(self):
        for n in self.nodes:
            if n.role == "interstp":
                return n
        return None

    def node(self, name):
        for n in self.nodes:
            if n.name == name:
                return n
        return None

    def free_point_codes(self, count=1):
        """Point codes libres pour la console, au FORMAT DU LAB (ITU 3-8-3).

        Le troisieme membre tient sur 3 bits : 0 a 7. Un "1.11.60" deborderait
        et serait recu comme un autre point code (1.15.4) - le message partirait
        vers un voisin, ou nulle part. On choisit donc dans les valeurs libres
        du meme groupe que les STP operateur (qui utilisent .1 a .3)."""
        used = set(n.point_code for n in self.nodes if n.point_code)
        for node in self.nodes:
            for addr in node.sccp.values():
                if addr.get("pc"):
                    used.add(addr["pc"])
        base = None
        for n in self.operators:
            if n.point_code:
                base = n.point_code
                break
        out = []
        heads = []
        if base and base.count(".") == 2:
            a, b, _ = base.split(".")
            heads.append((int(a), int(b)))
        heads.append((1, 11))
        for a, b in heads:
            for last in range(7, 0, -1):
                cand = "%d.%d.%d" % (a, b, last)
                if cand not in used and cand not in out:
                    out.append(cand)
                    if len(out) >= count:
                        return out
        while len(out) < count:
            out.append("1.11.7")
        return out

    def free_point_code(self):
        return self.free_point_codes(1)[0]


# ── lecture des configurations dans un noeud ──────────────────────────────────

_CFG_FILES = ["osmo-stp.cfg", "osmo-msc.cfg", "osmo-bsc.cfg", "osmo-hlr.cfg",
              "osmo-sgsn.cfg", "osmo-ggsn.cfg", "osmo-mgw.cfg"]


def _read_cfgs(name, docker):
    cfg = {}
    for f in _CFG_FILES:
        path = "/etc/osmocom/" + f
        if docker:
            txt = sh(["docker", "exec", name, "cat", path], timeout=10)
        else:
            try:
                txt = open(path).read()
            except Exception:
                txt = ""
        if txt.strip():
            cfg[f] = txt
    return cfg


def _parse_stp(node):
    txt = node.cfg.get("osmo-stp.cfg", "")
    if not txt:
        return
    m = re.search(r"^\s*point-code\s+(\S+)", txt, re.M)
    if m:
        node.point_code = m.group(1)
    m = re.search(r"^\s*listen\s+m3ua\s+(\d+)", txt, re.M)
    if m:
        node.local_m3ua = int(m.group(1))
    m = re.search(r"^\s*asp\s+asp-to-inter\s+(\d+)\s+(\d+)", txt, re.M)
    if m:
        node.hub_port = int(m.group(1))
    m = re.search(r"asp\s+asp-to-inter.*?^\s*remote-ip\s+(\S+)", txt, re.M | re.S)
    if m:
        node.hub_ip = m.group(1)
    m = re.search(r"as\s+as-inter.*?^\s*routing-key\s+(\d+)\s+(\S+)", txt, re.M | re.S)
    if m:
        node.routing_ctx = int(m.group(1))


def _parse_sccp(node):
    """Adresses SCCP declarees (osmo-bsc.cfg / osmo-msc.cfg) : c'est par la
    qu'on connait les SSN et les point codes des paires A-interface."""
    for fname in ("osmo-bsc.cfg", "osmo-msc.cfg"):
        txt = node.cfg.get(fname, "")
        if not txt:
            continue
        for blk in re.finditer(
                r"^\s*sccp-address\s+(\S+)\s*\n((?:\s+\S.*\n)*)", txt, re.M):
            name, body = blk.group(1), blk.group(2)
            entry = {"ssn": None, "pc": None, "ri": None, "source": fname}
            m = re.search(r"^\s*point-code\s+(\S+)", body, re.M)
            if m:
                entry["pc"] = m.group(1)
            m = re.search(r"^\s*subsystem-number\s+(\d+)", body, re.M)
            if m:
                entry["ssn"] = int(m.group(1))
            m = re.search(r"^\s*routing-indicator\s+(\S+)", body, re.M)
            if m:
                entry["ri"] = m.group(1)
            node.sccp[name] = entry
        # cs7 instance N / point-code du demon lui-meme
        m = re.search(r"^\s*point-code\s+(\S+)", txt, re.M)
        if m:
            node.sccp.setdefault("_self_" + fname, {"pc": m.group(1), "ssn": None,
                                                    "ri": None, "source": fname})


def _probe_vty(node, docker):
    if docker:
        raw = sh(["docker", "exec", "-i", node.name, "python3", "-c", _PROBE], timeout=30)
    else:
        raw = sh(["python3", "-c", _PROBE], timeout=30)
    try:
        found = json.loads(raw.strip().splitlines()[-1]) if raw.strip() else {}
    except Exception:
        found = {}
    for port, banner in sorted((int(p), b) for p, b in found.items()):
        daemon = ""
        m = re.search(r"Welcome to the (\S+) VTY interface", banner)
        if m:
            daemon = m.group(1)
        if not daemon:
            daemon = _BY_PORT.get(port, "VTY")
        label, family = _PRETTY.get(daemon, (daemon.replace("Osmo", ""), "autre"))
        node.services.append(Service(node.name, port, daemon, label, family))


def _env(name):
    raw = sh(["docker", "inspect", "-f", "{{json .Config.Env}}", name], timeout=10)
    env = {}
    try:
        for item in json.loads(raw or "[]"):
            if "=" in item:
                k, v = item.split("=", 1)
                env[k] = v
    except Exception:
        pass
    return env


def _native_present():
    """Cette machine porte-t-elle une pile Osmocom native ?"""
    if os.path.isdir("/etc/osmocom") and os.listdir("/etc/osmocom"):
        return True
    return bool(sh(["pgrep", "-f", "osmo-stp"]).strip())


def discover(docker=None, probe=True):
    topo = Topology()
    if docker is None:
        docker = bool(sh(["docker", "ps", "--format", "{{.Names}}"]).strip())
    topo.docker = docker

    names = []
    if docker:
        names = [n for n in sh(["docker", "ps", "--format", "{{.Names}}"]).split()
                 if n.startswith("osmo-")]
    if docker and not names:
        topo.errors.append("aucun conteneur osmo-* en cours d'execution")

    for name in sorted(names):
        if name == "osmo-inter-stp":
            node = Node(name, "interstp")
            topo.hub_local = True
        else:
            m = re.match(r"osmo-operator-(\d+)$", name)
            if not m:
                continue
            node = Node(name, "operator", int(m.group(1)))
        node.env = _env(name)
        node.cfg = _read_cfgs(name, True)
        _parse_stp(node)
        _parse_sccp(node)
        if probe:
            _probe_vty(node, True)
        node.wan_node = node.env.get("OSMO_WAN_NODE", node.env.get("WAN_NODE_ID", ""))
        if not node.hub_ip:
            node.hub_ip = node.env.get("OSMO_HUB_IP", "")
        topo.nodes.append(node)

    # Repli natif : SEULEMENT si cette machine porte vraiment une pile Osmocom.
    # Sans cette verification, un lab docker eteint se presentait comme un
    # "operateur natif" sans point code ni service - un inventaire imaginaire,
    # plus trompeur qu'un franc "il n'y a rien ici".
    if not docker and not _native_present():
        topo.errors.append(
            "aucun noeud : ni conteneur osmo-* en cours, ni /etc/osmocom sur "
            "cette machine (le lab est arrete ?)")
    elif not docker:
        node = Node("local", "operator", 1)
        node.cfg = _read_cfgs("local", False)
        _parse_stp(node)
        _parse_sccp(node)
        if probe:
            _probe_vty(node, False)
        # Un repertoire /etc/osmocom peut n'etre qu'un reste d'installation :
        # sans point code lisible ni VTY qui repond, il n'y a pas de noeud.
        if node.point_code or node.services:
            topo.nodes.append(node)
        else:
            topo.errors.append(
                "/etc/osmocom existe mais aucun demon Osmocom ne repond ici "
                "(ni point code, ni VTY) : rien a inventorier")

    for n in topo.operators:
        if n.hub_ip:
            topo.hub_ip = n.hub_ip
            topo.hub_port = n.hub_port
            break
    if topo.hub_local and not topo.hub_ip:
        topo.hub_ip = "172.20.0.10"

    hub = topo.hub
    if hub is None and topo.hub_ip:
        # Hub distant (WAN) : il ne tourne pas ici, mais il fait partie du
        # schema - c'est par lui que passe tout le SS7 inter-operateur.
        hub = Node("hub-distant", "interstp")
        hub.point_code = "0.0.0"
        hub.hub_ip = topo.hub_ip
        hub.hub_port = topo.hub_port
        topo.nodes.append(hub)
    elif hub is not None and not hub.point_code:
        hub.point_code = "0.0.0"
    return topo

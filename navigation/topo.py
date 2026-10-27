# topo.py - inventory of the lab, INHERITED from the configurations.
#
# Nothing is hard-coded: point codes, addresses, ports and services are read
# where they are authoritative.
#
#   1. "docker ps"                      -> which nodes run here;
#   2. the container environment        -> OSMO_HUB_IP, WAN_NODE_ID (set by
#                                          start-docker.sh, see --hub-ip / --wan);
#   3. /etc/osmocom/*.cfg IN the node   -> point code, routing keys, M3UA
#                                          listeners, SCCP addresses, links to
#                                          the hub. This is the REAL
#                                          configuration, not the repo template;
#   4. /proc/net/tcp IN the node        -> which VTYs really listen, and each
#                                          banner says WHICH daemon answers
#                                          (OsmoMSC, OsmoHLR, ...).
#
# The templates in configs/ are only a fallback when no node runs.

import json
import os
import re
import subprocess

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Probe pushed into the node: lists the listening VTYs and reads their
# banner. One execution per node, all in parallel.
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

# Short name shown in the diagram, derived from the banner ("OsmoMSC" -> MSC).
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

# Fallback when the banner says nothing (silent VTY, daemon still starting).
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
    """A daemon reachable by VTY on a node."""

    def __init__(self, node, port, daemon, label, family):
        self.node = node
        self.port = int(port)
        self.daemon = daemon
        self.label = label
        self.family = family

    def __repr__(self):
        return "<Service %s:%s %s>" % (self.node, self.port, self.label)


class Node(object):
    """A lab node: operator container, or inter-STP hub."""

    def __init__(self, name, role, index=None):
        self.name = name            # container name, or "local"
        self.role = role            # "operator" | "interstp"
        self.index = index          # operator number
        self.point_code = ""        # 1.11.2
        self.hub_ip = ""            # inter-STP address as seen by this node
        self.hub_port = 2908
        self.local_m3ua = 2905
        self.routing_ctx = None     # routing key to the hub
        self.wan_node = ""
        self.services = []          # [Service]
        self.sccp = {}              # name -> {"pc":..., "ssn":..., "ri":...}
        self.env = {}
        self.cfg = {}               # file -> text

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
        """Free point codes for the console, in the LAB FORMAT (ITU 3-8-3).

        The third member fits in 3 bits: 0 to 7. A "1.11.60" would overflow
        and be received as another point code (1.15.4) - the message would go
        to a neighbour, or nowhere. The choice is therefore made among the
        free values of the same group as the operator STPs (which use .1 to
        .3)."""
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


# ── reading the configurations in a node ──────────────────────────────────────

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
    """Declared SCCP addresses (osmo-bsc.cfg / osmo-msc.cfg): this is where
    the SSNs and point codes of the A-interface pairs come from."""
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
        # cs7 instance N / point-code of the daemon itself
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
    """Does this machine carry a native Osmocom stack?"""
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

    # Native fallback: ONLY if this machine really carries an Osmocom stack.
    # Without this check, a stopped docker lab would show up as a "native
    # operator" with no point code nor service - an imaginary inventory,
    # more misleading than a plain "nothing here".
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
        # An /etc/osmocom directory may be a mere leftover of an install:
        # without a readable point code nor an answering VTY, there is no node.
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
        # Remote hub (WAN): it does not run here, but it is part of the
        # diagram - all inter-operator SS7 goes through it.
        hub = Node("hub-distant", "interstp")
        hub.point_code = "0.0.0"
        hub.hub_ip = topo.hub_ip
        hub.hub_port = topo.hub_port
        topo.nodes.append(hub)
    elif hub is not None and not hub.point_code:
        hub.point_code = "0.0.0"
    return topo

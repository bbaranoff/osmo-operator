# diagram.py - le schema du lab, dessine en caracteres, et navigable.
#
# Chaque element du reseau devient une BOITE placee sur une grille de
# caracteres. Les fleches ne suivent pas une liste : elles se deplacent dans
# l'espace, vers la boite la plus proche dans la direction demandee. C'est ce
# qui fait qu'on "circule" dans le schema comme sur une carte.
#
# Les boites sont construites a partir de la topologie decouverte : rien
# n'est dessine qui n'existe pas dans le lab.

BOX_W = 20

# Ordre d'affichage des services : le coeur d'abord, la radio ensuite, le
# reste apres. Ce qui n'est pas liste garde son ordre de decouverte.
FAMILY_ORDER = {"SS7": 0, "coeur": 1, "abonnes": 2, "radio": 3, "media": 4,
                "data": 5, "voix": 6, "mobile": 7, "autre": 8}


class Box(object):
    __slots__ = ("key", "x", "y", "w", "h", "kind", "title", "lines", "ref",
                 "node", "color")

    def __init__(self, key, x, y, w, h, kind, title, lines, ref=None,
                 node=None, color=0):
        self.key = key
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.kind = kind          # hub | stp | service | console | note
        self.title = title
        self.lines = lines
        self.ref = ref            # Service, Node, ou None
        self.node = node          # Node auquel la boite appartient
        self.color = color

    @property
    def cx(self):
        return self.x + self.w // 2

    @property
    def cy(self):
        return self.y + self.h // 2

    def contains(self, x, y):
        return self.x <= x < self.x + self.w and self.y <= y < self.y + self.h


class Canvas(object):
    def __init__(self, width, height):
        self.w = width
        self.h = height
        self.grid = [[" "] * width for _ in range(height)]

    def put(self, x, y, text):
        if y < 0 or y >= self.h:
            return
        for i, ch in enumerate(text):
            if 0 <= x + i < self.w:
                self.grid[y][x + i] = ch

    def hline(self, x1, x2, y, ch="─"):
        for x in range(min(x1, x2), max(x1, x2) + 1):
            if 0 <= x < self.w and 0 <= y < self.h:
                cur = self.grid[y][x]
                self.grid[y][x] = "┼" if cur in "│├┤" else ch

    def vline(self, y1, y2, x, ch="│"):
        for y in range(min(y1, y2), max(y1, y2) + 1):
            if 0 <= x < self.w and 0 <= y < self.h:
                cur = self.grid[y][x]
                self.grid[y][x] = "┼" if cur in "─┬┴" else ch

    def box(self, b):
        top = "┌" + "─" * (b.w - 2) + "┐"
        bot = "└" + "─" * (b.w - 2) + "┘"
        self.put(b.x, b.y, top)
        rows = [b.title] + b.lines
        for i in range(b.h - 2):
            text = rows[i] if i < len(rows) else ""
            self.put(b.x, b.y + 1 + i, "│" + text.ljust(b.w - 2)[:b.w - 2] + "│")
        self.put(b.x, b.y + b.h - 1, bot)

    def render(self):
        return ["".join(row).rstrip() for row in self.grid]


def _service_sort(service):
    return (FAMILY_ORDER.get(service.family, 9), service.port)


def build(topo, extra=None):
    """Rend (lignes, boites). extra : dict d'etat de la console SS7."""
    extra = extra or {}
    ops = topo.operators
    per_op_cols = 2
    svc_rows = max([1] + [(len(o.services) + per_op_cols - 1) // per_op_cols
                          for o in ops])

    col_w = per_op_cols * (BOX_W + 2) + 2
    width = max(80, len(ops) * col_w + 8)
    height = 12 + svc_rows * 4 + 8
    cv = Canvas(width, height)
    boxes = []

    # ── bandeau ──────────────────────────────────────────────────────────
    cv.put(2, 0, "RESEAU SS7 - %s" % ("docker" if topo.docker else "natif"))

    # ── hub inter-STP ────────────────────────────────────────────────────
    hub = topo.hub
    hub_x = max(2, width // 2 - BOX_W // 2)
    hub_y = 2
    hub_lines = []
    if hub:
        hub_lines.append("PC %s" % (hub.point_code or "?"))
        hub_lines.append("%s:%d" % (topo.hub_ip or "?", topo.hub_port))
        hub_lines.append("M3UA/SCTP" if not topo.hub_local else "local")
    else:
        hub_lines = ["aucun hub", "declare", ""]
    hb = Box("hub", hub_x, hub_y, BOX_W + 6, 6, "hub", " INTER-STP (hub) ",
             hub_lines, ref=hub, node=hub)
    cv.box(hb)
    boxes.append(hb)

    # ── console SS7 (nous) ───────────────────────────────────────────────
    con_x = max(2, hub_x - BOX_W - 10)
    con_lines = [
        "PC %s" % extra.get("local_pc", topo.free_point_code()),
        "SSN %s" % extra.get("local_ssn", 8),
        extra.get("state", "hors ligne"),
    ]
    cb = Box("console", con_x, hub_y, BOX_W + 4, 6, "console", " CONSOLE SS7 ",
             con_lines)
    cv.box(cb)
    boxes.append(cb)
    cv.hline(cb.x + cb.w, hb.x - 1, hub_y + 2)
    cv.put(cb.x + cb.w + 1, hub_y + 1, "M3UA")

    # ── bus vers les operateurs ──────────────────────────────────────────
    bus_y = hub_y + 7
    cv.vline(hub_y + 6, bus_y, hb.cx)
    if ops:
        first_x = 4
        xs = []
        for i, _ in enumerate(ops):
            xs.append(first_x + i * col_w + (col_w - BOX_W) // 2)
        cv.hline(min(xs) + BOX_W // 2, max(xs) + BOX_W // 2, bus_y)
        cv.put(hb.cx - 4, bus_y - 1, "")

        for i, node in enumerate(ops):
            x = xs[i]
            stp_y = bus_y + 2
            cv.vline(bus_y, stp_y, x + BOX_W // 2)
            lines = ["PC %s" % (node.point_code or "?"),
                     "M3UA %s" % node.local_m3ua,
                     "noeud WAN %s" % (node.wan_node or "-")]
            sb = Box("stp:%s" % node.name, x, stp_y, BOX_W + 4, 6, "stp",
                     " %s - STP " % node.title, lines, ref=node, node=node)
            cv.box(sb)
            boxes.append(sb)

            svc_y = stp_y + 7
            cv.vline(stp_y + 6, svc_y - 1, x + BOX_W // 2)
            services = sorted(node.services, key=_service_sort)
            for j, svc in enumerate(services):
                row, col = divmod(j, per_op_cols)
                bx = x - 2 + col * (BOX_W + 2)
                by = svc_y + row * 4
                lines = ["VTY %d  %s" % (svc.port, svc.family)]
                box = Box("svc:%s:%d" % (node.name, svc.port), bx, by,
                          BOX_W, 4, "service", " %s" % svc.label, lines,
                          ref=svc, node=node)
                cv.box(box)
                boxes.append(box)
    else:
        cv.put(4, bus_y + 2, "aucun operateur en cours d'execution")

    lines = cv.render()
    while lines and not lines[-1].strip():
        lines.pop()
    return lines, boxes


def navigate(boxes, current, direction):
    """Boite la plus proche dans une direction. dx/dy en {-1,0,1}."""
    if not boxes:
        return current
    cur = boxes[current]
    dx, dy = direction
    best = None
    best_score = None
    for i, b in enumerate(boxes):
        if i == current:
            continue
        vx = b.cx - cur.cx
        vy = b.cy - cur.cy
        if dx and (vx * dx) <= 0:
            continue
        if dy and (vy * dy) <= 0:
            continue
        # Distance dans l'axe demande, penalisee par l'ecart lateral : on
        # prefere ce qui est "droit devant" a ce qui est loin sur le cote.
        along = abs(vx) if dx else abs(vy)
        across = abs(vy) if dx else abs(vx)
        score = along + across * 2.5
        if best_score is None or score < best_score:
            best_score = score
            best = i
    return best if best is not None else current

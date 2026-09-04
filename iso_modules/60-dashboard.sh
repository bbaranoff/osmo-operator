#!/bin/bash
# iso_modules/60-dashboard.sh - etape 6 : dashboard web
# Source par build-iso.sh, dans l ordre des numeros : meme shell, memes
# variables, memes fonctions. Ne s execute pas seul. `return` en tete de
# module = "rien a faire ici" (c est ainsi que --arm saute une etape).

# ── Etape 6 : Injection du dashboard web ───────────────────────────────────
echo -e "${GREEN}[6/9] Dashboard web (git clone)...${NC}"
WEB="$ROOTFS/opt/GSM/osmo-egprs-web"
WEB_REPO="${OSMO_WEB_REPO:-https://github.com/bbaranoff/osmo-egprs-web.git}"
# main, PAS "test". La branche de travail du depot web partait dans toutes les
# ISO : une image gravee recevait ce qui n'etait pas encore relu, et deux ISO
# construites a deux semaines d'ecart n'embarquaient pas le meme dashboard sans
# qu'aucune option ne l'ait demande. OSMO_WEB_BRANCH=test reste possible, mais
# il faut le vouloir.
WEB_BRANCH="${OSMO_WEB_BRANCH:-main}"

mkdir -p "$WEB/web"
# Source AUTORITAIRE = le VRAI git bbaranoff/osmo-egprs-web (clone ci-dessous).
# La copie locale /opt/GSM/osmo-egprs-web n'est plus utilisee que comme override
# EXPLICITE : OSMO_WEB_LOCAL=/chemin ./build-iso.sh. Sinon -> git.
# Le patch natif plus bas est idempotent (skip si server.js est deja en mode natif).
LOCAL_WEB="${OSMO_WEB_LOCAL:-}"
if [ -n "$LOCAL_WEB" ] && [ -f "$LOCAL_WEB/server.js" ]; then
    cp "$LOCAL_WEB/server.js" "$WEB/server.js"
    [ -f "$LOCAL_WEB/package.json" ] && cp "$LOCAL_WEB/package.json" "$WEB/package.json"
    [ -d "$LOCAL_WEB/web" ]          && cp -r "$LOCAL_WEB/web/."     "$WEB/web/"
    [ -f "$LOCAL_WEB/start-web.sh" ] && cp "$LOCAL_WEB/start-web.sh" "$WEB/" && chmod +x "$WEB/start-web.sh"
    [ -f "$LOCAL_WEB/Dockerfile" ]   && cp "$LOCAL_WEB/Dockerfile"   "$WEB/Dockerfile"
    # Le depot suit les fichiers : c'est lui qui evite le reclone au demarrage.
    [ -d "$LOCAL_WEB/.git" ]         && cp -a "$LOCAL_WEB/.git"     "$WEB/"
    echo -e "  ${GREEN}✓${NC} osmo-egprs-web depuis source LOCALE ($LOCAL_WEB)"
else
    WEB_TMP="$WORK/osmo-egprs-web"
    GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$WEB_BRANCH" "$WEB_REPO" "$WEB_TMP" 2>&1 | tail -2 || true
    # [2026-08-27] Le clone entier part dans l'image, .git COMPRIS. Avant, on ne
    # prelevait que quelques fichiers : l'ISO recevait un dossier sans depot, et
    # update.sh, faute de .git, ne pouvait qu'EFFACER et RECLONER a chaque
    # demarrage (wipe=1) - sans reseau, plus de dashboard du tout.
    # cp -a : les fichiers deja poses par un override local ne sont pas effaces,
    # ils sont recouverts par ceux du depot.
    [ -d "$WEB_TMP/.git" ] && cp -a "$WEB_TMP/." "$WEB/"
    # Layout REEL du repo : server.js / package.json / web/ / start-web.sh a la
    # RACINE (fallback sous server/ pour un ancien layout).
    if   [ -f "$WEB_TMP/server.js" ];        then cp "$WEB_TMP/server.js"        "$WEB/server.js"
    elif [ -f "$WEB_TMP/server/server.js" ]; then cp "$WEB_TMP/server/server.js" "$WEB/server.js"; fi
    if   [ -f "$WEB_TMP/package.json" ];        then cp "$WEB_TMP/package.json"        "$WEB/package.json"
    elif [ -f "$WEB_TMP/server/package.json" ]; then cp "$WEB_TMP/server/package.json" "$WEB/package.json"; fi
    [ -d "$WEB_TMP/web" ]          && cp -r "$WEB_TMP/web/."     "$WEB/web/"
    [ -f "$WEB_TMP/start-web.sh" ] && cp "$WEB_TMP/start-web.sh" "$WEB/" && chmod +x "$WEB/start-web.sh"
    [ -f "$WEB_TMP/Dockerfile" ]   && cp "$WEB_TMP/Dockerfile"   "$WEB/Dockerfile"
    if [ -f "$WEB/server.js" ]; then
        echo -e "  ${GREEN}✓${NC} osmo-egprs-web depuis le git ${CYAN}$WEB_REPO${NC} ($WEB_BRANCH)"
    else
        echo -e "  ${RED}✗ clone osmo-egprs-web sans server.js - dashboard incomplet${NC}"
    fi
fi

# ── LE TUTORIEL, SERVI PAR LE DASHBOARD ─────────────────────────────────────
# Ici et pas ailleurs : $WEB vient d etre peuple (clone ou source locale), et
# c est la seule racine statique que le dashboard expose. /usr/share garde un
# exemplaire pour le repli hors ligne, mais c est CELUI-CI que l icone ouvre -
# voir /usr/local/bin/osmo-tutorial et le confinement du snap Firefox.
if [ -f "$DIR/data/tutorial.html" ]; then
    mkdir -p "$WEB/web"
    cp -f "$DIR/data/tutorial.html" "$WEB/web/tutorial.html"
    echo -e "  ${GREEN}✓${NC} tutoriel servi par le dashboard : ${CYAN}/tutorial.html${NC}"
fi

# Patch server.js : mode natif (no-docker). VTY en telnet direct sur 127.0.0.1
# (ou ip netns exec) au lieu de docker exec. Idempotent ; n'echoue pas le build.
if [ -f "$WEB/server.js" ] && command -v python3 >/dev/null 2>&1; then
python3 - "$WEB/server.js" <<'PYEOF' || echo -e "  ${YELLOW}[web] patch natif non applique (server.js amont a change ?)${NC}"
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'const NATIVE' in s:
    print('  [web] server.js deja en mode natif - skip'); sys.exit(0)
HELPERS = """
// ─── Native (no-docker) mode ─────────────────────────────────
const NATIVE        = (process.env.OSMO_NATIVE !== '0');
const OP_IDS        = (process.env.OSMO_OP_IDS || '1').split(',')
                        .map(function(s){ return parseInt(s, 10); })
                        .filter(function(n){ return !isNaN(n); });
const NETNS_PREFIX  = process.env.OSMO_NETNS_PREFIX || '';
function vtyProc(container, port, ip, id) {
  if (NATIVE) {
    if (NETNS_PREFIX) return { bin: 'ip', args: ['netns','exec', NETNS_PREFIX + id, 'telnet', ip, String(port)] };
    return { bin: 'telnet', args: [ip, String(port)] };
  }
  return { bin: 'docker', args: ['exec','-i', container, 'telnet', ip, String(port)] };
}
function shCmd(container, id, inner) {
  if (NATIVE) {
    if (NETNS_PREFIX) return 'ip netns exec ' + NETNS_PREFIX + id + ' bash -c "' + inner + '"';
    return 'bash -c "' + inner + '"';
  }
  return 'docker exec ' + container + ' bash -c "' + inner + '"';
}
"""
n = [0]
def sub(pat, rep, flags=0):
    global s
    s, c = re.subn(pat, rep, s, flags=flags); n[0]+=c; return c
sub(r"(const VTY_RETRY_DELAY = 2000;)", r"\1\n" + HELPERS.replace('\\','\\\\'))
sub(r"(function discoverOperators\(\) \{)", r"\1\n  if (NATIVE) return Promise.resolve(OP_IDS.slice());")
sub(r"var proc = spawn\('docker', \[\s*'exec', '-i', container, 'telnet', targetIp, String\(port\)\s*\], \{ stdio: \['pipe','pipe','pipe'\] \}\);",
    "var vc = vtyProc(container, port, targetIp, String(container).replace(PREFIX, ''));\n    var proc = spawn(vc.bin, vc.args, { stdio: ['pipe','pipe','pipe'] });", re.DOTALL)
sub(r"return execAsync\(\s*'docker inspect.*?\)\.then\(function\(running\) \{",
    "var runningProbe = NATIVE\n    ? execAsync(shCmd(container, id, 'ss -tln 2>/dev/null | grep -q :' + VTY_PORTS.bsc + ' && echo true || echo false'), 3000)\n    : execAsync('docker inspect -f \\'{{.State.Running}}\\' ' + container + ' 2>/dev/null', 3000);\n  return runningProbe.then(function(running) {", re.DOTALL)
sub(r"execAsync\(\s*'docker exec ' \+ container \+ ' bash -c \"ss -tlnp.*?', 3000\s*\)",
    "execAsync(\n        shCmd(container, id, 'ss -tlnp 2>/dev/null | grep :7890 | wc -l'), 3000\n      )", re.DOTALL)
sub(r"log\('VTY open: docker exec.*?\], \{ stdio: \['pipe','pipe','pipe'\] \}\);",
    "var vc = vtyProc(this.container, this.port, this.ip, this.opId);\n  log('VTY open: ' + vc.bin + ' ' + vc.args.join(' ') + ' (attempt ' + (this.retries + 1) + ')');\n\n  this.proc = spawn(vc.bin, vc.args, { stdio: ['pipe','pipe','pipe'] });", re.DOTALL)
open(p,'w',encoding='utf-8').write(s)
print('  [web] server.js patche mode natif (%d remplacements)' % n[0])
sys.exit(0 if n[0] >= 6 else 2)
PYEOF
fi

# ── LE DASHBOARD DOIT SE LEVER SEUL, ICI COMME SUR LE DISQUE ────────────────
# Tout etait deja dans l image - server.js, node, node_modules - SAUF les deux
# unites systemd. services/ n etait copie nulle part par ce script : l ISO
# arrivait donc avec un dashboard complet et rien pour le demarrer, et il
# fallait lancer install-web-service.sh a la main a chaque demarrage. C est
# exactement ce qu on a constate sur le banc.
#
# DEUX UNITES, ET PAS UNE :
#   osmo-egprs-web.service          le dashboard lui-meme.
#   osmo-egprs-web-install.service  un oneshot qui rejoue install-web-service.sh
#                                   AU BOOT. Il porte le certificat TLS, et
#                                   c est la seule place correcte pour lui : une
#                                   cle posee ici, au build, serait la MEME dans
#                                   toutes les ISO tirees de cette image -
#                                   n importe qui pourrait se faire passer pour
#                                   la console. Genere au boot, il porte le nom
#                                   et les adresses REELS de la machine, ce qui
#                                   vaut aussi pour le systeme installe : le
#                                   disque recoit les unites avec le squashfs et
#                                   fabrique SON propre certificat au premier
#                                   demarrage, different de celui de la cle.
#
# On active l ONESHOT, pas le service : le script se termine par un
# `systemctl restart osmo-egprs-web` et l unite le dit - l ordonner avant le
# service creerait un cycle. Le dashboard est tire par lui.
_SVC_SRC="$DIR/services"
# [2026-08-31] SEUL LE SERVICE DU DASHBOARD EST POSE. Le oneshot d installation
# (osmo-egprs-web-install.service) n est plus deploye : il rejouait au premier
# demarrage un script qui TELECHARGE node s il manque, donc un boot qui exige
# Internet. L installation est faite au BUILD (Dockerfile, RUN bash
# install-web-service.sh) : l image arrive complete, le boot ne fait que lancer.
if [ -f "$_SVC_SRC/osmo-egprs-web.service" ]; then
    install -d "$ROOTFS/etc/systemd/system/multi-user.target.wants"
    cp -f "$_SVC_SRC/osmo-egprs-web.service"         "$ROOTFS/etc/systemd/system/"
    # Le depot web embarque sa propre copie du unit, qui a deja DIVERGE de
    # celle-ci (cf. Dockerfile) : on impose celle du depot operateur, une seule
    # verite.
    [ -d "$ROOTFS/opt/GSM/osmo-egprs-web" ] && \
        cp -f "$_SVC_SRC/osmo-egprs-web.service" \
              "$ROOTFS/opt/GSM/osmo-egprs-web/osmo-egprs-web.service"
    ln -sf /etc/systemd/system/osmo-egprs-web.service \
           "$ROOTFS/etc/systemd/system/multi-user.target.wants/osmo-egprs-web.service"
    echo -e "  ${GREEN}✓${NC} dashboard : unite ${CYAN}osmo-egprs-web${NC} posee et activee au boot"
else
    echo -e "  ${RED}✗ services/osmo-egprs-web*.service introuvables - le dashboard ne demarrerait pas seul${NC}" >&2
    exit 1
fi

# /usr/local/bin/node pointait sur /opt/node/bin/node, absent de l image : un
# lien mort AVANT /usr/bin dans le PATH. `node` marche par chance, parce que le
# shell continue son parcours ; un script qui teste `-x /usr/local/bin/node`,
# lui, se trompe. On ne garde le lien que s il mene quelque part.
if [ -L "$ROOTFS/usr/local/bin/node" ] && [ ! -e "$ROOTFS/usr/local/bin/node" ]; then
    rm -f "$ROOTFS/usr/local/bin/node" "$ROOTFS/usr/local/bin/npm" "$ROOTFS/usr/local/bin/npx"
    echo -e "  ${GREEN}✓${NC} liens morts /usr/local/bin/node,npm,npx retires (node reste en /usr/bin)"
fi


# Fin de module : `. fichier` rend le statut de sa DERNIERE commande, et
# build-iso.sh tourne sous set -e. Un module qui finirait par un test faux
# ("[ ... ] && { ...; }") arreterait tout, sans un mot. Toujours 0 ici.
true

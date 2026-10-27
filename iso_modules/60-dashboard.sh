#!/bin/bash
# iso_modules/60-dashboard.sh - step 6: web dashboard (osmo-egprs-web)
# Sourced by build-iso.sh in numeric order: same shell, same variables, same
# functions. Not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (this is how --arm skips a step).
#
# Environment:
#   OSMO_WEB_REPO=<url>      dashboard git repository
#   OSMO_WEB_BRANCH=<branch> branch to clone (default: main)
#   OSMO_WEB_LOCAL=<dir>     use this local tree instead of cloning

# ── Step 6: web dashboard injection ─────────────────────────────────────────
echo -e "${GREEN}[6/9] Dashboard web (git clone)...${NC}"
WEB="$ROOTFS/opt/GSM/osmo-egprs-web"
WEB_REPO="${OSMO_WEB_REPO:-https://github.com/bbaranoff/osmo-egprs-web.git}"
# Default branch is main (reviewed code); OSMO_WEB_BRANCH=test must be explicit.
WEB_BRANCH="${OSMO_WEB_BRANCH:-main}"

mkdir -p "$WEB/web"
# Source of truth: the bbaranoff/osmo-egprs-web git repo (cloned below).
# A local tree is only used when requested: OSMO_WEB_LOCAL=<dir> ./build-iso.sh.
# The native patch below is idempotent (skipped if server.js is already native).
LOCAL_WEB="${OSMO_WEB_LOCAL:-}"
if [ -n "$LOCAL_WEB" ] && [ -f "$LOCAL_WEB/server.js" ]; then
    cp "$LOCAL_WEB/server.js" "$WEB/server.js"
    [ -f "$LOCAL_WEB/package.json" ] && cp "$LOCAL_WEB/package.json" "$WEB/package.json"
    [ -d "$LOCAL_WEB/web" ]          && cp -r "$LOCAL_WEB/web/."     "$WEB/web/"
    [ -f "$LOCAL_WEB/start-web.sh" ] && cp "$LOCAL_WEB/start-web.sh" "$WEB/" && chmod +x "$WEB/start-web.sh"
    [ -f "$LOCAL_WEB/Dockerfile" ]   && cp "$LOCAL_WEB/Dockerfile"   "$WEB/Dockerfile"
    # The .git lets update.sh fetch instead of recloning at boot.
    [ -d "$LOCAL_WEB/.git" ]         && cp -a "$LOCAL_WEB/.git"     "$WEB/"
    echo -e "  ${GREEN}✓${NC} osmo-egprs-web depuis source LOCALE ($LOCAL_WEB)"
else
    WEB_TMP="$WORK/osmo-egprs-web"
    GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$WEB_BRANCH" "$WEB_REPO" "$WEB_TMP" 2>&1 | tail -2 || true
    # The whole clone, .git included, goes into the image so that update.sh can
    # fetch incrementally instead of wiping and recloning at boot.
    # cp -a: files already placed by a local override are overwritten, not removed.
    [ -d "$WEB_TMP/.git" ] && cp -a "$WEB_TMP/." "$WEB/"
    # Repo layout: server.js / package.json / web/ / start-web.sh at the ROOT
    # (fallback to server/ for an older layout).
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

# ── Tutorial, served by the dashboard ───────────────────────────────────────
# Done here because $WEB has just been populated and is the only static root
# the dashboard exposes. /usr/share keeps an offline fallback copy, but the
# icon opens THIS one - see /usr/local/bin/osmo-tutorial.
if [ -f "$DIR/data/tutorial.html" ]; then
    mkdir -p "$WEB/web"
    cp -f "$DIR/data/tutorial.html" "$WEB/web/tutorial.html"
    echo -e "  ${GREEN}✓${NC} tutoriel servi par le dashboard : ${CYAN}/tutorial.html${NC}"
fi
# The help page (the dock "?" button) is served the same way; see
# /usr/local/bin/osmo-info.
if [ -f "$DIR/configs/info.html" ]; then
    mkdir -p "$WEB/web"
    cp -f "$DIR/configs/info.html" "$WEB/web/info.html"
    echo -e "  ${GREEN}✓${NC} aide servie par le dashboard : ${CYAN}/info.html${NC}"
fi

# Patch server.js for native (no-docker) mode: VTY via direct telnet to
# 127.0.0.1 (or ip netns exec) instead of docker exec. Idempotent; never fails
# the build.
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

# ── The dashboard must start on its own (live ISO and installed disk) ───────
_SVC_SRC="$DIR/services"
# Only the dashboard unit (osmo-egprs-web.service) is installed and enabled.
# The web installation itself is done at image BUILD time (Dockerfile:
# RUN bash install-web-service.sh), so boot does not need Internet.
if [ -f "$_SVC_SRC/osmo-egprs-web.service" ]; then
    install -d "$ROOTFS/etc/systemd/system/multi-user.target.wants"
    cp -f "$_SVC_SRC/osmo-egprs-web.service"         "$ROOTFS/etc/systemd/system/"
    # The web repo ships its own, diverging copy of the unit: the operator
    # repo's copy is imposed as the single source of truth.
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

# Remove /usr/local/bin/node if it is a dangling link (e.g. to the absent
# /opt/node/bin/node): it precedes /usr/bin in PATH and misleads scripts that
# test `-x /usr/local/bin/node`.
if [ -L "$ROOTFS/usr/local/bin/node" ] && [ ! -e "$ROOTFS/usr/local/bin/node" ]; then
    rm -f "$ROOTFS/usr/local/bin/node" "$ROOTFS/usr/local/bin/npm" "$ROOTFS/usr/local/bin/npx"
    echo -e "  ${GREEN}✓${NC} liens morts /usr/local/bin/node,npm,npx retires (node reste en /usr/bin)"
fi

# End of module: `. file` returns the status of its LAST command and
# build-iso.sh runs under set -e. A module ending with a false test
# ("[ ... ] && { ...; }") would abort everything silently. Always 0 here.
true

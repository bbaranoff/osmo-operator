#!/bin/bash
# conky-osmo-status.sh - the lines of the bench Conky (configs/conky/osmo-conky.conf)
#   role | vue | net | hub | core | radio | lte | subs | services
# Every output is conky text (execpi): ${color2} green, ${color3} red,
# ${color4} yellow. Fast and without hard dependency: whatever is missing shows "-".
set -u
# GLYPHS IN DEJAVU SANS, TEXT IN UBUNTU. The Conky is entirely in Ubuntu
# (osmo-conky.conf), which has neither ● ○ nor ↓ ↑ ◀ ▶ ☺: they render as
# squares. Each glyph is therefore wrapped in a switch to DejaVu Sans (FS)
# followed by a return to the default font (FU = ${font}, i.e. Ubuntu).
# AT THE SAME SIZE (9) as the default font, and that matters: Conky computes
# its window height with the default font but DRAWS each line at the height
# of the tallest font met on it. With DejaVu at 8 (or 7, or Mono) every line
# with dots is drawn 6 px lower than computed, and after twenty lines the
# bottom of the Conky falls out of the window (21 px per line for 15
# computed). At 9 the metrics match and the window fits.
FS="\${font ${OSMO_CONKY_FS:-DejaVu Sans:size=9}}"; FU='${font}'
OK="${FS}\${color2}●\${color}${FU}"; KO="${FS}\${color3}○\${color}${FU}"; WARN="${FS}\${color4}●\${color}${FU}"
# One smiley for EACH stop of the bench (op1, op2, op3, hub, 4G): green smile
# when the stop is running, grey frown when it is down.
SMILE="${FS}\${color2}☺\${color}${FU}"; SAD="${FS}\${color5}☹\${color}${FU}"
C1='${color1}'; C='${color}'; C2='${color2}'; AR='${alignr}'
have() { command -v "$1" >/dev/null 2>&1; }
# ── pgrep -x COMPARES AGAINST THE NAME TRUNCATED TO 15 CHARACTERS ───────────
# The kernel keeps only 15 characters of process name (comm): osmo-sip-connector
# is « osmo-sip-connec », proto-smsc-daemon is « proto-smsc-daem ». `pgrep -x`
# with the full name never matches, so the pattern is truncated the same way.
# ── THE OPERATOR SELECTED IN THE PANEL ──────────────────────────────────────
# tools/osmo-panel.py (arrows < >) writes /run/osmo-fft/operator:
# OP=, MODE=native|docker, IP=, NAME=osmo-operator-N. On a container, every
# probe (pgrep, port, sqlite) runs INSIDE it (docker exec): the Conky follows
# the panel. Without the file, or in native mode: the local machine.
OP_FILE="${OSMO_FFT_DIR:-/run/osmo-fft}/operator"
OP_ID=1; OP_MODE=native; OP_NAME=""
if [ -r "$OP_FILE" ]; then
    OP_ID="$(sed -n 's/^OP=//p' "$OP_FILE" | head -1)"; OP_ID="${OP_ID:-1}"
    OP_MODE="$(sed -n 's/^MODE=//p' "$OP_FILE" | head -1)"; OP_MODE="${OP_MODE:-native}"
    OP_NAME="$(sed -n 's/^NAME=//p' "$OP_FILE" | head -1)"
fi
# in_op CMD...: run the command here, or inside the operator's container.
if [ "$OP_MODE" = docker ] && [ -n "$OP_NAME" ]; then
    in_op() { docker exec "$OP_NAME" "$@" 2>/dev/null; }
else
    in_op() { "$@"; }
fi
port_open() {
    if [ "$OP_MODE" = docker ]; then in_op timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/$1" 2>/dev/null
    else timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/$1" 2>/dev/null; fi
}
alive_x() { in_op pgrep -x "${1:0:15}" >/dev/null 2>&1; }
# ── IS THE BENCH UP? ────────────────────────────────────────────────────────
# Without a bench, the « Coeur GSM », « Radio / MS », « Abonnes » and
# « Services » sections would show thirty red dots - a wall of alarms saying
# one thing: nothing runs. That hides what actually matters when the bench
# is down: the network, the disk space, the machine.
#
# When the stack is down these sections therefore render NOTHING: the Conky
# falls back on the machine, and the titles stay as landmarks. The Network
# section is the only one that ALWAYS speaks - it depends on no operator, and
# it is precisely what one looks at when the bench does not come up.
#
# The criterion: the STP, BSC or MSC of the displayed operator. These are the
# processes that exist as soon as the core is up, in both worlds (native and
# container) - and in_op looks for them in the right place.
banc_debout() { alive_x osmo-stp || alive_x osmo-bsc || alive_x osmo-msc; }
# Pattern on the full command line (python scripts, paths).
alive_f() { in_op pgrep -f "$1" >/dev/null 2>&1; }

# ── THE MATRIX: DISPLAY (instant) AND MEASUREMENT (in the background) ───────
MATRIX_FILE="${OSMO_FFT_DIR:-/run/osmo-fft}/ss7-matrix"
MATRIX_LOCK="${OSMO_FFT_DIR:-/run/osmo-fft}/.ss7-matrix.lock"
MATRIX_TTL="${OSMO_MATRIX_TTL:-300}"

matrice() {
    local now age=999999 mtime=0
    now="$(date +%s)"
    [ -f "$MATRIX_FILE" ] && {
        mtime="$(stat -c %Y "$MATRIX_FILE" 2>/dev/null || echo 0)"
        age=$(( now - mtime ))
    }
    # ── A MEASUREMENT TAKEN BEFORE THE BENCH IS NOT A MEASUREMENT ───────────
    # A measurement taken at startup, before osmo-multi has launched
    # osmo-operator-2/3, reports the docker operators as failed because their
    # containers do not exist yet. The cache must not outlive what it
    # describes: any measurement older than the last start of osmo-banc or
    # osmo-multi is stale, whatever its age. `systemctl show` answers without
    # privilege.
    local t u
    for u in osmo-banc.service osmo-multi.service; do
        t="$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null)"
        [ -n "$t" ] || continue
        t="$(date -d "$t" +%s 2>/dev/null)" || continue
        [ -n "$t" ] && [ "$mtime" -lt "$t" ] && age=$(( MATRIX_TTL + 1 ))
    done
    # Stale (or never measured): launch the measurement DETACHED and return at
    # once. The lock is a mkdir: atomic, and it goes away with the directory
    # even if the measurement is killed (trap).
    local encours=0
    if [ "$age" -gt "$MATRIX_TTL" ]; then
        ( setsid "$0" --refresh-matrix >/dev/null 2>&1 & ) 2>/dev/null
        encours=1
    fi
    [ -d "$MATRIX_LOCK" ] && encours=1
    if [ -s "$MATRIX_FILE" ]; then
        cat "$MATRIX_FILE"
        # ss7_check.sh takes a good minute: SAY that what is shown is old and
        # that a measurement is running, rather than letting a stale KO pass
        # for the current state.
        if [ "$encours" = 1 ]; then
            echo "  \${color4}mesure en cours\${color} - affiche : il y a $(( age / 60 ))m$(( age % 60 ))s"
        fi
    else
        echo "  ${C1}matrice SS7${C} : premiere mesure en cours..."
    fi
}

refresh_matrice() {
    mkdir "$MATRIX_LOCK" 2>/dev/null || return 0     # one measurement at a time
    trap 'rmdir "$MATRIX_LOCK" 2>/dev/null' EXIT
    local dir out
    dir="$(cd "$(dirname "$0")/.." && pwd)"
    [ -x "$dir/checks/ss7_check.sh" ] || return 0
    # NO_COLOR + stripping of ANSI sequences: repainted with the Conky colours
    # (${color1..4}), as Conky does not understand terminal codes.
    out="$(cd "$dir" && NO_COLOR=1 timeout 240 ./checks/ss7_check.sh 2>/dev/null \
           | sed -e 's/\x1b\[[0-9;]*m//g')"
    [ -n "$out" ] || return 0
    {
        # The table: the header line (the OpN columns) then one line per
        # operator, up to the blank line that closes the block.
        printf '%s\n' "$out" \
        | awk '/MATRICE DE CONNECTIVITE/{f=1; next}
               f && /^[[:space:]]*$/ && seen {exit}
               f && /Op/ {seen=1; print}' \
        | sed -e 's/[[:space:]]*$//' \
              -e 's/\bself\b/${color1}self${color}/g' \
              -e 's/\bvia\b/${color2}via${color}/g' \
              -e 's/\bFAIL\b/${color3}FAIL${color}/g'
        # The verdict, as ss7_check phrases it.
        printf '%s\n' "$out" | awk '/SS7 (OK|DEGRADE|KO)/{sub(/^[[:space:]]+/,""); print; exit}' \
        | sed -e 's/^SS7 OK/${color2}SS7 OK${color}/' \
              -e 's/^SS7 DEGRADE/${color4}SS7 DEGRADE${color}/' \
              -e 's/^SS7 KO/${color3}SS7 KO${color}/' \
              -e 's/\([0-9]\+\) pass/${color2}\1 pass${color}/' \
              -e 's/\([0-9]\+\) fail/${color3}\1 fail${color}/' \
              -e 's/\([0-9]\+\) warn/${color4}\1 warn${color}/'
    } > "$MATRIX_FILE.tmp" 2>/dev/null && mv -f "$MATRIX_FILE.tmp" "$MATRIX_FILE"
}

case "${1:-}" in
--refresh-matrix) refresh_matrice; exit 0 ;;
role)
    r="$(awk -F= '/^OSMO_ROLE=/{print $2}' /etc/osmo-role 2>/dev/null)"
    n="$(awk -F= '/^OSMO_NODE=|^NODE_ID=/{print $2}' /etc/osmo-role 2>/dev/null | head -1)"
    h="$(awk -F= '/^OSMO_HUB_IP=/{print $2}' /etc/osmo-role 2>/dev/null)"
    live=""; [ -e /run/live/rootfs/filesystem.squashfs ] && live=" \${color4}LIVE${C}"
    opl=""; [ "$OP_MODE" = docker ] && opl=" \${color2}op $OP_ID${C} ($OP_NAME)"
    echo "${r:-operateur}${n:+ noeud $n}${h:+ · hub $h}$live$opl" ;;
net)
    ip -o -4 addr show up 2>/dev/null | awk '$2!="lo" && $2!~/^(veth|br-|docker|apn)/ {print $2, $4}' | sort -u | head -5 \
    | while read -r ifc addr; do
        printf '${color6}%s${color} ${alignr}${color2}${downspeedf %s}${color} K/s %s  ${color4}${upspeedf %s}${color} K/s %s\n%-8s ${color1}%s${color}\n' \
            "$ifc" "$ifc" "${FS}\${color2}↓\${color}${FU}" "$ifc" "${FS}\${color4}↑\${color}${FU}" "" "$addr"
      done
    # This section NEVER collapses (see banc_debout): when the bench is down,
    # it is the one being read. If the filter above let nothing through - only
    # veth/docker, or no address at all - say so, rather than rendering an
    # empty section that would pass for a broken Conky.
    if [ -z "$(ip -o -4 addr show up 2>/dev/null | awk '$2!="lo" && $2!~/^(veth|br-|docker|apn)/')" ]; then
        if [ -n "$(ip -o -4 addr show up 2>/dev/null | awk '$2!="lo"')" ]; then
            echo "${WARN} aucune carte physique - seulement les interfaces du banc"
        else
            echo "${WARN} aucune interface avec adresse"
        fi
    fi ;;
core)
    banc_debout || exit 0
    # name:process:VTY port
    for e in HLR:osmo-hlr:4258 MSC:osmo-msc:4254 BSC:osmo-bsc:4242 STP:osmo-stp:4239 \
             MGW:osmo-mgw:4243 SGSN:osmo-sgsn:4245 GGSN:osmo-ggsn:4260 PCU:osmo-pcu:4240 \
             BTS:osmo-bts-trx:4241 SIP:osmo-sip-connector:4256 SMSC:proto-smsc-daemon:0 PBX:asterisk:0; do
        IFS=: read -r name proc port <<< "$e"
        if alive_x "$proc"; then
            if [ "$port" != 0 ] && ! port_open "$port"; then s="$WARN"; else s="$OK"; fi
        else s="$KO"; fi
        printf '%s %-5s' "$s" "$name"
        i=$((${i:-0}+1)); [ $((i % 4)) -eq 0 ] && echo
    done
    # No extra blank line when the twelve dots fill the rows exactly.
    [ $((i % 4)) -eq 0 ] || echo ;;
radio)
    banc_debout || exit 0
    phy="-"
    pgrep -f 'qemu-system-arm' >/dev/null 2>&1 && phy="qemu (Calypso emule)"
    pgrep -f 'fake_trx.py' >/dev/null 2>&1 && phy="faketrx"
    pgrep -x virtphy >/dev/null 2>&1 && phy="virtphy"
    pgrep -f 'pont/pont(_dsp)?\.py' >/dev/null 2>&1 && phy="$phy + pont"
    echo "PHY ${C1}${phy}${C}"
    # ── WHAT EACH DOT REALLY LOOKS FOR ───────────────────────────────────
    # The ISO bench runs in faketrx + pont: there is NO osmo-trx binary, the
    # BTS transceiver is pont/pont.py and the MS#2 one is fake_trx.py. gapk
    # only exists as osmo-gapk, launched by gapk-start.sh for the duration of
    # a call; outside a call, the watcher (gapk-start.sh auto) IS the nominal
    # state. gr-gsm is replaced by qosmo-grgsm (gsm_sniff.py): grgsm_decode
    # is not installed.
    s=""
    { alive_f 'osmo-trx' || alive_f 'pont/pont(_dsp)?\.py' || alive_f 'fake_trx\.py'; } && s="$s$OK TRX     " || s="$s$KO TRX     "
    alive_x mobile                  && s="$s$OK MOBILE  " || s="$s$KO MOBILE  "
    alive_x trxcon                  && s="$s$OK TRXCON  " || s="$s$KO TRXCON  "
    alive_f 'qemu-system-arm'       && s="$s$OK QEMU    " || s="$s$KO QEMU    "
    if alive_x osmo-gapk; then s="$s$OK GAPK    "
    elif alive_f 'gapk-start\.sh'; then s="$s$OK GAPK    "
    else s="$s$KO GAPK    "; fi
    { alive_f 'grgsm_(decode|livemon)' || alive_f 'gsm_sniff\.py' || alive_x qosmo-grgsm; } \
        && s="$s$OK GRGSM  " || s="$s$KO GRGSM  "
    echo "$s"
    arfcn="$(in_op cat /etc/osmocom/osmo-bsc.cfg 2>/dev/null | awk '/^ *arfcn /{print $2; exit}')"
    plmn="$(in_op cat /etc/osmocom/osmo-msc.cfg 2>/dev/null | awk '/network country code/{c=$4} /mobile network code/{n=$4} END{if(c) print c"-"n}')"
    a5="$(in_op cat /etc/osmocom/osmo-msc.cfg 2>/dev/null | awk '/encryption a5/{$1="";$2="";print; exit}' | sed 's/^ *//')"
    echo "PLMN ${C1}${plmn:--}${C}  ARFCN ${C1}${arfcn:--}${C}  A5 ${C1}${a5:--}${C}" ;;
subs)
    banc_debout || exit 0
    db=/var/lib/osmocom/hlr.db
    # The container does not necessarily have sqlite3: its database is read
    # through a copy. Together with its -wal: osmo-hlr runs in WAL mode, so the
    # LUs are not yet written back into hlr.db (the copy alone would report
    # « 0 attached »). One copy per user, so a root-owned copy cannot block
    # the session user's conky.
    if [ "$OP_MODE" = docker ]; then
        dbl="/tmp/.conky-hlr-$(id -u)-${OP_NAME}.db"
        rm -f "$dbl-wal" "$dbl-shm"
        if docker cp "$OP_NAME:$db" "$dbl" >/dev/null 2>&1; then
            docker cp "$OP_NAME:$db-wal" "$dbl-wal" >/dev/null 2>&1
            db="$dbl"
        fi
    fi
    # ── THE HLR STATE IS NOT READ FROM ITS DATABASE ──────────────────────
    # The database outlives the daemon: it would still show subscribers
    # « attached » to a VLR that is gone. The daemon is checked first; the
    # database only says what is PROVISIONED.
    if ! alive_x osmo-hlr; then
        _n=""
        have sqlite3 && [ -r "$db" ] && \
            _n="$(sqlite3 "$db" 'select count(*) from subscriber;' 2>/dev/null)"
        echo "HLR ${KO} arrete${_n:+ ${AR}${_n} abonnes en base}"
    elif have sqlite3 && [ -r "$db" ]; then
        tot="$(sqlite3 "$db" 'select count(*) from subscriber;' 2>/dev/null)"
        att="$(sqlite3 "$db" "select count(*) from subscriber where vlr_number is not null and vlr_number != '';" 2>/dev/null)"
        last="$(sqlite3 "$db" 'select max(last_lu_seen) from subscriber;' 2>/dev/null)"
        echo "HLR ${C1}${tot:-0}${C} abonnes · ${C2}${att:-0}${C} rattaches ${AR}LU ${last:--}"
        sqlite3 "$db" "select imsi, coalesce(msisdn,'-'), case when vlr_number is not null and vlr_number != '' then 1 else 0 end from subscriber order by imsi limit 6;" 2>/dev/null \
        | awk -F'|' -v ok="$OK" -v ko="$KO" '{printf "%s %s ${alignr}%s\n", ($3==1?ok:ko), $1, $2}'
    else
        echo "HLR ${KO} base introuvable (${db})"
    fi ;;
vue)
    # ── THE SELECTOR: ◀ STOP ▶ , AND THE VIEW IT DRIVES ────────────────────
    # The Conky carries ONE selector and ONE view: the stops are those of
    # « osmo-op --list-vue » (op1, the docker operators that are RUNNING, the
    # hub if it runs, the 4G if it is installed) and the view changes with the
    # stop - 2G sections for an operator, SS7 matrix for the hub, EPC core and
    # LTE radio for the 4G.
    #
    # Conky does NOT receive clicks (that is the whole point of
    # tools/osmo-panel.py): the ◀ ▶ arrows are moved with those of the panel,
    # with Ctrl+AltGr+Left/Right (shortcut set by the ISO,
    # iso_modules/80-chroot.sh), or from the command line - « osmo-op --next »
    # and « --prev ».
    _op="${DIR:-/opt/GSM/osmo-operator}/tools/osmo-op.sh"
    [ -x "$_op" ] || _op="/opt/GSM/osmo-operator/tools/osmo-op.sh"
    [ -x "$_op" ] || { echo "${WARN} osmo-op.sh introuvable"; exit 0; }
    mapfile -t VUES < <("$_op" --list-vue 2>/dev/null)
    [ "${#VUES[@]}" -gt 0 ] || { echo "${WARN} aucun arret (osmo-op --list-vue)"; exit 0; }
    # ── THE SELECTED STOP MAY HAVE VANISHED ─────────────────────────────────
    # If the container of the selected operator was stopped, the stop no
    # longer exists and the Conky would show the view of an absent operator.
    # Fall back on the first stop - and WRITE it, so the panel and the arrows
    # follow instead of staying on a ghost.
    _cur="$OP_ID"; _mode="$OP_MODE"; _connu=0
    for l in "${VUES[@]}"; do
        set -- $l
        [ "$1" = "$_cur" ] && { _connu=1; _mode="$2"; }
    done
    if [ "$_connu" = 0 ]; then
        set -- ${VUES[0]}
        _cur="$1"; _mode="$2"
        "$_op" --set "$_cur" >/dev/null 2>&1 || true
    fi
    # The selector - only when there is more than one place to go.
    if [ "${#VUES[@]}" -gt 1 ]; then
        sel=""
        for l in "${VUES[@]}"; do
            set -- $l
            idx="$1"; mode="$2"; etat="${4:-arrete}"   # $3 = the IP, or « - »
            case "$mode" in
                interstp) nom="hub" ;;
                lte)      nom="4G" ;;
                *)        nom="op$idx" ;;
            esac
            # A smiley before each stop: green smile if it runs, grey frown
            # otherwise; the selected stop between ◀ ▶.
            [ "$etat" = actif ] && p="$SMILE" || p="$SAD"
            if [ "$idx" = "$_cur" ]; then
                sel="$sel ${FS}\${color4}◀\${color}${FU}$p${C2}$nom${C}${FS}\${color4}▶\${color}${FU}"
            else
                sel="$sel $p${C1}$nom${C}"
            fi
        done
        echo "${sel# }${AR}\${color5}Ctrl+AltGr+${FS}\${color4}◀▶\${color}${FU}"
    fi
    # The view.
    T='${font Ubuntu:bold:size=10}${color1}'; TF='${font}${color}'
    case "$_mode" in
        interstp)
            echo "${T}Hub inter-STP${TF}"
            "$0" hub ;;
        lte)
            echo "${T}4G / LTE\${color4} Open5GS + srsRAN${TF}"
            "$0" lte ;;
        *)
            # ── NO TITLE WITHOUT SOMETHING BELOW IT ─────────────────────────
            # These three sections render NOTHING when the stack is down
            # (banc_debout, above): the titles would then stand alone, three
            # lines that read like a broken Conky. They are only printed when
            # there is something to put below them, and the « nothing at all »
            # case is said in one line - the useful one.
            _vide=1
            for e in "Coeur GSM:core" "Radio / MS:radio" "Abonnes (HLR):subs"; do
                _out="$("$0" "${e##*:}" 2>/dev/null)"
                [ -n "$_out" ] || continue
                _vide=0
                echo "${T}${e%%:*}${TF}"
                echo "$_out"
            done
            [ "$_vide" = 0 ] || echo "${C1}banc a l arret${C} - ${C2}./start-native.sh${C}" ;;
    esac
    ;;
ops|hub)
    # ── THE INTER-STP HUB, AND THE CONNECTIVITY MATRIX ──────────────────────
    # The operator selector lives in « vue » above; only what concerns the hub
    # remains here, and it is the « hub » view. (« ops » is still accepted as
    # an alias: older ISOs call it by that name.)
    # The inter-STP hub: present only when it runs (multi bench only).
    if have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx osmo-inter-stp; then
        _pc="$(awk -F= '/^MULTI_HUB_PC=/{print $2}' /etc/osmocom/osmo-multi.conf 2>/dev/null)"
        _hi="$(awk -F= '/^MULTI_HUB_IP=/{print $2}' /etc/osmocom/osmo-multi.conf 2>/dev/null)"
        echo "$OK inter-STP ${C1}${_hi:-172.20.0.10}${C} PC ${C1}${_pc:-0.0.0}${C}"
        # ── THE CONNECTIVITY MATRIX, CACHED ─────────────────────────────────
        # It comes from checks/ss7_check.sh - THE source, the one that really
        # queries the VTYs and counts the routes. It is not recomputed here:
        # two implementations of the same question always end up disagreeing,
        # and the copy is the one people believe.
        #
        # BUT ss7_check.sh takes a good minute (31 tests, several VTY telnets
        # per operator, each with its timeouts). An `execpi` calling it would
        # FREEZE THE WHOLE CONKY at every refresh - clock, CPU, network, all
        # of it would stop during the measurement. Hence the cache: the last
        # result is DISPLAYED, and the next measurement is triggered IN THE
        # BACKGROUND once it has aged. The conky never blocks; at worst the
        # matrix is a minute late, which does not matter for a topology that
        # does not move.
        matrice
    fi ;;
lte)
    # ── THE BENCH 4G: Open5GS (the EPC core) + srsRAN over ZeroMQ ────────────
    # The bench carries the 4G through tools/osmo-lte.sh: the eight Open5GS
    # daemons (+ mongod, without which the HSS and the PCRF die at init), the
    # srsRAN eNB and UE linked by ZeroMQ, S1 on 36412 and ogstun for the user
    # plane.
    #
    # The probes are those of tools/osmo-epc.sh and tools/osmo-lte.sh - THE
    # sources - but WITHOUT their ZeroMQ throughput measurement: that one
    # sleeps one second between two counter reads, and an execpi that sleeps
    # FREEZES the whole Conky (same reason as the SS7 matrix cache above).
    # Everything is native here: Open5GS is not containerised, so no in_op.
    _o5gs=""
    for p in "${OPEN5GS_PREFIX:-}" /opt/LTE/open5gs/install /root/open5gs/install; do
        [ -n "$p" ] && [ -x "$p/bin/open5gs-mmed" ] && { _o5gs="$p"; break; }
    done
    _srs=""
    for b in /usr/local/bin/srsenb "${OSMO_SRSRAN_BUILD:-/opt/LTE/srsRAN_4G/build}/srsenb/src/srsenb"; do
        [ -x "$b" ] && { _srs="$b"; break; }
    done
    have srsenb && _srs="${_srs:-srsenb}"
    if [ -z "$_o5gs" ] && [ -z "$_srs" ]; then
        echo "${C1}4G non installee${C} - ${C2}osmo-lte-install --build${C}"; exit 0
    fi
    # ── A STOPPED 4G DOES NOT DESERVE THIRTEEN RED DOTS ─────────────────────
    # Same rule as banc_debout for the 2G: when nothing runs, one line saying
    # what to type is worth more than a wall of alarms.
    _debout=0
    for d in open5gs-mmed srsenb srsue; do
        pgrep -x "$d" >/dev/null 2>&1 && _debout=1
    done
    if [ "$_debout" = 0 ]; then
        # The subscriber console lives its own life: it only reads MongoDB and
        # is precisely used to provision with the core off. If it listens, say so.
        _w=""
        ss -tanH state listening "( sport = :9999 )" 2>/dev/null | grep -q . \
            && _w="  ${AR}${OK} console ${C1}:9999${C}"
        echo "${C1}4G a l arret${C} - ${C2}osmo-lte start${C}${_w}"; exit 0
    fi
    # The core: the eight daemons in osmo-epc.sh start order, mongod - the HSS
    # and the PCRF read the subscribers from it and DIE without it (the MME
    # then answers 3002 on S6a and rejects every attach) - and the subscriber
    # console (open5gs-webui.service, :9999), which reads the same database.
    i=0
    for e in MME:open5gs-mmed HSS:open5gs-hssd SGWC:open5gs-sgwcd SGWU:open5gs-sgwud \
             SMF:open5gs-smfd UPF:open5gs-upfd PCRF:open5gs-pcrfd NRF:open5gs-nrfd \
             MONGO:mongod WEBUI:@9999; do
        IFS=: read -r name proc <<< "$e"
        # « @port »: a console, not a daemon - the Open5GS WebUI is a node
        # process, its name says nothing. Check what it LISTENS on instead.
        case "$proc" in
            @*) ss -tanH state listening "( sport = :${proc#@} )" 2>/dev/null | grep -q . \
                    && s="$OK" || s="$KO" ;;
            *)  pgrep -x "$proc" >/dev/null 2>&1 && s="$OK" || s="$KO" ;;
        esac
        # %-6s and not %-5s: « MONGO » is five characters and would touch the
        # next dot.
        printf '%s %-6s' "$s" "$name"
        i=$((i+1)); [ $((i % 5)) -eq 0 ] && echo
    done
    [ $((i % 5)) -eq 0 ] || echo
    # The radio and the links: eNB, UE, S1 (SCTP 36412), ZeroMQ, ogstun.
    s=""
    pgrep -x srsenb >/dev/null 2>&1 && s="$s$OK eNB   " || s="$s$KO eNB   "
    pgrep -x srsue  >/dev/null 2>&1 && s="$s$OK UE    " || s="$s$KO UE    "
    ss -San 2>/dev/null | grep -q "ESTAB.*:36412" && s="$s$OK S1    " || s="$s$KO S1    "
    _zp="${OSMO_ZMQ_PORT:-2000}"
    ss -tanH state established "( sport = :$_zp or dport = :$_zp )" 2>/dev/null | grep -q . \
        && s="$s$OK ZMQ   " || s="$s$KO ZMQ   "
    ip -br link show ogstun >/dev/null 2>&1 && s="$s$OK TUN" || s="$s$KO TUN"
    echo "$s"
    # The cell as declared by enb.conf - the one that was used if readable
    # (root), the repo one otherwise: it is the source of the copy.
    _cfg=""
    for f in "${OSMO_SRSRAN_DIR:-/root/.config/srsran}/enb.conf" \
             "${DIR:-/opt/GSM/osmo-operator}/configs/srsran/enb.conf" \
             /opt/GSM/osmo-operator/configs/srsran/enb.conf; do
        [ -r "$f" ] && { _cfg="$f"; break; }
    done
    mcc=""; mnc=""; earfcn=""; prb=""
    if [ -n "$_cfg" ]; then
        eval "$(awk -F= '
            /^[[:space:]]*mcc[[:space:]]*=/       {gsub(/[[:space:]]/,"",$2); print "mcc="$2}
            /^[[:space:]]*mnc[[:space:]]*=/       {gsub(/[[:space:]]/,"",$2); print "mnc="$2}
            /^[[:space:]]*dl_earfcn[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print "earfcn="$2}
            /^[[:space:]]*n_prb[[:space:]]*=/     {gsub(/[[:space:]]/,"",$2); print "prb="$2}' "$_cfg")"
    fi
    # The PRB count IS the channel width: display the one that is read.
    case "$prb" in 6) bw=1.4;; 15) bw=3;; 25) bw=5;; 50) bw=10;; 75) bw=15;; 100) bw=20;; *) bw="";; esac
    # The UE address lives in a netns: « ip -n » requires privilege. Under
    # the session (non-root uid) there is none - say nothing rather than
    # suggesting the UE is not attached.
    ue="$(ip -n "${OSMO_LTE_NETNS:-ue1}" -4 -o addr show 2>/dev/null | awk '/tun_srsue/{print $4; exit}')"
    echo "PLMN ${C1}${mcc:--}-${mnc:--}${C}  EARFCN ${C1}${earfcn:--}${C}${bw:+  ${C1}${bw}${C} MHz}${ue:+ ${AR}UE ${C1}${ue}${C}}"
    ;;
services)
    # Bench down: a single line, the useful one - the failed units. The rest
    # (web, pulse, tmux, docker) says nothing beyond « nothing runs », which
    # the absence of the sections above has already said.
    if ! banc_debout; then
        f="$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
        [ "$f" -gt 0 ] && echo "${WARN} ${f} service(s) systemd en echec" \
                       || echo "${C1}banc a l arret${C} - ${C2}./start-native.sh${C}"
        exit 0
    fi
    s=""
    port_open 8080 || port_open 8443 && s="$s$OK web " || s="$s$KO web "
    pgrep -x pulseaudio >/dev/null 2>&1 && s="$s$OK pulse " || s="$s$KO pulse "
    # ── NO tmux OR docker DOTS ──────────────────────────────────────────────
    # The Conky runs under the SESSION account, so these two probes would
    # answer « what do I see » rather than « what runs on this machine »:
    #   tmux   : the bench opens its sessions as ROOT, on /tmp/tmux-0/default;
    #            `tmux list-sessions` as the user looks at
    #            /tmp/tmux-1001/default, which does not exist.
    #   docker : « permission denied ... /var/run/docker.sock » as long as the
    #            account is not in the docker group, hence zero containers.
    # Neither says anything useful about the bench: the Coeur GSM and Radio
    # sections already say whether the stack is up, and the operator line
    # (`ops` sub-command) says which containers run - and that one can tell
    # « stopped » from « invisible ».
    have nvidia-smi && s="$s$OK nvidia "
    echo "$s"
    # ── AND NAME WHAT FAILS ─────────────────────────────────────────────────
    # A bare « N systemd service(s) failed » sends the reader looking for which
    # one by hand; the name makes the diagnosis immediate (e.g. a unit masked
    # by the image that stays `failed` until `systemctl reset-failed`).
    # `systemctl --failed --no-legend` starts with a BULLET (●), not the name:
    # take the field that looks like a unit, whatever its position.
    f="$(systemctl --failed --no-legend 2>/dev/null \
         | awk '{for(i=1;i<=NF;i++) if($i ~ /\.(service|socket|target|timer|mount|path)$/) {print $i; break}}' \
         | sed 's/\.service$//' | paste -sd' ' -)"
    [ -n "$f" ] && echo "${WARN} en echec : ${C1}${f}${C}" || echo "${OK} systemd sans echec"
    ;;
*) echo "usage: $0 role|vue|net|hub|core|radio|lte|subs|services" >&2; exit 2 ;;
esac

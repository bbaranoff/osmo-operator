#!/bin/bash
# =============================================================================
# osmo-sim-install.sh - THE BENCH SIM, installed once for TWO paths.
#
# Same logic as tools/osmo-extras-install.sh: what must exist both in the
# SUPPLEMENT (addition.sh --sim, on an already installed machine) and in the
# NATIVE install (the ISO, iso_modules/80-chroot.sh, in the chroot) is written
# ONCE here; both paths source this script and call osmo_sim_install.
# Nothing is fatal: a missing package must not stop the rest.
#
# What it installs:
#   - pcscd + libccid: the PC/SC daemon and the CCID driver of the HID Omnikey
#     reader (6121, reads the ATR of the sysmoISIM-SJA5); pcsc-tools
#     (pcsc_scan) and opensc (opensc-tool -l/-a) to see the reader and the ATR;
#   - Ruby + ruby-libxml + the smartcard gem: softSIM (/opt/GSM/softsim), the
#     SAP server that serves either a software SIM (sim.xml, type sim) or the
#     card in the reader (type pcsc) to the osmocom-bb mobile ("sim sap");
#   - pySim (Osmocom, from its git: the PyPI "pySim" is another project) in
#     its venv /opt/GSM/pysim-venv: pySim-read, pySim-prog, pySim-shell, to
#     read and program the sysmoISIM-SJA5 (ADM1 key required to write);
#   - sysmo-usim-tool (sysmocom) in /opt/GSM/sysmo-usim-tool: the tool that
#     writes IMSI, Ki, algorithm (COMP128v1) and OPc on the sysmoISIM-SJA5;
#   - softSIM itself if missing (clone + patches tools/softsim/*.patch + Ruby
#     3.2 shim), as iso_modules/51-softsim.sh does for the ISO;
#   - pcscd.socket enabled (except in chroot: no systemd, the unit is enabled
#     at first boot by its preset).
#
# Idempotent: can be re-run without harm. Variables:
#   OSMO_SIM_PYSIM=0      do not install pySim
#   OSMO_SIM_SOFTSIM=0    do not install softSIM
#   PYSIM_VENV            the pySim venv (default /opt/GSM/pysim-venv)
#   SOFTSIM_DIR           the softSIM tree (default /opt/GSM/softsim)
#   REPO / DIR            the osmo-operator repository (softSIM patches, Ruby shim)
# =============================================================================

: "${GREEN:=}"; : "${YELLOW:=}"; : "${CYAN:=}"; : "${BOLD:=}"; : "${NC:=}"

_sim_repo() {
    local d
    for d in "${REPO:-}" "${DIR:-}" /opt/GSM/osmo-operator "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"; do
        [ -n "$d" ] && [ -f "$d/tools/softsim/ruby_compat.rb" ] && { printf '%s' "$d"; return 0; }
    done
    return 1
}

_sim_say()  { echo -e "  ${GREEN}✓${NC} $*"; }
_sim_warn() { echo -e "  ${YELLOW}!${NC} $*" >&2; }

# In chroot (ISO): no running systemd, no reader to test.
_sim_in_chroot() { [ "$(stat -c %d:%i / 2>/dev/null)" != "$(stat -c %d:%i /proc/1/root/. 2>/dev/null)" ]; }

osmo_sim_install_apt() {
    local pkgs="pcscd libccid pcsc-tools opensc libpcsclite1 libpcsclite-dev
                python3 python3-venv python3-pip python3-pyscard swig
                ruby ruby-libxml ruby-dev build-essential git"
    export DEBIAN_FRONTEND=noninteractive
    local apt=apt-get; command -v apt-fast >/dev/null 2>&1 && apt=apt-fast
    # shellcheck disable=SC2086
    if $apt install -y --no-install-recommends $pkgs >/dev/null 2>&1; then
        _sim_say "paquets SIM : pcscd, libccid, pcsc-tools, opensc, pyscard, ruby"
    else
        # one by one: a package missing from the mirror must not block the others
        local p; for p in $pkgs; do
            $apt install -y --no-install-recommends "$p" >/dev/null 2>&1 || _sim_warn "paquet absent : $p"
        done
    fi
    if ! _sim_in_chroot && command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now pcscd.socket >/dev/null 2>&1 && _sim_say "pcscd.socket actif" \
            || _sim_warn "pcscd.socket non active"
    fi
}

osmo_sim_install_gem() {
    command -v gem >/dev/null 2>&1 || { _sim_warn "gem absent : pas de softSIM pcsc"; return 0; }
    if gem list -i smartcard >/dev/null 2>&1; then
        _sim_say "gem smartcard deja present"
    elif gem install smartcard --no-document >/dev/null 2>&1; then
        _sim_say "gem smartcard installe (softSIM en lecteur PC/SC)"
    else
        _sim_warn "gem smartcard non installe (softSIM pcsc indisponible)"
    fi
}

osmo_sim_install_pysim() {
    [ "${OSMO_SIM_PYSIM:-1}" = 1 ] || return 0
    local venv="${PYSIM_VENV:-/opt/GSM/pysim-venv}"
    local repo="${OSMO_PYSIM_REPO:-https://gitea.osmocom.org/sim-card/pysim.git}"
    if [ -x "$venv/bin/pySim-shell.py" ] && [ "${OSMO_SIM_PYSIM_UPDATE:-0}" != 1 ]; then
        _sim_say "pySim deja present : $venv"
        return 0
    fi
    python3 -m venv "$venv" >/dev/null 2>&1 || { _sim_warn "venv pySim impossible ($venv)"; return 0; }
    # pyscard needs swig + libpcsclite-dev to build (PKGS above).
    if "$venv/bin/pip" install -q --disable-pip-version-check --no-cache-dir "git+$repo" >/dev/null 2>&1; then
        _sim_say "pySim (Osmocom) : $venv/bin/pySim-{read,prog,shell}.py"
    else
        _sim_warn "pySim non installe (reseau ? swig/libpcsclite-dev ?)"
    fi
}

osmo_sim_install_sysmo_tool() {
    local d="${SYSMO_TOOL:-/opt/GSM/sysmo-usim-tool}"
    if [ -f "$d/sysmo-isim-tool.sja5.py" ]; then _sim_say "sysmo-usim-tool deja present : $d"; return 0; fi
    if GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 "${OSMO_SYSMO_TOOL_REPO:-https://gitea.sysmocom.de/sysmocom/sysmo-usim-tool.git}" "$d" 2>/dev/null; then
        _sim_say "sysmo-usim-tool (sysmo-isim-tool.sja5.py) : $d"
    else
        rm -rf "$d"; _sim_warn "sysmo-usim-tool : clone impossible (reseau ?) - pySim-prog servira"
    fi
}

osmo_sim_install_softsim() {
    [ "${OSMO_SIM_SOFTSIM:-1}" = 1 ] || return 0
    local sdir="${SOFTSIM_DIR:-/opt/GSM/softsim}" repo p
    repo="$(_sim_repo)" || { _sim_warn "depot osmo-operator introuvable : softSIM non pose"; return 0; }
    if [ ! -f "$sdir/src/demo_server.rb" ]; then
        rm -rf "$sdir"
        if GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 "${OSMO_SOFTSIM_REPO:-https://gitea.osmocom.org/sim-card/softsim.git}" "$sdir" 2>/dev/null; then
            _sim_say "softSIM clone : $sdir"
        else
            rm -rf "$sdir"; _sim_warn "softSIM : clone impossible (reseau ?)"; return 0
        fi
    fi
    install -Dm644 "$repo/tools/softsim/comp128.rb" "$sdir/src/lib/comp128.rb"
    for p in "$repo"/tools/softsim/*.patch; do
        [ -f "$p" ] || continue
        if git -C "$sdir" apply --check -R "$p" >/dev/null 2>&1; then
            :  # deja applique
        elif git -C "$sdir" apply "$p" >/dev/null 2>&1; then
            _sim_say "softSIM : patch $(basename "$p") applique"
        else
            _sim_warn "softSIM : patch $(basename "$p") ne s applique pas"
        fi
    done
    install -Dm644 "$repo/tools/softsim/ruby_compat.rb" /usr/local/share/softsim/ruby_compat.rb
    if [ -f "$sdir/src/sim.xml" ]; then
        python3 "$repo/tools/softsim/make_sim_op1.py" "$sdir/src/sim.xml" "$sdir/src/sim-op1.xml" \
            --imsi "${OSMO_SIM_IMSI:-001010001000001}" >/dev/null 2>&1 \
            && _sim_say "softSIM : sim-op1.xml (IMSI ${OSMO_SIM_IMSI:-001010001000001})"
    fi
    _sim_say "softSIM pret : $sdir (shim /usr/local/share/softsim/ruby_compat.rb)"
}

osmo_sim_install() {
    echo -e "${CYAN}SIM du banc : lecteur PC/SC (Omnikey), softSIM (SAP), pySim${NC}"
    osmo_sim_install_apt
    osmo_sim_install_gem
    osmo_sim_install_pysim
    osmo_sim_install_sysmo_tool
    osmo_sim_install_softsim
    if ! _sim_in_chroot && command -v opensc-tool >/dev/null 2>&1; then
        local r; r="$(timeout 10 opensc-tool -l 2>/dev/null | sed -n '3,$p')"
        [ -n "$r" ] && echo -e "  ${BOLD}lecteurs :${NC}\n$(printf '%s\n' "$r" | sed 's/^/    /')" \
                    || echo -e "  ${YELLOW}aucun lecteur PC/SC branche${NC}"
    fi
    echo -e "  ${BOLD}suite :${NC} tools/osmo-sim.sh lecteur | lire | programmer | sap  (voir wiki/SIM.md)"
    return 0
}

# Run directly: do the work (otherwise, source + osmo_sim_install).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    [ "$(id -u)" -eq 0 ] || { echo "osmo-sim-install.sh : a lancer en root (sudo)" >&2; exit 1; }
    osmo_sim_install
fi

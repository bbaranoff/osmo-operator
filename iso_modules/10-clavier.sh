#!/bin/bash
# iso_modules/10-clavier.sh - image keyboard layout (interactive question or --kb)
# Sourced by build-iso.sh in numeric order (same shell, variables and
# functions); not meant to run on its own. A `return` at the top of a module
# means "nothing to do here" (that is how --arm skips a step).

# ══════════════════════════════════════════════════════════════════════════════
# QUESTIONS: all asked here, once, before anything starts
# ══════════════════════════════════════════════════════════════════════════════
# Everything interactive is asked HERE, never mid-build nor in the image at
# first boot:
#   - before the build, so a running pass is never interrupted;
#   - only once even when several images are produced: the answer is exported
#     and child passes inherit it;
#   - never in CI: without a terminal the default is used (waiting for an EOF
#     would fail the build under set -e).
#
# --kb=XX or OSMO_ISO_KB=XX skip the question.
ISO_KB_DEFAULT="fr"
if [ -z "${OSMO_ISO_KB:-}" ]; then
    if [ -t 0 ]; then
        echo -e "${CYAN}${BOLD}══ Clavier de l'image ══${NC}"
        echo "  1) fr   2) us   3) de   4) es   5) it"
        echo "  6) pt   7) gb   8) be   9) ch   0) autre"
        read -rp "  Choix [1] : " _kb_choice || _kb_choice=""
        case "${_kb_choice:-1}" in
            1|"") OSMO_ISO_KB="fr" ;;
            2) OSMO_ISO_KB="us" ;;  3) OSMO_ISO_KB="de" ;;
            4) OSMO_ISO_KB="es" ;;  5) OSMO_ISO_KB="it" ;;
            6) OSMO_ISO_KB="pt" ;;  7) OSMO_ISO_KB="gb" ;;
            8) OSMO_ISO_KB="be" ;;  9) OSMO_ISO_KB="ch" ;;
            0) read -rp "  Layout (fr, us, ru, ar...) : " OSMO_ISO_KB || OSMO_ISO_KB=""
               OSMO_ISO_KB="${OSMO_ISO_KB:-$ISO_KB_DEFAULT}" ;;
            *) OSMO_ISO_KB="$ISO_KB_DEFAULT" ;;
        esac
    else
        OSMO_ISO_KB="$ISO_KB_DEFAULT"
        echo -e "  ${YELLOW}Pas de terminal : clavier ${OSMO_ISO_KB} (--kb=XX pour changer)${NC}"
    fi
fi
export OSMO_ISO_KB
echo -e "  ${GREEN}✓${NC} clavier de l'image : ${CYAN}${OSMO_ISO_KB}${NC}"

# ── Without arguments: ALL default images ──────────────────────────────────
# A WAN needs both an SS7 hub and nodes, so both are produced, in separate
# full passes.
#
# ONE operator image serves all nine nodes: the node number is chosen at boot
# (`start-native.sh --node N`), which rewrites the point codes.
#
# ══════════════════════════════════════════════════════════════════════════════
# DONE ONLY ONCE: host packages and the docker build
# ══════════════════════════════════════════════════════════════════════════════
# The parent pass (--all) calls them once (20-hote.sh, 21-docker-build.sh);
# child passes skip them via OSMO_ISO_HOST_READY / OSMO_ISO_IMAGE_READY. A
# standalone pass calls them itself, once.


# End of module: `. file` returns the status of its LAST command, and
# build-iso.sh runs under set -e. A module ending with a false test
# ("[ ... ] && { ...; }") would silently stop everything. Always 0 here.
true

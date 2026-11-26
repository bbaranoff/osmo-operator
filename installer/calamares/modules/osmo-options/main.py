#!/usr/bin/env python3
# osmo-options (Calamares job) - the boxes ticked on the « Options » page
# (netinstall@options: one checkbox per supplement, any number of them).
#
# The page leaves names (osmo-option-<x>) in the installer's global storage,
# as if they were packages; nothing installs them. This job turns them into:
#   /etc/osmo-supplements        OSMO_SUPPLEMENTS="--multi --opencl ..." - the
#                                addition.sh flags that osmo-supplements.service
#                                (tools/osmo-supplements-firstboot.sh) runs at
#                                the first boot, once the network answers;
#                                OSMO_COMPTE: the account chosen in the installer
#   /etc/osmo-operator/options   the TPM options ticked (all optional, none
#                                posed by the installer - each needs the /home
#                                passphrase on the installed machine):
#                                  ancre=1        sudo osmo-empreinte ancrer
#                                  mesure=totp    sudo osmo-tpm poser
#                                  mesure=secret  sudo osmo-tpm poser --secret
#                                (both measured boots ticked: the phone's, the
#                                safer one). « osmo-tpm etat » reads this file
#                                and says what is still to do; no reminder at
#                                login.
import os

import libcalamares

# box ticked -> addition.sh flag (tools/osmo-supplements-firstboot.sh runs them)
DRAPEAUX = {"multi": "--multi", "opencl": "--opencl", "claude": "--claude", "extras": "--extras",
            "gnuarm": "--gnuarm", "magnetite": "--magnetite", "trx": "--trx",
            "calypso-fw": "--calypso-fw", "fernvale": "--fernvale", "simcom": "--simcom"}
PREFIXE = "osmo-option-"


def pretty_name():
    return "Supplements et options choisis"


def coches(gs):
    """The names ticked on the page, whatever form this Calamares stores them in."""
    noms = []

    def prendre(x):
        if isinstance(x, str):
            noms.append(x)
        elif isinstance(x, dict):
            for k in ("name", "package"):
                if isinstance(x.get(k), str):
                    noms.append(x[k])
        elif isinstance(x, (list, tuple)):
            for y in x:
                prendre(y)

    for cle in ("packageOperations", "netinstallAdd", "netinstallSelect"):
        v = gs.value(cle) if gs.contains(cle) else None
        for op in (v or []):
            if isinstance(op, dict):
                for k in ("install", "try_install"):
                    prendre(op.get(k))
            else:
                prendre(op)
    vus = []
    for n in noms:
        if n.startswith(PREFIXE) and n[len(PREFIXE):] not in vus:
            vus.append(n[len(PREFIXE):])
    return vus


def run():
    gs = libcalamares.globalstorage
    racine = gs.value("rootMountPoint")
    if not racine:
        return ("osmo-options", "pas de rootMountPoint")
    choix = coches(gs)
    drapeaux = [DRAPEAUX[c] for c in choix if c in DRAPEAUX]
    libcalamares.utils.debug("osmo-options : %s" % (", ".join(choix) or "rien de coche"))
    if drapeaux:
        compte = gs.value("username") or ""
        with open(os.path.join(racine, "etc/osmo-supplements"), "w") as f:
            f.write("# ecrit par l installeur (page Options) : les supplements coches\n")
            f.write('OSMO_SUPPLEMENTS="%s"\n' % " ".join(drapeaux))
            f.write('OSMO_COMPTE="%s"\n' % compte.replace('"', ""))
        os.chmod(os.path.join(racine, "etc/osmo-supplements"), 0o644)
        # the unit that runs them at the first boot
        unite = "/etc/systemd/system/osmo-supplements.service"
        wants = os.path.join(racine, "etc/systemd/system/multi-user.target.wants")
        if os.path.exists(os.path.join(racine, unite.lstrip("/"))):
            os.makedirs(wants, exist_ok=True)
            lien = os.path.join(wants, "osmo-supplements.service")
            if not os.path.lexists(lien):
                os.symlink(unite, lien)
    lignes = []
    if "tpm-ancre" in choix:
        lignes.append("ancre=1")
    if "tpm" in choix:
        lignes.append("mesure=totp")
    elif "tpm-secret" in choix:
        lignes.append("mesure=secret")
    if lignes:
        os.makedirs(os.path.join(racine, "etc/osmo-operator"), exist_ok=True)
        with open(os.path.join(racine, "etc/osmo-operator/options"), "a") as f:
            f.write("\n".join(lignes) + "\n")
    return None

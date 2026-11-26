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
#   the KIND OF MACHINE (first box of the page, ticked by default):
#     ticked    the SECURED BENCH, which REQUIRES A TPM 2.0. In the target:
#               crypthome-postinstall (unlock-home asks the /home passphrase,
#               guest root without it), the black box services, the measured
#               boot marked (so that the initramfs built next already carries
#               it), osmo-racine-live poser (/ in RAM, written at shutdown with
#               the passphrase). The TPM itself cannot be sealed from here: the
#               measures are those of the INSTALLED system's boot, not of this
#               live key - the FIRST BOOT asks the secret sentence and the PIN
#               right after the /home passphrase, then anchors and seals
#               (osmo-tpm premier, called by unlock-home).
#     unticked, or NO TPM 2.0 on this machine: an ordinary Ubuntu - none of
#               the above. Without a TPM the box is greyed out by osmo-install;
#               this job checks again and never sets the secured bench up.
#   /etc/osmo-operator/options   session=securise|ubuntu, and for the bench:
#                                ancre=1, mesure=secret|totp, premier=1
import os

import libcalamares

# box ticked -> addition.sh flag (tools/osmo-supplements-firstboot.sh runs them)
DRAPEAUX = {"multi": "--multi", "opencl": "--opencl", "claude": "--claude", "extras": "--extras",
            "gnuarm": "--gnuarm", "magnetite": "--magnetite", "trx": "--trx",
            "calypso-fw": "--calypso-fw", "fernvale": "--fernvale", "simcom": "--simcom"}
PREFIXE = "osmo-option-"


def tpm2():
    """A TPM 2.0 the kernel sees: what the secured bench requires."""
    try:
        with open("/sys/class/tpm/tpm0/tpm_version_major") as f:
            return f.read().strip() == "2"
    except OSError:
        return False


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
    if "securise" in choix and tpm2():
        compte = gs.value("username") or ""
        telephone = "tpm" in choix
        etapes = [["/usr/local/sbin/crypthome-postinstall", compte],
                  ["/bin/bash", "-c", "mkdir -p /etc/systemd/system/multi-user.target.wants && "
                   "ln -sf /etc/systemd/system/osmo-diffs.service /etc/systemd/system/multi-user.target.wants/osmo-diffs.service && "
                   "ln -sf /etc/systemd/system/osmo-diffs-init.service /etc/systemd/system/multi-user.target.wants/osmo-diffs-init.service"]]
        if not telephone:
            # the initramfs that « poser » builds next carries the measured boot
            etapes.append(["/bin/bash", "-c", "install -d -m 0755 /etc/osmo-tpm && : > /etc/osmo-tpm/actif"])
        etapes.append(["/usr/local/sbin/osmo-racine-live", "poser"])
        for e in etapes:
            rc = libcalamares.utils.target_env_call(e)
            libcalamares.utils.debug("osmo-options : %s -> %s" % (" ".join(e)[:80], rc))
        lignes += ["session=securise", "ancre=1"]
        lignes += ["mesure=totp"] if telephone else ["mesure=secret", "premier=1"]
    else:
        lignes.append("session=ubuntu")
        if "securise" in choix:
            lignes.append("securise-refuse=pas-de-tpm-2.0")
            libcalamares.utils.warning("osmo-options : poste securise demande SANS TPM 2.0 - Ubuntu ordinaire installe")
    os.makedirs(os.path.join(racine, "etc/osmo-operator"), exist_ok=True)
    with open(os.path.join(racine, "etc/osmo-operator/options"), "a") as f:
        f.write("\n".join(lignes) + "\n")
    return None

#!/usr/bin/env python3
# main.py - Calamares job "osmosupplements": carries the supplement choices
# from the installer to the first boot of the installed system.
#
# packagechooser@supplements (optionalmultiple, legacy method) stores the
# checked keys in packagechooser_supplements, comma separated;
# packagechooser@image stores ghcr or hub in packagechooser_image. They are
# translated into addition.sh flags, written to /etc/osmo-supplements in the
# target, and osmo-supplements.service is enabled: tools/osmo-supplements-firstboot.sh
# replays them at first boot, once the network is up.
import os

import libcalamares

DRAPEAUX = {
    "multi": "--multi",
    "opencl": "--opencl",
    "claude": "--claude",
    "firmwares": "--firmwares",
    "extras": "--extras",
}
IMAGES = {
    "ghcr": "ghcr.io/bbaranoff/osmo-operator/osmocom-nitb:latest",
    "hub": "bastienbaranoff/norf_gsm",
}
UNITE = "osmo-supplements.service"


def pretty_name():
    return "Supplements (premier demarrage)"


def _liste(cle):
    v = libcalamares.globalstorage.value(cle) or ""
    if isinstance(v, (list, tuple)):
        return [str(x).strip() for x in v if str(x).strip()]
    return [x.strip() for x in str(v).split(",") if x.strip()]


def run():
    root = libcalamares.globalstorage.value("rootMountPoint")
    if not root:
        return ("Supplements", "point de montage de la cible inconnu")
    choix = [c for c in _liste("packagechooser_supplements") if c in DRAPEAUX]
    conf = os.path.join(root, "etc/osmo-supplements")
    lien = os.path.join(root, "etc/systemd/system/multi-user.target.wants", UNITE)
    if not choix:
        libcalamares.utils.debug("osmosupplements : rien de coche")
        for f in (conf, lien):
            if os.path.lexists(f):
                os.remove(f)
        return None
    image = (_liste("packagechooser_image") or ["ghcr"])[0]
    with open(conf, "w") as f:
        f.write("# ecrit par l installeur (Calamares) - lu par tools/osmo-supplements-firstboot.sh\n")
        f.write('OSMO_SUPPLEMENTS="%s"\n' % " ".join(DRAPEAUX[c] for c in choix))
        if "multi" in choix:
            f.write('HUB_IMAGE="%s"\n' % IMAGES.get(image, IMAGES["ghcr"]))
        # Account created on the Users page: at first boot nobody is logged in
        # yet, so addition.sh could not find it (docker group, icons).
        compte = libcalamares.globalstorage.value("username")
        if compte:
            f.write('OSMO_COMPTE="%s"\n' % compte)
    if os.path.exists(os.path.join(root, "etc/systemd/system", UNITE)):
        os.makedirs(os.path.dirname(lien), exist_ok=True)
        if os.path.lexists(lien):
            os.remove(lien)
        os.symlink("/etc/systemd/system/" + UNITE, lien)
    else:
        libcalamares.utils.warning("osmosupplements : %s absente de la cible" % UNITE)
    libcalamares.utils.debug("osmosupplements : %s" % ", ".join(choix))
    return None

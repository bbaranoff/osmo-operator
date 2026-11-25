#!/usr/bin/env python3
"""composants-notes.py DIR - markdown table of the chroot components that did
not make it into the images, read from DIR/<image>/status.json (written by
iso_modules/80-chroot.sh). Prints nothing when every component is there.
Used for the job summary and the release notes (build-iso.yml)."""
import glob
import json
import os
import sys

racine = sys.argv[1] if len(sys.argv) > 1 else "osmo-build-logs"
lignes = []
for f in sorted(glob.glob(os.path.join(racine, "*", "status.json"))):
    image = os.path.basename(os.path.dirname(f))
    try:
        with open(f, encoding="utf-8", errors="replace") as fh:
            entrees = json.load(fh)
    except (OSError, ValueError) as e:
        lignes.append((image, "status.json", "illisible", str(e)))
        continue
    for e in entrees:
        if e.get("statut") != "ok" and e.get("classe") == "OPTIONNEL":
            lignes.append((image, e.get("composant", "?"), e.get("statut", "?"), e.get("erreur", "")))

if lignes:
    print("\n### Composants optionnels absents\n")
    print("Ces composants ont echoue pendant le build ; les images sont livrees sans eux "
          "(detail : `/var/log/osmo-build/` dans l'image, artefact `osmo-build-logs` du workflow).\n")
    print("| Image | Composant | Statut | Derniere ligne |")
    print("|---|---|---|---|")
    for image, comp, statut, err in lignes:
        err = err.replace("|", "/").replace("\n", " ")[:160]
        print(f"| {image} | {comp} | {statut} | {err} |")

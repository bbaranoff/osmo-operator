#!/bin/bash
# sommes-release.sh TAG - juste avant l envoi des fichiers (build-iso.yml).
#
# Un build ne produit souvent qu UNE partie des ISO (mode stp, base, lite,
# desktop). Il calculait SHA256SUMS, MD5SUMS et PARTS.sha256 pour SES seules
# ISO, puis les envoyait en --clobber : la release v0.2 n avait plus que la
# somme de osmo-operator-desktop.iso, les autres ISO n etaient plus
# verifiables. Ici :
#   1. LES SOMMES FUSIONNEES : celles deja publiees sont gardees pour les ISO
#      que ce build n a pas refaites ; celles des ISO refaites sont remplacees ;
#   2. LES FICHIERS PERIMES RETIRES : une ISO refaite peut changer de forme
#      (entiere <-> en morceaux de 1900 Mo, ou moins de morceaux) ; ce qui ne
#      correspond plus a ce build est retire de la release.
# Dans le dossier de travail : les ISO entieres et/ou leurs morceaux, et les
# sommes de ce build. Il faut GH_TOKEN et GH_REPO.
set -euo pipefail
TAG="${1:?usage : sommes-release.sh TAG}"
TOUTES="interstp.iso osmo-operator.iso osmo-operator-lite.iso osmo-operator-desktop.iso"

refaites=()
for iso in $TOUTES; do
    if [ -f "$iso" ] || compgen -G "$iso.part-*" >/dev/null; then refaites+=("$iso"); fi
done
[ "${#refaites[@]}" -gt 0 ] || { echo "aucune ISO dans ce build : rien a fusionner"; exit 0; }
echo "ISO refaites par ce build : ${refaites[*]}"

t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
for f in SHA256SUMS MD5SUMS PARTS.sha256; do
    gh release download "$TAG" -p "$f" -D "$t" --clobber >/dev/null 2>&1 || true
done

# 1. fusion : les lignes publiees des ISO NON refaites, puis celles de ce build
for f in SHA256SUMS MD5SUMS PARTS.sha256; do
    [ -f "$t/$f" ] || continue
    touch "$f"
    python3 - "$t/$f" "$f" "${refaites[@]}" <<'PY'
import sys
ancien, nouveau, refaites = sys.argv[1], sys.argv[2], sys.argv[3:]
def nom(l):
    p = l.rstrip("\n").split(None, 1)
    return p[1].lstrip("*") if len(p) == 2 else ""
def refaite(n):
    return any(n == i or n.startswith(i + ".part-") for i in refaites)
garde = [l for l in open(ancien) if l.strip() and not refaite(nom(l))]
neuf = [l for l in open(nouveau) if l.strip()]
lignes = sorted(garde + neuf, key=nom)
open(nouveau, "w").writelines(l if l.endswith("\n") else l + "\n" for l in lignes)
print("%s : %d ligne(s) gardee(s) de la release, %d de ce build" % (nouveau, len(garde), len(neuf)))
PY
done

# 2. les fichiers d une ISO refaite qui ne sont plus de ce build
publies="$(gh release view "$TAG" --json assets -q '.assets[].name' 2>/dev/null || true)"
for iso in "${refaites[@]}"; do
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        case "$a" in
            "$iso"|"$iso".part-*)
                if [ ! -f "$a" ]; then
                    echo "retire de la release (perime) : $a"
                    gh release delete-asset "$TAG" "$a" -y
                fi ;;
        esac
    done <<< "$publies"
done

echo "--- SHA256SUMS envoye ---"
cat SHA256SUMS

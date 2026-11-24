#!/bin/bash
# release-section.sh TAG SECTION NOTES.md
#
# The release TAG is shared by build-iso.yml (section « iso ») and
# build-arm.yml (section « arm64 »). Each workflow writes ONLY its own
# section of the text, between <!-- osmo:SECTION --> and <!-- /osmo:SECTION -->,
# and keeps the other one: whichever finishes last no longer erases the other.
# The title is the same for both: « Osmo-Operator TAG ».
#
# The release is created as a DRAFT if it does not exist yet (the workflow
# publishes it after its uploads); an existing release keeps its state.
# Needs GH_TOKEN and GH_REPO.
set -euo pipefail
TAG="$1" SECTION="$2" NOTES="$3"
ORDRE="iso arm64"   # order of the sections in the text
TITRE="Osmo-Operator $TAG"

if ! gh release view "$TAG" >/dev/null 2>&1; then
    # the other workflow may create it in the same seconds: on failure, look again
    gh release create "$TAG" --draft --title "$TITRE" --notes "" --target "${GITHUB_SHA:-main}" \
        || gh release view "$TAG" >/dev/null
fi

ancien="$(mktemp)" nouveau="$(mktemp)"
gh release view "$TAG" --json body -q .body > "$ancien"
python3 - "$ancien" "$NOTES" "$SECTION" "$ORDRE" > "$nouveau" <<'PY'
import re, sys
ancien, notes, section, ordre = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3], sys.argv[4].split()
bloc = lambda s, t: f"<!-- osmo:{s} -->\n{t.strip()}\n<!-- /osmo:{s} -->"
sections = {s: m.group(1) for s in ordre
            for m in [re.search(rf"<!-- osmo:{s} -->\n(.*?)\n<!-- /osmo:{s} -->", ancien, re.S)] if m}
sections[section] = notes
print("\n\n".join(bloc(s, sections[s]) for s in ordre if s in sections))
PY
gh release edit "$TAG" --title "$TITRE" --notes-file "$nouveau"
rm -f "$ancien" "$nouveau"

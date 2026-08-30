#!/bin/bash
# full_text.sh - Concat doc + tests + .h + .c + .py + .sh dans cet ordre
# en un seul .txt brut (separateurs ASCII, sans markdown fences).
# Pour ingestion LLM / archive plate.
#
# Usage :
#   ./full_text.sh                          # -> /tmp/calypso-full.txt
#   ./full_text.sh out.txt                  # custom output
#   SCOPE=hw/arm/calypso ./full_text.sh     # only this subdir
#   EXCLUDE='build|pc-bios' ./full_text.sh  # extra excludes

set -uo pipefail

OUT="${1:-./calypso-full.txt}"
SCOPE="${SCOPE:-.}"
EXCLUDE_RE="${EXCLUDE:-subprojects|build|pc-bios|tests/functional|tests/qtest|tests/unit|tests/migration|tests/qemu-iotests|node_modules|\.git|\.pytest_cache}"

# Si $OUT est un dossier, append le nom de fichier par defaut.
# Evite le cas "./full_text.sh /home/nirvana/qemu-calypso" -> echo >> dossier crash.
if [ -d "$OUT" ]; then
    OUT="${OUT%/}/calypso-full.txt"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

echo "=== full_text.sh ==="
echo "Scope    : $SCOPE"
echo "Output   : $OUT"
echo "Exclude  : $EXCLUDE_RE"
echo

: > "$OUT" || { echo "ERROR: cannot write to '$OUT' (permission ? path invalide ?)" >&2; exit 1; }

# ---- Header ----
cat >> "$OUT" <<EOF
================================================================================
Calypso QEMU - Full text bundle
Generated : $(date -Iseconds)
Scope     : $SCOPE
Sections  : 1.docs  2.tests  3.headers  4.sources  5.python  6.shell
================================================================================

EOF

# Helper : add a file with ASCII separator
_add() {
    local f="$1"
    local rel="${f#./}"
    local size=$(wc -c < "$f" 2>/dev/null || echo 0)
    local nlines=$(wc -l < "$f" 2>/dev/null || echo 0)
    {
        echo ""
        echo "================================================================================"
        echo "FILE: $rel"
        echo "SIZE: $size bytes, $nlines lines"
        echo "================================================================================"
        cat "$f"
        echo ""
    } >> "$OUT"
}

# Find files of a given pattern, filtered by EXCLUDE_RE
_find() {
    find "$SCOPE" -type f \( $1 \) 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" \
        | sort
}

# ---- 1) Documentation ----
{
    echo ""
    echo "################################################################################"
    echo "# SECTION 1 : DOCUMENTATION (.md, .mmd, .qmd)"
    echo "################################################################################"
} >> "$OUT"
DOCS=$(find "$SCOPE" -type f \( -name "*.md" -o -name "*.mmd" -o -name "*.qmd" \) 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" | sort)
N=$(echo "$DOCS" | grep -c . || echo 0)
echo "Section 1 : $N files"
echo "Total docs files : $N" >> "$OUT"
for f in $DOCS; do _add "$f"; done

# ---- 2) Tests ----
{
    echo ""
    echo "################################################################################"
    echo "# SECTION 2 : TESTS (tests/*.py)"
    echo "################################################################################"
} >> "$OUT"
TESTS=$(find "$SCOPE" -type f \( -name "test_*.py" -o -name "conftest.py" \) 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" | sort)
N=$(echo "$TESTS" | grep -c . || echo 0)
echo "Section 2 : $N files"
echo "Total tests files : $N" >> "$OUT"
for f in $TESTS; do _add "$f"; done

# ---- 3) Headers ----
{
    echo ""
    echo "################################################################################"
    echo "# SECTION 3 : HEADERS (.h)"
    echo "################################################################################"
} >> "$OUT"
HDRS=$(find "$SCOPE" -type f -name "*.h" 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" | sort)
N=$(echo "$HDRS" | grep -c . || echo 0)
echo "Section 3 : $N files"
echo "Total headers files : $N" >> "$OUT"
for f in $HDRS; do _add "$f"; done

# ---- 4) Sources ----
{
    echo ""
    echo "################################################################################"
    echo "# SECTION 4 : SOURCES (.c, .cpp)"
    echo "################################################################################"
} >> "$OUT"
SRCS=$(find "$SCOPE" -type f \( -name "*.c" -o -name "*.cpp" \) 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" | sort)
N=$(echo "$SRCS" | grep -c . || echo 0)
echo "Section 4 : $N files"
echo "Total sources files : $N" >> "$OUT"
for f in $SRCS; do _add "$f"; done

# ---- 5) Python scripts (hors tests/) ----
{
    echo ""
    echo "################################################################################"
    echo "# SECTION 5 : PYTHON SCRIPTS (hors tests/)"
    echo "################################################################################"
} >> "$OUT"
PYS=$(find "$SCOPE" -type f -name "*.py" 2>/dev/null \
       | grep -vE "$EXCLUDE_RE|/tests/|test_.*\.py$|conftest\.py$" | sort)
N=$(echo "$PYS" | grep -c . || echo 0)
echo "Section 5 : $N files"
echo "Total python files : $N" >> "$OUT"
for f in $PYS; do _add "$f"; done

# ---- 6) Shell scripts ----
{
    echo ""
    echo "################################################################################"
    echo "# SECTION 6 : SHELL SCRIPTS (.sh)"
    echo "################################################################################"
} >> "$OUT"
SHS=$(find "$SCOPE" -type f \( -name "*.sh" -o -name "*.bash" \) 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" | sort)
N=$(echo "$SHS" | grep -c . || echo 0)
echo "Section 6 : $N files"
echo "Total shell files : $N" >> "$OUT"
for f in $SHS; do _add "$f"; done

# ---- Footer ----
{
    echo ""
    echo "================================================================================"
    echo "END OF BUNDLE - generated $(date -Iseconds)"
    echo "================================================================================"
} >> "$OUT"

echo
echo "=== DONE ==="
echo "Output : $OUT"
echo "Size   : $(du -h "$OUT" | cut -f1)"
echo "Lines  : $(wc -l < "$OUT")"

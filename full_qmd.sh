#!/bin/bash
# full_qmd.sh - Bundle du depot en Quarto : doc + tests + .h + .c + .py + .sh,
# chaque fichier dans un bloc code type, theme "sketchy".
#
# DEUX MODES
#   MODE=single (defaut) : un seul .qmd. Simple, mais Deno/Quarto casse
#                          ("Maximum call stack size exceeded") au-dela de
#                          ~1-2 Mo, surtout avec embed-resources.
#   MODE=site            : projet Quarto multi-pages (recommande au-dela de 1 Mo).
#                          Sections decoupees en pages de SPLIT_KB max,
#                          recherche plein-texte integree, index global.
#
# Usage :
# TOUT EST ECRIT DANS UN SEUL DOSSIER ($OUTDIR, par defaut ./bundle-qmd/) :
# le .qmd, sketchy.css, sk-filter.html, et le rendu quarto. Le depot reste
# propre, et une seconde execution ne rescanne pas sa propre sortie.
#
# Usage :
#   MODE=site ./full_qmd.sh              # -> ./bundle-qmd/ (multi-pages)
#   ./full_qmd.sh                        # -> ./bundle-qmd/<depot>-full.qmd
#   ./full_qmd.sh out.qmd                # chemin explicite (mode single)
#   OUTDIR=/tmp/x ./full_qmd.sh          # ailleurs
#   PL4Y_SECTION=calypso ./full_qmd.sh   # section pl4y.store visee
#   SCOPE=hw/arm/calypso ./full_qmd.sh   # only this subdir
#   EXCLUDE='build|pc-bios' ./full_qmd.sh
#   MAX_KB=256 ./full_qmd.sh             # troncature par fichier
#   SPLIT_KB=300 MODE=site ./full_qmd.sh # taille max d'une page
#   EMBED=true ./full_qmd.sh             # html self-contained (risque de crash)
#   RENDER_MERMAID=0 ./full_qmd.sh       # .mmd en code au lieu de diagramme
#   RENDER=0 MODE=site ./full_qmd.sh     # sources .qmd seules, sans rendu

set -uo pipefail

case "${1:-}" in -h|--help) sed -n '2,30p' "$0"; exit 0;; esac

MODE="${MODE:-single}"
# Dossier unique de sortie, pour les DEUX modes. Le mode single ecrivait avant
# a la racine du depot (calypso-full.qmd + sketchy.css + sk-filter.html, puis
# calypso-full.html et calypso-full_files/ au rendu) : quatre artefacts laches
# dans le depot, que la passe suivante rescannait comme des sources.
# Nom derive du depot (osmo_egprs -> ./osmo_egprs-qmd) : les bundles de deux
# depots differents peuvent ainsi etre deposes cote a cote sans collision.
OUTDIR="${OUTDIR:-./$(basename "$(cd "$(dirname "$0")" && pwd)")-qmd}"
# Section pl4y.store visee par ce bundle : ecrite dans .pl4y-section a la racine
# du dossier de sortie. build.mjs (dans pl4y) la lit pour savoir sous quelle URL
# publier, plutot que de deviner d'apres le nom du dossier.
PL4Y_SECTION="${PL4Y_SECTION:-}"
OUT="${1:-}"
SCOPE="${SCOPE:-.}"
TITLE="${TITLE:-Calypso QEMU}"
SUBTITLE="${SUBTITLE:-Full source bundle - DSP C54x / osmocom-bb / SHUNT_LEGIT}"
MAX_KB="${MAX_KB:-512}"
SPLIT_KB="${SPLIT_KB:-400}"
RENDER_MERMAID="${RENDER_MERMAID:-1}"
EMBED="${EMBED:-false}"
# En mode site on rend par defaut : le dossier produit est alors DIRECTEMENT
# deposable dans pl4y/bundles/ (il contient _site/, du HTML). Sans rendu, ce
# n'est qu'un projet Quarto, que rien en aval ne sait publier.
# RENDER=0 pour ne generer que les sources .qmd.
if [ "$MODE" = "site" ]; then RENDER="${RENDER:-1}"; else RENDER="${RENDER:-0}"; fi
EXCLUDE_RE="${EXCLUDE:-subprojects|build|pc-bios|tests/functional|tests/qtest|tests/unit|tests/migration|tests/qemu-iotests|node_modules|\.git|\.pytest_cache}"

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# Le dossier existe avant toute chose : les deux modes ecrivent dedans.
mkdir -p "$OUTDIR" || { echo "ERROR: mkdir '$OUTDIR'" >&2; exit 1; }
OUTDIR="$(cd "$OUTDIR" && pwd)"

# Slug de section : explicite via PL4Y_SECTION, sinon derive du depot.
# qemu-calypso est publie sous /calypso/ — d'ou la seule correspondance
# particuliere.
if [ -z "$PL4Y_SECTION" ]; then
    case "$(basename "$HERE")" in
        qemu-calypso) PL4Y_SECTION="calypso" ;;
        *)            PL4Y_SECTION="$(basename "$HERE")" ;;
    esac
fi
printf '%s\n' "$PL4Y_SECTION" > "$OUTDIR/.pl4y-section"

# Sans argument, le .qmd va dans $OUTDIR. Un argument explicite reste
# respecte : `./full_qmd.sh /tmp/x.qmd` ecrit bien la (et son css/js a cote).
if [ -z "$OUT" ]; then
    OUT="$OUTDIR/$(basename "$HERE")-full.qmd"
elif [ -d "$OUT" ]; then
    OUT="${OUT%/}/$(basename "$HERE")-full.qmd"
fi

MAXB=$(( MAX_KB * 1024 ))
SPLITB=$(( SPLIT_KB * 1024 ))
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

GITREV="$(git rev-parse --short HEAD 2>/dev/null || echo 'n/a')"
GITBRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'n/a')"
NOW="$(date -Iseconds)"

# --- cible + auto-exclusion -------------------------------------------------
SELF_FIXED=""      # fichier a exclure du scan (mode single)
SELF_PREFIX=""     # prefixe de dossier a exclure (mode site)

# $OUTDIR est exclu du scan dans LES DEUX modes. Auparavant le mode single
# n'excluait que le .qmd lui-meme : sketchy.css, sk-filter.html et le
# repertoire *_files/ du rendu precedent etaient reavales comme des sources a
# chaque execution, et le bundle grossissait a chaque passe.
SELF_PREFIX="${OUTDIR#"$HERE"/}/"
[ "$SELF_PREFIX" = "$OUTDIR/" ] && SELF_PREFIX=""   # $OUTDIR hors du depot

if [ "$MODE" = "site" ]; then
    DEST=""
else
    mkdir -p "$(dirname "$OUT")" || { echo "ERROR: mkdir pour '$OUT'" >&2; exit 1; }
    : > "$OUT" || { echo "ERROR: cannot write '$OUT'" >&2; exit 1; }
    OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
    SELF_FIXED="${OUT_ABS#"$HERE"/}"
    DEST="$OUT"
fi

echo "=== full_qmd.sh ==="
echo "Mode     : $MODE"
echo "Scope    : $SCOPE"
echo "Output   : $([ "$MODE" = site ] && echo "$OUTDIR/" || echo "$OUT")"
echo "Exclude  : $EXCLUDE_RE"
echo "Max/file : ${MAX_KB} ko$([ "$MODE" = site ] && echo " | page: ${SPLIT_KB} ko")"
echo

# ------------------------------------------------------------------ helpers --

_lang_for() {
    case "${1##*.}" in
        c|h)        echo c ;;
        cpp|cc|cxx) echo cpp ;;
        py)         echo python ;;
        sh|bash)    echo bash ;;
        md|qmd)     echo markdown ;;
        mmd)        echo mermaid ;;
        *)          echo default ;;
    esac
}

_fence_for() {
    local maxrun n
    maxrun=$(grep -oE '^`{3,}' "$1" 2>/dev/null | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')
    n=3; [ "${maxrun:-0}" -ge 3 ] && n=$(( maxrun + 1 ))
    printf '%*s' "$n" '' | tr ' ' '`'
}

_anchor_for() {
    printf 'f-%s' "$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//')"
}

_human() {
    if command -v numfmt >/dev/null 2>&1; then numfmt --to=iec --suffix=B "$1"; else echo "$1 B"; fi
}

_self_filter() {
    { if [ -n "$SELF_FIXED" ]; then grep -vxF "$SELF_FIXED"; else cat; fi; } \
  | { if [ -n "$SELF_PREFIX" ]; then grep -vF "$SELF_PREFIX"; else cat; fi; }
}

_find_into() {
    local excl="$1"; shift
    local args=() p first=1
    for p in "$@"; do
        if [ "$first" -eq 1 ]; then args+=( -name "$p" ); first=0
        else args+=( -o -name "$p" ); fi
    done
    find "$SCOPE" -type f \( "${args[@]}" \) 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" \
        | { if [ -n "$excl" ]; then grep -vE "$excl"; else cat; fi; } \
        | sed 's|^\./||' \
        | _self_filter \
        | sort > "$TMPD/list"
    wc -l < "$TMPD/list"
}

# ------------------------------------------------------- emission d'un fichier

_add() {
    local f="$1" lang fence size nlines anchor ext eff
    ext="${f##*.}"
    lang="$(_lang_for "$f")"
    size=$(wc -c < "$f" 2>/dev/null || echo 0)
    nlines=$(wc -l < "$f" 2>/dev/null || echo 0)
    anchor="$(_anchor_for "$f")"

    {
        printf '\n## `%s` {#%s}\n\n' "$f" "$anchor"
        printf '::: {.file-meta}\n[.%s]{.tag} %s lignes - %s\n:::\n\n' "$ext" "$nlines" "$(_human "$size")"
    } >> "$DEST"

    if [ "$size" -eq 0 ]; then
        printf '::: {.callout-note appearance="simple"}\nFichier vide.\n:::\n' >> "$DEST"
        eff=0
    elif ! grep -Iq . "$f" 2>/dev/null; then
        printf '::: {.callout-warning appearance="simple"}\nFichier binaire - contenu omis.\n:::\n' >> "$DEST"
        eff=0
    else
        fence="$(_fence_for "$f")"
        if [ "$lang" = "mermaid" ] && [ "$RENDER_MERMAID" = "1" ]; then
            printf '%s{mermaid}\n' "$fence" >> "$DEST"
        else
            printf '%s{.%s .numberLines filename="%s"}\n' "$fence" "$lang" "$f" >> "$DEST"
        fi
        if [ "$size" -gt "$MAXB" ]; then
            head -c "$MAXB" "$f" >> "$DEST"
            printf '\n\n... [TRONQUE a %s ko - %s au total] ...\n' "$MAX_KB" "$(_human "$size")" >> "$DEST"
            eff=$MAXB
        else
            cat "$f" >> "$DEST"
            eff=$size
        fi
        printf '\n%s\n' "$fence" >> "$DEST"
    fi

    # manifest : section | page | fichier | ancre | lignes | taille
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$SECNUM" "$(basename "${DEST%.qmd}")" "$f" "$anchor" "$nlines" "$(_human "$size")" \
        >> "$TMPD/manifest"

    PAGE_BYTES=$(( PAGE_BYTES + eff + 400 ))
}

# ------------------------------------------------------------- mode site : page

_new_page() {
    local base
    base="$(printf 'sec%s-%02d' "$SECNUM" "$PART")"
    DEST="$OUTDIR/$base.qmd"
    printf '%s\t%s\t%s\t%s\n' "$SECNUM" "$SECTITLE" "$base.qmd" "partie $PART" >> "$TMPD/pages"
    cat > "$DEST" <<EOF
---
title: "$SECTITLE$([ "$PART" -gt 1 ] && printf ' - partie %s' "$PART")"
---

EOF
    PAGE_BYTES=0
}

# ----------------------------------------------------------------- une section

_section() {
    SECNUM="$1"; SECTITLE="$2"
    local extra_excl="$3" n f fsize
    shift 3
    n=$(_find_into "$extra_excl" "$@")
    echo "Section $SECNUM : $n files"

    if [ "$MODE" = "site" ]; then
        PART=1; _new_page
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            fsize=$(wc -c < "$f" 2>/dev/null || echo 0)
            [ "$fsize" -gt "$MAXB" ] && fsize=$MAXB
            if [ "$PAGE_BYTES" -gt 0 ] && [ $(( PAGE_BYTES + fsize )) -gt "$SPLITB" ]; then
                PART=$(( PART + 1 )); _new_page
            fi
            _add "$f"
        done < "$TMPD/list"
    else
        {
            printf '\n\n# %s {#sec-%s}\n\n' "$SECTITLE" "$SECNUM"
            printf '::: {.section-count}\n**%s fichiers**\n:::\n' "$n"
        } >> "$DEST"
        PAGE_BYTES=0
        while IFS= read -r f; do
            [ -n "$f" ] && _add "$f"
        done < "$TMPD/list"
    fi
}

# --------------------------------------------------------------------- le CSS

_write_css() {
    cat > "$1" <<'SKETCHYCSS'
@import url('https://fonts.googleapis.com/css2?family=Caveat:wght@600;700&family=Architects+Daughter&family=JetBrains+Mono:wght@400;700&display=swap');

:root{
  --sk-ink:#20242e;
  --sk-paper:#fffdf6;
  --sk-red:#e4572e;
  --sk-teal:#17968a;
  --sk-yellow:#ffd469;
  --sk-rough:255px 12px 225px 15px / 15px 225px 15px 255px;
  --sk-rough2:15px 225px 15px 255px / 255px 15px 225px 15px;
}

body{
  background-color:var(--sk-paper);
  background-image:
    linear-gradient(rgba(32,36,46,.05) 1px, transparent 1px),
    linear-gradient(90deg, rgba(32,36,46,.05) 1px, transparent 1px);
  background-size:28px 28px;
  font-family:'Architects Daughter','Neucha',ui-rounded,system-ui,sans-serif;
  color:var(--sk-ink);
}

h1.title{
  font-family:'Caveat',cursive; font-size:3.6rem; line-height:1.05;
  display:inline-block; padding:.1em .5em; transform:rotate(-1.1deg);
  background:var(--sk-yellow); border:3px solid var(--sk-ink);
  border-radius:var(--sk-rough); box-shadow:6px 6px 0 var(--sk-ink);
}
.subtitle{ font-size:1.2rem; opacity:.75; transform:rotate(.4deg); display:inline-block; }

h1:not(.title){
  font-family:'Caveat',cursive; font-size:2.9rem; margin-top:3.2rem;
  border-bottom:4px solid var(--sk-ink); border-radius:var(--sk-rough2);
  padding-bottom:.15em; transform:rotate(-.35deg);
}
h2{
  font-family:'JetBrains Mono',monospace; font-size:1.05rem; font-weight:700;
  margin-top:2.6rem; padding:.35em .7em; display:inline-block;
  background:#fff; border:2.5px dashed var(--sk-ink);
  border-radius:var(--sk-rough); box-shadow:3px 3px 0 rgba(23,150,138,.35);
}
h2 code{ background:none; color:var(--sk-ink); padding:0; font-size:1em; }

div.sourceCode, pre:not(.sourceCode){
  border:2.5px solid var(--sk-ink);
  border-radius:var(--sk-rough);
  box-shadow:5px 5px 0 rgba(32,36,46,.9), 10px 10px 0 rgba(228,87,46,.18);
  background:#fffef9 !important;
  transform:rotate(-.12deg);
}
code, pre, code span{ font-family:'JetBrains Mono',ui-monospace,monospace !important; }
div.sourceCode{ max-height:70vh; overflow:auto; }
code.sourceCode > span > a:first-child::before{ color:rgba(32,36,46,.28); }

.code-with-filename .code-with-filename-file{
  font-family:'Caveat',cursive !important; font-size:1.2rem; font-weight:700;
  background:var(--sk-yellow) !important; color:var(--sk-ink) !important;
  border:2.5px solid var(--sk-ink); border-bottom:none;
  border-radius:12px 110px 6px 6px / 40px 8px 6px 6px;
  transform:rotate(-.5deg); display:inline-block; padding:.15em .9em;
}
.code-with-filename .code-with-filename-file pre{ border:none; box-shadow:none; background:none; }

.file-meta{ font-size:.9rem; opacity:.8; margin:.1rem 0 .8rem .2rem; }
.file-meta .tag{
  background:var(--sk-teal); color:#fff; padding:.05em .55em; margin-right:.5em;
  border-radius:var(--sk-rough2); font-family:'JetBrains Mono',monospace; font-size:.8rem;
}
.section-count{
  display:inline-block; padding:.1em .8em; background:#fff;
  border:2px solid var(--sk-red); color:var(--sk-red);
  border-radius:var(--sk-rough2); transform:rotate(.7deg); margin-bottom:1rem;
}
.bundle-index table{ font-family:'JetBrains Mono',monospace; font-size:.82rem; width:100%; }
.bundle-index{
  border:2.5px solid var(--sk-ink); border-radius:var(--sk-rough);
  padding:.6rem 1rem; background:#fff; box-shadow:5px 5px 0 rgba(23,150,138,.3);
}
.bundle-index a{ text-decoration:none; }
.bundle-index tr:hover{ background:rgba(255,212,105,.35); }

#TOC, nav[role=doc-toc]{ font-family:'JetBrains Mono',monospace; font-size:.78rem; }
#TOC a.active, nav[role=doc-toc] a.active{ background:var(--sk-yellow); border-radius:var(--sk-rough2); }
#quarto-sidebar{ font-family:'JetBrains Mono',monospace; font-size:.85rem; }

.sk-filter{ position:sticky; top:0; z-index:50; padding:.4rem 0 .8rem; background:var(--sk-paper); }
.sk-filter input{
  width:100%; font-family:'Caveat',cursive; font-size:1.4rem; padding:.25em .8em;
  background:#fff; border:2.5px solid var(--sk-ink); border-radius:var(--sk-rough);
  box-shadow:4px 4px 0 rgba(228,87,46,.35); outline:none;
}
.sk-filter input:focus{ box-shadow:4px 4px 0 var(--sk-teal); }

a{ color:var(--sk-red); text-decoration-style:wavy; text-decoration-thickness:1px; }
blockquote{ border-left:4px solid var(--sk-teal); }
SKETCHYCSS
}

_write_filter_js() {
    cat > "$1" <<'FILTERJS'
<script>
document.addEventListener('DOMContentLoaded', function () {
  var box = document.getElementById('sk-filter');
  if (!box) return;
  var rows = Array.from(document.querySelectorAll('.bundle-index tbody tr'));
  var toc  = Array.from(document.querySelectorAll('#TOC a, nav[role=doc-toc] a'));
  box.addEventListener('input', function () {
    var q = box.value.trim().toLowerCase();
    rows.forEach(function (r) {
      r.style.display = (!q || r.textContent.toLowerCase().includes(q)) ? '' : 'none';
    });
    toc.forEach(function (a) {
      var li = a.closest('li') || a;
      li.style.display = (!q || a.textContent.toLowerCase().includes(q)) ? '' : 'none';
    });
  });
});
</script>
FILTERJS
}

: > "$TMPD/manifest"
: > "$TMPD/pages"

# =========================================================== MODE SINGLE ======

if [ "$MODE" != "site" ]; then

cat >> "$OUT" <<EOF
---
title: "$TITLE"
subtitle: "$SUBTITLE"
date: "$NOW"
date-format: "YYYY-MM-DD HH:mm"
lang: fr
format:
  html:
    theme: [sketchy]
    css: sketchy.css
    toc: true
    toc-depth: 2
    toc-location: left
    toc-title: "Fichiers"
    toc-expand: 1
    number-sections: false
    anchor-sections: true
    smooth-scroll: true
    code-copy: true
    code-overflow: scroll
    code-block-bg: true
    highlight-style: arrow
    embed-resources: $EMBED
    include-after-body: sk-filter.html
    grid:
      sidebar-width: 340px
      body-width: 1150px
      margin-width: 140px
    mermaid:
      theme: neutral
---

::: {.sk-filter}
<input id="sk-filter" type="text" placeholder="filtrer les fichiers (ex: dsp, .c, shunt)..." autocomplete="off">
:::

::: {.callout-note appearance="simple" icon=false}
**Bundle plat du depot** - doc, tests, headers, sources, python, shell.
Scope \`$SCOPE\` - git \`$GITBRANCH@$GITREV\` - genere $NOW
- exclusions \`$EXCLUDE_RE\` - troncature ${MAX_KB} ko/fichier.
:::
EOF

_write_css "$(dirname "$OUT")/sketchy.css"
_write_filter_js "$(dirname "$OUT")/sk-filter.html"

fi

# ============================================================= MODE SITE ======

if [ "$MODE" = "site" ]; then
    _write_css "$OUTDIR/sketchy.css"
    _write_filter_js "$OUTDIR/sk-filter.html"
fi

# ------------------------------------------------------------------ sections

_section 1 "1 - Documentation" ''                                   '*.md' '*.mmd' '*.qmd'
_section 2 "2 - Tests"         ''                                   'test_*.py' 'conftest.py'
_section 3 "3 - Headers"       ''                                   '*.h'
_section 4 "4 - Sources"       ''                                   '*.c' '*.cpp'
_section 5 "5 - Python"        '/tests/|test_.*\.py$|conftest\.py$' '*.py'
_section 6 "6 - Shell"         ''                                   '*.sh' '*.bash'

# ------------------------------------------------------- index + config site --

if [ "$MODE" = "site" ]; then

    # index.qmd : table globale, liens inter-pages
    {
        cat <<EOF
---
title: "$TITLE"
subtitle: "$SUBTITLE"
date: "$NOW"
date-format: "YYYY-MM-DD HH:mm"
---

::: {.callout-note appearance="simple" icon=false}
**Bundle du depot** - doc, tests, headers, sources, python, shell.
Scope \`$SCOPE\` - git \`$GITBRANCH@$GITREV\` - genere $NOW
- exclusions \`$EXCLUDE_RE\` - troncature ${MAX_KB} ko/fichier - pages de ${SPLIT_KB} ko max.
:::

::: {.sk-filter}
<input id="sk-filter" type="text" placeholder="filtrer les fichiers (ex: dsp, .c, shunt)..." autocomplete="off">
:::
EOF
        cursec=""
        while IFS=$'\t' read -r sec page f anchor nlines size; do
            if [ "$sec" != "$cursec" ]; then
                [ -n "$cursec" ] && printf '\n:::\n'
                title="$(awk -F'\t' -v s="$sec" '$1==s {print $2; exit}' "$TMPD/pages")"
                printf '\n# %s\n\n::: {.bundle-index}\n\n' "$title"
                printf '| Fichier | Lignes | Taille |\n|:---|---:|---:|\n'
                cursec="$sec"
            fi
            printf '| [`%s`](%s.html#%s) | %s | %s |\n' "$f" "$page" "$anchor" "$nlines" "$size"
        done < "$TMPD/manifest"
        printf '\n:::\n'
    } > "$OUTDIR/index.qmd"

    # _quarto.yml
    {
        cat <<EOF
project:
  type: website
  output-dir: _site

website:
  title: "$TITLE"
  search:
    location: sidebar
    type: textbox
  sidebar:
    style: floating
    collapse-level: 1
    contents:
      - text: "Index"
        href: index.qmd
EOF
        cursec=""
        while IFS=$'\t' read -r sec title page part; do
            if [ "$sec" != "$cursec" ]; then
                printf '      - section: "%s"\n        contents:\n' "$title"
                cursec="$sec"
            fi
            printf '          - href: %s\n            text: "%s"\n' "$page" "$part"
        done < "$TMPD/pages"

        cat <<EOF

format:
  html:
    theme: [sketchy]
    css: sketchy.css
    toc: true
    toc-depth: 2
    toc-location: right
    toc-title: "Fichiers"
    number-sections: false
    anchor-sections: true
    smooth-scroll: true
    code-copy: true
    code-overflow: scroll
    code-block-bg: true
    highlight-style: arrow
    embed-resources: false
    include-after-body: sk-filter.html
    mermaid:
      theme: neutral
EOF
    } > "$OUTDIR/_quarto.yml"
fi

# -------------------------------------------------------------------- footer

if [ "$MODE" != "site" ]; then
cat >> "$OUT" <<EOF

# Fin du bundle

::: {.section-count}
genere $NOW - \`$(basename "$0")\`
:::
EOF
fi

echo
echo "=== DONE ==="
if [ "$MODE" = "site" ]; then
    echo "Output : $OUTDIR/  ($(ls "$OUTDIR"/*.qmd | wc -l) pages, $(du -sh "$OUTDIR" | cut -f1))"
    echo "Rendu  : (cd \"$OUTDIR\" && quarto render)"
    echo "Preview: (cd \"$OUTDIR\" && quarto preview)"
else
    echo "Output : $OUT ($(du -h "$OUT" | cut -f1), $(wc -l < "$OUT") lignes)"
    echo "         + sketchy.css + sk-filter.html dans $(dirname "$OUT")/"
    echo "Rendu  : quarto render \"$OUT\"   (sortie dans $(dirname "$OUT")/)"
    if [ "$(wc -c < "$OUT")" -gt 1500000 ]; then
        echo
        echo "!! $(du -h "$OUT" | cut -f1) dans un seul document : Deno risque de casser"
        echo "   (RangeError: Maximum call stack size exceeded). Utilise MODE=site."
    fi
fi

if [ "$RENDER" = "1" ]; then
    if command -v quarto >/dev/null 2>&1; then
        if [ "$MODE" = "site" ]; then (cd "$OUTDIR" && quarto render); else quarto render "$OUT"; fi
    else
        echo "quarto introuvable dans le PATH - rendu ignore." >&2
    fi
fi

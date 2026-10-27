#!/usr/bin/env bash
# dockerfile-to-install-md.sh - the Dockerfile, step by step, as an "install from scratch" Markdown.
#
# The Dockerfile is the only complete and tested description of the installation
# (apt packages, compiled Osmocom stack, osmocom-bb + firmware, qosmo, gr-gsm, node, LTE...).
# Rather than maintaining by hand a second document that drifts, it is generated:
#   each FROM becomes a chapter, each RUN a bash block to paste as is in a root shell,
#   each COPY a cp from the repository, the Dockerfile comments become the prose.
#
#   tools/dockerfile-to-install-md.sh                      # Dockerfile -> doc/install-from-scratch.md
#   tools/dockerfile-to-install-md.sh Dockerfile.run -o doc/x.md
#   tools/dockerfile-to-install-md.sh --annexe doc/c54x_exe-depuis-ubuntu-vierge.md
#
# Deliberately simple (embedded python3, no dependency).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$HERE/Dockerfile"
OUT="$HERE/doc/install-from-scratch.md"
ANNEXES=()
LANG_DOC=fr
NOTES=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--out)    OUT="$2"; shift ;;
        --annexe)    ANNEXES+=("$2"); shift ;;
        # --lang en: English prose; the (French) Dockerfile comments are replaced by the
        # per-step notes of --notes <file> (sections "## <step name>"), the command blocks stay.
        --lang)      LANG_DOC="$2"; shift ;;
        --notes)     NOTES="$2"; shift ;;
        -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
        *)           DOCKERFILE="$1" ;;
    esac
    shift
done
[ -r "$DOCKERFILE" ] || { echo "Dockerfile illisible : $DOCKERFILE" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
python3 - "$DOCKERFILE" "$OUT" "$HERE" "$LANG_DOC" "$NOTES" "${ANNEXES[@]}" <<'EOF'
import re, sys, datetime, os
src, out, root, lang, notes_file, *annexes = sys.argv[1:]
EN = (lang == "en")
notes = {}
if notes_file and os.path.isfile(notes_file):
    cur = None
    for l in open(notes_file, encoding="utf-8").read().split("\n"):
        m = re.match(r"^## (\S+)", l)
        if m:
            cur = m.group(1); notes[cur] = []
        elif cur is not None:
            notes[cur].append(l)
    notes = {k: "\n".join(v).strip() for k, v in notes.items()}
lines = open(src, encoding="utf-8", errors="replace").read().split("\n")

# 1. re-join the continuations (\ at end of line), keep the comments that precede
items = []          # (comments:list[str], instr:str, args:str)
pending = []
i = 0
while i < len(lines):
    l = lines[i]
    if not l.strip():
        if pending and items and not items[-1][1]:
            pass
        i += 1
        continue
    if l.lstrip().startswith("#"):
        # keep the indentation after the "#": indented lines (diagrams, lists
        # "RAND=0 -> ...") are rendered verbatim, in a block
        pending.append(l.lstrip()[1:].rstrip())
        i += 1
        continue
    buf = [l]
    # continuation: as long as the last NON-comment line ends with "\"; Docker accepts
    # "# ..." lines in the middle of a continued RUN, they do not carry a "\"
    def derniere_utile():
        for b in reversed(buf):
            if not b.lstrip().startswith("#"):
                return b
        return ""
    while derniere_utile().rstrip().endswith("\\") and i + 1 < len(lines):
        i += 1
        buf.append(lines[i])
    i += 1
    text = "\n".join(buf)
    m = re.match(r"\s*([A-Z]+)\s*(.*)", text, re.S)
    if not m:
        continue
    items.append((pending, m.group(1), m.group(2)))
    pending = []

def prose(comments):
    """Les commentaires du Dockerfile, en paragraphes. Les titres « N. ... » et « -- ... -- » deviennent des sous-titres."""
    outl = []
    if EN:
        return outl
    para = []
    def flush():
        if para:
            outl.append(" ".join(para)); outl.append("")
            para.clear()
    verb = []
    def flush_verb():
        if verb:
            flush(); outl.append("```text"); outl.extend(verb); outl.append("```"); outl.append("")
            verb.clear()
    for c in comments:
        if c.startswith("  ") and c.strip():        # ligne indentee : verbatim
            verb.append(c[1:] if c.startswith(" ") else c)
            continue
        flush_verb()
        c = c.strip()
        if c.startswith("syntax="):
            continue
        s = re.sub(r"^[─━═\-]{3,}\s*", "", c); s = re.sub(r"\s*[─━═\-]{3,}$", "", s)
        if not s:
            flush(); continue
        if re.match(r"^(\d+\.\s+|[A-ZÉ][^a-z]{6,}$)", s) or (c.startswith("──") or c.startswith("---") or c.startswith("══")):
            flush(); outl.append("#### " + s.strip(" :")); outl.append("")
            continue
        para.append(s)
    flush_verb(); flush()
    return outl

def strip_mounts(cmd):
    cmd = re.sub(r"--mount=\S+(\s*\\\n\s*)?", "", cmd)
    return cmd

def run_block(args):
    cmd = strip_mounts(args).strip()
    # comments inside RUNs: they are already bash (#), keep them
    return ["```bash", cmd, "```", ""]

doc = []
if EN:
    doc.append("# Installing from scratch (generated from the Dockerfile)")
    doc.append("")
    doc.append("> Generated by `tools/dockerfile-to-install-md.sh --lang en` on %s from `%s`. Do not edit by hand: fix the Dockerfile, the script or `%s`, then regenerate. The French version (`doc/install-from-scratch.md`) carries the full rationale written in the Dockerfile comments; this one keeps the commands and a short English note per stage."
               % (datetime.date.today().isoformat(), os.path.relpath(src, root), os.path.relpath(notes_file, root) if notes_file else "the notes file"))
    doc.append("")
    doc.append("""## How to read this page

The osmo-operator Dockerfile is the complete, tested description of the installation. This page replays it
step by step on a bare machine (Ubuntu 24.04, as root), without Docker:

- every `FROM ... AS <name>` of the Dockerfile is a chapter; on a single machine the stages simply follow
  each other and the `COPY --from=<stage>` instructions are not needed (everything is already in place);
- every `RUN` is a bash block to paste as is into a root shell, in order;
- every `ARG`/`ENV` becomes an `export` to set before the blocks that follow (in Docker an `ARG` does not
  survive a `FROM`; here it just stays in the shell);
- every `COPY` becomes a `cp` from a checkout of the osmo-operator repository (`$REPO`, `/opt/GSM/osmo-operator` by default).

The `.deb` package cache (`osmo-deb install <name> <version>`) is an optimisation of the Docker build:
without the cache the command fails and the `if ! osmo-deb install ...; then ... fi` branch builds from
source, which is exactly what a bare machine needs. `osmo-deb pack` then wraps the result (`make install`);
without `/var/cache/osmo-debs` it just installs.

```bash
export REPO=/opt/GSM/osmo-operator      # checkout of the repository (git clone https://github.com/bbaranoff/osmo-operator)
export ROOT=/opt/GSM
mkdir -p "$ROOT"
```
""")
fr = []
fr.append("# Installation depuis zero (generee depuis le Dockerfile)")
fr.append("")
fr.append("> Fichier genere par `tools/dockerfile-to-install-md.sh` le %s depuis `%s`. Ne pas editer a la main : corriger le Dockerfile ou le script, puis regenerer."
           % (datetime.date.today().isoformat(), os.path.relpath(src, root)))
fr.append("")
fr.append("""## Comment lire cette page

Le Dockerfile d'osmo-operator est la description complete et testee de l'installation. Cette page le rejoue
etape par etape sur une machine nue (Ubuntu 24.04, en root), sans Docker :

- chaque `FROM ... AS <nom>` du Dockerfile est un chapitre ; sur une seule machine les etapes se suivent
  simplement, les `COPY --from=<etape>` ne sont plus necessaires (tout est deja en place) ;
- chaque `RUN` est un bloc bash a coller tel quel dans un shell root, dans l'ordre ;
- chaque `ARG`/`ENV` devient un `export` a poser avant les blocs qui suivent (les `ARG` ne traversent pas
  un `FROM` dans Docker, ici on les garde dans le shell) ;
- chaque `COPY` devient un `cp` depuis une copie du depot osmo-operator (`$REPO`, par defaut `/opt/GSM/osmo-operator`).

Le cache de paquets `.deb` (`osmo-deb install <nom> <version>`) est une optimisation du build Docker :
sans cache, la commande echoue et la branche `if ! osmo-deb install ...; then ... fi` compile depuis les
sources, ce qui est exactement ce qu'on veut sur une machine nue. `osmo-deb pack` emballe ensuite le
resultat (`make install`) ; sans `/var/cache/osmo-debs` il se contente d'installer.

```bash
export REPO=/opt/GSM/osmo-operator      # copie du depot (git clone https://github.com/bbaranoff/osmo-operator)
export ROOT=/opt/GSM
mkdir -p "$ROOT"
```
""")

if not EN:
    doc.extend(fr)

# table of contents
stages = [(k, a) for (c, k, a) in items if k == "FROM"]
doc.append("## Table of contents" if EN else "## Sommaire")
doc.append("")
n = 0
for c, k, a in items:
    if k == "FROM":
        n += 1
        m = re.match(r"(\S+)(?:\s+AS\s+(\S+))?", a, re.I)
        base, name = m.group(1), (m.group(2) or m.group(1))
        if EN:
            doc.append("%d. [%s](#stage-%d--%s) (from `%s`)" % (n, name, n, name.lower().replace("_", "-"), base))
        else:
            doc.append("%d. [%s](#etape-%d--%s) (a partir de `%s`)" % (n, name, n, name.lower().replace("_", "-"), base))
doc.append("")

n = 0
for comments, k, a in items:
    if k == "FROM":
        n += 1
        m = re.match(r"(\S+)(?:\s+AS\s+(\S+))?", a, re.I)
        base, name = m.group(1), (m.group(2) or m.group(1))
        doc.append("")
        doc.append(("## Stage %d : %s" if EN else "## Etape %d : %s") % (n, name))
        doc.append("")
        doc.extend(prose(comments))
        if EN and notes.get(name):
            doc.append(notes[name]); doc.append("")
        if base == "scratch":
            doc.append("_Docker stage without content of its own (`scratch` image): nothing to do on a machine._" if EN else "_Etape Docker sans contenu propre (image `scratch`) : rien a faire sur une machine._")
            doc.append("")
        else:
            doc.append(("_In Docker: `FROM %s`. On a machine, carry on in the same system._" if EN else "_Dans Docker : `FROM %s`. Sur une machine, on continue dans le meme systeme._") % base)
            doc.append("")
        continue
    doc.extend(prose(comments))
    if k in ("ARG", "ENV"):
        body = a.replace("\\\n", "\n").strip()
        exports = []
        for kv in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)=((?:\"[^\"]*\")|(?:'[^']*')|\S*)", body):
            exports.append("export %s=%s" % (kv[0], kv[1] if kv[1] != "" else '""'))
        if not exports and body:
            exports.append("export " + body)
        doc.append("```bash"); doc.extend(exports); doc.append("```"); doc.append("")
    elif k == "RUN":
        doc.extend(run_block(a))
    elif k == "COPY" or k == "ADD":
        parts = a.split()
        opts = [p for p in parts if p.startswith("--")]
        files = [p for p in parts if not p.startswith("--")]
        frm = [o for o in opts if o.startswith("--from=")]
        if frm:
            doc.append(("_Copy between Docker stages (`%s`): on a single machine %s is already in place._" if EN else "_Copie entre etapes Docker (`%s`) : sur une seule machine, %s est deja en place._") % (a.replace("\n", " "), ", ".join("`%s`" % f for f in files[:-1])))
            doc.append("")
        elif len(files) >= 2:
            dst = files[-1]
            doc.append("```bash")
            for s in files[:-1]:
                if dst.endswith("/"):
                    doc.append('mkdir -p %s && cp -r "$REPO"/%s %s' % (dst, s, dst))
                else:
                    doc.append('mkdir -p "$(dirname %s)" && cp -r "$REPO"/%s %s' % (dst, s, dst))
            doc.append("```"); doc.append("")
    elif k == "WORKDIR":
        doc.append("```bash"); doc.append("cd %s" % a.strip()); doc.append("```"); doc.append("")
    elif k in ("STOPSIGNAL", "ENTRYPOINT", "CMD", "EXPOSE", "LABEL", "HEALTHCHECK", "USER", "VOLUME", "SHELL"):
        doc.append(("_Docker metadata, no equivalent on a machine: `%s %s`._" if EN else "_Metadonnee Docker, sans equivalent sur une machine : `%s %s`._") % (k, a.replace("\n", " ").strip()))
        doc.append("")
    else:
        doc.append(("_Unhandled instruction: `%s %s`._" if EN else "_Instruction non traitee : `%s %s`._") % (k, a[:80]))
        doc.append("")

for an in annexes:
    if not os.path.isfile(an):
        continue
    doc.append("")
    doc.append("---")
    doc.append("")
    doc.append(("# Appendix: %s" if EN else "# Annexe : %s") % os.path.basename(an))
    doc.append("")
    doc.append(("_Contents of `%s`, included as is._" if EN else "_Contenu de `%s`, repris tel quel._") % os.path.relpath(an, root))
    doc.append("")
    txt = open(an, encoding="utf-8", errors="replace").read()
    # shift the headings down one level
    txt = re.sub(r"^(#{1,5}) ", lambda m: "#" + m.group(1) + " ", txt, flags=re.M)
    doc.append(txt)

open(out, "w", encoding="utf-8").write("\n".join(doc).rstrip() + "\n")
print("%s : %d lignes, %d etapes FROM, %d RUN" % (out, len(doc), len(stages), sum(1 for c,k,a in items if k=="RUN")))
EOF

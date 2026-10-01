#!/usr/bin/env python3
"""tout-en-un.py — rassemble tous les fichiers texte (sources, scripts, configs,
docs, logs) d'un ou plusieurs dossiers dans UN fichier Markdown, raccourci SANS PERTE :

  * fichiers identiques (meme contenu) : une seule copie, les autres renvoient
    a la premiere ;
  * lignes consecutives identiques : « ligne  ×N » ;
  * lignes consecutives qui ne different que par des nombres (horodatage,
    compteur, fn...) : un gabarit ou les nombres constants restent en place et
    les nombres variables deviennent ⟨1⟩ ⟨2⟩..., suivi de la liste ordonnee des
    valeurs. On reconstruit chaque ligne en remettant les valeurs dans l'ordre.
  * codes couleur ANSI et retours chariot retires (seule perte, volontaire).

    ./tout-en-un.py [dossier...]      defaut : /opt/GSM/osmo-operator et le dernier /root/osmo-operator-*
    SORTIE=/chemin.md  EXT="sh py c"  (restreint aux extensions ; defaut : tout fichier texte)
    SEUIL=3 (taille mini d'un groupe)

  Sont ecartes : .git et caches, binaires (ELF, images, .pyc, archives), sauvegardes
  (.bak*, ~, .orig), LICENSE/COPYING et les sorties precedentes de ce script.
"""
import glob
import hashlib
import os
import re
import sys
import time

EXT = os.environ.get("EXT", "").split()             # vide : tout fichier texte
SEUIL = int(os.environ.get("SEUIL", "3"))
FORMAT = os.environ.get("FORMAT", "qmd")           # qmd (Quarto) ou md
SORTIE = os.environ.get("SORTIE") or "/root/osmo-operator-%s.%s" % (time.strftime("%Y%m%d-%H%M%S"), FORMAT)
AUTEUR = os.environ.get("AUTEUR", "Banc GSM émulé — banc-max")
IGNORES = {".git", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", "node_modules", ".venv", "venv",
           "rom", "roms",                              # dumps de ROM (DSP Calypso) : pas a nous, pas dans le dossier
           "osmo-operator-qmd"}                        # compilation du depot par un autre outil : tout en double
BINAIRES = set("png jpg jpeg gif bmp ico webp pdf zip gz tgz bz2 xz 7z tar bin elf o a so pyc pyo pyd "
               "wav mp3 ogg mp4 sqlite db img iso woff woff2 ttf otf".split())
SAUVEGARDES = re.compile(r"(~|\.orig|\.rej|\.swp|\.bak(-\w+)?)$")
TITRE_SORTIE = "title: \"Banc GSM émulé — dossier de run\"".encode()   # une sortie precedente de ce script
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
TELNET = re.compile(rb"\xff[\xfb-\xfe].|\xff.")           # negociation telnet (IAC) des captures VTY
CONTROLE = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\ufffd]")  # caracteres de commande, octets indecodables
NUM = re.compile(r"\d+")
# Preambule LaTeX du format pdf (xelatex). Sans lui : « Dimension too large » (framed
# mesure tout le bloc de code avant de le couper), lignes de code non repliees,
# diagrammes Mermaid plus larges que la page, glyphes manquants.
PDF_PREAMBULE = "".join("        %s\n" % l for l in r"""
% Code : police reduite, retour a la ligne (y compris dans les mots longs)
\usepackage{fvextra}
\fvset{fontsize=\small,breaklines,breakanywhere}
\RecustomVerbatimEnvironment{verbatim}{Verbatim}{fontsize=\small,breaklines,breakanywhere}
% Images (diagrammes Mermaid) : jamais plus larges que la ligne ni plus hautes que la page
\usepackage{adjustbox}
\usepackage{letltxmacro}
\LetLtxMacro\ORIGincludegraphics\includegraphics
\renewcommand{\includegraphics}[2][]{\adjustimage{#1,max width=\linewidth,max totalheight=.85\textheight}{#2}}
% Sans cadre : framed/snugshade mesure tout le bloc et plante ("Dimension too large")
\renewenvironment{Shaded}{\medskip}{\medskip}
% Glyphes absents de Latin Modern Roman -> DejaVu Sans
\usepackage{newunicodechar}
\newfontfamily\fallbackfont{DejaVu Sans}
\newunicodechar{↔}{{\fallbackfont ↔}}
\newunicodechar{⟨}{{\fallbackfont ⟨}}
\newunicodechar{⟩}{{\fallbackfont ⟩}}
\newunicodechar{≠}{{\fallbackfont ≠}}
\newunicodechar{∈}{{\fallbackfont ∈}}
\newunicodechar{ᵉ}{{\fallbackfont ᵉ}}
\newunicodechar{✓}{{\fallbackfont ✓}}
\newunicodechar{✗}{{\fallbackfont ✗}}
\newunicodechar{⚠}{{\fallbackfont ⚠}}
\newunicodechar{📱}{{\fallbackfont ☎}}
\newunicodechar{↩}{{\fallbackfont ↩}}
""".strip("\n").split("\n"))

LANG = {"sh": "bash", "bash": "bash", "py": "python", "md": "markdown", "qmd": "markdown", "mmd": "mermaid",
        "txt": "text", "log": "text", "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "hpp": "cpp",
        "ini": "ini", "env": "ini", "service": "ini", "desktop": "ini", "toml": "toml", "yml": "yaml",
        "yaml": "yaml", "json": "json", "patch": "diff", "diff": "diff", "mak": "makefile", "mk": "makefile",
        "html": "html", "xml": "xml", "svg": "xml", "js": "javascript", "css": "css", "sql": "sql", "rs": "rust"}
NOMS_LANG = {"Makefile": "makefile", "GNUmakefile": "makefile", "Dockerfile": "dockerfile"}


def extension(nom):
    return nom.rsplit(".", 1)[-1].lower() if "." in nom[1:] else ""


def langage(chemin):
    """Langage de coloration : extension, puis nom du fichier, puis shebang."""
    nom = os.path.basename(chemin)
    e = extension(nom)
    if e in LANG:
        return LANG[e]
    if nom in NOMS_LANG:
        return NOMS_LANG[nom]
    try:
        premiere = open(chemin, "rb").readline().decode("utf-8", "replace")
    except OSError:
        premiere = ""
    if premiere.startswith("#!"):
        if "python" in premiere:
            return "python"
        if re.search(r"\b(ba|z|da|k)?sh\b", premiere):
            return "bash"
    return "text"


def texte_legitime(chemin, nom):
    """Fichier texte a nous : ni binaire, ni sauvegarde, ni licence, ni sortie de ce script."""
    if extension(nom) in BINAIRES or SAUVEGARDES.search(nom) or nom in ("LICENSE", "COPYING"):
        return False
    if nom.startswith("tout-en-un-"):
        return False
    try:
        with open(chemin, "rb") as f:
            debut = f.read(8192)
    except OSError:
        return False
    if b"\0" in debut:                        # ELF, images, .pyc, archives...
        return False
    if TITRE_SORTIE in debut:
        return False
    return True


def dossiers_par_defaut():
    runs = sorted(glob.glob("/root/osmo-operator-*"), key=os.path.getmtime)
    runs = [r for r in runs if os.path.isdir(r)]
    return ["/opt/GSM/osmo-operator"] + ([runs[-1]] if runs else [])


def fichiers(dossier):
    for racine, dirs, noms in os.walk(dossier):
        dirs[:] = sorted(d for d in dirs if d not in IGNORES)
        for n in sorted(noms):
            chemin = os.path.join(racine, n)
            if EXT and extension(n) not in EXT:
                continue
            if texte_legitime(chemin, n):
                yield chemin


LIGNE_MAX = int(os.environ.get("LIGNE_MAX", "1000"))


def couper(l):
    if len(l) <= LIGNE_MAX:
        return [l]
    return [l[i:i + LIGNE_MAX] + ("↩" if i + LIGNE_MAX < len(l) else "") for i in range(0, len(l), LIGNE_MAX)]


def compacter(lignes):
    """Rend (lignes de sortie, nb de groupes compactes)."""
    out, groupes, i, n = [], 0, 0, len(lignes)
    while i < n:
        cle = NUM.sub("\0", lignes[i])
        j = i + 1
        while j < n and NUM.sub("\0", lignes[j]) == cle:
            j += 1
        taille = j - i
        if taille < SEUIL:
            out.extend(lignes[i:j])
            i = j
            continue
        groupes += 1
        if "\0" not in cle:                      # repetition exacte
            out.append("%s  ×%d" % (lignes[i], taille))
            i = j
            continue
        valeurs = [NUM.findall(l) for l in lignes[i:j]]
        nb = len(valeurs[0])
        varie = [len({v[k] for v in valeurs}) > 1 for k in range(nb)]
        # gabarit : nombres constants remis en place, variables numerotes ⟨k⟩
        morceaux, k, idx = cle.split("\0"), 0, 0
        gab = morceaux[0]
        for m in morceaux[1:]:
            if varie[k]:
                idx += 1
                gab += "⟨%d⟩" % idx
            else:
                gab += valeurs[0][k]
            gab += m
            k += 1
        out.append("%s  ×%d" % (gab, taille))
        if idx:
            tuples = [",".join(v[k] for k in range(nb) if varie[k]) for v in valeurs]
            # lignes de valeurs de ~100 colonnes
            ligne, courant = [], "    ⟨⟩ ="
            for t in tuples:
                if len(courant) + len(t) + 3 > 110:
                    ligne.append(courant)
                    courant = "       "
                courant += " (" + t + ")"
            ligne.append(courant)
            out.extend(ligne)
        i = j
    return out, groupes


def synthese(tous):
    """Run, echelle, echecs, bilan de couverture : lus dans verdict.txt / couverture.txt."""
    lignes, vus = [], set()
    for f in tous:
        nom = os.path.basename(f)
        if nom not in ("verdict.txt", "couverture.txt"):
            continue
        run = os.path.basename(os.path.dirname(f))
        if (run, nom) in vus:                 # meme run copie a deux endroits
            continue
        vus.add((run, nom))
        try:
            txt = ANSI.sub("", open(f, "rb").read().decode("utf-8", "replace"))
        except OSError:
            continue
        for l in txt.splitlines():
            l = re.sub(r"\s+", " ", l.strip())
            if l.startswith("ELEMENT MAX"):
                lignes.append((0, "| %s | échelle | %s |" % (run, l)))
            elif l.startswith("bilan :"):
                lignes.append((2, "| %s | couverture | %s |" % (run, l[8:])))
            elif l.startswith("couverture couche 1"):
                lignes.append((1, "| %s | mode, date | %s |" % (run, l.split("—", 1)[-1].strip())))
            else:
                m = re.match(r"(\d+) (\S+) (ECHEC|SAUTE) ?(.*)", l)
                if m:
                    lignes.append((3, "| %s | barreau %s %s | %s %s |" % (run, m.group(1), m.group(2), m.group(3), m.group(4))))
    return [l for _, l in sorted(lignes, key=lambda x: x[0])]


MERMAID_OUVRE = "```{mermaid}" if FORMAT == "qmd" else "```mermaid"


def rendre_mmd(lignes):
    return "%s\n%s\n```" % (MERMAID_OUVRE, "\n".join(lignes))


def rendre_md(lignes):
    out, dans_bloc, cloture = [], False, ""
    i = 0
    if lignes and lignes[0].strip() == "---":           # front matter YAML : montre en bloc, pas interprete
        j = next((k for k in range(1, len(lignes)) if lignes[k].strip() in ("---", "...")), None)
        if j:
            out.append("```yaml"); out.extend(lignes[1:j]); out.append("```")
            i = j + 1
    while i < len(lignes):
        l = lignes[i]; i += 1
        m = re.match(r"^(\s*)(`{3,}|~{3,})(.*)$", l)
        if m and not dans_bloc:
            dans_bloc, cloture = True, m.group(2)
            info = m.group(3).strip()
            if info.startswith("{mermaid}") or info.startswith("mermaid"):
                l = m.group(1) + MERMAID_OUVRE
            elif info.startswith("{"):                     # ```{r ...} ou {.bash filename=...} : langage seul,
                l = m.group(1) + m.group(2) + info.strip("{}").split()[0].split(",")[0].lstrip(".")  # ni execution ni flottant
            out.append(l); continue
        if m and dans_bloc and m.group(2)[0] == cloture[0] and len(m.group(2)) >= len(cloture) and not m.group(3).strip():
            dans_bloc = False; out.append(l); continue
        if not dans_bloc:
            h = re.match(r"^(#{1,6})\s", l)
            if h:
                l = "#" * min(6, len(h.group(1)) + 3) + l[len(h.group(1)):]
            elif l.strip() in ("---", "..."):             # pas de bloc YAML ni de regle au milieu du dossier
                l = "* * *"
        out.append(l)
    if dans_bloc:
        out.append(cloture)
    return "\n".join(out)


def main():
    dossiers = sys.argv[1:] or dossiers_par_defaut()
    vus, sections, table = {}, [], []
    total_in = total_out = 0
    # Ordre : les resultats des tests (.txt .md .mmd : verdicts, couverture, rapports, grafcets)
    # d'abord, les fichiers du banc (sources, scripts, configs...) ensuite, les .log en dernier
    CATEGORIES = (("Verdict et couverture", ()), ("Resultats des tests", ("txt", "md", "mmd", "tsv", "csv")),
                  ("Fichiers", None), ("Logs", ("log",)))          # Fichiers : tout le reste
    EN_TETE = ("verdict.txt", "couverture.txt")     # tout en haut, dans cet ordre
    tous = []
    for d in dossiers:
        if not os.path.isdir(d):
            table.append("| (absent) %s | | | | |" % d)
            continue
        tous.extend(fichiers(d))
    def rang(f):
        if os.path.basename(f) in EN_TETE:
            return 0
        e = extension(os.path.basename(f))
        for i, (_, exts) in enumerate(CATEGORIES):
            if exts and e in exts:
                return i
        return 2                                  # Fichiers
    categorie_courante = None
    def cle(f):
        r = rang(f)
        return (r, EN_TETE.index(os.path.basename(f)) if r == 0 else 0, tous.index(f))
    for f in sorted(tous, key=cle):
        if rang(f) != categorie_courante:
            categorie_courante = rang(f)
            nom = CATEGORIES[categorie_courante][0] if categorie_courante < len(CATEGORIES) else "Autres"
            sections.append("## %s\n" % nom)
        if True:
            try:
                brut = open(f, "rb").read()
            except OSError as e:
                table.append("| %s | | | | illisible : %s |" % (f, e))
                continue
            texte = ANSI.sub("", TELNET.sub(b"", brut).decode("utf-8", "replace")).replace("\r", "")
            texte = CONTROLE.sub("", texte)
            lignes = texte.split("\n")
            if lignes and lignes[-1] == "":
                lignes.pop()
            # lignes demesurees (blob base64, minifie...) : coupees en morceaux de LIGNE_MAX
            # termines par ↩ ; sinon xelatex mesure la ligne entiere et plante (Dimension too large)
            lignes = [m for l in lignes for m in couper(l)]
            h = hashlib.sha1(texte.encode()).hexdigest()
            total_in += len(brut)
            if h in vus:
                sections.append("### %s\n\nidentique à %s\n" % (f, vus[h]))
                continue
            vus[h] = f
            ext = extension(os.path.basename(f))
            if ext in ("md", "qmd", "mmd"):
                # Rendu, pas cite : les .mmd deviennent des diagrammes Mermaid, les .md
                # sont inclus tels quels (titres retrogrades sous le titre du fichier,
                # blocs mermaid rendus, blocs {r}/{python} neutralises). Pas de compactage.
                total_out += len(texte) + 1
                sections.append("### %s\n\n%d octets, %d lignes\n\n%s\n"
                                % (f, len(brut), len(lignes), rendre_md(lignes) if ext in ("md", "qmd") else rendre_mmd(lignes)))
                continue
            compact, groupes = compacter(lignes)
            total_out += sum(len(l) + 1 for l in compact)
            note = "%d groupes compactés" % groupes if groupes else ""
            # cloture plus longue que toute suite de ` du contenu : un ``` dans un
            # .py ou un .md ne referme plus le bloc (pandoc lisait alors la suite
            # comme du Markdown : « Could not fetch resource »)
            plus_long = max((len(m) for m in re.findall(r"`+", "\n".join(compact))), default=0)
            cloture = "`" * max(3, plus_long + 1)
            sections.append("### %s\n\n%d octets, %d lignes → %d lignes%s\n\n%s%s\n%s\n%s\n"
                            % (f, len(brut), len(lignes), len(compact), (" (%s)" % note) if note else "",
                               cloture, langage(f), "\n".join(compact), cloture))
    runs = sorted({os.path.basename(os.path.dirname(f)) for f in tous if os.path.basename(f) == "verdict.txt"})
    with open(SORTIE, "w") as o:
        o.write("---\n")
        o.write("title: \"Banc GSM émulé — dossier de run\"\n")
        o.write("subtitle: \"%s\"\n" % (", ".join(runs) if runs else ", ".join(dossiers)))
        o.write("author: \"%s\"\n" % AUTEUR)
        o.write("date: \"%s\"\n" % time.strftime("%Y-%m-%d %H:%M"))
        o.write("lang: fr\n")
        if FORMAT == "qmd":
            o.write("engine: markdown\n")
            o.write("code-annotations: false\n")  # un "<100>" dans un commentaire n'est pas une annotation     # pandoc seul : knitr voyait des ```{r} dans les rapports inclus et s'arretait
        if FORMAT == "qmd":
            o.write("format:\n  html:\n    toc: true\n    toc-depth: 3\n    toc-location: left\n"
                    "    number-sections: true\n    embed-resources: true\n    theme: cosmo\n"
                    "    code-overflow: wrap\n    fontsize: 0.9em\n")
            o.write("  pdf:\n    toc: true\n    toc-depth: 3\n    number-sections: true\n"
                    "    shift-heading-level-by: -1\n"      # ## Synthese = section 1, pas 0.1
                    "    papersize: a4\n    geometry: margin=2cm\n    fontsize: 10pt\n"
                    "    monofont: DejaVu Sans Mono\n"      # trace de boites, ✓ ✗ ⟨⟩ ⚠ absents de Latin Modern Mono
                    "    include-in-header:\n      text: |\n" + PDF_PREAMBULE)
        o.write("---\n\n")
        o.write("## Synthèse\n\n")
        o.write("| run | élément | valeur |\n|---|---|---|\n")
        lignes_syn = synthese(tous)
        o.write("\n".join(lignes_syn) + "\n\n" if lignes_syn else "| (pas de verdict.txt) | | |\n\n")
        o.write("| dossier de run | contenu | |\n|---|---|---|\n")
        o.write("| Verdict et couverture | échelle des barreaux et tableau de couverture couche 1 | |\n")
        o.write("| Résultats des tests | captures VTY, diagnostics, rapports pytest, grafcets (.txt .md .mmd) | |\n")
        o.write("| Fichiers | sources, scripts, configs et docs du banc (tout fichier texte) | |\n")
        o.write("| Logs | journaux (.log), en dernier | |\n\n")
        o.write("::: {.callout-note collapse=\"true\"}\n## Méthode\n\n" if FORMAT == "qmd" else "### Méthode\n\n")
        o.write("Dossiers : %s. Extensions : %s. Entrée %d Ko, sortie %d Ko.\n\n"
                % (", ".join(dossiers), " ".join(EXT) if EXT else "tous les fichiers texte (hors .git, caches, "
                   "binaires, sauvegardes, LICENSE et sorties précédentes)", total_in // 1024, total_out // 1024))
        o.write("Compactage sans perte : fichiers identiques cités une fois ; lignes consécutives identiques "
                "« ×N » ; lignes ne différant que par des nombres : gabarit avec ⟨k⟩ puis la liste ordonnée "
                "des valeurs (k-uplets), chaque ligne se reconstruit en remettant les valeurs dans l'ordre. "
                "Seuls les codes couleur, la négociation telnet des captures VTY et les caractères de commande "
                "sont retirés ; les lignes de plus de %d caractères sont coupées en morceaux terminés par ↩. Les .md sont inclus tels quels (titres rétrogradés) et les .mmd rendus en "
                "diagrammes Mermaid, sans compactage.\n" % LIGNE_MAX)
        o.write(":::\n\n" if FORMAT == "qmd" else "\n")
        for t in table:                      # ne reste que les dossiers absents / fichiers illisibles
            o.write(t.strip("| ").split(" |")[0] + "\n")
        o.write("\n")
        o.write("\n".join(sections))
    print("%s : %d fichiers (%d uniques), %d Ko -> %d Ko" % (SORTIE, len(tous), len(vus), total_in // 1024,
                                                            os.path.getsize(SORTIE) // 1024))


if __name__ == "__main__":
    main()

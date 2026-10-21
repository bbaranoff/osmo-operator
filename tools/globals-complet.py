#!/usr/bin/env python3
# [2026-10-21] Les PATRONS de la page web (web/, servie par tools/osmo-reglages.py) :
#
#   globals.conf.example          les reglages reseau de globals.conf + les variables du LANCEUR
#                                 (start.sh, startup_scripts/*.sh) : globales a la chaine
#   instances/instance.env.example  les variables du BANC DSP (c54x_exe/run.sh) : UNE VALEUR PAR INSTANCE
#                                 Calypso (1 = BTS/TRX ou MS sur le pont, 2 = MS QEMU par l'air, 3 = TRX TS1),
#                                 ecrites par la page dans instances/instance-N.env et lues par run.sh
#
#   python3 tools/globals-complet.py            # (re)genere les deux patrons
#   python3 tools/globals-complet.py --voir     # les affiche sans rien ecrire
#
# Chaque variable porte son defaut en commentaire (fichier:ligne) et, quand les scripts la comparent a des
# valeurs fixes (0/1, dsp/grgsm, ...), une ligne « choix : a | b | c » : la page en fait un menu deroulant.
# Valeur VIDE = defaut du script. globals.conf est source avec `set -a` apres le traitement des options
# (03-affichage.sh) : une variable deja posee et non vide (ligne de commande) garde sa valeur ; la page ecrit
# commentees les variables du lanceur laissees vides (exportees vides, elles cassaient le lancement).
#
# Exclus : l'etat interne du lanceur (C_*, *_CHOISI, chemins calcules), les variables lues sans deux-points
# (${VAR-x} : vide et absent different). Pour run.sh, seules les variables qu'il renormalise lui-meme
# (VAR="${VAR:-x}", export compris) : une valeur vide n'atteint jamais le C.

import argparse, glob, os, re, shutil, time

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GLOBALS = os.path.join(RACINE, "globals.conf")
EXEMPLE = GLOBALS + ".example"
INSTANCES = os.path.join(RACINE, "instances")
EXEMPLE_INST = os.path.join(INSTANCES, "instance.env.example")
RUN_DSP = "/opt/GSM/c54x_exe/run.sh"
DEBUT = "# >>> VARIABLES DU LANCEUR : bloc genere par tools/globals-complet.py (ne pas editer les marqueurs) >>>"
FIN = "# <<< FIN DES VARIABLES DU LANCEUR <<<"

INTERNES = {"RUNTIME_ENV", "OQC_ROOT", "NITB_TREE", "RAND", "NODE_ID_SRC", "GEN_CONF_OUT", "SAP_FILE",
            "SOFTSIM_KI", "HUB_IP", "NO_COLOR", "RUN_SH", "HERE", "RUNDIR", "INSTANCE", "CALYPSO_NS"}
# choix a la main (les scripts ne les comparent pas tous a des valeurs fixes)
CHOIX = {
    "BAND": "GSM900 | DCS1800 | PCS1900 | GSM850",
    "ENCRYPTION": "a5 0 | a5 1 | a5 3 | a5 0 1 | a5 0 1 3",
    "SIM_ALGO": "comp128 | comp128v2 | comp128v3 | xor | milenage",
    "CALYPSO_PROFILE": "faketrx-qemu | faketrx | qemu | noproc",
    "MODE": "dsp | grgsm",
    "OSMO_TRX_TS": "1 | 2 | 2/1",
    "SAP_TYPE": "auto | pcsc | softsim",
}
DEFAUT = re.compile(r'\$\{([A-Z][A-Z0-9_]*):([-=])')
RENORMALISE = re.compile(r'^\s*(?:export\s+)?([A-Z][A-Z0-9_]*)="?\$\{\1:-')


def defaut_apres(ligne, i):
    """Le texte du defaut d'un ${VAR:-...} a partir de l'indice i, accolades equilibrees."""
    prof, j = 1, i
    while j < len(ligne) and prof:
        if ligne[j] == "{":
            prof += 1
        elif ligne[j] == "}":
            prof -= 1
        j += 1
    return ligne[i:j - 1]


def extraire(fichier, seulement_renormalisees=False):
    vus = {}
    for n, l in enumerate(open(fichier, encoding="utf-8", errors="replace").read().split("\n"), 1):
        if l.lstrip().startswith("#"):
            continue
        m_r = RENORMALISE.match(l)
        if seulement_renormalisees and not m_r:
            continue
        for m in DEFAUT.finditer(l):
            v = m.group(1)
            if seulement_renormalisees and v != m_r.group(1):
                continue
            if v not in vus:
                vus[v] = (defaut_apres(l, m.end()), n)
    return vus


def sans_deux_points(fichiers):
    r = set()
    for f in fichiers:
        r |= set(re.findall(r'\$\{([A-Z][A-Z0-9_]*)[-=]', open(f, encoding="utf-8", errors="replace").read()))
    return r


def choix_auto(textes):
    """Les valeurs fixes auxquelles les scripts comparent chaque variable : [ "$VAR" = 1 ], != "off"..."""
    comp = {}
    pat = re.compile(r'\$\{?([A-Z][A-Z0-9_]*)(?::-[^}]*)?\}?"?\s*(?:=|==|!=)\s*"?([A-Za-z0-9_./-]+)"?')
    for t in textes:
        for l in t.split("\n"):
            if l.lstrip().startswith("#"):
                continue
            for m in pat.finditer(l):
                comp.setdefault(m.group(1), []).append(m.group(2))
    return comp


def choix_de(var, defaut, comp):
    if var in CHOIX:
        return CHOIX[var]
    vals = []
    for v in comp.get(var, []):
        if v not in vals:
            vals.append(v)
    if defaut in ("0", "1") and all(v in ("0", "1") for v in vals):
        return "0 | 1"
    if len(vals) >= 2 and all(len(v) <= 24 for v in vals):
        if defaut and defaut not in vals and re.match(r'^[A-Za-z0-9_./-]+$', defaut):
            vals.insert(0, defaut)
        return " | ".join(vals)
    return ""


def titre(nom):
    return "# ── %s %s" % (nom, "─" * max(3, 58 - len(nom)))


def bloc_variables(sources, exclues, comp, ligne_var):
    deja, lignes, n = set(), [], 0
    for f, renorm in sources:
        vars_f = extraire(f, renorm)
        garde = [(v, d, l) for v, (d, l) in vars_f.items()
                 if v not in exclues and v not in deja and not v.startswith("C_") and not v.endswith("_CHOISI")]
        if not garde:
            continue
        nom = os.path.relpath(f, RACINE) if f.startswith(RACINE) else f
        lignes += ["", titre(nom), ""]
        for v, d, l in garde:
            deja.add(v)
            d = d.replace("\n", " ")
            lignes.append("# defaut : %s   (%s:%d)" % (d if d else "(vide)", os.path.basename(f), l))
            c = choix_de(v, d, comp)
            if c:
                lignes.append("# choix : %s" % c)
            lignes.append(ligne_var(v))
            n += 1
    return lignes, n


def tete_globals():
    texte = open(GLOBALS, encoding="utf-8").read()
    if DEBUT in texte and FIN in texte:
        tete, reste = texte.split(DEBUT, 1)
        queue = reste.split(FIN, 1)[1]
    else:
        tete, queue = texte, ""
    # le patron porte les reglages reseau VIDES de valeur ? Non : on garde les lignes telles quelles mais on
    # ajoute les choix a la main ; la page lit les valeurs dans globals.conf, pas ici.
    sortie = []
    for l in tete.rstrip("\n").split("\n"):
        m = re.match(r"^([A-Z_][A-Z0-9_]*)=", l)
        if m and m.group(1) in CHOIX and (not sortie or not sortie[-1].startswith("# choix :")):
            sortie.append("# choix : " + CHOIX[m.group(1)])
        sortie.append(l)
    declarees = set(re.findall(r"^([A-Z_][A-Z0-9_]*)=", tete + queue, re.M))
    return "\n".join(sortie), queue.strip("\n"), declarees


def generer():
    modules = [os.path.join(RACINE, "start.sh")] + sorted(glob.glob(os.path.join(RACINE, "startup_scripts", "*.sh")))
    textes = [open(f, encoding="utf-8", errors="replace").read() for f in modules + [RUN_DSP] if os.path.exists(f)]
    comp = choix_auto(textes)
    tete, queue, declarees = tete_globals()
    exclues = sans_deux_points(modules + [RUN_DSP]) | INTERNES | declarees
    lignes, n = bloc_variables([(m, False) for m in modules], exclues, comp, lambda v: '%s=""' % v)
    corps = [DEBUT, "#", "#  Valeur VIDE = defaut du script (en commentaire). Regenerer : python3 tools/globals-complet.py", "#"] + lignes + ["", FIN]
    globals_txt = tete + "\n\n" + "\n".join(corps) + ("\n\n" + queue if queue else "") + "\n"

    inst_tete = [
        "# instances/instance.env.example — patron des reglages PAR INSTANCE Calypso (c54x_exe/run.sh).",
        "# Genere par tools/globals-complet.py ; la page web (tools/osmo-reglages.py) ecrit instance-N.env :",
        "#   1 = la radio de la BTS (TRX Calypso, --bts) ou le mobile sur le pont (--bts-classique)",
        "#   2 = le mobile QEMU par l air (--bts --ms, --ms-magnetite)",
        "#   3 = le 2e TRX Calypso, TS1 (--ts 2)",
        "# run.sh lit instances/instance-$INSTANCE.env au demarrage, sous la forme : \"${VAR:=valeur}\" :",
        "# l environnement (start-native.sh, ligne de commande) garde la priorite, la valeur du fichier vient",
        "# ensuite, puis le defaut de run.sh. Valeur VIDE = defaut.",
    ]
    lignes_i, n_i = bloc_variables([(RUN_DSP, True)], sans_deux_points([RUN_DSP]) | INTERNES, comp, lambda v: '%s=""' % v)
    inst_txt = "\n".join(inst_tete + lignes_i) + "\n"
    return globals_txt, n, inst_txt, n_i


if __name__ == "__main__":
    a = argparse.ArgumentParser(description="patrons de la page de reglages")
    a.add_argument("--voir", action="store_true")
    o = a.parse_args()
    g, n, i, n_i = generer()
    if o.voir:
        print(g)
        print(i)
    else:
        for chemin, texte in ((EXEMPLE, g), (EXEMPLE_INST, i)):
            os.makedirs(os.path.dirname(chemin), exist_ok=True)
            if os.path.exists(chemin):
                shutil.copy2(chemin, chemin + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
            open(chemin, "w", encoding="utf-8").write(texte)
        print("globals.conf.example : %d variables du lanceur ; instances/instance.env.example : %d variables de run.sh" % (n, n_i))

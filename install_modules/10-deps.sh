# 10-deps - paquets systeme.
# La liste fait autorite dans le Dockerfile : on l'en EXTRAIT au lieu de la
# recopier, pour que les deux ne divergent jamais.
INST_REGISTER deps "Dependances systeme (apt)"
INST_DEPS[deps]="prereqs"

# [2026-08-25] L'extraction reconnaissait "RUN apt-get update && apt-get
# install" EN DUR. Le Dockerfile installe desormais via apt-fast : le motif ne
# capturait plus que le bloc d'amorcage (aria2, curl, et les bouts de la
# commande qui installe apt-fast lui-meme), et l'installation native repartait
# avec 29 jetons de charabia au lieu des paquets. Elle echouait sur des noms
# comme "&&" ou une URL, sans que rien ne designe le Dockerfile comme cause.
#
# Deux durcissements plutot qu'un simple elargissement du motif :
#   1. apt-get ET apt-fast sont acceptes, dans n'importe quel ordre update/install ;
#   2. on ne garde que ce qui RESSEMBLE a un nom de paquet. Un bloc apt peut
#      contenir des `&&`, des URL, des accolades - les laisser passer, c'est
#      transformer une erreur de format en erreur d'apt, illisible.
# Le filtre est la vraie protection : il survit au prochain changement de forme.
_deps_list() {
    # Un paquet, c'est ce qui suit "install -y --no-install-recommends" et
    # PRECEDE le premier operateur shell. Filtrer sur la forme des mots ne
    # suffit pas : le bloc d'amorcage contient "chmod", "printf", "rm",
    # qui ressemblent tous a des noms de paquets. On coupe donc a `&&`, `||`,
    # `{` ou une URL, et on ne garde que ce qu'il y a avant.
    awk '
        /^RUN apt-(get|fast) update && apt-(get|fast) install/ {
            inblk = 1
            line = $0
            sub(/^RUN.*--no-install-recommends/, "", line)
            emit(line)
            next
        }
        inblk { emit($0) }

        function emit(l,   n, a, i, cont) {
            # Le commentaire en PREMIER. Les lignes "# ..." au milieu de la
            # liste nont pas de barre de continuation : Docker les retire avant
            # le shell. Les traiter comme une fin de bloc coupait la liste au
            # premier commentaire - soit trois paquets sur soixante-dix.
            # (Pas dapostrophe dans ce bloc : il vit entre quotes simples.)
            sub(/#.*/, "", l)
            if (l ~ /^[ \t]*$/) return          # commentaire pur : transparent

            cont = (l ~ /\\[ \t]*$/)
            if (l ~ /&&|\|\||[{}]|https?:/) {   # on sort de la liste de paquets
                sub(/(&&|\|\||\{).*/, "", l)
                inblk = 0
            } else if (!cont) {
                inblk = 0                        # derniere ligne du bloc
            }
            sub(/\\[ \t]*$/, "", l)
            n = split(l, a, /[ \t]+/)
            for (i = 1; i <= n; i++)
                if (a[i] ~ /^[a-z0-9][a-z0-9.+*-]*$/) print a[i]
        }
    ' "$INST_TREE/Dockerfile" 2>/dev/null | sort -u | tr '\n' ' '
}

inst_deps_check() {
    have_file "$INST_TREE/Dockerfile" || { inst_fail "Dockerfile introuvable - c'est lui qui porte la liste des paquets"; return $INST_RC_FAIL; }
    inst_ok
}
inst_deps_done() {
    local p; for p in build-essential libtalloc-dev libsctp-dev; do have_pkg "$p" || return 1; done
    return 0
}
inst_deps_run() {
    local pkgs; pkgs="$(_deps_list)"
    [ -z "${pkgs// }" ] && { inst_fail "liste de paquets vide - le format du Dockerfile a change"; return $INST_RC_FAIL; }
    inst_say "paquets : $(echo $pkgs | wc -w)"
    apt-get update -qq && apt-get install -y --no-install-recommends $pkgs
}
inst_deps_verify() {
    local missing="" p
    for p in build-essential libtalloc-dev libsctp-dev libdbi-dev; do have_pkg "$p" || missing="$missing $p"; done
    [ -n "$missing" ] && { inst_fail "paquets absents apres installation :$missing"; return $INST_RC_FAIL; }
    inst_ok
}

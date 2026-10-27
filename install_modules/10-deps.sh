# 10-deps - system packages (apt).
# The package list is authoritative in the Dockerfile: it is EXTRACTED from it
# rather than copied, so the two can never diverge.
INST_REGISTER deps "Dependances systeme (apt)"
INST_DEPS[deps]="prereqs"

# Extract the package names from the Dockerfile's apt-get/apt-fast install
# block (either tool, any update/install order, optional --mount=... on the
# RUN line). Only tokens that LOOK like package names are kept, and the list
# is cut at the first shell operator (&&, ||, {) or URL: the bootstrap block
# contains commands (chmod, printf, rm) that would otherwise pass for
# packages and turn a format error into an unreadable apt error.
_deps_list() {
    awk '
        /^RUN( --mount=[^ ]+)? *\\?$/ { pending = 1; next }
        /^RUN( --mount=[^ ]+)? +apt-(get|fast) update && apt-(get|fast) install/ || (pending && /^ *apt-(get|fast) update && apt-(get|fast) install/) {
            pending = 0
            inblk = 1
            line = $0
            # The RUN may carry a --mount=... (BuildKit apt cache) and continue
            # on the next line: strip everything before the end of the apt
            # command, whether the line starts with RUN or not.
            sub(/^.*--no-install-recommends/, "", line)
            emit(line)
            next
        }
        pending && !/^ *apt-(get|fast) update/ { pending = 0 }
        inblk { emit($0) }

        function emit(l,   n, a, i, cont) {
            # Strip the comment FIRST: "# ..." lines inside the list carry no
            # continuation backslash (Docker removes them before the shell),
            # so they must not be taken as the end of the block.
            # (No apostrophe in this block: it lives between single quotes.)
            sub(/#.*/, "", l)
            if (l ~ /^[ \t]*$/) return          # pure comment: transparent

            cont = (l ~ /\\[ \t]*$/)
            if (l ~ /&&|\|\||[{}]|https?:/) {   # end of the package list
                sub(/(&&|\|\||\{).*/, "", l)
                inblk = 0
            } else if (!cont) {
                inblk = 0                        # last line of the block
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
# "Already installed" is judged on the WHOLE list, not on a few witness
# packages: a partially equipped system (binaries without the -dev packages)
# must not skip this step. A pattern (asterisk-moh*) counts as present if one
# of the packages it matches is installed.
_deps_missing() {
    local p
    for p in $(_deps_list); do
        dpkg-query -W -f='${db:Status-Status}\n' "$p" 2>/dev/null | grep -qx installed || printf '%s\n' "$p"
    done
}
inst_deps_done() {
    [ -n "$(_deps_list)" ] && [ -z "$(_deps_missing)" ]
}
inst_deps_run() {
    local pkgs; pkgs="$(_deps_list)"
    [ -z "${pkgs// }" ] && { inst_fail "liste de paquets vide - le format du Dockerfile a change"; return $INST_RC_FAIL; }
    inst_say "paquets : $(echo $pkgs | wc -w), dont manquants : $(_deps_missing | wc -l)"
    # The FULL list, not only the missing packages: apt-get install is
    # idempotent, and a pattern like asterisk-moh* is only resolved by apt.
    apt-get update -qq && apt-get install -y --no-install-recommends $pkgs
}
inst_deps_verify() {
    local missing; missing="$(_deps_missing | tr '\n' ' ')"
    [ -n "${missing// }" ] && { inst_fail "paquets absents apres installation : $missing"; return $INST_RC_FAIL; }
    inst_ok
}

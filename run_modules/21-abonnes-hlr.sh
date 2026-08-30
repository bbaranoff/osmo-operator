# =============================================================================
#  21-abonnes-hlr - provisionnement des abonnes dans le HLR
# =============================================================================
#  ROLE      cree les IMSI/MSISDN/Ki que les mobiles presenteront. Ce n'est pas
#            un service mais une ETAPE du coeur : sans elle, le rattachement est
#            rejete ("IMSI unknown in HLR") et l'on croit a une panne radio.
#            Reprend la derivation exacte de feed_hlr (start-direct.sh) :
#              IMSI   = MCC MNC %04d(op) %06d(ms)
#              MSISDN = <noeud>00<op><ms>       (100101, 100102, 100201...)
#              Ki     = 00112233445566778899aabbccdd %02x(ms) %02x(op)
#  PREREQUIS HLR pret (VTY joignable) ; socat ou telnet pour parler au VTY.
#  SUCCES    le DERNIER abonne de la serie est reellement relu depuis le HLR -
#            par la base sqlite en lecture seule si elle est accessible, sinon
#            par "subscriber imsi <imsi> show" sur le VTY. Ecrire n'est pas
#            reussir : la barriere relit.
#  JOURNAL   $LOGDIR/mod/abonnes-hlr.log
#
#  IDEMPOTENT : "subscriber create" sur un IMSI existant est sans effet
#  destructeur ; mod_*_status saute l'etape si le dernier abonne est deja la.
#  L'arret ne supprime AUCUN abonne (ce serait detruire l'etat du reseau).
# -----------------------------------------------------------------------------
: "${MODDIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$MODDIR/_lib/core.sh"

MOD_REGISTER abonnes-hlr "Coeur - abonnes provisionnes dans le HLR"
MOD_REQUIRED[abonnes-hlr]=0
MOD_DEPS[abonnes-hlr]="hlr"
MOD_PROFILES[abonnes-hlr]="calypso faketrx hybrid core"
MOD_TIMEOUT[abonnes-hlr]=30
MOD_ENABLED_IF[abonnes-hlr]='[ "${NO_OSMO_START:-0}" != 1 ]'

: "${HLR_VTY_PORT:=4258}"
: "${HLR_DB:=/var/lib/osmocom/hlr.db}"
: "${OPERATOR_ID:=1}"
: "${N_MS:=1}"

_abo_mcc() { printf '%s\n' "${MCC:-$(core_cfg_field "$(core_cfg osmo-msc)" '^[[:space:]]*network country code[[:space:]]' 4 001)}"; }
_abo_mnc() { printf '%s\n' "${MNC:-$(core_cfg_field "$(core_cfg osmo-msc)" '^[[:space:]]*mobile network code[[:space:]]' 4 01)}"; }

_abo_imsi() { printf '%s%s%04d%06d\n' "$(_abo_mcc)" "$(_abo_mnc)" "$OPERATOR_ID" "$1"; }
_abo_ki()   { printf '00112233445566778899aabbccdd%02x%02x\n' "$1" "$OPERATOR_ID"; }

# ── LE NOEUD N'ENTRE QUE DANS LE MSISDN ─────────────────────────────────────
# IMSI et Ki gardent EXACTEMENT leur derivation : ils sont recalcules a
# l'identique par start-direct.sh (ms_imsi/ms_ki), start.sh et le gabarit de
# mobile.cfg. Y glisser le noeud ferait diverger le Ki du mobile de celui du
# HLR, et l'authentification echouerait sur un Kc different des deux cotes -
# sans autre trace qu'un CIPHER MODE rejete.
# Le MSISDN, lui, ne sert a aucun calcul : c'est une adresse, et elle doit dire
# de quel noeud elle vient, sinon deux noeuds revendiquent les memes numeros.
_abo_node() {
    local n="${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}"
    [ -n "$n" ] || n="$(sed -n 's/^PLAN_NODE=//p' "${OSMOCOM_CFG:-/etc/osmocom}/radio-plan.env" 2>/dev/null | tail -1)"
    case "$n" in [1-9]) ;; *) n=1 ;; esac
    printf '%s' "$n"
}
_abo_msisdn() { echo $(( $(_abo_node) * 100000 + OPERATOR_ID * 100 + $1 )); }

# Relecture de l'abonne : base sqlite en lecture seule d'abord (fiable et
# instantanee), VTY en repli si sqlite est indisponible.
_abo_present() {
    local imsi="$1" n=""
    if [ -r "$HLR_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
        n="$(sqlite3 -readonly "$HLR_DB" "select count(*) from subscriber where imsi='$imsi';" 2>/dev/null)"
        case "$n" in ''|*[!0-9]*) n="" ;; esac
        if [ -n "$n" ]; then [ "$n" -ge 1 ]; return $?; fi
    fi
    core_vty_ask "$HLR_VTY_PORT" "enable" "subscriber imsi $imsi show" 2>/dev/null | grep -q "IMSI: $imsi"
}

mod_abonnes_hlr_check() {
    case "$N_MS" in ''|*[!0-9]*) mod_fail "N_MS invalide : "$N_MS""; return $MOD_RC_FAIL ;; esac
    [ "$N_MS" -ge 1 ] || { mod_skip "N_MS=$N_MS : aucun abonne a creer"; return $MOD_RC_SKIP; }
    core_vty_listen "$HLR_VTY_PORT" || {
        mod_hint "le HLR doit etre pret : ./run.sh --only hlr"
        mod_fail "VTY HLR ($HLR_VTY_PORT) injoignable"; return $MOD_RC_FAIL; }
    command -v socat >/dev/null 2>&1 || command -v telnet >/dev/null 2>&1 || {
        mod_hint "installez socat (ou telnet) : le provisionnement passe par le VTY"
        mod_fail "ni socat ni telnet - impossible d'ecrire dans le HLR"; return $MOD_RC_FAIL; }
    mod_ok
}

# ── L'ETAT, C'EST L'IMSI *ET* SON MSISDN ────────────────────────────────────
# Ne verifier que la presence de l'IMSI rendait cette etape aveugle a tout
# changement de numerotation : apres un ./start-direct.sh --regen, les configs
# repartent sur <noeud>00<op><ms> pendant que le HLR garde les MSISDN de
# l'ancien plan. L'IMSI, lui, n'a pas bouge - le module se declarait donc
# "deja fait" et ne mettait rien a jour. L'abonne s'attachait (l'IMSI est
# connu) mais restait injoignable : aucun appel, aucun SMS, et rien nulle part
# pour dire que le numero du HLR n'est plus celui du dialplan.
# "subscriber ... update msisdn" est idempotent : relancer ne coute rien.
_abo_msisdn_now() {
    local imsi="$1" v=""
    if [ -r "$HLR_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
        v="$(sqlite3 -readonly "$HLR_DB" "select msisdn from subscriber where imsi='$imsi';" 2>/dev/null)"
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    fi
    core_vty_ask "$HLR_VTY_PORT" "enable" "subscriber imsi $imsi show" 2>/dev/null \
        | sed -n 's/.*MSISDN: *\([0-9][0-9]*\).*/\1/p' | head -1
}

mod_abonnes_hlr_status() {
    local imsi; imsi="$(_abo_imsi "$N_MS")"
    _abo_present "$imsi" || return 1
    [ "$(_abo_msisdn_now "$imsi")" = "$(_abo_msisdn "$N_MS")" ]
}

mod_abonnes_hlr_start() {
    local m cmds=() imsi msisdn
    cmds+=("enable")
    for m in $(seq 1 "$N_MS"); do
        imsi="$(_abo_imsi "$m")"
        msisdn="$(_abo_msisdn "$m")"
        cmds+=("subscriber imsi $imsi create")
        cmds+=("subscriber imsi $imsi update msisdn $msisdn")
        cmds+=("subscriber imsi $imsi update aud2g comp128v1 ki $(_abo_ki "$m")")
    done
    # "exit" et non "end" : au noeud enable, end n'existe pas - le VTY
    # repondait "% Unknown command." et surtout laissait la session OUVERTE.
    # telnet, contrairement a socat, ne rend pas la main sur EOF de stdin : il
    # restait pendu jusqu'au timeout, qui le tuait avec un code non nul. exit
    # ferme la session cote HLR, le client sort proprement.
    cmds+=("exit")
    mod_say "provisionnement de $N_MS abonne(s), noeud $(_abo_node), operateur $OPERATOR_ID, PLMN $(_abo_mcc)-$(_abo_mnc) - MSISDN $(_abo_msisdn 1)..$(_abo_msisdn "$N_MS")"

    # On juge le dialogue sur ce qu'il a RENDU, pas sur le code de sortie du
    # transport : selon la variante (socat, telnet netkit, busybox) celui-ci
    # vaut 0, 1 ou 124 pour un meme echange reussi. C'est ce qui faisait
    # echouer l'etape alors que les abonnes etaient bel et bien crees.
    # Doctrine de 31-hlr-feed : "ecrire n'est pas reussir" - le verdict
    # appartient a la barriere mod_abonnes_hlr_wait, qui RELIT l'abonne.
    local out
    out="$(core_vty_ask "$HLR_VTY_PORT" "${cmds[@]}" 2>/dev/null)" || true
    printf '%s\n' "$out"        # le dialogue reste trace dans le journal
    if [ -z "${out//[[:space:]]/}" ]; then
        mod_hint "verifiez le VTY : socat STDIO TCP:127.0.0.1:$HLR_VTY_PORT,crlf"
        mod_fail "le dialogue VTY avec le HLR n'a rien retourne"; return $MOD_RC_FAIL
    fi
    case "$out" in
        *"% Unknown command"*|*"% Command incomplete"*)
            mod_hint "commande refusee par le VTY - voir le journal ci-dessus" ;;
    esac
    mod_ok
}

# BARRIERE - le VTY accepte des commandes invalides sans broncher : la seule
# preuve est la relecture de l'abonne cree en dernier.
mod_abonnes_hlr_wait() {
    local imsi; imsi="$(_abo_imsi "$N_MS")"
    if ! wait_until "${MOD_TIMEOUT[abonnes-hlr]}" "abonne $imsi present dans le HLR" _abo_present "$imsi"; then
        mod_hint "essayez a la main : subscriber imsi $imsi show (VTY $HLR_VTY_PORT) ; base = $HLR_DB"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

# Aucun arret : les abonnes sont de l'etat persistant, pas un processus.
mod_abonnes_hlr_stop() { return 0; }

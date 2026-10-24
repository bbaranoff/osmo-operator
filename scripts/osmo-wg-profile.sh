# osmo-wg-profile.sh - « wg 10.99.0.N » pour monter le tunnel WAN (a sourcer : /etc/profile.d/97-osmo-wg.sh)
# [2026-10-24] Le plan WireGuard du banc (wiki/WAN.md) : 10.99.0.1 le hub, 10.99.0.N les noeuds.
#   wg 1                                 ce noeud devient le hub (10.99.0.1)
#   wg N HUB_IP[:PORT] HUB_PUB           ce noeud devient 10.99.0.N et rejoint le hub
#   wg peer CLE_PUBLIQUE N               (sur le hub) accepte un noeud
#   wg up / wg down / wg status / wg pub le tunnel deja pose
# N ou 10.99.0.N, au choix.
# Ces formes vont a tools/osmo-wg.sh (en root, par sudo) ; tout le reste (wg show, wg genkey,
# wg set...) va au vrai wg, inchange. Une fonction, pas un lien dans le PATH : un « wg » dans
# /usr/local/bin masquerait /usr/bin/wg pour les scripts.
wg() {
    case "${1:-}" in
        10.99.0.*|peer|up|down|status|pub|[1-9]|[1-9][0-9]|[12][0-9][0-9]) /opt/GSM/osmo-operator/tools/osmo-wg.sh "$@" ;;
        *) command wg "$@" ;;
    esac
}

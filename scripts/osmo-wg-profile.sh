# osmo-wg-profile.sh - « wg 10.99.0.N » to bring up the WAN tunnel (sourced:
# /etc/profile.d/97-osmo-wg.sh)
# The bench WireGuard plan (wiki/WAN.md): 10.99.0.1 is the hub, 10.99.0.N the nodes.
#   wg 1                                 this node becomes the hub (10.99.0.1)
#   wg N HUB_IP[:PORT] HUB_PUB           this node becomes 10.99.0.N and joins the hub
#   wg peer PUBLIC_KEY N                 (on the hub) accept a node
#   wg up / wg down / wg status / wg pub the tunnel already configured
# N or 10.99.0.N, either form.
# These forms go to tools/osmo-wg.sh (as root, through sudo); everything else (wg show,
# wg genkey, wg set...) goes to the real wg, unchanged. A function, not a link in the PATH:
# a « wg » in /usr/local/bin would shadow /usr/bin/wg for scripts.
wg() {
    case "${1:-}" in
        10.99.0.*|peer|up|down|status|pub|[1-9]|[1-9][0-9]|[12][0-9][0-9]) /opt/GSM/osmo-operator/tools/osmo-wg.sh "$@" ;;
        *) command wg "$@" ;;
    esac
}

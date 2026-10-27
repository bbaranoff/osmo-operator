#!/bin/bash
# the mobile VTY port: 4247, or 4347 with --dsp (published by start-native.sh)
BB_VTY="$(tr -dc 0-9 < /run/osmo-banc/ms1-vty 2>/dev/null)"; BB_VTY="${BB_VTY:-4247}"

# Save the current terminal configuration
OLD_SETTINGS=$(stty -g)
# Save the initial colours (if supported)
INITIAL_BG=$(printf '\e]11;?\a')

# "Nord Theme" colour palette
set_kernel_profile() {
    # Change background and text
    echo -ne "\e]11;#2E3440\a" # Fond bleu-gris fonce
    echo -ne "\e]10;#D8DEE9\a" # Texte blanc casse
    clear
}

reset_terminal_profile() {
    # 1. Restore the original colours of the user profile
    echo -ne "\e]110\a" # Reset Foreground
    echo -ne "\e]111\a" # Reset Background
    echo -ne "\e]112\a" # Reset cursor color
    
    # 2. System command to reset the terminal
    tput reset
    tput sgr0
    
    # 3. Restore the stty settings
    stty "$OLD_SETTINGS"
    
    clear
    echo "--- Session SDR terminee, profil restaure ---"
}

# Matching whiptail theme
export NEWT_COLORS='
  root=,rgb:2e/34/40
  window=rgb:d8/de/e9,rgb:3b/42/52
  shadow=,rgb:1a/1c/23
  title=rgb:88/c0/d0,rgb:3b/42/52
  button=rgb:2e/34/40,rgb:81/a1/c1
  actbutton=rgb:d8/de/e9,rgb:5e/81/ac
  listbox=rgb:d8/de/e9,rgb:3b/42/52
  actlistbox=rgb:88/c0/d0,rgb:43/4c/5e
'

set_kernel_profile
trap reset_terminal_profile EXIT

connect_vty() {
    tput cnorm # S'assure que le curseur est visible
    expect ./tools/vty-connect.exp "$1" "$3" "$4"
    [[ $? -ne 0 ]] && { echo -e "\n[!] Service hors ligne."; sleep 1; }
}

# ...

menu_services() {
    local OP=$1
    while true; do
        # Option 7 is the Baseband
        CHOICE=$(whiptail --title " OPERATOR CONTROL : $OP " --menu "" 20 62 9 \
            "1" "MSC (4254)" "2" "BSC (4242)" "3" "HLR (4258)" \
            "4" "MGW (4243)" "5" "GGSN (4260)" "6" "SGSN (4245)" \
            "7" "STP (4239)" "8" "BASEBAND ($BB_VTY)" \
            "T" "TMUX - la pile en direct (session osmo)" \
            "R" "<< BACK" 3>&1 1>&2 2>&3)

        [[ -z "$CHOICE" || "$CHOICE" == "R" ]] && break
        
        case $CHOICE in
            1) connect_vty "$OP" "MSC" 4254 "msc" ;;
            2) connect_vty "$OP" "BSC" 4242 "bsc" ;;
            3) connect_vty "$OP" "HLR" 4258 "hlr" ;;
            4) connect_vty "$OP" "MGW" 4243 "mgw" ;;
            5) connect_vty "$OP" "GGSN" 4260 "gg" ;;
            6) connect_vty "$OP" "SGSN" 4245 "sg" ;;
            7) connect_vty "$OP" "STP" 4239 "stp" ;;
            T|t)
                # The session start-docker.sh opens in each operator container.
                # The launch terminal is taken by osmo-operator-1; this is how
                # the others are reached, without remembering the docker
                # command.
                tput cnorm
                # Several conventions coexist depending on the container:
                #   osmocom on /tmp/osmocom_tmux  the stack started by run.sh
                #   calypso / gapk on the default socket  the QEMU pipeline
                # They are tried in that order rather than imposing one: a
                # session announced but not found ("no sessions") would
                # suggest the stack is dead while it is running.
                _sock=""; _sess=""
                if docker exec "$OP" tmux -S /tmp/osmocom_tmux has-session -t osmocom 2>/dev/null; then
                    _sock="-S /tmp/osmocom_tmux"; _sess="osmocom"
                elif docker exec "$OP" tmux has-session -t calypso 2>/dev/null; then
                    _sess="calypso"
                elif docker exec "$OP" tmux has-session -t osmo 2>/dev/null; then
                    _sess="osmo"
                fi
                if [ -n "$_sess" ]; then
                    echo "  Session ${_sess} - detacher : Ctrl-b puis d"
                    # shellcheck disable=SC2086
                    docker exec -ti "$OP" tmux $_sock attach -t "$_sess"
                else
                    whiptail --msgbox "Pas de session tmux 'osmo' dans $OP.\n\nLe journal reste lisible :\n  docker exec $OP tail -f /var/log/osmocom/run.sh.log" 12 66
                fi
                ;;
            8)
                # Multi-group Baseband handling (127.0.0.1, 127.0.0.2, etc.)
                local GRP_IP
                GRP_IP=$(whiptail --title " BASEBAND GROUP SELECT " --inputbox "Target IP (127.0.0.X) :" 10 40 "127.0.0.1" 3>&1 1>&2 2>&3)
                if [[ -n "$GRP_IP" ]]; then
                    # Pass the group IP to the expect script
                    tput cnorm
                    expect ./tools/vty-connect.exp "$OP" "$BB_VTY" "bb" "$GRP_IP"
                fi
                ;;
        esac
    done
}

# --- MAIN LOOP (guarded) ---
while true; do
    MAIN_TYPE=$(whiptail --title " OSMO-SDR STACK MANAGER " --menu "Select Category :" 15 60 3 \
        "CORE" "Global Infrastructure (Inter-STP)" \
        "OPS"  "Network Operators (MSC/BSC/STP...)" \
        "EXIT" "Quit Manager" 3>&1 1>&2 2>&3)

    [[ -z "$MAIN_TYPE" || "$MAIN_TYPE" == "EXIT" ]] && break

    if [[ "$MAIN_TYPE" == "CORE" ]]; then
        # Check whether the inter-stp is alive
        if docker ps --format '{{.Names}}' | grep -q "osmo-inter-stp"; then
            docker exec -ti osmo-inter-stp telnet 127.0.0.1 4239
        else
            whiptail --msgbox "Erreur : osmo-inter-stp n'est pas lance." 10 50
        fi
    else
        # Get the active operators
        OPS=$(docker ps --format "{{.Names}}" | grep "osmo-operator" | sort)
        
        if [[ -z "$OPS" ]]; then
            whiptail --msgbox "Aucun operateur detecte ! Verifiez start-docker.sh" 10 50
            continue
        fi

        MENU_LIST=()
        while read -r line; do MENU_LIST+=("$line" "Status: Active"); done <<< "$OPS"

        OP_CHOICE=$(whiptail --title " OPERATOR SELECTION " --menu "Select Operator Node :" 20 70 10 \
            "${MENU_LIST[@]}" 3>&1 1>&2 2>&3)

        [[ -n "$OP_CHOICE" ]] && menu_services "$OP_CHOICE"
    fi
done

reset_terminal_profile

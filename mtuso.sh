#!/bin/bash

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

SELF_URL="https://raw.githubusercontent.com/Shellgate/mtuso/main/mtuso.sh"
INSTALL_PATH="/usr/local/bin/mtuso"
SYSTEMD_SERVICE="/etc/systemd/system/mtuso.service"
STATUS_FILE="/tmp/.smart_mtu_mss_status"
CONFIG_FILE="/etc/mtuso.conf"

install_deps() {
    echo -e "${CYAN}Checking and installing dependencies...${NC}"
    local pkgs=(iproute2 net-tools bc curl)
    local to_install=()
    for pkg in "${pkgs[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || to_install+=("$pkg")
    done
    if (( ${#to_install[@]} )); then
        if ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
            sudo apt-get update -y
            sudo apt-get install -y "${to_install[@]}"
            echo -e "${GREEN}Dependencies installed.${NC}"
        else
            echo -e "${RED}No internet connection. Cannot install: ${to_install[*]}.${NC}"
            echo -e "${YELLOW}If these packages are missing, please install manually!${NC}"
        fi
    else
        echo -e "${GREEN}All dependencies already installed.${NC}"
    fi
}

setup_service() {
    # Remove previous service if exists
    if systemctl list-unit-files | grep -q '^mtuso\.service'; then
        sudo systemctl stop mtuso 2>/dev/null
        sudo systemctl disable mtuso 2>/dev/null
    fi
    if [ -f "$SYSTEMD_SERVICE" ]; then
        sudo rm -f "$SYSTEMD_SERVICE"
    fi
    sudo systemctl daemon-reload

    # Create new service
    cat <<EOF | sudo tee "$SYSTEMD_SERVICE" >/dev/null
[Unit]
Description=MTU Smart Optimizer Service
After=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH --auto
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable mtuso
}

get_main_interface() {
    ip route | grep '^default' | awk '{print $5}' | head -n1
}

validate_ip_or_host() {
    ping -c1 -W1 "$1" >/dev/null 2>&1
}

parse_duration() {
    local input="$1"
    local total=0
    local rest="$input"
    local matched=0
    while [[ -n "$rest" ]]; do
        if [[ $rest =~ ^([0-9]+)[hH](.*) ]]; then
            total=$((total + ${BASH_REMATCH[1]} * 3600))
            rest="${BASH_REMATCH[2]}"
            matched=1
        elif [[ $rest =~ ^([0-9]+)[mM](.*) ]]; then
            total=$((total + ${BASH_REMATCH[1]} * 60))
            rest="${BASH_REMATCH[2]}"
            matched=1
        elif [[ $rest =~ ^([0-9]+)[sS](.*) ]]; then
            total=$((total + ${BASH_REMATCH[1]}))
            rest="${BASH_REMATCH[2]}"
            matched=1
        elif [[ $rest =~ ^([0-9]+)(.*) ]]; then
            total=$((total + ${BASH_REMATCH[1]}))
            rest="${BASH_REMATCH[2]}"
            matched=1
        else
            break
        fi
        rest="${rest#"${rest%%[![:space:]]*}"}"
    done
    [[ $matched -eq 1 ]] && echo $total || echo 0
}

test_jumbo_supported() {
    local IFACE=$1
    local ORIG_MTU
    ORIG_MTU=$(ip link show "$IFACE" | grep -o 'mtu [0-9]*' | awk '{print $2}')
    sudo ip link set dev "$IFACE" up
    if sudo ip link set dev "$IFACE" mtu 9000 2>/dev/null; then
        sudo ip link set dev "$IFACE" mtu "$ORIG_MTU"
        return 0
    else
        return 1
    fi
}

show_service_error() {
    echo -e "${RED}Service failed to start or restart.${NC}"
    systemctl status mtuso --no-pager -l | head -20
    echo -e "${YELLOW}Recent logs:${NC}"
    sudo journalctl -u mtuso -n 10 --no-pager
    echo -e "${YELLOW}Summary: Most likely cause is missing/corrupted executable, wrong permissions, or invalid config.${NC}"
}

configure_settings() {
    install_deps

    local IFACE DST INTERVAL_RAW INTERVAL JUMBO FORCE_JUMBO
    IFACE=$(get_main_interface)
    if [ -z "$IFACE" ]; then
        echo -e "${RED}No main network interface detected.${NC}"
        return
    fi
    echo -e "${CYAN}Detected main interface: $IFACE${NC}"

    # Load previous config if exists
    local prev_DST="" prev_INTERVAL="" prev_JUMBO="" prev_FORCE_JUMBO=""
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
        prev_DST="$DST"
        prev_INTERVAL="$INTERVAL"
        prev_JUMBO="$JUMBO"
        prev_FORCE_JUMBO="$FORCE_JUMBO"
    fi

    # Input DST
    while true; do
        read -p "Enter destination IP or domain for MTU test [${prev_DST}]: " DST_NEW
        DST="${DST_NEW:-$prev_DST}"
        if [ -n "$DST" ] && validate_ip_or_host "$DST"; then
            break
        else
            echo -e "${RED}Invalid IP address or hostname. Please try again.${NC}"
        fi
    done

    # Input INTERVAL
    while true; do
        read -p "Enter optimization interval (e.g. 60, 5m, 2h, 1h5m10s) [${prev_INTERVAL}]: " INTERVAL_RAW_NEW
        INTERVAL_RAW="${INTERVAL_RAW_NEW:-$prev_INTERVAL}"
        INTERVAL=$(parse_duration "$INTERVAL_RAW")
        [ "$INTERVAL" -ge 5 ] && break
        echo -e "${RED}Please enter a valid duration (>=5 seconds)!${NC}"
    done

    # Input JUMBO
    if test_jumbo_supported "$IFACE"; then
        while true; do
            read -p "Enable Jumbo Frame (MTU 9000) for $IFACE? (y/n) [${prev_JUMBO}]: " JUMBO_NEW
            JUMBO="${JUMBO_NEW:-$prev_JUMBO}"
            if [[ "$JUMBO" =~ ^[yYnN]$ ]]; then break; fi
        done
        if [[ "$JUMBO" =~ ^[yY]$ ]]; then
            while true; do
                read -p "Force Jumbo Frame even if ping test fails? (y/n) [${prev_FORCE_JUMBO}]: " FORCE_JUMBO_NEW
                FORCE_JUMBO="${FORCE_JUMBO_NEW:-$prev_FORCE_JUMBO}"
                if [[ "$FORCE_JUMBO" =~ ^[yYnN]$ ]]; then break; fi
            done
        else
            FORCE_JUMBO="n"
        fi
    else
        echo -e "${YELLOW}Jumbo Frame (MTU 9000) is NOT supported on $IFACE.${NC}"
        JUMBO="n"
        FORCE_JUMBO="n"
    fi

    # Save config
    sudo tee "$CONFIG_FILE" >/dev/null <<EOF
DST=$DST
INTERVAL=$INTERVAL
JUMBO=$JUMBO
FORCE_JUMBO=$FORCE_JUMBO
EOF
    echo -e "${GREEN}Configuration saved to $CONFIG_FILE${NC}"

    # Check and fix executable
    if [ ! -f "$INSTALL_PATH" ]; then
        echo -e "${RED}Executable not found: $INSTALL_PATH. Cannot (re)start service.${NC}"
        return 1
    fi
    if ! head -1 "$INSTALL_PATH" | grep -qE '^#!.*/bash'; then
        echo -e "${RED}Script missing or invalid shebang (#!/bin/bash)${NC}"
        return 1
    fi
    sudo chmod +x "$INSTALL_PATH"

    # Setup & restart service
    setup_service
    sudo systemctl daemon-reload
    sudo systemctl restart mtuso

    sleep 1

    # Check status and print error if failed
    if ! systemctl is-active --quiet mtuso 2>/dev/null; then
        show_service_error
    else
        echo -e "${GREEN}Service restarted and running with new configuration.${NC}"
    fi
    sleep 1
}

apply_settings() {
    local IFACE=$1
    local MTU=$2
    local MSS=$3
    local ORIG_MTU
    ORIG_MTU=$(ip link show "$IFACE" | grep -o 'mtu [0-9]*' | awk '{print $2}')
    sudo ip link set dev $IFACE mtu $MTU
    if ! ping -I "$IFACE" -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
        sudo ip link set dev $IFACE mtu $ORIG_MTU
        echo -e "${RED}MTU change broke connectivity. Reverted to previous MTU ($ORIG_MTU).${NC}"
        return 1
    fi
    sudo iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS 2>/dev/null || \
    sudo iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS
    return 0
}

reset_settings() {
    local IFACE
    IFACE=$(get_main_interface)
    [ -n "$IFACE" ] && sudo ip link set dev $IFACE mtu 1500
    sudo iptables -t mangle -F
    sudo rm -f "$CONFIG_FILE"
    echo -e "${GREEN}All settings reset to default.${NC}"
    sleep 1
}

show_status() {
    echo -e "${CYAN}Service status:${NC}"
    systemctl status mtuso --no-pager -l | head -20
    echo -e "${CYAN}Recent logs:${NC}"
    sudo journalctl -u mtuso -n 10 --no-pager
}

show_live_log() {
    echo -e "${CYAN}Showing live log for mtuso service. Press Ctrl+C to exit.${NC}"
    sudo journalctl -u mtuso -f
}

toggle_service() {
    if systemctl is-active --quiet mtuso 2>/dev/null; then
        sudo systemctl stop mtuso
        echo -e "${YELLOW}Service stopped.${NC}"
    else
        sudo systemctl start mtuso
        echo -e "${GREEN}Service started.${NC}"
    fi
    sleep 1
}

toggle_autostart() {
    if systemctl is-enabled --quiet mtuso 2>/dev/null; then
        sudo systemctl disable mtuso
        echo -e "${YELLOW}Service autostart disabled.${NC}"
    else
        sudo systemctl enable mtuso
        echo -e "${GREEN}Service autostart enabled.${NC}"
    fi
    sleep 1
}

restart_service() {
    if [ ! -f "$INSTALL_PATH" ]; then
        echo -e "${RED}Executable not found: $INSTALL_PATH. Cannot restart service.${NC}"
        return 1
    fi
    sudo chmod +x "$INSTALL_PATH"
    sudo systemctl daemon-reload
    if systemctl is-active --quiet mtuso 2>/dev/null; then
        sudo systemctl restart mtuso
        echo -e "${GREEN}Service restarted.${NC}"
    else
        sudo systemctl start mtuso
        echo -e "${GREEN}Service started.${NC}"
    fi
    sleep 1
}

uninstall_all() {
    read -p "Are you sure you want to uninstall MTUSO and remove all settings? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Uninstall cancelled.${NC}"; return; }

    IFACE=$(get_main_interface)
    [ -n "$IFACE" ] && sudo ip link set dev $IFACE mtu 1500
    sudo iptables -t mangle -F

    sudo systemctl stop mtuso || true
    sudo systemctl disable mtuso || true
    sudo rm -f "$SYSTEMD_SERVICE"
    sudo rm -f "$INSTALL_PATH"
    sudo rm -f "$CONFIG_FILE"
    sudo rm -f "$STATUS_FILE"
    sudo systemctl daemon-reload
    echo -e "${GREEN}MTUSO has been uninstalled and network settings restored to default.${NC}"
    sleep 1
    exit 0
}

delete_settings() {
    read -p "Are you sure you want to reset all network optimization settings? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Reset cancelled.${NC}"; return; }
    reset_settings
    rm -f $STATUS_FILE
    echo -e "${RED}All optimizer settings and status removed.${NC}"
    sleep 1
}

find_best_mtu() {
    local IFACE=$1
    local DST=$2
    local best_mtu=1300
    local best_score=100000
    local step=5
    for ((mtu=1500; mtu>=1300; mtu-=step)); do
        local ok=1
        local delays=()
        for i in {1..3}; do
            OUT=$(ping -I "$IFACE" -M do -s $((mtu-28)) -c 1 -W 1 "$DST" 2>/dev/null)
            if [[ $? -ne 0 ]]; then ok=0; break; fi
            DELAY=$(echo "$OUT" | grep 'time=' | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
            delays+=("$DELAY")
        done
        if [[ $ok -eq 1 ]]; then
            AVG=$(echo "${delays[@]}" | tr ' ' '\n' | awk '{s+=$1}END{print (NR>0)?s/NR:0}')
            MAX=$(echo "${delays[@]}" | tr ' ' '\n' | sort -n | tail -1)
            MIN=$(echo "${delays[@]}" | tr ' ' '\n' | sort -n | head -1)
            JITTER=$(echo "$MAX - $MIN" | bc)
            SCORE=$(echo "$AVG + 2*$JITTER" | bc)
            if (( $(echo "$SCORE < $best_score" | bc -l) )); then
                best_score=$SCORE
                best_mtu=$mtu
            fi
        fi
    done
    echo $best_mtu
}

run_optimization() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}No configuration found. Please complete configuration first.${NC}"
        configure_settings
        [ ! -f "$CONFIG_FILE" ] && return
    fi

    . "$CONFIG_FILE"
    local IFACE
    IFACE=$(get_main_interface)
    echo "enabled" > $STATUS_FILE

    while [ "$(cat $STATUS_FILE 2>/dev/null)" == "enabled" ]; do
        if [[ "$JUMBO" =~ ^[yY]$ ]]; then
            sudo ip link set dev "$IFACE" mtu 9000
            local jumbo_ok=1
            for i in {1..3}; do
                ping -I "$IFACE" -M do -s 8972 -c 1 -W 1 "$DST" >/dev/null 2>&1 || { jumbo_ok=0; break; }
            done
            if [[ $jumbo_ok -eq 1 || "$FORCE_JUMBO" =~ ^[yY]$ ]]; then
                MTU=9000
                MSS=8960
                echo -e "${CYAN}Applying Jumbo Frame MTU=$MTU and MSS=$MSS on $IFACE${NC}"
                apply_settings "$IFACE" "$MTU" "$MSS"
                for ((i=0; i<$INTERVAL; i++)); do
                    [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
                    sleep 1
                done
                continue
            else
                echo -e "${RED}Jumbo Frame not working to $DST. Reverting to normal MTU search.${NC}"
                sudo ip link set dev "$IFACE" mtu 1500
            fi
        fi
        MTU=$(find_best_mtu "$IFACE" "$DST")
        MSS=$((MTU-40))
        echo -e "${CYAN}Optimal MTU detected: $MTU, MSS: $MSS${NC}"
        apply_settings "$IFACE" "$MTU" "$MSS"
        for ((i=0; i<$INTERVAL; i++)); do
            [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
            sleep 1
        done
    done
}

if [ "$1" = "--auto" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "No config file found at $CONFIG_FILE, waiting for configuration..."
        while [ ! -f "$CONFIG_FILE" ]; do sleep 10; done
    fi
    run_optimization
    exit 0
fi

while true; do
    clear
    echo -e "${CYAN}========= MTUSO - Smart MTU/MSS Optimizer =========${NC}"
    echo "1) Configure & Save Optimization"
    echo -n "2) Service status: "
    if systemctl is-active --quiet mtuso 2>/dev/null; then
        echo "ON"
    else
        echo "OFF"
    fi
    echo -n "3) Service autostart: "
    if systemctl is-enabled --quiet mtuso 2>/dev/null; then
        echo "ON"
    else
        echo "OFF"
    fi
    echo "4) Restart Service"
    echo "5) Status"
    echo "6) Live Log"
    echo "7) Reset All Settings"
    echo "8) Uninstall"
    echo "9) Exit"
    read -p "Choose an option [1-9]: " CHOICE
    case $CHOICE in
        1) configure_settings ;;
        2) toggle_service ;;
        3) toggle_autostart ;;
        4) restart_service ;;
        5) show_status; read -p "Press enter to continue..." ;;
        6) show_live_log ;;
        7) delete_settings ;;
        8) uninstall_all ;;
        9) echo "Bye!"; exit 0 ;;
        *) echo "Invalid option!"; sleep 1 ;;
    esac
done

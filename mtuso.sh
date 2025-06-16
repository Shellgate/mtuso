#!/bin/bash

# MTUSO - All-in-One Smart MTU/MSS Optimizer & Installer
# Author: Shellgate

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
GRAY='\033[1;30m'
NC='\033[0m'

SELF_URL="https://raw.githubusercontent.com/Shellgate/mtuso/main/mtuso.sh"
INSTALL_PATH="/usr/local/bin/mtuso"
SYSTEMD_SERVICE="/etc/systemd/system/mtuso.service"
STATUS_FILE="/tmp/.smart_mtu_mss_status"

# --- Dependency Check & Install ---
install_deps() {
    echo -e "${CYAN}[MTUSO] Installing dependencies...${NC}"
    sudo apt-get update -y
    sudo apt-get install -y iproute2 net-tools bc curl
    echo -e "${GREEN}[MTUSO] Dependencies are installed.${NC}"
    sleep 1
}

# --- Self-Update ---
self_update() {
    echo -e "${CYAN}[MTUSO] Updating to the latest version...${NC}"
    sudo curl -fsSL "$SELF_URL" -o "$INSTALL_PATH"
    sudo chmod +x "$INSTALL_PATH"
    echo -e "${GREEN}MTUSO has been updated successfully.${NC}"
    sleep 1
}

# --- Systemd Service ---
setup_service() {
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
    sudo systemctl start mtuso
    echo -e "${GREEN}Service enabled and started.${NC}"
    sleep 1
}

disable_service() {
    sudo systemctl stop mtuso || true
    sudo systemctl disable mtuso || true
    echo -e "${RED}Service stopped and disabled.${NC}"
    sleep 1
}

uninstall_all() {
    sudo systemctl stop mtuso || true
    sudo systemctl disable mtuso || true
    sudo rm -f "$SYSTEMD_SERVICE"
    sudo rm -f "$INSTALL_PATH"
    sudo systemctl daemon-reload
    echo -e "${GREEN}MTUSO has been uninstalled.${NC}"
    sleep 1
    exit 0
}

# --- Optimizer Logic ---
get_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v "lo"
}

test_mtu() {
    local IFACE=$1
    local DST=$2
    local MIN_MTU=1200
    local MAX_MTU=9000
    local BEST_MTU=$MIN_MTU
    local BEST_SCORE=999999

    for ((MTU=$MAX_MTU; MTU>=$MIN_MTU; MTU-=100)); do
        PING_RESULT=$(ping -I $IFACE -M do -s $((MTU-28)) -c 2 -q $DST 2>/dev/null)
        LOSS=$(echo "$PING_RESULT" | grep -oP '\d+(?=% packet loss)')
        AVG_LATENCY=$(echo "$PING_RESULT" | grep rtt | awk -F'/' '{print $5}')
        [ -z "$LOSS" ] && LOSS=100
        [ -z "$AVG_LATENCY" ] && AVG_LATENCY=9999

        SCORE=$(echo "$LOSS*1000 + $AVG_LATENCY" | bc)
        if (( $(echo "$SCORE < $BEST_SCORE" | bc -l) )); then
            BEST_SCORE=$SCORE
            BEST_MTU=$MTU
        fi
    done
    echo $BEST_MTU
}

calc_mss() {
    local MTU=$1
    echo $((MTU-40))
}

apply_settings() {
    local IFACE=$1
    local MTU=$2
    sudo ip link set dev $IFACE mtu $MTU
    sudo iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    sudo iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
}

reset_settings() {
    for IFACE in $(get_interfaces); do
        sudo ip link set dev $IFACE mtu 1500
    done
    sudo iptables -t mangle -F
    echo -e "${GREEN}All settings reset to default.${NC}"
    sleep 1
}

show_status() {
    local SYS_STATUS RUN_STATUS APP_STATUS
    if [ ! -f "$INSTALL_PATH" ]; then
        APP_STATUS="${RED}NOT INSTALLED${NC}"
    else
        SYS_STATUS=$(systemctl is-enabled mtuso 2>/dev/null || echo "disabled")
        RUN_STATUS=$(systemctl is-active mtuso 2>/dev/null || echo "inactive")
        if [ -f "$STATUS_FILE" ]; then
            SVAL=$(cat "$STATUS_FILE")
            if [[ "$SVAL" == "paused" ]]; then
                APP_STATUS="${YELLOW}PAUSED${NC}"
            elif [[ "$SVAL" == "enabled" ]]; then
                APP_STATUS="${GREEN}ENABLED${NC}"
            else
                APP_STATUS="${RED}DISABLED${NC}"
            fi
        elif [ "$SYS_STATUS" = "enabled" ] && [ "$RUN_STATUS" = "active" ]; then
            APP_STATUS="${GREEN}ENABLED${NC}"
        elif [ "$SYS_STATUS" = "enabled" ]; then
            APP_STATUS="${YELLOW}INSTALLED, but NOT RUNNING${NC}"
        else
            APP_STATUS="${YELLOW}INSTALLED, but DISABLED${NC}"
        fi
    fi
    echo -e "\nStatus: $APP_STATUS"
}

# --- Optimizer Menu Logic ---
main_menu() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════╗"
    echo "║      MTUSO - Smart MTU/MSS Optimizer          ║"
    echo "╚════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  1) Install or Update Dependencies"
    echo "  2) Self-Update (Download latest version)"
    if [ -f "$INSTALL_PATH" ]; then
        echo "  3) Configure & Start Optimization"
        echo "  4) Pause Optimization"
        echo "  5) Resume Optimization"
        echo "  6) Disable & Stop Service"
        echo "  7) Enable & Start as Service"
        echo "  8) Reset All Settings"
        echo "  9) Uninstall MTUSO"
    else
        # Options disabled when not installed
        echo -e "  ${GRAY}3) Configure & Start Optimization   [Install first]${NC}"
        echo -e "  ${GRAY}4) Pause Optimization               [Install first]${NC}"
        echo -e "  ${GRAY}5) Resume Optimization              [Install first]${NC}"
        echo -e "  ${GRAY}6) Disable & Stop Service           [Install first]${NC}"
        echo -e "  ${GRAY}7) Enable & Start as Service        [Install first]${NC}"
        echo -e "  ${GRAY}8) Reset All Settings               [Install first]${NC}"
        echo -e "  ${GRAY}9) Uninstall MTUSO                  [Install first]${NC}"
    fi
    echo " 10) Exit"
    show_status
}

run_optimization() {
    read -p "Enter destination IP or domain to test against (e.g. 8.8.8.8): " DST
    read -p "Enter optimization interval (in seconds, e.g. 5): " INTERVAL
    read -p "Enable Jumbo Frame (MTU 9000)? (y/n): " JUMBO
    echo "enabled" > $STATUS_FILE
    while [ "$(cat $STATUS_FILE 2>/dev/null)" == "enabled" ]; do
        for IFACE in $(get_interfaces); do
            echo -e "${BLUE}Testing on interface: $IFACE${NC}"
            MTU=$(test_mtu $IFACE $DST)
            [ "$JUMBO" == "y" ] && MTU=9000
            MSS=$(calc_mss $MTU)
            echo -e "${CYAN}Applying MTU=$MTU and MSS=$MSS on $IFACE${NC}"
            apply_settings $IFACE $MTU
        done
        for ((i=0; i<$INTERVAL; i++)); do
            [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
            sleep 1
        done
        [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
    done
}

pause_optimization() {
    echo "paused" > $STATUS_FILE
    echo -e "${YELLOW}Optimization paused.${NC}"
    sleep 1
}

resume_optimization() {
    echo "enabled" > $STATUS_FILE
    echo -e "${GREEN}Optimization resumed.${NC}"
    sleep 1
}

disable_optimization() {
    echo "disabled" > $STATUS_FILE
    echo -e "${RED}Optimization disabled.${NC}"
    sleep 1
}

delete_settings() {
    reset_settings
    rm -f $STATUS_FILE
    echo -e "${RED}All optimizer settings and status removed.${NC}"
    sleep 1
}

# --- CLI Arguments for Service Start ---
if [ "$1" = "--auto" ]; then
    DST="8.8.8.8"
    INTERVAL=60
    JUMBO="n"
    echo "enabled" > $STATUS_FILE
    while [ "$(cat $STATUS_FILE 2>/dev/null)" == "enabled" ]; do
        for IFACE in $(get_interfaces); do
            MTU=$(test_mtu $IFACE $DST)
            [ "$JUMBO" == "y" ] && MTU=9000
            MSS=$(calc_mss $MTU)
            apply_settings $IFACE $MTU
        done
        for ((i=0; i<$INTERVAL; i++)); do
            [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
            sleep 1
        done
        [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
    done
    exit 0
fi

# --- Main Menu Loop ---
while true; do
    main_menu
    read -p "Choose an option [1-10]: " CHOICE
    case $CHOICE in
        1) install_deps ;;
        2) self_update ;;
        3) [ -f "$INSTALL_PATH" ] && run_optimization || { echo -e "${RED}Install MTUSO first.${NC}"; sleep 1; } ;;
        4) [ -f "$INSTALL_PATH" ] && pause_optimization || { echo -e "${RED}Install MTUSO first.${NC}"; sleep 1; } ;;
        5) [ -f "$INSTALL_PATH" ] && resume_optimization || { echo -e "${RED}Install MTUSO first.${NC}"; sleep 1; } ;;
        6) [ -f "$INSTALL_PATH" ] && disable_service || { echo -e "${RED}Install MTUSO first.${NC}"; sleep 1; } ;;
        7) [ -f "$INSTALL_PATH" ] && setup_service || { echo -e "${RED}Install MTUSO first.${NC}"; sleep 1; } ;;
        8) [ -f "$INSTALL_PATH" ] && delete_settings || { echo -e "${RED}Install MTUSO first.${NC}"; sleep 1; } ;;
        9) [ -f "$INSTALL_PATH" ] && uninstall_all || { echo -e "${RED}Install MTUSO first.${NC}"; sleep 1; } ;;
        10) echo "Bye!"; exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}"; sleep 1 ;;
    esac
done

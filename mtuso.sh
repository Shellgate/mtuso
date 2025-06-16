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

install_deps() {
    echo -e "${CYAN}Installing dependencies...${NC}"
    sudo apt-get update -y
    sudo apt-get install -y iproute2 net-tools bc curl
    echo -e "${GREEN}Dependencies installed.${NC}"
}

self_install() {
    echo -e "${CYAN}Installing MTUSO...${NC}"
    sudo curl -fsSL "$SELF_URL" -o "$INSTALL_PATH"
    sudo chmod +x "$INSTALL_PATH"
    echo -e "${GREEN}MTUSO installed to $INSTALL_PATH${NC}"
    sleep 1
}

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
}

enable_service() {
    setup_service
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

get_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -Ev "lo|docker|virbr|br-|veth|vmnet|tun|tap"
}

validate_ip_or_host() {
    local DST="$1"
    if ! ping -c1 -W1 "$DST" >/dev/null 2>&1; then
        echo -e "${RED}Invalid IP address or hostname. Please try again.${NC}"
        return 1
    fi
    return 0
}

test_mtu() {
    local IFACE=$1
    local DST=$2
    local MIN_MTU=1200
    local MAX_MTU=9000
    local BEST_MTU=$MIN_MTU
    local BEST_SCORE=999999

    if ! ping -I "$IFACE" -c 1 -W 1 "$DST" >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: $IFACE cannot reach $DST. Skipping.${NC}"
        return
    fi

    for ((MTU=$MAX_MTU; MTU>=$MIN_MTU; MTU-=100)); do
        PING_RESULT=$(ping -I $IFACE -M do -s $((MTU-28)) -c 1 -W 1 -q $DST 2>/dev/null)
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
    local MSS=$3
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

get_service_status() {
    SYS_STATUS=$(systemctl is-enabled mtuso 2>/dev/null || echo "disabled")
    RUN_STATUS=$(systemctl is-active mtuso 2>/dev/null || echo "inactive")
    if [ "$SYS_STATUS" = "enabled" ] && [ "$RUN_STATUS" = "active" ]; then
        echo -e "${GREEN}ON${NC}"
    else
        echo -e "${RED}OFF${NC}"
    fi
}

get_optimization_status() {
    if [ -f "$STATUS_FILE" ]; then
        STATUS=$(cat "$STATUS_FILE")
        case $STATUS in
            enabled) echo -e "${GREEN}Running${NC}" ;;
            paused) echo -e "${YELLOW}Paused${NC}" ;;
            disabled) echo -e "${RED}Disabled${NC}" ;;
            *) echo -e "${GRAY}Unknown${NC}" ;;
        esac
    else
        echo -e "${RED}Inactive${NC}"
    fi
}

show_status() {
    if [ ! -f "$INSTALL_PATH" ]; then
        echo -e "Status: ${RED}NOT INSTALLED${NC}"
        return
    fi
    SYS_STATUS=$(systemctl is-enabled mtuso 2>/dev/null || echo "disabled")
    RUN_STATUS=$(systemctl is-active mtuso 2>/dev/null || echo "inactive")
    if [ "$SYS_STATUS" = "enabled" ] && [ "$RUN_STATUS" = "active" ]; then
        echo -e "Status: ${GREEN}ENABLED${NC}"
    elif [ "$SYS_STATUS" = "enabled" ]; then
        echo -e "Status: ${YELLOW}INSTALLED, but NOT RUNNING${NC}"
    else
        echo -e "Status: ${YELLOW}INSTALLED, but DISABLED${NC}"
    fi
}

run_optimization() {
    while true; do
        read -p "Enter destination IP or domain to test against (e.g. 8.8.8.8): " DST
        if validate_ip_or_host "$DST"; then
            break
        fi
    done
    while true; do
        read -p "Enter optimization interval (in seconds, e.g. 5): " INTERVAL
        [[ "$INTERVAL" =~ ^[0-9]+$ ]] && [ "$INTERVAL" -gt 0 ] && break
        echo -e "${RED}Please enter a valid positive number!${NC}"
    done
    read -p "Enable Jumbo Frame (MTU 9000)? (y/n): " JUMBO
    echo "enabled" > $STATUS_FILE
    while [ "$(cat $STATUS_FILE 2>/dev/null)" == "enabled" ]; do
        for IFACE in $(get_interfaces); do
            echo -e "${BLUE}Testing on interface: $IFACE${NC}"
            MTU=$(test_mtu $IFACE $DST)
            if [ -z "$MTU" ]; then
                continue
            fi
            [ "$JUMBO" == "y" ] && MTU=9000
            MSS=$(calc_mss $MTU)
            echo -e "${CYAN}Applying MTU=$MTU and MSS=$MSS on $IFACE${NC}"
            apply_settings $IFACE $MTU $MSS
        done
        for ((i=0; i<$INTERVAL; i++)); do
            [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
            sleep 1
        done
        [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
    done
}

enable_disable_service() {
    SYS_STATUS=$(systemctl is-enabled mtuso 2>/dev/null || echo "disabled")
    RUN_STATUS=$(systemctl is-active mtuso 2>/dev/null || echo "inactive")
    if [ "$SYS_STATUS" = "enabled" ] && [ "$RUN_STATUS" = "active" ]; then
        disable_service
    else
        enable_service
    fi
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
            if [ -z "$MTU" ]; then
                continue
            fi
            [ "$JUMBO" == "y" ] && MTU=9000
            MSS=$(calc_mss $MTU)
            apply_settings $IFACE $MTU $MSS
        done
        for ((i=0; i<$INTERVAL; i++)); do
            [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
            sleep 1
        done
        [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
    done
    exit 0
fi

# --- Dynamic Main Menu Loop ---
while true; do
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════╗"
    echo "║      MTUSO - Smart MTU/MSS Optimizer          ║"
    echo "╚════════════════════════════════════════════════╝"
    echo -e "${NC}"
    if [ ! -f "$INSTALL_PATH" ]; then
        echo "  1) Install MTUSO"
        echo "  2) Exit"
        show_status
        read -p "Choose an option [1-2]: " CHOICE
        case $CHOICE in
            1)
                install_deps
                self_install
                sleep 1
                ;;
            2)
                echo "Bye!"; exit 0 ;;
            *)
                echo -e "${RED}Invalid option!${NC}"; sleep 1 ;;
        esac
        continue
    fi

    # If installed, show full menu with status
    echo -n "  1) Configure & Start Optimization [status: "
    get_optimization_status
    echo -n "  2) "
    SYS_STATUS=$(systemctl is-enabled mtuso 2>/dev/null || echo "disabled")
    RUN_STATUS=$(systemctl is-active mtuso 2>/dev/null || echo "inactive")
    if [ "$SYS_STATUS" = "enabled" ] && [ "$RUN_STATUS" = "active" ]; then
        echo -n "Disable Service "
    else
        echo -n "Enable Service  "
    fi
    echo -n "[status: "
    get_service_status
    echo "  3) Reset All Settings"
    echo "  4) Uninstall MTUSO"
    echo "  5) Exit"
    show_status
    read -p "Choose an option [1-5]: " CHOICE
    case $CHOICE in
        1) run_optimization ;;
        2) enable_disable_service ;;
        3) delete_settings ;;
        4) uninstall_all ;;
        5) echo "Bye!"; exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}"; sleep 1 ;;
    esac
done

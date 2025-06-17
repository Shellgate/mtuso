#!/bin/bash
set -e

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
GRAY='\033[1;30m'
NC='\033[0m'

VERSION="2.0.0"
SELF_URL="https://raw.githubusercontent.com/Shellgate/mtuso/main/mtuso.sh"
INSTALL_PATH="/usr/local/bin/mtuso"
SYSTEMD_SERVICE="/etc/systemd/system/mtuso.service"
STATUS_FILE="/tmp/.smart_mtu_mss_status"
CONFIG_FILE="/etc/mtuso.conf"
CONFIG_BAK="/etc/mtuso.conf.bak"
ORIGINAL_MTU_FILE="/etc/mtuso_original.conf"

require_sudo() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Please run as root or with sudo!${NC}"
        exit 1
    fi
}

install_deps() {
    local pkgs=(iproute2 net-tools bc curl)
    local to_install=()
    for pkg in "${pkgs[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || to_install+=("$pkg")
    done
    if (( ${#to_install[@]} )); then
        apt-get update -y
        apt-get install -y "${to_install[@]}"
    fi
}

self_update() {
    curl -fsSL "$SELF_URL" -o "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    echo -e "${GREEN}MTUSO updated to latest version.${NC}"
}

setup_service() {
    cat <<EOF > "$SYSTEMD_SERVICE"
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
    systemctl daemon-reload
}

show_last_log() {
    journalctl -u mtuso -n 10 --no-pager | tail -10
}

get_all_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v lo
}

get_main_interface() {
    ip route | grep '^default' | awk '{print $5}' | head -n1
}

choose_interface() {
    local ifs=($(get_all_interfaces))
    if (( ${#ifs[@]} == 1 )); then
        echo "${ifs[0]}"
        return
    fi
    echo -e "${CYAN}Available interfaces:${NC}"
    local i=1
    for iface in "${ifs[@]}"; do
        echo "  $i) $iface"
        ((i++))
    done
    while true; do
        read -p "Select interface [1-${#ifs[@]}]: " sel
        if [[ $sel =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#ifs[@]} )); then
            echo "${ifs[$((sel-1))]}"
            return
        fi
    done
}

backup_config() {
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$CONFIG_BAK"
        echo -e "${YELLOW}Backup of old config at $CONFIG_BAK${NC}"
    fi
}

show_network_summary() {
    local iface="$1"
    local mtu
    mtu=$(ip link show "$iface" | grep -o 'mtu [0-9]*' | awk '{print $2}')
    echo -e "${CYAN}Current Interface: $iface | MTU: $mtu${NC}"
    iptables -t mangle -S | grep TCPMSS || echo "No TCPMSS rule"
}

edit_config() {
    backup_config

    local IFACE DST INTERVAL JUMBO
    IFACE=$(choose_interface)
    curr_dst=""; curr_interval=""; curr_jumbo=""
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
        curr_dst="$DST"
        curr_interval="$INTERVAL"
        curr_jumbo="$JUMBO"
    fi
    echo -e "${CYAN}Configuring for interface: $IFACE${NC}"

    while true; do
        read -p "Destination IP/domain [${curr_dst:-8.8.8.8}]: " DST
        DST="${DST:-$curr_dst}"
        ping -c1 -W1 "$DST" >/dev/null 2>&1 && break || echo -e "${RED}Invalid destination.${NC}"
    done
    while true; do
        read -p "Optimization interval (e.g. 120, 5m) [${curr_interval:-300}]: " INTERVAL_RAW
        INTERVAL_RAW="${INTERVAL_RAW:-$curr_interval}"
        INTERVAL=$(echo "$INTERVAL_RAW" | grep -Eo '^[0-9]+$' || echo 300)
        [ "$INTERVAL" -ge 5 ] && break
        echo -e "${RED}Please enter a valid duration (>=5 seconds)!${NC}"
    done
    if test_jumbo_supported "$IFACE"; then
        read -p "Enable Jumbo Frame (MTU 9000)? [y/N] " JUMBO
        JUMBO="${JUMBO:-n}"
    else
        JUMBO="n"
    fi

    cat > "$CONFIG_FILE" <<EOF
IFACE=$IFACE
DST=$DST
INTERVAL=$INTERVAL
JUMBO=$JUMBO
EOF
    echo -e "${GREEN}Config saved to $CONFIG_FILE${NC}"
}

test_jumbo_supported() {
    local IFACE=$1
    local ORIG_MTU
    ORIG_MTU=$(ip link show "$IFACE" | grep -o 'mtu [0-9]*' | awk '{print $2}')
    ip link set dev "$IFACE" mtu 9000 2>/dev/null && ip link set dev "$IFACE" mtu "$ORIG_MTU" && return 0
    return 1
}

reset_network() {
    local IFACE
    IFACE=$(get_main_interface)
    ip link set dev "$IFACE" mtu 1500
    iptables -t mangle -F
    rm -f "$CONFIG_FILE"
    echo -e "${GREEN}Network reset to default.${NC}"
}

main_menu() {
    while true; do
        clear
        echo -e "${CYAN}========= MTUSO v$VERSION - Smart MTU/MSS Optimizer =========${NC}"
        echo "1) Install/Update Dependencies"
        echo "2) Edit Config & Optimize"
        echo "3) Enable/Disable Service"
        echo "4) Show Network Status"
        echo "5) Show Last Service Log"
        echo "6) Self-Update"
        echo "7) Reset Network"
        echo "8) Uninstall"
        echo "9) Exit"
        read -p "Choose an option [1-9]: " CHOICE
        case $CHOICE in
            1) require_sudo; install_deps; sleep 1 ;;
            2) require_sudo; edit_config; sleep 1 ;;
            3) require_sudo; systemctl is-enabled mtuso && { systemctl stop mtuso; systemctl disable mtuso; echo -e "${RED}Service disabled.${NC}"; } || { setup_service; systemctl enable mtuso; systemctl start mtuso; echo -e "${GREEN}Service enabled and started.${NC}"; } ; sleep 1 ;;
            4) show_network_summary "$(get_main_interface)"; read -p "Press enter..." ;;
            5) show_last_log; read -p "Press enter..." ;;
            6) require_sudo; self_update; sleep 1 ;;
            7) require_sudo; reset_network; sleep 1 ;;
            8) require_sudo; uninstall_all ;;
            9) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

[ "$1" = "--auto" ] && exec run_optimization || main_menu

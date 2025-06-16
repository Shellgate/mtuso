#!/bin/bash

# MTU/MSS Smart Optimizer - Main Script
# Author: Shellgate Copilot

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

STATUS_FILE="/tmp/.smart_mtu_mss_status"

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
}

show_status() {
    if [ -f "$STATUS_FILE" ]; then
        STATUS=$(cat "$STATUS_FILE")
        if [ "$STATUS" == "enabled" ]; then
            echo -e "Status: ${GREEN}ENABLED${NC}"
        elif [ "$STATUS" == "paused" ]; then
            echo -e "Status: ${YELLOW}PAUSED${NC}"
        else
            echo -e "Status: ${RED}DISABLED${NC}"
        fi
    else
        echo -e "Status: ${RED}DISABLED${NC}"
    fi
}

main_menu() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════╗"
    echo "║      MTU/MSS Smart Optimizer (mtuso)          ║"
    echo "╚════════════════════════════════════════════════╝"
    echo -e "${NC}"
    show_status
    echo "  1) Configure & Start Optimization"
    echo "  2) Pause Optimization"
    echo "  3) Resume Optimization"
    echo "  4) Disable Optimization"
    echo "  5) Reset All Settings"
    echo "  6) Exit"
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

while true; do
    main_menu
    read -p "Choose an option [1-6]: " CHOICE
    case $CHOICE in
        1) run_optimization ;;
        2) pause_optimization ;;
        3) resume_optimization ;;
        4) disable_optimization ;;
        5) delete_settings ;;
        6) echo "Bye!"; exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}" ;;
    esac
    sleep 1
done

#!/bin/bash

# MTUSO - Smart MTU/MSS Optimizer

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
CONFIG_FILE="/etc/mtuso.conf"
LOG_FILE="/var/log/mtuso.log"

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
    read -p "Are you sure you want to uninstall MTUSO and remove all settings and logs? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Uninstall cancelled.${NC}"; return; }
    sudo systemctl stop mtuso || true
    sudo systemctl disable mtuso || true
    sudo rm -f "$SYSTEMD_SERVICE"
    sudo rm -f "$INSTALL_PATH"
    sudo rm -f "$CONFIG_FILE"
    sudo rm -f "$STATUS_FILE"
    sudo rm -f "$LOG_FILE"
    sudo systemctl daemon-reload
    echo -e "${GREEN}MTUSO has been uninstalled and all related files removed.${NC}"
    sleep 1
    exit 0
}

get_main_interface() {
    ip route | grep '^default' | awk '{print $5}' | head -n1
}

validate_ip_or_host() {
    local DST="$1"
    if ! ping -c1 -W1 "$DST" >/dev/null 2>&1; then
        echo -e "${RED}Invalid IP address or hostname. Please try again.${NC}"
        return 1
    fi
    return 0
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

test_mtu() {
    local IFACE=$1
    local DST=$2
    local MIN_MTU=1300
    local MAX_MTU=1500
    local BEST_MTU=$MIN_MTU
    local original_mtu

    original_mtu=$(ip link show "$IFACE" | grep -o 'mtu [0-9]*' | awk '{print $2}')
    sudo ip link set dev "$IFACE" mtu $MAX_MTU

    if ! ping -I "$IFACE" -c 1 -W 1 "$DST" >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: $IFACE cannot reach $DST. Skipping.${NC}"
        sudo ip link set dev "$IFACE" mtu $original_mtu
        return 1
    fi

    for ((MTU=$MAX_MTU; MTU>=$MIN_MTU; MTU-=10)); do
        if ping -I "$IFACE" -M do -s $((MTU-28)) -c 1 -W 1 "$DST" >/dev/null 2>&1; then
            BEST_MTU=$MTU
            break
        fi
    done
    sudo ip link set dev "$IFACE" mtu $original_mtu
    echo $BEST_MTU
    return 0
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

calc_mss() {
    local MTU=$1
    echo $((MTU-40))
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
    [ -z "$IFACE" ] && return
    sudo ip link set dev $IFACE mtu 1500
    sudo iptables -t mangle -F
    sudo rm -f "$CONFIG_FILE"
    sudo rm -f "$LOG_FILE"
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

configure_settings() {
    local IFACE DST INTERVAL_RAW INTERVAL JUMBO FORCE
    IFACE=$(get_main_interface)
    if [ -z "$IFACE" ]; then
        echo -e "${RED}No main network interface detected.${NC}"
        return
    fi
    echo -e "${CYAN}Detected main interface: $IFACE${NC}"

    while true; do
        read -p "Enter destination IP or domain for MTU test (e.g. 8.8.8.8): " DST
        if validate_ip_or_host "$DST"; then
            break
        fi
    done

    while true; do
        read -p "Enter optimization interval (e.g. 60, 5m, 2h, 1h5m10s): " INTERVAL_RAW
        INTERVAL=$(parse_duration "$INTERVAL_RAW")
        [ "$INTERVAL" -ge 5 ] && break
        echo -e "${RED}Please enter a valid duration (>=5 seconds)!${NC}"
    done

    read -p "Enable Jumbo Frame (MTU 9000) for $IFACE? (y/n): " JUMBO
    FORCE="n"
    if [[ "$JUMBO" =~ ^[Yy]$ ]]; then
        read -p "Force Jumbo Frame even if not supported or ping fails? (y/n): " FORCE
    fi

    sudo tee "$CONFIG_FILE" >/dev/null <<EOF
DST=$DST
INTERVAL=$INTERVAL
JUMBO=$JUMBO
FORCE=$FORCE
EOF
    echo -e "${GREEN}Configuration saved to $CONFIG_FILE${NC}"
}

goto_normal_mtu() {
    local IFACE DST MTU MSS
    IFACE="$1"
    DST="$2"
    MTU=$(test_mtu $IFACE $DST)
    if [ $? -ne 0 ]; then
        echo -e "${RED}Could not detect a safe MTU. Skipping...${NC}"
    else
        echo -e "${CYAN}Optimal MTU detected: $MTU${NC}"
        MSS=$(calc_mss $MTU)
        echo -e "${CYAN}Applying MTU=$MTU and MSS=$MSS on $IFACE${NC}"
        apply_settings $IFACE $MTU $MSS
    fi
}

run_optimization() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}No configuration found. Please complete configuration first.${NC}"
        configure_settings
        [ ! -f "$CONFIG_FILE" ] && return
    fi

    . "$CONFIG_FILE"
    local IFACE DST INTERVAL JUMBO FORCE MTU MSS
    IFACE=$(get_main_interface)
    DST="$DST"
    INTERVAL="$INTERVAL"
    JUMBO="$JUMBO"
    FORCE="$FORCE"
    echo "enabled" > $STATUS_FILE

    # لاگ‌گیری زنده
    exec > >(tee -a "$LOG_FILE") 2>&1

    while [ "$(cat $STATUS_FILE 2>/dev/null)" == "enabled" ]; do
        if [ "$JUMBO" = "y" ] || [ "$JUMBO" = "Y" ]; then
            if [ "$FORCE" = "y" ] || [ "$FORCE" = "Y" ]; then
                MTU=9000
                MSS=$(calc_mss $MTU)
                echo -e "${CYAN}Force applying Jumbo Frame MTU=$MTU and MSS=$MSS on $IFACE${NC}"
                apply_settings $IFACE $MTU $MSS
                if ! ping -I "$IFACE" -M do -s $((MTU-28)) -c 1 -W 1 "$DST" >/dev/null 2>&1; then
                    echo -e "${RED}Warning: Forced Jumbo Frame may not work to $DST.${NC}"
                fi
            else
                if test_jumbo_supported "$IFACE"; then
                    MTU=9000
                    if ping -I "$IFACE" -M do -s $((MTU-28)) -c 1 -W 1 "$DST" >/dev/null 2>&1; then
                        MSS=$(calc_mss $MTU)
                        echo -e "${CYAN}Applying Jumbo Frame MTU=$MTU and MSS=$MSS on $IFACE${NC}"
                        apply_settings $IFACE $MTU $MSS
                    else
                        echo -e "${RED}Jumbo Frame not working to $DST. Falling back to normal MTU.${NC}"
                        goto_normal_mtu "$IFACE" "$DST"
                    fi
                else
                    echo -e "${RED}Jumbo Frame not supported by $IFACE, falling back to normal MTU.${NC}"
                    goto_normal_mtu "$IFACE" "$DST"
                fi
            fi
        else
            goto_normal_mtu "$IFACE" "$DST"
        fi
        for ((i=0; i<$INTERVAL; i++)); do
            [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
            sleep 1
        done
        [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
    done
}

enable_disable_service() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}You must configure optimization first.${NC}"
        configure_settings
        [ ! -f "$CONFIG_FILE" ] && return
    fi
    SYS_STATUS=$(systemctl is-enabled mtuso 2>/dev/null || echo "disabled")
    RUN_STATUS=$(systemctl is-active mtuso 2>/dev/null || echo "inactive")
    if [ "$SYS_STATUS" = "enabled" ] && [ "$RUN_STATUS" = "active" ]; then
        disable_service
    else
        enable_service
    fi
}

delete_settings() {
    read -p "Are you sure you want to reset all network optimization settings? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Reset cancelled.${NC}"; return; }
    reset_settings
    rm -f $STATUS_FILE
    echo -e "${RED}All optimizer settings and status removed.${NC}"
    sleep 1
}

show_live_log() {
    echo -e "${CYAN}Showing live log. Press Ctrl+C to exit.${NC}"
    sudo touch "$LOG_FILE"
    sudo tail -f "$LOG_FILE"
}

if [ "$1" = "--auto" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "No config file found at $CONFIG_FILE, waiting for configuration..."
        while [ ! -f "$CONFIG_FILE" ]; do sleep 10; done
    fi
    . "$CONFIG_FILE"
    IFACE=$(get_main_interface)
    DST="$DST"
    INTERVAL="$INTERVAL"
    JUMBO="$JUMBO"
    FORCE="$FORCE"
    echo "enabled" > $STATUS_FILE

    # لاگ‌گیری زنده
    exec > >(tee -a "$LOG_FILE") 2>&1

    while true; do
        if [ "$JUMBO" = "y" ] || [ "$JUMBO" = "Y" ]; then
            if [ "$FORCE" = "y" ] || [ "$FORCE" = "Y" ]; then
                MTU=9000
                MSS=$(calc_mss $MTU)
                apply_settings $IFACE $MTU $MSS
            else
                if test_jumbo_supported "$IFACE"; then
                    MTU=9000
                    if ping -I "$IFACE" -M do -s $((MTU-28)) -c 1 -W 1 "$DST" >/dev/null 2>&1; then
                        MSS=$(calc_mss $MTU)
                        apply_settings $IFACE $MTU $MSS
                    else
                        goto_normal_mtu "$IFACE" "$DST"
                    fi
                else
                    goto_normal_mtu "$IFACE" "$DST"
                fi
            fi
        else
            goto_normal_mtu "$IFACE" "$DST"
        fi
        for ((i=0; i<$INTERVAL; i++)); do
            [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
            sleep 1
        done
        [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
    done
    exit 0
fi

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
    echo "  4) Show Live Log"
    echo "  5) Uninstall MTUSO Completely"
    echo "  6) Exit"
    show_status
    read -p "Choose an option [1-6]: " CHOICE
    case $CHOICE in
        1) configure_settings ;;
        2) enable_disable_service ;;
        3) delete_settings ;;
        4) show_live_log ;;
        5) uninstall_all ;;
        6) echo "Bye!"; exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}"; sleep 1 ;;
    esac
done

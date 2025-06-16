#!/bin/bash

# MTUSO Installer & Launcher (Modern Status Display)
# Author: Shellgate Copilot

set -e

SCRIPT_URL="https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/mtuso.sh"
SCRIPT_PATH="/usr/local/bin/mtuso"
SYSTEMD_SERVICE="/etc/systemd/system/mtuso.service"
STATUS_FILE="/tmp/.smart_mtu_mss_status"

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# --- Status Logic ---
get_status() {
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo -e "Status: ${RED}NOT INSTALLED${NC}"
        return 1
    fi

    local SYS_STATUS
    SYS_STATUS=$(systemctl is-enabled mtuso 2>/dev/null || echo "disabled")
    local RUN_STATUS
    RUN_STATUS=$(systemctl is-active mtuso 2>/dev/null || echo "inactive")
    local APP_STATUS=""
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
        APP_STATUS="${YELLOW}ENABLED (NOT RUNNING)${NC}"
    else
        APP_STATUS="${RED}DISABLED${NC}"
    fi
    echo -e "Status: $APP_STATUS"
}

# --- Install Dependencies ---
install_deps() {
    echo -e "${CYAN}[MTUSO] Installing dependencies...${NC}"
    sudo apt-get update -y
    sudo apt-get install -y iproute2 net-tools bc curl
}

# --- Download/Update Script ---
install_script() {
    echo -e "${CYAN}[MTUSO] Downloading/updating main script...${NC}"
    sudo curl -L "$SCRIPT_URL" -o "$SCRIPT_PATH"
    sudo chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}[MTUSO] The command ${CYAN}mtuso${GREEN} is now available globally!${NC}"
}

# --- Setup Systemd Service ---
setup_service() {
    cat <<EOF | sudo tee "$SYSTEMD_SERVICE" >/dev/null
[Unit]
Description=MTU Smart Optimizer Service
After=network-online.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH --auto
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable mtuso
    sudo systemctl start mtuso
    echo -e "${GREEN}[MTUSO] Service enabled and started.${NC}"
}

# --- Uninstall Everything ---
uninstall_all() {
    echo -e "${RED}[MTUSO] Removing service and script...${NC}"
    sudo systemctl stop mtuso || true
    sudo systemctl disable mtuso || true
    sudo rm -f "$SYSTEMD_SERVICE"
    sudo rm -f "$SCRIPT_PATH"
    sudo systemctl daemon-reload
    echo -e "${GREEN}[MTUSO] Uninstall complete.${NC}"
}

# --- Disable Service (but keep installed) ---
disable_service() {
    sudo systemctl stop mtuso || true
    sudo systemctl disable mtuso || true
    echo -e "${RED}[MTUSO] Service stopped and disabled.${NC}"
}

# --- Enable/Start Service ---
enable_service() {
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo -e "${RED}[MTUSO] Script not installed, please install first.${NC}"
        return 1
    fi
    setup_service
}

# --- Main Menu ---
main_menu() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║         MTU Smart Optimizer (mtuso)             ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    get_status
    echo "  1) Install/Update MTUSO"
    echo "  2) Enable & Start Auto Optimization"
    echo "  3) Disable & Stop Optimization"
    echo "  4) Uninstall MTUSO"
    echo "  5) Exit"
}

# --- Process Menu Choice ---
process_choice() {
    read -p "Choose an option [1-5]: " CHOICE
    case $CHOICE in
        1)
            install_deps
            install_script
            ;;
        2)
            enable_service
            ;;
        3)
            disable_service
            ;;
        4)
            uninstall_all
            exit 0
            ;;
        5)
            echo "Bye!"
            exit 0
            ;;
        *)
            echo "Invalid option!"
            ;;
    esac
    sleep 1
}

# --- Main Logic ---
if [ "$1" = "--uninstall" ]; then
    uninstall_all
    exit 0
fi

while true; do
    main_menu
    process_choice
done

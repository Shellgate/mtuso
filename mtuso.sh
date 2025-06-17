#!/bin/bash

# MTUSO - Smart MTU/MSS Optimizer (Ultra Improved Version, English)
# Author: Shellgate | Last Update: 2025-06-17

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
COMMENT="MTUSO"
LOCK_FILE="/tmp/mtuso.lock"
FAIL_COUNT_FILE="/tmp/.mtuso_failcount"
MAX_FAILS=5

# --- Prevent concurrent runs ---
exec 200>"$LOCK_FILE"
flock -n 200 || { echo -e "${YELLOW}Another instance of MTUSO is already running. Exiting.${NC}"; exit 1; }

# --- Check dependencies ---
for tool in ip ethtool tracepath ping bc logger tee flock; do
    command -v $tool >/dev/null 2>&1 || { echo -e "${RED}[ERROR] $tool not found! Please install it.${NC}"; exit 1; }
done

# --- Check root/sudo access ---
if [[ $EUID -ne 0 ]]; then
    if ! sudo -v 2>/dev/null; then
        echo -e "${RED}This script requires sudo privileges! Run as root or use sudo.${NC}"
        exit 1
    fi
fi

# --- Helper functions ---
prompt_yesno() {
    while true; do
        read -p "$1 (y/n): " yn
        case "$yn" in
            [Yy]) echo "y"; return 0;;
            [Nn]) echo "n"; return 1;;
            *) echo -e "${YELLOW}Please answer y or n.${NC}";;
        esac
    done
}

prompt_menu() {
    local CHOICE
    while true; do
        read -p "$1" CHOICE
        [[ "$CHOICE" =~ ^[0-9]+$ ]] && echo "$CHOICE" && return 0
        echo -e "${YELLOW}Please enter a valid number.${NC}"
    done
}

log_msg() {
    # $1: level | $2: message
    local lvl="$1"
    local msg="$2"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$lvl] $ts: $msg" | tee -a "$LOG_FILE" | logger -t MTUSO
}

suggest_logrotate() {
    if [ ! -e /etc/logrotate.d/mtuso ]; then
        echo -e "${YELLOW}Tip: Consider adding the following to /etc/logrotate.d/mtuso for automatic log rotation:${NC}"
        echo -e "/var/log/mtuso.log { weekly rotate 4 compress missingok notifempty create 600 root root }"
    fi
}

show_live_log()    { echo -e "${CYAN}Live log (Ctrl+C to exit):${NC}"; sudo touch "$LOG_FILE"; sudo tail -f "$LOG_FILE"; }
clear_log() {
    if prompt_yesno "Are you sure you want to clear the log file?"; then
        sudo systemctl stop mtuso 2>/dev/null
        sudo rm -f "$LOG_FILE"
        sudo systemctl start mtuso 2>/dev/null
        log_msg "INFO" "Log file cleared."
    fi
}
show_journal_log() { echo -e "${CYAN}Systemd journal (Ctrl+C to exit):${NC}"; sudo journalctl -u mtuso -f; }

install_deps() {
    echo -e "${CYAN}Installing dependencies...${NC}"
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -y
        sudo apt-get install -y iproute2 net-tools bc curl ethtool tracepath logger flock
    elif command -v yum &>/dev/null; then
        sudo yum install -y iproute net-tools bc curl ethtool iputils-tracepath util-linux
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y iproute net-tools bc curl ethtool iputils util-linux
    else
        log_msg "ERROR" "No supported package manager found! Please install dependencies manually."
        exit 1
    fi
    echo -e "${GREEN}Dependencies installed.${NC}"
}

self_install() {
    echo -e "${CYAN}Installing MTUSO script...${NC}"
    sudo curl -fsSL "$SELF_URL" -o "$INSTALL_PATH"
    sudo chmod +x "$INSTALL_PATH"
    sudo chown root:root "$INSTALL_PATH"
    echo -e "${GREEN}MTUSO installed to $INSTALL_PATH${NC}"
    sleep 1
}

setup_service() {
    # Only overwrite the systemd unit file if contents have changed
    local TMPFILE="/tmp/.mtuso.service.tmp"
    cat <<EOF > "$TMPFILE"
[Unit]
Description=MTU Smart Optimizer Service
After=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH --auto
Restart=on-failure
RestartSec=60
StartLimitBurst=3
StartLimitIntervalSec=600

[Install]
WantedBy=multi-user.target
EOF
    if [ ! -f "$SYSTEMD_SERVICE" ] || ! cmp -s "$TMPFILE" "$SYSTEMD_SERVICE"; then
        sudo mv "$TMPFILE" "$SYSTEMD_SERVICE"
        sudo systemctl daemon-reload
        log_msg "INFO" "Systemd service file created/updated."
    else
        rm -f "$TMPFILE"
        log_msg "INFO" "Systemd service file unchanged."
    fi
}

enable_service() {
    setup_service
    sudo systemctl enable mtuso
    sudo systemctl restart mtuso
    log_msg "INFO" "MTUSO service enabled and started."
    sleep 1
}

disable_service() {
    sudo systemctl stop mtuso || true
    sudo systemctl disable mtuso || true
    log_msg "WARN" "MTUSO service stopped and disabled."
    sleep 1
}

restart_service() {
    sudo systemctl restart mtuso
    log_msg "INFO" "MTUSO service restarted."
    sleep 1
}

show_status() {
    if [ ! -f "$INSTALL_PATH" ]; then echo -e "Status: ${RED}NOT INSTALLED${NC}"; return; fi
    SYS_STATUS=$(systemctl is-enabled mtuso 2>/dev/null || echo "disabled")
    RUN_STATUS=$(systemctl is-active mtuso 2>/dev/null || echo "inactive")
    echo -n "Service: "
    if [ "$SYS_STATUS" = "enabled" ] && [ "$RUN_STATUS" = "active" ]; then
        echo -e "${GREEN}ENABLED & RUNNING${NC}"
    elif [ "$SYS_STATUS" = "enabled" ]; then
        echo -e "${YELLOW}ENABLED, but NOT RUNNING${NC}"
    else
        echo -e "${YELLOW}INSTALLED, but DISABLED${NC}"
    fi
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
        MTU=$(ip link show "$IFACE" 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}')
        MSS=$(sudo iptables -t mangle -S FORWARD | grep -- "--set-mss" | grep "$COMMENT" | awk '{for(i=1;i<=NF;i++){if($i=="--set-mss"){print $(i+1);break}}}' | head -n1)
        echo -e "Current Interface: ${CYAN}$IFACE${NC}  MTU: ${CYAN}${MTU:-unknown}${NC}  MSS: ${CYAN}${MSS:-unknown}${NC}"
    fi
}

show_service_status() {
    echo -e "${CYAN}Systemd service status:${NC}"
    sudo systemctl status mtuso --no-pager
}

get_all_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v lo
}
choose_interface() {
    local interfaces; IFS=$'\n' read -rd '' -a interfaces <<<"$(get_all_interfaces)"
    if [ "${#interfaces[@]}" -eq 1 ]; then
        echo "${interfaces[0]}"
    else
        echo -e "${CYAN}Available network interfaces:${NC}"
        for idx in "${!interfaces[@]}"; do echo "  $((idx+1))) ${interfaces[$idx]}"; done
        while true; do
            prompt_menu "Choose interface [1-${#interfaces[@]}]: "
            read CHOICE
            if [[ "$CHOICE" =~ ^[1-9][0-9]*$ ]] && [ "$CHOICE" -le "${#interfaces[@]}" ]; then
                echo "${interfaces[$((CHOICE-1))]}"
                break
            else
                echo -e "${YELLOW}Invalid choice.${NC}"
            fi
        done
    fi
}

check_iface_health() {
    local IFACE="$1"
    ip link show "$IFACE" | grep -q "state UP" || { log_msg "ERROR" "Interface $IFACE is down"; exit 1; }
}

check_jumbo_ethtool() {
    local IFACE="$1"
    if ethtool "$IFACE" 2>/dev/null | grep -qi jumbo; then
        return 0
    else
        return 1
    fi
}

validate_ip_or_host() {
    local DST="$1"
    if [[ "$DST" =~ ":" ]]; then
        ping6 -c1 -W1 "$DST" >/dev/null 2>&1
    else
        ping -c1 -W1 "$DST" >/dev/null 2>&1
    fi
    [ $? -eq 0 ] && return 0 || { log_msg "ERROR" "Invalid IP address or hostname."; return 1; }
}

parse_duration() {
    local input="$1" total=0 rest="$input" matched=0
    while [[ -n "$rest" ]]; do
        if [[ $rest =~ ^([0-9]+)[hH](.*) ]]; then total=$((total + ${BASH_REMATCH[1]} * 3600)); rest="${BASH_REMATCH[2]}"; matched=1
        elif [[ $rest =~ ^([0-9]+)[mM](.*) ]]; then total=$((total + ${BASH_REMATCH[1]} * 60)); rest="${BASH_REMATCH[2]}"; matched=1
        elif [[ $rest =~ ^([0-9]+)[sS](.*) ]]; then total=$((total + ${BASH_REMATCH[1]})); rest="${BASH_REMATCH[2]}"; matched=1
        elif [[ $rest =~ ^([0-9]+)(.*) ]]; then total=$((total + ${BASH_REMATCH[1]})); rest="${BASH_REMATCH[2]}"; matched=1
        else break; fi
        rest="${rest#"${rest%%[![:space:]]*}"}"
    done
    [[ $matched -eq 1 ]] && echo $total || echo 0
}

test_mtu() {
    local IFACE=$1 DST=$2 MTU
    if command -v tracepath >/dev/null 2>&1; then
        MTU=$(tracepath -n "$DST" 2>/dev/null | grep -m1 mtu | awk '{print $5}')
        [[ -z "$MTU" ]] && MTU=1500
        log_msg "INFO" "MTU detected with tracepath: $MTU"
        echo "$MTU"
        return 0
    else
        local MIN_MTU=1300 MAX_MTU=1500 BEST_MTU=$MIN_MTU original_mtu
        original_mtu=$(ip link show "$IFACE" | grep -o 'mtu [0-9]*' | awk '{print $2}')
        sudo ip link set dev "$IFACE" mtu $MAX_MTU
        if [[ "$DST" =~ ":" ]]; then
            ping6 -I "$IFACE" -c 1 -W 1 "$DST" >/dev/null 2>&1 || { log_msg "WARN" "$IFACE cannot reach $DST. Skipping."; sudo ip link set dev "$IFACE" mtu $original_mtu; return 1; }
            for ((MTU=$MAX_MTU; MTU>=$MIN_MTU; MTU-=10)); do
                if ping6 -I "$IFACE" -M do -s $((MTU-48)) -c 1 -W 1 "$DST" >/dev/null 2>&1; then BEST_MTU=$MTU; break; fi
            done
        else
            ping -I "$IFACE" -c 1 -W 1 "$DST" >/dev/null 2>&1 || { log_msg "WARN" "$IFACE cannot reach $DST. Skipping."; sudo ip link set dev "$IFACE" mtu $original_mtu; return 1; }
            for ((MTU=$MAX_MTU; MTU>=$MIN_MTU; MTU-=10)); do
                if ping -I "$IFACE" -M do -s $((MTU-28)) -c 1 -W 1 "$DST" >/dev/null 2>&1; then BEST_MTU=$MTU; break; fi
            done
        fi
        sudo ip link set dev "$IFACE" mtu $original_mtu
        log_msg "INFO" "MTU detected with ping: $BEST_MTU"
        echo $BEST_MTU
        return 0
    fi
}

test_jumbo_supported() {
    local IFACE=$1
    check_jumbo_ethtool "$IFACE" || { log_msg "WARN" "Jumbo not supported by ethtool"; return 1; }
    local ORIG_MTU
    ORIG_MTU=$(ip link show "$IFACE" | grep -o 'mtu [0-9]*' | awk '{print $2}')
    sudo ip link set dev "$IFACE" up
    sudo ip link set dev "$IFACE" mtu 9000 2>/dev/null && { sudo ip link set dev "$IFACE" mtu "$ORIG_MTU"; log_msg "INFO" "Jumbo test success"; return 0; } || { log_msg "WARN" "Jumbo test failed"; return 1; }
}

calc_mss() { local MTU=$1; [[ "$MTU" -ge 1280 ]] && echo $((MTU-40)) || echo $((MTU-48)); }

iptables_add_tcpmss() {
    local MSS=$1
    sudo iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS -m comment --comment "$COMMENT" 2>/dev/null || \
    sudo iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS -m comment --comment "$COMMENT"
}

iptables_del_tcpmss() {
    for chain in FORWARD INPUT OUTPUT; do
        while sudo iptables -t mangle -C $chain -p tcp --tcp-flags SYN,RST SYN -j TCPMSS -m comment --comment "$COMMENT" 2>/dev/null; do
            sudo iptables -t mangle -D $chain -p tcp --tcp-flags SYN,RST SYN -j TCPMSS -m comment --comment "$COMMENT"
        done
    done
}

apply_settings() {
    local IFACE=$1 MTU=$2 MSS=$3 DST=$4
    local ORIG_MTU; ORIG_MTU=$(ip link show "$IFACE" | grep -o 'mtu [0-9]*' | awk '{print $2}')
    sudo ip link set dev $IFACE mtu $MTU
    if [[ "$DST" =~ ":" ]]; then
        ping6 -I "$IFACE" -c 1 -W 1 "$DST" >/dev/null 2>&1 || { sudo ip link set dev $IFACE mtu $ORIG_MTU; log_msg "ERROR" "MTU change broke connectivity. Reverted."; return 1; }
    else
        ping -I "$IFACE" -c 1 -W 1 "$DST" >/dev/null 2>&1 || { sudo ip link set dev $IFACE mtu $ORIG_MTU; log_msg "ERROR" "MTU change broke connectivity. Reverted."; return 1; }
    fi
    iptables_del_tcpmss
    iptables_add_tcpmss "$MSS"
    log_msg "INFO" "Applied MTU $MTU & MSS $MSS on $IFACE"
    return 0
}

run_once() {
    if [ ! -f "$CONFIG_FILE" ]; then log_msg "WARN" "No configuration found. Please configure first."; configure_settings; [ ! -f "$CONFIG_FILE" ] && return; fi
    . "$CONFIG_FILE"
    IFACE="$IFACE"; check_iface_health "$IFACE"
    DST="$DST"
    exec > >(tee -a "$LOG_FILE") 2>&1
    if [ "$JUMBO" = "y" ] || [ "$JUMBO" = "Y" ]; then
        if [ "$FORCE" = "y" ] || [ "$FORCE" = "Y" ]; then
            MTU=9000; MSS=$(calc_mss $MTU)
            log_msg "INFO" "Force applying Jumbo Frame MTU=$MTU and MSS=$MSS on $IFACE"
            apply_settings $IFACE $MTU $MSS "$DST"
            if [[ "$DST" =~ ":" ]]; then
                ping6 -I "$IFACE" -M do -s $((MTU-48)) -c 1 -W 1 "$DST" >/dev/null 2>&1 || log_msg "WARN" "Forced Jumbo Frame may not work to $DST"
            else
                ping -I "$IFACE" -M do -s $((MTU-28)) -c 1 -W 1 "$DST" >/dev/null 2>&1 || log_msg "WARN" "Forced Jumbo Frame may not work to $DST"
            fi
        else
            if test_jumbo_supported "$IFACE"; then
                MTU=9000
                if [[ "$DST" =~ ":" ]]; then
                    if ping6 -I "$IFACE" -M do -s $((MTU-48)) -c 1 -W 1 "$DST" >/dev/null 2>&1; then
                        MSS=$(calc_mss $MTU)
                        log_msg "INFO" "Applying Jumbo Frame MTU=$MTU and MSS=$MSS on $IFACE"
                        apply_settings $IFACE $MTU $MSS "$DST"
                    else
                        log_msg "WARN" "Jumbo Frame not working to $DST. Falling back."
                        goto_normal_mtu "$IFACE" "$DST"
                    fi
                else
                    if ping -I "$IFACE" -M do -s $((MTU-28)) -c 1 -W 1 "$DST" >/dev/null 2>&1; then
                        MSS=$(calc_mss $MTU)
                        log_msg "INFO" "Applying Jumbo Frame MTU=$MTU and MSS=$MSS on $IFACE"
                        apply_settings $IFACE $MTU $MSS "$DST"
                    else
                        log_msg "WARN" "Jumbo Frame not working to $DST. Falling back."
                        goto_normal_mtu "$IFACE" "$DST"
                    fi
                fi
            else
                log_msg "WARN" "Jumbo Frame not supported by $IFACE. Falling back."
                goto_normal_mtu "$IFACE" "$DST"
            fi
        fi
    else
        goto_normal_mtu "$IFACE" "$DST"
    fi
    log_msg "INFO" "One-time optimization finished."
    read -p "Press Enter to continue..."
}

goto_normal_mtu() {
    local IFACE DST MTU MSS
    IFACE="$1"; DST="$2"
    MTU=$(test_mtu $IFACE $DST)
    if [ $? -ne 0 ]; then
        log_msg "ERROR" "Could not detect safe MTU. Skipping..."
    else
        log_msg "INFO" "Optimal MTU detected: $MTU"
        MSS=$(calc_mss $MTU)
        log_msg "INFO" "Applying MTU=$MTU MSS=$MSS on $IFACE"
        apply_settings $IFACE $MTU $MSS "$DST"
    fi
}

run_optimization() {
    if [ ! -f "$CONFIG_FILE" ]; then log_msg "WARN" "No configuration found. Please configure first."; configure_settings; [ ! -f "$CONFIG_FILE" ] && return; fi
    . "$CONFIG_FILE"
    IFACE="$IFACE"; check_iface_health "$IFACE"
    DST="$DST"; INTERVAL="$INTERVAL"; JUMBO="$JUMBO"; FORCE="$FORCE"
    echo "enabled" > $STATUS_FILE; exec > >(tee -a "$LOG_FILE") 2>&1; sudo chmod 600 "$LOG_FILE" 2>/dev/null
    [[ ! -e "$FAIL_COUNT_FILE" ]] && echo 0 > "$FAIL_COUNT_FILE"
    local failcount
    while [ "$(cat $STATUS_FILE 2>/dev/null)" == "enabled" ]; do
        failcount=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
        if [ "$failcount" -ge "$MAX_FAILS" ]; then
            log_msg "ERROR" "Optimization failed $failcount times, pausing."
            echo "paused" > $STATUS_FILE
            break
        fi
        if [ "$JUMBO" = "y" ] || [ "$JUMBO" = "Y" ]; then
            if [ "$FORCE" = "y" ] || [ "$FORCE" = "Y" ]; then
                MTU=9000; MSS=$(calc_mss $MTU)
                log_msg "INFO" "Force applying Jumbo Frame MTU=$MTU MSS=$MSS on $IFACE"
                apply_settings $IFACE $MTU $MSS "$DST" || { failcount=$((failcount+1)); echo $failcount > "$FAIL_COUNT_FILE"; continue; }
            else
                if test_jumbo_supported "$IFACE"; then
                    MTU=9000
                    if [[ "$DST" =~ ":" ]]; then
                        if ping6 -I "$IFACE" -M do -s $((MTU-48)) -c 1 -W 1 "$DST" >/dev/null 2>&1; then
                            MSS=$(calc_mss $MTU)
                            log_msg "INFO" "Applying Jumbo Frame MTU=$MTU and MSS=$MSS on $IFACE"
                            apply_settings $IFACE $MTU $MSS "$DST" || { failcount=$((failcount+1)); echo $failcount > "$FAIL_COUNT_FILE"; continue; }
                        else
                            log_msg "WARN" "Jumbo Frame not working to $DST. Falling back."
                            goto_normal_mtu "$IFACE" "$DST"
                        fi
                    else
                        if ping -I "$IFACE" -M do -s $((MTU-28)) -c 1 -W 1 "$DST" >/dev/null 2>&1; then
                            MSS=$(calc_mss $MTU)
                            log_msg "INFO" "Applying Jumbo Frame MTU=$MTU and MSS=$MSS on $IFACE"
                            apply_settings $IFACE $MTU $MSS "$DST" || { failcount=$((failcount+1)); echo $failcount > "$FAIL_COUNT_FILE"; continue; }
                        else
                            log_msg "WARN" "Jumbo Frame not working to $DST. Falling back."
                            goto_normal_mtu "$IFACE" "$DST"
                        fi
                    fi
                else
                    log_msg "WARN" "Jumbo Frame not supported by $IFACE. Falling back."
                    goto_normal_mtu "$IFACE" "$DST"
                fi
            fi
        else
            goto_normal_mtu "$IFACE" "$DST"
        fi
        echo 0 > "$FAIL_COUNT_FILE"
        for ((i=0; i<$INTERVAL; i++)); do [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break; sleep 1; done
        [ "$(cat $STATUS_FILE 2>/dev/null)" != "enabled" ] && break
    done
}

uninstall_all() {
    if prompt_yesno "Are you sure you want to uninstall MTUSO and remove all settings and logs?"; then
        sudo systemctl stop mtuso || true
        sudo systemctl disable mtuso || true
        sudo rm -f "$SYSTEMD_SERVICE" "$INSTALL_PATH" "$CONFIG_FILE" "$STATUS_FILE" "$LOG_FILE" "$FAIL_COUNT_FILE" "$LOCK_FILE"
        iptables_del_tcpmss
        sudo systemctl daemon-reload
        log_msg "INFO" "MTUSO uninstalled and all files removed."
        exit 0
    fi
}
reset_settings() {
    if prompt_yesno "Are you sure you want to reset all network optimization settings?"; then
        . "$CONFIG_FILE" 2>/dev/null
        [ -n "$IFACE" ] && sudo ip link set dev $IFACE mtu 1500
        iptables_del_tcpmss
        sudo rm -f "$CONFIG_FILE" "$LOG_FILE" "$FAIL_COUNT_FILE"
        log_msg "INFO" "All settings reset to default."
        sleep 1
    fi
}

configure_settings() {
    local IFACE DST INTERVAL_RAW INTERVAL JUMBO FORCE
    IFACE=$(choose_interface)
    check_iface_health "$IFACE"
    echo -e "${CYAN}Selected interface: $IFACE${NC}"
    while true; do
        read -p "Enter destination IP or domain for MTU test (e.g. 8.8.8.8): " DST
        if validate_ip_or_host "$DST"; then break; fi
    done
    while true; do
        read -p "Enter optimization interval (e.g. 60, 5m, 2h, 1h5m10s): " INTERVAL_RAW
        INTERVAL=$(parse_duration "$INTERVAL_RAW")
        [ "$INTERVAL" -ge 5 ] && break
        echo -e "${RED}Please enter a valid duration (>=5 seconds)!${NC}"
    done
    JUMBO=$(prompt_yesno "Enable Jumbo Frame (MTU 9000) for $IFACE?")
    FORCE="n"
    if [[ "$JUMBO" == "y" ]]; then
        FORCE=$(prompt_yesno "Force Jumbo Frame even if not supported or ping fails?")
    fi
    sudo tee "$CONFIG_FILE" >/dev/null <<EOF
IFACE=$IFACE
DST=$DST
INTERVAL=$INTERVAL
JUMBO=$JUMBO
FORCE=$FORCE
EOF
    sudo chmod 600 "$CONFIG_FILE"
    log_msg "INFO" "Configuration saved to $CONFIG_FILE"
}

enable_disable_service() {
    if [ ! -f "$CONFIG_FILE" ]; then log_msg "WARN" "You must configure optimization first."; configure_settings; [ ! -f "$CONFIG_FILE" ] && return; fi
    SYS_STATUS=$(systemctl is-enabled mtuso 2>/dev/null || echo "disabled")
    RUN_STATUS=$(systemctl is-active mtuso 2>/dev/null || echo "inactive")
    if [ "$SYS_STATUS" = "enabled" ] && [ "$RUN_STATUS" = "active" ]; then
        disable_service
    else
        enable_service
    fi
}

run_dry() {
    if [ ! -f "$CONFIG_FILE" ]; then log_msg "WARN" "No configuration found. Please configure first."; configure_settings; [ ! -f "$CONFIG_FILE" ] && return; fi
    . "$CONFIG_FILE"
    echo -e "${CYAN}DRY-RUN: The following steps would be performed:${NC}"
    echo "- Interface: $IFACE"
    echo "- Destination: $DST"
    echo "- Interval: $INTERVAL"
    echo "- Jumbo: $JUMBO"
    echo "- Force: $FORCE"
    echo "- Would check link, check jumbo support (ethtool), test MTU (tracepath), and apply iptables rule with comment '$COMMENT'."
    echo "- Would log to $LOG_FILE and systemd journal."
    read -p "Press Enter to continue..."
}

# --- Main menu ---
suggest_logrotate

if [ "$1" = "--auto" ]; then run_optimization; exit 0; fi

while true; do
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════╗"
    echo "║      MTUSO - Smart MTU/MSS Optimizer          ║"
    echo "╚════════════════════════════════════════════════╝"
    echo -e "${NC}"
    show_status
    echo "  1) Configure & Start Optimization (set parameters and begin optimizing)"
    echo "  2) Enable/Disable Service (start/stop systemd service)"
    echo "  3) Show Service Status (view current systemd status)"
    echo "  4) Reset All Settings (reset config and revert changes)"
    echo "  5) Show Live Log (tail file log in real time)"
    echo "  6) Clear Log File (delete /var/log/mtuso.log)"
    echo "  7) Show Journalctl Log (systemd logs)"
    echo "  8) Run One-Time Optimization Now (no service, just once)"
    echo "  9) Dry-run (simulate all changes, no apply)"
    echo " 10) Restart Service (systemd restart)"
    echo " 11) Uninstall MTUSO Completely (remove all traces)"
    echo " 12) Exit"
    prompt_menu "Choose an option [1-12]: "
    read CHOICE
    case $CHOICE in
        1) configure_settings; show_status; read -p "Press Enter to continue...";;
        2) enable_disable_service; show_status; read -p "Press Enter to continue...";;
        3) show_service_status; read -p "Press Enter to continue...";;
        4) reset_settings; show_status; read -p "Press Enter to continue...";;
        5) show_live_log ;;
        6) clear_log ;;
        7) show_journal_log ;;
        8) run_once ;;
        9) run_dry ;;
        10) restart_service; show_status; read -p "Press Enter to continue...";;
        11) uninstall_all ;;
        12) echo "Bye!"; exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}"; sleep 1 ;;
    esac
done

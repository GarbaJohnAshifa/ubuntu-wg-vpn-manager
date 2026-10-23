#!/usr/bin/env bash

# ==========================================
#        WIREGUARD VPN MANAGER
# ==========================================

set -u

INTERFACE="wg0"
CONFIG="/etc/wireguard/${INTERFACE}.conf"
BACKUP_DIR="/etc/wireguard/backups"

# Require root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Please run this script with sudo:"
    echo "sudo bash $0"
    exit 1
fi

# Check required commands
for cmd in wg wg-quick ip curl systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd"
        exit 1
    fi
done

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

pause() {
    echo
    read -r -p "Press Enter to continue..."
}

vpn_is_up() {
    ip link show dev "$INTERFACE" >/dev/null 2>&1
}

backup_config() {
    if [[ ! -f "$CONFIG" ]]; then
        echo "Configuration file not found: $CONFIG"
        return 1
    fi

    local backup
    backup="$BACKUP_DIR/${INTERFACE}-$(date +%Y%m%d-%H%M%S).conf"

    if cp -p "$CONFIG" "$backup"; then
        chmod 600 "$backup"
        echo "Backup created: $backup"
    else
        echo "ERROR: Could not create backup."
        return 1
    fi
}

connect_vpn() {
    if vpn_is_up; then
        echo "VPN interface $INTERFACE is already up."
        return
    fi

    if [[ ! -f "$CONFIG" ]]; then
        echo "Configuration not found: $CONFIG"
        return
    fi

    echo "Connecting to WireGuard..."

    if wg-quick up "$INTERFACE"; then
        echo "VPN interface started."
        show_status
    else
        echo "ERROR: Connection failed."
        echo "Check the configuration and system logs."
    fi
}

disconnect_vpn() {
    if ! vpn_is_up; then
        echo "VPN interface is already down."
        return
    fi

    echo "Disconnecting from WireGuard..."

    if wg-quick down "$INTERFACE"; then
        echo "VPN disconnected."
    else
        echo "ERROR: Could not disconnect cleanly."
    fi
}

restart_vpn() {
    if ! vpn_is_up; then
        echo "VPN is down. Attempting to connect..."
        connect_vpn
        return
    fi

    echo "Restarting WireGuard..."

    if wg-quick down "$INTERFACE"; then
        connect_vpn
    else
        echo "ERROR: Could not stop the interface."
        echo "Not attempting to start a second interface."
    fi
}

show_status() {
    echo
    echo "========== VPN STATUS =========="

    if vpn_is_up; then
        echo "Interface: UP"
        wg show "$INTERFACE"
    else
        echo "Interface: DOWN"
    fi

    echo
    echo "========== SYSTEMD SERVICE =========="

    systemctl is-enabled "wg-quick@${INTERFACE}" 2>/dev/null \
        || true

    systemctl is-active "wg-quick@${INTERFACE}" 2>/dev/null \
        || true
}

show_public_ip() {
    echo "Public IPv4:"
    curl -4 --connect-timeout 5 --max-time 10 \
        -fsS https://icanhazip.com \
        || echo "IPv4 lookup failed."

    echo
    echo "Public IPv6:"
    curl -6 --connect-timeout 5 --max-time 10 \
        -fsS https://icanhazip.com \
        || echo "IPv6 unavailable or lookup failed."

    echo
    echo "Compare the results with the VPN disconnected."
}

show_interface() {
    echo "========== INTERFACE =========="

    if vpn_is_up; then
        ip addr show dev "$INTERFACE"
        echo
        wg show "$INTERFACE"
    else
        echo "Interface $INTERFACE is down."
    fi
}

show_routes() {
    echo "========== IPv4 ROUTES =========="
    ip route show

    echo
    echo "========== IPv6 ROUTES =========="
    ip -6 route show

    echo
    echo "========== POLICY RULES =========="
    ip rule show
}

update_config() {
    local source candidate backup was_up

    echo "========== UPDATE CONFIGURATION =========="
    echo "Current configuration: $CONFIG"
    echo
    echo "Enter the full path to the new .conf file."
    read -r -p "New configuration path: " source

    # Remove optional surrounding quotes.
    source="${source%\"}"
    source="${source#\"}"
    source="${source%\'}"
    source="${source#\'}"

    if [[ ! -f "$source" || ! -r "$source" ]]; then
        echo "ERROR: File does not exist or is unreadable."
        return
    fi

    if [[ "$source" == "$CONFIG" ]]; then
        echo "ERROR: Choose a new file, not the installed configuration."
        return
    fi

    if ! grep -q '^\[Interface\]' "$source" ||
       ! grep -q '^\[Peer\]' "$source"; then
        echo "ERROR: Expected [Interface] and [Peer] sections."
        return
    fi

    candidate=$(mktemp /etc/wireguard/.wg0-candidate.XXXXXX) || {
        echo "ERROR: Could not create temporary configuration."
        return
    }

    if ! install -o root -g root -m 600 "$source" "$candidate"; then
        rm -f "$candidate"
        echo "ERROR: Could not stage the new configuration."
        return
    fi

    # Validate WireGuard configuration syntax without displaying keys.
    if ! wg-quick strip "$candidate" >/dev/null; then
        echo "ERROR: Configuration validation failed."
        rm -f "$candidate"
        return
    fi

    if [[ -f "$CONFIG" ]]; then
        backup="$BACKUP_DIR/${INTERFACE}-$(date +%Y%m%d-%H%M%S).conf"

        if ! cp -p "$CONFIG" "$backup"; then
            echo "ERROR: Could not back up the current configuration."
            rm -f "$candidate"
            return
        fi

        chmod 600 "$backup"
        echo "Backup created: $backup"
    else
        echo "No existing configuration to back up."
    fi

    echo
    echo "New configuration passed basic syntax validation."
    read -r -p "Install this configuration? (y/N): " answer

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Update cancelled."
        rm -f "$candidate"
        return
    fi

    was_up=0
    if vpn_is_up; then
        was_up=1

        echo "Stopping the current VPN..."

        if ! wg-quick down "$INTERFACE"; then
            echo "ERROR: Could not stop the VPN."
            echo "The old configuration has not been replaced."
            rm -f "$candidate"
            return
        fi
    fi

    if ! mv -f "$candidate" "$CONFIG"; then
        echo "ERROR: Could not install the new configuration."
        return
    fi

    chown root:root "$CONFIG"
    chmod 600 "$CONFIG"

    if [[ "$was_up" -eq 1 ]]; then
        echo "Starting VPN with the new configuration..."

        if wg-quick up "$INTERFACE"; then
            echo "Configuration updated successfully."
            show_status
            return
        fi

        echo "ERROR: New configuration failed to start."
        echo "Attempting to restore the previous configuration..."

        if [[ -n "${backup:-}" && -f "$backup" ]]; then
            cp -p "$backup" "$CONFIG"
            chown root:root "$CONFIG"
            chmod 600 "$CONFIG"

            if wg-quick up "$INTERFACE"; then
                echo "Previous configuration restored."
            else
                echo "WARNING: Rollback completed, but VPN did not start."
                echo "Inspect the configuration and system logs."
            fi
        fi
    else
        echo "Configuration installed successfully."
        echo "VPN remains disconnected."
        echo "Select Connect to apply and test it."
    fi
}

restore_config() {
    local files selected

    echo "========== RESTORE CONFIGURATION =========="

    files=("$BACKUP_DIR"/*.conf)

    if [[ ! -f "${files[0]}" ]]; then
        echo "No backups found in $BACKUP_DIR"
        return
    fi

    echo "Available backups:"
    select selected in "${files[@]}"; do
        if [[ -n "${selected:-}" && -f "$selected" ]]; then
            break
        fi
        echo "Invalid selection."
    done

    echo
    echo "Selected backup: $selected"
    read -r -p "Restore this backup? (y/N): " answer

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Restore cancelled."
        return
    fi

    local was_up=0

    if vpn_is_up; then
        was_up=1

        if ! wg-quick down "$INTERFACE"; then
            echo "ERROR: Could not stop the VPN."
            return
        fi
    fi

    if [[ -f "$CONFIG" ]]; then
        local current_backup
        current_backup="$BACKUP_DIR/${INTERFACE}-before-restore-$(date +%Y%m%d-%H%M%S).conf"

        if ! cp -p "$CONFIG" "$current_backup"; then
            echo "ERROR: Could not back up the current configuration."
            return
        fi

        chmod 600 "$current_backup"
    fi

    if ! install -o root -g root -m 600 "$selected" "$CONFIG"; then
        echo "ERROR: Could not install the backup."
        return
    fi

    if ! wg-quick strip "$CONFIG" >/dev/null; then
        echo "ERROR: Restored configuration failed validation."
        echo "Inspect $CONFIG before reconnecting."
        return
    fi

    if [[ "$was_up" -eq 1 ]]; then
        connect_vpn
    else
        echo "Backup restored. VPN remains disconnected."
    fi
}

enable_startup() {
    systemctl enable "wg-quick@${INTERFACE}"
}

disable_startup() {
    systemctl disable "wg-quick@${INTERFACE}"
}

show_logs() {
    journalctl -u "wg-quick@${INTERFACE}" -n 50 --no-pager
}

main_menu() {
    while true; do
        clear

        echo "========================================"
        echo "        WIREGUARD VPN MANAGER"
        echo "========================================"
        echo " Interface: $INTERFACE"
        echo " Config:    $CONFIG"
        echo "----------------------------------------"
        echo " 1. Connect to VPN"
        echo " 2. Disconnect from VPN"
        echo " 3. Restart VPN"
        echo " 4. Check VPN status"
        echo " 5. Check public IP"
        echo " 6. Check interface and VPN IP"
        echo " 7. Check routing"
        echo " 8. Update configuration"
        echo " 9. Back up configuration"
        echo "10. Restore configuration"
        echo "11. Enable VPN at startup"
        echo "12. Disable VPN at startup"
        echo "13. View VPN logs"
        echo "14. Exit"
        echo "========================================"

        read -r -p "Select an option: " choice

        case "$choice" in
            1)  connect_vpn; pause ;;
            2)  disconnect_vpn; pause ;;
            3)  restart_vpn; pause ;;
            4)  show_status; pause ;;
            5)  show_public_ip; pause ;;
            6)  show_interface; pause ;;
            7)  show_routes; pause ;;
            8)  update_config; pause ;;
            9)  backup_config; pause ;;
            10) restore_config; pause ;;
            11) enable_startup; pause ;;
            12) disable_startup; pause ;;
            13) show_logs; pause ;;
            14) echo "Exiting WireGuard VPN Manager."; exit 0 ;;
            *)  echo "Invalid option."; pause ;;
        esac
    done
}

main_menu




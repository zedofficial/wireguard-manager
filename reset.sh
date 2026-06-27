#!/usr/bin/env bash
# =============================================================================
# reset.sh — WireGuard Manager Clean Reset
# Removes everything the installer created so you can run install.sh fresh.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'

[[ "$EUID" -ne 0 ]] && { echo -e "${RED}  Run as root: sudo bash reset.sh${RESET}"; exit 1; }

echo ""
echo -e "${YELLOW}${BOLD}  WireGuard Manager — Clean Reset${RESET}"
echo -e "  This will remove WireGuard and everything the installer created."
echo -e "  ${RED}All client keys, configs, and Docker containers will be permanently deleted.${RESET}"
echo ""
read -rp "  Type 'yes' to confirm: " confirm
[[ "${confirm}" != "yes" ]] && { echo "  Cancelled."; exit 0; }

echo ""

# ---- Stop and disable WireGuard ----
echo -e "${CYAN}  Stopping WireGuard...${RESET}"
systemctl stop    wg-quick@wg0 2>/dev/null || true
systemctl disable wg-quick@wg0 2>/dev/null || true
wg-quick down wg0              2>/dev/null || true
echo -e "${GREEN}  ✔ WireGuard stopped.${RESET}"

# ---- Remove Uptime Kuma Docker container and volume ----
if command -v docker &>/dev/null; then
    echo -e "${CYAN}  Removing Uptime Kuma container...${RESET}"
    docker stop  uptime-kuma 2>/dev/null || true
    docker rm    uptime-kuma 2>/dev/null || true
    docker volume rm uptime-kuma 2>/dev/null || true
    echo -e "${GREEN}  ✔ Uptime Kuma removed.${RESET}"

    echo -e "${CYAN}  Removing Docker...${RESET}"
    # Stop Docker cleanly first — this tears down veth interfaces
    systemctl stop docker       2>/dev/null || true
    systemctl stop docker.socket 2>/dev/null || true
    systemctl disable docker    2>/dev/null || true

    # Explicitly bring down and delete docker0 bridge
    ip link set docker0 down    2>/dev/null || true
    ip link delete docker0      2>/dev/null || true

    # Remove any lingering veth interfaces
    ip link show 2>/dev/null | grep -o 'veth[^ @]*' | while read -r veth; do
        ip link delete "${veth}" 2>/dev/null || true
    done

    # Remove Docker packages
    apt-get remove -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    apt-get remove -y docker docker.io docker-compose docker-doc \
        podman-docker 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true

    # Remove Docker data directories
    rm -rf /var/lib/docker
    rm -rf /var/lib/containerd
    rm -rf /etc/docker
    rm -f  /etc/apt/sources.list.d/docker.list
    rm -f  /etc/apt/keyrings/docker.gpg
    rm -f  /etc/apt/keyrings/docker.asc

    echo -e "${GREEN}  ✔ Docker removed.${RESET}"
else
    echo -e "  Docker not installed — skipping."
fi

# ---- Remove WireGuard packages ----
echo -e "${CYAN}  Removing WireGuard packages...${RESET}"
apt-get remove -y wireguard wireguard-tools 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
echo -e "${GREEN}  ✔ WireGuard packages removed.${RESET}"

# ---- Remove WireGuard config and client data ----
echo -e "${CYAN}  Removing /etc/wireguard/...${RESET}"
rm -rf /etc/wireguard
echo -e "${GREEN}  ✔ /etc/wireguard removed.${RESET}"

# ---- Remove WireGuard Manager data ----
echo -e "${CYAN}  Removing /opt/wireguard/...${RESET}"
rm -rf /opt/wireguard
echo -e "${GREEN}  ✔ /opt/wireguard removed.${RESET}"

# ---- Remove all wg-* commands ----
echo -e "${CYAN}  Removing client scripts...${RESET}"
rm -f /usr/local/bin/wg-add-client
rm -f /usr/local/bin/wg-delete-client
rm -f /usr/local/bin/wg-show-client
rm -f /usr/local/bin/wg-list-clients
rm -f /usr/local/bin/wg-disable-client
rm -f /usr/local/bin/wg-enable-client
rm -f /usr/local/bin/wg-rename-client
rm -f /usr/local/bin/wg-export-client
rm -f /usr/local/bin/wg-import-client
rm -f /usr/local/bin/wg-regen-qr
rm -f /usr/local/bin/wg-update
rm -f /usr/local/bin/wg-check-update
rm -f /usr/local/bin/wg-dashboard-passwd
rm -f /usr/local/bin/wg-reset
echo -e "${GREEN}  ✔ Scripts removed.${RESET}"

# ---- Remove cron jobs ----
echo -e "${CYAN}  Removing cron jobs...${RESET}"
rm -f /etc/cron.d/wireguard-ddns
rm -f /etc/cron.d/wireguard-backup
rm -f /etc/cron.d/wireguard-update-check
echo -e "${GREEN}  ✔ Cron jobs removed.${RESET}"

# ---- Remove sysctl config ----
echo -e "${CYAN}  Removing IP forwarding config...${RESET}"
rm -f /etc/sysctl.d/99-wireguard-manager.conf
sysctl -w net.ipv4.ip_forward=0 > /dev/null 2>&1 || true
echo -e "${GREEN}  ✔ sysctl config removed.${RESET}"

# ---- Remove sudoers entry ----
echo -e "${CYAN}  Removing sudoers entry...${RESET}"
rm -f /etc/sudoers.d/wireguard-manager
echo -e "${GREEN}  ✔ Sudoers entry removed.${RESET}"

# ---- Remove dashboard ----
if [[ -d /var/www/html/wireguard-manager ]]; then
    echo -e "${CYAN}  Removing PHP dashboard...${RESET}"
    rm -rf /var/www/html/wireguard-manager
    a2dissite wireguard-manager.conf > /dev/null 2>&1 || true
    rm -f /etc/apache2/sites-available/wireguard-manager.conf
    systemctl reload apache2 2>/dev/null || true
    echo -e "${GREEN}  ✔ Dashboard removed.${RESET}"
fi

# ---- Remove UFW rules (use the port in case profile varies) ----
if command -v ufw &>/dev/null; then
    echo -e "${CYAN}  Removing UFW rules...${RESET}"
    ufw delete allow 51820/udp > /dev/null 2>&1 || true
    ufw delete allow 80/tcp    > /dev/null 2>&1 || true
    ufw delete allow 443/tcp   > /dev/null 2>&1 || true
    ufw delete allow 3001/tcp  > /dev/null 2>&1 || true
    ufw delete allow 22/tcp    > /dev/null 2>&1 || true
    ufw delete allow OpenSSH   > /dev/null 2>&1 || true
    echo -e "${GREEN}  ✔ UFW rules removed.${RESET}"
fi

# ---- Remove logs ----
echo -e "${CYAN}  Removing logs...${RESET}"
rm -rf /var/log/wireguard-manager
echo -e "${GREEN}  ✔ Logs removed.${RESET}"

# ---- Done ----
echo ""
echo -e "${GREEN}${BOLD}  Reset complete. System is clean.${RESET}"
echo ""
echo -e "  Run the installer again:"
echo -e "  ${CYAN}sudo bash install.sh${RESET}"
echo ""

# ---- Self-delete ----
SCRIPT_PATH="$(realpath "$0")"
rm -f "${SCRIPT_PATH}"

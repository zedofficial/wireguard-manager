#!/usr/bin/env bash
# =============================================================================
# WireGuard Manager — install.sh
# =============================================================================
# Project   : WireGuard Manager
# Author    : ZED Official
# License   : MIT
# Description:
#   Interactive installer for WireGuard + client management scripts,
#   optional PHP dashboard, DuckDNS/No-IP/Cloudflare/Custom DDNS,
#   Uptime Kuma monitoring, and automatic backup scheduling.
#
#   Supports: Debian 12+, Ubuntu 22.04+, Raspberry Pi OS, Armbian
#   Architectures: amd64, arm64, armhf
# =============================================================================

set -euo pipefail

# =============================================================================
# CONSTANTS & PATHS
# =============================================================================

WGM_VERSION="1.0.0"
WGM_DIR="/opt/wireguard"
WGM_LOG_DIR="/var/log/wireguard-manager"
WGM_LOG_FILE="${WGM_LOG_DIR}/install.log"
WGM_CLIENTS_DIR="/etc/wireguard/clients"
WGM_DB="${WGM_DIR}/clients.db"
WGM_DDNS_DIR="${WGM_DIR}/ddns"
WGM_BACKUP_SCRIPT="${WGM_DIR}/backup.sh"
WG_CONF="/etc/wireguard/wg0.conf"
BIN_DIR="/usr/local/bin"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# =============================================================================
# LOGGING
# =============================================================================

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${timestamp} [${level}] ${msg}" >> "${WGM_LOG_FILE}"
}

log_info()    { log "INFO"    "$*"; }
log_warn()    { log "WARN"    "$*"; }
log_error()   { log "ERROR"   "$*"; }
log_success() { log "SUCCESS" "$*"; }

# =============================================================================
# PRINT HELPERS
# =============================================================================

print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════╗"
    printf "  ║%*s%s%*s║\n" 12 "" "WireGuard Manager  v${WGM_VERSION}" 13 ""
    printf "  ║%*s%s%*s║\n" 17 "" "by ZED Official" 18 ""
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# Used inside ask_* functions — shows the step without clearing the screen
# so the user can see all their previous answers at once.
print_question_header() {
    local step="$1"
    local total="$2"
    local title="$3"
    echo -e "\n${BLUE}${BOLD}  ── Step ${step} of ${total} — ${title}${RESET}"
    echo -e "  ────────────────────────────────────────────────"
}

print_step() {
    echo -e "\n${BLUE}${BOLD}──── $* ────${RESET}\n"
}

print_success() {
    echo -e "${GREEN}  ✔  $*${RESET}"
    log_success "$*"
}

print_warn() {
    echo -e "${YELLOW}  ⚠  $*${RESET}"
    log_warn "$*"
}

print_error() {
    echo -e "${RED}  ✖  $*${RESET}"
    log_error "$*"
}

print_info() {
    echo -e "${CYAN}  →  $*${RESET}"
    log_info "$*"
}

# Simple progress spinner
spinner() {
    local pid=$1
    local msg="${2:-Working...}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % ${#spin} ))
        printf "\r${CYAN}  ${spin:$i:1}  ${msg}${RESET}"
        sleep 0.1
    done
    printf "\r                                        \r"
}

# Progress bar (manual steps)
progress_bar() {
    local current=$1
    local total=$2
    local label="${3:-}"
    local pct=$(( current * 100 / total ))
    local filled=$(( current * 40 / total ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=filled; i<40; i++)); do bar+="░"; done
    printf "\r  ${CYAN}[${bar}] ${pct}%%  ${label}${RESET}"
}

# Pause and wait for Enter
pause() {
    echo -e "\n${YELLOW}  Press Enter to continue...${RESET}"
    read -r
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}${BOLD}  Error: This installer must be run as root.${RESET}"
        echo -e "  Run:  ${CYAN}sudo bash install.sh${RESET}\n"
        exit 1
    fi
}

check_not_piped() {
    # When piped through curl | bash, stdin is the pipe not the terminal.
    # read commands return immediately with empty strings, breaking the installer.
    if [[ ! -t 0 ]]; then
        echo ""
        echo -e "${RED}${BOLD}  Error: Do not pipe this installer directly into bash.${RESET}"
        echo ""
        echo -e "  Running ${CYAN}curl ... | sudo bash${RESET} breaks interactive prompts."
        echo -e "  Download the script first, then run it:\n"
        echo -e "  ${CYAN}curl -fsSL https://raw.githubusercontent.com/zedofficial/wireguard-manager/main/install.sh -o install.sh${RESET}"
        echo -e "  ${CYAN}sudo bash install.sh${RESET}"
        echo ""
        exit 1
    fi
}

check_os() {
    print_step "Checking System Compatibility"

    if [[ ! -f /etc/os-release ]]; then
        print_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    source /etc/os-release

    OS_ID="${ID}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-unknown}"
    ARCH="$(uname -m)"

    print_info "Detected OS   : ${OS_NAME}"
    print_info "Architecture  : ${ARCH}"

    case "${OS_ID}" in
        debian|ubuntu|raspbian|armbian) ;;
        *)
            print_error "Unsupported OS: ${OS_ID}. Supported: Debian, Ubuntu, Raspberry Pi OS, Armbian."
            exit 1
            ;;
    esac

    case "${ARCH}" in
        x86_64|aarch64|armv7l) ;;
        *)
            print_error "Unsupported architecture: ${ARCH}."
            exit 1
            ;;
    esac

    print_success "OS and architecture supported."
    log_info "OS: ${OS_NAME} | Arch: ${ARCH}"
}

check_internet() {
    print_step "Checking Internet Connectivity"
    if ! curl -sf --max-time 5 https://1.1.1.1 > /dev/null 2>&1; then
        print_error "No internet connection detected. Please check your network."
        exit 1
    fi
    print_success "Internet connection OK."
}

check_existing_wireguard() {
    if [[ -f "${WG_CONF}" ]]; then
        echo -e "\n${YELLOW}${BOLD}  ⚠  WireGuard is already configured on this system.${RESET}"
        echo -e "  Reinstalling will ${RED}overwrite your existing configuration${RESET}."
        echo -e ""
        read -rp "  Do you want to continue anyway? [y/N]: " confirm
        if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
            echo -e "\n  Installation cancelled.\n"
            exit 0
        fi
    fi
}

# =============================================================================
# SETUP LOG DIRECTORY
# =============================================================================

setup_logging() {
    mkdir -p "${WGM_LOG_DIR}"
    touch "${WGM_LOG_FILE}"
    chmod 640 "${WGM_LOG_FILE}"
    log_info "WireGuard Manager installer started — version ${WGM_VERSION}"
    log_info "Date: $(date)"
}

# =============================================================================
# AUTO-DETECT NETWORK INTERFACE
# =============================================================================

detect_interface() {
    # Get the default route interface
    DETECTED_IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)"
    if [[ -z "${DETECTED_IFACE}" ]]; then
        DETECTED_IFACE="eth0"
    fi
}

# =============================================================================
# INTERACTIVE QUESTIONS
# =============================================================================

ask_hostname() {
    print_question_header 1 9 "Hostname"
    echo -e "  What hostname should this server use?"
    echo -e "  ${YELLOW}This is used in logs and the dashboard.${RESET}\n"
    local default_hostname
    default_hostname="$(hostname -s 2>/dev/null || echo 'wireguard-server')"
    read -rp "  Hostname [${default_hostname}]: " SERVER_HOSTNAME
    SERVER_HOSTNAME="${SERVER_HOSTNAME:-$default_hostname}"
    log_info "Hostname set to: ${SERVER_HOSTNAME}"
}

ask_vpn_subnet() {
    print_question_header 2 9 "VPN Subnet"
    echo -e "  What subnet should the VPN use?"
    echo -e "  ${YELLOW}Default is 10.0.0.0/24 (supports up to 253 clients)${RESET}\n"
    read -rp "  VPN Subnet [10.0.0.0/24]: " VPN_SUBNET
    VPN_SUBNET="${VPN_SUBNET:-10.0.0.0/24}"

    # Derive base IP (e.g. 10.0.0 from 10.0.0.0/24)
    VPN_BASE_IP="$(echo "${VPN_SUBNET}" | cut -d'.' -f1-3)"
    SERVER_VPN_IP="${VPN_BASE_IP}.1"

    log_info "VPN Subnet: ${VPN_SUBNET} | Server IP: ${SERVER_VPN_IP}"
}

ask_endpoint() {
    print_question_header 3 9 "VPN Server Address"
    echo -e "  What is the public address clients will use to connect?"
    echo -e "  Examples:"
    echo -e "    ${CYAN}vpn.example.com${RESET}       (custom domain)"
    echo -e "    ${CYAN}myhome.duckdns.org${RESET}    (dynamic DNS)"
    echo -e "    ${CYAN}203.0.113.1${RESET}           (static public IP)\n"

    # Auto-detect public IP as suggestion
    local detected_ip
    detected_ip="$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo '')"
    if [[ -n "${detected_ip}" ]]; then
        echo -e "  ${YELLOW}Detected public IP: ${detected_ip}${RESET}\n"
    fi

    read -rp "  Server Address [${detected_ip:-your-domain.com}]: " SERVER_ENDPOINT
    SERVER_ENDPOINT="${SERVER_ENDPOINT:-${detected_ip}}"

    if [[ -z "${SERVER_ENDPOINT}" ]]; then
        print_error "Server address cannot be empty."
        ask_endpoint
    fi

    log_info "Endpoint: ${SERVER_ENDPOINT}"
}

ask_port() {
    print_question_header 4 9 "WireGuard Port"
    echo -e "  Which UDP port should WireGuard listen on?"
    echo -e "  ${YELLOW}Default is 51820. Change only if that port is blocked.${RESET}\n"
    read -rp "  WireGuard Port [51820]: " WG_PORT
    WG_PORT="${WG_PORT:-51820}"

    # Validate it's a number in valid range
    if ! [[ "${WG_PORT}" =~ ^[0-9]+$ ]] || (( WG_PORT < 1 || WG_PORT > 65535 )); then
        print_error "Invalid port. Enter a number between 1 and 65535."
        ask_port
    fi

    log_info "WireGuard Port: ${WG_PORT}"
}

ask_interface() {
    print_question_header 5 9 "Network Interface"
    detect_interface
    echo -e "  Which network interface connects this server to the internet?"
    echo -e "  ${YELLOW}Auto-detected: ${DETECTED_IFACE}${RESET}\n"
    echo -e "  Available interfaces:"
    # Filter out loopback, virtual, and container interfaces
    ip -o link show \
        | awk -F': ' '{print $2}' \
        | grep -v -E '^(lo|docker[0-9]+|veth|br-|virbr|wg[0-9]+|tun|tap|dummy)' \
        | sed 's/@.*//' \
        | sort -u \
        | while read -r iface; do
            echo "    ${iface}"
          done
    echo ""
    read -rp "  Interface [${DETECTED_IFACE}]: " NET_IFACE
    NET_IFACE="${NET_IFACE:-$DETECTED_IFACE}"
    log_info "Network interface: ${NET_IFACE}"
}

ask_dns() {
    print_question_header 6 9 "DNS for VPN Clients"
    echo -e "  Which DNS server should VPN clients use?\n"
    echo -e "  1) Pi-hole          (enter your Pi-hole IP)"
    echo -e "  2) AdGuard Home     (enter your AdGuard IP)"
    echo -e "  3) Cloudflare       1.1.1.1, 1.0.0.1"
    echo -e "  4) Google           8.8.8.8, 8.8.4.4"
    echo -e "  5) Quad9            9.9.9.9, 149.112.112.112"
    echo -e "  6) Custom           (enter manually)\n"
    read -rp "  Choice [3]: " dns_choice
    dns_choice="${dns_choice:-3}"

    case "${dns_choice}" in
        1)
            read -rp "  Pi-hole IP address: " CLIENT_DNS
            ;;
        2)
            read -rp "  AdGuard Home IP address: " CLIENT_DNS
            ;;
        3)
            CLIENT_DNS="1.1.1.1, 1.0.0.1"
            ;;
        4)
            CLIENT_DNS="8.8.8.8, 8.8.4.4"
            ;;
        5)
            CLIENT_DNS="9.9.9.9, 149.112.112.112"
            ;;
        6)
            read -rp "  Custom DNS (comma-separated): " CLIENT_DNS
            ;;
        *)
            print_warn "Invalid choice, defaulting to Cloudflare."
            CLIENT_DNS="1.1.1.1, 1.0.0.1"
            ;;
    esac

    log_info "Client DNS: ${CLIENT_DNS}"
}

ask_ddns() {
    print_question_header 7 9 "Dynamic DNS"
    echo -e "  Do you have a dynamic IP? A DDNS provider keeps your domain"
    echo -e "  pointing to your current IP automatically.\n"
    echo -e "  1) DuckDNS          (free, easy)"
    echo -e "  2) No-IP            (free tier available)"
    echo -e "  3) Cloudflare DNS   (requires Cloudflare API token)"
    echo -e "  4) Custom URL       (any update URL)"
    echo -e "  5) None             (static IP or handle manually)\n"
    read -rp "  Choice [5]: " ddns_choice
    DDNS_PROVIDER="${ddns_choice:-5}"

    case "${DDNS_PROVIDER}" in
        1)
            DDNS_NAME="DuckDNS"
            echo ""
            read -rp "  DuckDNS subdomain (e.g. myhome from myhome.duckdns.org): " DUCKDNS_SUBDOMAIN
            read -rp "  DuckDNS token: " DUCKDNS_TOKEN
            if [[ -z "${DUCKDNS_SUBDOMAIN}" || -z "${DUCKDNS_TOKEN}" ]]; then
                print_error "Subdomain and token are required for DuckDNS."
                ask_ddns
            fi
            log_info "DDNS: DuckDNS | subdomain: ${DUCKDNS_SUBDOMAIN}"
            ;;
        2)
            DDNS_NAME="No-IP"
            echo ""
            read -rp "  No-IP hostname (e.g. myhome.ddns.net): " NOIP_HOSTNAME
            read -rp "  No-IP username/email: " NOIP_USERNAME
            read -rsp "  No-IP password: " NOIP_PASSWORD
            echo ""
            if [[ -z "${NOIP_HOSTNAME}" || -z "${NOIP_USERNAME}" || -z "${NOIP_PASSWORD}" ]]; then
                print_error "Hostname, username, and password are required for No-IP."
                ask_ddns
            fi
            log_info "DDNS: No-IP | hostname: ${NOIP_HOSTNAME}"
            ;;
        3)
            DDNS_NAME="Cloudflare"
            echo ""
            read -rp "  Cloudflare Zone ID: " CF_ZONE_ID
            read -rp "  Cloudflare DNS Record ID: " CF_RECORD_ID
            read -rp "  Cloudflare API Token: " CF_API_TOKEN
            read -rp "  DNS Record name (e.g. vpn.example.com): " CF_RECORD_NAME
            if [[ -z "${CF_ZONE_ID}" || -z "${CF_RECORD_ID}" || -z "${CF_API_TOKEN}" || -z "${CF_RECORD_NAME}" ]]; then
                print_error "All Cloudflare fields are required."
                ask_ddns
            fi
            log_info "DDNS: Cloudflare | record: ${CF_RECORD_NAME}"
            ;;
        4)
            DDNS_NAME="Custom"
            echo ""
            echo -e "  ${YELLOW}Enter a URL that updates your IP when fetched.${RESET}"
            echo -e "  Use \${IP} as a placeholder for your current IP if needed.\n"
            read -rp "  Update URL: " CUSTOM_DDNS_URL
            if [[ -z "${CUSTOM_DDNS_URL}" ]]; then
                print_error "Update URL cannot be empty."
                ask_ddns
            fi
            log_info "DDNS: Custom | URL: ${CUSTOM_DDNS_URL}"
            ;;
        5|*)
            DDNS_NAME="None"
            log_info "DDNS: None"
            ;;
    esac
}

ask_ipv6() {
    print_question_header 8 9 "IPv6 Support"
    echo -e "  Enable IPv6 on the VPN tunnel?"
    echo -e "  ${YELLOW}Only enable this if your server has a public IPv6 address.${RESET}\n"
    read -rp "  Enable IPv6? [y/N]: " ipv6_choice
    if [[ "${ipv6_choice}" =~ ^[Yy]$ ]]; then
        ENABLE_IPV6=true
        VPN_IPV6_SUBNET="fd86:ea04:1115::/64"
        SERVER_VPN_IPV6="${VPN_IPV6_SUBNET%::*}::1/64"
        print_info "IPv6 enabled: ${VPN_IPV6_SUBNET}"
    else
        ENABLE_IPV6=false
        print_info "IPv6 disabled."
    fi
    log_info "IPv6: ${ENABLE_IPV6}"
}

ask_optional_components() {
    print_question_header 9 9 "Optional Components"
    echo -e "  Select which optional components to install:\n"

    read -rp "  Install PHP Dashboard?          [Y/n]: " install_dash
    INSTALL_DASHBOARD=true
    [[ "${install_dash}" =~ ^[Nn]$ ]] && INSTALL_DASHBOARD=false

    read -rp "  Install Uptime Kuma monitoring? [Y/n]: " install_kuma
    INSTALL_KUMA=true
    [[ "${install_kuma}" =~ ^[Nn]$ ]] && INSTALL_KUMA=false

    read -rp "  Enable automatic backups?       [Y/n]: " install_backup
    INSTALL_BACKUP=true
    [[ "${install_backup}" =~ ^[Nn]$ ]] && INSTALL_BACKUP=false

    echo ""
    echo -e "  ${CYAN}Automatic updates:${RESET}"
    echo -e "  The system can check GitHub for updates nightly at 1 AM."
    echo -e "  You choose: notify only (banner in dashboard) or apply automatically.\n"

    read -rp "  Enable nightly update checks?   [Y/n]: " check_updates
    ENABLE_UPDATE_CHECK=true
    [[ "${check_updates}" =~ ^[Nn]$ ]] && ENABLE_UPDATE_CHECK=false

    AUTO_UPDATE=false
    if [[ "${ENABLE_UPDATE_CHECK}" == true ]]; then
        read -rp "  Auto-apply updates automatically? [y/N]: " auto_up
        [[ "${auto_up}" =~ ^[Yy]$ ]] && AUTO_UPDATE=true
        if [[ "${AUTO_UPDATE}" == true ]]; then
            print_warn "Auto-update ON: updates will apply automatically at 1 AM. WireGuard stays running."
        else
            print_info "Notify-only: dashboard will show a banner when an update is available."
        fi
    fi

    log_info "Dashboard: ${INSTALL_DASHBOARD} | Kuma: ${INSTALL_KUMA} | Backup: ${INSTALL_BACKUP} | UpdateCheck: ${ENABLE_UPDATE_CHECK} | AutoUpdate: ${AUTO_UPDATE}"
}

# =============================================================================
# CONFIRM SUMMARY
# =============================================================================

confirm_summary() {
    print_header
    print_step "Installation Summary — Please Review"

    echo -e "  ${BOLD}Hostname          :${RESET} ${SERVER_HOSTNAME}"
    echo -e "  ${BOLD}VPN Subnet        :${RESET} ${VPN_SUBNET}"
    echo -e "  ${BOLD}Server VPN IP     :${RESET} ${SERVER_VPN_IP}"
    echo -e "  ${BOLD}Public Endpoint   :${RESET} ${SERVER_ENDPOINT}"
    echo -e "  ${BOLD}WireGuard Port    :${RESET} ${WG_PORT}/UDP"
    echo -e "  ${BOLD}Network Interface :${RESET} ${NET_IFACE}"
    echo -e "  ${BOLD}Client DNS        :${RESET} ${CLIENT_DNS}"
    echo -e "  ${BOLD}DDNS Provider     :${RESET} ${DDNS_NAME}"
    echo -e "  ${BOLD}IPv6              :${RESET} ${ENABLE_IPV6}"
    echo -e "  ${BOLD}Dashboard         :${RESET} ${INSTALL_DASHBOARD}"
    echo -e "  ${BOLD}Uptime Kuma       :${RESET} ${INSTALL_KUMA}"
    echo -e "  ${BOLD}Auto Backup       :${RESET} ${INSTALL_BACKUP}"
    echo ""
    echo -e "  ${YELLOW}This will install and configure your system.${RESET}"
    echo ""
    read -rp "  Proceed with installation? [Y/n]: " confirm
    if [[ "${confirm}" =~ ^[Nn]$ ]]; then
        echo -e "\n  Installation cancelled.\n"
        exit 0
    fi
}

# =============================================================================
# PACKAGE INSTALLATION
# =============================================================================

install_packages() {
    print_step "Installing Packages"

    local packages=(wireguard wireguard-tools qrencode iptables curl cron)

    print_info "Updating package lists..."
    (apt-get update -qq > /dev/null 2>&1) &
    spinner $! "Updating package lists..."
    print_success "Package lists updated."

    print_info "Installing required packages..."
    (DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}" > /dev/null 2>&1) &
    spinner $! "Installing wireguard, qrencode, iptables, curl, cron..."
    print_success "Core packages installed."

    # UFW — only configure if already installed
    if command -v ufw &>/dev/null; then
        print_info "UFW detected — will configure firewall rules."
        UFW_AVAILABLE=true
    else
        UFW_AVAILABLE=false
    fi

    log_success "Packages installed: ${packages[*]}"
}

install_docker() {
    if command -v docker &>/dev/null; then
        print_info "Docker already installed — skipping."
        log_info "Docker already present."
        return
    fi

    print_info "Installing Docker..."
    (
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh > /dev/null 2>&1
        sh /tmp/get-docker.sh > /dev/null 2>&1
        rm -f /tmp/get-docker.sh
    ) &
    spinner $! "Installing Docker..."
    print_success "Docker installed."
    log_success "Docker installed."
}

# =============================================================================
# WIREGUARD CONFIGURATION
# =============================================================================

generate_server_keys() {
    print_step "Generating WireGuard Server Keys"

    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard

    # Generate server private and public keys
    SERVER_PRIVATE_KEY="$(wg genkey)"
    SERVER_PUBLIC_KEY="$(echo "${SERVER_PRIVATE_KEY}" | wg pubkey)"

    # Save keys
    echo "${SERVER_PRIVATE_KEY}" > /etc/wireguard/server_private.key
    echo "${SERVER_PUBLIC_KEY}"  > /etc/wireguard/server_public.key
    chmod 600 /etc/wireguard/server_private.key
    chmod 644 /etc/wireguard/server_public.key

    print_success "Server keys generated."
    log_success "Server keys generated. Public key: ${SERVER_PUBLIC_KEY}"
}

create_wg_conf() {
    print_step "Creating WireGuard Configuration"

    local ipv4_address="${SERVER_VPN_IP}/24"
    local address_line="${ipv4_address}"

    if [[ "${ENABLE_IPV6}" == true ]]; then
        address_line="${ipv4_address}, ${SERVER_VPN_IPV6}"
    fi

    cat > "${WG_CONF}" <<EOF
# ============================================================
# WireGuard Server Configuration
# Generated by WireGuard Manager v${WGM_VERSION}
# Date: $(date)
# ============================================================

[Interface]
# Server VPN address
Address = ${address_line}

# Listening port
ListenPort = ${WG_PORT}

# Server private key
PrivateKey = ${SERVER_PRIVATE_KEY}

# Save config on shutdown (preserves runtime peer changes)
SaveConfig = false

# ---- NAT & Forwarding Rules ----
PostUp   = iptables -t nat -A POSTROUTING -s ${VPN_SUBNET} -o ${NET_IFACE} -j MASQUERADE
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp   = iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${VPN_SUBNET} -o ${NET_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
EOF

    if [[ "${ENABLE_IPV6}" == true ]]; then
        cat >> "${WG_CONF}" <<EOF

# ---- IPv6 NAT Rules ----
PostUp   = ip6tables -t nat -A POSTROUTING -s ${VPN_IPV6_SUBNET} -o ${NET_IFACE} -j MASQUERADE
PostUp   = ip6tables -A FORWARD -i wg0 -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -s ${VPN_IPV6_SUBNET} -o ${NET_IFACE} -j MASQUERADE
PostDown = ip6tables -D FORWARD -i wg0 -j ACCEPT
EOF
    fi

    cat >> "${WG_CONF}" <<EOF

# ============================================================
# Peers are appended below by wg-add-client
# ============================================================
EOF

    chmod 600 "${WG_CONF}"
    print_success "wg0.conf created."
    log_success "WireGuard config written to ${WG_CONF}"
}

enable_ip_forwarding() {
    print_step "Enabling IP Forwarding"

    # Set immediately
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

    if [[ "${ENABLE_IPV6}" == true ]]; then
        sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1
    fi

    # Persist across reboots
    local sysctl_conf="/etc/sysctl.d/99-wireguard-manager.conf"
    cat > "${sysctl_conf}" <<EOF
# WireGuard Manager — IP Forwarding
net.ipv4.ip_forward = 1
EOF
    if [[ "${ENABLE_IPV6}" == true ]]; then
        echo "net.ipv6.conf.all.forwarding = 1" >> "${sysctl_conf}"
    fi

    sysctl -p "${sysctl_conf}" > /dev/null 2>&1
    print_success "IP forwarding enabled and persisted."
    log_success "IP forwarding enabled."
}

configure_firewall() {
    print_step "Configuring Firewall"

    if [[ "${UFW_AVAILABLE}" == true ]]; then
        # Allow WireGuard UDP port
        ufw allow "${WG_PORT}"/udp > /dev/null 2>&1 || true

        # Allow SSH — try app profile first, fall back to port number
        # (minimal Ubuntu installs may not have UFW app profiles)
        ufw allow OpenSSH > /dev/null 2>&1 || \
        ufw allow 22/tcp  > /dev/null 2>&1 || true

        print_success "UFW: WireGuard port ${WG_PORT}/UDP allowed."
        print_success "UFW: SSH allowed."

        if [[ "${INSTALL_DASHBOARD}" == true ]]; then
            ufw allow 80/tcp  > /dev/null 2>&1 || true
            ufw allow 443/tcp > /dev/null 2>&1 || true
            print_success "UFW: HTTP/HTTPS allowed for dashboard."
        fi

        if [[ "${INSTALL_KUMA}" == true ]]; then
            ufw allow 3001/tcp > /dev/null 2>&1 || true
            print_success "UFW: Port 3001/TCP allowed for Uptime Kuma."
        fi

        # Enable UFW non-interactively if not already active
        if ! ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw --force enable > /dev/null 2>&1 || true
            print_success "UFW: Firewall enabled."
        fi

        log_success "UFW rules configured."
    else
        # UFW not present — use raw iptables
        iptables -A INPUT -p udp --dport "${WG_PORT}" -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
        print_success "iptables: WireGuard port ${WG_PORT}/UDP allowed."
        print_warn "UFW not installed — rules applied via iptables but won't persist across reboots."
        print_warn "To persist: sudo apt install iptables-persistent"
        log_warn "UFW not present. iptables rules applied (not persistent)."
    fi
}

start_wireguard() {
    print_step "Starting WireGuard"

    systemctl enable wg-quick@wg0 > /dev/null 2>&1
    systemctl start  wg-quick@wg0 > /dev/null 2>&1

    sleep 2

    if systemctl is-active --quiet wg-quick@wg0; then
        print_success "WireGuard started and enabled on boot."
        log_success "wg-quick@wg0 is running."
    else
        print_error "WireGuard failed to start. Check: journalctl -u wg-quick@wg0"
        log_error "wg-quick@wg0 failed to start."
        exit 1
    fi
}

# =============================================================================
# CLIENT MANAGEMENT SCRIPTS
# =============================================================================

install_client_scripts() {
    print_step "Installing Client Management Scripts"

    mkdir -p "${WGM_CLIENTS_DIR}"
    mkdir -p "${WGM_DIR}"

    # ---- Write runtime config (read by all client scripts) ----
    cat > "${WGM_DIR}/config.env" <<EOF
# WireGuard Manager — Runtime Config
# Generated by installer v${WGM_VERSION}
WGM_VERSION="${WGM_VERSION}"
SERVER_HOSTNAME="${SERVER_HOSTNAME}"
VPN_SUBNET="${VPN_SUBNET}"
VPN_BASE_IP="${VPN_BASE_IP}"
SERVER_VPN_IP="${SERVER_VPN_IP}"
SERVER_ENDPOINT="${SERVER_ENDPOINT}"
WG_PORT="${WG_PORT}"
NET_IFACE="${NET_IFACE}"
CLIENT_DNS="${CLIENT_DNS}"
ENABLE_IPV6="${ENABLE_IPV6}"
WGM_CLIENTS_DIR="${WGM_CLIENTS_DIR}"
WGM_DB="${WGM_DB}"
WG_CONF="${WG_CONF}"
ENABLE_UPDATE_CHECK="${ENABLE_UPDATE_CHECK:-true}"
AUTO_UPDATE="${AUTO_UPDATE:-false}"
GITHUB_USER="${GITHUB_USER}"
GITHUB_REPO="${GITHUB_REPO}"
GITHUB_BRANCH="${GITHUB_BRANCH}"
EOF
    chmod 640 "${WGM_DIR}/config.env"

    # ---- Initialize client database ----
    # Format: name|ip|pubkey|created|status
    if [[ ! -f "${WGM_DB}" ]]; then
        echo "# WireGuard Manager Client Database" > "${WGM_DB}"
        echo "# Format: name|ip|pubkey|created|status" >> "${WGM_DB}"
        chmod 640 "${WGM_DB}"
    fi

    # ---- Download all client scripts from GitHub ----
    # Every script is a standalone file in scripts/ in the repo.
    # This means wg-update can push fixes to all installs without
    # anyone needing to re-run install.sh.

    local scripts=(
        wg-add-client
        wg-delete-client
        wg-show-client
        wg-list-clients
        wg-disable-client
        wg-enable-client
        wg-rename-client
        wg-export-client
        wg-import-client
        wg-regen-qr
        wg-dashboard-passwd
        wg-check-update
    )

    local failed=0

    print_info "Downloading scripts from GitHub..."

    for script in "${scripts[@]}"; do
        local url="${GITHUB_RAW}/scripts/${script}"
        local dest="${BIN_DIR}/${script}"
        local tmp
        tmp="$(mktemp)"

        if curl -sf --max-time 30 -o "${tmp}" "${url}" \
            && [[ -s "${tmp}" ]] \
            && head -1 "${tmp}" | grep -q '^#!'; then
            mv "${tmp}" "${dest}"
            chmod +x "${dest}"
            print_success "${script}"
        else
            rm -f "${tmp}"
            # Install a stub so the command exists but tells user to update
            cat > "${dest}" <<STUB
#!/usr/bin/env bash
echo ""
echo "  '${script}' was not downloaded during installation."
echo "  This usually means GitHub was temporarily unreachable."
echo ""
echo "  Fix with:  wg-update"
echo ""
exit 1
STUB
            chmod +x "${dest}"
            print_warn "${script} — download failed, stub installed. Run 'wg-update' to fix."
            (( failed++ )) || true
        fi
    done

    if (( failed > 0 )); then
        print_warn "${failed} script(s) were not downloaded. Run 'wg-update' once internet is confirmed."
        log_warn "Script download failures during install: ${failed}"
    fi

    print_success "Client management scripts installed in ${BIN_DIR}."
    log_success "Client scripts installed."
}


# =============================================================================
# UPDATER
# =============================================================================

# GitHub repo where updates will be pulled from.
# Change these to match your actual repo before distributing.
GITHUB_USER="zedofficial"
GITHUB_REPO="wireguard-manager"
GITHUB_BRANCH="main"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

install_updater() {
    # Write current version to disk so wg-update can compare
    echo "${WGM_VERSION}" > "${WGM_DIR}/version"
    chmod 644 "${WGM_DIR}/version"

    # Install wg-update command
    cat > "${BIN_DIR}/wg-update" <<UPDATER_SCRIPT
#!/usr/bin/env bash
# =============================================================================
# wg-update — WireGuard Manager Self-Updater
# Pulls latest scripts and dashboard from GitHub.
# Never touches WireGuard config, keys, or client data.
# =============================================================================
set -euo pipefail

GITHUB_RAW="${GITHUB_RAW}"
WGM_DIR="${WGM_DIR}"
BIN_DIR="${BIN_DIR}"
DASHBOARD_DIR="/var/www/html/wireguard-manager"
WGM_LOG_DIR="${WGM_LOG_DIR}"
VERSION_FILE="\${WGM_DIR}/version"
BACKUP_DIR="\${WGM_DIR}/backups/pre-update"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'

CHECK_ONLY=false; FORCE_UPDATE=false
for arg in "\$@"; do
    case "\${arg}" in --check) CHECK_ONLY=true;; --force) FORCE_UPDATE=true;; esac
done

[[ "\$EUID" -ne 0 ]] && { echo -e "\${RED}  Run as root.\${RESET}"; exit 1; }
log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') [UPDATE] \$*" >> "\${WGM_LOG_DIR}/update.log" 2>/dev/null || true; }

echo -e "\n\${CYAN}\${BOLD}  WireGuard Manager — Updater\${RESET}\n"

CURRENT_VERSION="\$(cat "\${VERSION_FILE}" 2>/dev/null | tr -d '[:space:]' || echo 'unknown')"
echo -e "  Installed : \${CYAN}\${CURRENT_VERSION}\${RESET}"

LATEST_VERSION="\$(curl -sf --max-time 10 "\${GITHUB_RAW}/version" 2>/dev/null | tr -d '[:space:]' || echo '')"
[[ -z "\${LATEST_VERSION}" ]] && { echo -e "\${RED}  Cannot reach GitHub.\${RESET}"; exit 1; }
echo -e "  Latest    : \${CYAN}\${LATEST_VERSION}\${RESET}"

if [[ "\${CURRENT_VERSION}" == "\${LATEST_VERSION}" && "\${FORCE_UPDATE}" == false ]]; then
    echo -e "\n\${GREEN}  Already up to date (\${CURRENT_VERSION}).\${RESET}\n"; exit 0
fi

if [[ "\${CHECK_ONLY}" == true ]]; then
    echo -e "\n\${YELLOW}  Update available: \${CURRENT_VERSION} → \${LATEST_VERSION}\${RESET}"
    echo -e "  Run \${CYAN}wg-update\${RESET} to apply.\n"; exit 0
fi

echo ""
read -rp "  Apply update \${CURRENT_VERSION} → \${LATEST_VERSION}? [Y/n]: " confirm
[[ "\${confirm}" =~ ^[Nn]\$ ]] && { echo "  Cancelled."; exit 0; }

log "Update starting: \${CURRENT_VERSION} → \${LATEST_VERSION}"

# Pre-update backup
mkdir -p "\${BACKUP_DIR}"
BACKUP_FILE="\${BACKUP_DIR}/pre_update_\$(date '+%Y%m%d_%H%M%S').tar.gz"
tar -czf "\${BACKUP_FILE}" "\${BIN_DIR}"/wg-* "\${WGM_DIR}/version" 2>/dev/null || true
[[ -d "\${DASHBOARD_DIR}" ]] && tar -czf "\${BACKUP_DIR}/dashboard_\$(date '+%Y%m%d_%H%M%S').tar.gz" "\${DASHBOARD_DIR}/" 2>/dev/null || true
echo -e "  \${GREEN}✔ Backup: \${BACKUP_FILE}\${RESET}"

dl() {
    local src="\$1" dst="\$2" tmp
    tmp="\$(mktemp)"
    if curl -sf --max-time 30 -o "\${tmp}" "\${GITHUB_RAW}/\${src}" && [[ -s "\${tmp}" ]]; then
        mv "\${tmp}" "\${dst}"; return 0
    fi
    rm -f "\${tmp}"; return 1
}

echo ""
echo -e "  \${CYAN}Updating scripts...\${RESET}"
SCRIPTS=(wg-add-client wg-delete-client wg-show-client wg-list-clients
         wg-disable-client wg-enable-client wg-rename-client
         wg-export-client wg-import-client wg-regen-qr
         wg-update wg-dashboard-passwd)
UPDATED=0
for s in "\${SCRIPTS[@]}"; do
    if dl "scripts/\${s}" "\${BIN_DIR}/\${s}"; then
        chmod +x "\${BIN_DIR}/\${s}"
        echo -e "  \${GREEN}✔\${RESET} \${s}"; (( UPDATED++ ))
    else
        echo -e "  \${YELLOW}⚠ \${s} — not in this release\${RESET}"
    fi
done

if [[ -d "\${DASHBOARD_DIR}" ]]; then
    echo ""
    echo -e "  \${CYAN}Updating dashboard...\${RESET}"
    for f in index.php login.php logout.php action.php clients.php config.php logs.php; do
        dl "dashboard/\${f}" "\${DASHBOARD_DIR}/\${f}" && echo -e "  \${GREEN}✔\${RESET} \${f}" || true
    done
    systemctl reload apache2 2>/dev/null || true
fi

echo "\${LATEST_VERSION}" > "\${VERSION_FILE}"

echo ""
echo -e "\${GREEN}\${BOLD}  Update complete: \${CURRENT_VERSION} → \${LATEST_VERSION}\${RESET}"
echo -e "  \${UPDATED} scripts updated. WireGuard kept running. Clients unaffected.\n"
log "Update done: \${CURRENT_VERSION} → \${LATEST_VERSION}"
UPDATER_SCRIPT

    chmod +x "${BIN_DIR}/wg-update"
    print_success "wg-update installed."

    # ---- Download and install wg-check-update ----
    local tmp
    tmp="$(mktemp)"
    if curl -sf --max-time 30 -o "${tmp}" "${GITHUB_RAW}/scripts/wg-check-update" \
        && [[ -s "${tmp}" ]] && head -1 "${tmp}" | grep -q '^#!'; then
        mv "${tmp}" "${BIN_DIR}/wg-check-update"
        chmod +x "${BIN_DIR}/wg-check-update"
        print_success "wg-check-update installed."
    else
        rm -f "${tmp}"
        # Embed minimal fallback inline
        cat > "${BIN_DIR}/wg-check-update" <<'STUB'
#!/usr/bin/env bash
source /opt/wireguard/config.env 2>/dev/null || true
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_USER:-zedofficial}/${GITHUB_REPO:-wireguard-manager}/${GITHUB_BRANCH:-main}"
CURRENT="$(cat /opt/wireguard/version 2>/dev/null | tr -d '[:space:]' || echo 'unknown')"
LATEST="$(curl -sf --max-time 10 "${GITHUB_RAW}/version" 2>/dev/null | tr -d '[:space:]' || echo '')"
[[ -z "${LATEST}" ]] && exit 1
if [[ "${CURRENT}" != "${LATEST}" ]]; then
    printf '{"status":"available","current_version":"%s","latest_version":"%s","message":"Update available","checked_at":"%s","auto_update":%s}\n' \
        "${CURRENT}" "${LATEST}" "$(date '+%Y-%m-%d %H:%M:%S')" "${AUTO_UPDATE:-false}" \
        > /opt/wireguard/update_status.json
else
    printf '{"status":"up_to_date","current_version":"%s","latest_version":"%s","message":"Up to date","checked_at":"%s","auto_update":%s}\n' \
        "${CURRENT}" "${LATEST}" "$(date '+%Y-%m-%d %H:%M:%S')" "${AUTO_UPDATE:-false}" \
        > /opt/wireguard/update_status.json
fi
STUB
        chmod +x "${BIN_DIR}/wg-check-update"
        print_warn "wg-check-update fallback installed. Run 'wg-update' to fetch full version."
    fi

    # ---- Set up nightly update check cron ----
    if [[ "${ENABLE_UPDATE_CHECK:-true}" == true ]]; then
        echo "0 1 * * * root ${BIN_DIR}/wg-check-update >> ${WGM_LOG_DIR}/update.log 2>&1" \
            > /etc/cron.d/wireguard-update-check
        chmod 644 /etc/cron.d/wireguard-update-check
        print_success "Nightly update check scheduled at 1:00 AM."
        if [[ "${AUTO_UPDATE:-false}" == true ]]; then
            print_info "Auto-update mode: updates will apply automatically."
        else
            print_info "Notify-only mode: dashboard will show a banner when updates are available."
        fi
    else
        print_info "Automatic update checks disabled. Run 'wg-update' manually to update."
    fi

    # ---- Run initial check right now so dashboard has status immediately ----
    "${BIN_DIR}/wg-check-update" >> "${WGM_LOG_DIR}/update.log" 2>&1 || true

    log_success "Updater installed. GitHub: ${GITHUB_RAW}"
}

# =============================================================================
# DYNAMIC DNS
# =============================================================================

setup_ddns() {
    [[ "${DDNS_PROVIDER}" == "5" ]] && return

    print_step "Setting Up Dynamic DNS — ${DDNS_NAME}"
    mkdir -p "${WGM_DDNS_DIR}"

    case "${DDNS_PROVIDER}" in
        1) setup_ddns_duckdns ;;
        2) setup_ddns_noip ;;
        3) setup_ddns_cloudflare ;;
        4) setup_ddns_custom ;;
    esac

    # Create cron job to run every 5 minutes
    local cron_entry="*/5 * * * * root bash ${WGM_DDNS_DIR}/update.sh >> ${WGM_LOG_DIR}/ddns.log 2>&1"
    echo "${cron_entry}" > /etc/cron.d/wireguard-ddns
    chmod 644 /etc/cron.d/wireguard-ddns

    print_success "DDNS update script: ${WGM_DDNS_DIR}/update.sh"
    print_success "DDNS cron job created (runs every 5 minutes)."
    log_success "DDNS configured: ${DDNS_NAME}"
}

setup_ddns_duckdns() {
    cat > "${WGM_DDNS_DIR}/update.sh" <<EOF
#!/usr/bin/env bash
# DuckDNS updater — generated by WireGuard Manager
SUBDOMAIN="${DUCKDNS_SUBDOMAIN}"
TOKEN="${DUCKDNS_TOKEN}"
LOG_FILE="${WGM_LOG_DIR}/ddns.log"

CURRENT_IP="\$(curl -sf --max-time 10 https://api.ipify.org 2>/dev/null)"
if [[ -z "\${CURRENT_IP}" ]]; then
    echo "\$(date) [WARN] Could not detect public IP." >> "\${LOG_FILE}"
    exit 1
fi

RESPONSE="\$(curl -sf --max-time 10 "https://www.duckdns.org/update?domains=\${SUBDOMAIN}&token=\${TOKEN}&ip=\${CURRENT_IP}")"
echo "\$(date) DuckDNS update: IP=\${CURRENT_IP} Response=\${RESPONSE}" >> "\${LOG_FILE}"
EOF
    chmod 700 "${WGM_DDNS_DIR}/update.sh"
}

setup_ddns_noip() {
    cat > "${WGM_DDNS_DIR}/update.sh" <<EOF
#!/usr/bin/env bash
# No-IP updater — generated by WireGuard Manager
HOSTNAME="${NOIP_HOSTNAME}"
USERNAME="${NOIP_USERNAME}"
PASSWORD="${NOIP_PASSWORD}"
LOG_FILE="${WGM_LOG_DIR}/ddns.log"

CURRENT_IP="\$(curl -sf --max-time 10 https://api.ipify.org 2>/dev/null)"
if [[ -z "\${CURRENT_IP}" ]]; then
    echo "\$(date) [WARN] Could not detect public IP." >> "\${LOG_FILE}"
    exit 1
fi

RESPONSE="\$(curl -sf --max-time 10 \
    -u "\${USERNAME}:\${PASSWORD}" \
    "https://dynupdate.no-ip.com/nic/update?hostname=\${HOSTNAME}&myip=\${CURRENT_IP}" \
    -A "WireGuardManager/1.0 admin@${SERVER_HOSTNAME}")"

echo "\$(date) No-IP update: IP=\${CURRENT_IP} Response=\${RESPONSE}" >> "\${LOG_FILE}"
EOF
    chmod 700 "${WGM_DDNS_DIR}/update.sh"
}

setup_ddns_cloudflare() {
    cat > "${WGM_DDNS_DIR}/update.sh" <<EOF
#!/usr/bin/env bash
# Cloudflare DNS updater — generated by WireGuard Manager
ZONE_ID="${CF_ZONE_ID}"
RECORD_ID="${CF_RECORD_ID}"
API_TOKEN="${CF_API_TOKEN}"
RECORD_NAME="${CF_RECORD_NAME}"
LOG_FILE="${WGM_LOG_DIR}/ddns.log"

CURRENT_IP="\$(curl -sf --max-time 10 https://api.ipify.org 2>/dev/null)"
if [[ -z "\${CURRENT_IP}" ]]; then
    echo "\$(date) [WARN] Could not detect public IP." >> "\${LOG_FILE}"
    exit 1
fi

RESPONSE="\$(curl -sf --max-time 10 -X PATCH \
    "https://api.cloudflare.com/client/v4/zones/\${ZONE_ID}/dns_records/\${RECORD_ID}" \
    -H "Authorization: Bearer \${API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"\${RECORD_NAME}\",\"content\":\"\${CURRENT_IP}\",\"ttl\":60,\"proxied\":false}")"

SUCCESS="\$(echo "\${RESPONSE}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success','false'))" 2>/dev/null)"
echo "\$(date) Cloudflare update: IP=\${CURRENT_IP} Success=\${SUCCESS}" >> "\${LOG_FILE}"
EOF
    chmod 700 "${WGM_DDNS_DIR}/update.sh"
}

setup_ddns_custom() {
    cat > "${WGM_DDNS_DIR}/update.sh" <<EOF
#!/usr/bin/env bash
# Custom DDNS updater — generated by WireGuard Manager
UPDATE_URL="${CUSTOM_DDNS_URL}"
LOG_FILE="${WGM_LOG_DIR}/ddns.log"

CURRENT_IP="\$(curl -sf --max-time 10 https://api.ipify.org 2>/dev/null)"
FINAL_URL="\${UPDATE_URL//\\\${IP}/\${CURRENT_IP}}"

RESPONSE="\$(curl -sf --max-time 10 "\${FINAL_URL}")"
echo "\$(date) Custom DDNS update: IP=\${CURRENT_IP} Response=\${RESPONSE}" >> "\${LOG_FILE}"
EOF
    chmod 700 "${WGM_DDNS_DIR}/update.sh"
}

# =============================================================================
# BACKUP SYSTEM
# =============================================================================

setup_backup() {
    [[ "${INSTALL_BACKUP}" != true ]] && return

    print_step "Setting Up Automatic Backups"

    mkdir -p "${WGM_DIR}/backups"

    cat > "${WGM_BACKUP_SCRIPT}" <<EOF
#!/usr/bin/env bash
# WireGuard Manager — Backup Script
# Generated by installer v${WGM_VERSION}
set -euo pipefail

BACKUP_DIR="${WGM_DIR}/backups"
TIMESTAMP="\$(date '+%Y%m%d_%H%M%S')"
BACKUP_FILE="\${BACKUP_DIR}/wgm_backup_\${TIMESTAMP}.tar.gz"
LOG_FILE="${WGM_LOG_DIR}/backup.log"

echo "\$(date) Starting backup..." >> "\${LOG_FILE}"

tar -czf "\${BACKUP_FILE}" \\
    /etc/wireguard/ \\
    ${WGM_DIR}/clients.db \\
    ${WGM_DIR}/config.env \\
    ${WGM_DDNS_DIR}/ \\
    2>/dev/null || true

# Keep only last 7 backups
ls -t "\${BACKUP_DIR}"/wgm_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null || true

echo "\$(date) Backup saved: \${BACKUP_FILE}" >> "\${LOG_FILE}"
EOF
    chmod 700 "${WGM_BACKUP_SCRIPT}"

    # Schedule daily backup at 2:00 AM
    echo "0 2 * * * root bash ${WGM_BACKUP_SCRIPT}" > /etc/cron.d/wireguard-backup
    chmod 644 /etc/cron.d/wireguard-backup

    print_success "Backup script: ${WGM_BACKUP_SCRIPT}"
    print_success "Auto-backup scheduled daily at 2:00 AM."
    log_success "Backup system configured."
}

# =============================================================================
# UPTIME KUMA
# =============================================================================

setup_uptime_kuma() {
    [[ "${INSTALL_KUMA}" != true ]] && return

    print_step "Installing Uptime Kuma (Monitoring)"

    install_docker

    # Pull and start Uptime Kuma container
    (
        docker pull louislam/uptime-kuma:1 > /dev/null 2>&1
        docker run -d \
            --name uptime-kuma \
            --restart always \
            -p 3001:3001 \
            -v uptime-kuma:/app/data \
            louislam/uptime-kuma:1 > /dev/null 2>&1
    ) &
    spinner $! "Starting Uptime Kuma..."

    print_success "Uptime Kuma started."
    local internal_ip
    internal_ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo 'your-server-ip')"
    print_info "Access Uptime Kuma at: http://${internal_ip}:3001"
    print_info "First launch will prompt you to create an admin account."
    log_success "Uptime Kuma container started."
}

# =============================================================================
# DASHBOARD (PHP)
# =============================================================================

setup_dashboard() {
    [[ "${INSTALL_DASHBOARD}" != true ]] && return

    print_step "Installing PHP Dashboard"

    # ---- Install Apache + PHP ----
    # Install the 'php' meta-package — on Debian/Ubuntu this always resolves
    # to the latest PHP version available in the distro's repos automatically.
    print_info "Installing Apache + PHP..."

    (DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        apache2 php libapache2-mod-php php-cli > /dev/null 2>&1) &
    spinner $! "Installing Apache + PHP..."

    if command -v php &>/dev/null; then
        local php_version
        php_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo 'unknown')"
        print_success "Apache and PHP ${php_version} installed."
        log_success "PHP version installed: ${php_version}"
    else
        print_error "Could not install PHP. Dashboard will not work."
        print_warn "Try manually: sudo apt install php libapache2-mod-php"
        log_error "PHP installation failed."
    fi

    DASHBOARD_DIR="/var/www/html/wireguard-manager"
    mkdir -p "${DASHBOARD_DIR}"

    # ---- Download all dashboard files from GitHub ----
    # Same pattern as scripts — every PHP file is standalone in dashboard/ in the repo.

    local dashboard_files=(
        layout.php
        index.php
        login.php
        logout.php
        action.php
        clients.php
        config.php
        logs.php
    )

    print_info "Downloading dashboard files from GitHub..."
    local failed=0

    for f in "${dashboard_files[@]}"; do
        local url="${GITHUB_RAW}/dashboard/${f}"
        local dest="${DASHBOARD_DIR}/${f}"
        local tmp
        tmp="$(mktemp)"

        if curl -sf --max-time 30 -o "${tmp}" "${url}" && [[ -s "${tmp}" ]]; then
            mv "${tmp}" "${dest}"
            chmod 644 "${dest}"
            print_success "${f}"
        else
            rm -f "${tmp}"
            print_warn "${f} — download failed. Run 'wg-update' to fetch it."
            (( failed++ )) || true
        fi
    done

    if (( failed > 0 )); then
        print_warn "${failed} dashboard file(s) missing. Dashboard may not work until 'wg-update' is run."
        log_warn "Dashboard download failures: ${failed}"
    fi

    # ---- Configure Apache vhost ----
    cat > /etc/apache2/sites-available/wireguard-manager.conf <<EOF
<VirtualHost *:80>
    ServerName ${SERVER_HOSTNAME}
    ServerAlias *
    DocumentRoot ${DASHBOARD_DIR}
    DirectoryIndex index.php

    <Directory ${DASHBOARD_DIR}>
        AllowOverride All
        Require all granted
        Options -Indexes
    </Directory>

    ErrorLog  \${APACHE_LOG_DIR}/wgm_error.log
    CustomLog \${APACHE_LOG_DIR}/wgm_access.log combined
</VirtualHost>
EOF

    a2dissite 000-default.conf > /dev/null 2>&1 || true
    a2ensite wireguard-manager.conf > /dev/null 2>&1 || true
    a2enmod rewrite > /dev/null 2>&1 || true
    systemctl enable apache2 > /dev/null 2>&1 || true

    # Stop first to clear any stale state, then start fresh
    systemctl stop    apache2 > /dev/null 2>&1 || true
    systemctl start   apache2 > /dev/null 2>&1 || true

    sleep 1

    # Verify Apache is actually running
    if systemctl is-active --quiet apache2; then
        print_success "Apache started and running."
    else
        # Try one more time with explicit restart
        systemctl restart apache2 2>/dev/null || true
        sleep 1
        if systemctl is-active --quiet apache2; then
            print_success "Apache started."
        else
            print_error "Apache failed to start. Check: sudo journalctl -u apache2 -n 20"
            log_error "Apache failed to start after setup."
        fi
    fi

    # ---- sudo rules so www-data can run wg commands ----
    cat > /etc/sudoers.d/wireguard-manager <<EOF
# WireGuard Manager dashboard — command permissions for www-data
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/wg-add-client
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/wg-delete-client
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/wg-disable-client
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/wg-enable-client
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/wg-rename-client
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/wg-update
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/wg-check-update
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/wg-regen-qr
www-data ALL=(ALL) NOPASSWD: /opt/wireguard/backup.sh
www-data ALL=(ALL) NOPASSWD: /bin/systemctl start wg-quick@wg0
www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop wg-quick@wg0
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart wg-quick@wg0
www-data ALL=(ALL) NOPASSWD: /bin/systemctl reload wg-quick@wg0
www-data ALL=(ALL) NOPASSWD: /usr/bin/wg
www-data ALL=(ALL) NOPASSWD: /usr/sbin/wg
EOF
    chmod 440 /etc/sudoers.d/wireguard-manager

    # Set default dashboard password (admin) — owned by root, readable by www-data
    echo "$(php -r "echo password_hash('admin', PASSWORD_DEFAULT);")" \
        > /opt/wireguard/dashboard.passwd
    chown root:www-data /opt/wireguard/dashboard.passwd
    chmod 640 /opt/wireguard/dashboard.passwd

    local internal_ip
    internal_ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo 'your-server-ip')"
    print_success "Dashboard installed at: http://${internal_ip}:80"
    print_warn "Default password: admin — CHANGE IT with: wg-dashboard-passwd"
    log_success "Dashboard installed."
}

# VERIFICATION
# =============================================================================

install_reset_script() {
    local dest="${WGM_DIR}/reset.sh"
    local url="${GITHUB_RAW}/reset.sh"
    local tmp
    tmp="$(mktemp)"
    local downloaded=false

    # Try GitHub first
    if curl -sf --max-time 30 -o "${tmp}" "${url}" \
        && [[ -s "${tmp}" ]] \
        && head -1 "${tmp}" | grep -q '^#!'; then
        mv "${tmp}" "${dest}"
        downloaded=true
    else
        rm -f "${tmp}"
    fi

    # Fallback: embed reset.sh inline so it's always available
    # even if the repo doesn't have it yet or GitHub is unreachable
    cat > "${dest}" <<'RESET_EMBED'
#!/usr/bin/env bash
# WireGuard Manager — Clean Reset (embedded fallback)
# For the latest version: https://raw.githubusercontent.com/zedofficial/wireguard-manager/main/reset.sh
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
[[ "$EUID" -ne 0 ]] && { echo -e "${RED}  Run as root: sudo wg-reset${RESET}"; exit 1; }
echo ""
echo -e "${YELLOW}${BOLD}  WireGuard Manager — Clean Reset${RESET}"
echo -e "  ${RED}All WireGuard data, clients, Docker containers, and configs will be deleted.${RESET}"
echo ""
read -rp "  Type 'yes' to confirm: " confirm
[[ "${confirm}" != "yes" ]] && { echo "  Cancelled."; exit 0; }
echo ""
echo -e "${CYAN}  Stopping WireGuard...${RESET}"
systemctl stop wg-quick@wg0 2>/dev/null || true
systemctl disable wg-quick@wg0 2>/dev/null || true
echo -e "${GREEN}  ✔ WireGuard stopped.${RESET}"
if command -v docker &>/dev/null; then
    echo -e "${CYAN}  Removing Docker and Uptime Kuma...${RESET}"
    docker stop uptime-kuma 2>/dev/null || true
    docker rm uptime-kuma 2>/dev/null || true
    docker volume rm uptime-kuma 2>/dev/null || true
    systemctl stop docker 2>/dev/null || true
    systemctl stop docker.socket 2>/dev/null || true
    systemctl disable docker 2>/dev/null || true
    apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    apt-get remove -y docker docker.io 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/docker.asc
    echo -e "${GREEN}  ✔ Docker removed.${RESET}"
fi
echo -e "${CYAN}  Removing WireGuard packages...${RESET}"
apt-get remove -y wireguard wireguard-tools 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
echo -e "${GREEN}  ✔ Packages removed.${RESET}"
rm -rf /etc/wireguard && echo -e "${GREEN}  ✔ /etc/wireguard removed.${RESET}"
rm -rf /opt/wireguard  && echo -e "${GREEN}  ✔ /opt/wireguard removed.${RESET}"
rm -f /usr/local/bin/wg-add-client /usr/local/bin/wg-delete-client /usr/local/bin/wg-show-client \
      /usr/local/bin/wg-list-clients /usr/local/bin/wg-disable-client /usr/local/bin/wg-enable-client \
      /usr/local/bin/wg-rename-client /usr/local/bin/wg-export-client /usr/local/bin/wg-import-client \
      /usr/local/bin/wg-regen-qr /usr/local/bin/wg-update /usr/local/bin/wg-check-update \
      /usr/local/bin/wg-dashboard-passwd /usr/local/bin/wg-reset
echo -e "${GREEN}  ✔ Scripts removed.${RESET}"
rm -f /etc/cron.d/wireguard-ddns /etc/cron.d/wireguard-backup /etc/cron.d/wireguard-update-check
rm -f /etc/sysctl.d/99-wireguard-manager.conf
sysctl -w net.ipv4.ip_forward=0 > /dev/null 2>&1 || true
rm -f /etc/sudoers.d/wireguard-manager
if [[ -d /var/www/html/wireguard-manager ]]; then
    rm -rf /var/www/html/wireguard-manager
    a2dissite wireguard-manager.conf > /dev/null 2>&1 || true
    rm -f /etc/apache2/sites-available/wireguard-manager.conf
    systemctl reload apache2 2>/dev/null || true
    echo -e "${GREEN}  ✔ Dashboard removed.${RESET}"
fi
if command -v ufw &>/dev/null; then
    ufw delete allow 51820/udp > /dev/null 2>&1 || true
    ufw delete allow 80/tcp    > /dev/null 2>&1 || true
    ufw delete allow 443/tcp   > /dev/null 2>&1 || true
    ufw delete allow 3001/tcp  > /dev/null 2>&1 || true
    ufw delete allow 22/tcp    > /dev/null 2>&1 || true
    ufw delete allow OpenSSH   > /dev/null 2>&1 || true
    echo -e "${GREEN}  ✔ UFW rules removed.${RESET}"
fi
rm -rf /var/log/wireguard-manager && echo -e "${GREEN}  ✔ Logs removed.${RESET}"
echo ""
echo -e "${GREEN}${BOLD}  Reset complete. System is clean.${RESET}"
echo -e "  Run: ${CYAN}sudo bash install.sh${RESET}"
echo ""
SCRIPT_PATH="$(realpath "$0")"
rm -f "${SCRIPT_PATH}"
RESET_EMBED

    chmod 700 "${dest}"
    print_success "Reset script embedded and ready."

    # Step 2: Try to upgrade from GitHub (newer version may be available)
    local tmp
    tmp="$(mktemp)"
    if curl -sf --max-time 30 -o "${tmp}" "${GITHUB_RAW}/reset.sh" \
        && [[ -s "${tmp}" ]] \
        && head -1 "${tmp}" | grep -q '^#!'; then
        mv "${tmp}" "${dest}"
        chmod 700 "${dest}"
        print_success "Reset script updated from GitHub."
        log_success "reset.sh updated from GitHub."
    else
        rm -f "${tmp}"
        log_info "Using embedded reset.sh (GitHub version not available)."
    fi

    # Step 3: Install wg-reset command in /usr/local/bin
    cat > "${BIN_DIR}/wg-reset" <<'WGRESET'
#!/usr/bin/env bash
# WireGuard Manager — Reset shortcut
RESET_SCRIPT="/opt/wireguard/reset.sh"
[[ "$EUID" -ne 0 ]] && { echo "Run as root: sudo wg-reset"; exit 1; }
if [[ ! -f "${RESET_SCRIPT}" ]]; then
    echo "reset.sh not found. Downloading..."
    curl -fsSL https://raw.githubusercontent.com/zedofficial/wireguard-manager/main/reset.sh \
        -o "${RESET_SCRIPT}" && chmod 700 "${RESET_SCRIPT}" || { echo "Download failed."; exit 1; }
fi
exec bash "${RESET_SCRIPT}" "$@"
WGRESET
    chmod +x "${BIN_DIR}/wg-reset"

    print_success "wg-reset command installed. Run anytime with: sudo wg-reset"
    log_success "reset.sh ready at ${dest} | wg-reset installed."
}

# =============================================================================

verify_installation() {
    print_step "Verifying Installation"
    local all_ok=true

    # WireGuard running
    if systemctl is-active --quiet wg-quick@wg0; then
        print_success "WireGuard service: running"
    else
        print_error "WireGuard service: NOT running"
        all_ok=false
    fi

    # wg0 interface exists
    if ip link show wg0 &>/dev/null; then
        print_success "wg0 interface: up"
    else
        print_error "wg0 interface: NOT found"
        all_ok=false
    fi

    # IP forwarding
    local fwd
    fwd="$(cat /proc/sys/net/ipv4/ip_forward)"
    if [[ "${fwd}" == "1" ]]; then
        print_success "IP forwarding: enabled"
    else
        print_warn "IP forwarding: not enabled"
    fi

    # Port listening
    if ss -ulnp | grep -q ":${WG_PORT}"; then
        print_success "WireGuard port ${WG_PORT}/UDP: listening"
    else
        print_warn "Port ${WG_PORT}/UDP not visible in ss output (may still be OK)"
    fi

    # Internet connectivity
    if curl -sf --max-time 5 https://1.1.1.1 > /dev/null 2>&1; then
        print_success "Internet: reachable"
    else
        print_warn "Internet: not reachable (check NAT rules)"
    fi

    # Client scripts
    for cmd in wg-add-client wg-delete-client wg-show-client wg-list-clients; do
        if [[ -x "${BIN_DIR}/${cmd}" ]]; then
            print_success "${cmd}: installed"
        else
            print_error "${cmd}: missing"
            all_ok=false
        fi
    done

    if [[ "${all_ok}" == true ]]; then
        log_success "All verification checks passed."
    else
        log_warn "Some verification checks failed — review above."
    fi
}

# =============================================================================
# COMPLETION SUMMARY
# =============================================================================

print_completion() {
    print_header
    echo -e "${GREEN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║        Installation Complete!                        ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    echo -e "  ${BOLD}WireGuard is running and ready.${RESET}\n"
    echo -e "  ${CYAN}VPN Endpoint   :${RESET} ${SERVER_ENDPOINT}:${WG_PORT}"
    echo -e "  ${CYAN}VPN Subnet     :${RESET} ${VPN_SUBNET}"
    echo -e "  ${CYAN}Server Key     :${RESET} $(cat /etc/wireguard/server_public.key)"

    echo -e "\n  ${BOLD}Client Commands:${RESET}"
    echo -e "  ${CYAN}wg-add-client    <name>${RESET}         — Add a new client"
    echo -e "  ${CYAN}wg-delete-client <name>${RESET}         — Remove a client"
    echo -e "  ${CYAN}wg-disable-client <name>${RESET}        — Disable (without deleting)"
    echo -e "  ${CYAN}wg-enable-client  <name>${RESET}        — Re-enable a disabled client"
    echo -e "  ${CYAN}wg-rename-client  <old> <new>${RESET}   — Rename a client"
    echo -e "  ${CYAN}wg-export-client  <name>${RESET}        — Export config + QR"
    echo -e "  ${CYAN}wg-import-client  <name> <file>${RESET} — Import existing config"
    echo -e "  ${CYAN}wg-show-client    <name>${RESET}         — Show config + QR"
    echo -e "  ${CYAN}wg-regen-qr       <name>${RESET}         — Regenerate QR (keys unchanged)"
    echo -e "  ${CYAN}wg-list-clients${RESET}                 — List all clients"

    echo -e "\n  ${BOLD}Updates:${RESET}"
    echo -e "  ${CYAN}wg-update${RESET}              — Apply latest update from GitHub"
    echo -e "  ${CYAN}wg-update --check${RESET}      — Check if update is available"

    if [[ "${INSTALL_DASHBOARD}" == true ]]; then
        # Detect internal/LAN IP for dashboard access
        local internal_ip
        internal_ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo 'your-server-ip')"
        echo -e "\n  ${BOLD}Dashboard:${RESET}"
        echo -e "  ${CYAN}URL      :${RESET} http://${internal_ip}:80"
        echo -e "  ${CYAN}Password :${RESET} admin ${YELLOW}(change with: wg-dashboard-passwd)${RESET}"
    fi

    if [[ "${INSTALL_KUMA}" == true ]]; then
        local internal_ip
        internal_ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo 'your-server-ip')"
        echo -e "\n  ${BOLD}Uptime Kuma:${RESET}"
        echo -e "  ${CYAN}URL      :${RESET} http://${internal_ip}:3001"
    fi

    if [[ "${DDNS_NAME}" != "None" ]]; then
        echo -e "\n  ${BOLD}Dynamic DNS:${RESET}"
        echo -e "  ${CYAN}Provider :${RESET} ${DDNS_NAME}"
        echo -e "  ${CYAN}Script   :${RESET} ${WGM_DDNS_DIR}/update.sh"
        echo -e "  ${CYAN}Cron     :${RESET} Every 5 minutes"
    fi

    if [[ "${INSTALL_BACKUP}" == true ]]; then
        echo -e "\n  ${BOLD}Backups:${RESET}"
        echo -e "  ${CYAN}Location :${RESET} ${WGM_DIR}/backups/"
        echo -e "  ${CYAN}Schedule :${RESET} Daily at 2:00 AM"
        echo -e "  ${CYAN}Manual   :${RESET} bash ${WGM_BACKUP_SCRIPT}"
    fi

    echo -e "\n  ${BOLD}Logs:${RESET} ${WGM_LOG_DIR}/"
    echo -e "  ${BOLD}Reset:${RESET} sudo wg-reset"
    echo -e "\n  ${YELLOW}Add your first client:${RESET}  wg-add-client myfirstdevice\n"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    check_not_piped
    setup_logging
    check_root
    print_header
    check_os
    check_internet
    check_existing_wireguard

    # Interactive questions
    ask_hostname
    ask_vpn_subnet
    ask_endpoint
    ask_port
    ask_interface
    ask_dns
    ask_ddns
    ask_ipv6
    ask_optional_components
    confirm_summary

    # Installation steps
    print_header
    echo -e "\n${CYAN}${BOLD}  Starting installation...${RESET}\n"

    install_packages
    generate_server_keys
    create_wg_conf
    enable_ip_forwarding
    configure_firewall
    start_wireguard
    install_client_scripts
    install_updater
    setup_ddns
    setup_backup
    setup_uptime_kuma
    setup_dashboard
    install_reset_script

    verify_installation
    print_completion
}

main "$@"

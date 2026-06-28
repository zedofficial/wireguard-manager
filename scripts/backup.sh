#!/usr/bin/env bash
# =============================================================================
# backup.sh
# WireGuard Manager — Backup Script
#
# Creates a timestamped .tar.gz of all WireGuard Manager data and keeps the
# last 7 backups. Run manually with `sudo bash /opt/wireguard/backup.sh` or
# automatically via the daily cron job installed at /etc/cron.d/wireguard-backup.
#
# Backs up:
#   - /etc/wireguard/            (server + all client keys and configs)
#   - /opt/wireguard/clients.db  (client registry)
#   - /opt/wireguard/config.env  (runtime settings)
#   - /opt/wireguard/ddns/       (DDNS update script — includes credentials)
# =============================================================================
set -euo pipefail

BACKUP_DIR="/opt/wireguard/backups"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_FILE="${BACKUP_DIR}/wgm_backup_${TIMESTAMP}.tar.gz"
LOG_FILE="/var/log/wireguard-manager/backup.log"

mkdir -p "${BACKUP_DIR}"

echo "$(date) Starting backup..." >> "${LOG_FILE}"

tar -czf "${BACKUP_FILE}" \
    /etc/wireguard/ \
    /opt/wireguard/clients.db \
    /opt/wireguard/config.env \
    /opt/wireguard/ddns/ \
    2>/dev/null || true

# Keep only the last 7 backups
ls -t "${BACKUP_DIR}"/wgm_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null || true

echo "$(date) Backup saved: ${BACKUP_FILE}" >> "${LOG_FILE}"

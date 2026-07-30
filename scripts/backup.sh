#!/usr/bin/env bash
# =============================================================================
# backup.sh
# WireGuard Manager — Backup Script
#
# Creates a timestamped .tar.gz of all WireGuard Manager data and keeps the
# last 7 backups. Run manually with `sudo /opt/wireguard/backup.sh` or
# automatically via the daily cron job at /etc/cron.d/wireguard-backup.
#
# The archive contains private keys, preshared keys, client configs and DDNS
# credentials, so it is created with umask 077 (owner-only, 0600). The backup is
# written to a temp file, verified with `tar -tzf`, and only then atomically
# renamed into place — a failed or truncated backup is never reported as success.
#
# Backs up:
#   - /etc/wireguard/            (server + all client keys and configs)
#   - /opt/wireguard/clients.db  (client registry)
#   - /opt/wireguard/config.env  (runtime settings)
#   - /opt/wireguard/ddns/       (DDNS update script — includes credentials)
# =============================================================================
set -euo pipefail

# Secrets inside — keep every file this script creates owner-only.
umask 077

BACKUP_DIR="/opt/wireguard/backups"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_FILE="${BACKUP_DIR}/wgm_backup_${TIMESTAMP}.tar.gz"
TMP_FILE="${BACKUP_DIR}/.wgm_backup_${TIMESTAMP}.tar.gz.partial"
LOG_FILE="/var/log/wireguard-manager/backup.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "${LOG_FILE}"; }
fail() { log "[ERROR] $*"; rm -f "${TMP_FILE}"; exit 1; }

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}" 2>/dev/null || true

log "Starting backup..."

# Only archive sources that exist; a missing required source is a real failure.
SOURCES=()
[[ -d /etc/wireguard ]]           && SOURCES+=("/etc/wireguard/")
[[ -f /opt/wireguard/clients.db ]] && SOURCES+=("/opt/wireguard/clients.db")
[[ -f /opt/wireguard/config.env ]] && SOURCES+=("/opt/wireguard/config.env")
[[ -d /opt/wireguard/ddns ]]      && SOURCES+=("/opt/wireguard/ddns/")

if [[ ${#SOURCES[@]} -eq 0 ]]; then
    fail "nothing to back up (no source files found)"
fi

# Create the archive. Do NOT swallow tar's exit status — we need to know if it failed.
if ! tar -czf "${TMP_FILE}" "${SOURCES[@]}" 2>>"${LOG_FILE}"; then
    fail "tar failed while creating the archive"
fi

# Verify the archive is readable and non-empty before trusting it.
if [[ ! -s "${TMP_FILE}" ]]; then
    fail "archive is empty"
fi
if ! tar -tzf "${TMP_FILE}" >/dev/null 2>&1; then
    fail "archive failed verification (tar -tzf)"
fi

# Atomically move the verified archive into place.
chmod 600 "${TMP_FILE}"
mv -f "${TMP_FILE}" "${BACKUP_FILE}"

# Keep only the last 7 good backups.
ls -t "${BACKUP_DIR}"/wgm_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f 2>/dev/null || true

SIZE="$(du -h "${BACKUP_FILE}" 2>/dev/null | cut -f1)"
log "Backup OK: ${BACKUP_FILE} (${SIZE:-?})"
echo "OK: ${BACKUP_FILE}"

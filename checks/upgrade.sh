#!/usr/bin/env bash
# =============================================================================
# checks/upgrade.sh — end-to-end upgrade, rollback and restore tests.
#
# DESTRUCTIVE. Run this ONLY on a disposable VM you can throw away, never on a
# server anyone relies on. It deliberately breaks an update halfway through and
# deletes /etc/wireguard to prove the recovery paths work.
#
# What it proves, in order of how much it matters:
#   1. An update never touches your keys, wg0.conf or clients.db.
#   2. A failed update rolls the whole install back on its own.
#   3. `wg-update --rollback` puts the previous version back on demand.
#   4. A backup archive can actually rebuild a destroyed install.
#
# ---------------------------------------------------------------------------
# Setting up the VM (do this once, then snapshot it):
#   1. Clean VM on a supported OS (Debian 12+, Ubuntu 22.04+, Raspberry Pi OS,
#      Armbian).
#   2. Install an OLDER release, e.g.
#        curl -fsSL https://raw.githubusercontent.com/zedofficial/wireguard-manager/v1.1.0/install.sh -o install.sh
#        sudo bash install.sh
#   3. Create real state — add two or three clients, set a dashboard password.
#   4. SNAPSHOT THE VM. Every future run is then a revert away, not a rebuild.
#
# Running:
#   sudo bash checks/upgrade.sh --disposable            # everything
#   sudo bash checks/upgrade.sh --disposable update     # just the upgrade test
#
# Tests are self-restoring and can run back to back, but reverting to the
# snapshot between runs is still the cleanest way to work.
#
# Paste the output into a bug report — every line is an assertion with a verdict.
# =============================================================================
set -uo pipefail

# Overridable so the fingerprint helpers can be exercised against a fake tree
# without a live install — see checks/upgrade_selftest.sh.
WGM_DIR="${WGM_DIR:-/opt/wireguard}"
WG_CONF_DIR="${WG_CONF_DIR:-/etc/wireguard}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
DASHBOARD_DIR="${DASHBOARD_DIR:-/var/www/html/wireguard-manager}"
VERSION_FILE="${WGM_DIR}/version"
WG_IF="${WG_IF:-wg0}"

pass=0; fail=0; skip=0
ok()   { echo "  PASS  $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail+1)); }
skp()  { echo "  SKIP  $*"; skip=$((skip+1)); }
info() { echo "        $*"; }
head2(){ echo ""; echo "=== $* ==="; }

assert_eq() {   # <label> <got> <want>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}

# ---- Fingerprints -----------------------------------------------------------
# One hash over every byte of user data the updater promises never to touch.
fp_userdata() {
    {
        [[ -d "${WG_CONF_DIR}" ]] && find "${WG_CONF_DIR}" -type f -print0 \
            | sort -z | xargs -0 sha256sum 2>/dev/null
        [[ -f "${WGM_DIR}/clients.db" ]] && sha256sum "${WGM_DIR}/clients.db"
    } 2>/dev/null | sha256sum | awk '{print $1}'
}
fp_peers()   { wg show "${WG_IF}" peers 2>/dev/null | sort | sha256sum | awk '{print $1}'; }
cur_ver()    { tr -d '[:space:]' < "${VERSION_FILE}" 2>/dev/null || echo 'unknown'; }
client_cnt() { "${BIN_DIR}/wg-list-clients" 2>/dev/null | grep -c . || echo 0; }

# ---- Shared assertions ------------------------------------------------------
assert_install_sane() {
    local missing=0 broken=0 n=0
    for f in "${BIN_DIR}"/wg-*; do
        [[ -e "$f" ]] || continue
        n=$((n+1))
        [[ -x "$f" ]] || missing=1
        bash -n "$f" 2>/dev/null || broken=1
    done
    [[ ${n} -gt 0 ]] && ok "${n} wg-* commands installed" || bad "no wg-* commands found"
    assert_eq "all commands executable" "${missing}" "0"
    assert_eq "all commands parse"      "${broken}"  "0"

    if [[ -f /etc/sudoers.d/wireguard-manager ]]; then
        if visudo -cf /etc/sudoers.d/wireguard-manager >/dev/null 2>&1; then
            ok "sudoers valid"
        else
            bad "sudoers REJECTED by visudo — dashboard actions will break"
        fi
    else
        skp "sudoers file not present (dashboard not installed?)"
    fi

    if [[ -d "${DASHBOARD_DIR}" ]]; then
        local phpbad=0
        for f in "${DASHBOARD_DIR}"/*.php; do
            [[ -e "$f" ]] || continue
            php -l "$f" >/dev/null 2>&1 || phpbad=1
        done
        assert_eq "dashboard PHP parses" "${phpbad}" "0"
        if systemctl is-active --quiet apache2; then ok "apache2 running"; else bad "apache2 not running"; fi
        info "dashboard HTTP status: $(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1/ 2>/dev/null || echo unreachable)"
    else
        skp "dashboard not installed"
    fi

    if wg show "${WG_IF}" >/dev/null 2>&1; then
        ok "${WG_IF} is up"
    else
        bad "${WG_IF} is DOWN"
    fi
}

# ---- 1. Upgrade -------------------------------------------------------------
test_update() {
    head2 "1. update preserves user data"
    local v0 fp0 peers0 clients0 v1 fp1 peers1 clients1
    v0="$(cur_ver)"; fp0="$(fp_userdata)"; peers0="$(fp_peers)"; clients0="$(client_cnt)"
    info "installed version: ${v0}, clients: ${clients0}"

    if ! "${BIN_DIR}/wg-update" --yes; then
        bad "wg-update exited non-zero"
        return
    fi

    v1="$(cur_ver)"; fp1="$(fp_userdata)"; peers1="$(fp_peers)"; clients1="$(client_cnt)"

    # The assertion that matters most: not one byte of key material moved.
    assert_eq "/etc/wireguard + clients.db byte-identical" "${fp1}" "${fp0}"
    assert_eq "peer list unchanged"                        "${peers1}" "${peers0}"
    assert_eq "client count unchanged"                     "${clients1}" "${clients0}"
    if [[ "${v1}" != "${v0}" ]]; then ok "version advanced ${v0} -> ${v1}"; else skp "already latest (${v0})"; fi

    if grep -q "WGM_VERSION=\"${v1}\"" "${WGM_DIR}/config.env" 2>/dev/null; then
        ok "config.env version in sync"
    else
        bad "config.env WGM_VERSION out of sync with ${VERSION_FILE}"
    fi

    local bk
    bk="$(ls -t "${WGM_DIR}"/backups/pre-update/pre_update_*.tar.gz 2>/dev/null | head -n1)"
    if [[ -n "${bk}" ]] && tar -tzf "${bk}" >/dev/null 2>&1; then
        ok "pre-update backup written and verifiable"
    else
        bad "no valid pre-update backup was created"
    fi

    assert_install_sane
}

# ---- 2. Rollback on a failed deploy ----------------------------------------
# chattr +i is the cleanest deterministic mid-deploy failure: even root cannot
# overwrite an immutable file, so `install` fails partway through the loop.
test_rollback_on_failure() {
    head2 "2. a failed update rolls itself back"
    local victim="${BIN_DIR}/wg-list-clients"

    if ! command -v chattr >/dev/null 2>&1 || ! chattr +i "${victim}" 2>/dev/null; then
        skp "cannot set immutable flag (needs e2fsprogs on ext4) — failure not injectable here"
        return
    fi

    local v0 fp0 sums0
    v0="$(cur_ver)"; fp0="$(fp_userdata)"
    sums0="$(sha256sum "${BIN_DIR}"/wg-* 2>/dev/null | sha256sum | awk '{print $1}')"
    info "injected failure: ${victim} is immutable"

    "${BIN_DIR}/wg-update" --force --yes >/tmp/wgm_rb.log 2>&1
    local rc=$?
    chattr -i "${victim}" 2>/dev/null

    assert_eq "wg-update reported failure" "$([[ ${rc} -ne 0 ]] && echo yes || echo no)" "yes"

    # The rollback path must have run. Don't insist it reported total success:
    # the immutable file we used to break the deploy also blocks the restore of
    # that one (unmodified) file, so "incomplete" is the honest answer here. What
    # actually matters is the file state asserted below.
    if grep -qiE "rolled back|rollback (incomplete|unavailable)" /tmp/wgm_rb.log; then
        ok "rollback path ran"
        info "reported: $(grep -oiE "rolled back to [^ ]+|rollback incomplete|rollback unavailable" /tmp/wgm_rb.log | head -1)"
    else
        bad "no rollback attempted — see /tmp/wgm_rb.log"
    fi

    local sums1
    sums1="$(sha256sum "${BIN_DIR}"/wg-* 2>/dev/null | sha256sum | awk '{print $1}')"
    assert_eq "all wg-* restored to pre-update content" "${sums1}" "${sums0}"
    assert_eq "version still ${v0}"                     "$(cur_ver)" "${v0}"
    assert_eq "user data untouched by the failure"      "$(fp_userdata)" "${fp0}"
    assert_install_sane

    info "re-running the update now the block is removed..."
    "${BIN_DIR}/wg-update" --force --yes >/dev/null 2>&1 \
        && ok "update succeeds once the cause is fixed" \
        || bad "update still fails after clearing the immutable flag"
}

# ---- 3. Manual rollback -----------------------------------------------------
test_manual_rollback() {
    head2 "3. wg-update --rollback"
    local before after
    before="$(sha256sum "${BIN_DIR}"/wg-* 2>/dev/null | sha256sum | awk '{print $1}')"

    if ! "${BIN_DIR}/wg-update" --rollback --yes >/tmp/wgm_mr.log 2>&1; then
        bad "--rollback exited non-zero — see /tmp/wgm_mr.log"
        return
    fi
    ok "--rollback completed"
    after="$(sha256sum "${BIN_DIR}"/wg-* 2>/dev/null | sha256sum | awk '{print $1}')"
    if [[ "${before}" != "${after}" ]]; then
        ok "commands changed back to the previous release"
    else
        skp "nothing changed (no newer version had been installed)"
    fi
    assert_install_sane

    info "returning to latest..."
    "${BIN_DIR}/wg-update" --yes >/dev/null 2>&1 || true
}

# ---- 4. Backup and restore --------------------------------------------------
# The path nobody tests until they need it: can the archive rebuild the install?
test_backup_restore() {
    head2 "4. a backup can rebuild a destroyed install"
    if [[ ! -x "${WGM_DIR}/backup.sh" ]]; then
        skp "backup.sh not installed"
        return
    fi

    local fp0 clients0 arc
    fp0="$(fp_userdata)"; clients0="$(client_cnt)"

    "${WGM_DIR}/backup.sh" >/dev/null 2>&1 || { bad "backup.sh failed"; return; }
    arc="$(ls -t "${WGM_DIR}"/backups/wgm_backup_*.tar.gz 2>/dev/null | head -n1)"
    [[ -n "${arc}" ]] || { bad "no archive produced"; return; }
    ok "backup created: $(basename "${arc}")"

    assert_eq "archive is mode 600" "$(stat -c %a "${arc}")" "600"
    tar -tzf "${arc}" >/dev/null 2>&1 && ok "archive verifies" || { bad "archive corrupt"; return; }

    # Destroy the live install. This is why the header says disposable VM.
    info "destroying /etc/wireguard and clients.db..."
    wg-quick down "${WG_IF}" >/dev/null 2>&1 || true
    rm -rf "${WG_CONF_DIR:?}"/* "${WGM_DIR:?}/clients.db"
    assert_eq "destruction confirmed" "$(fp_userdata)" "$(printf '' | sha256sum | awk '{print $1}')"

    info "restoring from ${arc}..."
    if tar -xzf "${arc}" -C / 2>/dev/null; then ok "archive extracted"; else bad "restore failed"; return; fi

    assert_eq "user data byte-identical to pre-backup" "$(fp_userdata)" "${fp0}"
    assert_eq "client count restored"                  "$(client_cnt)" "${clients0}"

    if wg-quick up "${WG_IF}" >/dev/null 2>&1 || systemctl start "wg-quick@${WG_IF}" >/dev/null 2>&1; then
        ok "${WG_IF} came back up from restored config"
    else
        bad "${WG_IF} would not start after restore"
    fi
    info "existing client configs are unchanged, so clients reconnect without re-import."
}

# ---- Main -------------------------------------------------------------------
[[ "${EUID}" -eq 0 ]] || { echo "Run as root."; exit 1; }

DISPOSABLE=false; WHICH="all"
for a in "$@"; do
    case "$a" in
        --disposable) DISPOSABLE=true ;;
        update|rollback-fail|manual-rollback|backup-restore|all) WHICH="$a" ;;
    esac
done

if [[ "${DISPOSABLE}" != true ]]; then
    cat <<'WARN'
This test is DESTRUCTIVE. It breaks an update on purpose and deletes
/etc/wireguard to prove the recovery paths work.

Run it only on a throwaway VM, then re-run with --disposable:

    sudo bash checks/upgrade.sh --disposable
WARN
    exit 1
fi

[[ -d "${WGM_DIR}" ]] || { echo "WireGuard Manager is not installed at ${WGM_DIR}."; exit 1; }

echo "WireGuard Manager — upgrade/rollback/restore tests"
echo "OS: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}") | arch: $(uname -m) | version: $(cur_ver)"

case "${WHICH}" in
    update)          test_update ;;
    rollback-fail)   test_rollback_on_failure ;;
    manual-rollback) test_manual_rollback ;;
    backup-restore)  test_backup_restore ;;
    # Order matters: manual-rollback must run while the newest pre-update backup
    # still holds the OLD version. Running it after the --force updates below
    # would restore the same version onto itself and prove nothing.
    all)             test_update; test_manual_rollback; test_rollback_on_failure; test_backup_restore ;;
esac

echo ""
echo "==============================================="
echo "  ${pass} passed, ${fail} failed, ${skip} skipped"
[[ ${fail} -eq 0 ]] || exit 1

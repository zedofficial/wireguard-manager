#!/usr/bin/env bash
# =============================================================================
# checks/upgrade_selftest.sh — tests the test.
#
# checks/upgrade.sh can only run on a live install, so its assertions are easy to
# break without noticing. The one that would hurt most is fp_userdata(): if it
# ever returned a constant, every "your keys were not touched" assertion would
# pass whether or not that was true — a test that always succeeds is worse than
# no test, because it manufactures confidence.
#
# This exercises the real helpers from upgrade.sh against a fake tree. No root,
# no VM, no WireGuard — so CI can run it on every push.
#
# Note: the helpers are sourced into this shell, so this file deliberately uses
# t_* names for its own reporting. Reusing ok()/pass would collide with the
# library under test and make these results depend on the thing being tested.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

t_pass=0; t_fail=0
t_ok()  { echo "  ok:   $*"; t_pass=$((t_pass+1)); }
t_err() { echo "  FAIL: $*"; t_fail=$((t_fail+1)); }
t_is()  { if [[ "$2" == "$3" ]]; then t_ok "$1"; else t_err "$1 (got '$2', want '$3')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Pull in everything above the main section, so we test the shipped helpers
# rather than a copy of them that can drift.
awk '/^# ---- Main/{exit} {print}' checks/upgrade.sh > "${TMP}/lib.sh"
export WG_CONF_DIR="${TMP}/wg" WGM_DIR="${TMP}/opt"
mkdir -p "${WG_CONF_DIR}" "${WGM_DIR}"
# shellcheck disable=SC1091
source "${TMP}/lib.sh" || { echo "could not source helpers from checks/upgrade.sh"; exit 1; }

EMPTY_HASH="$(printf '' | sha256sum | awk '{print $1}')"

echo "== fp_userdata detects change =="

printf 'PrivateKey = abc\n' > "${WG_CONF_DIR}/wg0.conf"
printf 'client1\n'          > "${WGM_DIR}/clients.db"
base="$(fp_userdata)"

if [[ -n "${base}" && "${base}" != "${EMPTY_HASH}" ]]; then
    t_ok "a populated tree hashes to something real"
else
    t_err "a populated tree hashed to the empty value"
fi

t_is "stable across repeated calls" "$(fp_userdata)" "${base}"

changed() {   # <label> — asserts the current tree hashes differently to base
    if [[ "$(fp_userdata)" != "${base}" ]]; then t_ok "$1"; else t_err "$1 — NOT DETECTED"; fi
}

printf 'PrivateKey = abd\n' > "${WG_CONF_DIR}/wg0.conf"          # single byte
changed "one changed byte in a key file is detected"
printf 'PrivateKey = abc\n' > "${WG_CONF_DIR}/wg0.conf"

printf 'psk\n' > "${WG_CONF_DIR}/extra.conf"
changed "an added file is detected"
rm -f "${WG_CONF_DIR}/extra.conf"

mv "${WG_CONF_DIR}/wg0.conf" "${WG_CONF_DIR}/wg1.conf"
changed "a renamed file is detected (the path is part of the hash)"
mv "${WG_CONF_DIR}/wg1.conf" "${WG_CONF_DIR}/wg0.conf"

printf 'client1\nclient2\n' > "${WGM_DIR}/clients.db"
changed "a changed clients.db is detected"
printf 'client1\n' > "${WGM_DIR}/clients.db"

rm -f "${WGM_DIR}/clients.db"
changed "a deleted clients.db is detected"
printf 'client1\n' > "${WGM_DIR}/clients.db"

t_is "returns to the original hash once everything is put back" "$(fp_userdata)" "${base}"

echo ""
echo "== assert_eq reports honestly =="
# Run in subshells: assert_eq mutates the library's own pass/fail counters.
t_is "equal values pass"     "$( (assert_eq lbl a a) 2>&1 | grep -c PASS )" "1"
t_is "different values fail" "$( (assert_eq lbl a b) 2>&1 | grep -c FAIL )" "1"

echo ""
if [[ ${t_fail} -eq 0 ]]; then
    echo "UPGRADE SELFTEST PASSED (${t_pass} checks)"
else
    echo "UPGRADE SELFTEST FAILED (${t_fail} of $((t_pass+t_fail)))"
    exit 1
fi

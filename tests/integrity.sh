#!/usr/bin/env bash
# =============================================================================
# tests/integrity.sh — repo integrity checks (run from the repo root).
# Verifies the invariants that have regressed before: shell/PHP syntax, that
# heredoc-generated scripts still parse, that the manifest matches its bundled
# fallback, and that the inline sudoers matches the canonical file.
# Exits non-zero if anything fails. Used by CI and safe to run locally.
# =============================================================================
set -uo pipefail

fail=0
err() { echo "  FAIL: $*"; fail=1; }
ok()  { echo "  ok:   $*"; }
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "== shell syntax =="
for f in install.sh reset.sh scripts/*; do
    bash -n "$f" 2>/dev/null || err "bash -n $f"
done
ok "install.sh, reset.sh, scripts/*"

echo "== heredoc-generated scripts parse =="
awk "/<<UPDATER_BOOTSTRAP/{f=1;next} /^UPDATER_BOOTSTRAP\$/{f=0} f" install.sh > "${tmp}/boot.sh"
[[ -s "${tmp}/boot.sh" ]] && bash -n "${tmp}/boot.sh" 2>/dev/null || err "generated wg-update bootstrap"
awk "/<<'RESET_EMBED'/{f=1;next} /^RESET_EMBED\$/{f=0} f" install.sh > "${tmp}/reset.sh"
[[ -s "${tmp}/reset.sh" ]] && bash -n "${tmp}/reset.sh" 2>/dev/null || err "embedded reset.sh"
ok "wg-update bootstrap, embedded reset"

echo "== php syntax =="
if command -v php >/dev/null 2>&1; then
    for f in dashboard/*.php; do
        php -l "$f" >/dev/null 2>&1 || err "php -l $f"
    done
    ok "dashboard/*.php"
else
    echo "  skip: php not installed"
fi

echo "== manifest files exist =="
while read -r p; do
    [[ -z "$p" ]] && continue
    [[ -f "$p" ]] || err "manifest references missing file: $p"
done < <(grep -E '^(bin|web)[[:space:]]' manifest.txt | awk '{print $2}')
ok "every manifest path resolves"

echo "== bundled fallback manifest matches manifest.txt =="
awk "/<<'MANIFEST_FALLBACK'/{f=1;next} /^MANIFEST_FALLBACK\$/{f=0} f" install.sh \
    | grep -E '^(bin|web) ' | sort > "${tmp}/bundled.txt"
grep -E '^(bin|web)[[:space:]]' manifest.txt | sed -E 's/[[:space:]]+/ /g' | sort > "${tmp}/manifest.txt"
if ! diff -q "${tmp}/bundled.txt" "${tmp}/manifest.txt" >/dev/null; then
    err "install.sh bundled fallback manifest != manifest.txt"
    diff "${tmp}/bundled.txt" "${tmp}/manifest.txt" || true
else
    ok "bundled fallback == manifest.txt"
fi

echo "== inline sudoers matches canonical =="
awk "/<<'SUDOERS'/{f=1;next} /^SUDOERS\$/{f=0} f" install.sh | grep '^www-data' | sort > "${tmp}/si.txt"
grep '^www-data' wireguard-manager.sudoers | sort > "${tmp}/sc.txt"
if ! diff -q "${tmp}/si.txt" "${tmp}/sc.txt" >/dev/null; then
    err "install.sh inline sudoers != wireguard-manager.sudoers"
    diff "${tmp}/si.txt" "${tmp}/sc.txt" || true
else
    ok "inline sudoers == canonical"
fi

echo "== sudoers validates with visudo =="
if command -v visudo >/dev/null 2>&1; then
    visudo -cf wireguard-manager.sudoers >/dev/null 2>&1 || err "visudo -cf wireguard-manager.sudoers"
    ok "wireguard-manager.sudoers"
else
    echo "  skip: visudo not installed"
fi

echo "== version is semver =="
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' version || err "version file is not X.Y.Z"
ok "version = $(tr -d '[:space:]' < version)"

echo ""
if [[ $fail -eq 0 ]]; then
    echo "ALL INTEGRITY CHECKS PASSED"
else
    echo "INTEGRITY CHECKS FAILED"
    exit 1
fi

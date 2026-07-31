#!/usr/bin/env bash
# =============================================================================
# checks/integrity.sh — repo integrity checks (run from the repo root).
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
for f in install.sh reset.sh scripts/* checks/*.sh; do
    bash -n "$f" 2>/dev/null || err "bash -n $f"
done
ok "install.sh, reset.sh, scripts/*, checks/*.sh"

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

echo "== checksums.txt matches the working tree =="
# wg-update refuses to install any file whose hash is not in checksums.txt, so a
# stale list breaks every install's updater with what looks like a tampering
# error. tools/release.sh regenerates it; this catches the case where a deployable
# file changed without going through that path.
if [[ ! -s checksums.txt ]]; then
    err "checksums.txt is missing or empty"
elif ! sha256sum -c checksums.txt >/dev/null 2>&1; then
    err "checksums.txt is stale — re-run tools/release.sh"
    sha256sum -c checksums.txt 2>&1 | grep -v ': OK$' | head -20 || true
else
    ok "$(wc -l < checksums.txt | tr -d ' ') hashes match"
fi

echo "== every deployable file is listed in checksums.txt =="
missing=0
while read -r f; do
    [[ -z "$f" ]] && continue
    awk -v want="$f" '$2==want{f=1} END{exit !f}' checksums.txt \
        || { err "not listed in checksums.txt: $f"; missing=1; }
done < <({ printf '%s\n' install.sh version manifest.txt reset.sh wireguard-manager.sudoers
           find scripts dashboard -type f | sort; })
[[ $missing -eq 0 ]] && ok "install.sh, version, manifest, reset.sh, sudoers, scripts/*, dashboard/*"

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

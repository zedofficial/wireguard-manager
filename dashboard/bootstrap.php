<?php
// =============================================================================
// bootstrap.php — shared session + security setup for every dashboard entry.
// MUST be required at the very top of each page, before any output or session
// use. Replaces a bare session_start() so cookie flags, security headers, and
// password-change session invalidation are applied everywhere consistently.
// =============================================================================

// Harden the session cookie. `secure` is auto-enabled when the request is HTTPS
// so it works over plain HTTP on the LAN/VPN but tightens up if TLS is added.
$__wgm_https = (!empty($_SERVER['HTTPS']) && strtolower((string) $_SERVER['HTTPS']) !== 'off')
            || (($_SERVER['SERVER_PORT'] ?? '') === '443');
session_set_cookie_params([
    'lifetime' => 0,
    'path'     => '/',
    'httponly' => true,
    'samesite' => 'Strict',
    'secure'   => $__wgm_https,
]);
if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

// Baseline security headers. Kept conservative so they don't break the UI
// (no strict CSP — the dashboard loads Bootstrap from a CDN and uses inline styles).
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header('Referrer-Policy: no-referrer');

// Invalidate every existing session when the dashboard password changes: login
// stamps the password file's mtime into the session, and we force re-login here
// if it no longer matches. Closes the "old session stays valid after a password
// change" gap without needing to enumerate server-side session files.
if (isset($_SESSION['authenticated'], $_SESSION['pw_stamp'])) {
    if ($_SESSION['pw_stamp'] !== (string) @filemtime('/opt/wireguard/dashboard.passwd')) {
        $_SESSION = [];
        session_destroy();
        header('Location: login.php?timeout=1');
        exit;
    }
}

// Shared audit logger. Writes to a dashboard log the web user can actually append
// to (dashboard.log is created root:www-data 0664 by the installer) — install.log
// is root-only, so audit writes there silently no-op.
function wgm_audit(string $line): void {
    $ip = $_SERVER['REMOTE_ADDR'] ?? '-';
    @file_put_contents(
        '/var/log/wireguard-manager/dashboard.log',
        date('Y-m-d H:i:s') . " [{$ip}] {$line}\n",
        FILE_APPEND | LOCK_EX
    );
}

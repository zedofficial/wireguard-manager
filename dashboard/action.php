<?php
// =============================================================================
// action.php — WireGuard Manager — Action Handler
// Handles POST requests for WireGuard controls and wg-update.
// All actions require authentication and a valid CSRF token.
// Never called directly — always POSTed from the dashboard.
// =============================================================================
session_start();

// ---- Auth guard ----
if (!isset($_SESSION['authenticated'])) {
    http_response_code(403);
    header('Location: login.php');
    exit;
}

// ---- Session timeout ----
if (isset($_SESSION['login_time']) && (time() - $_SESSION['login_time']) > 3600) {
    session_destroy();
    header('Location: login.php?timeout=1');
    exit;
}

// ---- Only accept POST ----
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    header('Location: index.php');
    exit;
}

// ---- CSRF check ----
$submitted_csrf = $_POST['csrf'] ?? '';
if (!hash_equals($_SESSION['csrf'] ?? '', $submitted_csrf)) {
    http_response_code(403);
    header('Location: index.php?err=csrf');
    exit;
}

// ---- Allowed actions and their system commands ----
$allowed_actions = [
    'start'        => 'sudo systemctl start   wg-quick@wg0',
    'stop'         => 'sudo systemctl stop    wg-quick@wg0',
    'restart'      => 'sudo systemctl restart wg-quick@wg0',
    'reload'       => 'sudo systemctl reload  wg-quick@wg0',
    'update'       => 'sudo wg-update --force --yes 2>&1',
    'check_update' => 'sudo wg-check-update 2>&1',
];

$action = preg_replace('/[^a-z]/', '', $_POST['action'] ?? '');

if (!array_key_exists($action, $allowed_actions)) {
    header('Location: index.php?err=invalid_action');
    exit;
}

// ---- Determine redirect target ----
$redirect_map = [
    'start'        => 'index.php?msg=started',
    'stop'         => 'index.php?msg=stopped',
    'restart'      => 'index.php?msg=restarted',
    'reload'       => 'index.php?msg=reloaded',
    'update'       => 'config.php?msg=update_triggered',
    'check_update' => 'config.php?msg=check_triggered',
];

// ---- Execute command ----
$cmd    = $allowed_actions[$action];
$output = [];
$code   = 0;

exec($cmd . ' 2>&1', $output, $code);

// Log the action
$log_entry = date('Y-m-d H:i:s') . " [DASHBOARD] action={$action} exit={$code}\n";
@file_put_contents('/var/log/wireguard-manager/install.log', $log_entry, FILE_APPEND);

// ---- Redirect with result ----
$redirect = $redirect_map[$action];

if ($code !== 0 && $action !== 'update') {
    // On failure, pass a short error hint in the URL
    $err_hint = urlencode(implode(' ', array_slice($output, -2)));
    header("Location: index.php?err=action_failed&hint={$err_hint}");
} else {
    header("Location: {$redirect}");
}
exit;

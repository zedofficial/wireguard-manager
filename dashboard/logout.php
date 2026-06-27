<?php
// =============================================================================
// logout.php — WireGuard Manager — Logout
// Destroys the session and redirects to login.
// =============================================================================
session_start();
session_unset();
session_destroy();

// Clear session cookie
if (ini_get('session.use_cookies')) {
    $params = session_get_cookie_params();
    setcookie(
        session_name(),
        '',
        time() - 42000,
        $params['path'],
        $params['domain'],
        $params['secure'],
        $params['httponly']
    );
}

header('Location: login.php');
exit;

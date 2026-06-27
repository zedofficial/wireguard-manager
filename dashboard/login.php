<?php
// =============================================================================
// login.php — WireGuard Manager — Login
// Simple single-password login with CSRF and brute-force delay.
// =============================================================================
session_start();

// ---- Redirect if already authenticated ----
if (isset($_SESSION['authenticated'])) {
    header('Location: index.php');
    exit;
}

// ---- Session timeout message ----
$timeout = isset($_GET['timeout']);

// ---- Load stored password hash ----
$pass_file   = '/opt/wireguard/dashboard.passwd';
$stored_hash = file_exists($pass_file)
    ? trim(file_get_contents($pass_file))
    : password_hash('admin', PASSWORD_DEFAULT);

// ---- CSRF token ----
if (empty($_SESSION['csrf'])) {
    $_SESSION['csrf'] = bin2hex(random_bytes(32));
}

$error = '';

// ---- Handle login POST ----
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $submitted_csrf = $_POST['csrf'] ?? '';
    $submitted_pass = $_POST['password'] ?? '';

    if (!hash_equals($_SESSION['csrf'], $submitted_csrf)) {
        $error = 'Invalid request. Please try again.';
    } elseif (!$submitted_pass) {
        $error = 'Password is required.';
    } elseif (password_verify($submitted_pass, $stored_hash)) {
        // Regenerate session ID on successful login (session fixation protection)
        session_regenerate_id(true);
        $_SESSION['authenticated'] = true;
        $_SESSION['login_time']    = time();
        $_SESSION['csrf']          = bin2hex(random_bytes(32));
        header('Location: index.php');
        exit;
    } else {
        sleep(1); // Slow down brute force
        $error = 'Incorrect password.';
        // Regenerate CSRF on failed attempt
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign In — WireGuard Manager</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.css">
<style>
:root {
    --bg:      #0d1117;
    --surface: #161b22;
    --border:  #30363d;
    --text:    #c9d1d9;
    --muted:   #8b949e;
    --accent:  #58a6ff;
    --red:     #f85149;
    --green:   #3fb950;
    --radius:  .6rem;
}
*, *::before, *::after { box-sizing: border-box; }
html, body {
    height: 100%; margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    font-size: .9rem;
    display: flex;
    align-items: center;
    justify-content: center;
}

/* Subtle grid background */
body::before {
    content: '';
    position: fixed;
    inset: 0;
    background-image:
        linear-gradient(rgba(88,166,255,.03) 1px, transparent 1px),
        linear-gradient(90deg, rgba(88,166,255,.03) 1px, transparent 1px);
    background-size: 40px 40px;
    pointer-events: none;
}

.login-wrap {
    width: 100%;
    max-width: 360px;
    padding: 1rem;
    position: relative;
    z-index: 1;
}

.login-card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 2rem 2rem 1.75rem;
}

.login-brand {
    text-align: center;
    margin-bottom: 1.75rem;
}
.login-brand .icon {
    font-size: 2rem;
    color: var(--accent);
    display: block;
    margin-bottom: .5rem;
}
.login-brand h1 {
    font-size: 1.1rem;
    font-weight: 700;
    margin: 0 0 .2rem;
    color: var(--text);
}
.login-brand .sub {
    font-size: .78rem;
    color: var(--muted);
}

.form-label {
    display: block;
    color: var(--muted);
    font-size: .78rem;
    margin-bottom: .3rem;
}
.form-control {
    width: 100%;
    background: #21262d;
    border: 1px solid var(--border);
    color: var(--text);
    border-radius: var(--radius);
    padding: .55rem .75rem;
    font-size: .88rem;
    outline: none;
    transition: border-color .15s, box-shadow .15s;
}
.form-control:focus {
    border-color: var(--accent);
    box-shadow: 0 0 0 3px rgba(88,166,255,.12);
}
.form-control::placeholder { color: var(--muted); }

.btn-login {
    width: 100%;
    background: var(--accent);
    color: #0d1117;
    border: none;
    border-radius: var(--radius);
    padding: .6rem;
    font-size: .88rem;
    font-weight: 600;
    cursor: pointer;
    transition: background .15s;
    margin-top: 1.25rem;
}
.btn-login:hover { background: #79b8ff; }
.btn-login:active { background: #388bfd; }

.alert-error {
    background: rgba(248,81,73,.1);
    border: 1px solid rgba(248,81,73,.3);
    border-radius: var(--radius);
    color: var(--red);
    padding: .55rem .75rem;
    font-size: .82rem;
    margin-bottom: 1rem;
    display: flex;
    align-items: center;
    gap: .5rem;
}
.alert-timeout {
    background: rgba(210,153,34,.1);
    border: 1px solid rgba(210,153,34,.3);
    border-radius: var(--radius);
    color: #d29922;
    padding: .55rem .75rem;
    font-size: .82rem;
    margin-bottom: 1rem;
    display: flex;
    align-items: center;
    gap: .5rem;
}

.login-footer {
    text-align: center;
    margin-top: 1.25rem;
    color: var(--muted);
    font-size: .72rem;
    line-height: 1.5;
}
.login-footer code {
    background: #21262d;
    color: var(--accent);
    border-radius: .3rem;
    padding: .1rem .35rem;
    font-size: .7rem;
}

/* Password show/hide toggle */
.pass-wrap { position: relative; }
.pass-toggle {
    position: absolute;
    right: .6rem;
    top: 50%;
    transform: translateY(-50%);
    background: none;
    border: none;
    color: var(--muted);
    cursor: pointer;
    font-size: .9rem;
    padding: 0;
    line-height: 1;
}
.pass-toggle:hover { color: var(--text); }
</style>
</head>
<body>

<div class="login-wrap">
    <div class="login-card">

        <div class="login-brand">
            <i class="bi bi-shield-lock-fill icon"></i>
            <h1>WireGuard Manager</h1>
            <span class="sub">Enter your dashboard password to continue</span>
        </div>

        <?php if ($timeout): ?>
        <div class="alert-timeout">
            <i class="bi bi-clock"></i>
            Session expired. Please sign in again.
        </div>
        <?php endif; ?>

        <?php if ($error): ?>
        <div class="alert-error">
            <i class="bi bi-exclamation-circle"></i>
            <?= htmlspecialchars($error) ?>
        </div>
        <?php endif; ?>

        <form method="POST" autocomplete="off">
            <input type="hidden" name="csrf" value="<?= htmlspecialchars($_SESSION['csrf']) ?>">

            <div style="margin-bottom:1rem;">
                <label class="form-label" for="password">Password</label>
                <div class="pass-wrap">
                    <input
                        type="password"
                        id="password"
                        name="password"
                        class="form-control"
                        placeholder="••••••••••"
                        autofocus
                        required
                        autocomplete="current-password"
                    >
                    <button type="button" class="pass-toggle" onclick="togglePass()" id="pass-btn">
                        <i class="bi bi-eye" id="pass-icon"></i>
                    </button>
                </div>
            </div>

            <button type="submit" class="btn-login">
                <i class="bi bi-box-arrow-in-right me-1"></i>Sign In
            </button>
        </form>

    </div>

    <div class="login-footer">
        Default password: <code>admin</code><br>
        Change it on the server: <code>sudo wg-dashboard-passwd</code>
    </div>
</div>

<script>
function togglePass() {
    const inp = document.getElementById('password');
    const ico = document.getElementById('pass-icon');
    if (inp.type === 'password') {
        inp.type = 'text';
        ico.className = 'bi bi-eye-slash';
    } else {
        inp.type = 'password';
        ico.className = 'bi bi-eye';
    }
}
</script>
</body>
</html>

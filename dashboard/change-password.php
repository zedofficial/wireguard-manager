<?php
// =============================================================================
// change-password.php — WireGuard Manager — Change dashboard password
// Standalone page (no sidebar) so a forced change can't be navigated around.
// Reached automatically by layout.php while the password is still the default,
// and usable any time to change the password.
// =============================================================================
session_start();

// ---- Auth guard ----
if (!isset($_SESSION['authenticated'])) {
    header('Location: login.php');
    exit;
}

// ---- Is the password still the default 'admin'? ----
function password_is_default(): bool {
    $h = @file_get_contents('/opt/wireguard/dashboard.passwd');
    return $h !== false && password_verify('admin', trim($h));
}
$forced = password_is_default();

if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(32));

$error = '';
$ok    = false;

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $new     = $_POST['new_password'] ?? '';
    $confirm = $_POST['confirm_password'] ?? '';

    if (!hash_equals($_SESSION['csrf'] ?? '', $_POST['csrf'] ?? '')) {
        $error = 'Invalid request. Please try again.';
    } elseif (strlen($new) < 6) {
        $error = 'Password must be at least 6 characters.';
    } elseif ($new !== $confirm) {
        $error = 'Passwords do not match.';
    } elseif ($new === 'admin') {
        $error = 'Pick something other than the default "admin".';
    } else {
        // Hand the new password to the privileged helper via stdin (not argv).
        $out = [];
        $code = 0;
        exec('printf %s ' . escapeshellarg($new) . ' | sudo /usr/local/bin/wg-dashboard-passwd --stdin 2>&1', $out, $code);
        if ($code === 0 && in_array('OK', $out, true)) {
            $ok = true;
            $_SESSION['csrf'] = bin2hex(random_bytes(32));
            @file_put_contents('/var/log/wireguard-manager/install.log',
                date('Y-m-d H:i:s') . " [DASHBOARD] action=change_password exit=0\n", FILE_APPEND);
        } else {
            $error = 'Could not update password: ' . htmlspecialchars(implode(' ', $out));
        }
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Change Password — WireGuard Manager</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.css">
<style>
:root {
    --bg:#0d1117; --surface:#161b22; --border:#30363d; --text:#c9d1d9;
    --muted:#8b949e; --accent:#58a6ff; --red:#f85149; --green:#3fb950;
    --yellow:#d29922; --radius:.6rem;
}
*, *::before, *::after { box-sizing: border-box; }
html, body {
    height:100%; margin:0; background:var(--bg); color:var(--text);
    font-family:-apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    font-size:.9rem; display:flex; align-items:center; justify-content:center;
}
.wrap { width:100%; max-width:380px; padding:1rem; }
.card { background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); padding:2rem; }
.brand { text-align:center; margin-bottom:1.5rem; }
.brand .icon { font-size:2rem; color:var(--accent); display:block; margin-bottom:.5rem; }
.brand h1 { font-size:1.1rem; font-weight:700; margin:0 0 .2rem; }
.brand .sub { font-size:.78rem; color:var(--muted); }
.form-label { display:block; color:var(--muted); font-size:.78rem; margin-bottom:.3rem; }
.form-control {
    width:100%; background:#21262d; border:1px solid var(--border); color:var(--text);
    border-radius:var(--radius); padding:.55rem .75rem; font-size:.88rem; outline:none; margin-bottom:1rem;
}
.form-control:focus { border-color:var(--accent); box-shadow:0 0 0 3px rgba(88,166,255,.12); }
.btn-primary-wgm {
    width:100%; background:var(--accent); color:#0d1117; border:none; border-radius:var(--radius);
    padding:.6rem; font-size:.88rem; font-weight:600; cursor:pointer; margin-top:.25rem;
}
.btn-primary-wgm:hover { background:#79b8ff; }
.alert { border-radius:var(--radius); padding:.55rem .75rem; font-size:.82rem; margin-bottom:1rem; display:flex; align-items:center; gap:.5rem; }
.alert-error  { background:rgba(248,81,73,.1);  border:1px solid rgba(248,81,73,.3);  color:var(--red); }
.alert-warn   { background:rgba(210,153,34,.1); border:1px solid rgba(210,153,34,.3); color:var(--yellow); }
.alert-ok     { background:rgba(63,185,80,.1);  border:1px solid rgba(63,185,80,.3);  color:var(--green); }
.foot { text-align:center; margin-top:1rem; font-size:.72rem; }
.foot a { color:var(--muted); text-decoration:none; }
</style>
</head>
<body>
<div class="wrap">
  <div class="card">
    <div class="brand">
      <i class="bi bi-shield-lock-fill icon"></i>
      <h1>Change Dashboard Password</h1>
      <span class="sub">Pick a strong password for the web dashboard</span>
    </div>

    <?php if ($ok): ?>
      <div class="alert alert-ok"><i class="bi bi-check-circle"></i> Password updated.</div>
      <a class="btn-primary-wgm" href="index.php" style="display:block; text-align:center; text-decoration:none;">Continue to dashboard</a>
    <?php else: ?>

      <?php if ($forced): ?>
        <div class="alert alert-warn">
          <i class="bi bi-exclamation-triangle"></i>
          You're still using the default password. Set a new one to continue.
        </div>
      <?php endif; ?>

      <?php if ($error): ?>
        <div class="alert alert-error"><i class="bi bi-exclamation-circle"></i> <?= $error ?></div>
      <?php endif; ?>

      <form method="POST" autocomplete="off">
        <input type="hidden" name="csrf" value="<?= htmlspecialchars($_SESSION['csrf']) ?>">
        <label class="form-label" for="new_password">New password</label>
        <input type="password" id="new_password" name="new_password" class="form-control"
               placeholder="At least 6 characters" autofocus required autocomplete="new-password">
        <label class="form-label" for="confirm_password">Confirm password</label>
        <input type="password" id="confirm_password" name="confirm_password" class="form-control"
               placeholder="Re-enter password" required autocomplete="new-password">
        <button type="submit" class="btn-primary-wgm"><i class="bi bi-check2 me-1"></i>Save password</button>
      </form>

      <?php if (!$forced): ?>
        <div class="foot"><a href="index.php"><i class="bi bi-arrow-left"></i> Back to dashboard</a></div>
      <?php endif; ?>

    <?php endif; ?>
  </div>
</div>
</body>
</html>

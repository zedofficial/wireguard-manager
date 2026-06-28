<?php
// =============================================================================
// layout.php — WireGuard Manager Dashboard Shared Layout
// Included by every page. Provides header, sidebar, and footer wrappers.
// Usage:
//   $page_title = 'Clients';
//   $active_nav = 'clients';
//   require __DIR__ . '/layout.php';
//   // then call layout_start() and layout_end()
// =============================================================================

// ---- Auth guard ----
if (session_status() === PHP_SESSION_NONE) session_start();
if (!isset($_SESSION['authenticated'])) {
    header('Location: login.php');
    exit;
}

// ---- Session timeout (60 min) ----
if (isset($_SESSION['login_time']) && (time() - $_SESSION['login_time']) > 3600) {
    session_destroy();
    header('Location: login.php?timeout=1');
    exit;
}

// ---- Force a password change while still on the default 'admin' ----
// Refuse to serve any real page until the password is changed. The change-password
// page is standalone (doesn't include this file), so there's no redirect loop.
if (($wgm_pw = @file_get_contents('/opt/wireguard/dashboard.passwd')) !== false
    && password_verify('admin', trim($wgm_pw))) {
    header('Location: change-password.php');
    exit;
}

// ---- Load runtime config ----
function wgm_config(): array {
    static $cfg = null;
    if ($cfg !== null) return $cfg;
    $cfg = [];
    foreach (@file('/opt/wireguard/config.env') ?: [] as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#') continue;
        [$k, $v] = array_pad(explode('=', $line, 2), 2, '');
        $cfg[$k] = trim($v, '"');
    }
    return $cfg;
}

// ---- Installed version ----
// Read from /opt/wireguard/version — the authoritative file that wg-update
// rewrites on every update. config.env's WGM_VERSION is only an install-time
// snapshot and is not a reliable source after an update, so it's just a fallback.
function wgm_version(): string {
    $v = @file_get_contents('/opt/wireguard/version');
    if ($v !== false && trim($v) !== '') return trim($v);
    return wgm_config()['WGM_VERSION'] ?? '—';
}

// ---- WireGuard status ----
function wgm_wg_status(): string {
    exec('systemctl is-active wg-quick@wg0 2>/dev/null', $out);
    return trim($out[0] ?? 'unknown');
}

// ---- Load client DB ----
function wgm_clients(): array {
    $clients = [];
    foreach (@file('/opt/wireguard/clients.db') ?: [] as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#') continue;
        $p = explode('|', $line);
        if (count($p) >= 5) {
            $clients[] = [
                'name'    => $p[0],
                'ip'      => $p[1],
                'pubkey'  => $p[2],
                'created' => $p[3],
                'status'  => $p[4],
            ];
        }
    }
    return $clients;
}

// ---- Update status ----
function wgm_update_status(): array {
    $path = '/opt/wireguard/update_status.json';
    if (!file_exists($path)) return [];
    $data = json_decode(file_get_contents($path), true);
    return is_array($data) ? $data : [];
}

$nav_items = [
    'dashboard' => ['icon' => 'bi-speedometer2', 'label' => 'Dashboard',     'href' => 'index.php'],
    'clients'   => ['icon' => 'bi-people',        'label' => 'Clients',       'href' => 'clients.php'],
    'config'    => ['icon' => 'bi-gear',          'label' => 'Configuration', 'href' => 'config.php'],
    'logs'      => ['icon' => 'bi-journal-text',  'label' => 'Logs',          'href' => 'logs.php'],
];

$page_title  = $page_title  ?? 'WireGuard Manager';
$active_nav  = $active_nav  ?? 'dashboard';
$cfg         = wgm_config();
$wg_running  = wgm_wg_status() === 'active';

function layout_head(string $extra_css = ''): void {
    global $page_title;
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= htmlspecialchars($page_title) ?> — WireGuard Manager</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.css">
<style>
/* ── Base ─────────────────────────────────────────────────── */
:root {
    --bg:        #0d1117;
    --surface:   #161b22;
    --surface2:  #21262d;
    --border:    #30363d;
    --text:      #c9d1d9;
    --muted:     #8b949e;
    --accent:    #58a6ff;
    --accent2:   #388bfd;
    --green:     #3fb950;
    --red:       #f85149;
    --yellow:    #d29922;
    --radius:    .6rem;
    --sidebar-w: 220px;
}
*, *::before, *::after { box-sizing: border-box; }
html, body { height: 100%; margin: 0; }
body {
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    font-size: .9rem;
    display: flex;
}

/* ── Sidebar ──────────────────────────────────────────────── */
.wgm-sidebar {
    width: var(--sidebar-w);
    min-height: 100vh;
    background: var(--surface);
    border-right: 1px solid var(--border);
    display: flex;
    flex-direction: column;
    padding: 1.25rem 1rem;
    flex-shrink: 0;
    position: sticky;
    top: 0;
    height: 100vh;
    overflow-y: auto;
}
.wgm-brand {
    color: var(--accent);
    font-weight: 700;
    font-size: 1rem;
    letter-spacing: -.01em;
    display: flex;
    align-items: center;
    gap: .5rem;
    padding: .25rem .5rem .75rem;
    border-bottom: 1px solid var(--border);
    margin-bottom: .75rem;
    text-decoration: none;
}
.wgm-brand:hover { color: var(--accent); }
.wgm-brand .shield { font-size: 1.2rem; }
.wgm-nav { list-style: none; padding: 0; margin: 0; flex: 1; }
.wgm-nav li + li { margin-top: .15rem; }
.wgm-nav a {
    display: flex;
    align-items: center;
    gap: .6rem;
    padding: .45rem .75rem;
    border-radius: var(--radius);
    color: var(--muted);
    text-decoration: none;
    font-size: .85rem;
    transition: background .15s, color .15s;
}
.wgm-nav a:hover       { background: var(--surface2); color: var(--text); }
.wgm-nav a.active      { background: var(--surface2); color: var(--accent); }
.wgm-nav a i           { font-size: 1rem; }
.wgm-sidebar-footer {
    border-top: 1px solid var(--border);
    padding-top: .75rem;
    margin-top: .5rem;
}
.wgm-wg-pill {
    display: inline-flex;
    align-items: center;
    gap: .35rem;
    font-size: .75rem;
    padding: .2rem .6rem;
    border-radius: 99px;
    font-weight: 500;
}
.wgm-wg-pill.running  { background: rgba(63,185,80,.15); color: var(--green); }
.wgm-wg-pill.stopped  { background: rgba(248,81,73,.15);  color: var(--red); }
.wgm-wg-pill .dot {
    width: 6px; height: 6px;
    border-radius: 50%;
    background: currentColor;
}

/* ── Main ─────────────────────────────────────────────────── */
.wgm-main {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
}
.wgm-topbar {
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    padding: .7rem 1.5rem;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    flex-shrink: 0;
}
.wgm-topbar h1 {
    font-size: 1rem;
    font-weight: 600;
    margin: 0;
    color: var(--text);
}
.wgm-content { padding: 1.5rem; flex: 1; }

/* ── Cards ────────────────────────────────────────────────── */
.wgm-card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
}
.wgm-card-header {
    background: var(--surface2);
    border-bottom: 1px solid var(--border);
    padding: .65rem 1rem;
    font-size: .8rem;
    font-weight: 600;
    color: var(--muted);
    letter-spacing: .04em;
    text-transform: uppercase;
    border-radius: var(--radius) var(--radius) 0 0;
    display: flex;
    align-items: center;
    justify-content: space-between;
}
.wgm-card-body { padding: 1rem; }

/* ── Stat tiles ───────────────────────────────────────────── */
.wgm-stat {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 1rem 1.25rem;
}
.wgm-stat .label { color: var(--muted); font-size: .75rem; text-transform: uppercase; letter-spacing: .05em; margin-bottom: .35rem; }
.wgm-stat .value { font-size: 1.5rem; font-weight: 700; color: var(--accent); line-height: 1; }
.wgm-stat .sub   { color: var(--muted); font-size: .75rem; margin-top: .3rem; }

/* ── Tables ───────────────────────────────────────────────── */
.wgm-table { width: 100%; border-collapse: collapse; font-size: .85rem; }
.wgm-table th {
    color: var(--muted);
    font-size: .75rem;
    text-transform: uppercase;
    letter-spacing: .05em;
    font-weight: 500;
    padding: .5rem 1rem;
    border-bottom: 1px solid var(--border);
    text-align: left;
    background: var(--surface2);
}
.wgm-table td {
    padding: .65rem 1rem;
    border-bottom: 1px solid var(--border);
    vertical-align: middle;
}
.wgm-table tr:last-child td { border-bottom: none; }
.wgm-table tr:hover td { background: rgba(255,255,255,.02); }

/* ── Badges ───────────────────────────────────────────────── */
.badge-active   { background: rgba(63,185,80,.15);  color: var(--green); }
.badge-disabled { background: rgba(248,81,73,.15);  color: var(--red); }
.badge-offline  { background: rgba(139,148,158,.12); color: var(--muted); }
.wgm-badge {
    display: inline-flex; align-items: center; gap: .3rem;
    padding: .2rem .55rem; border-radius: 99px;
    font-size: .72rem; font-weight: 600;
}

/* ── Buttons ──────────────────────────────────────────────── */
.btn-wgm-primary   { background: var(--accent2); color: #fff; border: none; }
.btn-wgm-primary:hover { background: var(--accent); color: #fff; }
.btn-icon {
    display: inline-flex; align-items: center; justify-content: center;
    width: 30px; height: 30px; border-radius: var(--radius);
    background: var(--surface2); border: 1px solid var(--border);
    color: var(--muted); font-size: .9rem; transition: all .15s;
    text-decoration: none;
}
.btn-icon:hover { border-color: var(--accent); color: var(--accent); }
.btn-icon.danger:hover { border-color: var(--red); color: var(--red); }
.btn-icon.success:hover { border-color: var(--green); color: var(--green); }

/* ── Forms ────────────────────────────────────────────────── */
.wgm-input, .wgm-select {
    background: var(--surface2);
    border: 1px solid var(--border);
    color: var(--text);
    border-radius: var(--radius);
    padding: .45rem .75rem;
    font-size: .85rem;
    width: 100%;
    outline: none;
    transition: border-color .15s;
}
.wgm-input:focus, .wgm-select:focus {
    border-color: var(--accent);
    box-shadow: 0 0 0 3px rgba(88,166,255,.12);
}
.wgm-select option { background: var(--surface2); }
.form-label { color: var(--muted); font-size: .8rem; margin-bottom: .3rem; display: block; }

/* ── Code / mono ──────────────────────────────────────────── */
code {
    background: var(--surface2);
    color: var(--accent);
    border-radius: .3rem;
    padding: .1rem .4rem;
    font-size: .82rem;
}
.log-output {
    background: #0a0e14;
    border: 1px solid var(--border);
    border-radius: var(--radius);
    font-family: 'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace;
    font-size: .78rem;
    color: #a5b4c3;
    padding: 1rem;
    overflow-y: auto;
    white-space: pre-wrap;
    word-break: break-all;
    line-height: 1.6;
}

/* ── Alerts ───────────────────────────────────────────────── */
.wgm-alert {
    border-radius: var(--radius);
    padding: .65rem 1rem;
    font-size: .85rem;
    margin-bottom: 1rem;
    border-left: 3px solid;
}
.wgm-alert.success { background: rgba(63,185,80,.1);  border-color: var(--green); color: var(--green); }
.wgm-alert.error   { background: rgba(248,81,73,.1);  border-color: var(--red);   color: var(--red); }
.wgm-alert.warn    { background: rgba(210,153,34,.1); border-color: var(--yellow); color: var(--yellow); }

/* ── QR modal ─────────────────────────────────────────────── */
.wgm-modal-overlay {
    display: none; position: fixed; inset: 0;
    background: rgba(0,0,0,.7); z-index: 1000;
    align-items: center; justify-content: center;
}
.wgm-modal-overlay.show { display: flex; }
.wgm-modal {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 1.5rem;
    max-width: 420px; width: 90%;
    position: relative;
}
.wgm-modal h5 { color: var(--accent); margin-bottom: 1rem; }
.wgm-modal img { width: 100%; border-radius: .4rem; background: #fff; padding: .5rem; }
.wgm-modal-close {
    position: absolute; top: .75rem; right: .75rem;
    background: none; border: none; color: var(--muted);
    font-size: 1.2rem; cursor: pointer; line-height: 1;
}
.wgm-modal-close:hover { color: var(--text); }

/* ── Misc ─────────────────────────────────────────────────── */
.text-accent  { color: var(--accent) !important; }
.text-green   { color: var(--green)  !important; }
.text-red     { color: var(--red)    !important; }
.text-muted-wgm { color: var(--muted) !important; }
.divider { border-color: var(--border); margin: 1rem 0; }

<?= $extra_css ?>
</style>
</head>
<body>
<?php } // end layout_head

function layout_sidebar(): void {
    global $nav_items, $active_nav, $wg_running, $cfg;
    $update_available = (wgm_update_status()['status'] ?? '') === 'available';
?>
<aside class="wgm-sidebar">
    <a href="index.php" class="wgm-brand">
        <i class="bi bi-shield-lock-fill shield"></i>
        WG Manager
    </a>
    <ul class="wgm-nav">
        <?php foreach ($nav_items as $key => $item): ?>
        <li>
            <a href="<?= $item['href'] ?>" class="<?= $active_nav === $key ? 'active' : '' ?>">
                <i class="bi <?= $item['icon'] ?>"></i>
                <?= $item['label'] ?>
                <?php if ($key === 'config' && $update_available): ?>
                <span style="margin-left:auto; background:var(--yellow); color:#000;
                             font-size:.6rem; font-weight:700; padding:.1rem .35rem;
                             border-radius:99px; line-height:1.4;">UPDATE</span>
                <?php endif; ?>
            </a>
        </li>
        <?php endforeach; ?>
    </ul>
    <div class="wgm-sidebar-footer">
        <div class="mb-2">
            <span class="wgm-wg-pill <?= $wg_running ? 'running' : 'stopped' ?>">
                <span class="dot"></span>
                <?= $wg_running ? 'WireGuard running' : 'WireGuard stopped' ?>
            </span>
        </div>
        <div style="font-size:.72rem; color:var(--muted);">
            <?= htmlspecialchars($cfg['SERVER_HOSTNAME'] ?? 'server') ?>
        </div>
        <a href="logout.php" style="font-size:.75rem; color:var(--muted); text-decoration:none; display:flex; align-items:center; gap:.3rem; margin-top:.5rem;">
            <i class="bi bi-box-arrow-right"></i> Sign out
        </a>
    </div>
</aside>
<?php } // end layout_sidebar

function layout_topbar(string $title, string $icon = 'bi-circle', string $extra = ''): void {
    $update_status    = wgm_update_status();
    $update_available = ($update_status['status'] ?? '') === 'available';
    ?>
<div class="wgm-topbar">
    <h1><i class="bi <?= $icon ?> me-2 text-accent"></i><?= htmlspecialchars($title) ?></h1>
    <?php if ($extra): ?><div><?= $extra ?></div><?php endif; ?>
</div>
<?php if ($update_available): ?>
<div style="background:rgba(210,153,34,.12); border-bottom:1px solid rgba(210,153,34,.3);
            padding:.55rem 1.5rem; display:flex; align-items:center; gap:.75rem; font-size:.82rem;">
    <i class="bi bi-arrow-up-circle-fill" style="color:var(--yellow);"></i>
    <span>
        Update available:
        <strong style="color:var(--text);"><?= htmlspecialchars($update_status['current_version'] ?? '') ?></strong>
        →
        <strong style="color:var(--yellow);"><?= htmlspecialchars($update_status['latest_version'] ?? '') ?></strong>
    </span>
    <form method="POST" action="action.php" style="margin-left:auto; display:inline;">
        <input type="hidden" name="action" value="update">
        <input type="hidden" name="csrf"   value="<?= $_SESSION['csrf'] ?? '' ?>">
        <button type="submit"
                style="background:var(--yellow); color:#000; border:none; border-radius:var(--radius);
                       padding:.25rem .75rem; font-size:.78rem; font-weight:600; cursor:pointer;">
            Update now
        </button>
    </form>
    <a href="config.php" style="color:var(--muted); font-size:.78rem; text-decoration:none;">
        Settings
    </a>
</div>
<?php endif; ?>
<?php } // end layout_topbar

function layout_foot(): void { ?>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
<?php } // end layout_foot

<?php
// =============================================================================
// index.php — WireGuard Manager — Dashboard
// Shows WireGuard status, stat tiles, controls, and client overview.
// =============================================================================
$page_title = 'Dashboard';
$active_nav = 'dashboard';
require __DIR__ . '/layout.php';

if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(32));

// ---- WireGuard interface stats ----
$wg_status = wgm_wg_status();
$wg_running = $wg_status === 'active';

// Public IP
$public_ip = trim(@file_get_contents('https://api.ipify.org') ?: '');

// Live peer data from wg show
$peers       = [];
$total_rx    = 0;
$total_tx    = 0;
$online_count = 0;

if ($wg_running) {
    // Parse wg show wg0 dump: pubkey, psk, endpoint, allowed-ips, latest-handshake, rx, tx, keepalive
    exec('sudo wg show wg0 dump 2>/dev/null', $dump_lines);
    $now = time();
    foreach (array_slice($dump_lines, 1) as $line) { // skip server line
        $p = explode("\t", trim($line));
        if (count($p) < 7) continue;
        $hs  = (int)($p[4] ?? 0);
        $rx  = (int)($p[5] ?? 0);
        $tx  = (int)($p[6] ?? 0);
        $total_rx += $rx;
        $total_tx += $tx;
        if ($hs && ($now - $hs) < 180) $online_count++;
        $peers[$p[0]] = [
            'endpoint' => $p[2] !== '(none)' ? $p[2] : null,
            'allowed'  => $p[3],
            'hs'       => $hs,
            'rx'       => $rx,
            'tx'       => $tx,
        ];
    }
}

// ---- Clients from DB ----
$clients      = wgm_clients();
$total_clients = count($clients);
$disabled_count = count(array_filter($clients, fn($c) => $c['status'] === 'disabled'));

// ---- DDNS status ----
$ddns_log_last = '';
exec('tail -1 /var/log/wireguard-manager/ddns.log 2>/dev/null', $ddns_lines);
$ddns_log_last = trim($ddns_lines[0] ?? '');

// ---- Format bytes ----
function fmt_bytes(int $b): string {
    if ($b >= 1073741824) return round($b / 1073741824, 2) . ' GB';
    if ($b >= 1048576)    return round($b / 1048576,    2) . ' MB';
    if ($b >= 1024)       return round($b / 1024,       1) . ' KB';
    return $b . ' B';
}

// ---- Format seconds ago ----
function fmt_ago(int $ts): string {
    if (!$ts) return 'never';
    $age = time() - $ts;
    if ($age <  60)   return $age . 's ago';
    if ($age < 3600)  return floor($age / 60)   . 'm ago';
    if ($age < 86400) return floor($age / 3600)  . 'h ago';
    return floor($age / 86400) . 'd ago';
}

// ---- Flash messages from action.php redirects ----
$flash     = '';
$flash_type = 'success';
if (isset($_GET['msg'])) {
    $flash_map = [
        'started'   => 'WireGuard started.',
        'stopped'   => 'WireGuard stopped.',
        'restarted' => 'WireGuard restarted.',
        'reloaded'  => 'Configuration reloaded.',
    ];
    $flash = $flash_map[$_GET['msg']] ?? '';
}
if (isset($_GET['err'])) {
    $flash_type = 'error';
    if ($_GET['err'] === 'action_failed') {
        $flash = 'Command failed. ' . htmlspecialchars(urldecode($_GET['hint'] ?? ''));
    } elseif ($_GET['err'] === 'csrf') {
        $flash = 'Invalid request — please try again.';
    }
}

layout_head();
layout_sidebar();
?>
<div class="wgm-main">
<?php layout_topbar('Dashboard', 'bi-speedometer2',
    '<span style="color:var(--muted);font-size:.8rem;">' . date('D j M Y, H:i') . '</span>'
); ?>
<div class="wgm-content">
<?php if ($flash): ?>
<div class="wgm-alert <?= $flash_type ?>"><?= $flash ?></div>
<?php endif; ?>

    <!-- ── Stat row ─────────────────────────────────────────── -->
    <div class="row g-3 mb-3">
        <div class="col-6 col-lg-3">
            <div class="wgm-stat">
                <div class="label">WireGuard</div>
                <div class="value" style="font-size:1.1rem;">
                    <?php if ($wg_running): ?>
                    <span style="color:var(--green);">● Running</span>
                    <?php else: ?>
                    <span style="color:var(--red);">✖ Stopped</span>
                    <?php endif; ?>
                </div>
                <div class="sub">Port <?= htmlspecialchars($cfg['WG_PORT'] ?? '51820') ?>/UDP</div>
            </div>
        </div>
        <div class="col-6 col-lg-3">
            <div class="wgm-stat">
                <div class="label">Clients online</div>
                <div class="value"><?= $online_count ?><span style="color:var(--muted);font-size:.9rem;font-weight:400;"> / <?= $total_clients ?></span></div>
                <div class="sub"><?= $disabled_count ?> disabled</div>
            </div>
        </div>
        <div class="col-6 col-lg-3">
            <div class="wgm-stat">
                <div class="label">Total transfer</div>
                <div class="value" style="font-size:1.1rem;"><?= fmt_bytes($total_rx + $total_tx) ?></div>
                <div class="sub">↓ <?= fmt_bytes($total_rx) ?> &nbsp; ↑ <?= fmt_bytes($total_tx) ?></div>
            </div>
        </div>
        <div class="col-6 col-lg-3">
            <div class="wgm-stat">
                <div class="label">Public IP</div>
                <div class="value" style="font-size:1rem; word-break:break-all;">
                    <?= $public_ip ? htmlspecialchars($public_ip) : '—' ?>
                </div>
                <div class="sub"><?= htmlspecialchars($cfg['SERVER_ENDPOINT'] ?? '') ?></div>
            </div>
        </div>
    </div>

    <div class="row g-3">

        <!-- ── Left: controls + recent peers ──────────────────── -->
        <div class="col-lg-7">

            <!-- WireGuard Controls -->
            <div class="wgm-card mb-3">
                <div class="wgm-card-header">Controls</div>
                <div class="wgm-card-body" style="display:flex; gap:.5rem; flex-wrap:wrap;">
                    <?php
                    $controls = [
                        ['start',   'bi-play-fill',      'btn-success', 'Start'],
                        ['stop',    'bi-stop-fill',       'btn-danger',  'Stop'],
                        ['restart', 'bi-arrow-repeat',    'btn-warning', 'Restart'],
                        ['reload',  'bi-arrow-clockwise', 'btn-secondary','Reload config'],
                    ];
                    foreach ($controls as [$act, $icon, $cls, $label]):
                    ?>
                    <form method="POST" action="action.php" style="display:inline;">
                        <input type="hidden" name="action" value="<?= $act ?>">
                        <input type="hidden" name="csrf"   value="<?= $_SESSION['csrf'] ?>">
                        <button type="submit" class="btn btn-sm <?= $cls ?>">
                            <i class="bi <?= $icon ?> me-1"></i><?= $label ?>
                        </button>
                    </form>
                    <?php endforeach; ?>
                </div>
            </div>

            <!-- Client overview table -->
            <div class="wgm-card">
                <div class="wgm-card-header">
                    <span>Clients</span>
                    <a href="clients.php?action=add" style="font-size:.78rem; color:var(--accent); text-decoration:none;">
                        <i class="bi bi-plus-lg me-1"></i>Add client
                    </a>
                </div>
                <?php if (empty($clients)): ?>
                <div class="wgm-card-body" style="text-align:center; color:var(--muted); padding:2rem 1rem;">
                    No clients yet.
                    <a href="clients.php" style="color:var(--accent);">Add your first client.</a>
                </div>
                <?php else: ?>
                <table class="wgm-table">
                    <thead>
                        <tr>
                            <th>Name</th>
                            <th>VPN IP</th>
                            <th>Status</th>
                            <th>Handshake</th>
                            <th></th>
                        </tr>
                    </thead>
                    <tbody>
                    <?php foreach ($clients as $c):
                        $pub  = $c['pubkey'];
                        $peer = $peers[$pub] ?? null;
                        $hs   = $peer ? $peer['hs'] : 0;
                        $age  = $hs ? (time() - $hs) : null;

                        if ($c['status'] === 'disabled') {
                            $badge = '<span class="wgm-badge badge-disabled">disabled</span>';
                        } elseif ($hs && $age < 180) {
                            $badge = '<span class="wgm-badge badge-active">● online</span>';
                        } else {
                            $badge = '<span class="wgm-badge badge-offline">offline</span>';
                        }
                    ?>
                    <tr>
                        <td><strong><?= htmlspecialchars($c['name']) ?></strong></td>
                        <td><code><?= htmlspecialchars($c['ip']) ?></code></td>
                        <td><?= $badge ?></td>
                        <td style="color:var(--muted); font-size:.78rem;"><?= $hs ? fmt_ago($hs) : 'never' ?></td>
                        <td style="text-align:right;">
                            <a href="clients.php?action=show&name=<?= urlencode($c['name']) ?>"
                               class="btn-icon" style="width:24px;height:24px;font-size:.78rem;" title="Show QR">
                                <i class="bi bi-qr-code"></i>
                            </a>
                        </td>
                    </tr>
                    <?php endforeach; ?>
                    </tbody>
                </table>
                <div style="padding:.5rem 1rem; border-top:1px solid var(--border);">
                    <a href="clients.php" style="font-size:.78rem; color:var(--accent); text-decoration:none;">
                        Manage all clients →
                    </a>
                </div>
                <?php endif; ?>
            </div>

        </div>

        <!-- ── Right: server info + ddns ──────────────────────── -->
        <div class="col-lg-5">

            <!-- Server info -->
            <div class="wgm-card mb-3">
                <div class="wgm-card-header">Server</div>
                <div class="wgm-card-body" style="font-size:.82rem;">
                    <?php
                    $info_rows = [
                        ['Hostname',  $cfg['SERVER_HOSTNAME'] ?? '—'],
                        ['Endpoint',  ($cfg['SERVER_ENDPOINT'] ?? '—') . ':' . ($cfg['WG_PORT'] ?? '51820')],
                        ['VPN Subnet',$cfg['VPN_SUBNET'] ?? '—'],
                        ['Interface', $cfg['NET_IFACE'] ?? '—'],
                        ['DNS',       $cfg['CLIENT_DNS'] ?? '—'],
                        ['IPv6',      ($cfg['ENABLE_IPV6'] ?? 'false') === 'true' ? 'Enabled' : 'Disabled'],
                    ];
                    foreach ($info_rows as [$label, $val]): ?>
                    <div style="display:flex; justify-content:space-between; padding:.35rem 0; border-bottom:1px solid var(--border);">
                        <span style="color:var(--muted);"><?= $label ?></span>
                        <span style="text-align:right; word-break:break-all; max-width:55%;">
                            <?= htmlspecialchars($val) ?>
                        </span>
                    </div>
                    <?php endforeach; ?>
                </div>
            </div>

            <!-- DDNS status -->
            <div class="wgm-card mb-3">
                <div class="wgm-card-header">
                    <span>Dynamic DNS</span>
                    <a href="config.php" style="font-size:.72rem; color:var(--accent); text-decoration:none;">Configure</a>
                </div>
                <div class="wgm-card-body" style="font-size:.82rem;">
                    <?php if ($ddns_log_last): ?>
                    <div style="color:var(--muted); font-size:.75rem; margin-bottom:.4rem;">Last update</div>
                    <code style="font-size:.74rem; word-break:break-all; color:var(--text);">
                        <?= htmlspecialchars($ddns_log_last) ?>
                    </code>
                    <?php else: ?>
                    <span style="color:var(--muted);">No DDNS updates logged yet.</span>
                    <?php endif; ?>
                </div>
            </div>

            <!-- Quick links -->
            <div class="wgm-card">
                <div class="wgm-card-header">Quick Links</div>
                <div class="wgm-card-body" style="display:flex; flex-direction:column; gap:.4rem;">
                    <?php
                    $links = [
                        ['clients.php',          'bi-people',       'Manage Clients'],
                        ['clients.php?action=add','bi-person-plus',  'Add Client'],
                        ['config.php',           'bi-gear',         'Configuration'],
                        ['logs.php',             'bi-journal-text', 'View Logs'],
                        ['logs.php?tab=wireguard','bi-shield-check', 'WireGuard Logs'],
                    ];
                    foreach ($links as [$href, $icon, $label]): ?>
                    <a href="<?= $href ?>"
                       style="display:flex; align-items:center; gap:.6rem; color:var(--muted);
                              text-decoration:none; font-size:.82rem; padding:.3rem .25rem;
                              border-radius:var(--radius); transition:color .15s;"
                       onmouseover="this.style.color='var(--accent)'"
                       onmouseout="this.style.color='var(--muted)'">
                        <i class="bi <?= $icon ?>"></i><?= $label ?>
                    </a>
                    <?php endforeach; ?>
                </div>
            </div>

        </div>
    </div><!-- /.row -->

</div><!-- /.wgm-content -->
</div><!-- /.wgm-main -->

<?php layout_foot(); ?>

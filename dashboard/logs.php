<?php
// =============================================================================
// logs.php — WireGuard Manager — Log Viewer
// Tabs: WireGuard · System · DDNS · Install · Update
// =============================================================================
$page_title = 'Logs';
$active_nav = 'logs';
require __DIR__ . '/layout.php';

// ---- Log sources ----
$log_sources = [
    'wireguard' => [
        'label' => 'WireGuard',
        'icon'  => 'bi-shield-check',
        'cmd'   => 'journalctl -u wg-quick@wg0 --no-pager -n 200 --output=short-iso 2>/dev/null',
        'type'  => 'cmd',
    ],
    'system' => [
        'label' => 'System',
        'icon'  => 'bi-cpu',
        'cmd'   => 'journalctl -n 150 --no-pager --output=short-iso 2>/dev/null',
        'type'  => 'cmd',
    ],
    'ddns' => [
        'label' => 'DDNS',
        'icon'  => 'bi-globe',
        'path'  => '/var/log/wireguard-manager/ddns.log',
        'type'  => 'file',
    ],
    'install' => [
        'label' => 'Install',
        'icon'  => 'bi-download',
        'path'  => '/var/log/wireguard-manager/install.log',
        'type'  => 'file',
    ],
    'update' => [
        'label' => 'Updates',
        'icon'  => 'bi-arrow-up-circle',
        'path'  => '/var/log/wireguard-manager/update.log',
        'type'  => 'file',
    ],
    'backup' => [
        'label' => 'Backup',
        'icon'  => 'bi-archive',
        'path'  => '/var/log/wireguard-manager/backup.log',
        'type'  => 'file',
    ],
];

// ---- Active tab ----
$active_tab = preg_replace('/[^a-z]/', '', $_GET['tab'] ?? 'wireguard');
if (!array_key_exists($active_tab, $log_sources)) $active_tab = 'wireguard';

// ---- Load log content ----
function read_log(array $src): string {
    if ($src['type'] === 'cmd') {
        exec($src['cmd'], $lines);
        return implode("\n", $lines) ?: '(no output)';
    }
    $path = $src['path'];
    if (!file_exists($path)) return "(log file not found: {$path})";
    // Read last 300 lines
    exec('tail -300 ' . escapeshellarg($path) . ' 2>/dev/null', $lines);
    return implode("\n", $lines) ?: '(empty)';
}

// ---- Colorize log lines ----
function colorize(string $text): string {
    $lines = explode("\n", htmlspecialchars($text));
    $out   = [];
    foreach ($lines as $line) {
        // Prefer an explicit structured log level (Docker/journald write level=info,
        // level=error, etc.) over keyword matching — otherwise an info line that merely
        // contains an error="..." field gets painted red and looks like a failure.
        if (preg_match('/\blevel=(error|fatal|panic|crit\w*|emerg\w*|alert)\b/i', $line)) {
            $color = '#f85149';
        } elseif (preg_match('/\blevel=warn(ing)?\b/i', $line)) {
            $color = '#d29922';
        } elseif (preg_match('/\blevel=(info|debug|trace|notice)\b/i', $line)) {
            $color = '';   // structured info/debug — never alarm, regardless of words inside
        } elseif (preg_match('/\b(error|fail|critical|fatal)\b/i', $line)) {
            $color = '#f85149';
        } elseif (preg_match('/\bwarn/i', $line)) {
            $color = '#d29922';
        } elseif (preg_match('/\b(success|started|running|active|ok|done)\b/i', $line)) {
            $color = '#3fb950';
        } elseif (preg_match('/^\d{4}-\d{2}-\d{2}|^[A-Z][a-z]{2}\s+\d/', $line)) {
            $color = '#8b949e';
        } else {
            $color = '';
        }
        $out[] = $color ? '<span style="color:' . $color . ';">' . $line . '</span>' : $line;
    }
    return implode("\n", $out);
}

$log_content = read_log($log_sources[$active_tab]);
$line_count  = substr_count($log_content, "\n") + 1;

layout_head(<<<'CSS'
.log-output {
    height: calc(100vh - 260px);
    min-height: 300px;
}
.tab-btn {
    display: inline-flex; align-items: center; gap: .4rem;
    padding: .45rem .9rem;
    background: none;
    border: 1px solid transparent;
    border-radius: var(--radius);
    color: var(--muted);
    font-size: .82rem;
    cursor: pointer;
    text-decoration: none;
    transition: all .15s;
}
.tab-btn:hover  { background: var(--surface2); color: var(--text); border-color: var(--border); }
.tab-btn.active { background: var(--surface2); color: var(--accent); border-color: var(--border); }
CSS);
layout_sidebar();
?>
<div class="wgm-main">
<?php layout_topbar('Logs', 'bi-journal-text', '
    <span style="color:var(--muted); font-size:.8rem;">' . $line_count . ' lines</span>
'); ?>
<div class="wgm-content" style="padding-bottom:.5rem;">

    <!-- ── Tab bar ──────────────────────────────────────────── -->
    <div style="display:flex; gap:.35rem; flex-wrap:wrap; margin-bottom:1rem;">
        <?php foreach ($log_sources as $key => $src): ?>
        <a href="?tab=<?= $key ?>"
           class="tab-btn <?= $active_tab === $key ? 'active' : '' ?>">
            <i class="bi <?= $src['icon'] ?>"></i>
            <?= $src['label'] ?>
        </a>
        <?php endforeach; ?>

        <div style="margin-left:auto; display:flex; gap:.35rem; align-items:center;">
            <!-- Refresh -->
            <a href="?tab=<?= $active_tab ?>" class="tab-btn" title="Refresh">
                <i class="bi bi-arrow-clockwise"></i>
            </a>
            <!-- Download raw log -->
            <?php if ($log_sources[$active_tab]['type'] === 'file'
                   && file_exists($log_sources[$active_tab]['path'])): ?>
            <a href="?tab=<?= $active_tab ?>&download=1" class="tab-btn" title="Download log">
                <i class="bi bi-download"></i>
            </a>
            <?php endif; ?>
        </div>
    </div>

    <!-- ── Log display ──────────────────────────────────────── -->
    <div class="wgm-card">
        <div class="wgm-card-header">
            <span>
                <i class="bi <?= $log_sources[$active_tab]['icon'] ?> me-1"></i>
                <?= $log_sources[$active_tab]['label'] ?> Log
            </span>
            <?php if ($log_sources[$active_tab]['type'] === 'file'): ?>
            <span style="font-size:.72rem; color:var(--muted);">
                <?= htmlspecialchars($log_sources[$active_tab]['path']) ?>
            </span>
            <?php else: ?>
            <span style="font-size:.72rem; color:var(--muted);">
                <?= htmlspecialchars($log_sources[$active_tab]['cmd']) ?>
            </span>
            <?php endif; ?>
        </div>
        <div class="log-output" id="log-output"><?= colorize($log_content) ?></div>
    </div>

</div>
</div>

<?php
// ---- Handle download ----
if (isset($_GET['download'])
    && $log_sources[$active_tab]['type'] === 'file'
    && file_exists($log_sources[$active_tab]['path'])) {
    // Output already sent above — redirect instead to a clean download endpoint
}
?>

<script>
// Auto-scroll log to bottom on load
const logEl = document.getElementById('log-output');
if (logEl) logEl.scrollTop = logEl.scrollHeight;

// Auto-refresh every 30s for live log tabs
const liveTab = '<?= $active_tab ?>';
if (['wireguard', 'system'].includes(liveTab)) {
    setTimeout(() => window.location.reload(), 30000);
}
</script>

<?php layout_foot(); ?>

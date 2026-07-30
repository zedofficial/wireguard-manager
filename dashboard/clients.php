<?php
// =============================================================================
// clients.php — WireGuard Manager — Client Management
// Actions: list, add, delete, disable, enable, rename, show (QR), download
// =============================================================================
$page_title = 'Clients';
$active_nav = 'clients';
require __DIR__ . '/layout.php';

$msg   = '';
$msg_type = 'success';

// ---- CSRF token ----
if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(32));

function csrf_ok(): bool {
    return hash_equals($_SESSION['csrf'] ?? '', $_POST['csrf'] ?? '');
}

// Audit trail — record every client action to the dashboard audit log.
function audit(string $action, int $code = 0, string $detail = ''): void {
    wgm_audit("action={$action} exit={$code}" . ($detail !== '' ? " {$detail}" : ''));
}

// ---- Sanitize name param ----
$name = preg_replace('/[^a-zA-Z0-9_-]/', '', $_GET['name'] ?? $_POST['name'] ?? '');
$action = preg_replace('/[^a-z]/', '', $_GET['action'] ?? $_POST['action'] ?? 'list');

// ---- Handle: download config ----
if ($action === 'download' && $name) {
    $output = [];
    $code   = 0;
    exec('sudo wg-get-config ' . escapeshellarg($name) . ' 2>/dev/null', $output, $code);
    audit('client_download', $code, "name={$name}");
    if ($code === 0 && !empty($output)) {
        $content = implode("\n", $output);
        header('Content-Type: text/plain; charset=utf-8');
        header("Content-Disposition: attachment; filename=\"{$name}.conf\"");
        header('Cache-Control: no-cache');
        header('Content-Length: ' . strlen($content));
        echo $content;
        exit;
    }
    $msg = "Config file not found for '{$name}'.";
    $msg_type = 'error';
}

// ---- Handle: add client (POST) ----
if ($action === 'add' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!csrf_ok()) { $msg = 'Invalid request.'; $msg_type = 'error'; }
    else {
        $newname = preg_replace('/[^a-zA-Z0-9_-]/', '', $_POST['client_name'] ?? '');
        if (!$newname) {
            $msg = 'Invalid client name.'; $msg_type = 'error';
        } else {
            exec('sudo wg-add-client ' . escapeshellarg($newname) . ' 2>&1', $out, $code);
            audit('client_add', $code, "name={$newname}");
            if ($code === 0) {
                header('Location: clients.php?msg=added&name=' . urlencode($newname));
                exit;
            } else {
                $msg = 'Failed to add client: ' . htmlspecialchars(implode(' ', $out));
                $msg_type = 'error';
            }
        }
    }
}

// ---- Handle: delete (POST only for safety) ----
if ($action === 'delete' && $_SERVER['REQUEST_METHOD'] === 'POST' && $name) {
    if (!csrf_ok()) { $msg = 'Invalid request.'; $msg_type = 'error'; }
    else {
        exec('echo ' . escapeshellarg($name) . ' | sudo wg-delete-client ' . escapeshellarg($name) . ' 2>&1', $out, $code);
        audit('client_delete', $code, "name={$name}");
        header('Location: clients.php?msg=deleted&name=' . urlencode($name));
        exit;
    }
}

// ---- Handle: disable ----
if ($action === 'disable' && $_SERVER['REQUEST_METHOD'] === 'POST' && $name) {
    if (!csrf_ok()) { $msg = 'Invalid request.'; $msg_type = 'error'; }
    else {
        exec('sudo wg-disable-client ' . escapeshellarg($name) . ' 2>&1', $out, $code);
        audit('client_disable', $code, "name={$name}");
        header('Location: clients.php?msg=disabled&name=' . urlencode($name));
        exit;
    }
}

// ---- Handle: enable ----
if ($action === 'enable' && $_SERVER['REQUEST_METHOD'] === 'POST' && $name) {
    if (!csrf_ok()) { $msg = 'Invalid request.'; $msg_type = 'error'; }
    else {
        exec('sudo wg-enable-client ' . escapeshellarg($name) . ' 2>&1', $out, $code);
        audit('client_enable', $code, "name={$name}");
        header('Location: clients.php?msg=enabled&name=' . urlencode($name));
        exit;
    }
}

// ---- Handle: rename (POST) ----
if ($action === 'rename' && $_SERVER['REQUEST_METHOD'] === 'POST' && $name) {
    if (!csrf_ok()) { $msg = 'Invalid request.'; $msg_type = 'error'; }
    else {
        $newname = preg_replace('/[^a-zA-Z0-9_-]/', '', $_POST['new_name'] ?? '');
        if (!$newname) {
            $msg = 'Invalid new name.'; $msg_type = 'error';
        } else {
            exec('sudo wg-rename-client ' . escapeshellarg($name) . ' ' . escapeshellarg($newname) . ' 2>&1', $out, $code);
            audit('client_rename', $code, "from={$name} to={$newname}");
            header('Location: clients.php?msg=renamed&from=' . urlencode($name) . '&name=' . urlencode($newname));
            exit;
        }
    }
}

// ---- Flash messages from redirects ----
if (!$msg && isset($_GET['msg'])) {
    $n = htmlspecialchars($_GET['name'] ?? '');
    switch ($_GET['msg']) {
        case 'added':    $msg = "Client '{$n}' created successfully."; break;
        case 'deleted':  $msg = "Client '{$n}' deleted."; break;
        case 'disabled': $msg = "Client '{$n}' disabled — they cannot connect until re-enabled."; break;
        case 'enabled':  $msg = "Client '{$n}' is now active."; break;
        case 'renamed':
            $from = htmlspecialchars($_GET['from'] ?? '');
            $msg = "Client '{$from}' renamed to '{$n}'."; break;
    }
}

// ---- Load clients ----
$clients = wgm_clients();

// ---- Load live handshake data ----
$handshakes = [];
exec('sudo wg show wg0 latest-handshakes 2>/dev/null', $hs_lines);
foreach ($hs_lines as $hl) {
    $parts = preg_split('/\s+/', trim($hl));
    if (count($parts) === 2) $handshakes[$parts[0]] = (int)$parts[1];
}

// ---- QR code for show action — call wg-show-qr via sudo ----
$qr_data = '';
$qr_name = '';
if ($action === 'show' && $name) {
    $conf_path = "/etc/wireguard/clients/{$name}/{$name}.conf";
    if (file_exists($conf_path) || true) { // sudo script checks internally
        $qr_name = $name;
        $output = [];
        $code   = 0;
        exec('sudo wg-show-qr ' . escapeshellarg($name) . ' 2>/dev/null', $output, $code);
        if ($code === 0 && !empty($output)) {
            $qr_data = implode('', $output);
        }
    }
}

// ---- Output ----
layout_head();
layout_sidebar();
?>
<div class="wgm-main">
<?php layout_topbar('Clients', 'bi-people', '
    <button class="btn btn-sm btn-wgm-primary" onclick="document.getElementById(\'modal-add\').classList.add(\'show\')">
        <i class="bi bi-plus-lg me-1"></i>Add Client
    </button>
'); ?>
<div class="wgm-content">

<?php if ($msg): ?>
<div class="wgm-alert <?= $msg_type ?>"><?= $msg ?></div>
<?php endif; ?>

<?php if (empty($clients)): ?>
<!-- Empty state -->
<div class="wgm-card" style="text-align:center; padding:3rem 1rem;">
    <i class="bi bi-people" style="font-size:2.5rem; color:var(--muted);"></i>
    <p style="color:var(--muted); margin-top:1rem;">No clients yet.</p>
    <button class="btn btn-sm btn-wgm-primary" onclick="document.getElementById('modal-add').classList.add('show')">
        Add your first client
    </button>
</div>

<?php else: ?>
<!-- Client table -->
<div class="wgm-card">
    <div class="wgm-card-header">
        <span><?= count($clients) ?> client<?= count($clients) !== 1 ? 's' : '' ?></span>
    </div>
    <table class="wgm-table">
        <thead>
            <tr>
                <th>Name</th>
                <th>VPN IP</th>
                <th>Status</th>
                <th>Last Handshake</th>
                <th>Created</th>
                <th style="text-align:right;">Actions</th>
            </tr>
        </thead>
        <tbody>
        <?php foreach ($clients as $c):
            $pub     = $c['pubkey'];
            $hs      = $handshakes[$pub] ?? 0;
            $now     = time();
            $age     = $hs ? ($now - $hs) : null;
            $online  = $hs && $age < 180;
            $disabled = $c['status'] === 'disabled';

            if ($disabled) {
                $badge = '<span class="wgm-badge badge-disabled"><i class="bi bi-x-circle"></i> disabled</span>';
                $hs_label = '—';
            } elseif ($online) {
                $badge = '<span class="wgm-badge badge-active"><i class="bi bi-circle-fill" style="font-size:.5rem"></i> online</span>';
                $hs_label = date('Y-m-d H:i', $hs);
            } else {
                $badge = '<span class="wgm-badge badge-offline"><i class="bi bi-circle" style="font-size:.5rem"></i> offline</span>';
                $hs_label = $hs ? date('Y-m-d H:i', $hs) : 'never';
            }
        ?>
        <tr>
            <td>
                <strong><?= htmlspecialchars($c['name']) ?></strong>
            </td>
            <td><code><?= htmlspecialchars($c['ip']) ?></code></td>
            <td><?= $badge ?></td>
            <td style="color:var(--muted); font-size:.8rem;"><?= $hs_label ?></td>
            <td style="color:var(--muted); font-size:.8rem;"><?= htmlspecialchars($c['created']) ?></td>
            <td style="text-align:right;">
                <div style="display:flex; gap:.35rem; justify-content:flex-end;">
                    <!-- QR / Show -->
                    <a href="clients.php?action=show&name=<?= urlencode($c['name']) ?>"
                       class="btn-icon" title="Show QR code">
                        <i class="bi bi-qr-code"></i>
                    </a>
                    <!-- Download conf -->
                    <a href="clients.php?action=download&name=<?= urlencode($c['name']) ?>"
                       class="btn-icon" title="Download .conf">
                        <i class="bi bi-download"></i>
                    </a>
                    <!-- Rename -->
                    <button class="btn-icon" title="Rename"
                        onclick="openRename('<?= htmlspecialchars($c['name'], ENT_QUOTES) ?>')">
                        <i class="bi bi-pencil"></i>
                    </button>
                    <!-- Disable / Enable toggle -->
                    <?php if ($disabled): ?>
                    <form method="POST" action="clients.php" style="display:inline;">
                        <input type="hidden" name="action" value="enable">
                        <input type="hidden" name="name"   value="<?= htmlspecialchars($c['name']) ?>">
                        <input type="hidden" name="csrf"   value="<?= $_SESSION['csrf'] ?>">
                        <button type="submit" class="btn-icon success" title="Re-enable client">
                            <i class="bi bi-play-circle"></i>
                        </button>
                    </form>
                    <?php else: ?>
                    <form method="POST" action="clients.php" style="display:inline;">
                        <input type="hidden" name="action" value="disable">
                        <input type="hidden" name="name"   value="<?= htmlspecialchars($c['name']) ?>">
                        <input type="hidden" name="csrf"   value="<?= $_SESSION['csrf'] ?>">
                        <button type="submit" class="btn-icon" title="Disable client">
                            <i class="bi bi-pause-circle"></i>
                        </button>
                    </form>
                    <?php endif; ?>
                    <!-- Delete -->
                    <button class="btn-icon danger" title="Delete client"
                        onclick="openDelete('<?= htmlspecialchars($c['name'], ENT_QUOTES) ?>')">
                        <i class="bi bi-trash"></i>
                    </button>
                </div>
            </td>
        </tr>
        <?php endforeach; ?>
        </tbody>
    </table>
</div>
<?php endif; ?>

</div><!-- /.wgm-content -->
</div><!-- /.wgm-main -->

<!-- ═══ Modal: Add Client ═══════════════════════════════════════════════ -->
<div class="wgm-modal-overlay" id="modal-add">
    <div class="wgm-modal">
        <button class="wgm-modal-close" onclick="this.closest('.wgm-modal-overlay').classList.remove('show')">
            <i class="bi bi-x-lg"></i>
        </button>
        <h5><i class="bi bi-person-plus me-2"></i>Add Client</h5>
        <form method="POST" action="clients.php">
            <input type="hidden" name="action" value="add">
            <input type="hidden" name="csrf"   value="<?= $_SESSION['csrf'] ?>">
            <div class="mb-3">
                <label class="form-label">Client name</label>
                <input type="text" name="client_name" class="wgm-input"
                       placeholder="e.g. phone-zed" required
                       pattern="[a-zA-Z0-9_-]+" autofocus>
                <div style="color:var(--muted); font-size:.75rem; margin-top:.3rem;">
                    Letters, numbers, hyphens, underscores only. No spaces.
                </div>
            </div>
            <div style="display:flex; gap:.5rem;">
                <button type="submit" class="btn btn-sm btn-wgm-primary">Create Client</button>
                <button type="button" class="btn btn-sm btn-secondary"
                        onclick="this.closest('.wgm-modal-overlay').classList.remove('show')">Cancel</button>
            </div>
        </form>
    </div>
</div>

<!-- ═══ Modal: Delete Confirm ═══════════════════════════════════════════ -->
<div class="wgm-modal-overlay" id="modal-delete">
    <div class="wgm-modal">
        <button class="wgm-modal-close" onclick="this.closest('.wgm-modal-overlay').classList.remove('show')">
            <i class="bi bi-x-lg"></i>
        </button>
        <h5 style="color:var(--red);"><i class="bi bi-trash me-2"></i>Delete Client</h5>
        <p style="color:var(--muted); font-size:.85rem;">
            This permanently removes <strong id="delete-name-label" style="color:var(--text);"></strong>
            and their keys. They will lose VPN access immediately.
        </p>
        <p style="color:var(--muted); font-size:.8rem;">
            Use <em>Disable</em> instead if you only want to temporarily block access.
        </p>
        <form method="POST" action="clients.php">
            <input type="hidden" name="action" value="delete">
            <input type="hidden" name="name"   id="delete-name-input">
            <input type="hidden" name="csrf"   value="<?= $_SESSION['csrf'] ?>">
            <div style="display:flex; gap:.5rem; margin-top:1rem;">
                <button type="submit" class="btn btn-sm btn-danger">Delete permanently</button>
                <button type="button" class="btn btn-sm btn-secondary"
                        onclick="this.closest('.wgm-modal-overlay').classList.remove('show')">Cancel</button>
            </div>
        </form>
    </div>
</div>

<!-- ═══ Modal: Rename ═══════════════════════════════════════════════════ -->
<div class="wgm-modal-overlay" id="modal-rename">
    <div class="wgm-modal">
        <button class="wgm-modal-close" onclick="this.closest('.wgm-modal-overlay').classList.remove('show')">
            <i class="bi bi-x-lg"></i>
        </button>
        <h5><i class="bi bi-pencil me-2"></i>Rename Client</h5>
        <form method="POST" action="clients.php">
            <input type="hidden" name="action" value="rename">
            <input type="hidden" name="name"   id="rename-old-input">
            <input type="hidden" name="csrf"   value="<?= $_SESSION['csrf'] ?>">
            <div class="mb-3">
                <label class="form-label">Current name</label>
                <input type="text" id="rename-old-label" class="wgm-input" disabled>
            </div>
            <div class="mb-3">
                <label class="form-label">New name</label>
                <input type="text" name="new_name" class="wgm-input"
                       placeholder="new-name" required pattern="[a-zA-Z0-9_-]+" autofocus>
                <div style="color:var(--muted); font-size:.75rem; margin-top:.3rem;">
                    IP address and keys are unchanged. The client does not need to reconnect.
                </div>
            </div>
            <div style="display:flex; gap:.5rem;">
                <button type="submit" class="btn btn-sm btn-wgm-primary">Rename</button>
                <button type="button" class="btn btn-sm btn-secondary"
                        onclick="this.closest('.wgm-modal-overlay').classList.remove('show')">Cancel</button>
            </div>
        </form>
    </div>
</div>

<!-- ═══ Modal: QR Code ══════════════════════════════════════════════════ -->
<?php if ($qr_data): ?>
<div class="wgm-modal-overlay show" id="modal-qr">
    <div class="wgm-modal" style="max-width:360px;">
        <button class="wgm-modal-close" onclick="window.location='clients.php'">
            <i class="bi bi-x-lg"></i>
        </button>
        <h5><i class="bi bi-qr-code me-2"></i><?= htmlspecialchars($qr_name) ?></h5>
        <p style="color:var(--muted); font-size:.8rem; margin-bottom:.75rem;">
            Scan with the WireGuard app on iOS or Android.
        </p>
        <img src="data:image/png;base64,<?= $qr_data ?>" alt="QR Code for <?= htmlspecialchars($qr_name) ?>">
        <div style="display:flex; gap:.5rem; margin-top:1rem;">
            <a href="clients.php?action=download&name=<?= urlencode($qr_name) ?>"
               class="btn btn-sm btn-wgm-primary">
                <i class="bi bi-download me-1"></i>Download .conf
            </a>
            <a href="clients.php" class="btn btn-sm btn-secondary">Close</a>
        </div>
    </div>
</div>
<?php endif; ?>

<script>
function openDelete(name) {
    document.getElementById('delete-name-label').textContent = name;
    document.getElementById('delete-name-input').value = name;
    document.getElementById('modal-delete').classList.add('show');
}
function openRename(name) {
    document.getElementById('rename-old-label').value = name;
    document.getElementById('rename-old-input').value = name;
    document.getElementById('modal-rename').classList.add('show');
}
// Close modals on backdrop click
document.querySelectorAll('.wgm-modal-overlay').forEach(overlay => {
    overlay.addEventListener('click', e => {
        if (e.target === overlay) overlay.classList.remove('show');
    });
});
</script>

<?php layout_foot(); ?>

<?php
// =============================================================================
// config.php — WireGuard Manager — Configuration
// Shows current server config. Allows editing DNS, DDNS, and port.
// =============================================================================
$page_title = 'Configuration';
$active_nav = 'config';
require __DIR__ . '/layout.php';

$msg      = '';
$msg_type = 'success';

if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(32));

function csrf_ok(): bool {
    return hash_equals($_SESSION['csrf'] ?? '', $_POST['csrf'] ?? '');
}

// ---- Handle: update DNS ----
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['section'])) {
    if (!csrf_ok()) {
        $msg = 'Invalid request.'; $msg_type = 'error';
    } else {
        $section = $_POST['section'];

        if ($section === 'dns') {
            // Validate: must be comma-separated IPs
            $raw = trim($_POST['dns'] ?? '');
            $parts = array_map('trim', explode(',', $raw));
            $valid = true;
            foreach ($parts as $p) {
                if (!filter_var($p, FILTER_VALIDATE_IP)) { $valid = false; break; }
            }
            if (!$valid || !$raw) {
                $msg = 'Invalid DNS — enter one or more valid IP addresses, comma-separated.';
                $msg_type = 'error';
            } else {
                // Update config.env
                $env_path = '/opt/wireguard/config.env';
                $content  = file_get_contents($env_path);
                $content  = preg_replace('/^CLIENT_DNS=.*/m', 'CLIENT_DNS="' . $raw . '"', $content);
                file_put_contents($env_path, $content);

                // Update wg0.conf DNS for existing peers isn't needed —
                // DNS only applies to new client configs. Log note.
                $msg = 'DNS updated to: ' . htmlspecialchars($raw) . '. New clients will use this DNS. Existing clients must regenerate their configs.';
            }
        }

        if ($section === 'ddns') {
            $provider = $_POST['ddns_provider'] ?? '';
            $script   = '/opt/wireguard/ddns/update.sh';

            // Rebuild the DDNS update script based on new provider/creds
            switch ($provider) {
                case 'duckdns':
                    $sub   = escapeshellarg(trim($_POST['duckdns_sub']   ?? ''));
                    $token = escapeshellarg(trim($_POST['duckdns_token'] ?? ''));
                    if (!$sub || !$token) { $msg = 'DuckDNS requires subdomain and token.'; $msg_type = 'error'; break; }
                    $sh = "#!/usr/bin/env bash\nSUBDOMAIN={$sub}\nTOKEN={$token}\n"
                        . "IP=\$(curl -sf --max-time 10 https://api.ipify.org)\n"
                        . "curl -sf \"https://www.duckdns.org/update?domains=\${SUBDOMAIN}&token=\${TOKEN}&ip=\${IP}\" >> /var/log/wireguard-manager/ddns.log\n"
                        . "echo \" \$(date) IP=\${IP}\" >> /var/log/wireguard-manager/ddns.log\n";
                    file_put_contents($script, $sh); chmod($script, 0700);
                    $msg = 'DuckDNS DDNS updated.'; break;

                case 'noip':
                    $host = escapeshellarg(trim($_POST['noip_host'] ?? ''));
                    $user = escapeshellarg(trim($_POST['noip_user'] ?? ''));
                    $pass = escapeshellarg(trim($_POST['noip_pass'] ?? ''));
                    if (!$host || !$user || !$pass) { $msg = 'No-IP requires hostname, username, and password.'; $msg_type = 'error'; break; }
                    $sh = "#!/usr/bin/env bash\nHOST={$host}\nUSER={$user}\nPASS={$pass}\n"
                        . "IP=\$(curl -sf --max-time 10 https://api.ipify.org)\n"
                        . "curl -sf -u \"\${USER}:\${PASS}\" \"https://dynupdate.no-ip.com/nic/update?hostname=\${HOST}&myip=\${IP}\" -A 'WireGuardManager/1.0' >> /var/log/wireguard-manager/ddns.log\n";
                    file_put_contents($script, $sh); chmod($script, 0700);
                    $msg = 'No-IP DDNS updated.'; break;

                case 'cloudflare':
                    $zone   = escapeshellarg(trim($_POST['cf_zone']   ?? ''));
                    $record = escapeshellarg(trim($_POST['cf_record'] ?? ''));
                    $token  = escapeshellarg(trim($_POST['cf_token']  ?? ''));
                    $rname  = escapeshellarg(trim($_POST['cf_rname']  ?? ''));
                    if (!$zone || !$record || !$token || !$rname) { $msg = 'All Cloudflare fields are required.'; $msg_type = 'error'; break; }
                    $sh = "#!/usr/bin/env bash\nZONE={$zone}\nRECORD={$record}\nTOKEN={$token}\nRNAME={$rname}\n"
                        . "IP=\$(curl -sf --max-time 10 https://api.ipify.org)\n"
                        . "curl -sf -X PATCH \"https://api.cloudflare.com/client/v4/zones/\${ZONE}/dns_records/\${RECORD}\""
                        . " -H \"Authorization: Bearer \${TOKEN}\" -H 'Content-Type: application/json'"
                        . " --data \"{\\\"type\\\":\\\"A\\\",\\\"name\\\":\\\"\${RNAME}\\\",\\\"content\\\":\\\"\${IP}\\\",\\\"ttl\\\":60}\" >> /var/log/wireguard-manager/ddns.log\n";
                    file_put_contents($script, $sh); chmod($script, 0700);
                    $msg = 'Cloudflare DDNS updated.'; break;

                case 'none':
                    // Disable cron
                    @unlink('/etc/cron.d/wireguard-ddns');
                    $msg = 'DDNS disabled. Cron job removed.'; break;

                default:
                    $msg = 'Unknown DDNS provider.'; $msg_type = 'error';
            }
        }

        if ($section === 'update_settings') {
            $auto_update   = isset($_POST['auto_update'])  ? 'true' : 'false';
            $enable_check  = isset($_POST['enable_check']) ? 'true' : 'false';

            // Update config.env
            $env_path = '/opt/wireguard/config.env';
            $content  = file_get_contents($env_path);
            $content  = preg_replace('/^AUTO_UPDATE=.*/m',           "AUTO_UPDATE=\"{$auto_update}\"",  $content);
            $content  = preg_replace('/^ENABLE_UPDATE_CHECK=.*/m',   "ENABLE_UPDATE_CHECK=\"{$enable_check}\"", $content);
            file_put_contents($env_path, $content);

            // Toggle cron job
            $cron_path = '/etc/cron.d/wireguard-update-check';
            if ($enable_check === 'true') {
                file_put_contents($cron_path, "0 1 * * * root /usr/local/bin/wg-check-update >> /var/log/wireguard-manager/update.log 2>&1\n");
                chmod($cron_path, 0644);
            } else {
                @unlink($cron_path);
            }

            $mode = $auto_update === 'true' ? 'auto-apply' : 'notify-only';
            $msg = "Update settings saved. Mode: {$mode}. Nightly check: {$enable_check}.";
        }

        if ($section === 'backup') {
            exec('sudo /opt/wireguard/backup.sh 2>&1', $out, $code);
            if ($code === 0) {
                $msg = 'Manual backup triggered successfully.';
            } else {
                $msg = 'Backup failed: ' . htmlspecialchars(implode(' ', $out));
                $msg_type = 'error';
            }
        }
    }
}

// ---- Reload config after possible update ----
$cfg = wgm_config();

// ---- Flash messages from action.php redirects (GET) ----
// action.php runs wg-check-update / wg-update then redirects here with ?msg=...
if (!$msg && isset($_GET['msg'])) {
    if ($_GET['msg'] === 'check_triggered') {
        $upd = wgm_update_status();
        if (($upd['status'] ?? '') === 'available') {
            $msg = 'Checked for updates — update available: '
                 . htmlspecialchars($upd['current_version'] ?? '?') . ' → '
                 . htmlspecialchars($upd['latest_version'] ?? '?') . '.';
        } else {
            $msg = 'Checked for updates — you are on the latest version ('
                 . htmlspecialchars($upd['latest_version'] ?? wgm_version()) . ').';
        }
    } elseif ($_GET['msg'] === 'update_triggered') {
        $msg = 'Update applied. Now running version ' . htmlspecialchars(wgm_version()) . '.';
    }
}

// ---- Read current DDNS script to detect provider ----
$ddns_script = @file_get_contents('/opt/wireguard/ddns/update.sh') ?: '';
$current_ddns = 'none';
if (str_contains($ddns_script, 'duckdns.org'))          $current_ddns = 'duckdns';
elseif (str_contains($ddns_script, 'no-ip.com'))        $current_ddns = 'noip';
elseif (str_contains($ddns_script, 'cloudflare.com'))   $current_ddns = 'cloudflare';

// ---- Read last few DDNS log lines ----
$ddns_log = '';
exec('tail -5 /var/log/wireguard-manager/ddns.log 2>/dev/null', $ddns_log_lines);
$ddns_log = implode("\n", $ddns_log_lines);

// ---- Read last backup ----
exec('ls -t /opt/wireguard/backups/wgm_backup_*.tar.gz 2>/dev/null | head -1', $backup_lines);
$last_backup = $backup_lines[0] ?? null;
$last_backup_time = $last_backup ? date('Y-m-d H:i', filemtime($last_backup)) : 'Never';

// ---- Subnet info ----
exec('ip addr show wg0 2>/dev/null | grep "inet "', $iface_lines);
$wg_iface_ip = trim(preg_replace('/inet\s+/', '', $iface_lines[0] ?? ''));

layout_head();
layout_sidebar();
?>
<div class="wgm-main">
<?php layout_topbar('Configuration', 'bi-gear'); ?>
<div class="wgm-content">

<?php if ($msg): ?>
<div class="wgm-alert <?= $msg_type ?>"><?= $msg ?></div>
<?php endif; ?>

<div class="row g-3">

    <!-- ── Left column ──────────────────────────────────────── -->
    <div class="col-lg-6">

        <!-- Server Info (read-only) -->
        <div class="wgm-card mb-3">
            <div class="wgm-card-header">Server Info</div>
            <div class="wgm-card-body">
                <table style="width:100%; font-size:.85rem; border-collapse:collapse;">
                    <?php
                    $rows = [
                        ['Hostname',       $cfg['SERVER_HOSTNAME'] ?? '—'],
                        ['Public Endpoint',$cfg['SERVER_ENDPOINT'] ?? '—'],
                        ['WireGuard Port', ($cfg['WG_PORT'] ?? '—') . '/UDP'],
                        ['VPN Subnet',     $cfg['VPN_SUBNET'] ?? '—'],
                        ['Server VPN IP',  $cfg['SERVER_VPN_IP'] ?? '—'],
                        ['Interface IP',   $wg_iface_ip ?: '—'],
                        ['Network Iface',  $cfg['NET_IFACE'] ?? '—'],
                        ['IPv6',           ($cfg['ENABLE_IPV6'] ?? 'false') === 'true' ? 'Enabled' : 'Disabled'],
                        ['WGM Version',    wgm_version()],
                    ];
                    foreach ($rows as [$label, $val]): ?>
                    <tr style="border-bottom:1px solid var(--border);">
                        <td style="color:var(--muted); padding:.5rem .25rem; width:45%;"><?= $label ?></td>
                        <td style="padding:.5rem .25rem;"><code><?= htmlspecialchars($val) ?></code></td>
                    </tr>
                    <?php endforeach; ?>
                </table>
                <p style="color:var(--muted); font-size:.75rem; margin-top:.75rem; margin-bottom:0;">
                    These values were set at install time. To change port or subnet, reinstall.
                </p>
            </div>
        </div>

        <!-- DNS Settings -->
        <div class="wgm-card mb-3">
            <div class="wgm-card-header">Client DNS</div>
            <div class="wgm-card-body">
                <p style="color:var(--muted); font-size:.82rem; margin-bottom:1rem;">
                    DNS assigned to new clients. Existing clients must re-download their config to pick up changes.
                </p>
                <form method="POST">
                    <input type="hidden" name="section" value="dns">
                    <input type="hidden" name="csrf"    value="<?= $_SESSION['csrf'] ?>">
                    <div class="mb-3">
                        <label class="form-label">DNS Servers</label>
                        <input type="text" name="dns" class="wgm-input"
                               value="<?= htmlspecialchars($cfg['CLIENT_DNS'] ?? '') ?>"
                               placeholder="1.1.1.1, 1.0.0.1">
                        <div style="color:var(--muted); font-size:.75rem; margin-top:.3rem;">
                            Comma-separated IPs. Examples: 1.1.1.1 · 8.8.8.8 · 9.9.9.9 · your Pi-hole IP
                        </div>
                    </div>
                    <button type="submit" class="btn btn-sm btn-wgm-primary">Save DNS</button>
                </form>
            </div>
        </div>

        <!-- Server Public Key -->
        <div class="wgm-card mb-3">
            <div class="wgm-card-header">Server Public Key</div>
            <div class="wgm-card-body">
                <?php
                $pub_key = trim(@file_get_contents('/etc/wireguard/server_public.key') ?: '');
                ?>
                <code style="word-break:break-all; display:block; font-size:.78rem; color:var(--muted);">
                    <?= htmlspecialchars($pub_key ?: 'Not found') ?>
                </code>
                <p style="color:var(--muted); font-size:.75rem; margin-top:.5rem; margin-bottom:0;">
                    Share this with clients who need to configure peers manually.
                    The private key is never shown here.
                </p>
            </div>
        </div>

    </div>

    <!-- ── Right column ─────────────────────────────────────── -->
    <div class="col-lg-6">

        <!-- DDNS -->
        <div class="wgm-card mb-3">
            <div class="wgm-card-header">Dynamic DNS</div>
            <div class="wgm-card-body">
                <?php if ($ddns_log): ?>
                <div style="margin-bottom:1rem;">
                    <div style="color:var(--muted); font-size:.75rem; margin-bottom:.3rem;">Last update</div>
                    <div class="log-output" style="max-height:80px; font-size:.72rem;"><?= htmlspecialchars($ddns_log) ?></div>
                </div>
                <?php endif; ?>

                <form method="POST">
                    <input type="hidden" name="section" value="ddns">
                    <input type="hidden" name="csrf"    value="<?= $_SESSION['csrf'] ?>">

                    <div class="mb-3">
                        <label class="form-label">Provider</label>
                        <select name="ddns_provider" class="wgm-select" id="ddns-provider-select"
                                onchange="showDdnsFields(this.value)">
                            <option value="duckdns"    <?= $current_ddns==='duckdns'    ? 'selected':'' ?>>DuckDNS</option>
                            <option value="noip"       <?= $current_ddns==='noip'       ? 'selected':'' ?>>No-IP</option>
                            <option value="cloudflare" <?= $current_ddns==='cloudflare' ? 'selected':'' ?>>Cloudflare</option>
                            <option value="none"       <?= $current_ddns==='none'       ? 'selected':'' ?>>None (disable)</option>
                        </select>
                    </div>

                    <!-- DuckDNS fields -->
                    <div id="fields-duckdns" class="ddns-fields" style="display:none;">
                        <div class="mb-2">
                            <label class="form-label">Subdomain</label>
                            <input type="text" name="duckdns_sub" class="wgm-input" placeholder="myhome">
                        </div>
                        <div class="mb-2">
                            <label class="form-label">Token</label>
                            <input type="password" name="duckdns_token" class="wgm-input" placeholder="••••••••">
                        </div>
                    </div>

                    <!-- No-IP fields -->
                    <div id="fields-noip" class="ddns-fields" style="display:none;">
                        <div class="mb-2">
                            <label class="form-label">Hostname</label>
                            <input type="text" name="noip_host" class="wgm-input" placeholder="myhome.ddns.net">
                        </div>
                        <div class="mb-2">
                            <label class="form-label">Username / Email</label>
                            <input type="text" name="noip_user" class="wgm-input">
                        </div>
                        <div class="mb-2">
                            <label class="form-label">Password</label>
                            <input type="password" name="noip_pass" class="wgm-input">
                        </div>
                    </div>

                    <!-- Cloudflare fields -->
                    <div id="fields-cloudflare" class="ddns-fields" style="display:none;">
                        <div class="mb-2">
                            <label class="form-label">Zone ID</label>
                            <input type="text" name="cf_zone" class="wgm-input">
                        </div>
                        <div class="mb-2">
                            <label class="form-label">DNS Record ID</label>
                            <input type="text" name="cf_record" class="wgm-input">
                        </div>
                        <div class="mb-2">
                            <label class="form-label">API Token</label>
                            <input type="password" name="cf_token" class="wgm-input">
                        </div>
                        <div class="mb-2">
                            <label class="form-label">Record name (e.g. vpn.example.com)</label>
                            <input type="text" name="cf_rname" class="wgm-input">
                        </div>
                    </div>

                    <button type="submit" class="btn btn-sm btn-wgm-primary">Save DDNS</button>
                </form>
            </div>
        </div>

        <!-- Backup -->
        <div class="wgm-card mb-3">
            <div class="wgm-card-header">Backup</div>
            <div class="wgm-card-body">
                <table style="width:100%; font-size:.85rem; border-collapse:collapse;">
                    <tr style="border-bottom:1px solid var(--border);">
                        <td style="color:var(--muted); padding:.4rem .25rem;">Last backup</td>
                        <td style="padding:.4rem .25rem;"><code><?= htmlspecialchars($last_backup_time) ?></code></td>
                    </tr>
                    <tr>
                        <td style="color:var(--muted); padding:.4rem .25rem;">Backup path</td>
                        <td style="padding:.4rem .25rem; font-size:.78rem; color:var(--muted);">/opt/wireguard/backups/</td>
                    </tr>
                </table>
                <form method="POST" style="margin-top:1rem;">
                    <input type="hidden" name="section" value="backup">
                    <input type="hidden" name="csrf"    value="<?= $_SESSION['csrf'] ?>">
                    <button type="submit" class="btn btn-sm btn-wgm-primary">
                        <i class="bi bi-archive me-1"></i>Run Backup Now
                    </button>
                </form>
            </div>
        </div>

        <!-- Updates -->
        <div class="wgm-card mb-3">
            <div class="wgm-card-header">Software Updates</div>
            <div class="wgm-card-body">
                <?php
                $upd = wgm_update_status();
                $upd_status  = $upd['status'] ?? 'unknown';
                $upd_current = $upd['current_version'] ?? wgm_version();
                $upd_latest  = $upd['latest_version'] ?? '—';
                $upd_checked = $upd['checked_at'] ?? 'Never';
                $upd_auto    = ($upd['auto_update'] ?? false) === true
                            || ($cfg['AUTO_UPDATE'] ?? 'false') === 'true';
                $upd_enabled = ($cfg['ENABLE_UPDATE_CHECK'] ?? 'true') === 'true';
                ?>

                <!-- Status row -->
                <div style="display:flex; align-items:center; gap:.75rem; margin-bottom:1rem;
                            padding:.65rem .75rem; background:var(--surface2);
                            border-radius:var(--radius); border:1px solid var(--border);">
                    <?php if ($upd_status === 'available'): ?>
                        <i class="bi bi-arrow-up-circle-fill" style="color:var(--yellow); font-size:1.2rem;"></i>
                        <div>
                            <div style="font-weight:600; color:var(--yellow);">Update available</div>
                            <div style="font-size:.75rem; color:var(--muted);">
                                <?= htmlspecialchars($upd_current) ?> → <?= htmlspecialchars($upd_latest) ?>
                            </div>
                        </div>
                        <form method="POST" action="action.php" style="margin-left:auto;">
                            <input type="hidden" name="action" value="update">
                            <input type="hidden" name="csrf"   value="<?= $_SESSION['csrf'] ?>">
                            <button type="submit" class="btn btn-sm btn-warning" style="font-size:.78rem;">
                                Update now
                            </button>
                        </form>
                    <?php elseif ($upd_status === 'up_to_date'): ?>
                        <i class="bi bi-check-circle-fill" style="color:var(--green); font-size:1.2rem;"></i>
                        <div>
                            <div style="font-weight:600; color:var(--green);">Up to date</div>
                            <div style="font-size:.75rem; color:var(--muted);">
                                Version <?= htmlspecialchars($upd_current) ?>
                            </div>
                        </div>
                    <?php elseif ($upd_status === 'updating'): ?>
                        <i class="bi bi-arrow-repeat" style="color:var(--accent); font-size:1.2rem;"></i>
                        <div style="color:var(--accent);">Update in progress...</div>
                    <?php elseif ($upd_status === 'error'): ?>
                        <i class="bi bi-exclamation-triangle-fill" style="color:var(--red); font-size:1.2rem;"></i>
                        <div>
                            <div style="font-weight:600; color:var(--red);">Check failed</div>
                            <div style="font-size:.75rem; color:var(--muted);">
                                <?= htmlspecialchars($upd['message'] ?? '') ?>
                            </div>
                        </div>
                    <?php else: ?>
                        <i class="bi bi-question-circle" style="color:var(--muted); font-size:1.2rem;"></i>
                        <div style="color:var(--muted);">No update check run yet.</div>
                    <?php endif; ?>
                </div>

                <table style="width:100%; font-size:.82rem; border-collapse:collapse; margin-bottom:1rem;">
                    <tr style="border-bottom:1px solid var(--border);">
                        <td style="color:var(--muted); padding:.4rem .25rem;">Installed version</td>
                        <td style="padding:.4rem .25rem;"><code><?= htmlspecialchars($upd_current) ?></code></td>
                    </tr>
                    <tr style="border-bottom:1px solid var(--border);">
                        <td style="color:var(--muted); padding:.4rem .25rem;">Last checked</td>
                        <td style="padding:.4rem .25rem;"><?= htmlspecialchars($upd_checked) ?></td>
                    </tr>
                    <tr style="border-bottom:1px solid var(--border);">
                        <td style="color:var(--muted); padding:.4rem .25rem;">Nightly check</td>
                        <td style="padding:.4rem .25rem;">
                            <?= $upd_enabled
                                ? '<span style="color:var(--green);">Enabled (1:00 AM)</span>'
                                : '<span style="color:var(--muted);">Disabled</span>' ?>
                        </td>
                    </tr>
                    <tr>
                        <td style="color:var(--muted); padding:.4rem .25rem;">Auto-apply updates</td>
                        <td style="padding:.4rem .25rem;">
                            <?= $upd_auto
                                ? '<span style="color:var(--yellow);">On — updates apply automatically</span>'
                                : '<span style="color:var(--muted);">Off — notify only</span>' ?>
                        </td>
                    </tr>
                </table>

                <!-- Toggle auto-update via config.env -->
                <form method="POST">
                    <input type="hidden" name="section" value="update_settings">
                    <input type="hidden" name="csrf"    value="<?= $_SESSION['csrf'] ?>">
                    <div style="display:flex; flex-direction:column; gap:.6rem;">
                        <label style="display:flex; align-items:center; gap:.6rem; cursor:pointer; font-size:.85rem;">
                            <input type="checkbox" name="auto_update" value="1"
                                   <?= $upd_auto ? 'checked' : '' ?>
                                   style="accent-color:var(--accent); width:15px; height:15px;">
                            Auto-apply updates at 1 AM
                            <span style="color:var(--muted); font-size:.75rem;">(WireGuard stays running)</span>
                        </label>
                        <label style="display:flex; align-items:center; gap:.6rem; cursor:pointer; font-size:.85rem;">
                            <input type="checkbox" name="enable_check" value="1"
                                   <?= $upd_enabled ? 'checked' : '' ?>
                                   style="accent-color:var(--accent); width:15px; height:15px;">
                            Enable nightly update checks
                        </label>
                    </div>
                    <div style="display:flex; gap:.5rem; margin-top:.75rem;">
                        <button type="submit" class="btn btn-sm btn-wgm-primary">Save</button>
                        <form method="POST" action="action.php" style="display:inline;">
                            <input type="hidden" name="action" value="check_update">
                            <input type="hidden" name="csrf"   value="<?= $_SESSION['csrf'] ?>">
                            <button type="submit" class="btn btn-sm btn-secondary">Check now</button>
                        </form>
                    </div>
                </form>
            </div>
        </div>

    </div>
</div><!-- /.row -->
</div><!-- /.wgm-content -->
</div><!-- /.wgm-main -->

<script>
function showDdnsFields(provider) {
    document.querySelectorAll('.ddns-fields').forEach(el => el.style.display = 'none');
    const target = document.getElementById('fields-' + provider);
    if (target) target.style.display = 'block';
}
// Show correct fields on page load
showDdnsFields(document.getElementById('ddns-provider-select').value);
</script>

<?php layout_foot(); ?>

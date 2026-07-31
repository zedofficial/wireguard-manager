# WireGuard Manager

A self-hosted WireGuard installation and management system for Linux home servers, Raspberry Pis, NanoPis, mini PCs, and VPSs. One command to install, a web dashboard to manage, and a single command to update everything across all your installs.

---

## Requirements

**Supported operating systems:**
- Debian 12 (Bookworm) or newer
- Ubuntu 22.04 LTS or newer
- Raspberry Pi OS (Bullseye or newer)
- Armbian

**Supported architectures:** `amd64` · `arm64` · `armhf`

**You need:**
- Root access (or `sudo`)
- A working internet connection
- A public IP address or Dynamic DNS hostname

---

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/zedofficial/wireguard-manager/main/install.sh -o install.sh
sudo bash install.sh
```

> **Do not pipe directly into bash** (`curl ... | sudo bash`). The installer is interactive — it needs to read keyboard input, which breaks when stdin is a pipe.



The installer will ask you questions — no manual config file editing needed. It walks you through:

1. Hostname
2. VPN subnet (default `10.0.0.0/24`)
3. Public endpoint (auto-detects your IP)
4. WireGuard port (default `51820`)
5. Network interface (auto-detected)
6. DNS for VPN clients (Cloudflare, Google, Quad9, Pi-hole, AdGuard, or custom)
7. Dynamic DNS provider (DuckDNS, No-IP, Cloudflare API, custom URL, or none)
8. IPv6 support
9. Optional components (Dashboard, Uptime Kuma, auto-backups, automatic updates)

Total install time: roughly 3–5 minutes depending on your connection.

---

## Client Management

All commands run as root (or with `sudo`).

### Add a client
```bash
wg-add-client phone-zed
```
Generates keys, assigns the next available IP, writes the config, adds the peer to the live tunnel, and shows a QR code to scan with the WireGuard app. No restart needed.

### List all clients
```bash
wg-list-clients
```
Shows a table with each client's name, VPN IP, online/offline/disabled status, last handshake time, and creation date.

### Show config and QR code
```bash
wg-show-client phone-zed
```

### Delete a client
```bash
wg-delete-client phone-zed
```
Removes the peer from the live tunnel immediately. Asks you to type the client name to confirm — this is permanent.

### Disable a client (temporary block)
```bash
wg-disable-client phone-zed
```
Removes the peer from the tunnel without deleting any keys or config. Use this when you want to temporarily block access.

### Re-enable a disabled client
```bash
wg-enable-client phone-zed
```
Re-adds the peer to the live tunnel instantly. No restart needed.

### Rename a client
```bash
wg-rename-client phone-zed zeds-phone
```
Renames files, the database entry, and the `wg0.conf` label. The client's IP address and keys are unchanged — they do not need to reconnect.

### Export a client config
```bash
wg-export-client phone-zed              # QR code + saves .conf to current directory
wg-export-client phone-zed --qr        # QR code only
wg-export-client phone-zed --conf      # Raw config text
wg-export-client phone-zed --path /tmp # Save .conf to a specific directory
```

### Import an existing client config
```bash
wg-import-client zeds-laptop /path/to/zeds-laptop.conf
```
Parses an existing `.conf` file and registers it with WireGuard Manager without generating new keys.

### Regenerate QR code
```bash
wg-regen-qr phone-zed
```
Re-renders the QR code from the existing config. Keys are never changed.

---

## Web Dashboard

If you installed the dashboard, it runs on port 80 at your server's address.

### Access

By default the dashboard is **private** — reachable only from:
- your **home/local network** (private IP ranges), and
- **VPN clients** connected through WireGuard.

It is **not** exposed to the public internet unless you choose to during install
(the installer asks). This is enforced two ways: an Apache `Require ip` rule and a
UFW rule, so it holds even if one layer is misconfigured.

```
http://your-server-ip        # from home / LAN
http://10.0.0.1              # when connected via the VPN (your server's VPN IP)
```

You can switch between **private** and **public** at any time from the dashboard:
**Configuration → Dashboard Access**. (Or from the terminal: `sudo wg-dashboard-access private` / `public`.)
This updates both the Apache rule and the firewall and reloads Apache — no reinstall needed.

### Private vs. public, and what each means for encryption

| | Private (default) | Public |
|---|---|---|
| Port | `:80`, plain HTTP | `:443`, HTTPS (`:80` redirects to it) |
| Certificate | none | self-signed, generated at switch time |
| Reachable from | LAN + VPN clients only | anywhere |

Plain HTTP is used in private mode because the traffic never leaves your LAN or
the WireGuard tunnel — which is already encrypted. Switching to public turns on
HTTPS automatically; you don't have to configure anything.

The certificate is **self-signed**, so browsers show a one-time trust warning.
That's expected for a personal server without a domain, and the connection is
still encrypted once you accept it. If you're exposing the dashboard to the
internet for anyone other than yourself, put it behind a reverse proxy with a
real certificate (Let's Encrypt) instead — a self-signed cert can't tell a user
apart from an attacker's substitute.

**Recommendation: leave it private.** The dashboard manages VPN keys and runs
privileged commands. If you can reach your server over the VPN, you don't need it
public.

**Default password:** `admin`

The first time you log in, the dashboard **forces you to change the password** before
you can use it — you can't get past the change-password screen while it's still `admin`.
You can also change it any time from the terminal:
```bash
sudo wg-dashboard-passwd
```

### Dashboard pages

| Page | What it does |
|---|---|
| **Dashboard** | WireGuard status, client overview, transfer stats, controls |
| **Clients** | Add, delete, disable, enable, rename, show QR, download config |
| **Configuration** | DNS settings, DDNS provider, backup, update settings |
| **Logs** | WireGuard, system, DDNS, install, update, and backup logs |

### WireGuard controls

The Start / Stop / Restart / Reload buttons are on the Dashboard page. They work without a terminal.

---

## Dynamic DNS

Supported providers:

| Provider | What you need |
|---|---|
| **DuckDNS** | Your subdomain + token from duckdns.org |
| **No-IP** | Your hostname + username + password |
| **Cloudflare** | Zone ID + DNS Record ID + API Token + record name |
| **Custom URL** | Any URL that updates your IP when fetched (use `${IP}` as placeholder) |
| **None** | Static IP or self-managed |

The update script runs every 5 minutes via cron. Logs are at `/var/log/wireguard-manager/ddns.log` and visible in the dashboard Logs page.

You can change your DDNS provider at any time from the **Configuration** page in the dashboard.

---

## Automatic Updates

WireGuard Manager can check GitHub for updates nightly and either notify you or apply them automatically.

**How it works:**
- A cron job runs `wg-check-update` at 1:00 AM every night
- It compares the installed version against the `version` file in this repo
- If an update is found, it writes `/opt/wireguard/update_status.json`
- The dashboard reads that file on every page load and shows a banner if an update is available
- If auto-update is enabled, the update is applied automatically (WireGuard stays running, no clients are disconnected)

**Configure from the dashboard:** Configuration page → Software Updates section.

**Or from the terminal:**

```bash
# Check for updates without applying
wg-update --check

# Apply update now (interactive)
wg-update

# Apply update non-interactively (used internally by auto-update)
wg-update --force --yes
```

**What gets updated:**
- All `wg-*` management commands
- The PHP dashboard
- The backup script

**What is never touched:**
- `/etc/wireguard/wg0.conf`
- Server private/public keys
- Client configs and keys
- `/opt/wireguard/clients.db`
- `/opt/wireguard/config.env`
- `/opt/wireguard/dashboard.passwd`
- DDNS credentials

---

## Backups

If you enabled automatic backups, a backup runs daily at 2:00 AM.

**Manual backup:**
```bash
sudo bash /opt/wireguard/backup.sh
```

**Backup location:** `/opt/wireguard/backups/`

Each backup is a `.tar.gz` containing:
- `/etc/wireguard/` (all keys and client configs)
- `clients.db`
- `config.env`
- DDNS scripts

The last 7 backups are kept automatically.

---

## File Layout

```
/etc/wireguard/
  wg0.conf                  WireGuard server config
  server_private.key
  server_public.key
  clients/
    <name>/
      private.key
      public.key
      preshared.key
      <name>.conf            Client config (shareable)

/opt/wireguard/
  config.env                Runtime settings (read by all wg-* commands)
  clients.db                Client registry (name|ip|pubkey|created|status)
  version                   Installed version string
  update_status.json        Last update check result (read by dashboard)
  dashboard.passwd          Bcrypt hash of dashboard password
  backup.sh
  backups/
  ddns/
    update.sh
  logs/ → /var/log/wireguard-manager/

/usr/local/bin/
  wg-add-client
  wg-delete-client
  wg-show-client
  wg-list-clients
  wg-disable-client
  wg-enable-client
  wg-rename-client
  wg-export-client
  wg-import-client
  wg-regen-qr
  wg-update
  wg-check-update
  wg-dashboard-passwd

/var/log/wireguard-manager/
  install.log
  ddns.log
  update.log
  backup.log

/var/www/html/wireguard-manager/
  layout.php
  index.php
  login.php
  logout.php
  action.php
  clients.php
  config.php
  logs.php

/etc/cron.d/
  wireguard-ddns            Every 5 min — DDNS update
  wireguard-backup          Daily 2 AM — backup
  wireguard-update-check    Daily 1 AM — update check
```

---

## Updating

```bash
sudo wg-update
```

That's it. WireGuard keeps running. Your clients stay connected.

---

## Uninstalling

The fastest way is the built-in reset, which removes everything the installer created:

```bash
sudo wg-reset --dry-run   # preview exactly what would be removed (changes nothing)
sudo wg-reset             # actually remove everything, then prompt to reinstall
```

Or remove it manually:

```bash
# Stop and disable WireGuard
sudo systemctl stop wg-quick@wg0
sudo systemctl disable wg-quick@wg0

# Remove WireGuard config and client data
sudo rm -rf /etc/wireguard
sudo rm -rf /opt/wireguard

# Remove scripts
sudo rm -f /usr/local/bin/wg-*

# Remove cron jobs
sudo rm -f /etc/cron.d/wireguard-*

# Remove dashboard (if installed)
sudo a2dissite wireguard-manager.conf
sudo rm -rf /var/www/html/wireguard-manager
sudo rm -f /etc/apache2/sites-available/wireguard-manager.conf
sudo rm -f /etc/sudoers.d/wireguard-manager

# Remove logs
sudo rm -rf /var/log/wireguard-manager
```

---

## Troubleshooting

**WireGuard won't start:**
```bash
sudo journalctl -u wg-quick@wg0 -n 50
```

**Client can connect but has no internet:**
- Check that IP forwarding is enabled: `cat /proc/sys/net/ipv4/ip_forward` should be `1`
- Check NAT rules: `sudo iptables -t nat -L POSTROUTING`

**Dashboard shows blank page or PHP errors:**
```bash
sudo journalctl -u apache2 -n 30
sudo tail -30 /var/log/apache2/wgm_error.log
```

**DDNS not updating:**
```bash
sudo bash /opt/wireguard/ddns/update.sh
cat /var/log/wireguard-manager/ddns.log
```

**Update check failing:**
```bash
sudo wg-check-update
cat /var/log/wireguard-manager/update.log
```

**Port not reachable from outside:**
- Make sure your router is forwarding UDP port `51820` (or whatever port you chose) to this machine
- Check UFW: `sudo ufw status`

---

## Project Structure (repo)

```
wireguard-manager/
  install.sh
  reset.sh
  version
  manifest.txt
  README.md
  scripts/
    wg-add-client
    wg-delete-client
    wg-show-client
    wg-list-clients
    wg-disable-client
    wg-enable-client
    wg-rename-client
    wg-export-client
    wg-import-client
    wg-regen-qr
    wg-show-qr
    wg-get-config
    wg-update
    wg-check-update
    wg-reset
    wg-dashboard-passwd
    backup.sh
  dashboard/
    layout.php
    index.php
    login.php
    logout.php
    action.php
    clients.php
    config.php
    logs.php
  docs/
    README.md
```

---

## Maintaining: adding a new script or dashboard page

`manifest.txt` is the single source of truth for which files get deployed. Both
`install.sh` (fresh installs) and `wg-update` (existing installs) read it, so you
do **not** edit either of them when adding files.

1. Drop the new file in `scripts/` or `dashboard/`.
2. Add one line to `manifest.txt`:
   - `bin scripts/wg-my-command` — a command, installed to `/usr/local/bin`, made executable
   - `web dashboard/mypage.php` — a dashboard page, installed to the web root
3. If it's a dashboard page, add its link to `layout.php`. If it's a command the
   dashboard calls, add a `www-data` rule in the sudoers block of `install.sh`.
4. Bump `version` and push.

That's it — the new file flows to every install on the next update. (As always,
the *very first* update after a change runs the old updater once to install the new
one; brand-new files land on the following update, or immediately via `wg-update --force`.)

---

## Security

Found a vulnerability? Please report it privately — see [SECURITY.md](SECURITY.md).
Don't open a public issue for security problems.

---

## License

[Apache License 2.0](LICENSE).

You may use, run, and modify this for any purpose, including commercially. Two
things the license asks in return:

- **Modified files must state that they were changed** (§4(b)) — so a customised
  copy is never mistaken for an official release.
- **The name is not licensed** (§6) — a fork can't call itself WireGuard Manager.

Provided **as is, without warranty of any kind**. You run it on your own servers
at your own risk. That applies especially to modified copies: if you change it,
whatever happens next is yours to support, not mine.

Copyright © 2026 ZED Official

---

*Built by ZED Official*

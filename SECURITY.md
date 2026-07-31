# Security Policy

WireGuard Manager configures a VPN, writes firewall rules, and runs a small set of
privileged commands on behalf of a web dashboard. Security reports are welcome and
taken seriously.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it privately through GitHub:

> **Security** tab → **Report a vulnerability**

That opens a private advisory visible only to you and the maintainer. If private
reporting is unavailable to you for any reason, open a public issue containing
only "security report, please advise how to reach you privately" — with no
details — and you'll get a private channel.

**What helps:** the version (`cat /opt/wireguard/version`), the OS and
architecture, what an attacker would need in order to exploit it (network access?
a dashboard login? local shell?), and the steps to reproduce.

**What to expect:** an acknowledgement within a few days. This is a
single-maintainer project, not a company with an on-call rotation — please size
your expectations accordingly. Fixes ship as a normal tagged release, and the
advisory is published once a fix is available.

## Supported versions

Only the **latest release** is supported. Fixes are not backported. Run
`wg-update` to get current before reporting — the issue may already be fixed.

| Version | Supported |
|---|---|
| latest release | yes |
| anything older | no — update first |

## Scope

**In scope** — things worth reporting:

- Privilege escalation through the `sudoers` rules, or command/argument injection
  in any of the `wg-*` scripts the dashboard is allowed to invoke
- Authentication bypass, session fixation, or CSRF in the dashboard
- Path traversal or unsafe handling of client names, imported configs, or uploads
- Secrets (private keys, preshared keys, DDNS credentials, the dashboard password
  hash) exposed through logs, process arguments, file permissions, or backups
- Anything that lets an unauthenticated network client reach a privileged action
- Flaws in the updater's checksum verification or in the installer

**Out of scope:**

- Deliberately exposing the dashboard to the internet in public mode and objecting
  to the self-signed certificate — this is documented behaviour, and the
  recommendation is to keep the dashboard private
- Issues in WireGuard itself, Apache, PHP, or the operating system — report those
  upstream
- Anything requiring root on the server already, or physical access
- Modified copies of this software. Under the license, changed files must say so;
  bugs you introduce are not vulnerabilities in this project
- Missing hardening that has no demonstrated attack path, from an automated
  scanner with no accompanying analysis

## Security model, in brief

Knowing the intended design makes it easier to judge whether something is a real
finding:

- **The dashboard is private by default.** Access is restricted to LAN/private
  ranges and connected VPN clients, enforced at both Apache and the firewall so
  one misconfiguration is not enough to expose it.
- **The web user is not root.** `www-data` may run a fixed list of `wg-*` commands
  through `sudoers` and nothing else. That list is the security boundary, and it
  is the first place to look for a flaw.
- **Updates are tag-pinned and checksum-verified.** The updater downloads from an
  immutable release tag, verifies every file against `checksums.txt`, and installs
  nothing unless all of them match. Releases are not cryptographically signed —
  an attacker with write access to the repository is outside the current threat
  model.
- **Backups contain private keys.** They are written with `umask 077`, mode `600`,
  in a `700` directory, and are never uploaded anywhere by this software.

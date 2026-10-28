---
source-path: .
---

# Migration Plan: nginx-multisite

**TLDR**: This cookbook installs and configures nginx as a multi-site web server hosting three SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`). It hardens the host with fail2ban intrusion prevention, UFW firewall rules, and kernel-level sysctl security parameters. Self-signed TLS certificates are generated per site using a passphrase fetched from CyberArk Conjur. SSH is locked down (no root login, no password authentication). The cookbook runs four recipes in order: security hardening → nginx base install → SSL certificate generation → virtual host configuration.

## Service Type and Instances

**Service Type**: Web Server (nginx multi-site with TLS termination)

**Configured Instances**:

- **test.cluster.local**: Internal test environment virtual host
  - Location/Path: `/opt/server/test` (document root)
  - Port/Socket: HTTP 80 (redirects to HTTPS), HTTPS 443
  - SSL: Enabled — certificate: `/etc/ssl/certs/test.cluster.local.crt`, key: `/etc/ssl/private/test.cluster.local.key`
  - Key Config: TLSv1.2/TLSv1.3 only, HSTS enabled, security headers (X-Frame-Options DENY, X-Content-Type-Options, X-XSS-Protection, CSP), gzip on
  - Access log: `/var/log/nginx/test.cluster.local_access.log`
  - Error log: `/var/log/nginx/test.cluster.local_error.log`

- **ci.cluster.local**: CI/CD environment virtual host
  - Location/Path: `/opt/server/ci` (document root)
  - Port/Socket: HTTP 80 (redirects to HTTPS), HTTPS 443
  - SSL: Enabled — certificate: `/etc/ssl/certs/ci.cluster.local.crt`, key: `/etc/ssl/private/ci.cluster.local.key`
  - Key Config: TLSv1.2/TLSv1.3 only, HSTS enabled, security headers (X-Frame-Options DENY, X-Content-Type-Options, X-XSS-Protection, CSP), gzip on
  - Access log: `/var/log/nginx/ci.cluster.local_access.log`
  - Error log: `/var/log/nginx/ci.cluster.local_error.log`

- **status.cluster.local**: Status page virtual host
  - Location/Path: `/opt/server/status` (document root)
  - Port/Socket: HTTP 80 (redirects to HTTPS), HTTPS 443
  - SSL: Enabled — certificate: `/etc/ssl/certs/status.cluster.local.crt`, key: `/etc/ssl/private/status.cluster.local.key`
  - Key Config: TLSv1.2/TLSv1.3 only, HSTS enabled, security headers (X-Frame-Options DENY, X-Content-Type-Options, X-XSS-Protection, CSP), gzip on
  - Access log: `/var/log/nginx/status.cluster.local_access.log`
  - Error log: `/var/log/nginx/status.cluster.local_error.log`

## File Structure

```
cookbooks/nginx-multisite/
├── attributes/
│   └── default.rb
├── recipes/
│   ├── default.rb
│   ├── security.rb
│   ├── nginx.rb
│   ├── ssl.rb
│   └── sites.rb
└── templates/
    └── default/
        ├── fail2ban.jail.local.erb
        ├── nginx.conf.erb
        ├── security.conf.erb
        ├── site.conf.erb
        └── sysctl-security.conf.erb
```

> **Note**: The `cookbook_file` resources in `recipes/nginx.rb` reference static files using the pattern `"#{site_folder}/index.html"` (where `site_folder` is the first label of the site name: `test`, `ci`, `status`). These files (`test/index.html`, `ci/index.html`, `status/index.html`) are expected to exist in the cookbook's `files/default/` directory but were **not found** on disk. The Ansible migration must account for this — either provide these static files or replace them with placeholder content.

## Module Explanation

The cookbook performs operations in this order:

**1. default** (`cookbooks/nginx-multisite/recipes/default.rb`):
- Entry point — includes four sub-recipes in strict order
- Resources: `include_recipe` (4): `nginx-multisite::security`, `nginx-multisite::nginx`, `nginx-multisite::ssl`, `nginx-multisite::sites`

---

**2. security** (`cookbooks/nginx-multisite/recipes/security.rb`):
- Installs packages: `fail2ban`, `ufw` (single `package` resource with array)
- Enables and starts the `fail2ban` service
- Deploys fail2ban jail configuration:
  - Template: `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` (mode 0644)
  - Jail config: DEFAULT bantime=3600s, findtime=600s, maxretry=3; jails enabled: `[sshd]`, `[nginx-http-auth]`, `[nginx-limit-req]`, `[nginx-botsearch]`
  - Notifies: restart `fail2ban` service (delayed)
- Configures UFW firewall via five idempotent `execute` resources (each guarded by `not_if`):
  - `ufw_default_deny`: `ufw --force default deny` (skipped if already "Default: deny")
  - `ufw_allow_ssh`: `ufw allow ssh` (skipped if 22/tcp already present)
  - `ufw_allow_http`: `ufw allow http` (skipped if 80/tcp already present)
  - `ufw_allow_https`: `ufw allow https` (skipped if 443/tcp already present)
  - `ufw_enable`: `ufw --force enable` (skipped if already "Status: active")
- Deploys kernel security parameters:
  - Template: `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` (mode 0644)
  - Parameters set: IP spoofing protection (`rp_filter=1`), ICMP redirect ignore, source routing disabled, martian logging, ICMP ping ignore (`icmp_echo_ignore_all=1`), IPv6 disabled, TCP SYN cookie protection (`tcp_syncookies=1`, `tcp_max_syn_backlog=2048`)
  - Notifies: run `execute[reload_sysctl]` (delayed) → `sysctl -p /etc/sysctl.d/99-security.conf`
- Hardens SSH via custom resource `ada_ada` (line-in-file style editor):
  - Conditional: `node['security']['ssh']['disable_root']` is `true` → sets `PermitRootLogin no` in `/etc/ssh/sshd_config` (matches `^#?PermitRootLogin`)
  - Conditional: `node['security']['ssh']['password_auth']` is `false` → sets `PasswordAuthentication no` in `/etc/ssh/sshd_config` (matches `^#?PasswordAuthentication`)
  - Both notify: restart `service[ssh]` (delayed)
- `service 'ssh'` declared with `action :nothing` (only triggered by notifications above)
- Resources: package (1, array), service (2: fail2ban + ssh), template (2), execute (5: ufw×4 + reload_sysctl), ada_ada (2)

---

**3. nginx** (`cookbooks/nginx-multisite/recipes/nginx.rb`):
- Installs package: `nginx`
- Deploys global nginx configuration:
  - Template: `nginx.conf.erb` → `/etc/nginx/nginx.conf` (mode 0644)
  - Config: user=www-data, worker_processes=auto, worker_connections=768, sendfile/tcp_nopush/tcp_nodelay on, keepalive_timeout=65, gzip on, access_log=/var/log/nginx/access.log, error_log=/var/log/nginx/error.log
  - Includes: `/etc/nginx/conf.d/*.conf` and `/etc/nginx/sites-enabled/*`
  - Notifies: reload nginx (delayed)
- Deploys security snippet:
  - Template: `security.conf.erb` → `/etc/nginx/conf.d/security.conf` (mode 0644)
  - Config: server_tokens off, rate limit zones (login: 10r/m, api: 30r/m), client buffer limits (body=1K, header=1K, max_body=1K), timeouts (body/header/send=10s), global SSL settings (TLSv1.2/TLSv1.3, strong ciphers, session cache 10m)
  - Notifies: reload nginx (delayed)
- Enables and starts `nginx` service
- Iterations: Runs 3 times for sites: `test.cluster.local`, `ci.cluster.local`, `status.cluster.local`:
  - **test.cluster.local**:
    - Creates directory `/opt/server/test` (owner: www-data, group: www-data, mode: 0755, recursive)
    - Deploys `cookbook_file` → `/opt/server/test/index.html` from cookbook source `test/index.html` (owner: www-data, group: www-data, mode: 0644)
  - **ci.cluster.local**:
    - Creates directory `/opt/server/ci` (owner: www-data, group: www-data, mode: 0755, recursive)
    - Deploys `cookbook_file` → `/opt/server/ci/index.html` from cookbook source `ci/index.html` (owner: www-data, group: www-data, mode: 0644)
  - **status.cluster.local**:
    - Creates directory `/opt/server/status` (owner: www-data, group: www-data, mode: 0755, recursive)
    - Deploys `cookbook_file` → `/opt/server/status/index.html` from cookbook source `status/index.html` (owner: www-data, group: www-data, mode: 0644)
- Resources: package (1), template (2), service (1), directory (3), cookbook_file (3)

---

**4. ssl** (`cookbooks/nginx-multisite/recipes/ssl.rb`):
- Installs packages: `openssl`, `ca-certificates`
- **Fetches SSL passphrase from CyberArk Conjur** using `conjur_variable('production/nginx/ssl_passphrase')` — this is a runtime secret fetch, not a static attribute
- Creates group `ssl-cert`
- Creates SSL certificate directory `/etc/ssl/certs` (owner: root, group: root, mode: 0755)
- Creates SSL private key directory `/etc/ssl/private` (owner: root, group: ssl-cert, mode: 0710)
- Iterations: Runs 3 times for sites with `ssl_enabled: true`: `test.cluster.local`, `ci.cluster.local`, `status.cluster.local`:
  - **test.cluster.local**:
    - Runs `execute[generate-ssl-cert-test.cluster.local]` (idempotent: skipped if both `.crt` and `.key` already exist):
      - `openssl req -x509 -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/test.cluster.local.key -out /etc/ssl/certs/test.cluster.local.crt -passout pass:<conjur_secret> -subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=test.cluster.local/emailAddress=admin@example.com"`
      - `chmod 640 /etc/ssl/private/test.cluster.local.key`
      - `chown root:ssl-cert /etc/ssl/private/test.cluster.local.key`
      - Marked `sensitive true` (passphrase not logged)
      - Notifies: reload nginx (delayed)
  - **ci.cluster.local**:
    - Runs `execute[generate-ssl-cert-ci.cluster.local]` (idempotent: skipped if both `.crt` and `.key` already exist):
      - `openssl req -x509 -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/ci.cluster.local.key -out /etc/ssl/certs/ci.cluster.local.crt -passout pass:<conjur_secret> -subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=ci.cluster.local/emailAddress=admin@example.com"`
      - `chmod 640 /etc/ssl/private/ci.cluster.local.key`
      - `chown root:ssl-cert /etc/ssl/private/ci.cluster.local.key`
      - Marked `sensitive true`
      - Notifies: reload nginx (delayed)
  - **status.cluster.local**:
    - Runs `execute[generate-ssl-cert-status.cluster.local]` (idempotent: skipped if both `.crt` and `.key` already exist):
      - `openssl req -x509 -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/status.cluster.local.key -out /etc/ssl/certs/status.cluster.local.crt -passout pass:<conjur_secret> -subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=status.cluster.local/emailAddress=admin@example.com"`
      - `chmod 640 /etc/ssl/private/status.cluster.local.key`
      - `chown root:ssl-cert /etc/ssl/private/status.cluster.local.key`
      - Marked `sensitive true`
      - Notifies: reload nginx (delayed)
- Resources: package (1, array), group (1), directory (2), execute (3)

---

**5. sites** (`cookbooks/nginx-multisite/recipes/sites.rb`):
- Iterations: Runs 3 times for sites: `test.cluster.local`, `ci.cluster.local`, `status.cluster.local`:
  - **test.cluster.local**:
    - Deploys vhost config: `site.conf.erb` → `/etc/nginx/sites-available/test.cluster.local` (mode 0644)
      - Variables: server_name=`test.cluster.local`, document_root=`/opt/server/test`, ssl_enabled=`true`, cert_file=`/etc/ssl/certs/test.cluster.local.crt`, key_file=`/etc/ssl/private/test.cluster.local.key`
      - Notifies: reload nginx (delayed)
    - Creates symlink: `/etc/nginx/sites-enabled/test.cluster.local` → `/etc/nginx/sites-available/test.cluster.local`
      - Notifies: reload nginx (delayed)
  - **ci.cluster.local**:
    - Deploys vhost config: `site.conf.erb` → `/etc/nginx/sites-available/ci.cluster.local` (mode 0644)
      - Variables: server_name=`ci.cluster.local`, document_root=`/opt/server/ci`, ssl_enabled=`true`, cert_file=`/etc/ssl/certs/ci.cluster.local.crt`, key_file=`/etc/ssl/private/ci.cluster.local.key`
      - Notifies: reload nginx (delayed)
    - Creates symlink: `/etc/nginx/sites-enabled/ci.cluster.local` → `/etc/nginx/sites-available/ci.cluster.local`
      - Notifies: reload nginx (delayed)
  - **status.cluster.local**:
    - Deploys vhost config: `site.conf.erb` → `/etc/nginx/sites-available/status.cluster.local` (mode 0644)
      - Variables: server_name=`status.cluster.local`, document_root=`/opt/server/status`, ssl_enabled=`true`, cert_file=`/etc/ssl/certs/status.cluster.local.crt`, key_file=`/etc/ssl/private/status.cluster.local.key`
      - Notifies: reload nginx (delayed)
    - Creates symlink: `/etc/nginx/sites-enabled/status.cluster.local` → `/etc/nginx/sites-available/status.cluster.local`
      - Notifies: reload nginx (delayed)
- Deletes the default nginx site: `file '/etc/nginx/sites-enabled/default'` → action `:delete`
  - Notifies: reload nginx (delayed)
- Resources: template (3), link (3), file (1)

## Dependencies

**External cookbook dependencies**:
- `cyberark-conjur ~> 3.0` — provides the `conjur_variable()` helper used in `cookbooks/nginx-multisite/recipes/ssl.rb` to fetch the SSL passphrase at converge time
- `ada_ada` custom resource — defined in `resources/ada_ada.rb` within this cookbook; provides line-in-file editing for `/etc/ssh/sshd_config`

**System package dependencies**:
- `nginx` — web server
- `fail2ban` — intrusion prevention / log-based banning
- `ufw` — Uncomplicated Firewall (iptables frontend)
- `openssl` — TLS certificate generation
- `ca-certificates` — CA certificate bundle

**Service dependencies** (systemd services managed):
- `nginx` — enabled, started; reloaded on config/cert/vhost changes
- `fail2ban` — enabled, started; restarted on jail.local changes
- `ssh` (sshd) — restarted when sshd_config is modified

## Credentials

**Detection Summary**: 1 credential detected across 2 files (`attributes/default.rb` and `recipes/ssl.rb`)

**Source**:
- **Provider**: CyberArk Conjur
- **URL**: `https://conjur.example.com` (configured via `node['cyberark']['conjur']['appliance_url']`)
- **Path**: `production/nginx/ssl_passphrase` (configured via `node['cyberark']['conjur']['variable']`)

### SSL Certificate Passphrase

- **Variable(s)**: `node['cyberark']['conjur']['variable']` → resolves to path `production/nginx/ssl_passphrase`; runtime value stored in local variable `ssl_passphrase` inside `cookbooks/nginx-multisite/recipes/ssl.rb`
- **Source file(s)**:
  - `cookbooks/nginx-multisite/attributes/default.rb` — defines Conjur appliance URL, account (`myorg`), and variable path
  - `cookbooks/nginx-multisite/recipes/ssl.rb` — calls `conjur_variable(node['cyberark']['conjur']['variable'])` to fetch the secret at converge time; passes it as `-passout pass:<value>` to `openssl req`; the execute resource is marked `sensitive true` to suppress logging
- **Current storage**: CyberArk Conjur (fetched via the `cyberark-conjur` cookbook helper `conjur_variable()`)
- **Usage context**: Used as the PEM passphrase (`-passout pass:`) when generating self-signed RSA-2048 TLS certificates for all three nginx virtual hosts. The same passphrase is applied to all three certificate generation commands. The private key files are protected with mode 0640 and owned by `root:ssl-cert`.

> **AAP Migration Note**: In Ansible, this credential must be retrieved from CyberArk Conjur (or an equivalent secrets backend configured in AAP) before the `openssl` command runs. Use the `cyberark.conjur.conjur_variable` lookup plugin or AAP's CyberArk Conjur credential type. The secret path is `production/nginx/ssl_passphrase` in the `myorg` account at `https://conjur.example.com`. Mark any task using this value with `no_log: true`.

## Checks for the Migration

**Files to verify**:

*nginx configuration:*
- `/etc/nginx/nginx.conf`
- `/etc/nginx/conf.d/security.conf`
- `/etc/nginx/sites-available/test.cluster.local`
- `/etc/nginx/sites-available/ci.cluster.local`
- `/etc/nginx/sites-available/status.cluster.local`
- `/etc/nginx/sites-enabled/test.cluster.local` (symlink)
- `/etc/nginx/sites-enabled/ci.cluster.local` (symlink)
- `/etc/nginx/sites-enabled/status.cluster.local` (symlink)
- `/etc/nginx/sites-enabled/default` (must NOT exist — deleted)

*Document roots:*
- `/opt/server/test/index.html`
- `/opt/server/ci/index.html`
- `/opt/server/status/index.html`

*SSL certificates and keys:*
- `/etc/ssl/certs/test.cluster.local.crt`
- `/etc/ssl/private/test.cluster.local.key`
- `/etc/ssl/certs/ci.cluster.local.crt`
- `/etc/ssl/private/ci.cluster.local.key`
- `/etc/ssl/certs/status.cluster.local.crt`
- `/etc/ssl/private/status.cluster.local.key`

*Security configuration:*
- `/etc/fail2ban/jail.local`
- `/etc/sysctl.d/99-security.conf`
- `/etc/ssh/sshd_config` (PermitRootLogin no, PasswordAuthentication no)

*Log files:*
- `/var/log/nginx/access.log`
- `/var/log/nginx/error.log`
- `/var/log/nginx/test.cluster.local_access.log`
- `/var/log/nginx/test.cluster.local_error.log`
- `/var/log/nginx/ci.cluster.local_access.log`
- `/var/log/nginx/ci.cluster.local_error.log`
- `/var/log/nginx/status.cluster.local_access.log`
- `/var/log/nginx/status.cluster.local_error.log`

**Service endpoints to check**:
- Ports listening: 80 (HTTP, all three sites — redirect only), 443 (HTTPS, all three sites)
- Unix sockets: none
- Network interfaces: all interfaces (nginx listens on `0.0.0.0:80` and `0.0.0.0:443`)

**Templates rendered**:
- `nginx.conf.erb` → `/etc/nginx/nginx.conf` — renders **1 time** (global config)
- `security.conf.erb` → `/etc/nginx/conf.d/security.conf` — renders **1 time** (global security snippet)
- `site.conf.erb` → `/etc/nginx/sites-available/<site_name>` — renders **3 times**: once for `test.cluster.local`, once for `ci.cluster.local`, once for `status.cluster.local`
- `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` — renders **1 time**
- `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` — renders **1 time**

## Pre-flight Checks

```bash
# ============================================================
# 1. SERVICE STATUS
# ============================================================
systemctl status nginx
systemctl status fail2ban
systemctl status ssh

ps aux | grep nginx
ps aux | grep fail2ban

# ============================================================
# 2. NGINX CONFIGURATION SYNTAX
# ============================================================
nginx -t
nginx -T | grep -E 'server_name|listen|ssl_certificate|root'

# ============================================================
# 3. PORTS LISTENING
# ============================================================
ss -tlnp | grep -E ':80|:443'
netstat -tulpn | grep nginx
lsof -i :80
lsof -i :443

# ============================================================
# 4. VIRTUAL HOST: test.cluster.local
# ============================================================
# Config file present
ls -lah /etc/nginx/sites-available/test.cluster.local
ls -lah /etc/nginx/sites-enabled/test.cluster.local  # must be a symlink
readlink /etc/nginx/sites-enabled/test.cluster.local  # must point to sites-available/test.cluster.local

# Document root and index
ls -lah /opt/server/test/
cat /opt/server/test/index.html

# SSL certificate
openssl x509 -in /etc/ssl/certs/test.cluster.local.crt -noout -subject -dates -issuer
ls -lah /etc/ssl/private/test.cluster.local.key  # must be mode 640, owner root:ssl-cert
stat -c "%a %U:%G" /etc/ssl/private/test.cluster.local.key  # expect: 640 root:ssl-cert

# HTTP → HTTPS redirect
curl -I -H "Host: test.cluster.local" http://localhost/
# Expected: HTTP/1.1 301 Moved Permanently, Location: https://test.cluster.local/

# HTTPS response (self-signed cert, skip verify)
curl -k -I -H "Host: test.cluster.local" https://localhost/
# Expected: HTTP/1.1 200 OK

# Security headers on test.cluster.local
curl -k -s -I -H "Host: test.cluster.local" https://localhost/ | grep -E 'Strict-Transport|X-Frame|X-Content-Type|X-XSS|Referrer-Policy|Content-Security'

# Per-site logs
ls -lah /var/log/nginx/test.cluster.local_access.log
ls -lah /var/log/nginx/test.cluster.local_error.log
tail -20 /var/log/nginx/test.cluster.local_error.log

# ============================================================
# 5. VIRTUAL HOST: ci.cluster.local
# ============================================================
# Config file present
ls -lah /etc/nginx/sites-available/ci.cluster.local
ls -lah /etc/nginx/sites-enabled/ci.cluster.local  # must be a symlink
readlink /etc/nginx/sites-enabled/ci.cluster.local  # must point to sites-available/ci.cluster.local

# Document root and index
ls -lah /opt/server/ci/
cat /opt/server/ci/index.html

# SSL certificate
openssl x509 -in /etc/ssl/certs/ci.cluster.local.crt -noout -subject -dates -issuer
ls -lah /etc/ssl/private/ci.cluster.local.key
stat -c "%a %U:%G" /etc/ssl/private/ci.cluster.local.key  # expect: 640 root:ssl-cert

# HTTP → HTTPS redirect
curl -I -H "Host: ci.cluster.local" http://localhost/
# Expected: HTTP/1.1 301 Moved Permanently, Location: https://ci.cluster.local/

# HTTPS response
curl -k -I -H "Host: ci.cluster.local" https://localhost/
# Expected: HTTP/1.1 200 OK

# Security headers on ci.cluster.local
curl -k -s -I -H "Host: ci.cluster.local" https://localhost/ | grep -E 'Strict-Transport|X-Frame|X-Content-Type|X-XSS|Referrer-Policy|Content-Security'

# Per-site logs
ls -lah /var/log/nginx/ci.cluster.local_access.log
ls -lah /var/log/nginx/ci.cluster.local_error.log
tail -20 /var/log/nginx/ci.cluster.local_error.log

# ============================================================
# 6. VIRTUAL HOST: status.cluster.local
# ============================================================
# Config file present
ls -lah /etc/nginx/sites-available/status.cluster.local
ls -lah /etc/nginx/sites-enabled/status.cluster.local  # must be a symlink
readlink /etc/nginx/sites-enabled/status.cluster.local  # must point to sites-available/status.cluster.local

# Document root and index
ls -lah /opt/server/status/
cat /opt/server/status/index.html

# SSL certificate
openssl x509 -in /etc/ssl/certs/status.cluster.local.crt -noout -subject -dates -issuer
ls -lah /etc/ssl/private/status.cluster.local.key
stat -c "%a %U:%G" /etc/ssl/private/status.cluster.local.key  # expect: 640 root:ssl-cert

# HTTP → HTTPS redirect
curl -I -H "Host: status.cluster.local" http://localhost/
# Expected: HTTP/1.1 301 Moved Permanently, Location: https://status.cluster.local/

# HTTPS response
curl -k -I -H "Host: status.cluster.local" https://localhost/
# Expected: HTTP/1.1 200 OK

# Security headers on status.cluster.local
curl -k -s -I -H "Host: status.cluster.local" https://localhost/ | grep -E 'Strict-Transport|X-Frame|X-Content-Type|X-XSS|Referrer-Policy|Content-Security'

# Per-site logs
ls -lah /var/log/nginx/status.cluster.local_access.log
ls -lah /var/log/nginx/status.cluster.local_error.log
tail -20 /var/log/nginx/status.cluster.local_error.log

# ============================================================
# 7. DEFAULT SITE REMOVED
# ============================================================
ls /etc/nginx/sites-enabled/default 2>&1
# Expected: "No such file or directory"

# ============================================================
# 8. NGINX GLOBAL CONFIG VALIDATION
# ============================================================
cat /etc/nginx/nginx.conf | grep -E 'worker_processes|worker_connections|keepalive_timeout|gzip|server_tokens'
cat /etc/nginx/conf.d/security.conf | grep -E 'server_tokens|limit_req_zone|client_max_body_size|ssl_protocols'

# Verify server_tokens off
curl -k -s -I https://localhost/ | grep -i server
# Expected: "Server: nginx" (no version number)

# ============================================================
# 9. FAIL2BAN
# ============================================================
systemctl status fail2ban
fail2ban-client status
fail2ban-client status sshd
fail2ban-client status nginx-http-auth
fail2ban-client status nginx-limit-req
fail2ban-client status nginx-botsearch

cat /etc/fail2ban/jail.local | grep -E 'bantime|findtime|maxretry|enabled'
# Expected: bantime=3600, findtime=600, maxretry=3 in [DEFAULT]

# ============================================================
# 10. UFW FIREWALL
# ============================================================
ufw status verbose
# Expected: Status: active
# Expected rules: 22/tcp (ssh) ALLOW, 80/tcp (http) ALLOW, 443/tcp (https) ALLOW
# Expected default: deny (incoming)

ufw status | grep -E '22|80|443|Status|Default'

# ============================================================
# 11. SYSCTL SECURITY PARAMETERS
# ============================================================
cat /etc/sysctl.d/99-security.conf
sysctl net.ipv4.conf.all.rp_filter          # expect: 1
sysctl net.ipv4.conf.all.accept_redirects   # expect: 0
sysctl net.ipv4.conf.all.send_redirects     # expect: 0
sysctl net.ipv4.icmp_echo_ignore_all        # expect: 1
sysctl net.ipv4.tcp_syncookies              # expect: 1
sysctl net.ipv4.tcp_max_syn_backlog         # expect: 2048
sysctl net.ipv6.conf.all.disable_ipv6      # expect: 1

# ============================================================
# 12. SSH HARDENING
# ============================================================
sshd -T | grep -E 'permitrootlogin|passwordauthentication'
# Expected: permitrootlogin no
# Expected: passwordauthentication no

grep -E '^PermitRootLogin|^PasswordAuthentication' /etc/ssh/sshd_config
# Expected: PermitRootLogin no
# Expected: PasswordAuthentication no

# ============================================================
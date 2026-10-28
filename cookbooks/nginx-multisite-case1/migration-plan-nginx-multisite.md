---
source-path: .
---

# Migration Plan: nginx-multisite

**TLDR**: This cookbook configures nginx as a multi-site web server hosting 3 SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) on an Ubuntu/CentOS system. It hardens the host with fail2ban, UFW firewall rules, and kernel-level sysctl security parameters, generates self-signed TLS certificates per site using an SSL passphrase fetched from CyberArk Conjur, and deploys per-site document roots with static `index.html` files. All three sites enforce HTTPS-only access with HTTP→HTTPS redirects, TLS 1.2/1.3, HSTS, and a full set of security response headers.

## Service Type and Instances

**Service Type**: Web Server (nginx multi-site with SSL)

**Configured Instances**:

- **test.cluster.local**: Test environment virtual host
  - Location/Path: `/opt/server/test` (document root)
  - Port/Socket: HTTP 80 (redirect only) → HTTPS 443
  - SSL Certificate: `/etc/ssl/certs/test.cluster.local.crt`
  - SSL Private Key: `/etc/ssl/private/test.cluster.local.key`
  - Static file deployed: `files/default/test/index.html` → `/opt/server/test/index.html`
  - Key Config: `ssl_enabled: true`, HTTP→HTTPS redirect, HSTS, TLS 1.2/1.3

- **ci.cluster.local**: CI environment virtual host
  - Location/Path: `/opt/server/ci` (document root)
  - Port/Socket: HTTP 80 (redirect only) → HTTPS 443
  - SSL Certificate: `/etc/ssl/certs/ci.cluster.local.crt`
  - SSL Private Key: `/etc/ssl/private/ci.cluster.local.key`
  - Static file deployed: `files/default/ci/index.html` → `/opt/server/ci/index.html`
  - Key Config: `ssl_enabled: true`, HTTP→HTTPS redirect, HSTS, TLS 1.2/1.3

- **status.cluster.local**: Status page virtual host
  - Location/Path: `/opt/server/status` (document root)
  - Port/Socket: HTTP 80 (redirect only) → HTTPS 443
  - SSL Certificate: `/etc/ssl/certs/status.cluster.local.crt`
  - SSL Private Key: `/etc/ssl/private/status.cluster.local.key`
  - Static file deployed: `files/default/status/index.html` → `/opt/server/status/index.html`
  - Key Config: `ssl_enabled: true`, HTTP→HTTPS redirect, HSTS, TLS 1.2/1.3

## File Structure

```
cookbooks/nginx-multisite/
├── attributes/
│   └── default.rb
├── files/
│   └── default/
│       ├── ci/
│       │   └── index.html
│       ├── status/
│       │   └── index.html
│       └── test/
│           └── index.html
├── recipes/
│   ├── default.rb
│   ├── nginx.rb
│   ├── security.rb
│   ├── sites.rb
│   └── ssl.rb
├── resources/
│   └── lineinfile.rb
└── templates/
    └── default/
        ├── fail2ban.jail.local.erb
        ├── nginx.conf.erb
        ├── security.conf.erb
        ├── site.conf.erb
        └── sysctl-security.conf.erb
```

## Module Explanation

The cookbook performs operations in this order:

**1. default** (`cookbooks/nginx-multisite/recipes/default.rb`):
- Entry point that includes all four sub-recipes in strict order: security → nginx → ssl → sites
- Resources: include_recipe (4)

---

**2. security** (`cookbooks/nginx-multisite/recipes/security.rb`):
- Installs packages: `fail2ban`, `ufw` (single `package` resource with array)
- Enables and starts the `fail2ban` service
- Deploys fail2ban jail configuration:
  - Template: `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` (mode 0644)
  - Configures jails: `[sshd]`, `[nginx-http-auth]`, `[nginx-limit-req]`, `[nginx-botsearch]`
  - All jails: `bantime=3600`, `findtime=600`, `maxretry=3` (botsearch: maxretry=2, limit-req: maxretry=10)
  - Notifies: `:restart` on `service[fail2ban]` (delayed)
- Configures UFW firewall via 5 `execute` resources (all idempotent with `not_if` guards):
  - `ufw_default_deny`: `ufw --force default deny`
  - `ufw_allow_ssh`: `ufw allow ssh`
  - `ufw_allow_http`: `ufw allow http`
  - `ufw_allow_https`: `ufw allow https`
  - `ufw_enable`: `ufw --force enable`
- Deploys kernel hardening parameters:
  - Template: `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` (mode 0644)
  - Parameters set: IP spoofing protection (`rp_filter=1`), ICMP redirect ignore, source routing disabled, martian logging, ICMP ping ignore (`icmp_echo_ignore_all=1`), IPv6 disabled, TCP SYN cookie protection (`tcp_syncookies=1`, `tcp_max_syn_backlog=2048`)
  - Notifies: `:run` on `execute[reload_sysctl]` (delayed) → runs `sysctl -p /etc/sysctl.d/99-security.conf`
- Hardens SSH via custom `lineinfile` resource (defined in `cookbooks/nginx-multisite/resources/lineinfile.rb`):
  - Conditional: `node['security']['ssh']['disable_root'] == true` (default: true)
    - `lineinfile '/etc/ssh/sshd_config'`: sets `PermitRootLogin no`, matches `^#?PermitRootLogin`, notifies `:restart` on `service[ssh]`
  - Conditional: `node['security']['ssh']['password_auth'] == false` (default: false)
    - `lineinfile '/etc/ssh/sshd_config'`: sets `PasswordAuthentication no`, matches `^#?PasswordAuthentication`, notifies `:restart` on `service[ssh]`
- Declares `service 'ssh'` with `action :nothing` (only triggered by notifications above)
- Resources: package (1, array), service (2: fail2ban + ssh), template (2), execute (6: 5 ufw + 1 sysctl reload), lineinfile (2)

---

**3. nginx** (`cookbooks/nginx-multisite/recipes/nginx.rb`):
- Installs package: `nginx`
- Deploys global nginx configuration:
  - Template: `nginx.conf.erb` → `/etc/nginx/nginx.conf` (mode 0644)
  - Settings: `user www-data`, `worker_processes auto`, `worker_connections 768`, `keepalive_timeout 65`, gzip on, includes `conf.d/*.conf` and `sites-enabled/*`
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Deploys nginx security snippet:
  - Template: `security.conf.erb` → `/etc/nginx/conf.d/security.conf` (mode 0644)
  - Settings: `server_tokens off`, rate limiting zones (`login: 10r/m`, `api: 30r/m`), buffer overflow protections (`client_body_buffer_size 1K`, `client_max_body_size 1k`), timeout settings, global SSL session cache and cipher configuration
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Enables and starts the `nginx` service (supports restart, reload, status)
- Iterations — runs 3 times for sites:
  - **test.cluster.local**:
    - `directory '/opt/server/test'`: owner `www-data`, group `www-data`, mode `0755`, recursive true
    - `cookbook_file '/opt/server/test/index.html'`: source `files/default/test/index.html`, owner `www-data`, group `www-data`, mode `0644`
  - **ci.cluster.local**:
    - `directory '/opt/server/ci'`: owner `www-data`, group `www-data`, mode `0755`, recursive true
    - `cookbook_file '/opt/server/ci/index.html'`: source `files/default/ci/index.html`, owner `www-data`, group `www-data`, mode `0644`
  - **status.cluster.local**:
    - `directory '/opt/server/status'`: owner `www-data`, group `www-data`, mode `0755`, recursive true
    - `cookbook_file '/opt/server/status/index.html'`: source `files/default/status/index.html`, owner `www-data`, group `www-data`, mode `0644`
- Resources: package (1), template (2), service (1), directory (3), cookbook_file (3)

---

**4. ssl** (`cookbooks/nginx-multisite/recipes/ssl.rb`):
- Installs packages: `openssl`, `ca-certificates`
- **Fetches SSL passphrase from CyberArk Conjur** using `conjur_variable('production/nginx/ssl_passphrase')` — runtime call to the Conjur API at `https://conjur.example.com`, account `myorg`
- Creates group `ssl-cert`
- Creates certificate directory `/etc/ssl/certs`: owner `root`, group `root`, mode `0755`
- Creates private key directory `/etc/ssl/private`: owner `root`, group `ssl-cert`, mode `0710`
- Iterations — runs 3 times for sites (all have `ssl_enabled: true`):
  - **test.cluster.local**:
    - `execute 'generate-ssl-cert-test.cluster.local'`: generates self-signed RSA 2048-bit cert valid 365 days
      - Output cert: `/etc/ssl/certs/test.cluster.local.crt`
      - Output key: `/etc/ssl/private/test.cluster.local.key` (chmod 640, chown root:ssl-cert)
      - Subject: `/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=test.cluster.local/emailAddress=admin@example.com`
      - Passphrase: injected from Conjur at runtime; marked `sensitive true`
      - Guard: `not_if { File.exist?(cert) && File.exist?(key) }` — skips if both files already exist
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - `execute 'generate-ssl-cert-ci.cluster.local'`: same parameters, CN=`ci.cluster.local`
      - Output cert: `/etc/ssl/certs/ci.cluster.local.crt`
      - Output key: `/etc/ssl/private/ci.cluster.local.key`
      - Guard: skips if both files already exist
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **status.cluster.local**:
    - `execute 'generate-ssl-cert-status.cluster.local'`: same parameters, CN=`status.cluster.local`
      - Output cert: `/etc/ssl/certs/status.cluster.local.crt`
      - Output key: `/etc/ssl/private/status.cluster.local.key`
      - Guard: skips if both files already exist
      - Notifies: `:reload` on `service[nginx]` (delayed)
- Resources: package (1, array), group (1), directory (2), execute (3)

---

**5. sites** (`cookbooks/nginx-multisite/recipes/sites.rb`):
- Iterations — runs 3 times for sites:
  - **test.cluster.local**:
    - `template '/etc/nginx/sites-available/test.cluster.local'`: source `site.conf.erb`, mode `0644`
      - Variables: `server_name=test.cluster.local`, `document_root=/opt/server/test`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/test.cluster.local.crt`, `key_file=/etc/ssl/private/test.cluster.local.key`
      - Renders: HTTP→HTTPS redirect on port 80, HTTPS server on port 443 with SSL, HSTS header, security headers (X-Frame-Options DENY, X-Content-Type-Options nosniff, X-XSS-Protection, Referrer-Policy, Content-Security-Policy), gzip, access_log `/var/log/nginx/test.cluster.local_access.log`, error_log `/var/log/nginx/test.cluster.local_error.log`
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/test.cluster.local'` → `/etc/nginx/sites-available/test.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - `template '/etc/nginx/sites-available/ci.cluster.local'`: source `site.conf.erb`, mode `0644`
      - Variables: `server_name=ci.cluster.local`, `document_root=/opt/server/ci`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/ci.cluster.local.crt`, `key_file=/etc/ssl/private/ci.cluster.local.key`
      - Renders: HTTP→HTTPS redirect on port 80, HTTPS server on port 443 with SSL, HSTS header, security headers, gzip, access_log `/var/log/nginx/ci.cluster.local_access.log`, error_log `/var/log/nginx/ci.cluster.local_error.log`
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/ci.cluster.local'` → `/etc/nginx/sites-available/ci.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **status.cluster.local**:
    - `template '/etc/nginx/sites-available/status.cluster.local'`: source `site.conf.erb`, mode `0644`
      - Variables: `server_name=status.cluster.local`, `document_root=/opt/server/status`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/status.cluster.local.crt`, `key_file=/etc/ssl/private/status.cluster.local.key`
      - Renders: HTTP→HTTPS redirect on port 80, HTTPS server on port 443 with SSL, HSTS header, security headers, gzip, access_log `/var/log/nginx/status.cluster.local_access.log`, error_log `/var/log/nginx/status.cluster.local_error.log`
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/status.cluster.local'` → `/etc/nginx/sites-available/status.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
- Deletes `/etc/nginx/sites-enabled/default` (removes nginx default site)
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Resources: template (3), link (3), file (1)

## Dependencies

**External cookbook dependencies**:
- `cyberark-conjur ~> 3.0` — provides the `conjur_variable()` helper used in `cookbooks/nginx-multisite/recipes/ssl.rb` to fetch the SSL passphrase at converge time

**System package dependencies**:
- `nginx` — web server
- `fail2ban` — intrusion prevention / log-based banning
- `ufw` — Uncomplicated Firewall (iptables frontend)
- `openssl` — TLS certificate generation
- `ca-certificates` — CA certificate bundle

**Service dependencies** (systemd services managed):
- `nginx` — enabled, started; reloaded on config/site/cert changes
- `fail2ban` — enabled, started; restarted on jail.local changes
- `ssh` (sshd) — restarted only when sshd_config is modified by `lineinfile`

## Credentials

**Detection Summary**: 1 credential detected across 2 files (`cookbooks/nginx-multisite/attributes/default.rb` and `cookbooks/nginx-multisite/recipes/ssl.rb`)

**Source**:
- **Provider**: CyberArk Conjur
- **URL**: `https://conjur.example.com` (configured in `node['cyberark']['conjur']['appliance_url']`)
- **Path**: `production/nginx/ssl_passphrase` (configured in `node['cyberark']['conjur']['variable']`)

### SSL Certificate Passphrase

- **Variable(s)**: `node['cyberark']['conjur']['variable']` → resolves to path `production/nginx/ssl_passphrase`; runtime value stored in local variable `ssl_passphrase` in `cookbooks/nginx-multisite/recipes/ssl.rb`
- **Source file(s)**:
  - `cookbooks/nginx-multisite/attributes/default.rb` — defines Conjur appliance URL, account, and variable path
  - `cookbooks/nginx-multisite/recipes/ssl.rb` — calls `conjur_variable(node['cyberark']['conjur']['variable'])` to retrieve the secret at converge time; injects it as `-passout pass:#{ssl_passphrase}` into the `openssl req` command; the execute resource is marked `sensitive true` to suppress log output
- **Current storage**: CyberArk Conjur vault (accessed via `conjur_variable()` helper from the `cyberark-conjur` cookbook dependency)
- **Usage context**: Used as the PEM passphrase (`-passout`) when generating self-signed RSA 2048-bit TLS certificates for all 3 virtual hosts. The same passphrase is applied to all three `openssl req` executions (test.cluster.local, ci.cluster.local, status.cluster.local). The private key files are written with mode 0640, owned root:ssl-cert.

> **Note for Solutions Architect**: In Ansible/AAP, this credential must be retrieved from CyberArk Conjur (or an equivalent secrets manager) before the certificate generation tasks run. The Conjur account is `myorg`, the variable path is `production/nginx/ssl_passphrase`. The AAP credential type should be configured to call the Conjur API at `https://conjur.example.com` and inject the passphrase as a variable (e.g., `ssl_passphrase`) available to the certificate generation tasks. Do NOT hardcode this value in any Ansible variable file or vault.

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
- `/etc/nginx/sites-enabled/default` — must NOT exist (deleted)

*Document roots and static files:*
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
- `/etc/ssh/sshd_config` (modified lines: `PermitRootLogin no`, `PasswordAuthentication no`)

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
- Ports listening: 80 (HTTP redirect, all 3 sites), 443 (HTTPS, all 3 sites)
- Unix sockets: none
- Network interfaces: all interfaces (nginx listens on `0.0.0.0:80` and `0.0.0.0:443`)

**Templates rendered**:
- `nginx.conf.erb` → `/etc/nginx/nginx.conf` — renders **1 time**
- `security.conf.erb` → `/etc/nginx/conf.d/security.conf` — renders **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/{site_name}` — renders **3 times** (test.cluster.local, ci.cluster.local, status.cluster.local)
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
# 2. NGINX CONFIGURATION VALIDATION
# ============================================================
nginx -t
nginx -T | grep -E 'server_name|listen|ssl_certificate|root'

# Verify global config
cat /etc/nginx/nginx.conf | grep -E 'worker_processes|worker_connections|keepalive_timeout|server_tokens'
cat /etc/nginx/conf.d/security.conf | grep -E 'server_tokens|limit_req_zone|client_max_body_size|ssl_protocols'

# Verify default site is removed
ls -la /etc/nginx/sites-enabled/default 2>&1 | grep -q "No such file" && echo "OK: default site removed" || echo "FAIL: default site still present"

# ============================================================
# 3. VIRTUAL HOST CONFIGURATION - test.cluster.local
# ============================================================
# Config file exists
ls -lah /etc/nginx/sites-available/test.cluster.local
# Symlink active
ls -lah /etc/nginx/sites-enabled/test.cluster.local
readlink /etc/nginx/sites-enabled/test.cluster.local  # should point to sites-available/test.cluster.local

# Document root and index file
ls -lah /opt/server/test/
ls -lah /opt/server/test/index.html
stat /opt/server/test/index.html | grep -E 'Uid|Gid|Access'  # should be www-data:www-data, 0644

# HTTP redirect check (should return 301)
curl -I -H "Host: test.cluster.local" http://localhost/ 2>/dev/null | grep -E 'HTTP|Location'
# Expected: HTTP/1.1 301 Moved Permanently, Location: https://test.cluster.local/

# HTTPS check (self-signed cert, use -k)
curl -k -I -H "Host: test.cluster.local" https://localhost/ 2>/dev/null | grep -E 'HTTP|Strict-Transport|X-Frame|X-Content'
# Expected: HTTP/1.1 200 OK, Strict-Transport-Security header present

# SSL certificate details
openssl s_client -connect localhost:443 -servername test.cluster.local </dev/null 2>/dev/null | openssl x509 -noout -subject -dates -issuer
# Expected: CN=test.cluster.local, validity ~365 days from issue

# Certificate and key file permissions
ls -lah /etc/ssl/certs/test.cluster.local.crt   # should be root:root
ls -lah /etc/ssl/private/test.cluster.local.key  # should be root:ssl-cert, mode 640

# Per-site log files
ls -lah /var/log/nginx/test.cluster.local_access.log
ls -lah /var/log/nginx/test.cluster.local_error.log
tail -5 /var/log/nginx/test.cluster.local_access.log
tail -5 /var/log/nginx/test.cluster.local_error.log

# ============================================================
# 4. VIRTUAL HOST CONFIGURATION - ci.cluster.local
# ============================================================
ls -lah /etc/nginx/sites-available/ci.cluster.local
ls -lah /etc/nginx/sites-enabled/ci.cluster.local
readlink /etc/nginx/sites-enabled/ci.cluster.local  # should point to sites-available/ci.cluster.local

ls -lah /opt/server/ci/
ls -lah /opt/server/ci/index.html
stat /opt/server/ci/index.html | grep -E 'Uid|Gid|Access'  # should be www-data:www-data, 0644

curl -I -H "Host: ci.cluster.local" http://localhost/ 2>/dev/null | grep -E 'HTTP|Location'
# Expected: HTTP/1.1 301 Moved Permanently, Location: https://ci.cluster.local/

curl -k -I -H "Host: ci.cluster.local" https://localhost/ 2>/dev/null | grep -E 'HTTP|Strict-Transport|X-Frame|X-Content'
# Expected: HTTP/1.1 200 OK, Strict-Transport-Security header present

openssl s_client -connect localhost:443 -servername ci.cluster.local </dev/null 2>/dev/null | openssl x509 -noout -subject -dates -issuer
# Expected: CN=ci.cluster.local

ls -lah /etc/ssl/certs/ci.cluster.local.crt
ls -lah /etc/ssl/private/ci.cluster.local.key  # should be root:ssl-cert, mode 640

ls -lah /var/log/nginx/ci.cluster.local_access.log
ls -lah /var/log/nginx/ci.cluster.local_error.log
tail -5 /var/log/nginx/ci.cluster.local_access.log
tail -5 /var/log/nginx/ci.cluster.local_error.log

# ============================================================
# 5. VIRTUAL HOST CONFIGURATION - status.cluster.local
# ============================================================
ls -lah /etc/nginx/sites-available/status.cluster.local
ls -lah /etc/nginx/sites-enabled/status.cluster.local
readlink /etc/nginx/sites-enabled/status.cluster.local  # should point to sites-available/status.cluster.local

ls -lah /opt/server/status/
ls -lah /opt/server/status/index.html
stat /opt/server/status/index.html | grep -E 'Uid|Gid|Access'  # should be www-data:www-data, 0644

curl -I -H "Host: status.cluster.local" http://localhost/ 2>/dev/null | grep -E 'HTTP|Location'
# Expected: HTTP/1.1 301 Moved Permanently, Location: https://status.cluster.local/

curl -k -I -H "Host: status.cluster.local" https://localhost/ 2>/dev/null | grep -E 'HTTP|Strict-Transport|X-Frame|X-Content'
# Expected: HTTP/1.1 200 OK, Strict-Transport-Security header present

openssl s_client -connect localhost:443 -servername status.cluster.local </dev/null 2>/dev/null | openssl x509 -noout -subject -dates -issuer
# Expected: CN=status.cluster.local

ls -lah /etc/ssl/certs/status.cluster.local.crt
ls -lah /etc/ssl/private/status.cluster.local.key  # should be root:ssl-cert, mode 640

ls -lah /var/log/nginx/status.cluster.local_access.log
ls -lah /var/log/nginx/status.cluster.local_error.log
tail -5 /var/log/nginx/status.cluster.local_access.log
tail -5 /var/log/nginx/status.cluster.local_error.log

# ============================================================
# 6. SSL DIRECTORY PERMISSIONS
# ============================================================
stat /etc/ssl/certs | grep -E 'Uid|Gid|Access'   # should be root:root, 0755
stat /etc/ssl/private | grep -E 'Uid|Gid|Access'  # should be root:ssl-cert, 0710
getent group ssl-cert  # group must exist

# ============================================================
# 7. FAIL2BAN CONFIGURATION
# ============================================================
systemctl is-active fail2ban  # should output: active
fail2ban-client status         # should list jails: sshd, nginx-http-auth, nginx-limit-req, nginx-botsearch

fail2ban-client status sshd
fail2ban-client status nginx-http-auth
fail2ban-client status nginx-limit-req
fail2ban-client status nginx-botsearch

cat /etc/fail2ban/jail.local | grep -E 'bantime|findtime|maxretry|enabled'
# Expected: bantime=3600, findtime=600, maxretry=3 (global), all 4 jails enabled=true

# ============================================================
# 8. UFW FIREWALL
# ============================================================
ufw status verbose
# Expected: Status: active
# Expected rules: 22/tcp (ssh) ALLOW, 80/tcp (http) ALLOW, 443/tcp (https) ALLOW
# Expected default: deny (incoming)

ufw status | grep -E '22|80|443|Status|Default'

# ============================================================
# 9. SYSCTL KERNEL HARDENING
# ============================================================
cat /etc/sysctl.d/99-security.conf

sysctl net.ipv4.conf.all.rp_filter           # should be 1
sysctl net.ipv4.conf.all.accept_redirects    # should be 0
sysctl net.ipv4.conf.all.send_redirects      # should be 0
sysctl net.ipv4.conf.all.accept_source_route # should be 0
sysctl net.ipv4.conf.all.log_martians        # should be 1
sysctl net.ipv4.icmp_echo_ignore_all         # should be 1
sysctl net.ipv4.tcp_syncookies               # should be 1
sysctl net.ipv4.tcp_max_syn_backlog          # should be 2048
sysctl net.ipv6.conf.all.disable_ipv6        # should be 1

# ============================================================
# 10. SSH HARDENING
# ============================================================
grep 'PermitRootLogin' /etc/ssh/sshd_config
# Expected: PermitRootLogin no

grep 'PasswordAuthentication' /etc/ssh/sshd_config
# Expected: PasswordAuthentication no

sshd -t  # SSH config syntax check — should return no errors

# ============================================================
# 11. NETWORK PORTS
#
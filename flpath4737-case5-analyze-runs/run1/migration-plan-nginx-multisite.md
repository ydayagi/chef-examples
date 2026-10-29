---
source-path: .
---

# Migration Plan: nginx-multisite

**TLDR**: This cookbook configures an Nginx web server hosting three SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) on a single node. It hardens the host with fail2ban, UFW firewall rules, and kernel-level sysctl security parameters, then generates self-signed TLS certificates for each site using a passphrase retrieved from CyberArk Conjur. Each site gets its own document root, static `index.html`, and a per-site Nginx server block that enforces HTTP→HTTPS redirect, TLS 1.2/1.3, HSTS, and a full set of security response headers. SSH hardening (no root login, no password auth) is applied via a custom in-place file-edit resource (`ada_ada`). Two additional custom resources (`fetch_token`, `fetch_and_parse_token`) perform OAuth/token-fetch operations during the Chef run.

---

## Service Type and Instances

**Service Type**: Web Server (Nginx multi-site with TLS)

**Configured Instances**:

- **test.cluster.local**: Static-file virtual host
  - Document Root: `/opt/server/test`
  - Port/Socket: 80 (HTTP→HTTPS redirect), 443 (HTTPS/TLS)
  - SSL: enabled — certificate `/etc/ssl/certs/test.cluster.local.crt`, key `/etc/ssl/private/test.cluster.local.key`
  - Static file deployed: `files/default/test/index.html` → `/opt/server/test/index.html`
  - Key Config: TLS 1.2/1.3, HSTS, X-Frame-Options DENY, CSP, gzip

- **ci.cluster.local**: Static-file virtual host
  - Document Root: `/opt/server/ci`
  - Port/Socket: 80 (HTTP→HTTPS redirect), 443 (HTTPS/TLS)
  - SSL: enabled — certificate `/etc/ssl/certs/ci.cluster.local.crt`, key `/etc/ssl/private/ci.cluster.local.key`
  - Static file deployed: `files/default/ci/index.html` → `/opt/server/ci/index.html`
  - Key Config: TLS 1.2/1.3, HSTS, X-Frame-Options DENY, CSP, gzip

- **status.cluster.local**: Static-file virtual host
  - Document Root: `/opt/server/status`
  - Port/Socket: 80 (HTTP→HTTPS redirect), 443 (HTTPS/TLS)
  - SSL: enabled — certificate `/etc/ssl/certs/status.cluster.local.crt`, key `/etc/ssl/private/status.cluster.local.key`
  - Static file deployed: `files/default/status/index.html` → `/opt/server/status/index.html`
  - Key Config: TLS 1.2/1.3, HSTS, X-Frame-Options DENY, CSP, gzip

---

## File Structure

```
nginx-multisite/
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
│   ├── ada_ada.rb
│   ├── fetch_and_parse_token.rb
│   └── fetch_token.rb
└── templates/
    └── default/
        ├── fail2ban.jail.local.erb
        ├── nginx.conf.erb
        ├── security.conf.erb
        ├── site.conf.erb
        └── sysctl-security.conf.erb
```

---

## Module Explanation

The cookbook performs operations in this order:

**1. default** (`cookbooks/nginx-multisite/recipes/default.rb`):
- Entry point — includes four recipes in strict order: `security`, `nginx`, `ssl`, `sites`.
- Resources: `include_recipe` (4)

---

**2. security** (`cookbooks/nginx-multisite/recipes/security.rb`):
- Installs packages: `fail2ban`, `ufw` (array install in a single `package` resource).
- Enables and starts the `fail2ban` service.
- Deploys `/etc/fail2ban/jail.local` from `cookbooks/nginx-multisite/templates/default/fail2ban.jail.local.erb` (mode 0644); notifies `fail2ban` restart on change.
  - Template configures five jails: `[DEFAULT]` (bantime=3600, findtime=600, maxretry=3), `[sshd]` (logpath=/var/log/auth.log), `[nginx-http-auth]` (logpath=/var/log/nginx/*error.log), `[nginx-limit-req]` (logpath=/var/log/nginx/*error.log, maxretry=10), `[nginx-botsearch]` (logpath=/var/log/nginx/*access.log, maxretry=2).
- Configures UFW firewall via five idempotent `execute` resources (each guarded by `not_if`):
  - `ufw_default_deny`: `ufw --force default deny` (skipped if already "Default: deny")
  - `ufw_allow_ssh`: `ufw allow ssh` (skipped if 22/tcp already present)
  - `ufw_allow_http`: `ufw allow http` (skipped if 80/tcp already present)
  - `ufw_allow_https`: `ufw allow https` (skipped if 443/tcp already present)
  - `ufw_enable`: `ufw --force enable` (skipped if "Status: active")
- Uses custom resource `fetch_token['get auth token']`:
  - Calls `https://auth.example.com/oauth/token` via HTTP POST with `client_id=nginx-multisite` and `client_secret=sup3rs3cr3t` (hardcoded).
  - Stores the returned `access_token` in `node.run_state['access_token']`.
  - Provider: `cookbooks/nginx-multisite/resources/fetch_token.rb`
- Uses custom resource `fetch_and_parse_token['get parsed token']`:
  - Calls `https://api.example.com/token_endpoint` via HTTP GET.
  - Parses the response body for a line matching `X-Header:<value>` and stores the captured value in `node.run_state['extracted_token']`.
  - Provider: `cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb`
- Deploys `/etc/sysctl.d/99-security.conf` from `cookbooks/nginx-multisite/templates/default/sysctl-security.conf.erb` (mode 0644); notifies `execute[reload_sysctl]` on change.
  - Template sets: IP spoofing protection (`rp_filter=1`), ICMP redirect ignore, send-redirect disable, source-route disable, martian logging, ICMP echo ignore, TCP SYN-cookie flood protection (`tcp_syncookies=1`, `tcp_max_syn_backlog=2048`), IPv6 disabled.
- `execute[reload_sysctl]`: `sysctl -p /etc/sysctl.d/99-security.conf` — action `:nothing`, triggered only by template change notification.
- Conditionally (because `node['security']['ssh']['disable_root']` = `true`) uses custom resource `ada_ada['/etc/ssh/sshd_config']`:
  - Finds lines matching `^#\?PermitRootLogin` and replaces with `PermitRootLogin no`; appends if not found.
  - Creates a timestamped `.backup.<epoch>` file before modifying.
  - Notifies `service[ssh]` restart.
  - Provider: `cookbooks/nginx-multisite/resources/ada_ada.rb`
- Conditionally (because `node['security']['ssh']['password_auth']` = `false`) uses custom resource `ada_ada['/etc/ssh/sshd_config']` again:
  - Finds lines matching `^#\?PasswordAuthentication` and replaces with `PasswordAuthentication no`.
  - Notifies `service[ssh]` restart.
  - Provider: `cookbooks/nginx-multisite/resources/ada_ada.rb`
- `service[ssh]`: action `:nothing` — triggered only by `ada_ada` notifications above.
- Resources: `package` (1, array), `service` (1 fail2ban), `template` (2), `execute` (6), `fetch_token` (1, custom), `fetch_and_parse_token` (1, custom), `ada_ada` (2, custom), `service` (1 ssh)

---

**3. nginx** (`cookbooks/nginx-multisite/recipes/nginx.rb`):
- Installs package `nginx`.
- Deploys `/etc/nginx/nginx.conf` from `cookbooks/nginx-multisite/templates/default/nginx.conf.erb` (mode 0644); notifies nginx reload on change.
  - Template sets: `user www-data`, `worker_processes auto`, `worker_connections 768`, sendfile/tcp_nopush/tcp_nodelay on, `keepalive_timeout 65`, gzip on, includes `conf.d/*.conf` and `sites-enabled/*`.
- Deploys `/etc/nginx/conf.d/security.conf` from `cookbooks/nginx-multisite/templates/default/security.conf.erb` (mode 0644); notifies nginx reload on change.
  - Template sets: `server_tokens off`, rate-limit zones (`login` 10r/m, `api` 30r/m), buffer limits (client_body 1K, client_header 1k, client_max_body 1k, large_client_header_buffers 2 1k), timeouts (body/header/send = 10s), global SSL settings (TLS 1.2/1.3, cipher suite, session cache 10m, session timeout 10m).
- Enables and starts the `nginx` service.
- Iterations: Runs **3 times** for sites — **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - Creates directory `/opt/server/test` (owner: www-data, group: www-data, mode 0755, recursive).
    - Deploys `cookbooks/nginx-multisite/files/default/test/index.html` → `/opt/server/test/index.html` (owner: www-data, group: www-data, mode 0644) via `cookbook_file`.
  - **ci.cluster.local**:
    - Creates directory `/opt/server/ci` (owner: www-data, group: www-data, mode 0755, recursive).
    - Deploys `cookbooks/nginx-multisite/files/default/ci/index.html` → `/opt/server/ci/index.html` (owner: www-data, group: www-data, mode 0644) via `cookbook_file`.
  - **status.cluster.local**:
    - Creates directory `/opt/server/status` (owner: www-data, group: www-data, mode 0755, recursive).
    - Deploys `cookbooks/nginx-multisite/files/default/status/index.html` → `/opt/server/status/index.html` (owner: www-data, group: www-data, mode 0644) via `cookbook_file`.
- Resources: `package` (1), `template` (2), `service` (1), `directory` (3), `cookbook_file` (3)

---

**4. ssl** (`cookbooks/nginx-multisite/recipes/ssl.rb`):
- Installs packages: `openssl`, `ca-certificates`.
- Fetches SSL passphrase from CyberArk Conjur using `conjur_variable(node['cyberark']['conjur']['variable'])` — variable path: `production/nginx/ssl_passphrase`, Conjur URL: `https://conjur.example.com`, account: `myorg`. The passphrase is stored in the local Ruby variable `ssl_passphrase` and used inline in `openssl` commands.
- Creates group `ssl-cert`.
- Creates directory `/etc/ssl/certs` (owner: root, group: root, mode 0755).
- Creates directory `/etc/ssl/private` (owner: root, group: ssl-cert, mode 0710).
- Iterations: Runs **3 times** for SSL-enabled sites — **test.cluster.local**, **ci.cluster.local**, **status.cluster.local** (all three have `ssl_enabled: true`):
  - **test.cluster.local**:
    - `execute[generate-ssl-cert-test.cluster.local]`: Runs `openssl req -x509 -days 365 -newkey rsa:2048` generating `/etc/ssl/certs/test.cluster.local.crt` and `/etc/ssl/private/test.cluster.local.key`. Subject: `/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=test.cluster.local/emailAddress=admin@example.com`. Sets key permissions to 640, owner root:ssl-cert. Marked `sensitive true`. Guarded by `not_if { File.exist?(cert) && File.exist?(key) }`. Notifies nginx reload.
  - **ci.cluster.local**:
    - `execute[generate-ssl-cert-ci.cluster.local]`: Same openssl command for `/etc/ssl/certs/ci.cluster.local.crt` and `/etc/ssl/private/ci.cluster.local.key`. Subject with `CN=ci.cluster.local`. Guarded, sensitive, notifies nginx reload.
  - **status.cluster.local**:
    - `execute[generate-ssl-cert-status.cluster.local]`: Same openssl command for `/etc/ssl/certs/status.cluster.local.crt` and `/etc/ssl/private/status.cluster.local.key`. Subject with `CN=status.cluster.local`. Guarded, sensitive, notifies nginx reload.
- Resources: `package` (1, array), `group` (1), `directory` (2), `execute` (3)

---

**5. sites** (`cookbooks/nginx-multisite/recipes/sites.rb`):
- Iterations: Runs **3 times** for sites — **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - Deploys `/etc/nginx/sites-available/test.cluster.local` from `cookbooks/nginx-multisite/templates/default/site.conf.erb` (mode 0644) with variables: `server_name=test.cluster.local`, `document_root=/opt/server/test`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/test.cluster.local.crt`, `key_file=/etc/ssl/private/test.cluster.local.key`. Notifies nginx reload.
    - Template renders two `server {}` blocks: port 80 (HTTP→HTTPS 301 redirect) and port 443 (SSL, TLS 1.2/1.3, HSTS, security headers, gzip, location blocks, per-site access/error logs at `/var/log/nginx/test.cluster.local_access.log` and `/var/log/nginx/test.cluster.local_error.log`).
    - Creates symlink `/etc/nginx/sites-enabled/test.cluster.local` → `/etc/nginx/sites-available/test.cluster.local`. Notifies nginx reload.
  - **ci.cluster.local**:
    - Deploys `/etc/nginx/sites-available/ci.cluster.local` from `cookbooks/nginx-multisite/templates/default/site.conf.erb` (mode 0644) with variables: `server_name=ci.cluster.local`, `document_root=/opt/server/ci`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/ci.cluster.local.crt`, `key_file=/etc/ssl/private/ci.cluster.local.key`. Notifies nginx reload.
    - Template renders HTTP redirect block and HTTPS block with per-site logs at `/var/log/nginx/ci.cluster.local_access.log` and `/var/log/nginx/ci.cluster.local_error.log`.
    - Creates symlink `/etc/nginx/sites-enabled/ci.cluster.local` → `/etc/nginx/sites-available/ci.cluster.local`. Notifies nginx reload.
  - **status.cluster.local**:
    - Deploys `/etc/nginx/sites-available/status.cluster.local` from `cookbooks/nginx-multisite/templates/default/site.conf.erb` (mode 0644) with variables: `server_name=status.cluster.local`, `document_root=/opt/server/status`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/status.cluster.local.crt`, `key_file=/etc/ssl/private/status.cluster.local.key`. Notifies nginx reload.
    - Template renders HTTP redirect block and HTTPS block with per-site logs at `/var/log/nginx/status.cluster.local_access.log` and `/var/log/nginx/status.cluster.local_error.log`.
    - Creates symlink `/etc/nginx/sites-enabled/status.cluster.local` → `/etc/nginx/sites-available/status.cluster.local`. Notifies nginx reload.
- Deletes `/etc/nginx/sites-enabled/default` (removes the default Nginx placeholder site). Notifies nginx reload.
- Resources: `template` (3), `link` (3), `file` (1)

---

## Dependencies

**External cookbook dependencies**: `cyberark-conjur ~> 3.0` (provides the `conjur_variable()` helper used in `cookbooks/nginx-multisite/recipes/ssl.rb`)

**System package dependencies**:
- `nginx` (web server)
- `fail2ban` (intrusion prevention)
- `ufw` (firewall)
- `openssl` (TLS certificate generation)
- `ca-certificates` (CA bundle)

**Service dependencies**:
- `nginx` — enabled, started, reloaded on config/cert/site changes
- `fail2ban` — enabled, started, restarted on jail config changes
- `ssh` — restarted on sshd_config changes (triggered only by `ada_ada` notifications)

---

## Credentials

**Detection Summary**: 3 credentials detected across 3 files.

**Source**:
- **Provider**: CyberArk Conjur (for SSL passphrase); Hardcoded (for OAuth client secret)
- **URL**: `https://conjur.example.com` (from `cookbooks/nginx-multisite/attributes/default.rb`)
- **Path**: `production/nginx/ssl_passphrase` (from `cookbooks/nginx-multisite/attributes/default.rb`)

### SSL Certificate Passphrase

- **Variable(s)**: `ssl_passphrase` (local Ruby variable), `node['cyberark']['conjur']['variable']` = `'production/nginx/ssl_passphrase'`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/ssl.rb`, `cookbooks/nginx-multisite/attributes/default.rb`
- **Current storage**: CyberArk Conjur — fetched at converge time via `conjur_variable()` helper from the `cyberark-conjur` cookbook dependency
- **Usage context**: Passed as `-passout pass:<value>` to `openssl req` when generating self-signed certificates for all three sites. Marked `sensitive true` on the execute resource to suppress log output.

### OAuth Client Secret (fetch_token)

- **Variable(s)**: `client_secret` property on `fetch_token` resource, hardcoded value `'sup3rs3cr3t'`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb`
- **Current storage**: Hardcoded plaintext in recipe source code
- **Usage context**: Sent as the `client_secret` field in a JSON POST body to `https://auth.example.com/oauth/token` to obtain an OAuth access token. The returned `access_token` is stored in `node.run_state['access_token']` for potential downstream use within the same Chef run.

### Parsed Token (fetch_and_parse_token)

- **Variable(s)**: `extracted_token` property on `fetch_and_parse_token` resource; `node.run_state['extracted_token']`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb`, `cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb`
- **Current storage**: Retrieved at runtime from `https://api.example.com/token_endpoint` by parsing an `X-Header:<value>` line in the HTTP response body. No credential is stored statically, but the endpoint URL is hardcoded in the recipe.
- **Usage context**: The parsed token value is stored in `node.run_state['extracted_token']`. Its downstream consumer is not visible in this cookbook's source — it may be consumed by a wrapper cookbook or role.

---

## Checks for the Migration

**Files to verify**:
- `/etc/nginx/nginx.conf`
- `/etc/nginx/conf.d/security.conf`
- `/etc/nginx/sites-available/test.cluster.local`
- `/etc/nginx/sites-available/ci.cluster.local`
- `/etc/nginx/sites-available/status.cluster.local`
- `/etc/nginx/sites-enabled/test.cluster.local` (symlink)
- `/etc/nginx/sites-enabled/ci.cluster.local` (symlink)
- `/etc/nginx/sites-enabled/status.cluster.local` (symlink)
- `/etc/nginx/sites-enabled/default` (must NOT exist)
- `/etc/fail2ban/jail.local`
- `/etc/sysctl.d/99-security.conf`
- `/etc/ssh/sshd_config`
- `/etc/ssl/certs/test.cluster.local.crt`
- `/etc/ssl/private/test.cluster.local.key`
- `/etc/ssl/certs/ci.cluster.local.crt`
- `/etc/ssl/private/ci.cluster.local.key`
- `/etc/ssl/certs/status.cluster.local.crt`
- `/etc/ssl/private/status.cluster.local.key`
- `/opt/server/test/index.html`
- `/opt/server/ci/index.html`
- `/opt/server/status/index.html`
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
- `nginx.conf.erb` → `/etc/nginx/nginx.conf` — rendered **1 time**
- `security.conf.erb` → `/etc/nginx/conf.d/security.conf` — rendered **1 time**
- `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` — rendered **1 time**
- `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` — rendered **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/<site_name>` — rendered **3 times**: test.cluster.local, ci.cluster.local, status.cluster.local

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
# 4. SITE: test.cluster.local
# ============================================================
# HTTP redirect check (should return 301)
curl -I -H "Host: test.cluster.local" http://localhost/
# Expected: HTTP/1.1 301 Moved Permanently

# HTTPS check (self-signed cert, use -k)
curl -k -I -H "Host: test.cluster.local" https://localhost/
# Expected: HTTP/1.1 200 OK

# Security headers present
curl -k -s -I -H "Host: test.cluster.local" https://localhost/ | grep -E 'Strict-Transport|X-Frame|X-Content-Type|X-XSS|Referrer-Policy|Content-Security'
# Expected: all 5 headers present

# Document root and static file
ls -lah /opt/server/test/index.html
stat -c "%U %G %a" /opt/server/test/index.html
# Expected: www-data www-data 644

# Site config deployed and symlinked
ls -lah /etc/nginx/sites-available/test.cluster.local
ls -lah /etc/nginx/sites-enabled/test.cluster.local
readlink /etc/nginx/sites-enabled/test.cluster.local
# Expected: -> /etc/nginx/sites-available/test.cluster.local

# Per-site logs exist
ls -lah /var/log/nginx/test.cluster.local_access.log
ls -lah /var/log/nginx/test.cluster.local_error.log
tail -5 /var/log/nginx/test.cluster.local_error.log

# TLS certificate details
openssl x509 -in /etc/ssl/certs/test.cluster.local.crt -noout -subject -dates -issuer
# Expected: CN=test.cluster.local, not expired
stat -c "%U %G %a" /etc/ssl/private/test.cluster.local.key
# Expected: root ssl-cert 640

# ============================================================
# 5. SITE: ci.cluster.local
# ============================================================
# HTTP redirect check (should return 301)
curl -I -H "Host: ci.cluster.local" http://localhost/
# Expected: HTTP/1.1 301 Moved Permanently

# HTTPS check (self-signed cert, use -k)
curl -k -I -H "Host: ci.cluster.local" https://localhost/
# Expected: HTTP/1.1 200 OK

# Security headers present
curl -k -s -I -H "Host: ci.cluster.local" https://localhost/ | grep -E 'Strict-Transport|X-Frame|X-Content-Type|X-XSS|Referrer-Policy|Content-Security'
# Expected: all 5 headers present

# Document root and static file
ls -lah /opt/server/ci/index.html
stat -c "%U %G %a" /opt/server/ci/index.html
# Expected: www-data www-data 644

# Site config deployed and symlinked
ls -lah /etc/nginx/sites-available/ci.cluster.local
ls -lah /etc/nginx/sites-enabled/ci.cluster.local
readlink /etc/nginx/sites-enabled/ci.cluster.local
# Expected: -> /etc/nginx/sites-available/ci.cluster.local

# Per-site logs exist
ls -lah /var/log/nginx/ci.cluster.local_access.log
ls -lah /var/log/nginx/ci.cluster.local_error.log
tail -5 /var/log/nginx/ci.cluster.local_error.log

# TLS certificate details
openssl x509 -in /etc/ssl/certs/ci.cluster.local.crt -noout -subject -dates -issuer
# Expected: CN=ci.cluster.local, not expired
stat -c "%U %G %a" /etc/ssl/private/ci.cluster.local.key
# Expected: root ssl-cert 640

# ============================================================
# 6. SITE: status.cluster.local
# ============================================================
# HTTP redirect check (should return 301)
curl -I -H "Host: status.cluster.local" http://localhost/
# Expected: HTTP/1.1 301 Moved Permanently

# HTTPS check (self-signed cert, use -k)
curl -k -I -H "Host: status.cluster.local" https://localhost/
# Expected: HTTP/1.1 200 OK

# Security headers present
curl -k -s -I -H "Host: status.cluster.local" https://localhost/ | grep -E 'Strict-Transport|X-Frame|X-Content-Type|X-XSS|Referrer-Policy|Content-Security'
# Expected: all 5 headers present

# Document root and static file
ls -lah /opt/server/status/index.html
stat -c "%U %G %a" /opt/server/status/index.html
# Expected: www-data www-data 644

# Site config deployed and symlinked
ls -lah /etc/nginx/sites-available/status.cluster.local
ls -lah /etc/nginx/sites-enabled/status.cluster.local
readlink /etc/nginx/sites-enabled/status.cluster.local
# Expected: -> /etc/nginx/sites-available/status.cluster.local

# Per-site logs exist
ls -lah /var/log/nginx/status.cluster.local_access.log
ls -lah /var/log/nginx/status.cluster.local_error.log
tail -5 /var/log/nginx/status.cluster.local_error.log

# TLS certificate details
openssl x509 -in /etc/ssl/certs/status.cluster.local.crt -noout -subject -dates -issuer
# Expected: CN=status.cluster.local, not expired
stat -c "%U %G %a" /etc/ssl/private/status.cluster.local.key
# Expected: root ssl-cert 640

# ============================================================
# 7. FIREWALL (UFW)
# ============================================================
ufw status verbose
# Expected: Status: active, rules for 22/tcp, 80/tcp, 443/tcp, default deny

# ============================================================
# 8. FAIL2BAN
# ============================================================
fail2ban-client status
fail2ban-client status sshd
fail2ban-client status nginx-http-auth
fail2ban-client status nginx-limit-req
fail2ban-client status nginx-botsearch
cat /etc/fail2ban/jail.local

# ============================================================
# 9. SYSCTL SECURITY PARAMETERS
# ============================================================
sysctl net.ipv4.conf.all.rp_filter
# Expected: 1
sysctl net.ipv4.tcp_syncookies
# Expected: 1
sysctl net.ipv6.conf.all.disable_ipv6
# Expected: 1
cat /etc/sysctl.d/99-security.conf

# ============================================================
# 10. SSH HARDENING
# ============================================================
grep -E '^PermitRootLogin' /etc/ssh/sshd_config
# Expected: PermitRootLogin no
grep -E '^PasswordAuthentication' /etc/ssh/sshd_config
# Expected: PasswordAuthentication no
sshd -T | grep -E 'permitrootlogin|passwordauthentication'

# ============================================================
# 11. DEFAULT NGINX SITE REMOVED
# ============================================================
ls /etc/nginx/sites-enabled/default 2>&1
# Expected: No such file or directory

# ============================================================
# 12. SSL DIRECTORY PERMISSIONS
# ============================================================
stat -c "%U %G %a" /etc/ssl/certs
# Expected: root root 755
stat -c "%U %G %a" /etc/ssl/private
# Expected: root ssl-cert 710
getent group ssl-cert
# Expected: ssl-cert group exists
```
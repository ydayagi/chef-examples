---
source-path: .
---

# Migration Plan: nginx-multisite

**TLDR**: This cookbook installs and configures nginx as a multi-site web server hosting 3 SSL-enabled virtual hosts — `test.cluster.local`, `ci.cluster.local`, and `status.cluster.local` — each with its own document root, self-signed TLS certificate, and static `index.html`. It also hardens the host by configuring fail2ban (with nginx-aware jails), UFW firewall rules (deny-by-default, allow SSH/HTTP/HTTPS), kernel-level sysctl security parameters, and SSH hardening (no root login, no password auth). SSL passphrases are retrieved from CyberArk Conjur. Two custom token-fetching resources (`fetch_token`, `fetch_and_parse_token`) are invoked during the security recipe, with `fetch_token` containing a hardcoded `client_secret`.

---

## Service Type and Instances

**Service Type**: Web Server (nginx) with Host Security Hardening

**Configured Instances**:

- **test.cluster.local**: nginx virtual host for the test environment
  - Location/Path: `/opt/server/test` (document root)
  - Port/Socket: HTTP 80 (redirects to HTTPS), HTTPS 443
  - SSL: Enabled — certificate: `/etc/ssl/certs/test.cluster.local.crt`, key: `/etc/ssl/private/test.cluster.local.key`
  - Static file deployed: `files/default/test/index.html` → `/opt/server/test/index.html`
  - Nginx config: `/etc/nginx/sites-available/test.cluster.local` (symlinked to `sites-enabled`)
  - Key Config: TLSv1.2/TLSv1.3 only, HSTS enabled, security headers (X-Frame-Options DENY, X-Content-Type-Options, X-XSS-Protection, CSP), gzip on
  - Logs: `/var/log/nginx/test.cluster.local_access.log`, `/var/log/nginx/test.cluster.local_error.log`

- **ci.cluster.local**: nginx virtual host for the CI environment
  - Location/Path: `/opt/server/ci` (document root)
  - Port/Socket: HTTP 80 (redirects to HTTPS), HTTPS 443
  - SSL: Enabled — certificate: `/etc/ssl/certs/ci.cluster.local.crt`, key: `/etc/ssl/private/ci.cluster.local.key`
  - Static file deployed: `files/default/ci/index.html` → `/opt/server/ci/index.html`
  - Nginx config: `/etc/nginx/sites-available/ci.cluster.local` (symlinked to `sites-enabled`)
  - Key Config: TLSv1.2/TLSv1.3 only, HSTS enabled, security headers, gzip on
  - Logs: `/var/log/nginx/ci.cluster.local_access.log`, `/var/log/nginx/ci.cluster.local_error.log`

- **status.cluster.local**: nginx virtual host for the status page
  - Location/Path: `/opt/server/status` (document root)
  - Port/Socket: HTTP 80 (redirects to HTTPS), HTTPS 443
  - SSL: Enabled — certificate: `/etc/ssl/certs/status.cluster.local.crt`, key: `/etc/ssl/private/status.cluster.local.key`
  - Static file deployed: `files/default/status/index.html` → `/opt/server/status/index.html`
  - Nginx config: `/etc/nginx/sites-available/status.cluster.local` (symlinked to `sites-enabled`)
  - Key Config: TLSv1.2/TLSv1.3 only, HSTS enabled, security headers, gzip on
  - Logs: `/var/log/nginx/status.cluster.local_access.log`, `/var/log/nginx/status.cluster.local_error.log`

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
- Entry point. Includes four recipes in strict order: `security`, `nginx`, `ssl`, `sites`.
- Resources: `include_recipe` (4)

---

**2. security** (`cookbooks/nginx-multisite/recipes/security.rb`):
- Installs packages: `fail2ban`, `ufw` (installed together as a package array)
- Enables and starts the `fail2ban` service
- Deploys fail2ban jail configuration:
  - Template: `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` (mode 0644)
  - Jail config: DEFAULT bantime=3600s, findtime=600s, maxretry=3, backend=auto
  - Jails enabled: `[sshd]` (port=ssh, logpath=/var/log/auth.log), `[nginx-http-auth]` (port=http,https, logpath=/var/log/nginx/*error.log), `[nginx-limit-req]` (port=http,https, maxretry=10), `[nginx-botsearch]` (port=http,https, logpath=/var/log/nginx/*access.log, maxretry=2)
  - Notifies: restart `service[fail2ban]` (delayed)
- Configures UFW firewall (each execute has a `not_if` guard to be idempotent):
  - `ufw_default_deny`: runs `ufw --force default deny`
  - `ufw_allow_ssh`: runs `ufw allow ssh`
  - `ufw_allow_http`: runs `ufw allow http`
  - `ufw_allow_https`: runs `ufw allow https`
  - `ufw_enable`: runs `ufw --force enable`
- Invokes custom resource `fetch_token['get auth token']`:
  - Provider: `cookbooks/nginx-multisite/resources/fetch_token.rb`
  - POSTs to `https://auth.example.com/oauth/token` with `client_id=nginx-multisite` and **hardcoded** `client_secret=sup3rs3cr3t`
  - Stores retrieved `access_token` in `node.run_state['access_token']`
- Invokes custom resource `fetch_and_parse_token['get parsed token']`:
  - Provider: `cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb`
  - GETs `https://api.example.com/token_endpoint`, parses response body for pattern `pattern1:(.+)`, stores result in `node.run_state['extracted_token']`
- Deploys kernel sysctl hardening:
  - Template: `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` (mode 0644)
  - Settings: IP spoofing protection (rp_filter=1), ICMP redirect ignore, source routing disabled, martian logging, ICMP ping ignore (icmp_echo_ignore_all=1), TCP SYN flood protection (syncookies=1, max_syn_backlog=2048), IPv6 disabled
  - Notifies: run `execute[reload_sysctl]` (delayed) → runs `sysctl -p /etc/sysctl.d/99-security.conf`
- Conditionally hardens SSH using custom resource `ada_ada` (line-in-file style editor):
  - Provider: `cookbooks/nginx-multisite/resources/ada_ada.rb`
  - Condition 1: `node['security']['ssh']['disable_root']` is `true` (default: true) → sets `PermitRootLogin no` in `/etc/ssh/sshd_config` (matches `^#?PermitRootLogin`), notifies restart `service[ssh]`
  - Condition 2: `node['security']['ssh']['password_auth']` is `false` (default: false) → sets `PasswordAuthentication no` in `/etc/ssh/sshd_config` (matches `^#?PasswordAuthentication`), notifies restart `service[ssh]`
  - `service[ssh]` is defined with `action :nothing` (only restarts when notified)
- Resources: `package` (1, array of 2), `service` (1 fail2ban), `template` (1 fail2ban), `execute` (5 ufw + 1 sysctl reload), `fetch_token` (1), `fetch_and_parse_token` (1), `template` (1 sysctl), `ada_ada` (2 conditional), `service` (1 ssh)

---

**3. nginx** (`cookbooks/nginx-multisite/recipes/nginx.rb`):
- Installs package: `nginx`
- Deploys global nginx configuration:
  - Template: `nginx.conf.erb` → `/etc/nginx/nginx.conf` (mode 0644)
  - Config: user=www-data, worker_processes=auto, worker_connections=768, sendfile/tcp_nopush/tcp_nodelay on, keepalive_timeout=65, gzip on, access_log=/var/log/nginx/access.log, error_log=/var/log/nginx/error.log
  - Includes: `/etc/nginx/conf.d/*.conf` and `/etc/nginx/sites-enabled/*`
  - Notifies: reload `service[nginx]` (delayed)
- Deploys nginx security snippet:
  - Template: `security.conf.erb` → `/etc/nginx/conf.d/security.conf` (mode 0644)
  - Config: server_tokens off, rate limiting zones (login: 10r/m, api: 30r/m), client buffer limits (body=1K, header=1K, max_body=1K), timeouts (body/header/send=10s), global SSL settings (TLSv1.2/TLSv1.3, session cache 10m)
  - Notifies: reload `service[nginx]` (delayed)
- Enables and starts `service[nginx]`
- Iterations: Runs 3 times for sites — **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - Creates directory `/opt/server/test` (owner=www-data, group=www-data, mode=0755, recursive=true)
    - Deploys `cookbook_file`: `files/default/test/index.html` → `/opt/server/test/index.html` (owner=www-data, group=www-data, mode=0644)
  - **ci.cluster.local**:
    - Creates directory `/opt/server/ci` (owner=www-data, group=www-data, mode=0755, recursive=true)
    - Deploys `cookbook_file`: `files/default/ci/index.html` → `/opt/server/ci/index.html` (owner=www-data, group=www-data, mode=0644)
  - **status.cluster.local**:
    - Creates directory `/opt/server/status` (owner=www-data, group=www-data, mode=0755, recursive=true)
    - Deploys `cookbook_file`: `files/default/status/index.html` → `/opt/server/status/index.html` (owner=www-data, group=www-data, mode=0644)
- Resources: `package` (1), `template` (2), `service` (1), `directory` (3), `cookbook_file` (3)

---

**4. ssl** (`cookbooks/nginx-multisite/recipes/ssl.rb`):
- Installs packages: `openssl`, `ca-certificates`
- Fetches SSL passphrase from CyberArk Conjur at runtime: `conjur_variable('production/nginx/ssl_passphrase')` using the `cyberark-conjur` cookbook dependency (appliance_url=`https://conjur.example.com`, account=`myorg`)
- Creates group `ssl-cert`
- Creates certificate directory `/etc/ssl/certs` (owner=root, group=root, mode=0755)
- Creates private key directory `/etc/ssl/private` (owner=root, group=ssl-cert, mode=0710)
- Iterations: Runs 3 times for sites where `ssl_enabled=true` — **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - Executes `generate-ssl-cert-test.cluster.local` (guarded: `not_if { File.exist?('/etc/ssl/certs/test.cluster.local.crt') && File.exist?('/etc/ssl/private/test.cluster.local.key') }`)
    - Command: `openssl req -x509 -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/test.cluster.local.key -out /etc/ssl/certs/test.cluster.local.crt -passout pass:<conjur_passphrase> -subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=test.cluster.local/emailAddress=admin@example.com"` then `chmod 640 /etc/ssl/private/test.cluster.local.key` and `chown root:ssl-cert /etc/ssl/private/test.cluster.local.key`
    - Marked `sensitive true`; notifies reload `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - Executes `generate-ssl-cert-ci.cluster.local` (same guard pattern)
    - Command: same openssl command with CN=ci.cluster.local, outputs to `/etc/ssl/certs/ci.cluster.local.crt` and `/etc/ssl/private/ci.cluster.local.key`
    - Marked `sensitive true`; notifies reload `service[nginx]` (delayed)
  - **status.cluster.local**:
    - Executes `generate-ssl-cert-status.cluster.local` (same guard pattern)
    - Command: same openssl command with CN=status.cluster.local, outputs to `/etc/ssl/certs/status.cluster.local.crt` and `/etc/ssl/private/status.cluster.local.key`
    - Marked `sensitive true`; notifies reload `service[nginx]` (delayed)
- Resources: `package` (1, array of 2), `group` (1), `directory` (2), `execute` (3)

---

**5. sites** (`cookbooks/nginx-multisite/recipes/sites.rb`):
- Iterations: Runs 3 times for sites — **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - Template: `site.conf.erb` → `/etc/nginx/sites-available/test.cluster.local` (mode 0644)
      - Variables: server_name=test.cluster.local, document_root=/opt/server/test, ssl_enabled=true, cert_file=/etc/ssl/certs/test.cluster.local.crt, key_file=/etc/ssl/private/test.cluster.local.key
      - Rendered config: HTTP port 80 block redirects to HTTPS; HTTPS port 443 block with ssl_certificate, ssl_certificate_key, TLSv1.2/TLSv1.3, HSTS, security headers, gzip, location / try_files, deny .ht/.git/.svn
      - Notifies: reload `service[nginx]` (delayed)
    - Symlink: `/etc/nginx/sites-enabled/test.cluster.local` → `/etc/nginx/sites-available/test.cluster.local`
      - Notifies: reload `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - Template: `site.conf.erb` → `/etc/nginx/sites-available/ci.cluster.local` (mode 0644)
      - Variables: server_name=ci.cluster.local, document_root=/opt/server/ci, ssl_enabled=true, cert_file=/etc/ssl/certs/ci.cluster.local.crt, key_file=/etc/ssl/private/ci.cluster.local.key
      - Notifies: reload `service[nginx]` (delayed)
    - Symlink: `/etc/nginx/sites-enabled/ci.cluster.local` → `/etc/nginx/sites-available/ci.cluster.local`
      - Notifies: reload `service[nginx]` (delayed)
  - **status.cluster.local**:
    - Template: `site.conf.erb` → `/etc/nginx/sites-available/status.cluster.local` (mode 0644)
      - Variables: server_name=status.cluster.local, document_root=/opt/server/status, ssl_enabled=true, cert_file=/etc/ssl/certs/status.cluster.local.crt, key_file=/etc/ssl/private/status.cluster.local.key
      - Notifies: reload `service[nginx]` (delayed)
    - Symlink: `/etc/nginx/sites-enabled/status.cluster.local` → `/etc/nginx/sites-available/status.cluster.local`
      - Notifies: reload `service[nginx]` (delayed)
- Deletes `/etc/nginx/sites-enabled/default` (removes the default nginx placeholder site); notifies reload `service[nginx]` (delayed)
- Resources: `template` (3), `link` (3), `file` (1 delete)

---

## Dependencies

**External cookbook dependencies**:
- `cyberark-conjur` (~> 3.0) — provides the `conjur_variable()` helper used in `cookbooks/nginx-multisite/recipes/ssl.rb` to retrieve the SSL passphrase from CyberArk Conjur

**System package dependencies**:
- `nginx` — web server
- `fail2ban` — intrusion prevention / log-based banning
- `ufw` — Uncomplicated Firewall (iptables frontend)
- `openssl` — TLS certificate generation
- `ca-certificates` — CA certificate bundle

**Service dependencies**:
- `nginx` — managed: enabled + started; reloaded on config/cert/site changes
- `fail2ban` — managed: enabled + started; restarted on jail.local changes
- `ssh` — managed: `action :nothing` (only restarted when sshd_config is modified by `ada_ada`)

---

## Credentials

**Detection Summary**: 3 credentials detected across 3 files

**Source**:
- **Provider**: CyberArk Conjur (for SSL passphrase); Hardcoded (for OAuth client secret); Unknown/Custom HTTP endpoint (for parsed token)
- **URL**: `https://conjur.example.com` (Conjur appliance), `https://auth.example.com/oauth/token` (OAuth endpoint), `https://api.example.com/token_endpoint` (token parse endpoint)
- **Path**: `production/nginx/ssl_passphrase` (Conjur variable path)

---

### SSL Certificate Passphrase

- **Variable(s)**: `node['cyberark']['conjur']['variable']` → resolves to `'production/nginx/ssl_passphrase'`; used as `ssl_passphrase = conjur_variable(node['cyberark']['conjur']['variable'])`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/ssl.rb`, `cookbooks/nginx-multisite/attributes/default.rb`
- **Current storage**: CyberArk Conjur vault (`conjur_variable()` call from `cyberark-conjur` cookbook)
- **Usage context**: Passed as `-passout pass:<value>` to `openssl req` when generating self-signed certificates for all 3 sites. The execute resources are marked `sensitive true` to suppress log output. The Conjur connection is configured via `node['cyberark']['conjur']['appliance_url']` (`https://conjur.example.com`) and `node['cyberark']['conjur']['account']` (`myorg`).

---

### OAuth Client Secret (fetch_token)

- **Variable(s)**: `client_secret` property of `fetch_token` custom resource; hardcoded literal value `'sup3rs3cr3t'`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb`
- **Current storage**: **Hardcoded** directly in the recipe source code
- **Usage context**: Used by the `fetch_token['get auth token']` custom resource (`cookbooks/nginx-multisite/resources/fetch_token.rb`) to POST a JSON body `{client_id: "nginx-multisite", client_secret: "sup3rs3cr3t"}` to `https://auth.example.com/oauth/token`. The retrieved `access_token` is stored in `node.run_state['access_token']`. **This is a security risk — the secret must be migrated to a secrets manager (e.g., AAP Credential, HashiCorp Vault, or CyberArk) before production use.**

---

### Parsed Token Endpoint

- **Variable(s)**: `token_url` property of `fetch_and_parse_token` custom resource; value `'https://api.example.com/token_endpoint'`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb`, `cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb`
- **Current storage**: Hardcoded URL in recipe; response body parsed for pattern `pattern1:(.+)` and stored in `node.run_state['extracted_token']`
- **Usage context**: The parsed token value is extracted from the HTTP response and stored in run state. The purpose of this token is not explicitly documented in the cookbook — the Solutions Architect should clarify with the application team what `extracted_token` is consumed by downstream resources or external systems.

---

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
- `/etc/ssh/sshd_config` (PermitRootLogin no, PasswordAuthentication no)

**Service endpoints to check**:
- Ports listening: 80 (HTTP, all 3 sites redirect to HTTPS), 443 (HTTPS, all 3 sites)
- Unix sockets: none (nginx uses TCP only in this configuration)
- Network interfaces: all interfaces (nginx listens on `0.0.0.0:80` and `0.0.0.0:443`)

**Templates rendered**:
- `nginx.conf.erb` → `/etc/nginx/nginx.conf` — rendered **1 time**
- `security.conf.erb` → `/etc/nginx/conf.d/security.conf` — rendered **1 time**
- `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` — rendered **1 time**
- `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` — rendered **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/test.cluster.local` — rendered **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/ci.cluster.local` — rendered **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/status.cluster.local` — rendered **1 time**
- Total `site.conf.erb` renders: **3 times** (once per site)

---

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
# 3. PORT VERIFICATION
# ============================================================
ss -tlnp | grep -E ':80|:443'
netstat -tulpn | grep nginx
lsof -i :80
lsof -i :443

# ============================================================
# 4. VIRTUAL HOST: test.cluster.local
# ============================================================
# HTTP → HTTPS redirect
curl -I -H "Host: test.cluster.local" http://localhost/
# Expected: HTTP/1.1 301 Moved Permanently, Location: https://test.cluster.local/

# HTTPS response (skip cert verify for self-signed)
curl -k -I -H "Host: test.cluster.local" https://localhost/
# Expected: HTTP/1.1 200 OK

# Certificate details
openssl s_client -connect localhost:443 -servername test.cluster.local </dev/null 2>/dev/null | openssl x509 -noout -subject -dates
# Expected: subject=.../CN=test.cluster.local, notAfter=~365 days from issue

# Document root and static file
ls -lah /opt/server/test/index.html
stat /opt/server/test/index.html | grep -E 'Uid|Gid|Access'
# Expected: owner=www-data, group=www-data, mode=0644

# Site config and symlink
cat /etc/nginx/sites-available/test.cluster.local | grep -E 'server_name|listen|ssl_certificate|root|return 301'
ls -la /etc/nginx/sites-enabled/test.cluster.local
# Expected: symlink → /etc/nginx/sites-available/test.cluster.local

# Per-site logs
ls -lah /var/log/nginx/test.cluster.local_access.log
ls -lah /var/log/nginx/test.cluster.local_error.log
tail -20 /var/log/nginx/test.cluster.local_error.log

# ============================================================
# 5. VIRTUAL HOST: ci.cluster.local
# ============================================================
# HTTP → HTTPS redirect
curl -I -H "Host: ci.cluster.local" http://localhost/
# Expected: HTTP/1.1 301 Moved Permanently, Location: https://ci.cluster.local/

# HTTPS response
curl -k -I -H "Host: ci.cluster.local" https://localhost/
# Expected: HTTP/1.1 200 OK

# Certificate details
openssl s_client -connect localhost:443 -servername ci.cluster.local </dev/null 2>/dev/null | openssl x509 -noout -subject -dates
# Expected: subject=.../CN=ci.cluster.local

# Document root and static file
ls -lah /opt/server/ci/index.html
stat /opt/server/ci/index.html | grep -E 'Uid|Gid|Access'
# Expected: owner=www-data, group=www-data, mode=0644

# Site config and symlink
cat /etc/nginx/sites-available/ci.cluster.local | grep -E 'server_name|listen|ssl_certificate|root|return 301'
ls -la /etc/nginx/sites-enabled/ci.cluster.local
# Expected: symlink → /etc/nginx/sites-available/ci.cluster.local

# Per-site logs
ls -lah /var/log/nginx/ci.cluster.local_access.log
ls -lah /var/log/nginx/ci.cluster.local_error.log
tail -20 /var/log/nginx/ci.cluster.local_error.log

# ============================================================
# 6. VIRTUAL HOST: status.cluster.local
# ============================================================
# HTTP → HTTPS redirect
curl -I -H "Host: status.cluster.local" http://localhost/
# Expected: HTTP/1.1 301 Moved Permanently, Location: https://status.cluster.local/

# HTTPS response
curl -k -I -H "Host: status.cluster.local" https://localhost/
# Expected: HTTP/1.1 200 OK

# Certificate details
openssl s_client -connect localhost:443 -servername status.cluster.local </dev/null 2>/dev/null | openssl x509 -noout -subject -dates
# Expected: subject=.../CN=status.cluster.local

# Document root and static file
ls -lah /opt/server/status/index.html
stat /opt/server/status/index.html | grep -E 'Uid|Gid|Access'
# Expected: owner=www-data, group=www-data, mode=0644

# Site config and symlink
cat /etc/nginx/sites-available/status.cluster.local | grep -E 'server_name|listen|ssl_certificate|root|return 301'
ls -la /etc/nginx/sites-enabled/status.cluster.local
# Expected: symlink → /etc/nginx/sites-available/status.cluster.local

# Per-site logs
ls -lah /var/log/nginx/status.cluster.local_access.log
ls -lah /var/log/nginx/status.cluster.local_error.log
tail -20 /var/log/nginx/status.cluster.local_error.log

# ============================================================
# 7. DEFAULT SITE REMOVED
# ============================================================
ls /etc/nginx/sites-enabled/default 2>/dev/null && echo "FAIL: default site still exists" || echo "OK: default site removed"

# ============================================================
# 8. SSL CERTIFICATES AND KEYS
# ============================================================
# test.cluster.local
ls -lah /etc/ssl/certs/test.cluster.local.crt
ls -lah /etc/ssl/private/test.cluster.local.key
stat /etc/ssl/private/test.cluster.local.key | grep -E 'Uid|Gid|Access'
# Expected: mode=0640, owner=root, group=ssl-cert
openssl x509 -in /etc/ssl/certs/test.cluster.local.crt -noout -text | grep -E 'Subject:|Not After'

# ci.cluster.local
ls -lah /etc/ssl/certs/ci.cluster.local.crt
ls -lah /etc/ssl/private/ci.cluster.local.key
stat /etc/ssl/private/ci.cluster.local.key | grep -E 'Uid|Gid|Access'
# Expected: mode=0640, owner=root, group=ssl-cert
openssl x509 -in /etc/ssl/certs/ci.cluster.local.crt -noout -text | grep -E 'Subject:|Not After'

# status.cluster.local
ls -lah /etc/ssl/certs/status.cluster.local.crt
ls -lah /
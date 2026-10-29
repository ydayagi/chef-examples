---
source-path: .
---

# Migration Plan: nginx-multisite

**TLDR**: This cookbook installs and configures nginx as a multi-site web server hosting three SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) on a single node. It hardens the host with fail2ban, UFW firewall rules, and kernel-level sysctl security settings, then generates self-signed TLS certificates for each site using a passphrase retrieved from CyberArk Conjur. Each site gets its own document root, static `index.html`, nginx vhost configuration with HTTP→HTTPS redirect, HSTS, and a full set of security response headers. Three custom resources are present in the cookbook: `ada_ada` (in-place line editor for config files), `fetch_token` (OAuth2 client-credentials token fetcher), and `fetch_and_parse_token` (HTTP response header token extractor).

---

## Service Type and Instances

**Service Type**: Web Server (nginx multi-site)

**Configured Instances**:

- **test.cluster.local**: Test/development environment virtual host
  - Document Root: `/opt/server/test`
  - Port/Socket: 80 (HTTP → HTTPS redirect), 443 (SSL/TLS)
  - SSL: Enabled — certificate `/etc/ssl/certs/test.cluster.local.crt`, key `/etc/ssl/private/test.cluster.local.key`
  - Static file deployed: `files/default/test/index.html` → `/opt/server/test/index.html`
  - Key Config: HSTS, X-Frame-Options DENY, X-Content-Type-Options nosniff, CSP, TLSv1.2+TLSv1.3 only

- **ci.cluster.local**: CI/CD dashboard virtual host
  - Document Root: `/opt/server/ci`
  - Port/Socket: 80 (HTTP → HTTPS redirect), 443 (SSL/TLS)
  - SSL: Enabled — certificate `/etc/ssl/certs/ci.cluster.local.crt`, key `/etc/ssl/private/ci.cluster.local.key`
  - Static file deployed: `files/default/ci/index.html` → `/opt/server/ci/index.html`
  - Key Config: HSTS, X-Frame-Options DENY, X-Content-Type-Options nosniff, CSP, TLSv1.2+TLSv1.3 only

- **status.cluster.local**: System status/monitoring virtual host
  - Document Root: `/opt/server/status`
  - Port/Socket: 80 (HTTP → HTTPS redirect), 443 (SSL/TLS)
  - SSL: Enabled — certificate `/etc/ssl/certs/status.cluster.local.crt`, key `/etc/ssl/private/status.cluster.local.key`
  - Static file deployed: `files/default/status/index.html` → `/opt/server/status/index.html`
  - Key Config: HSTS, X-Frame-Options DENY, X-Content-Type-Options nosniff, CSP, TLSv1.2+TLSv1.3 only

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
- Entry point — includes four recipes in strict order: `security`, `nginx`, `ssl`, `sites`
- Resources: `include_recipe` (4)

---

**2. security** (`cookbooks/nginx-multisite/recipes/security.rb`):
- Installs packages: `fail2ban`, `ufw` (single `package` resource with array)
- Enables and starts the `fail2ban` service
- Deploys `/etc/fail2ban/jail.local` from `fail2ban.jail.local.erb`
  - Template: `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` (mode 0644)
  - Configures jails: `[DEFAULT]` (bantime=3600, findtime=600, maxretry=3), `[sshd]`, `[nginx-http-auth]`, `[nginx-limit-req]`, `[nginx-botsearch]`
  - Notifies: `:restart` on `service[fail2ban]` (delayed)
- Configures UFW firewall with idempotent `not_if` guards:
  - `execute 'ufw_default_deny'` — runs `ufw --force default deny` (skipped if already set)
  - `execute 'ufw_allow_ssh'` — runs `ufw allow ssh` (skipped if 22/tcp already present)
  - `execute 'ufw_allow_http'` — runs `ufw allow http` (skipped if 80/tcp already present)
  - `execute 'ufw_allow_https'` — runs `ufw allow https` (skipped if 443/tcp already present)
  - `execute 'ufw_enable'` — runs `ufw --force enable` (skipped if already active)
- Uses custom resource `fetch_token 'get auth token'`:
  - `auth_url`: `https://auth.example.com/oauth/token`
  - `client_id`: `nginx-multisite`
  - `client_secret`: `sup3rs3cr3t` (**hardcoded secret — see Credentials section**)
  - Stores result in `node.run_state['access_token']`
- Uses custom resource `fetch_and_parse_token 'get parsed token'`:
  - `token_url`: `https://api.example.com/token_endpoint`
  - Parses `X-Header:` line from HTTP response body
  - Stores result in `node.run_state['extracted_token']`
- Deploys `/etc/sysctl.d/99-security.conf` from `sysctl-security.conf.erb`
  - Template: `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` (mode 0644)
  - Sets: IP spoofing protection, ICMP redirect blocking, source routing disabled, martian logging, ICMP echo ignore, TCP SYN cookie protection (tcp_max_syn_backlog=2048), IPv6 disabled
  - Notifies: `:run` on `execute[reload_sysctl]` (delayed)
- `execute 'reload_sysctl'` — runs `sysctl -p /etc/sysctl.d/99-security.conf` (action :nothing, triggered by template notify)
- Conditionally modifies `/etc/ssh/sshd_config` using `ada_ada` custom resource:
  - If `node['security']['ssh']['disable_root']` is `true` (default: true):
    - `ada_ada '/etc/ssh/sshd_config'` — replaces/appends line `PermitRootLogin no`, matching pattern `^#\?PermitRootLogin`
    - Notifies: `:restart` on `service[ssh]` (delayed)
  - If `node['security']['ssh']['password_auth']` is `false` (default: false):
    - `ada_ada '/etc/ssh/sshd_config'` — replaces/appends line `PasswordAuthentication no`, matching pattern `^#\?PasswordAuthentication`
    - Notifies: `:restart` on `service[ssh]` (delayed)
- `service 'ssh'` — action :nothing (triggered only by ada_ada notifies above)
- Resources: package (1), service (2), template (2), execute (6), fetch_token (1), fetch_and_parse_token (1), ada_ada (2)

---

**3. nginx** (`cookbooks/nginx-multisite/recipes/nginx.rb`):
- Installs package: `nginx`
- Deploys `/etc/nginx/nginx.conf` from `nginx.conf.erb`
  - Template: `nginx.conf.erb` → `/etc/nginx/nginx.conf` (mode 0644)
  - Sets: user=www-data, worker_processes=auto, worker_connections=768, sendfile/tcp_nopush/tcp_nodelay on, keepalive_timeout=65, gzip on, includes `/etc/nginx/conf.d/*.conf` and `/etc/nginx/sites-enabled/*`
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Deploys `/etc/nginx/conf.d/security.conf` from `security.conf.erb`
  - Template: `security.conf.erb` → `/etc/nginx/conf.d/security.conf` (mode 0644)
  - Sets: server_tokens off, rate limiting zones (login: 10r/m, api: 30r/m), client buffer limits (body=1K, header=1k, max_body=1k), timeouts (body/header/send=10s), SSL session cache (10m), TLSv1.2+TLSv1.3, strong cipher suite
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Enables and starts `nginx` service
- Iterations — runs 3 times for sites: **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - `directory '/opt/server/test'` — owner=www-data, group=www-data, mode=0755, recursive=true
    - `cookbook_file '/opt/server/test/index.html'` — source `test/index.html`, owner=www-data, group=www-data, mode=0644
  - **ci.cluster.local**:
    - `directory '/opt/server/ci'` — owner=www-data, group=www-data, mode=0755, recursive=true
    - `cookbook_file '/opt/server/ci/index.html'` — source `ci/index.html`, owner=www-data, group=www-data, mode=0644
  - **status.cluster.local**:
    - `directory '/opt/server/status'` — owner=www-data, group=www-data, mode=0755, recursive=true
    - `cookbook_file '/opt/server/status/index.html'` — source `status/index.html`, owner=www-data, group=www-data, mode=0644
- Resources: package (1), template (2), service (1), directory (3), cookbook_file (3)

---

**4. ssl** (`cookbooks/nginx-multisite/recipes/ssl.rb`):
- Installs packages: `openssl`, `ca-certificates`
- Fetches SSL passphrase from CyberArk Conjur using `conjur_variable(node['cyberark']['conjur']['variable'])`:
  - Conjur URL: `https://conjur.example.com`
  - Account: `myorg`
  - Variable path: `production/nginx/ssl_passphrase`
  - Result stored in local variable `ssl_passphrase` used in openssl commands
- Creates group `ssl-cert`
- Creates directory `/etc/ssl/certs` — owner=root, group=root, mode=0755
- Creates directory `/etc/ssl/private` — owner=root, group=ssl-cert, mode=0710
- Iterations — runs 3 times for sites with ssl_enabled=true: **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - `execute 'generate-ssl-cert-test.cluster.local'` — generates self-signed RSA-2048 cert valid 365 days
      - Key: `/etc/ssl/private/test.cluster.local.key` (chmod 640, chown root:ssl-cert)
      - Cert: `/etc/ssl/certs/test.cluster.local.crt`
      - Subject: `/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=test.cluster.local/emailAddress=admin@example.com`
      - Passphrase: from Conjur variable `production/nginx/ssl_passphrase`
      - `sensitive true`, `not_if` guard: skipped if both cert and key files already exist
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - `execute 'generate-ssl-cert-ci.cluster.local'` — generates self-signed RSA-2048 cert valid 365 days
      - Key: `/etc/ssl/private/ci.cluster.local.key` (chmod 640, chown root:ssl-cert)
      - Cert: `/etc/ssl/certs/ci.cluster.local.crt`
      - Subject: `/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=ci.cluster.local/emailAddress=admin@example.com`
      - Passphrase: from Conjur variable `production/nginx/ssl_passphrase`
      - `sensitive true`, `not_if` guard: skipped if both cert and key files already exist
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **status.cluster.local**:
    - `execute 'generate-ssl-cert-status.cluster.local'` — generates self-signed RSA-2048 cert valid 365 days
      - Key: `/etc/ssl/private/status.cluster.local.key` (chmod 640, chown root:ssl-cert)
      - Cert: `/etc/ssl/certs/status.cluster.local.crt`
      - Subject: `/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=status.cluster.local/emailAddress=admin@example.com`
      - Passphrase: from Conjur variable `production/nginx/ssl_passphrase`
      - `sensitive true`, `not_if` guard: skipped if both cert and key files already exist
      - Notifies: `:reload` on `service[nginx]` (delayed)
- Resources: package (1), group (1), directory (2), execute (3)

---

**5. sites** (`cookbooks/nginx-multisite/recipes/sites.rb`):
- Iterations — runs 3 times for sites: **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - `template '/etc/nginx/sites-available/test.cluster.local'` — source `site.conf.erb`, mode=0644
      - Variables: server_name=`test.cluster.local`, document_root=`/opt/server/test`, ssl_enabled=`true`, cert_file=`/etc/ssl/certs/test.cluster.local.crt`, key_file=`/etc/ssl/private/test.cluster.local.key`
      - Renders: HTTP server block (port 80, redirect to HTTPS) + HTTPS server block (port 443 ssl http2) with HSTS, security headers, gzip, location blocks
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/test.cluster.local'` → `/etc/nginx/sites-available/test.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - `template '/etc/nginx/sites-available/ci.cluster.local'` — source `site.conf.erb`, mode=0644
      - Variables: server_name=`ci.cluster.local`, document_root=`/opt/server/ci`, ssl_enabled=`true`, cert_file=`/etc/ssl/certs/ci.cluster.local.crt`, key_file=`/etc/ssl/private/ci.cluster.local.key`
      - Renders: HTTP server block (port 80, redirect to HTTPS) + HTTPS server block (port 443 ssl http2) with HSTS, security headers, gzip, location blocks
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/ci.cluster.local'` → `/etc/nginx/sites-available/ci.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **status.cluster.local**:
    - `template '/etc/nginx/sites-available/status.cluster.local'` — source `site.conf.erb`, mode=0644
      - Variables: server_name=`status.cluster.local`, document_root=`/opt/server/status`, ssl_enabled=`true`, cert_file=`/etc/ssl/certs/status.cluster.local.crt`, key_file=`/etc/ssl/private/status.cluster.local.key`
      - Renders: HTTP server block (port 80, redirect to HTTPS) + HTTPS server block (port 443 ssl http2) with HSTS, security headers, gzip, location blocks
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/status.cluster.local'` → `/etc/nginx/sites-available/status.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
- `file '/etc/nginx/sites-enabled/default'` — action :delete (removes default nginx site)
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Resources: template (3), link (3), file (1)

---

## Dependencies

**External cookbook dependencies**: `cyberark-conjur ~> 3.0` (provides the `conjur_variable()` helper used in `cookbooks/nginx-multisite/recipes/ssl.rb`)

**System package dependencies**: `nginx`, `fail2ban`, `ufw`, `openssl`, `ca-certificates`

**Service dependencies**: `nginx` (enabled + started), `fail2ban` (enabled + started), `ssh` (restarted on sshd_config change only)

---

## Credentials

**Detection Summary**: 3 credentials detected across 3 files

### SSL Certificate Passphrase

- **Variable(s)**: `node['cyberark']['conjur']['variable']` → resolved value of Conjur path `production/nginx/ssl_passphrase`; used as `-passout pass:#{ssl_passphrase}` in openssl commands
- **Source file(s)**: `cookbooks/nginx-multisite/attributes/default.rb` (Conjur config), `cookbooks/nginx-multisite/recipes/ssl.rb` (retrieval and use)
- **Current storage**: CyberArk Conjur — retrieved at converge time via `conjur_variable()` helper from the `cyberark-conjur` cookbook dependency
- **Source**:
  - **Provider**: CyberArk Conjur
  - **URL**: `https://conjur.example.com`
  - **Path**: `production/nginx/ssl_passphrase`
- **Usage context**: Passed as the `-passout` argument to `openssl req -x509` when generating self-signed TLS certificates for all three sites. The passphrase protects the private key files at `/etc/ssl/private/*.key`.

### OAuth2 Client Secret (fetch_token)

- **Variable(s)**: `client_secret` property of `fetch_token 'get auth token'` resource — hardcoded value `sup3rs3cr3t`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb` (line: `client_secret 'sup3rs3cr3t'`)
- **Current storage**: **Hardcoded** in recipe source code — this is a critical security finding
- **Source**:
  - **Provider**: None (hardcoded)
  - **URL**: N/A
  - **Path**: N/A
- **Usage context**: Used as the OAuth2 `client_secret` in a POST to `https://auth.example.com/oauth/token` to obtain an access token. The resulting token is stored in `node.run_state['access_token']` but its downstream consumer is not visible in this cookbook. This secret **must** be migrated to AAP Credential or a vault before any production deployment.

### CyberArk Conjur Connection Attributes

- **Variable(s)**: `node['cyberark']['conjur']['appliance_url']`, `node['cyberark']['conjur']['account']`
- **Source file(s)**: `cookbooks/nginx-multisite/attributes/default.rb`
- **Current storage**: Plaintext attribute defaults (non-secret connection metadata)
- **Source**:
  - **Provider**: CyberArk Conjur (connection metadata)
  - **URL**: `https://conjur.example.com`
  - **Path**: N/A
- **Usage context**: Configure the Conjur client used by the `cyberark-conjur` cookbook to authenticate and retrieve the `production/nginx/ssl_passphrase` variable. In Ansible, these map to the CyberArk Conjur credential type in AAP.

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
- `/etc/nginx/sites-enabled/default` (must NOT exist — deleted)
- `/opt/server/test/index.html`
- `/opt/server/ci/index.html`
- `/opt/server/status/index.html`
- `/etc/ssl/certs/test.cluster.local.crt`
- `/etc/ssl/certs/ci.cluster.local.crt`
- `/etc/ssl/certs/status.cluster.local.crt`
- `/etc/ssl/private/test.cluster.local.key`
- `/etc/ssl/private/ci.cluster.local.key`
- `/etc/ssl/private/status.cluster.local.key`
- `/etc/fail2ban/jail.local`
- `/etc/sysctl.d/99-security.conf`
- `/etc/ssh/sshd_config` (modified lines: `PermitRootLogin no`, `PasswordAuthentication no`)
- `/var/log/nginx/access.log`
- `/var/log/nginx/error.log`
- `/var/log/nginx/test.cluster.local_access.log`
- `/var/log/nginx/test.cluster.local_error.log`
- `/var/log/nginx/ci.cluster.local_access.log`
- `/var/log/nginx/ci.cluster.local_error.log`
- `/var/log/nginx/status.cluster.local_access.log`
- `/var/log/nginx/status.cluster.local_error.log`

**Service endpoints to check**:
- Port 80 (HTTP, all three sites — redirect only)
- Port 443 (HTTPS, all three sites)
- Network interfaces: all interfaces (nginx listens on `0.0.0.0:80` and `0.0.0.0:443`)
- Unix sockets: none

**Templates rendered**:
- `nginx.conf.erb` → `/etc/nginx/nginx.conf` — renders **1 time**
- `security.conf.erb` → `/etc/nginx/conf.d/security.conf` — renders **1 time**
- `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` — renders **1 time**
- `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` — renders **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/test.cluster.local` — renders **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/ci.cluster.local` — renders **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/status.cluster.local` — renders **1 time**

Total: `site.conf.erb` renders **3 times** (once per site); all other templates render once each.

---

## Pre-flight Checks

```bash
# ============================================================
# SERVICE STATUS
# ============================================================
systemctl status nginx
systemctl status fail2ban
systemctl is-enabled nginx
systemctl is-enabled fail2ban
ps aux | grep nginx | grep -v grep

# ============================================================
# NGINX CONFIGURATION VALIDATION
# ============================================================
nginx -t
cat /etc/nginx/nginx.conf | grep -E 'worker_processes|worker_connections|keepalive_timeout|gzip'
cat /etc/nginx/conf.d/security.conf | grep -E 'server_tokens|ssl_protocols|ssl_ciphers|limit_req_zone'

# Verify default site is removed
ls -la /etc/nginx/sites-enabled/default 2>&1 | grep "No such file"

# ============================================================
# SITE: test.cluster.local
# ============================================================
# Vhost config exists
ls -lah /etc/nginx/sites-available/test.cluster.local
cat /etc/nginx/sites-available/test.cluster.local | grep -E 'server_name|ssl_certificate|root|return 301'

# Symlink active
ls -la /etc/nginx/sites-enabled/test.cluster.local
readlink /etc/nginx/sites-enabled/test.cluster.local
# Expected: /etc/nginx/sites-available/test.cluster.local

# Document root and static file
ls -lah /opt/server/test/index.html
stat /opt/server/test/index.html | grep -E 'Uid|Gid|Access'
# Expected: www-data:www-data 0644

# SSL certificate
ls -lah /etc/ssl/certs/test.cluster.local.crt
ls -lah /etc/ssl/private/test.cluster.local.key
openssl x509 -in /etc/ssl/certs/test.cluster.local.crt -noout -subject -dates -issuer
openssl x509 -in /etc/ssl/certs/test.cluster.local.crt -noout -subject | grep "CN=test.cluster.local"
stat /etc/ssl/private/test.cluster.local.key | grep "Access: (0640"

# HTTP → HTTPS redirect
curl -I -H "Host: test.cluster.local" http://localhost/ 2>/dev/null | grep -E 'HTTP|Location'
# Expected: HTTP/1.1 301 and Location: https://test.cluster.local/

# HTTPS response (skip cert verification for self-signed)
curl -k -I -H "Host: test.cluster.local" https://localhost/ 2>/dev/null | grep -E 'HTTP|Strict-Transport|X-Frame|X-Content'
# Expected: HTTP/1.1 200 OK, Strict-Transport-Security, X-Frame-Options: DENY, X-Content-Type-Options: nosniff

# Per-site log files
ls -lah /var/log/nginx/test.cluster.local_access.log
ls -lah /var/log/nginx/test.cluster.local_error.log

# ============================================================
# SITE: ci.cluster.local
# ============================================================
# Vhost config exists
ls -lah /etc/nginx/sites-available/ci.cluster.local
cat /etc/nginx/sites-available/ci.cluster.local | grep -E 'server_name|ssl_certificate|root|return 301'

# Symlink active
ls -la /etc/nginx/sites-enabled/ci.cluster.local
readlink /etc/nginx/sites-enabled/ci.cluster.local
# Expected: /etc/nginx/sites-available/ci.cluster.local

# Document root and static file
ls -lah /opt/server/ci/index.html
stat /opt/server/ci/index.html | grep -E 'Uid|Gid|Access'
# Expected: www-data:www-data 0644

# SSL certificate
ls -lah /etc/ssl/certs/ci.cluster.local.crt
ls -lah /etc/ssl/private/ci.cluster.local.key
openssl x509 -in /etc/ssl/certs/ci.cluster.local.crt -noout -subject -dates -issuer
openssl x509 -in /etc/ssl/certs/ci.cluster.local.crt -noout -subject | grep "CN=ci.cluster.local"
stat /etc/ssl/private/ci.cluster.local.key | grep "Access: (0640"

# HTTP → HTTPS redirect
curl -I -H "Host: ci.cluster.local" http://localhost/ 2>/dev/null | grep -E 'HTTP|Location'
# Expected: HTTP/1.1 301 and Location: https://ci.cluster.local/

# HTTPS response (skip cert verification for self-signed)
curl -k -I -H "Host: ci.cluster.local" https://localhost/ 2>/dev/null | grep -E 'HTTP|Strict-Transport|X-Frame|X-Content'
# Expected: HTTP/1.1 200 OK, Strict-Transport-Security, X-Frame-Options: DENY, X-Content-Type-Options: nosniff

# Per-site log files
ls -lah /var/log/nginx/ci.cluster.local_access.log
ls -lah /var/log/nginx/ci.cluster.local_error.log

# ============================================================
# SITE: status.cluster.local
# ============================================================
# Vhost config exists
ls -lah /etc/nginx/sites-available/status.cluster.local
cat /etc/nginx/sites-available/status.cluster.local | grep -E 'server_name|ssl_certificate|root|return 301'

# Symlink active
ls -la /etc/nginx/sites-enabled/status.cluster.local
readlink /etc/nginx/sites-enabled/status.cluster.local
# Expected: /etc/nginx/sites-available/status.cluster.local

# Document root and static file
ls -lah /opt/server/status/index.html
stat /opt/server/status/index.html | grep -E 'Uid|Gid|Access'
# Expected: www-data:www-data 0644

# SSL certificate
ls -lah /etc/ssl/certs/status.cluster.local.crt
ls -lah /etc/ssl/private/status.cluster.local.key
openssl x509 -in /etc/ssl/certs/status.cluster.local.crt -noout -subject -dates -issuer
openssl x509 -in /etc/ssl/certs/status.cluster.local.crt -noout -subject | grep "CN=status.cluster.local"
stat /etc/ssl/private/status.cluster.local.key | grep "Access: (0640"

# HTTP → HTTPS redirect
curl -I -H "Host: status.cluster.local" http://localhost/ 2>/dev/null | grep -E 'HTTP|Location'
# Expected: HTTP/1.1 301 and Location: https://status.cluster.local/

# HTTPS response (skip cert verification for self-signed)
curl -k -I -H "Host: status.cluster.local" https://localhost/ 2>/dev/null | grep -E 'HTTP|Strict-Transport|X-Frame|X-Content'
# Expected: HTTP/1.1 200 OK, Strict-Transport-Security, X-Frame-Options: DENY, X-Content-Type-Options: nosniff

# Per-site log files
ls -lah /var/log/nginx/status.cluster.local_access.log
ls -l
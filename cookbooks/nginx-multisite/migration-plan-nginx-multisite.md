---
source-path: .
---

# Migration Plan: nginx-multisite

**TLDR**: This cookbook configures an nginx web server hosting three SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) on a single node. It hardens the host with fail2ban, UFW firewall rules, and kernel-level sysctl security settings, then generates self-signed TLS certificates for each site using a passphrase fetched from CyberArk Conjur. Each site gets its own document root, static `index.html`, nginx `sites-available` configuration, and a symlink into `sites-enabled`. Two custom token-fetching resources (`fetch_token`, `fetch_and_parse_token`) are also invoked during the security phase, and a custom line-editor resource (`ada_ada`) is used to harden `/etc/ssh/sshd_config`.

---

## Service Type and Instances

**Service Type**: Web Server (nginx multi-site / reverse proxy with TLS termination)

**Configured Instances**:

- **test.cluster.local**: Test/development environment virtual host
  - Document Root: `/opt/server/test`
  - Port/Socket: 80 (HTTP → 301 redirect to HTTPS), 443 (HTTPS/TLS)
  - SSL: Enabled — certificate: `/etc/ssl/certs/test.cluster.local.crt`, key: `/etc/ssl/private/test.cluster.local.key`
  - Static file deployed: `files/default/test/index.html` → `/opt/server/test/index.html`
  - Key Config: TLSv1.2/TLSv1.3, HSTS, security headers (X-Frame-Options DENY, X-Content-Type-Options, X-XSS-Protection, CSP), gzip enabled
  - Logs: `/var/log/nginx/test.cluster.local_access.log`, `/var/log/nginx/test.cluster.local_error.log`

- **ci.cluster.local**: CI/CD dashboard virtual host
  - Document Root: `/opt/server/ci`
  - Port/Socket: 80 (HTTP → 301 redirect to HTTPS), 443 (HTTPS/TLS)
  - SSL: Enabled — certificate: `/etc/ssl/certs/ci.cluster.local.crt`, key: `/etc/ssl/private/ci.cluster.local.key`
  - Static file deployed: `files/default/ci/index.html` → `/opt/server/ci/index.html`
  - Key Config: TLSv1.2/TLSv1.3, HSTS, security headers, gzip enabled
  - Logs: `/var/log/nginx/ci.cluster.local_access.log`, `/var/log/nginx/ci.cluster.local_error.log`

- **status.cluster.local**: System status/monitoring virtual host
  - Document Root: `/opt/server/status`
  - Port/Socket: 80 (HTTP → 301 redirect to HTTPS), 443 (HTTPS/TLS)
  - SSL: Enabled — certificate: `/etc/ssl/certs/status.cluster.local.crt`, key: `/etc/ssl/private/status.cluster.local.key`
  - Static file deployed: `files/default/status/index.html` → `/opt/server/status/index.html`
  - Key Config: TLSv1.2/TLSv1.3, HSTS, security headers, gzip enabled
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
- Entry point. Includes four recipes in strict order: `security` → `nginx` → `ssl` → `sites`.
- Resources: `include_recipe` (4)

---

**2. security** (`cookbooks/nginx-multisite/recipes/security.rb`):
- Installs packages: `fail2ban`, `ufw` (installed together as a package array).
- Enables and starts the `fail2ban` service.
- Deploys fail2ban jail configuration:
  - Template: `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` (mode 0644)
  - Notifies: `:restart` on `service[fail2ban]` (delayed)
  - Jail configuration sets: `bantime=3600`, `findtime=600`, `maxretry=3`, `backend=auto`
  - Enabled jails: `[sshd]` (port ssh, `/var/log/auth.log`), `[nginx-http-auth]` (port http,https, `/var/log/nginx/*error.log`), `[nginx-limit-req]` (port http,https, `/var/log/nginx/*error.log`, maxretry=10), `[nginx-botsearch]` (port http,https, `/var/log/nginx/*access.log`, maxretry=2)
- Configures UFW firewall rules (each with `not_if` idempotency guards):
  - `execute 'ufw_default_deny'`: runs `ufw --force default deny`
  - `execute 'ufw_allow_ssh'`: runs `ufw allow ssh`
  - `execute 'ufw_allow_http'`: runs `ufw allow http`
  - `execute 'ufw_allow_https'`: runs `ufw allow https`
  - `execute 'ufw_enable'`: runs `ufw --force enable`
- Invokes custom resource `fetch_token 'get auth token'`:
  - `auth_url`: `https://auth.example.com/oauth/token`
  - `client_id`: `nginx-multisite`
  - `client_secret`: `sup3rs3cr3t` (**hardcoded secret — see Credentials section**)
  - Stores result in `node.run_state['access_token']`
- Invokes custom resource `fetch_and_parse_token 'get parsed token'`:
  - `token_url`: `https://api.example.com/token_endpoint`
  - Parses response body for pattern `pattern1:(.+)`, stores in `node.run_state['extracted_token']`
- Deploys kernel hardening sysctl configuration:
  - Template: `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` (mode 0644)
  - Notifies: `:run` on `execute[reload_sysctl]` (delayed)
  - Settings applied: IP spoofing protection (`rp_filter=1`), ICMP redirect ignore, source routing disabled, martian logging, ICMP ping ignore (`icmp_echo_ignore_all=1`), IPv6 disabled, TCP SYN cookie protection (`tcp_syncookies=1`, `tcp_max_syn_backlog=2048`)
- `execute 'reload_sysctl'`: runs `sysctl -p /etc/sysctl.d/99-security.conf` (action `:nothing`, triggered by template notify)
- Conditionally hardens SSH using custom resource `ada_ada`:
  - If `node['security']['ssh']['disable_root']` is `true` (default: `true`):
    - `ada_ada '/etc/ssh/sshd_config'`: sets `PermitRootLogin no`, matches pattern `^#\?PermitRootLogin`, notifies `:restart` on `service[ssh]`
  - If `node['security']['ssh']['password_auth']` is `false` (default: `false`):
    - `ada_ada '/etc/ssh/sshd_config'`: sets `PasswordAuthentication no`, matches pattern `^#\?PasswordAuthentication`, notifies `:restart` on `service[ssh]`
- `service 'ssh'`: action `:nothing` (only restarted via notify from `ada_ada` resources above)
- Resources: package (1, array of 2), service (2), template (2), execute (6), fetch_token (1), fetch_and_parse_token (1), ada_ada (2)

---

**3. nginx** (`cookbooks/nginx-multisite/recipes/nginx.rb`):
- Installs package: `nginx`
- Deploys global nginx configuration:
  - Template: `nginx.conf.erb` → `/etc/nginx/nginx.conf` (mode 0644)
  - Config: `user www-data`, `worker_processes auto`, `worker_connections 768`, `keepalive_timeout 65`, gzip on, includes `/etc/nginx/conf.d/*.conf` and `/etc/nginx/sites-enabled/*`
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Deploys nginx security snippet:
  - Template: `security.conf.erb` → `/etc/nginx/conf.d/security.conf` (mode 0644)
  - Config: `server_tokens off`, rate limiting zones (`login:10m rate=10r/m`, `api:10m rate=30r/m`), buffer overflow protections (`client_body_buffer_size 1K`, `client_header_buffer_size 1k`, `client_max_body_size 1k`, `large_client_header_buffers 2 1k`), timeouts (body/header/send = 10s), global SSL settings (TLSv1.2/TLSv1.3, session cache 10m)
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Enables and starts the `nginx` service (supports restart, reload, status)
- Iterations — runs 3 times for sites `test.cluster.local`, `ci.cluster.local`, `status.cluster.local`:
  - **test.cluster.local**:
    - Creates directory `/opt/server/test` (owner: `www-data`, group: `www-data`, mode: `0755`, recursive: true)
    - Deploys `cookbook_file`: `files/default/test/index.html` → `/opt/server/test/index.html` (owner: `www-data`, group: `www-data`, mode: `0644`)
    - `site_folder` derived as `test` (first segment of `test.cluster.local`)
  - **ci.cluster.local**:
    - Creates directory `/opt/server/ci` (owner: `www-data`, group: `www-data`, mode: `0755`, recursive: true)
    - Deploys `cookbook_file`: `files/default/ci/index.html` → `/opt/server/ci/index.html` (owner: `www-data`, group: `www-data`, mode: `0644`)
    - `site_folder` derived as `ci`
  - **status.cluster.local**:
    - Creates directory `/opt/server/status` (owner: `www-data`, group: `www-data`, mode: `0755`, recursive: true)
    - Deploys `cookbook_file`: `files/default/status/index.html` → `/opt/server/status/index.html` (owner: `www-data`, group: `www-data`, mode: `0644`)
    - `site_folder` derived as `status`
- Resources: package (1), template (2), service (1), directory (3), cookbook_file (3)

---

**4. ssl** (`cookbooks/nginx-multisite/recipes/ssl.rb`):
- Installs packages: `openssl`, `ca-certificates` (installed together as a package array)
- Fetches SSL passphrase from CyberArk Conjur using `conjur_variable(node['cyberark']['conjur']['variable'])`:
  - Variable path: `production/nginx/ssl_passphrase`
  - Conjur appliance URL: `https://conjur.example.com`, account: `myorg`
  - Result stored in local variable `ssl_passphrase` (used in openssl commands below)
- Creates group `ssl-cert`
- Creates certificate directory `/etc/ssl/certs` (owner: `root`, group: `root`, mode: `0755`)
- Creates private key directory `/etc/ssl/private` (owner: `root`, group: `ssl-cert`, mode: `0710`)
- Iterations — runs 3 times for sites where `ssl_enabled: true` (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`):
  - **test.cluster.local** (`ssl_enabled: true`):
    - `execute 'generate-ssl-cert-test.cluster.local'`: generates self-signed certificate using openssl
      - Key output: `/etc/ssl/private/test.cluster.local.key`
      - Cert output: `/etc/ssl/certs/test.cluster.local.crt`
      - Parameters: `-x509 -days 365 -newkey rsa:2048`, subject `/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=test.cluster.local/emailAddress=admin@example.com`
      - Passphrase: from Conjur (`ssl_passphrase` variable), passed via `-passout pass:#{ssl_passphrase}`
      - Post-generation: `chmod 640` on key, `chown root:ssl-cert` on key
      - Guard: `not_if { ::File.exist?(cert_file) && ::File.exist?(key_file) }` (idempotent)
      - `sensitive true` (suppresses output in Chef logs)
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local** (`ssl_enabled: true`):
    - `execute 'generate-ssl-cert-ci.cluster.local'`: same openssl command
      - Key output: `/etc/ssl/private/ci.cluster.local.key`
      - Cert output: `/etc/ssl/certs/ci.cluster.local.crt`
      - Subject CN: `ci.cluster.local`
      - Same passphrase, permissions, guard, and notify as above
  - **status.cluster.local** (`ssl_enabled: true`):
    - `execute 'generate-ssl-cert-status.cluster.local'`: same openssl command
      - Key output: `/etc/ssl/private/status.cluster.local.key`
      - Cert output: `/etc/ssl/certs/status.cluster.local.crt`
      - Subject CN: `status.cluster.local`
      - Same passphrase, permissions, guard, and notify as above
- Resources: package (1, array of 2), group (1), directory (2), execute (3)

---

**5. sites** (`cookbooks/nginx-multisite/recipes/sites.rb`):
- Iterations — runs 3 times for sites `test.cluster.local`, `ci.cluster.local`, `status.cluster.local`:
  - **test.cluster.local**:
    - Template: `site.conf.erb` → `/etc/nginx/sites-available/test.cluster.local` (mode 0644)
      - Variables: `server_name=test.cluster.local`, `document_root=/opt/server/test`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/test.cluster.local.crt`, `key_file=/etc/ssl/private/test.cluster.local.key`
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - Symlink: `/etc/nginx/sites-enabled/test.cluster.local` → `/etc/nginx/sites-available/test.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - Template: `site.conf.erb` → `/etc/nginx/sites-available/ci.cluster.local` (mode 0644)
      - Variables: `server_name=ci.cluster.local`, `document_root=/opt/server/ci`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/ci.cluster.local.crt`, `key_file=/etc/ssl/private/ci.cluster.local.key`
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - Symlink: `/etc/nginx/sites-enabled/ci.cluster.local` → `/etc/nginx/sites-available/ci.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **status.cluster.local**:
    - Template: `site.conf.erb` → `/etc/nginx/sites-available/status.cluster.local` (mode 0644)
      - Variables: `server_name=status.cluster.local`, `document_root=/opt/server/status`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/status.cluster.local.crt`, `key_file=/etc/ssl/private/status.cluster.local.key`
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - Symlink: `/etc/nginx/sites-enabled/status.cluster.local` → `/etc/nginx/sites-available/status.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
- Deletes the default nginx site: `file '/etc/nginx/sites-enabled/default'` (action `:delete`, notifies `:reload` on `service[nginx]`)
- Resources: template (3), link (3), file (1)

---

## Custom Resources

### `ada_ada` (`cookbooks/nginx-multisite/resources/ada_ada.rb`)

A custom line-editor resource for idempotently managing individual lines in configuration files. Equivalent to Ansible's `lineinfile` module.

**Properties**:

| Property | Type | Default | Description |
|---|---|---|---|
| `file_path` | String | (name property) | Path to the file to edit |
| `line` | String | required | The exact line content to insert or replace |
| `match` | String | optional | Ruby regex pattern; if the pattern matches an existing line, that line is replaced with `line`. If no match is found, `line` is appended. If `match` is omitted, `line` is appended only if not already present. |
| `backup` | Boolean | `true` | If `true`, writes a timestamped backup of the original file before modifying it (e.g., `/etc/ssh/sshd_config.backup.1700000000`) |

**Action `:create`** (default):
1. Reads the target file.
2. If `match` is provided and the pattern is found → replaces the matched line with `line` using `gsub`.
3. If `match` is provided but not found → appends `line` to the file.
4. If `match` is not provided → appends `line` only if it is not already present.
5. If the file does not exist → creates it with `line` as its sole content.
6. If `backup: true` and the content changed → writes a backup file at `#{file_path}.backup.#{Time.now.to_i}`.

**Usage in this cookbook** (`recipes/security.rb`):
```ruby
# Disable root SSH login
ada_ada '/etc/ssh/sshd_config' do
  line  'PermitRootLogin no'
  match '^#\?PermitRootLogin'
  notifies :restart, 'service[ssh]', :delayed
end

# Disable password authentication
ada_ada '/etc/ssh/sshd_config' do
  line  'PasswordAuthentication no'
  match '^#\?PasswordAuthentication'
  notifies :restart, 'service[ssh]', :delayed
end
```

---

### `fetch_token` (`cookbooks/nginx-multisite/resources/fetch_token.rb`)

A custom resource that performs an OAuth2 client-credentials token fetch over HTTPS and stores the resulting `access_token` in `node.run_state`.

**Properties**:

| Property | Type | Required | Description |
|---|---|---|---|
| `auth_url` | String | yes | Full URL of the OAuth token endpoint |
| `client_id` | String | yes | OAuth client ID |
| `client_secret` | String | yes | OAuth client secret |
| `access_token` | String | no | Output property; populated with the `access_token` from the JSON response |

**Action `:fetch`** (default):
1. Parses `auth_url` with `URI.parse`.
2. Opens an HTTPS connection (`Net::HTTP`).
3. POSTs a JSON body `{ client_id: ..., client_secret: ... }` with `Content-Type: application/json`.
4. Parses the JSON response and extracts `payload['access_token']`.
5. Stores the token in both `new_resource.access_token` and `node.run_state['access_token']`.

**Usage in this cookbook** (`recipes/security.rb`):
```ruby
fetch_token 'get auth token' do
  auth_url      'https://auth.example.com/oauth/token'
  client_id     'nginx-multisite'
  client_secret 'sup3rs3cr3t'   # ← hardcoded secret
end
```

---

### `fetch_and_parse_token` (`cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb`)

A custom resource that performs a plain HTTP GET to a token URL, then parses the response body using a fixed regex pattern (`pattern1:(.+)`) to extract a token value.

**Properties**:

| Property | Type | Required | Description |
|---|---|---|---|
| `token_url` | String | yes | Full URL to GET |
| `extracted_token` | String | no | Output property; populated with the captured group from the regex match |

**Action `:fetch_and_parse`** (default):
1. Performs `Net::HTTP.get_response(URI.parse(token_url))`.
2. Matches the response body against `/pattern1:(.+)/`.
3. If matched → strips whitespace from capture group 1, stores in `new_resource.extracted_token` and `node.run_state['extracted_token']`.
4. If not matched → raises `"Failed to parse token pattern from response body."`.

**Usage in this cookbook** (`recipes/security.rb`):
```ruby
fetch_and_parse_token 'get parsed token' do
  token_url 'https://api.example.com/token_endpoint'
end
```

---

## Dependencies

**External cookbook dependencies**:
- `cyberark-conjur ~> 3.0` — provides the `conjur_variable()` helper used in `recipes/ssl.rb` to fetch the SSL passphrase from CyberArk Conjur

**System package dependencies**:
- `nginx` — web server
- `fail2ban` — intrusion prevention / log-based banning
- `ufw` — Uncomplicated Firewall (iptables frontend)
- `openssl` — TLS certificate generation
- `ca-certificates` — CA certificate bundle

**Service dependencies** (systemd services managed):
- `nginx` — enabled, started; reloaded on config/cert/site changes
- `fail2ban` — enabled, started; restarted on jail config changes
- `ssh` — restarted (action `:nothing`, triggered only by `ada_ada` sshd_config changes)

---

## Credentials

**Detection Summary**: 3 credentials detected across 3 files

**Source**:
- **Provider**: CyberArk Conjur (for SSL passphrase); Hardcoded (for OAuth client secret); Unknown/custom HTTP endpoint (for parsed token)
- **URL**: `https://conjur.example.com` (Conjur appliance)
- **Path**: `production/nginx/ssl_passphrase` (Conjur variable path)

---

### SSL Certificate Passphrase

- **Variable(s)**: `node['cyberark']['conjur']['variable']` → resolves to `production/nginx/ssl_passphrase`; used as `ssl_passphrase` local variable in `recipes/ssl.rb`
- **Source file(s)**: `cookbooks/nginx-multisite/attributes/default.rb` (Conjur config), `cookbooks/nginx-multisite/recipes/ssl.rb` (retrieval and use)
- **Current storage**: CyberArk Conjur vault — fetched at converge time via `conjur_variable()` helper from the `cyberark-conjur` cookbook
- **Usage context**: Passed as `-passout pass:#{ssl_passphrase}` to `openssl req` when generating self-signed TLS certificates for all three virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`). The `execute` resource is marked `sensitive true` to suppress the passphrase from Chef logs.

---

### OAuth Client Secret (fetch_token)

- **Variable(s)**: `client_secret` property of `fetch_token 'get auth token'`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb` (line: `client_secret 'sup3rs3cr3t'`)
- **Current storage**: **Hardcoded** plaintext string `sup3rs3cr3t` directly in the recipe source code
- **Usage context**: Used as the OAuth2 `client_secret` in a POST request to `https://auth.example.com/oauth/token` to obtain an `access_token`. The token is stored in `node.run_state['access_token']` for potential use by subsequent resources. **This is a security risk and must be migrated to a secrets manager (e.g., AAP Credential, HashiCorp Vault, or CyberArk Conjur) before production use.**

---

### Parsed Token (fetch_and_parse_token)

- **Variable(s)**: `extracted_token` property of `fetch_and_parse_token 'get parsed token'`; stored in `node.run_state['extracted_token']`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb`
- **Current storage**: Fetched at runtime from `https://api.example.com/token_endpoint` via HTTP GET; no static credential stored in the cookbook itself
- **Usage context**: The response body is parsed with the regex `pattern1:(.+)` to extract a token value. The purpose of this token is not explicitly documented in the cookbook; it appears to be a secondary authentication or API token. The endpoint URL and parsing pattern are hardcoded in the resource definition (`cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb`).

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
- `/etc/ssh/sshd_config` (must contain `PermitRootLogin no` and `PasswordAuthentication no`)

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
- Port 80 (HTTP, all three vhosts — redirects to HTTPS), listening on `0.0.0.0:80`
- Port 443 (HTTPS/TLS, all three vhosts), listening on `0.0.0.0:443`
- Unix sockets: none

**Templates rendered**:
- `nginx.conf.erb` → `/etc/nginx/nginx.conf` — renders **1 time**
- `security.conf.erb` → `/etc/nginx/conf.d/security.conf` — renders **1 time**
- `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` — renders **1 time**
- `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` — renders **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/test.cluster.local` — renders **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/ci.cluster.local` — renders **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/status.cluster.local` — renders **1 time**
- Total: `site.conf.erb` renders **3 times** (once per virtual host)

---

## Pre-flight Checks

```bash
# ============================================================
# SERVICE STATUS
# ============================================================
systemctl status nginx
systemctl status fail2ban
systemctl status ssh
ps aux | grep nginx

# ============================================================
# NGINX CONFIGURATION VALIDATION
# ============================================================
nginx -t
nginx -T | grep -E 'server_name|listen|ssl_certificate|root'

# Verify global config
grep -E 'worker_processes|worker_connections|keepalive_timeout|gzip' /etc/nginx/nginx.conf

# Verify security snippet
grep -E 'server_tokens|limit_req_zone|client_body_buffer_size|ssl_protocols' /etc/nginx/conf.d/security.conf

# Verify default site is DELETED (should return no output / error)
ls -la /etc/nginx/sites-enabled/default 2>&1 | grep "No such file"

# ============================================================
# VIRTUAL HOST: test.cluster.local
# ============================================================
# Config file exists and is correct
grep -E 'server_name|listen|root|ssl_certificate' /etc/nginx/sites-available/test.cluster.local

# Symlink is active and points to correct target
ls -la /etc/nginx/sites-enabled/test.cluster.local
readlink /etc/nginx/sites-enabled/test.cluster.local
# Expected: /etc/nginx/sites-available/test.cluster.local

# Document root and static file
ls -lah /opt/server/test/index.html
stat -c "%U %G %a" /opt/server/test/index.html
# Expected: www-data www-data 644

# SSL certificate and key
ls -lah /etc/ssl/certs/test.cluster.local.crt
ls -lah /etc/ssl/private/test.cluster.local.key
stat -c "%U %G %a" /etc/ssl/private/test.cluster.local.key
# Expected: root ssl-cert 640
openssl x509 -in /etc/
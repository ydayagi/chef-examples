---
source-path: .
---

# Migration Plan: nginx-multisite

**TLDR**: This cookbook configures an Nginx web server hosting 3 SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) on a single node. It hardens the host with UFW firewall rules, fail2ban intrusion prevention, and kernel-level sysctl security parameters. SSL certificates are self-signed and generated per-site using OpenSSL; the SSL passphrase is retrieved at runtime from **CyberArk Conjur** (`production/nginx/ssl_passphrase`). SSH access is locked down (no root login, no password authentication). Three custom Chef resources (`ada_ada`, `fetch_value`, `fetch_and_parse_value`) handle in-place file-line editing and remote API value fetching respectively.

---

## Service Type and Instances

**Service Type**: Web Server (Nginx multi-site / reverse proxy with SSL termination)

**Configured Instances**:

- **test.cluster.local**: Test/development environment virtual host
  - Document Root: `/opt/server/test`
  - Port/Socket: 80 (HTTP → HTTPS redirect), 443 (HTTPS/SSL)
  - SSL: Enabled — certificate: `/etc/ssl/certs/test.cluster.local.crt`, key: `/etc/ssl/private/test.cluster.local.key`
  - Static file deployed: `files/default/test/index.html` → `/opt/server/test/index.html`
  - Key Config: TLSv1.2/TLSv1.3, HSTS, security headers (X-Frame-Options DENY, X-Content-Type-Options, X-XSS-Protection, CSP)

- **ci.cluster.local**: CI/CD Dashboard virtual host
  - Document Root: `/opt/server/ci`
  - Port/Socket: 80 (HTTP → HTTPS redirect), 443 (HTTPS/SSL)
  - SSL: Enabled — certificate: `/etc/ssl/certs/ci.cluster.local.crt`, key: `/etc/ssl/private/ci.cluster.local.key`
  - Static file deployed: `files/default/ci/index.html` → `/opt/server/ci/index.html`
  - Key Config: TLSv1.2/TLSv1.3, HSTS, security headers (X-Frame-Options DENY, X-Content-Type-Options, X-XSS-Protection, CSP)

- **status.cluster.local**: System status/monitoring virtual host
  - Document Root: `/opt/server/status`
  - Port/Socket: 80 (HTTP → HTTPS redirect), 443 (HTTPS/SSL)
  - SSL: Enabled — certificate: `/etc/ssl/certs/status.cluster.local.crt`, key: `/etc/ssl/private/status.cluster.local.key`
  - Static file deployed: `files/default/status/index.html` → `/opt/server/status/index.html`
  - Key Config: TLSv1.2/TLSv1.3, HSTS, security headers (X-Frame-Options DENY, X-Content-Type-Options, X-XSS-Protection, CSP)

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
│   ├── fetch_and_parse_value.rb
│   └── fetch_value.rb
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
- Entry point. Includes four sub-recipes in strict order: `security` → `nginx` → `ssl` → `sites`.
- Resources: `include_recipe` (4)

---

**2. security** (`cookbooks/nginx-multisite/recipes/security.rb`):
- Installs packages: `fail2ban`, `ufw` (single `package` resource with array `%w[fail2ban ufw]`)
- Enables and starts the `fail2ban` service
- Deploys fail2ban configuration:
  - Template: `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` (mode 0644)
  - Configures jails: `[DEFAULT]` (bantime=3600, findtime=600, maxretry=3), `[sshd]` (enabled, logpath=/var/log/auth.log), `[nginx-http-auth]` (enabled, port=http,https, logpath=/var/log/nginx/*error.log), `[nginx-limit-req]` (enabled, maxretry=10), `[nginx-botsearch]` (enabled, logpath=/var/log/nginx/*access.log, maxretry=2)
  - Notifies: `:restart` on `service[fail2ban]` (delayed)
- Configures UFW firewall with 5 idempotent `execute` resources (each guarded by `not_if`):
  - `ufw_default_deny`: `ufw --force default deny` (skipped if already "Default: deny")
  - `ufw_allow_ssh`: `ufw allow ssh` (skipped if 22/tcp already present)
  - `ufw_allow_http`: `ufw allow http` (skipped if 80/tcp already present)
  - `ufw_allow_https`: `ufw allow https` (skipped if 443/tcp already present)
  - `ufw_enable`: `ufw --force enable` (skipped if already "Status: active")
- Invokes custom resource `fetch_value['get remote value']`:
  - Provider: `cookbooks/nginx-multisite/resources/fetch_value.rb`
  - Performs HTTP GET to `https://api.example.com/value_endpoint`
  - Stores raw response body in `node.run_state['fetched_value']`
  - Action: `:fetch`
- Invokes custom resource `fetch_and_parse_value['get and parse remote value']`:
  - Provider: `cookbooks/nginx-multisite/resources/fetch_and_parse_value.rb`
  - Performs HTTP GET to `https://api.example.com/parse_endpoint`
  - Parses response body for pattern `pattern1:(.+)`, captures group 1
  - Stores parsed value in `node.run_state['parsed_value']`
  - Raises error if pattern not found
  - Action: `:fetch_and_parse`
- Deploys kernel hardening configuration:
  - Template: `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` (mode 0644)
  - Parameters set: `net.ipv4.conf.default.rp_filter=1`, `net.ipv4.conf.all.rp_filter=1`, `net.ipv4.conf.all.accept_redirects=0`, `net.ipv6.conf.all.accept_redirects=0`, `net.ipv4.conf.default.accept_redirects=0`, `net.ipv6.conf.default.accept_redirects=0`, `net.ipv4.conf.all.send_redirects=0`, `net.ipv4.conf.default.send_redirects=0`, `net.ipv4.conf.all.accept_source_route=0`, `net.ipv6.conf.all.accept_source_route=0`, `net.ipv4.conf.default.accept_source_route=0`, `net.ipv6.conf.default.accept_source_route=0`, `net.ipv4.conf.all.log_martians=1`, `net.ipv4.conf.default.log_martians=1`, `net.ipv4.icmp_echo_ignore_all=1`, `net.ipv4.icmp_echo_ignore_broadcasts=1`, `net.ipv6.conf.all.disable_ipv6=1`, `net.ipv6.conf.default.disable_ipv6=1`, `net.ipv6.conf.lo.disable_ipv6=1`, `net.ipv4.tcp_syncookies=1`, `net.ipv4.tcp_max_syn_backlog=2048`, `net.ipv4.tcp_synack_retries=2`, `net.ipv4.tcp_syn_retries=5`
  - Notifies: `:run` on `execute[reload_sysctl]` (delayed)
- `execute[reload_sysctl]`: `sysctl -p /etc/sysctl.d/99-security.conf` (action `:nothing`, triggered by template above)
- Conditional SSH hardening using custom resource `ada_ada` (provider: `cookbooks/nginx-multisite/resources/ada_ada.rb`):
  - If `node['security']['ssh']['disable_root']` is `true` (default: `true`):
    - `ada_ada '/etc/ssh/sshd_config'`: Replaces/appends line matching `^#\?PermitRootLogin` with `PermitRootLogin no`; creates a timestamped `.backup` file before modifying; notifies `:restart` on `service[ssh]` (delayed)
  - If `node['security']['ssh']['password_auth']` is `false` (default: `false`):
    - `ada_ada '/etc/ssh/sshd_config'`: Replaces/appends line matching `^#\?PasswordAuthentication` with `PasswordAuthentication no`; creates a timestamped `.backup` file before modifying; notifies `:restart` on `service[ssh]` (delayed)
- `service 'ssh'`: action `:nothing` (only restarted via notifications from `ada_ada` above)
- Resources: `package` (1), `service` (2), `template` (2), `execute` (6), `fetch_value` (1), `fetch_and_parse_value` (1), `ada_ada` (2)

---

**3. nginx** (`cookbooks/nginx-multisite/recipes/nginx.rb`):
- Installs package: `nginx`
- Deploys global Nginx configuration:
  - Template: `nginx.conf.erb` → `/etc/nginx/nginx.conf` (mode 0644)
  - Config: user=www-data, worker_processes=auto, worker_connections=768, sendfile=on, tcp_nopush=on, tcp_nodelay=on, keepalive_timeout=65, gzip=on, access_log=/var/log/nginx/access.log, error_log=/var/log/nginx/error.log; includes `/etc/nginx/conf.d/*.conf` and `/etc/nginx/sites-enabled/*`
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Deploys Nginx security snippet:
  - Template: `security.conf.erb` → `/etc/nginx/conf.d/security.conf` (mode 0644)
  - Config: server_tokens=off; rate limit zones `login` (10r/m, 10m) and `api` (30r/m, 10m); client_body_buffer_size=1K, client_header_buffer_size=1k, client_max_body_size=1k, large_client_header_buffers=2 1k; client_body_timeout=10, client_header_timeout=10, send_timeout=10; ssl_session_cache=shared:SSL:10m, ssl_session_timeout=10m, ssl_protocols=TLSv1.2 TLSv1.3, ssl_ciphers=ECDHE-RSA-AES256-GCM-SHA512:..., ssl_prefer_server_ciphers=on
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Enables and starts the `nginx` service (supports restart, reload, status)
- Iterations — runs 3 times for sites `test.cluster.local`, `ci.cluster.local`, `status.cluster.local`:
  - **test.cluster.local**:
    - `directory '/opt/server/test'`: owner=www-data, group=www-data, mode=0755, recursive=true
    - `cookbook_file '/opt/server/test/index.html'`: source=`test/index.html` (from `files/default/test/index.html`), owner=www-data, group=www-data, mode=0644
  - **ci.cluster.local**:
    - `directory '/opt/server/ci'`: owner=www-data, group=www-data, mode=0755, recursive=true
    - `cookbook_file '/opt/server/ci/index.html'`: source=`ci/index.html` (from `files/default/ci/index.html`), owner=www-data, group=www-data, mode=0644
  - **status.cluster.local**:
    - `directory '/opt/server/status'`: owner=www-data, group=www-data, mode=0755, recursive=true
    - `cookbook_file '/opt/server/status/index.html'`: source=`status/index.html` (from `files/default/status/index.html`), owner=www-data, group=www-data, mode=0644
- Resources: `package` (1), `template` (2), `service` (1), `directory` (3), `cookbook_file` (3)

---

**4. ssl** (`cookbooks/nginx-multisite/recipes/ssl.rb`):
- Installs packages: `openssl`, `ca-certificates`
- Fetches SSL passphrase from CyberArk Conjur at runtime: `conjur_variable('production/nginx/ssl_passphrase')` using the `cyberark-conjur` cookbook dependency (appliance URL: `https://conjur.example.com`, account: `myorg`)
- Creates group `ssl-cert`
- Creates SSL certificate directory: `/etc/ssl/certs` (owner=root, group=root, mode=0755)
- Creates SSL private key directory: `/etc/ssl/private` (owner=root, group=ssl-cert, mode=0710)
- Iterations — runs 3 times for sites where `ssl_enabled: true` — all 3: `test.cluster.local`, `ci.cluster.local`, `status.cluster.local`:
  - **test.cluster.local**:
    - `execute 'generate-ssl-cert-test.cluster.local'`: Runs `openssl req -x509 -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/test.cluster.local.key -out /etc/ssl/certs/test.cluster.local.crt -passout pass:<conjur_passphrase> -subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=test.cluster.local/emailAddress=admin@example.com"`, then `chmod 640 /etc/ssl/private/test.cluster.local.key` and `chown root:ssl-cert /etc/ssl/private/test.cluster.local.key`; marked `sensitive true`; guarded by `not_if { File.exist?(cert) && File.exist?(key) }`; notifies `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - `execute 'generate-ssl-cert-ci.cluster.local'`: Same openssl command with CN=ci.cluster.local, outputs to `/etc/ssl/certs/ci.cluster.local.crt` and `/etc/ssl/private/ci.cluster.local.key`; same guards and notifications
  - **status.cluster.local**:
    - `execute 'generate-ssl-cert-status.cluster.local'`: Same openssl command with CN=status.cluster.local, outputs to `/etc/ssl/certs/status.cluster.local.crt` and `/etc/ssl/private/status.cluster.local.key`; same guards and notifications
- Resources: `package` (1), `group` (1), `directory` (2), `execute` (3)

---

**5. sites** (`cookbooks/nginx-multisite/recipes/sites.rb`):
- Iterations — runs 3 times for sites `test.cluster.local`, `ci.cluster.local`, `status.cluster.local`:
  - **test.cluster.local**:
    - Template: `site.conf.erb` → `/etc/nginx/sites-available/test.cluster.local` (mode 0644)
      - Variables: server_name=test.cluster.local, document_root=/opt/server/test, ssl_enabled=true, cert_file=/etc/ssl/certs/test.cluster.local.crt, key_file=/etc/ssl/private/test.cluster.local.key
      - Config rendered: HTTP→HTTPS redirect on port 80; HTTPS server on port 443 with ssl http2; TLSv1.2/TLSv1.3; HSTS max-age=31536000 includeSubDomains; security headers (X-Frame-Options DENY, X-Content-Type-Options nosniff, X-XSS-Protection 1;mode=block, Referrer-Policy strict-origin-when-cross-origin, CSP default-src 'self'); gzip on; access_log=/var/log/nginx/test.cluster.local_access.log; error_log=/var/log/nginx/test.cluster.local_error.log
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/test.cluster.local'` → `/etc/nginx/sites-available/test.cluster.local`; notifies `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - Template: `site.conf.erb` → `/etc/nginx/sites-available/ci.cluster.local` (mode 0644)
      - Variables: server_name=ci.cluster.local, document_root=/opt/server/ci, ssl_enabled=true, cert_file=/etc/ssl/certs/ci.cluster.local.crt, key_file=/etc/ssl/private/ci.cluster.local.key
      - Config rendered: HTTP→HTTPS redirect on port 80; HTTPS server on port 443 with ssl http2; TLSv1.2/TLSv1.3; HSTS max-age=31536000 includeSubDomains; same security headers; gzip on; access_log=/var/log/nginx/ci.cluster.local_access.log; error_log=/var/log/nginx/ci.cluster.local_error.log
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/ci.cluster.local'` → `/etc/nginx/sites-available/ci.cluster.local`; notifies `:reload` on `service[nginx]` (delayed)
  - **status.cluster.local**:
    - Template: `site.conf.erb` → `/etc/nginx/sites-available/status.cluster.local` (mode 0644)
      - Variables: server_name=status.cluster.local, document_root=/opt/server/status, ssl_enabled=true, cert_file=/etc/ssl/certs/status.cluster.local.crt, key_file=/etc/ssl/private/status.cluster.local.key
      - Config rendered: HTTP→HTTPS redirect on port 80; HTTPS server on port 443 with ssl http2; TLSv1.2/TLSv1.3; HSTS max-age=31536000 includeSubDomains; same security headers; gzip on; access_log=/var/log/nginx/status.cluster.local_access.log; error_log=/var/log/nginx/status.cluster.local_error.log
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/status.cluster.local'` → `/etc/nginx/sites-available/status.cluster.local`; notifies `:reload` on `service[nginx]` (delayed)
- Deletes the default Nginx site: `file '/etc/nginx/sites-enabled/default'` (action `:delete`); notifies `:reload` on `service[nginx]` (delayed)
- Resources: `template` (3), `link` (3), `file` (1)

---

## Custom Resources

### `ada_ada` (`cookbooks/nginx-multisite/resources/ada_ada.rb`)

**Purpose**: In-place line replacement/append in a text file, with optional backup. Equivalent to Ansible's `lineinfile` module.

**Properties**:
| Property | Type | Default | Description |
|---|---|---|---|
| `file_path` | String | (name property) | Path to the file to modify |
| `line` | String | required | The exact line to write |
| `match` | String | nil | Ruby regex pattern to find and replace; if nil, appends if line not present |
| `backup` | Boolean | `true` | If true, writes a timestamped `.backup.<epoch>` copy before modifying |

**Action `:create`**:
1. Reads the file at `file_path`
2. If `match` is provided: replaces the first matching line with `line`; if no match found, appends `line`
3. If `match` is nil: appends `line` only if it is not already present
4. If content changed and `backup=true`: writes original content to `<file_path>.backup.<epoch>`
5. Writes new content to `file_path`
6. If file does not exist: creates it with `line` as content

**Ansible equivalent**: `ansible.builtin.lineinfile` with `regexp`, `line`, and `backup` parameters.

**Usage in cookbook**:
- `ada_ada '/etc/ssh/sshd_config'` with `line 'PermitRootLogin no'`, `match '^#\?PermitRootLogin'` → disables root SSH login
- `ada_ada '/etc/ssh/sshd_config'` with `line 'PasswordAuthentication no'`, `match '^#\?PasswordAuthentication'` → disables password authentication

---

### `fetch_value` (`cookbooks/nginx-multisite/resources/fetch_value.rb`)

**Purpose**: Performs an HTTP GET request to a remote URL and stores the raw response body in `node.run_state['fetched_value']` for use by subsequent resources in the same Chef run.

**Properties**:
| Property | Type | Required | Description |
|---|---|---|---|
| `value_url` | String | yes | Full URL to fetch |
| `fetched_value` | String | no | Output property; populated after fetch |

**Action `:fetch`**:
1. Parses `value_url` as a URI
2. Performs `Net::HTTP.get_response(uri)`
3. Stores `response.body` in both `new_resource.fetched_value` and `node.run_state['fetched_value']`

**Ansible equivalent**: `ansible.builtin.uri` module with `return_content: true`, storing result in a variable via `register`.

**Usage in cookbook**: Called in `cookbooks/nginx-multisite/recipes/security.rb` as `fetch_value 'get remote value'` with `value_url 'https://api.example.com/value_endpoint'`. The fetched value is available to subsequent resources via `node.run_state['fetched_value']`.

---

### `fetch_and_parse_value` (`cookbooks/nginx-multisite/resources/fetch_and_parse_value.rb`)

**Purpose**: Performs an HTTP GET request to a remote URL, parses the response body for a specific pattern (`pattern1:(.+)`), and stores the captured group in `node.run_state['parsed_value']`. Raises a hard error if the pattern is not found.

**Properties**:
| Property | Type | Required | Description |
|---|---|---|---|
| `value_url` | String | yes | Full URL to fetch |
| `parsed_value` | String | no | Output property; populated after successful parse |

**Action `:fetch_and_parse`**:
1. Parses `value_url` as a URI
2. Performs `Net::HTTP.get_response(uri)`
3. Matches response body against `/pattern1:(.+)/`
4. If matched: strips whitespace from capture group 1, stores in `new_resource.parsed_value` and `node.run_state['parsed_value']`
5. If not matched: raises `"Failed to parse value pattern from response body."`

**Ansible equivalent**: `ansible.builtin.uri` + `ansible.builtin.set_fact` with a `regex_search` filter on the response body.

**Usage in cookbook**: Called in `cookbooks/nginx-multisite/recipes/security.rb` as `fetch_and_parse_value 'get and parse remote value'` with `value_url 'https://api.example.com/parse_endpoint'`. The parsed value is available to subsequent resources via `node.run_state['parsed_value']`.

> **⚠️ Migration Note**: The pattern `pattern1:(.+)` appears to be a placeholder. The Ansible developer must confirm the actual expected response format from `https://api.example.com/parse_endpoint` with the application team before implementing the equivalent parsing logic.

---

## Dependencies

**External cookbook dependencies**:
- `cyberark-conjur ~> 3.0` — provides the `conjur_variable()` helper used in `cookbooks/nginx-multisite/recipes/ssl.rb` to retrieve the SSL passphrase from CyberArk Conjur at `https://conjur.example.com` (account: `myorg`, variable path: `production/nginx/ssl_passphrase`)

**System package dependencies**:
- `nginx` — web server
- `fail2ban` — intrusion prevention / brute-force protection
- `ufw` — host-based firewall (Uncomplicated Firewall)
- `openssl` — SSL certificate generation
- `ca-certificates` — CA certificate bundle

**Service dependencies** (systemd services managed):
- `nginx` — enabled + started; reloaded on config/site/cert changes
- `fail2ban` — enabled + started; restarted on jail.local changes
- `ssh` — action `:nothing` (only restarted when sshd_config is modified by `ada_ada`)

---

## Credentials

**Detection Summary**: 1 credential detected across 2 files (`attributes/default.rb` and `recipes/ssl.rb`)

**Source**:
- **Provider**: CyberArk Conjur
- **URL**: `https://conjur.example.com`
- **Path**: `production/nginx/ssl_passphrase`

### SSL Certificate Passphrase

- **Variable(s)**: `node['cyberark']['conjur']['variable']` → resolved value of `production/nginx/ssl_passphrase`; used inline as `-passout pass:<value>` in the `openssl req` command
- **Source file(s)**:
  - `cookbooks/nginx-multisite/attributes/default.rb` — defines Conjur connection parameters (`appliance_url`, `account`, `variable` path)
  - `cookbooks/nginx-multisite/recipes/ssl.rb` — calls `conjur_variable(node['cyberark']['conjur']['variable'])` to retrieve the secret at converge time; passes it directly into the `openssl req -passout` argument
- **Current storage**: CyberArk Conjur (via `conjur_variable()` helper from the `cyberark-conjur` cookbook)
- **Usage context**: Used as the PEM passphrase (`-passout pass:...`) when generating self-signed SSL certificates for all 3 virtual hosts. The `execute` resource is marked `sensitive true` to suppress the passphrase from Chef logs. The passphrase protects the private key files at `/etc/ssl/private/*.key`.

> **⚠️ Migration Note for Solutions Architect**: In Ansible, this secret must be retrieved from CyberArk Conjur before the `openssl` command runs. Options include:
> 1. Using the `cyberark.conjur.conjur_variable` lookup plugin: `"{{ lookup('cyberark.conjur.conjur_variable', 'production/nginx/ssl_passphrase') }}"`
> 2. Using AAP Credential Type for CyberArk Conjur and injecting the value as an environment variable or extra var
> 3. Pre-fetching the secret in an earlier task and storing it as a `no_log: true` variable
>
> The `openssl` task must use `no_log: true` to prevent the passphrase from appearing in AAP job output.

---

## Checks for the Migration

**Files to verify**:

*Nginx configuration:*
- `/etc/nginx/nginx.conf`
- `/etc/nginx/conf.d/security.conf`
- `/etc/nginx/sites-available/test.cluster.local`
- `/etc/nginx/sites-available/ci.cluster.local`
- `/etc/nginx/sites-available/status.cluster.local`
- `/etc/nginx/sites-enabled/test.cluster.local` (symlink)
- `/etc/nginx/sites-enabled/ci.cluster.local` (symlink)
- `/etc/nginx/sites-enabled/status.cluster.local` (symlink)
- `/etc/nginx/sites-enabled/default` (must NOT exist — deleted)

*SSL certificates and keys:*
- `/etc/ssl/certs/test.cluster.local.crt`
- `/etc/ssl/private/test.cluster.local.key`
- `/etc/ssl/certs/ci.cluster.local.crt`
- `/etc/ssl/private/ci.cluster.local.key`
- `/etc/ssl/certs/status.cluster.local.crt`
- `/etc/ssl/private/status.cluster.local.key`

*Document roots and static files:*
- `/opt/server/test/index.html`
- `/opt/server/ci/index.html`
- `/opt/server/status/index.html`

*Security configuration:*
- `/etc/fail2ban/jail.local`
- `/etc/sysctl.d/99-security.conf`
- `/etc/ssh/sshd_config` (must contain `PermitRootLogin no` and `PasswordAuthentication no`)
- `/etc/ssh/sshd_config.backup.<epoch>` (backup created by `ada_ada`)

**Service endpoints to check**:
- Ports listening: 80 (HTTP, all 3 sites — redirect only), 443 (HTTPS, all 3 sites)
- Unix sockets: none
- Network interfaces: all interfaces (nginx listens on `0.0.0.0:80` and `0.0.0.0:443`)

**Templates rendered**:
- `nginx.conf.erb` → `/etc/nginx/nginx.conf` — rendered **1 time**
- `security.conf.erb` → `/etc/nginx/conf.d/security.conf` — rendered **1 time**
- `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` — rendered **1 time**
- `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` — rendered **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/test.cluster.local` — rendered **1 time** (site 1 of 3)
- `site.conf.erb` → `/etc/nginx/sites-available/ci.cluster.local` — rendered **1 time** (site 2 of 3)
- `site.conf.erb` → `/etc/nginx/sites-available/status.cluster.local` — rendered **1 time** (site 3 of 3)

---

## Pre-flight Checks

```bash
# ============================================================
# 1. SERVICE STATUS
# ============================================================
systemctl status nginx
systemctl status fail2ban
systemctl status ssh
ps aux | grep nginx | grep -v grep

# ============================================================
# 2. NGINX CONFIGURATION SYNTAX
# ============================================================
nginx -t
nginx -T | grep -E 'server_name|listen|ssl_certificate|root'

# ============================================================
# 3. VIRTUAL HOST: test.cluster.local
# ============================================================
# Config file present
ls -lah /etc/
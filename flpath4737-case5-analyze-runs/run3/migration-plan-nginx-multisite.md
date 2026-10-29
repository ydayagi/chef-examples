---
source-path: .
---

# Migration Plan: nginx-multisite

**TLDR**: This cookbook configures an Nginx web server hosting three SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) on a single node. It hardens the host with fail2ban, UFW firewall rules, and kernel-level sysctl security parameters, then generates self-signed TLS certificates for each site using a passphrase retrieved from CyberArk Conjur. Each site gets its own document root, static `index.html`, and a per-site Nginx vhost configuration that enforces HTTP→HTTPS redirect, TLS 1.2/1.3, HSTS, and a full set of security response headers. The cookbook also patches `/etc/ssh/sshd_config` to disable root login and password authentication using a custom in-line file-editing resource (`ada_ada`), and makes two token-fetch calls to external HTTP APIs via the `fetch_token` and `fetch_and_parse_token` custom resources.

---

## Service Type and Instances

**Service Type**: Web Server (Nginx multi-site with TLS termination)

**Configured Instances**:

- **test.cluster.local**: Static-file site served from `/opt/server/test`
  - Location/Path: Document root `/opt/server/test`; static file `files/default/test/index.html` deployed to `/opt/server/test/index.html`
  - Port/Socket: HTTP 80 (redirect only) → HTTPS 443
  - Key Config: `ssl_enabled: true`; certificate `/etc/ssl/certs/test.cluster.local.crt`; key `/etc/ssl/private/test.cluster.local.key`; vhost config `/etc/nginx/sites-available/test.cluster.local`

- **ci.cluster.local**: Static-file site served from `/opt/server/ci`
  - Location/Path: Document root `/opt/server/ci`; static file `files/default/ci/index.html` deployed to `/opt/server/ci/index.html`
  - Port/Socket: HTTP 80 (redirect only) → HTTPS 443
  - Key Config: `ssl_enabled: true`; certificate `/etc/ssl/certs/ci.cluster.local.crt`; key `/etc/ssl/private/ci.cluster.local.key`; vhost config `/etc/nginx/sites-available/ci.cluster.local`

- **status.cluster.local**: Static-file site served from `/opt/server/status`
  - Location/Path: Document root `/opt/server/status`; static file `files/default/status/index.html` deployed to `/opt/server/status/index.html`
  - Port/Socket: HTTP 80 (redirect only) → HTTPS 443
  - Key Config: `ssl_enabled: true`; certificate `/etc/ssl/certs/status.cluster.local.crt`; key `/etc/ssl/private/status.cluster.local.key`; vhost config `/etc/nginx/sites-available/status.cluster.local`

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
- Entry point; includes four sub-recipes in strict order: `security` → `nginx` → `ssl` → `sites`.
- Resources: `include_recipe` (4)

---

**2. security** (`cookbooks/nginx-multisite/recipes/security.rb`):
- Installs packages: `fail2ban`, `ufw` (single `package` resource with array).
- Enables and starts the `fail2ban` service.
- Deploys `/etc/fail2ban/jail.local` from `fail2ban.jail.local.erb` (mode `0644`); notifies `fail2ban` service restart on change.
  - Template configures five jails: `[DEFAULT]` (bantime=3600, findtime=600, maxretry=3), `[sshd]` (logpath=/var/log/auth.log), `[nginx-http-auth]` (logpath=/var/log/nginx/*error.log), `[nginx-limit-req]` (logpath=/var/log/nginx/*error.log, maxretry=10), `[nginx-botsearch]` (logpath=/var/log/nginx/*access.log, maxretry=2).
- Configures UFW firewall via five idempotent `execute` resources (each guarded by `not_if`):
  - `ufw_default_deny`: `ufw --force default deny` (skipped if already "Default: deny")
  - `ufw_allow_ssh`: `ufw allow ssh` (skipped if 22/tcp already listed)
  - `ufw_allow_http`: `ufw allow http` (skipped if 80/tcp already listed)
  - `ufw_allow_https`: `ufw allow https` (skipped if 443/tcp already listed)
  - `ufw_enable`: `ufw --force enable` (skipped if "Status: active")
- Uses custom resource `fetch_token['get auth token']`:
  - `auth_url`: `https://auth.example.com/oauth/token`
  - `client_id`: `nginx-multisite`
  - `client_secret`: `sup3rs3cr3t` (**hardcoded secret — see Credentials section**)
  - Stores retrieved `access_token` in `node.run_state['access_token']`
- Uses custom resource `fetch_and_parse_token['get parsed token']`:
  - `token_url`: `https://api.example.com/token_endpoint`
  - Parses `X-Header:<value>` from HTTP response body
  - Stores result in `node.run_state['extracted_token']`
- Deploys `/etc/sysctl.d/99-security.conf` from `sysctl-security.conf.erb` (mode `0644`); notifies `execute[reload_sysctl]` on change.
  - Template sets: IP spoofing protection (`rp_filter=1`), ICMP redirect ignore, send-redirect disable, source-route disable, martian logging, ICMP echo ignore, broadcast ping ignore, IPv6 disable, TCP SYN-cookie flood protection (`tcp_syncookies=1`, `tcp_max_syn_backlog=2048`).
- `execute[reload_sysctl]`: `sysctl -p /etc/sysctl.d/99-security.conf` — action `:nothing`, triggered only by template change.
- Conditionally patches `/etc/ssh/sshd_config` using `ada_ada` custom resource:
  - If `node['security']['ssh']['disable_root']` is `true` (default: `true`): replaces/appends `PermitRootLogin no` matching pattern `^#\?PermitRootLogin`.
  - If `node['security']['ssh']['password_auth']` is `false` (default: `false`): replaces/appends `PasswordAuthentication no` matching pattern `^#\?PasswordAuthentication`.
  - Both `ada_ada` calls notify `service[ssh]` restart (`:delayed`).
- `service[ssh]`: action `:nothing` — triggered only by `ada_ada` notifications.
- Resources: `package` (1, array of 2), `service` (2: fail2ban + ssh), `template` (2), `execute` (6), `fetch_token` (1, custom), `fetch_and_parse_token` (1, custom), `ada_ada` (2, custom)

---

**3. nginx** (`cookbooks/nginx-multisite/recipes/nginx.rb`):
- Installs package: `nginx`.
- Deploys `/etc/nginx/nginx.conf` from `nginx.conf.erb` (mode `0644`); notifies nginx reload on change.
  - Template sets: `user www-data`, `worker_processes auto`, `worker_connections 768`, `keepalive_timeout 65`, gzip on, includes `/etc/nginx/conf.d/*.conf` and `/etc/nginx/sites-enabled/*`.
- Deploys `/etc/nginx/conf.d/security.conf` from `security.conf.erb` (mode `0644`); notifies nginx reload on change.
  - Template sets: `server_tokens off`, rate-limit zones (`login` 10r/m, `api` 30r/m), buffer limits (`client_body_buffer_size 1K`, `client_max_body_size 1k`), timeouts (body/header/send = 10s), global SSL settings (TLSv1.2/TLSv1.3, strong cipher suite, `ssl_prefer_server_ciphers on`).
- Enables and starts the `nginx` service.
- Iterations: Runs 3 times for sites — **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - Creates directory `/opt/server/test` (owner: `www-data`, group: `www-data`, mode: `0755`, recursive).
    - Deploys `files/default/test/index.html` → `/opt/server/test/index.html` (owner: `www-data`, group: `www-data`, mode: `0644`).
  - **ci.cluster.local**:
    - Creates directory `/opt/server/ci` (owner: `www-data`, group: `www-data`, mode: `0755`, recursive).
    - Deploys `files/default/ci/index.html` → `/opt/server/ci/index.html` (owner: `www-data`, group: `www-data`, mode: `0644`).
  - **status.cluster.local**:
    - Creates directory `/opt/server/status` (owner: `www-data`, group: `www-data`, mode: `0755`, recursive).
    - Deploys `files/default/status/index.html` → `/opt/server/status/index.html` (owner: `www-data`, group: `www-data`, mode: `0644`).
  - Note: `site_folder` is derived as the first DNS label (e.g., `test.cluster.local` → `test`), which maps to the `files/default/<site_folder>/index.html` cookbook file source.
- Resources: `package` (1), `template` (2), `service` (1), `directory` (3), `cookbook_file` (3)

---

**4. ssl** (`cookbooks/nginx-multisite/recipes/ssl.rb`):
- Installs packages: `openssl`, `ca-certificates`.
- Fetches SSL passphrase from CyberArk Conjur via `conjur_variable(node['cyberark']['conjur']['variable'])` — variable path: `production/nginx/ssl_passphrase`, Conjur URL: `https://conjur.example.com`, account: `myorg`. This is a runtime call to the `cyberark-conjur` cookbook dependency.
- Creates group `ssl-cert`.
- Creates directory `/etc/ssl/certs` (owner: `root`, group: `root`, mode: `0755`).
- Creates directory `/etc/ssl/private` (owner: `root`, group: `ssl-cert`, mode: `0710`).
- Iterations: Runs 3 times for sites with `ssl_enabled: true` — **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - `execute[generate-ssl-cert-test.cluster.local]`: Runs `openssl req -x509 -days 365 -newkey rsa:2048` generating `/etc/ssl/private/test.cluster.local.key` and `/etc/ssl/certs/test.cluster.local.crt`. Subject: `/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=test.cluster.local/emailAddress=admin@example.com`. Sets key permissions `640`, ownership `root:ssl-cert`. Marked `sensitive true`. Guarded by `not_if { File.exist?(cert) && File.exist?(key) }`. Notifies nginx reload.
  - **ci.cluster.local**:
    - `execute[generate-ssl-cert-ci.cluster.local]`: Same openssl command generating `/etc/ssl/private/ci.cluster.local.key` and `/etc/ssl/certs/ci.cluster.local.crt`. Subject CN=`ci.cluster.local`. Guarded by file-existence check. Notifies nginx reload.
  - **status.cluster.local**:
    - `execute[generate-ssl-cert-status.cluster.local]`: Same openssl command generating `/etc/ssl/private/status.cluster.local.key` and `/etc/ssl/certs/status.cluster.local.crt`. Subject CN=`status.cluster.local`. Guarded by file-existence check. Notifies nginx reload.
- Resources: `package` (1, array of 2), `group` (1), `directory` (2), `execute` (3)

---

**5. sites** (`cookbooks/nginx-multisite/recipes/sites.rb`):
- Iterations: Runs 3 times for sites — **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - Deploys template `/etc/nginx/sites-available/test.cluster.local` from `site.conf.erb` (mode `0644`); notifies nginx reload.
      - Variables: `server_name=test.cluster.local`, `document_root=/opt/server/test`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/test.cluster.local.crt`, `key_file=/etc/ssl/private/test.cluster.local.key`.
      - Template renders: HTTP server block (port 80) with `return 301 https://...` redirect; HTTPS server block (port 443 ssl http2) with TLSv1.2/TLSv1.3, HSTS header, X-Frame-Options DENY, X-Content-Type-Options nosniff, X-XSS-Protection, Referrer-Policy, CSP, gzip, `try_files`, deny `.ht*` and `.git/.svn` locations. Access log: `/var/log/nginx/test.cluster.local_access.log`. Error log: `/var/log/nginx/test.cluster.local_error.log`.
    - Creates symlink `/etc/nginx/sites-enabled/test.cluster.local` → `/etc/nginx/sites-available/test.cluster.local`; notifies nginx reload.
  - **ci.cluster.local**:
    - Deploys template `/etc/nginx/sites-available/ci.cluster.local` from `site.conf.erb` (mode `0644`); notifies nginx reload.
      - Variables: `server_name=ci.cluster.local`, `document_root=/opt/server/ci`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/ci.cluster.local.crt`, `key_file=/etc/ssl/private/ci.cluster.local.key`.
    - Creates symlink `/etc/nginx/sites-enabled/ci.cluster.local` → `/etc/nginx/sites-available/ci.cluster.local`; notifies nginx reload.
  - **status.cluster.local**:
    - Deploys template `/etc/nginx/sites-available/status.cluster.local` from `site.conf.erb` (mode `0644`); notifies nginx reload.
      - Variables: `server_name=status.cluster.local`, `document_root=/opt/server/status`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/status.cluster.local.crt`, `key_file=/etc/ssl/private/status.cluster.local.key`.
    - Creates symlink `/etc/nginx/sites-enabled/status.cluster.local` → `/etc/nginx/sites-available/status.cluster.local`; notifies nginx reload.
- Deletes `/etc/nginx/sites-enabled/default` (removes the default Nginx placeholder site); notifies nginx reload.
- Resources: `template` (3), `link` (3), `file` (1)

---

## Custom Resources

### `ada_ada` (`cookbooks/nginx-multisite/resources/ada_ada.rb`)

**Description**: A custom in-place line editor for text configuration files. Given a file path, a target line string, and an optional regex match pattern, it reads the file, replaces the first line matching the pattern with the new line (or appends the line if no match is found). Optionally creates a timestamped `.backup.<epoch>` file before writing. If the file does not exist, it creates it with the given line as content.

**Properties**:
- `file_path` (String, name property): Path to the file to edit.
- `line` (String, required): The exact line to write/replace.
- `match` (String, optional): Ruby regex pattern; the first line matching this pattern is replaced.
- `backup` (Boolean, default: `true`): Whether to write a timestamped backup before modifying.

**Used in**: `recipes/security.rb` — twice, to patch `/etc/ssh/sshd_config`:
1. Set `PermitRootLogin no` (match: `^#\?PermitRootLogin`) when `node['security']['ssh']['disable_root']` is `true`.
2. Set `PasswordAuthentication no` (match: `^#\?PasswordAuthentication`) when `node['security']['ssh']['password_auth']` is `false`.

**Conversion outcome**: Use `ansible.builtin.lineinfile`. The `lineinfile` module natively supports regex-based line replacement (`regexp` parameter), appending if no match (`insertafter: EOF`), and is idempotent. Backup is handled via `backup: yes`.

```yaml
- name: Disable root SSH login
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?\s*PermitRootLogin'
    line: 'PermitRootLogin no'
    backup: yes
  notify: Restart ssh
  when: security_ssh_disable_root | bool

- name: Disable SSH password authentication
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?\s*PasswordAuthentication'
    line: 'PasswordAuthentication no'
    backup: yes
  notify: Restart ssh
  when: not security_ssh_password_auth | bool
```

---

### `fetch_token` (`cookbooks/nginx-multisite/resources/fetch_token.rb`)

**Description**: Makes an HTTPS POST request to an OAuth token endpoint with `client_id` and `client_secret` in a JSON body. Parses the JSON response and stores `access_token` in both the resource property and `node.run_state['access_token']`.

**Properties**:
- `auth_url` (String, required): Full URL of the OAuth token endpoint.
- `client_id` (String, required): OAuth client identifier.
- `client_secret` (String, required): OAuth client secret.
- `access_token` (String, output): Populated after a successful fetch.

**Action**: `:fetch` (non-default — must be explicitly called).

**Used in**: `recipes/security.rb` — called with `auth_url: 'https://auth.example.com/oauth/token'`, `client_id: 'nginx-multisite'`, `client_secret: 'sup3rs3cr3t'`.

**Conversion outcome**: No built-in Ansible module performs an OAuth client-credentials token fetch and stores the result in a play-scoped variable in the same way. Use `ansible.builtin.uri` for the HTTP call and `ansible.builtin.set_fact` to store the result. Since no downstream consumer of `node.run_state['access_token']` is visible in this cookbook, the Ansible developer must clarify whether the token is actually used before implementing.

```yaml
- name: Fetch OAuth access token
  ansible.builtin.uri:
    url: "https://auth.example.com/oauth/token"
    method: POST
    body_format: json
    body:
      client_id: "nginx-multisite"
      client_secret: "{{ oauth_client_secret }}"   # must come from AAP credential, NOT hardcoded
    return_content: yes
    status_code: 200
  register: oauth_token_response
  no_log: true

- name: Store access token as fact
  ansible.builtin.set_fact:
    access_token: "{{ oauth_token_response.json.access_token }}"
  no_log: true
```

**⚠️ Flag**: The `client_secret` is currently hardcoded as `sup3rs3cr3t` in the recipe. This MUST be replaced with an AAP credential or Conjur/Vault lookup before migration. Do not replicate the hardcoded value in Ansible.

---

### `fetch_and_parse_token` (`cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb`)

**Description**: Makes an HTTP GET request to a given URL, then searches the response body for a line matching the pattern `X-Header:<value>` and extracts the value after the colon. Stores the result in the resource property `extracted_token` and in `node.run_state['extracted_token']`. Raises an error if the pattern is not found.

**Properties**:
- `token_url` (String, required): URL to GET.
- `extracted_token` (String, output): Populated after successful parse.

**Action**: `:fetch_and_parse` (non-default — must be explicitly called).

**Used in**: `recipes/security.rb` — called with `token_url: 'https://api.example.com/token_endpoint'`.

**Conversion outcome**: Use `ansible.builtin.uri` for the HTTP GET, then `ansible.builtin.set_fact` with a `regex_search` filter to extract the value.

```yaml
- name: Fetch and parse token from API endpoint
  ansible.builtin.uri:
    url: "https://api.example.com/token_endpoint"
    method: GET
    return_content: yes
    status_code: 200
  register: token_response
  no_log: true

- name: Extract token from X-Header pattern
  ansible.builtin.set_fact:
    extracted_token: "{{ token_response.content | regex_search('X-Header:(.+)', '\\1') | first | trim }}"
  no_log: true

- name: Fail if token pattern not found
  ansible.builtin.fail:
    msg: "Failed to parse token pattern from response body."
  when: extracted_token is not defined or extracted_token == ''
```

**⚠️ Flag**: The downstream use of `extracted_token` is not visible in this cookbook. The Ansible developer must clarify with the Solutions Architect what subsequent tasks consume this value before deciding where to pass it.

---

## Dependencies

**External cookbook dependencies**:
- `cyberark-conjur ~> 3.0` — provides the `conjur_variable()` helper used in `recipes/ssl.rb` to retrieve the SSL passphrase at converge time.

**System package dependencies**:
- `nginx` — web server
- `fail2ban` — intrusion prevention / log-based banning
- `ufw` — Uncomplicated Firewall (iptables frontend)
- `openssl` — TLS certificate generation
- `ca-certificates` — CA bundle

**Service dependencies**:
- `nginx` — managed: enabled + started; reloaded on config/cert/vhost changes
- `fail2ban` — managed: enabled + started; restarted on jail.local changes
- `ssh` (sshd) — managed: restarted only when sshd_config is patched

---

## Credentials

**Detection Summary**: 3 credentials detected across 3 files.

---

### SSL Certificate Passphrase

- **Variable(s)**: `ssl_passphrase` (local variable in `recipes/ssl.rb`); `node['cyberark']['conjur']['variable']` = `'production/nginx/ssl_passphrase'`; `node['cyberark']['conjur']['appliance_url']` = `'https://conjur.example.com'`; `node['cyberark']['conjur']['account']` = `'myorg'`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/ssl.rb`, `cookbooks/nginx-multisite/attributes/default.rb`
- **Current storage**: CyberArk Conjur — fetched at runtime via `conjur_variable()` helper from the `cyberark-conjur` cookbook
- **Usage context**: Passed as `-passout pass:<value>` to `openssl req` when generating self-signed TLS private keys for all three sites. The `execute` resources are marked `sensitive true` to suppress the passphrase from Chef logs.

**Source**:
- **Provider**: CyberArk Conjur
- **URL**: `https://conjur.example.com`
- **Path**: `production/nginx/ssl_passphrase`

---

### OAuth Client Secret (fetch_token)

- **Variable(s)**: `client_secret` property on `fetch_token['get auth token']` resource
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb`
- **Current storage**: **Hardcoded** — the literal string `sup3rs3cr3t` is written directly in the recipe source code
- **Usage context**: Sent as the `client_secret` field in a JSON POST body to `https://auth.example.com/oauth/token` to obtain an OAuth access token. The token is stored in `node.run_state['access_token']` for potential downstream use within the same Chef run. **This credential must be moved to a secrets manager (Conjur, Vault, or AAP credential) before migration.**

**Source**:
- **Provider**: Hardcoded (must be remediated before migration)
- **URL**: `https://auth.example.com/oauth/token`
- **Path**: None — literal value in recipe source

---

### Parsed Token from External API (fetch_and_parse_token)

- **Variable(s)**: `extracted_token` property on `fetch_and_parse_token['get parsed token']` resource; `node.run_state['extracted_token']`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb`
- **Current storage**: Retrieved at runtime from `https://api.example.com/token_endpoint` by parsing an `X-Header:<value>` pattern from the HTTP response body. No credential is stored statically, but the endpoint itself may require authentication (not visible in source).
- **Usage context**: The parsed token value is stored in `node.run_state['extracted_token']`. It is not consumed by any subsequent resource visible in this cookbook — its downstream use is unknown. The Solutions Architect must clarify what this token is used for and whether the endpoint requires authentication headers.

**Source**:
- **Provider**: Unknown/External HTTP API
- **URL**: `https://api.example.com/token_endpoint`
- **Path**: None — value parsed from HTTP response body at runtime

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
- `/etc/nginx/sites-enabled/default` (must NOT exist)

*Document roots and static files:*
- `/opt/server/test/index.html`
- `/opt/server/ci/index.html`
- `/opt/server/status/index.html`

*TLS certificates and keys:*
- `/etc/ssl/certs/test.cluster.local.crt`
- `/etc/ssl/private/test.cluster.local.key`
- `/etc/ssl/certs/ci.cluster.local.crt`
- `/etc/ssl/private/ci.cluster.local.key`
- `/etc/ssl/certs/status.cluster.local.crt`
- `/etc/ssl/private/status.cluster.local.key`

*Security configuration:*
- `/etc/fail2ban/jail.local`
- `/etc/sysctl.d/99-security.conf`
- `/etc/ssh/sshd_config`

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
- Port 80 (HTTP redirect only) — all three hostnames
- Port 443 (HTTPS) — all three hostnames
- Unix sockets: none
- Network interfaces: all interfaces (`0.0.0.0:80` and `0.0.0.0:443`)

**Templates rendered**:
- `nginx.conf.erb` → `/etc/nginx/nginx.conf` — rendered **1 time**
- `security.conf.erb` → `/etc/nginx/conf.d/security.conf` — rendered **1 time**
- `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` — rendered **1 time**
- `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` — rendered **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/test.cluster.local` — rendered **1 time** (iteration item 1)
- `site.conf.erb` → `/etc/nginx/sites-available/ci.cluster.local` — rendered **1 time** (iteration item 2)
- `site.conf.erb` → `/etc/nginx/sites-available/status.cluster.local` — rendered **1 time** (iteration item 3)

Total template renders: **7**

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
ps aux | grep fail2ban

# ============================================================
# NGINX CONFIGURATION SYNTAX
# ============================================================
nginx -t
nginx -T | grep -E 'server_name|listen|ssl_certificate|root'

# ============================================================
# UFW FIREWALL STATUS
# ============================================================
ufw status verbose
# Expected: Status: active; rules for 22/tcp, 80/tcp, 443/tcp; default: deny

# ============================================================
# SYSCTL SECURITY PARAMETERS
# ============================================================
sysctl net.ipv4.conf.all.rp_filter
sysctl net.ipv4.tcp_syncookies
sysctl net.ipv6.conf.all.disable_ipv6
# Expected: rp_filter=1, tcp_syncookies=1, disable_ipv6=1

# ============================================================
# SSH HARDENING
# ============================================================
grep -E '^PermitRootLogin|^PasswordAuthentication' /etc/ssh/sshd_config
# Expected: PermitRootLogin no
# Expected: PasswordAuthentication no

# ============================================================
# FAIL2BAN JAILS
# ============================================================
fail2ban-client status
fail2ban-client status sshd
fail2ban-client status nginx-http-auth
fail2ban-client status nginx-limit-req
fail2ban-client status nginx-botsearch
cat
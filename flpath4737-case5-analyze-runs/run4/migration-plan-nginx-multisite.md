---
source-path: .
---

# Migration Plan: nginx-multisite

**TLDR**: This cookbook configures an nginx web server hosting three SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) on a single node. It hardens the host with fail2ban, UFW firewall rules, and kernel-level sysctl security parameters, then generates self-signed TLS certificates for each site using a passphrase fetched from CyberArk Conjur. Each site gets its own document root, static `index.html`, nginx vhost configuration with HTTP→HTTPS redirect, security headers, and per-site access/error logs. Two additional custom resources (`fetch_token`, `fetch_and_parse_token`) perform OAuth token retrieval during the security recipe run.

---

## Service Type and Instances

**Service Type**: Web Server (nginx multi-site with TLS)

**Configured Instances**:

- **test.cluster.local**: Static site served over HTTPS
  - Location/Path: `/opt/server/test`
  - Port/Socket: 80 (HTTP→HTTPS redirect), 443 (HTTPS/TLS)
  - SSL Certificate: `/etc/ssl/certs/test.cluster.local.crt`
  - SSL Private Key: `/etc/ssl/private/test.cluster.local.key`
  - Key Config: `ssl_enabled: true`, self-signed cert (365 days, RSA 2048), TLSv1.2+TLSv1.3 only
  - Logs: `/var/log/nginx/test.cluster.local_access.log`, `/var/log/nginx/test.cluster.local_error.log`

- **ci.cluster.local**: Static site served over HTTPS
  - Location/Path: `/opt/server/ci`
  - Port/Socket: 80 (HTTP→HTTPS redirect), 443 (HTTPS/TLS)
  - SSL Certificate: `/etc/ssl/certs/ci.cluster.local.crt`
  - SSL Private Key: `/etc/ssl/private/ci.cluster.local.key`
  - Key Config: `ssl_enabled: true`, self-signed cert (365 days, RSA 2048), TLSv1.2+TLSv1.3 only
  - Logs: `/var/log/nginx/ci.cluster.local_access.log`, `/var/log/nginx/ci.cluster.local_error.log`

- **status.cluster.local**: Static site served over HTTPS
  - Location/Path: `/opt/server/status`
  - Port/Socket: 80 (HTTP→HTTPS redirect), 443 (HTTPS/TLS)
  - SSL Certificate: `/etc/ssl/certs/status.cluster.local.crt`
  - SSL Private Key: `/etc/ssl/private/status.cluster.local.key`
  - Key Config: `ssl_enabled: true`, self-signed cert (365 days, RSA 2048), TLSv1.2+TLSv1.3 only
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
- Installs packages: `fail2ban`, `ufw` (single `package` resource with array `%w[fail2ban ufw]`)
- Enables and starts the `fail2ban` service
- Deploys `/etc/fail2ban/jail.local` from `fail2ban.jail.local.erb`
  - Template configures five jails: `[DEFAULT]` (bantime=3600, findtime=600, maxretry=3), `[sshd]` (enabled, logpath=/var/log/auth.log), `[nginx-http-auth]` (enabled, logpath=/var/log/nginx/*error.log), `[nginx-limit-req]` (enabled, maxretry=10), `[nginx-botsearch]` (enabled, logpath=/var/log/nginx/*access.log)
  - Notifies: `:restart` on `service[fail2ban]` (delayed)
- Runs `execute[ufw_default_deny]`: `ufw --force default deny` (guarded: skips if already "Default: deny")
- Runs `execute[ufw_allow_ssh]`: `ufw allow ssh` (guarded: skips if 22/tcp already present)
- Runs `execute[ufw_allow_http]`: `ufw allow http` (guarded: skips if 80/tcp already present)
- Runs `execute[ufw_allow_https]`: `ufw allow https` (guarded: skips if 443/tcp already present)
- Runs `execute[ufw_enable]`: `ufw --force enable` (guarded: skips if already "Status: active")
- Uses custom resource `fetch_token['get auth token']`:
  - `auth_url`: `https://auth.example.com/oauth/token`
  - `client_id`: `nginx-multisite`
  - `client_secret`: `sup3rs3cr3t` (**hardcoded secret — see Credentials section**)
- Uses custom resource `fetch_and_parse_token['get parsed token']`:
  - `token_url`: `https://api.example.com/token_endpoint`
- Deploys `/etc/sysctl.d/99-security.conf` from `sysctl-security.conf.erb`
  - Template sets: IP spoofing protection (`rp_filter=1`), ICMP redirect ignore, send redirect disable, source routing disable, martian logging, ICMP ping ignore (`icmp_echo_ignore_all=1`), IPv6 disable, TCP SYN flood protection (`tcp_syncookies=1`, `tcp_max_syn_backlog=2048`)
  - Notifies: `:run` on `execute[reload_sysctl]` (delayed)
- Runs `execute[reload_sysctl]`: `sysctl -p /etc/sysctl.d/99-security.conf` (action `:nothing`, triggered by template notify)
- Conditional: `node['security']['ssh']['disable_root']` is `true` → uses `ada_ada['/etc/ssh/sshd_config']`
  - Sets line `PermitRootLogin no`, matching pattern `^#\?PermitRootLogin`
  - Notifies: `:restart` on `service[ssh]` (delayed)
- Conditional: `node['security']['ssh']['password_auth']` is `false` → uses `ada_ada['/etc/ssh/sshd_config']`
  - Sets line `PasswordAuthentication no`, matching pattern `^#\?PasswordAuthentication`
  - Notifies: `:restart` on `service[ssh]` (delayed)
- Declares `service[ssh]` with action `:nothing` (only restarted via notify from ada_ada resources)
- Resources: package (1), service/fail2ban (1), template (2), execute (6), fetch_token (1), fetch_and_parse_token (1), ada_ada (2), service/ssh (1)

---

**3. nginx** (`cookbooks/nginx-multisite/recipes/nginx.rb`):
- Installs package: `nginx`
- Deploys `/etc/nginx/nginx.conf` from `nginx.conf.erb`
  - Template sets: `user www-data`, `worker_processes auto`, `worker_connections 768`, sendfile/tcp_nopush/tcp_nodelay on, `keepalive_timeout 65`, gzip on, includes `/etc/nginx/conf.d/*.conf` and `/etc/nginx/sites-enabled/*`
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Deploys `/etc/nginx/conf.d/security.conf` from `security.conf.erb`
  - Template sets: `server_tokens off`, rate-limit zones (`login:10m rate=10r/m`, `api:10m rate=30r/m`), client buffer limits (body=1K, header=1k, max_body=1k), timeouts (body/header/send=10s), global SSL settings (TLSv1.2+TLSv1.3, strong cipher suite, session cache 10m)
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Enables and starts `service[nginx]`
- Iterations: Runs 3 times for sites:
  - **test.cluster.local**:
    - Creates directory `/opt/server/test` (owner: www-data, group: www-data, mode: 0755, recursive)
    - Deploys static file `/opt/server/test/index.html` from cookbook source `test/index.html` (owner: www-data, group: www-data, mode: 0644)
  - **ci.cluster.local**:
    - Creates directory `/opt/server/ci` (owner: www-data, group: www-data, mode: 0755, recursive)
    - Deploys static file `/opt/server/ci/index.html` from cookbook source `ci/index.html` (owner: www-data, group: www-data, mode: 0644)
  - **status.cluster.local**:
    - Creates directory `/opt/server/status` (owner: www-data, group: www-data, mode: 0755, recursive)
    - Deploys static file `/opt/server/status/index.html` from cookbook source `status/index.html` (owner: www-data, group: www-data, mode: 0644)
- Resources: package (1), template (2), service (1), directory (3), cookbook_file (3)

---

**4. ssl** (`cookbooks/nginx-multisite/recipes/ssl.rb`):
- Installs packages: `openssl`, `ca-certificates`
- Fetches SSL passphrase from CyberArk Conjur using `conjur_variable(node['cyberark']['conjur']['variable'])` — variable path: `production/nginx/ssl_passphrase`, Conjur URL: `https://conjur.example.com`, account: `myorg` (**see Credentials section**)
- Creates group `ssl-cert`
- Creates directory `/etc/ssl/certs` (owner: root, group: root, mode: 0755)
- Creates directory `/etc/ssl/private` (owner: root, group: ssl-cert, mode: 0710)
- Iterations: Runs 3 times for sites with ssl_enabled=true:
  - **test.cluster.local**:
    - Runs `execute[generate-ssl-cert-test.cluster.local]` (sensitive: true, guarded: skips if `/etc/ssl/certs/test.cluster.local.crt` AND `/etc/ssl/private/test.cluster.local.key` both exist)
    - Command: `openssl req -x509 -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/test.cluster.local.key -out /etc/ssl/certs/test.cluster.local.crt -passout pass:<conjur_passphrase> -subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=test.cluster.local/emailAddress=admin@example.com"` then `chmod 640` key and `chown root:ssl-cert` key
    - Notifies: `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - Runs `execute[generate-ssl-cert-ci.cluster.local]` (sensitive: true, guarded: skips if `/etc/ssl/certs/ci.cluster.local.crt` AND `/etc/ssl/private/ci.cluster.local.key` both exist)
    - Command: same openssl invocation with CN=ci.cluster.local
    - Notifies: `:reload` on `service[nginx]` (delayed)
  - **status.cluster.local**:
    - Runs `execute[generate-ssl-cert-status.cluster.local]` (sensitive: true, guarded: skips if `/etc/ssl/certs/status.cluster.local.crt` AND `/etc/ssl/private/status.cluster.local.key` both exist)
    - Command: same openssl invocation with CN=status.cluster.local
    - Notifies: `:reload` on `service[nginx]` (delayed)
- Resources: package (1), group (1), directory (2), execute (3)

---

**5. sites** (`cookbooks/nginx-multisite/recipes/sites.rb`):
- Iterations: Runs 3 times for sites:
  - **test.cluster.local**:
    - Deploys `/etc/nginx/sites-available/test.cluster.local` from `site.conf.erb`
      - Variables: `server_name=test.cluster.local`, `document_root=/opt/server/test`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/test.cluster.local.crt`, `key_file=/etc/ssl/private/test.cluster.local.key`
      - Template renders: HTTP server block (port 80, 301 redirect to HTTPS) + HTTPS server block (port 443 ssl http2, TLSv1.2+TLSv1.3, HSTS, security headers: X-Frame-Options DENY, X-Content-Type-Options nosniff, X-XSS-Protection, Referrer-Policy, CSP)
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - Creates symlink `/etc/nginx/sites-enabled/test.cluster.local` → `/etc/nginx/sites-available/test.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - Deploys `/etc/nginx/sites-available/ci.cluster.local` from `site.conf.erb`
      - Variables: `server_name=ci.cluster.local`, `document_root=/opt/server/ci`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/ci.cluster.local.crt`, `key_file=/etc/ssl/private/ci.cluster.local.key`
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - Creates symlink `/etc/nginx/sites-enabled/ci.cluster.local` → `/etc/nginx/sites-available/ci.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **status.cluster.local**:
    - Deploys `/etc/nginx/sites-available/status.cluster.local` from `site.conf.erb`
      - Variables: `server_name=status.cluster.local`, `document_root=/opt/server/status`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/status.cluster.local.crt`, `key_file=/etc/ssl/private/status.cluster.local.key`
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - Creates symlink `/etc/nginx/sites-enabled/status.cluster.local` → `/etc/nginx/sites-available/status.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
- Deletes `/etc/nginx/sites-enabled/default` (removes the default nginx placeholder site)
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Resources: template (3), link (3), file (1)

---

## Custom Resources

### `ada_ada` (`cookbooks/nginx-multisite/resources/ada_ada.rb`)

**Description**: A line-in-file editor. Given a file path, a target line string, and an optional regex match pattern, it either replaces the first matching line in the file with the new line, or appends the line if no match is found. Optionally creates a timestamped `.backup.<epoch>` file before modifying. If the file does not exist, it creates it with the line as content.

**Properties**: `file_path` (String, name property), `line` (String, required), `match` (String, regex pattern), `backup` (Boolean, default: true)

**Used in**: `cookbooks/nginx-multisite/recipes/security.rb` — twice:
1. Sets `PermitRootLogin no` in `/etc/ssh/sshd_config` (when `node['security']['ssh']['disable_root']` is true)
2. Sets `PasswordAuthentication no` in `/etc/ssh/sshd_config` (when `node['security']['ssh']['password_auth']` is false)

**Ansible equivalent**: `ansible.builtin.lineinfile`

| ada_ada property | ansible.builtin.lineinfile parameter |
|---|---|
| `file_path` (name property) | `path` |
| `line` | `line` |
| `match` (Ruby regex string) | `regexp` |
| `backup: true` (default) | `backup: true` |
| action `:create` | `state: present` |

```yaml
- name: Disable root SSH login
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?\s*PermitRootLogin'
    line: 'PermitRootLogin no'
    backup: true
  notify: Restart ssh
  when: security_ssh_disable_root | bool

- name: Disable SSH password authentication
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?\s*PasswordAuthentication'
    line: 'PasswordAuthentication no'
    backup: true
  notify: Restart ssh
  when: not security_ssh_password_auth | bool
```

---

### `fetch_token` (`cookbooks/nginx-multisite/resources/fetch_token.rb`)

**Description**: Performs an HTTP POST to an OAuth2 token endpoint with `client_id` and `client_secret` as a JSON body. Parses the JSON response and stores `access_token` in `node.run_state['access_token']` and in the resource's `access_token` property.

**Properties**: `auth_url` (String, required), `client_id` (String, required), `client_secret` (String, required), `access_token` (String, output)

**Used in**: `cookbooks/nginx-multisite/recipes/security.rb` — called once with `auth_url: 'https://auth.example.com/oauth/token'`, `client_id: 'nginx-multisite'`, `client_secret: 'sup3rs3cr3t'`

**Ansible equivalent**: `ansible.builtin.uri`

```yaml
- name: Fetch OAuth access token
  ansible.builtin.uri:
    url: "https://auth.example.com/oauth/token"
    method: POST
    body_format: json
    body:
      client_id: "nginx-multisite"
      client_secret: "{{ oauth_client_secret }}"   # from Ansible Vault / AAP credential
    return_content: true
    status_code: 200
  register: oauth_token_response
  no_log: true
# Token available as: oauth_token_response.json.access_token
```

> ⚠️ **Important**: The `client_secret` value `sup3rs3cr3t` is currently hardcoded in `recipes/security.rb`. This MUST be stored in Ansible Vault or an AAP credential type before migration. The downstream consumer of the token is not visible in this cookbook — confirm with the application team whether the token is actually needed and what uses it.

---

### `fetch_and_parse_token` (`cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb`)

**Description**: Performs an HTTP GET to a token URL. Scans the response body for a line matching the pattern `X-Header:<value>` and extracts the value after the colon. Stores the result in `node.run_state['extracted_token']` and the resource's `extracted_token` property. Raises an error if the pattern is not found.

**Properties**: `token_url` (String, required), `extracted_token` (String, output)

**Used in**: `cookbooks/nginx-multisite/recipes/security.rb` — called once with `token_url: 'https://api.example.com/token_endpoint'`

**Ansible equivalent**: `ansible.builtin.uri` + `ansible.builtin.set_fact`

```yaml
- name: Fetch and parse token from API endpoint
  ansible.builtin.uri:
    url: "https://api.example.com/token_endpoint"
    method: GET
    return_content: true
    status_code: 200
  register: parsed_token_response
  no_log: true

- name: Extract token from X-Header line
  ansible.builtin.set_fact:
    extracted_token: "{{ parsed_token_response.content | regex_search('X-Header:(.+)', '\\1') | first | trim }}"
  when: parsed_token_response.content is search('X-Header:')

- name: Fail if token pattern not found
  ansible.builtin.fail:
    msg: "Failed to parse token pattern from response body."
  when: parsed_token_response.content is not search('X-Header:')
```

> ⚠️ **Important**: The downstream consumer of `extracted_token` is not visible in this cookbook. Confirm with the application team what this token is used for before deciding whether to include this task in the Ansible role.

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
- `nginx` (enabled + started; reloaded on config/cert/site changes)
- `fail2ban` (enabled + started; restarted on jail.local changes)
- `ssh` (restarted only when sshd_config is modified by ada_ada)

---

## Credentials

**Detection Summary**: 3 credentials detected across 3 files

**Source**:
- **Provider**: CyberArk Conjur (for SSL passphrase); Hardcoded (for OAuth client secret); Runtime HTTP endpoint (for parsed token)
- **URL**: `https://conjur.example.com` (Conjur appliance URL)
- **Path**: `production/nginx/ssl_passphrase` (Conjur variable path)

---

### SSL Certificate Passphrase

- **Variable(s)**: `ssl_passphrase` (local Ruby variable), `node['cyberark']['conjur']['variable']` (path: `production/nginx/ssl_passphrase`), `node['cyberark']['conjur']['appliance_url']`, `node['cyberark']['conjur']['account']`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/ssl.rb`, `cookbooks/nginx-multisite/attributes/default.rb`
- **Current storage**: CyberArk Conjur vault — fetched at converge time via `conjur_variable()` helper from the `cyberark-conjur` cookbook dependency
- **Usage context**: Passed as `-passout pass:<value>` to `openssl req` when generating self-signed certificates for all three sites. The `execute` resource is marked `sensitive true` to suppress the passphrase from Chef logs.

---

### OAuth Client Secret (fetch_token)

- **Variable(s)**: `client_secret` property on `fetch_token` resource
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb`, `cookbooks/nginx-multisite/resources/fetch_token.rb`
- **Current storage**: **Hardcoded** — the literal string `sup3rs3cr3t` is written directly in `recipes/security.rb` as `client_secret 'sup3rs3cr3t'`
- **Usage context**: Used by the `fetch_token` custom resource to POST an OAuth2 client-credentials request to `https://auth.example.com/oauth/token`. The resulting `access_token` is stored in `node.run_state['access_token']`. No downstream resource in this cookbook reads `node.run_state['access_token']`, but the token fetch still executes.

---

### Parsed Token (fetch_and_parse_token)

- **Variable(s)**: `extracted_token` property on `fetch_and_parse_token` resource; `node.run_state['extracted_token']`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb`, `cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb`
- **Current storage**: Fetched at runtime from `https://api.example.com/token_endpoint` — the resource performs an HTTP GET and extracts a value from the `X-Header:` line in the response body
- **Usage context**: The parsed token is stored in `node.run_state['extracted_token']`. No downstream recipe resource in this cookbook consumes the stored value. The endpoint URL is not sensitive itself, but the extracted token value may be.

---

## Checks for the Migration

**Files to verify**:
- `/etc/nginx/nginx.conf` — main nginx configuration
- `/etc/nginx/conf.d/security.conf` — global security directives
- `/etc/nginx/sites-available/test.cluster.local` — vhost config for test site
- `/etc/nginx/sites-available/ci.cluster.local` — vhost config for ci site
- `/etc/nginx/sites-available/status.cluster.local` — vhost config for status site
- `/etc/nginx/sites-enabled/test.cluster.local` — symlink to sites-available
- `/etc/nginx/sites-enabled/ci.cluster.local` — symlink to sites-available
- `/etc/nginx/sites-enabled/status.cluster.local` — symlink to sites-available
- `/etc/nginx/sites-enabled/default` — must NOT exist (deleted)
- `/opt/server/test/index.html` — static content for test site
- `/opt/server/ci/index.html` — static content for ci site
- `/opt/server/status/index.html` — static content for status site
- `/etc/ssl/certs/test.cluster.local.crt` — TLS certificate
- `/etc/ssl/certs/ci.cluster.local.crt` — TLS certificate
- `/etc/ssl/certs/status.cluster.local.crt` — TLS certificate
- `/etc/ssl/private/test.cluster.local.key` — TLS private key (mode 640, owner root:ssl-cert)
- `/etc/ssl/private/ci.cluster.local.key` — TLS private key (mode 640, owner root:ssl-cert)
- `/etc/ssl/private/status.cluster.local.key` — TLS private key (mode 640, owner root:ssl-cert)
- `/etc/fail2ban/jail.local` — fail2ban jail configuration
- `/etc/sysctl.d/99-security.conf` — kernel security parameters
- `/etc/ssh/sshd_config` — SSH daemon configuration (PermitRootLogin no, PasswordAuthentication no)

**Service endpoints to check**:
- Ports listening: 80 (HTTP, all three sites — redirect only), 443 (HTTPS, all three sites)
- Unix sockets: none
- Network interfaces: all interfaces (nginx listens on `0.0.0.0:80` and `0.0.0.0:443`)

**Templates rendered**:
- `nginx.conf.erb` → `/etc/nginx/nginx.conf` — rendered **1 time**
- `security.conf.erb` → `/etc/nginx/conf.d/security.conf` — rendered **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/<site_name>` — rendered **3 times** (test.cluster.local, ci.cluster.local, status.cluster.local)
- `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` — rendered **1 time**
- `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` — rendered **1 time**

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

# Confirm default site is removed
ls /etc/nginx/sites-enabled/default
# Expected: No such file or directory

# ============================================================
# SITE: test.cluster.local
# ============================================================

# HTTP redirect check (should return 301 to https)
curl -I http://test.cluster.local
# Expected: HTTP/1.1 301 Moved Permanently
# Expected: Location: https://test.cluster.local/

# HTTPS response check (self-signed cert, use -k)
curl -k -I https://test.cluster.local
# Expected: HTTP/1.1 200 OK

# Security headers check
curl -k -s -D - https://test.cluster.local -o /dev/null | grep -E 'Strict-Transport-Security|X-Frame-Options|X-Content-Type-Options|X-XSS-Protection|Referrer-Policy|Content-Security-Policy'
# Expected: all 5 headers present

# Document root and static file
ls -lah /opt/server/test/index.html
stat -c "%U %G %a" /opt/server/test/index.html
# Expected: www-data www-data 644

# vhost config
grep -E 'server_name|listen|ssl_certificate|root|return 301' /etc/nginx/sites-available/test.cluster.local
ls -la /etc/nginx/sites-enabled/test.cluster.local
# Expected: symlink → /etc/nginx/sites-available/test.cluster.local

# TLS certificate
ls -lah /etc/ssl/certs/test.cluster.local.crt
openssl x509 -in /etc/ssl/certs/test.cluster.local.crt -noout -subject -dates -issuer
# Expected: CN=test.cluster.local, notAfter ~365 days from issue

ls -lah /etc/ssl/private/test.cluster.local.key
stat -c "%U %G %a" /etc/ssl/private/test.cluster.local.key
# Expected: root ssl-cert 640

# Per-site logs
ls -lah /var/log/nginx/test.cluster.local_access.log
ls -lah /var/log/nginx/test.cluster.local_error.log
tail -5 /var/log/nginx/test.cluster.local_error.log

# ============================================================
# SITE: ci.cluster.local
# ============================================================

# HTTP redirect check (should return 301 to https)
curl -I http://ci.cluster.local
# Expected: HTTP/1.1 301 Moved Permanently
# Expected: Location: https://ci.cluster.local/

# HTTPS response check
curl -k -I https://ci.cluster.local
# Expected: HTTP/1.1 200 OK

# Security headers check
curl -k -s -D - https://ci.cluster.local -o /dev/null | grep -E
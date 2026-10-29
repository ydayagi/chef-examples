---
source-path: .
---

# Migration Plan: nginx-multisite

**TLDR**: This cookbook configures an nginx web server hosting 3 SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) on a single node. It hardens the host with UFW firewall rules, fail2ban intrusion prevention, and kernel-level sysctl security parameters. Self-signed TLS certificates are generated per-site using an SSL passphrase fetched from CyberArk Conjur. The cookbook also uses three custom resources: `ada_ada` (in-place file line editor), `fetch_token` (OAuth2 token fetcher with a hardcoded client secret), and `fetch_and_parse_token` (HTTP response header parser). All three sites have SSL enabled and serve static HTML index pages from `/opt/server/<site-prefix>/`.

---

## Service Type and Instances

**Service Type**: Web Server (nginx with multi-site virtual hosting)

**Configured Instances**:

- **test.cluster.local**: Test/development environment virtual host
  - Location/Path: Document root `/opt/server/test`
  - Port/Socket: HTTP 80 (redirects to HTTPS), HTTPS 443
  - SSL: Enabled — certificate `/etc/ssl/certs/test.cluster.local.crt`, key `/etc/ssl/private/test.cluster.local.key`
  - Static file deployed: `files/default/test/index.html` → `/opt/server/test/index.html`
  - Key Config: TLSv1.2/TLSv1.3 only, HSTS enabled, security headers (X-Frame-Options DENY, X-Content-Type-Options, X-XSS-Protection, CSP)

- **ci.cluster.local**: CI/CD dashboard virtual host
  - Location/Path: Document root `/opt/server/ci`
  - Port/Socket: HTTP 80 (redirects to HTTPS), HTTPS 443
  - SSL: Enabled — certificate `/etc/ssl/certs/ci.cluster.local.crt`, key `/etc/ssl/private/ci.cluster.local.key`
  - Static file deployed: `files/default/ci/index.html` → `/opt/server/ci/index.html`
  - Key Config: TLSv1.2/TLSv1.3 only, HSTS enabled, security headers (X-Frame-Options DENY, X-Content-Type-Options, X-XSS-Protection, CSP)

- **status.cluster.local**: System status/monitoring virtual host
  - Location/Path: Document root `/opt/server/status`
  - Port/Socket: HTTP 80 (redirects to HTTPS), HTTPS 443
  - SSL: Enabled — certificate `/etc/ssl/certs/status.cluster.local.crt`, key `/etc/ssl/private/status.cluster.local.key`
  - Static file deployed: `files/default/status/index.html` → `/opt/server/status/index.html`
  - Key Config: TLSv1.2/TLSv1.3 only, HSTS enabled, security headers (X-Frame-Options DENY, X-Content-Type-Options, X-XSS-Protection, CSP)

---

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
- Installs packages: `fail2ban`, `ufw` (single `package` resource with array argument)
- Enables and starts the `fail2ban` service
- Deploys `/etc/fail2ban/jail.local` from `fail2ban.jail.local.erb`
  - Template: `cookbooks/nginx-multisite/templates/default/fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` (mode 0644)
  - Notifies: `:restart` on `service[fail2ban]` (delayed)
  - Configures 5 jails: `[DEFAULT]` (bantime=3600, findtime=600, maxretry=3), `[sshd]` (enabled, logpath=/var/log/auth.log), `[nginx-http-auth]` (enabled, port=http,https, logpath=/var/log/nginx/*error.log), `[nginx-limit-req]` (enabled, maxretry=10), `[nginx-botsearch]` (enabled, logpath=/var/log/nginx/*access.log, maxretry=2)
- Configures UFW firewall with 5 idempotent `execute` resources (each guarded by `not_if`):
  - `ufw_default_deny`: `ufw --force default deny` (skipped if already "Default: deny")
  - `ufw_allow_ssh`: `ufw allow ssh` (skipped if 22/tcp already present)
  - `ufw_allow_http`: `ufw allow http` (skipped if 80/tcp already present)
  - `ufw_allow_https`: `ufw allow https` (skipped if 443/tcp already present)
  - `ufw_enable`: `ufw --force enable` (skipped if "Status: active")
- Uses custom resource `fetch_token['get auth token']`:
  - `auth_url`: `https://auth.example.com/oauth/token`
  - `client_id`: `nginx-multisite`
  - `client_secret`: `sup3rs3cr3t` (**hardcoded secret — see Credentials section**)
  - Stores result in `node.run_state['access_token']`
- Uses custom resource `fetch_and_parse_token['get parsed token']`:
  - `token_url`: `https://api.example.com/token_endpoint`
  - Parses `X-Header:` line from HTTP response body
  - Stores result in `node.run_state['extracted_token']`
- Deploys `/etc/sysctl.d/99-security.conf` from `sysctl-security.conf.erb`
  - Template: `cookbooks/nginx-multisite/templates/default/sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` (mode 0644)
  - Notifies: `:run` on `execute[reload_sysctl]` (delayed)
  - Sets 18 kernel parameters: IP spoofing protection (`rp_filter=1`), ICMP redirect ignore, send redirect disable, source routing disable, martian logging, ICMP ping ignore (`icmp_echo_ignore_all=1`), broadcast ping ignore, IPv6 disable, TCP SYN cookie protection (`tcp_syncookies=1`, `tcp_max_syn_backlog=2048`, `tcp_synack_retries=2`, `tcp_syn_retries=5`)
- `execute[reload_sysctl]`: `sysctl -p /etc/sysctl.d/99-security.conf` (action `:nothing`, triggered by template notify)
- Conditionally modifies `/etc/ssh/sshd_config` using `ada_ada` custom resource:
  - If `node['security']['ssh']['disable_root']` is `true` (default: true):
    - `ada_ada '/etc/ssh/sshd_config'`: sets `PermitRootLogin no`, matches pattern `^#\?PermitRootLogin`, notifies `:restart` on `service[ssh]`
  - If `node['security']['ssh']['password_auth']` is `false` (default: false):
    - `ada_ada '/etc/ssh/sshd_config'`: sets `PasswordAuthentication no`, matches pattern `^#\?PasswordAuthentication`, notifies `:restart` on `service[ssh]`
- `service 'ssh'`: action `:nothing` (only restarted via notify from `ada_ada` resources)
- Resources: package (1), service (2), template (2), execute (6), fetch_token (1), fetch_and_parse_token (1), ada_ada (2)

---

**3. nginx** (`cookbooks/nginx-multisite/recipes/nginx.rb`):
- Installs package: `nginx`
- Deploys `/etc/nginx/nginx.conf` from `nginx.conf.erb`
  - Template: `cookbooks/nginx-multisite/templates/default/nginx.conf.erb` → `/etc/nginx/nginx.conf` (mode 0644)
  - Config: user=www-data, worker_processes=auto, worker_connections=768, gzip=on, access_log=/var/log/nginx/access.log, error_log=/var/log/nginx/error.log, includes `/etc/nginx/conf.d/*.conf` and `/etc/nginx/sites-enabled/*`
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Deploys `/etc/nginx/conf.d/security.conf` from `security.conf.erb`
  - Template: `cookbooks/nginx-multisite/templates/default/security.conf.erb` → `/etc/nginx/conf.d/security.conf` (mode 0644)
  - Config: server_tokens off, rate limiting zones (login: 10r/m / 10MB, api: 30r/m / 10MB), buffer overflow protection (client_body_buffer_size=1K, client_header_buffer_size=1k, client_max_body_size=1k, large_client_header_buffers=2 1k), timeouts (body/header/send=10s), global SSL settings (TLSv1.2/TLSv1.3, ECDHE ciphers, session cache 10m)
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Enables and starts `nginx` service (supports restart, reload, status)
- Iterations — runs 3 times for sites: `test.cluster.local`, `ci.cluster.local`, `status.cluster.local`:
  - **test.cluster.local**:
    - `directory '/opt/server/test'`: owner=www-data, group=www-data, mode=0755, recursive=true
    - `cookbook_file '/opt/server/test/index.html'`: source=`test/index.html`, owner=www-data, group=www-data, mode=0644
  - **ci.cluster.local**:
    - `directory '/opt/server/ci'`: owner=www-data, group=www-data, mode=0755, recursive=true
    - `cookbook_file '/opt/server/ci/index.html'`: source=`ci/index.html`, owner=www-data, group=www-data, mode=0644
  - **status.cluster.local**:
    - `directory '/opt/server/status'`: owner=www-data, group=www-data, mode=0755, recursive=true
    - `cookbook_file '/opt/server/status/index.html'`: source=`status/index.html`, owner=www-data, group=www-data, mode=0644
- Resources: package (1), template (2), service (1), directory (3), cookbook_file (3)

---

**4. ssl** (`cookbooks/nginx-multisite/recipes/ssl.rb`):
- Installs packages: `openssl`, `ca-certificates`
- Fetches SSL passphrase from CyberArk Conjur via `conjur_variable('production/nginx/ssl_passphrase')` — result stored in local variable `ssl_passphrase` (**see Credentials section**)
- Creates group `ssl-cert`
- Creates directory `/etc/ssl/certs`: owner=root, group=root, mode=0755
- Creates directory `/etc/ssl/private`: owner=root, group=ssl-cert, mode=0710
- Iterations — runs 3 times for sites with `ssl_enabled=true`: `test.cluster.local`, `ci.cluster.local`, `status.cluster.local`:
  - **test.cluster.local**:
    - `execute 'generate-ssl-cert-test.cluster.local'`: generates self-signed cert with `openssl req -x509 -days 365 -newkey rsa:2048`
      - `-keyout /etc/ssl/private/test.cluster.local.key`
      - `-out /etc/ssl/certs/test.cluster.local.crt`
      - `-passout pass:<conjur_passphrase>`
      - `-subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=test.cluster.local/emailAddress=admin@example.com"`
      - Post-command: `chmod 640 /etc/ssl/private/test.cluster.local.key` and `chown root:ssl-cert /etc/ssl/private/test.cluster.local.key`
      - `sensitive true`, skipped if both `.crt` and `.key` files already exist
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - `execute 'generate-ssl-cert-ci.cluster.local'`: generates self-signed cert with `openssl req -x509 -days 365 -newkey rsa:2048`
      - `-keyout /etc/ssl/private/ci.cluster.local.key`
      - `-out /etc/ssl/certs/ci.cluster.local.crt`
      - `-passout pass:<conjur_passphrase>`
      - `-subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=ci.cluster.local/emailAddress=admin@example.com"`
      - `sensitive true`, skipped if both files already exist
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **status.cluster.local**:
    - `execute 'generate-ssl-cert-status.cluster.local'`: generates self-signed cert with `openssl req -x509 -days 365 -newkey rsa:2048`
      - `-keyout /etc/ssl/private/status.cluster.local.key`
      - `-out /etc/ssl/certs/status.cluster.local.crt`
      - `-passout pass:<conjur_passphrase>`
      - `-subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=status.cluster.local/emailAddress=admin@example.com"`
      - `sensitive true`, skipped if both files already exist
      - Notifies: `:reload` on `service[nginx]` (delayed)
- Resources: package (1), group (1), directory (2), execute (3)

---

**5. sites** (`cookbooks/nginx-multisite/recipes/sites.rb`):
- Iterations — runs 3 times for sites: `test.cluster.local`, `ci.cluster.local`, `status.cluster.local`:
  - **test.cluster.local**:
    - `template '/etc/nginx/sites-available/test.cluster.local'`: source=`site.conf.erb`, mode=0644
      - Variables: server_name=`test.cluster.local`, document_root=`/opt/server/test`, ssl_enabled=`true`, cert_file=`/etc/ssl/certs/test.cluster.local.crt`, key_file=`/etc/ssl/private/test.cluster.local.key`
      - Rendered config: HTTP 80 block redirects to HTTPS; HTTPS 443 block with ssl_certificate, ssl_certificate_key, TLSv1.2/TLSv1.3, HSTS, security headers, gzip, try_files, deny .ht/.git/.svn, per-site logs at `/var/log/nginx/test.cluster.local_access.log` and `/var/log/nginx/test.cluster.local_error.log`
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/test.cluster.local'`: symlink → `/etc/nginx/sites-available/test.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - `template '/etc/nginx/sites-available/ci.cluster.local'`: source=`site.conf.erb`, mode=0644
      - Variables: server_name=`ci.cluster.local`, document_root=`/opt/server/ci`, ssl_enabled=`true`, cert_file=`/etc/ssl/certs/ci.cluster.local.crt`, key_file=`/etc/ssl/private/ci.cluster.local.key`
      - Rendered config: HTTP 80 block redirects to HTTPS; HTTPS 443 block with ssl_certificate, ssl_certificate_key, TLSv1.2/TLSv1.3, HSTS, security headers, gzip, try_files, deny .ht/.git/.svn, per-site logs at `/var/log/nginx/ci.cluster.local_access.log` and `/var/log/nginx/ci.cluster.local_error.log`
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/ci.cluster.local'`: symlink → `/etc/nginx/sites-available/ci.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
  - **status.cluster.local**:
    - `template '/etc/nginx/sites-available/status.cluster.local'`: source=`site.conf.erb`, mode=0644
      - Variables: server_name=`status.cluster.local`, document_root=`/opt/server/status`, ssl_enabled=`true`, cert_file=`/etc/ssl/certs/status.cluster.local.crt`, key_file=`/etc/ssl/private/status.cluster.local.key`
      - Rendered config: HTTP 80 block redirects to HTTPS; HTTPS 443 block with ssl_certificate, ssl_certificate_key, TLSv1.2/TLSv1.3, HSTS, security headers, gzip, try_files, deny .ht/.git/.svn, per-site logs at `/var/log/nginx/status.cluster.local_access.log` and `/var/log/nginx/status.cluster.local_error.log`
      - Notifies: `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/status.cluster.local'`: symlink → `/etc/nginx/sites-available/status.cluster.local`
      - Notifies: `:reload` on `service[nginx]` (delayed)
- Deletes `/etc/nginx/sites-enabled/default` (removes nginx default site)
  - Notifies: `:reload` on `service[nginx]` (delayed)
- Resources: template (3), link (3), file (1)

---

## Dependencies

**External cookbook dependencies**:
- `cyberark-conjur ~> 3.0` — provides the `conjur_variable()` helper used in `cookbooks/nginx-multisite/recipes/ssl.rb` to fetch the SSL passphrase from CyberArk Conjur

**System package dependencies**:
- `nginx` — web server
- `fail2ban` — intrusion prevention
- `ufw` — firewall management
- `openssl` — TLS certificate generation
- `ca-certificates` — CA certificate bundle

**Service dependencies** (systemd services managed):
- `nginx` — enabled, started; reloaded on config/cert/site changes
- `fail2ban` — enabled, started; restarted on jail.local changes
- `ssh` — action `:nothing` at declaration; restarted only when sshd_config is modified by `ada_ada`

---

## Credentials

**Detection Summary**: 3 credentials detected across 3 files

**Source**:
- **Provider**: CyberArk Conjur (for SSL passphrase); Hardcoded (for OAuth2 client secret); Unknown/undocumented (for parsed token endpoint)
- **URL**: `https://conjur.example.com` (Conjur appliance URL from `cookbooks/nginx-multisite/attributes/default.rb`)
- **Path**: `production/nginx/ssl_passphrase` (Conjur variable path from `cookbooks/nginx-multisite/attributes/default.rb`)

### SSL Certificate Passphrase

- **Variable(s)**: `ssl_passphrase` (local variable in recipe), `node['cyberark']['conjur']['variable']` = `'production/nginx/ssl_passphrase'`, `node['cyberark']['conjur']['appliance_url']` = `'https://conjur.example.com'`, `node['cyberark']['conjur']['account']` = `'myorg'`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/ssl.rb` (line: `ssl_passphrase = conjur_variable(node['cyberark']['conjur']['variable'])`), `cookbooks/nginx-multisite/attributes/default.rb`
- **Current storage**: CyberArk Conjur vault — fetched at converge time via the `cyberark-conjur` cookbook's `conjur_variable()` helper
- **Usage context**: Passed as `-passout pass:<value>` to `openssl req` when generating self-signed certificates for all 3 sites. The `execute` resources are marked `sensitive true` to suppress the passphrase from Chef logs.

### OAuth2 Client Secret (fetch_token)

- **Variable(s)**: `client_secret` property of `fetch_token['get auth token']`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb` (line: `client_secret 'sup3rs3cr3t'`)
- **Current storage**: **Hardcoded** plaintext string in the recipe source code
- **Usage context**: Used by the `fetch_token` custom resource to POST an OAuth2 token request to `https://auth.example.com/oauth/token` with `client_id=nginx-multisite`. The resulting `access_token` is stored in `node.run_state['access_token']` but is **never consumed** by any subsequent resource in the cookbook — its downstream purpose is unclear from the source alone. The Ansible developer must clarify with the cookbook author what this token is used for before migrating this step.

### Parsed Token from API Endpoint (fetch_and_parse_token)

- **Variable(s)**: `extracted_token` property of `fetch_and_parse_token['get parsed token']`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb` (line: `fetch_and_parse_token 'get parsed token'`)
- **Current storage**: Runtime-fetched from `https://api.example.com/token_endpoint` — no persistent storage; stored in `node.run_state['extracted_token']`
- **Usage context**: Fetches a plain HTTP response from `https://api.example.com/token_endpoint`, parses a value from a line matching `X-Header:<value>`, and stores it in run state. Like the OAuth2 token above, this value is **never consumed** by any subsequent resource in the cookbook. The Ansible developer must clarify with the cookbook author what this parsed token is used for before migrating this step.

---

## Custom Resources

### 1. `ada_ada` — In-place line editor for config files

**Defined in**: `cookbooks/nginx-multisite/resources/ada_ada.rb`
**Used in**: `cookbooks/nginx-multisite/recipes/security.rb` (twice — for `PermitRootLogin no` and `PasswordAuthentication no` in `/etc/ssh/sshd_config`)

**Behavior**: Reads a target file, finds a line matching a regex pattern (`match`), replaces the entire matched line with the `line` property value. If no match is found, appends the line. If the file does not exist, creates it with only the line. Optionally creates a timestamped `.backup.<epoch>` file before writing. Idempotent: only writes if content would change.

**Properties**:
| Property | Type | Required | Default | Description |
|---|---|---|---|---|
| `file_path` | String | yes (name_property) | — | Path to the file to modify |
| `line` | String | yes | — | The exact line to write/replace |
| `match` | String | no | nil | Ruby regex pattern to find the line to replace |
| `backup` | Boolean | no | `true` | Create a timestamped backup before modifying |

**Ansible equivalent**: `ansible.builtin.lineinfile`

```yaml
- name: Disable root SSH login
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?PermitRootLogin'
    line: 'PermitRootLogin no'
    backup: true
  notify: Restart ssh

- name: Disable password authentication
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?PasswordAuthentication'
    line: 'PasswordAuthentication no'
    backup: true
  notify: Restart ssh
```

---

### 2. `fetch_token` — OAuth2 client credentials token fetcher

**Defined in**: `cookbooks/nginx-multisite/resources/fetch_token.rb`
**Used in**: `cookbooks/nginx-multisite/recipes/security.rb` (`fetch_token 'get auth token'`)

**Behavior**: Makes an HTTPS POST request to `auth_url` with a JSON body containing `client_id` and `client_secret`. Parses the JSON response and extracts `access_token`. Stores the token in `node.run_state['access_token']` for use by subsequent resources in the same Chef run. Uses Ruby's `Net::HTTP` directly. No idempotency guard — runs on every Chef converge.

**Properties**:
| Property | Type | Required | Default | Description |
|---|---|---|---|---|
| `auth_url` | String | yes | — | Full HTTPS URL of the OAuth2 token endpoint |
| `client_id` | String | yes | — | OAuth2 client identifier |
| `client_secret` | String | yes | — | OAuth2 client secret (currently hardcoded as `sup3rs3cr3t`) |
| `access_token` | String | no | nil | Output: populated with the fetched token |

**Ansible equivalent**: `ansible.builtin.uri`

```yaml
- name: Fetch OAuth2 access token
  ansible.builtin.uri:
    url: "https://auth.example.com/oauth/token"
    method: POST
    body_format: json
    body:
      client_id: "nginx-multisite"
      client_secret: "{{ oauth2_client_secret }}"  # store in Ansible Vault, NOT hardcoded
    return_content: true
    status_code: 200
  register: oauth2_token_response
  no_log: true
# Access token available as: oauth2_token_response.json.access_token
```

> ⚠️ **Important**: The `client_secret` is currently hardcoded as `sup3rs3cr3t` in `cookbooks/nginx-multisite/recipes/security.rb`. This MUST be moved to Ansible Vault or AAP credentials before migration. Additionally, the token is never consumed by any downstream resource in this cookbook — the Ansible developer must clarify with the cookbook author what this token is used for and whether the `uri` task is even needed.

---

### 3. `fetch_and_parse_token` — HTTP response header value extractor

**Defined in**: `cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb`
**Used in**: `cookbooks/nginx-multisite/recipes/security.rb` (`fetch_and_parse_token 'get parsed token'`)

**Behavior**: Makes a plain HTTP GET request to `token_url`. Scans the response **body** (not headers) for a line matching the pattern `X-Header:<value>` and extracts the value after the colon. Stores the extracted string in `node.run_state['extracted_token']`. Raises a hard error if the pattern is not found. No idempotency guard — runs on every Chef converge.

**Properties**:
| Property | Type | Required | Default | Description |
|---|---|---|---|---|
| `token_url` | String | yes | — | Full URL to fetch |
| `extracted_token` | String | no | nil | Output: populated with the parsed value |

**Ansible equivalent**: `ansible.builtin.uri` + `ansible.builtin.set_fact`

```yaml
- name: Fetch token response from API endpoint
  ansible.builtin.uri:
    url: "https://api.example.com/token_endpoint"
    method: GET
    return_content: true
    status_code: 200
  register: token_response
  no_log: true

- name: Parse X-Header value from response body
  ansible.builtin.set_fact:
    extracted_token: "{{ token_response.content | regex_search('X-Header:(.+)', '\\1') | first | trim }}"

- name: Fail if token pattern not found
  ansible.builtin.fail:
    msg: "Failed to parse token pattern from response body."
  when: extracted_token is not defined or extracted_token == ''
```

> ⚠️ **Important**: Like `fetch_token`, the extracted value is never consumed by any downstream resource in this cookbook. The Ansible developer must clarify with the cookbook author what this parsed token is used for before including this step in the Ansible role.

---

### 4. `conjur_variable()` — CyberArk Conjur secret fetcher

**Defined in**: External cookbook `cyberark-conjur ~> 3.0` (not in this cookbook's source)
**Used in**: `cookbooks/nginx-multisite/recipes/ssl.rb` (line: `ssl_passphrase = conjur_variable(node['cyberark']['conjur']['variable'])`)

**Behavior**: Fetches a secret value from CyberArk Conjur using the configured appliance URL, account, and variable path. Returns the secret as a plain string. The Conjur cookbook handles authentication (typically via a host identity/token already provisioned on the node).

**Ansible equivalent**: `cyberark.conjur.conjur_variable` lookup plugin

```yaml
- name: Fetch SSL passphrase from CyberArk Conjur
  ansible.builtin.set_fact:
    ssl_passphrase: "{{ lookup('cyberark.conjur.conjur_variable', 'production/nginx/ssl_passphrase',
                        conjur_appliance_url='https://conjur.example.com',
                        conjur_account='myorg') }}"
  no_log: true
```

> ⚠️ **Note**: The `cyberark.conjur` Ansible collection must be installed in AAP and the target node (or the AAP controller) must have a valid Conjur host identity configured. Coordinate with the security/secrets team to provision the Conjur identity for the Ansible automation host.

---

## Checks for the Migration

**Files to verify**:
- `/etc/nginx/nginx.conf` — main nginx configuration
- `/etc/nginx/conf.d/security.conf` — nginx security hardening snippet
- `/etc/nginx/sites-available/test.cluster.local` — test site vhost config
- `/etc/nginx/sites-available/ci.cluster.local` — CI site vhost config
- `/etc/nginx/sites-available/status.cluster.local` — status site vhost config
- `/etc/nginx/sites-enabled/test.cluster.local` — symlink to sites-available
- `/etc/nginx/sites-enabled/ci.cluster.local` — symlink to sites-available
- `/etc/nginx/sites-enabled/status.cluster.local` — symlink to sites-available
- `/etc
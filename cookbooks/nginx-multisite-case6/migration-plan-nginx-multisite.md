---
source-path: .
---

# Migration Plan: nginx-multisite

**TLDR**: This cookbook configures an nginx web server hosting three SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) on a single node. It hardens the host with UFW firewall rules, fail2ban intrusion prevention, and kernel-level sysctl security parameters. Self-signed TLS certificates are generated per-site using a passphrase fetched from CyberArk Conjur. The cookbook also invokes several custom resources — some straightforward to convert to Ansible, one using a proprietary internal library that cannot be safely converted without additional information.

---

## Service Type and Instances

**Service Type**: Web Server (nginx multi-site / reverse proxy with TLS termination)

**Configured Instances**:

- **test.cluster.local**: Test/development environment virtual host
  - Location/Path: Document root `/opt/server/test`
  - Port/Socket: HTTP 80 (redirects to HTTPS), HTTPS 443
  - Key Config: `ssl_enabled: true`; self-signed cert at `/etc/ssl/certs/test.cluster.local.crt`; key at `/etc/ssl/private/test.cluster.local.key`; static index page deployed from `files/default/test/index.html`

- **ci.cluster.local**: CI/CD dashboard virtual host
  - Location/Path: Document root `/opt/server/ci`
  - Port/Socket: HTTP 80 (redirects to HTTPS), HTTPS 443
  - Key Config: `ssl_enabled: true`; self-signed cert at `/etc/ssl/certs/ci.cluster.local.crt`; key at `/etc/ssl/private/ci.cluster.local.key`; static index page deployed from `files/default/ci/index.html`

- **status.cluster.local**: System status dashboard virtual host
  - Location/Path: Document root `/opt/server/status`
  - Port/Socket: HTTP 80 (redirects to HTTPS), HTTPS 443
  - Key Config: `ssl_enabled: true`; self-signed cert at `/etc/ssl/certs/status.cluster.local.crt`; key at `/etc/ssl/private/status.cluster.local.key`; static index page deployed from `files/default/status/index.html`

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
│   ├── fetch_token.rb
│   ├── my_format.rb
│   └── secret_setting.rb
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
- Installs packages `fail2ban` and `ufw` (single `package` resource with array `%w[fail2ban ufw]`).
- Enables and starts the `fail2ban` service.
- Deploys `/etc/fail2ban/jail.local` from `templates/default/fail2ban.jail.local.erb`. The rendered file configures five jails:
  - `[DEFAULT]`: bantime=3600s, findtime=600s, maxretry=3, backend=auto
  - `[sshd]`: enabled, port=ssh, logpath=/var/log/auth.log, bantime=3600, maxretry=3
  - `[nginx-http-auth]`: enabled, port=http,https, logpath=/var/log/nginx/*error.log, bantime=3600, maxretry=3
  - `[nginx-limit-req]`: enabled, port=http,https, logpath=/var/log/nginx/*error.log, bantime=3600, maxretry=10
  - `[nginx-botsearch]`: enabled, port=http,https, logpath=/var/log/nginx/*access.log, bantime=3600, maxretry=2
  - Notifies: restart `service[fail2ban]` (delayed)
- Runs `execute 'ufw_default_deny'`: `ufw --force default deny` (guarded: skipped if `ufw status | grep -q "Default: deny"`)
- Runs `execute 'ufw_allow_ssh'`: `ufw allow ssh` (guarded: skipped if port 22/tcp already allowed)
- Runs `execute 'ufw_allow_http'`: `ufw allow http` (guarded: skipped if port 80/tcp already allowed)
- Runs `execute 'ufw_allow_https'`: `ufw allow https` (guarded: skipped if port 443/tcp already allowed)
- Runs `execute 'ufw_enable'`: `ufw --force enable` (guarded: skipped if UFW already active)
- Invokes custom resource `fetch_token 'get auth token'`:
  - `auth_url`: `https://auth.example.com/oauth/token`
  - `client_id`: `nginx-multisite`
  - `client_secret`: `sup3rs3cr3t` (**hardcoded secret — see Credentials section**)
  - Action `:fetch` — POSTs JSON to the auth URL, stores `access_token` in `node.run_state['access_token']`
- Invokes custom resource `fetch_and_parse_token 'get parsed token'`:
  - `token_url`: `https://api.example.com/token_endpoint`
  - Action `:fetch_and_parse` — GETs the URL, parses response body for pattern `pattern1:(.+)`, stores result in `node.run_state['extracted_token']`
- Invokes custom resource `my_format '/etc/company/app.conf'` (first call):
  - `entry`: `app_mode`, `value`: `production`
  - Action `:set` — writes `!app_mode=production` to `/etc/company/app.conf`
- Invokes custom resource `my_format '/etc/company/app.conf'` (second call):
  - `entry`: `health_port`, `value`: `8080`
  - Action `:set` — writes `!health_port=8080` to `/etc/company/app.conf`
- Invokes custom resource `secret_setting 'service_api_key'`:
  - `scope`: `nginx`
  - Action `:fetch` — retrieves `service_api_key` from the internal Company Secrets Platform via the `company_internal_lib` gem; stores value in `node.run_state['service_api_key']`
- Deploys `/etc/sysctl.d/99-security.conf` from `templates/default/sysctl-security.conf.erb`. The rendered file sets kernel parameters:
  - IP spoofing protection: `net.ipv4.conf.default.rp_filter=1`, `net.ipv4.conf.all.rp_filter=1`
  - ICMP redirect ignore: `net.ipv4.conf.all.accept_redirects=0`, `net.ipv6.conf.all.accept_redirects=0`, `net.ipv4.conf.default.accept_redirects=0`, `net.ipv6.conf.default.accept_redirects=0`
  - Send redirect disable: `net.ipv4.conf.all.send_redirects=0`, `net.ipv4.conf.default.send_redirects=0`
  - Source routing disable: `net.ipv4.conf.all.accept_source_route=0`, `net.ipv6.conf.all.accept_source_route=0`, `net.ipv4.conf.default.accept_source_route=0`, `net.ipv6.conf.default.accept_source_route=0`
  - Martian logging: `net.ipv4.conf.all.log_martians=1`, `net.ipv4.conf.default.log_martians=1`
  - ICMP ping ignore: `net.ipv4.icmp_echo_ignore_all=1`, `net.ipv4.icmp_echo_ignore_broadcasts=1`
  - IPv6 disable: `net.ipv6.conf.all.disable_ipv6=1`, `net.ipv6.conf.default.disable_ipv6=1`, `net.ipv6.conf.lo.disable_ipv6=1`
  - SYN flood protection: `net.ipv4.tcp_syncookies=1`, `net.ipv4.tcp_max_syn_backlog=2048`, `net.ipv4.tcp_synack_retries=2`, `net.ipv4.tcp_syn_retries=5`
  - Notifies: run `execute[reload_sysctl]` (delayed)
- Runs `execute 'reload_sysctl'`: `sysctl -p /etc/sysctl.d/99-security.conf` (action `:nothing` — only triggered by template notification)
- **Conditional** (when `node['security']['ssh']['disable_root']` is `true`): Invokes `ada_ada '/etc/ssh/sshd_config'`:
  - `line`: `PermitRootLogin no`
  - `match`: `^#\?PermitRootLogin`
  - Replaces or appends the `PermitRootLogin` directive in `/etc/ssh/sshd_config`; creates a timestamped `.backup` file before modifying
  - Notifies: restart `service[ssh]` (delayed)
- **Conditional** (when `node['security']['ssh']['password_auth']` is `false`): Invokes `ada_ada '/etc/ssh/sshd_config'`:
  - `line`: `PasswordAuthentication no`
  - `match`: `^#\?PasswordAuthentication`
  - Replaces or appends the `PasswordAuthentication` directive in `/etc/ssh/sshd_config`
  - Notifies: restart `service[ssh]` (delayed)
- Declares `service 'ssh'` with action `:nothing` (only restarted via notifications from `ada_ada` resources above)
- Resources: package (1, array), service (2: fail2ban + ssh), template (2), execute (6), fetch_token (1 custom), fetch_and_parse_token (1 custom), my_format (2 custom), secret_setting (1 custom), ada_ada (2 custom, conditional)

---

**3. nginx** (`cookbooks/nginx-multisite/recipes/nginx.rb`):
- Installs package `nginx`.
- Deploys `/etc/nginx/nginx.conf` from `templates/default/nginx.conf.erb`. Key settings: `user www-data`, `worker_processes auto`, `worker_connections 768`, gzip on, includes `/etc/nginx/conf.d/*.conf` and `/etc/nginx/sites-enabled/*`. Notifies: reload `service[nginx]` (delayed).
- Deploys `/etc/nginx/conf.d/security.conf` from `templates/default/security.conf.erb`. Key settings: `server_tokens off`, rate limiting zones (`login`: 10r/m, `api`: 30r/m), buffer limits (`client_body_buffer_size 1K`, `client_max_body_size 1K`), timeout settings (10s), SSL global settings (TLSv1.2/TLSv1.3, strong cipher suite). Notifies: reload `service[nginx]` (delayed).
- Enables and starts the `nginx` service.
- Iterations — runs 3 times, once per site:
  - **test.cluster.local**:
    - Creates directory `/opt/server/test` (owner: `www-data`, group: `www-data`, mode: `0755`, recursive)
    - Deploys `files/default/test/index.html` → `/opt/server/test/index.html` (owner: `www-data`, group: `www-data`, mode: `0644`)
  - **ci.cluster.local**:
    - Creates directory `/opt/server/ci` (owner: `www-data`, group: `www-data`, mode: `0755`, recursive)
    - Deploys `files/default/ci/index.html` → `/opt/server/ci/index.html` (owner: `www-data`, group: `www-data`, mode: `0644`)
  - **status.cluster.local**:
    - Creates directory `/opt/server/status` (owner: `www-data`, group: `www-data`, mode: `0755`, recursive)
    - Deploys `files/default/status/index.html` → `/opt/server/status/index.html` (owner: `www-data`, group: `www-data`, mode: `0644`)
  - Note: `site_folder` is derived by taking the first label of the FQDN (e.g., `test.cluster.local` → `test`), which maps to the `files/default/<site_folder>/index.html` source path.
- Resources: package (1), template (2), service (1), directory (3), cookbook_file (3)

---

**4. ssl** (`cookbooks/nginx-multisite/recipes/ssl.rb`):
- Installs packages `openssl` and `ca-certificates` (single `package` resource with array `%w[openssl ca-certificates]`).
- Fetches SSL passphrase from CyberArk Conjur using `conjur_variable(node['cyberark']['conjur']['variable'])` — variable path: `production/nginx/ssl_passphrase`, Conjur appliance: `https://conjur.example.com`, account: `myorg`. The passphrase is stored in the local Ruby variable `ssl_passphrase` and used inline in `openssl` commands.
- Creates group `ssl-cert`.
- Creates directory `/etc/ssl/certs` (owner: `root`, group: `root`, mode: `0755`).
- Creates directory `/etc/ssl/private` (owner: `root`, group: `ssl-cert`, mode: `0710`).
- Iterations — runs 3 times for all sites with `ssl_enabled: true`:
  - **test.cluster.local**:
    - Runs `execute 'generate-ssl-cert-test.cluster.local'` (guarded: skipped if both `/etc/ssl/certs/test.cluster.local.crt` and `/etc/ssl/private/test.cluster.local.key` already exist):
      - `openssl req -x509 -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/test.cluster.local.key -out /etc/ssl/certs/test.cluster.local.crt -passout pass:<ssl_passphrase> -subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=test.cluster.local/emailAddress=admin@example.com"`
      - `chmod 640 /etc/ssl/private/test.cluster.local.key`
      - `chown root:ssl-cert /etc/ssl/private/test.cluster.local.key`
      - `sensitive true` (passphrase not logged)
      - Notifies: reload `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - Runs `execute 'generate-ssl-cert-ci.cluster.local'` (guarded: skipped if both `/etc/ssl/certs/ci.cluster.local.crt` and `/etc/ssl/private/ci.cluster.local.key` already exist):
      - Same openssl command with CN=`ci.cluster.local`, output to `/etc/ssl/certs/ci.cluster.local.crt` and `/etc/ssl/private/ci.cluster.local.key`
      - Notifies: reload `service[nginx]` (delayed)
  - **status.cluster.local**:
    - Runs `execute 'generate-ssl-cert-status.cluster.local'` (guarded: skipped if both `/etc/ssl/certs/status.cluster.local.crt` and `/etc/ssl/private/status.cluster.local.key` already exist):
      - Same openssl command with CN=`status.cluster.local`, output to `/etc/ssl/certs/status.cluster.local.crt` and `/etc/ssl/private/status.cluster.local.key`
      - Notifies: reload `service[nginx]` (delayed)
- Resources: package (1, array), group (1), directory (2), execute (3, guarded)

---

**5. sites** (`cookbooks/nginx-multisite/recipes/sites.rb`):
- Iterations — runs 3 times, once per site:
  - **test.cluster.local**:
    - Deploys `/etc/nginx/sites-available/test.cluster.local` from `templates/default/site.conf.erb` with variables:
      - `server_name`: `test.cluster.local`, `document_root`: `/opt/server/test`, `ssl_enabled`: `true`
      - `cert_file`: `/etc/ssl/certs/test.cluster.local.crt`, `key_file`: `/etc/ssl/private/test.cluster.local.key`
      - Template renders: HTTP server block (port 80) with `return 301 https://...` redirect; HTTPS server block (port 443 ssl http2) with TLSv1.2/TLSv1.3, HSTS header, security headers (X-Frame-Options DENY, X-Content-Type-Options nosniff, X-XSS-Protection, Referrer-Policy, Content-Security-Policy), gzip, `try_files`, deny `.ht`/`.git`/`.svn`, access_log `/var/log/nginx/test.cluster.local_access.log`, error_log `/var/log/nginx/test.cluster.local_error.log`
      - Notifies: reload `service[nginx]` (delayed)
    - Creates symlink `/etc/nginx/sites-enabled/test.cluster.local` → `/etc/nginx/sites-available/test.cluster.local`. Notifies: reload `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - Deploys `/etc/nginx/sites-available/ci.cluster.local` from `templates/default/site.conf.erb` with variables:
      - `server_name`: `ci.cluster.local`, `document_root`: `/opt/server/ci`, `ssl_enabled`: `true`
      - `cert_file`: `/etc/ssl/certs/ci.cluster.local.crt`, `key_file`: `/etc/ssl/private/ci.cluster.local.key`
      - Same template structure; access_log `/var/log/nginx/ci.cluster.local_access.log`, error_log `/var/log/nginx/ci.cluster.local_error.log`
      - Notifies: reload `service[nginx]` (delayed)
    - Creates symlink `/etc/nginx/sites-enabled/ci.cluster.local` → `/etc/nginx/sites-available/ci.cluster.local`. Notifies: reload `service[nginx]` (delayed)
  - **status.cluster.local**:
    - Deploys `/etc/nginx/sites-available/status.cluster.local` from `templates/default/site.conf.erb` with variables:
      - `server_name`: `status.cluster.local`, `document_root`: `/opt/server/status`, `ssl_enabled`: `true`
      - `cert_file`: `/etc/ssl/certs/status.cluster.local.crt`, `key_file`: `/etc/ssl/private/status.cluster.local.key`
      - Same template structure; access_log `/var/log/nginx/status.cluster.local_access.log`, error_log `/var/log/nginx/status.cluster.local_error.log`
      - Notifies: reload `service[nginx]` (delayed)
    - Creates symlink `/etc/nginx/sites-enabled/status.cluster.local` → `/etc/nginx/sites-available/status.cluster.local`. Notifies: reload `service[nginx]` (delayed)
- Deletes `/etc/nginx/sites-enabled/default` (removes the nginx default site). Notifies: reload `service[nginx]` (delayed).
- Resources: template (3), link (3), file (1, delete)

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
- `nginx` — managed (enabled, started, reloaded on config change)
- `fail2ban` — managed (enabled, started, restarted on jail config change)
- `ssh` — managed (restarted only when `/etc/ssh/sshd_config` is modified)

---

## Credentials

**Detection Summary**: 4 credentials detected across 4 files

**Source**:
- **Provider**: CyberArk Conjur (SSL passphrase); Internal Company Secrets Platform via `company_internal_lib` gem (service API key); Hardcoded plaintext (OAuth client secret); Runtime HTTP fetch (parsed token)
- **URL**: `https://conjur.example.com` (Conjur appliance URL); `https://auth.example.com/oauth/token` (OAuth token endpoint); `https://api.example.com/token_endpoint` (parsed token endpoint)
- **Path**: `production/nginx/ssl_passphrase` (Conjur variable path)

---

### SSL Certificate Passphrase

- **Variable(s)**: `node['cyberark']['conjur']['variable']` → resolved at runtime via `conjur_variable('production/nginx/ssl_passphrase')`; stored in local Ruby variable `ssl_passphrase`
- **Source file(s)**: `cookbooks/nginx-multisite/attributes/default.rb` (Conjur config), `cookbooks/nginx-multisite/recipes/ssl.rb` (usage)
- **Current storage**: CyberArk Conjur vault — fetched at converge time using the `cyberark-conjur` cookbook helper `conjur_variable()`
- **Usage context**: Passed as `-passout pass:<value>` to `openssl req` when generating self-signed certificates for all three sites (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`). Marked `sensitive true` on the execute resource to suppress logging.

---

### OAuth Client Secret (fetch_token)

- **Variable(s)**: `client_secret` property on `fetch_token 'get auth token'` resource
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb` (hardcoded value: `sup3rs3cr3t`)
- **Current storage**: **Hardcoded** plaintext string directly in recipe source code
- **Usage context**: Used as the `client_secret` in a JSON POST body to `https://auth.example.com/oauth/token` to obtain an OAuth access token. The token is stored in `node.run_state['access_token']`. **This credential must be moved to a secrets manager before migration.**

---

### Service API Key (secret_setting)

- **Variable(s)**: `setting_name`: `service_api_key`, `scope`: `nginx`; stored in `node.run_state['service_api_key']`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb` (usage), `cookbooks/nginx-multisite/resources/secret_setting.rb` (implementation)
- **Current storage**: Internal Company Secrets Platform, accessed via the proprietary `company_internal_lib` Ruby gem (`CompanyInternal::SettingsStore`)
- **Usage context**: Fetches the `service_api_key` secret scoped to `nginx` from the internal platform. The value is stored in Chef run state for potential downstream use. **The gem and platform are internal/proprietary — the `secret_setting` custom resource cannot be safely converted without access to the internal platform's Ansible equivalent.**

---

### Parsed Token (fetch_and_parse_token)

- **Variable(s)**: `extracted_token` property; stored in `node.run_state['extracted_token']`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb` (usage), `cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb` (implementation)
- **Current storage**: Retrieved at runtime from `https://api.example.com/token_endpoint` via HTTP GET; parsed from response body using regex `pattern1:(.+)`
- **Usage context**: Fetches and parses a token from an internal API endpoint. The parsed value is stored in run state. **Note**: The regex pattern `pattern1:(.+)` appears to be a placeholder — the actual pattern and endpoint semantics are not documented in the cookbook source. Consult the team that owns `https://api.example.com/token_endpoint` before migrating.

---

## Custom Resources

### 1. `ada_ada` (`cookbooks/nginx-multisite/resources/ada_ada.rb`)

**Description**: A line-in-file editor for configuration files. Given a file path, a target line string, and an optional regex match pattern, it either replaces the first matching line or appends the line if no match is found. Before modifying, it writes a timestamped backup file (`<path>.backup.<epoch>`). Idempotent: skips write if the resulting content is unchanged.

**Used in**: `cookbooks/nginx-multisite/recipes/security.rb` — twice, conditionally:
1. Sets `PermitRootLogin no` in `/etc/ssh/sshd_config` (when `node['security']['ssh']['disable_root']` is `true`)
2. Sets `PasswordAuthentication no` in `/etc/ssh/sshd_config` (when `node['security']['ssh']['password_auth']` is `false`)

**Conversion outcome**: **Existing Ansible modules** — use `ansible.builtin.lineinfile`:
```yaml
- name: Disable root SSH login
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?\s*PermitRootLogin'
    line: 'PermitRootLogin no'
    backup: yes
  notify: restart ssh
  when: security_ssh_disable_root | bool

- name: Disable password authentication
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?\s*PasswordAuthentication'
    line: 'PasswordAuthentication no'
    backup: yes
  notify: restart ssh
  when: not security_ssh_password_auth | bool
```

---

### 2. `fetch_token` (`cookbooks/nginx-multisite/resources/fetch_token.rb`)

**Description**: Makes an HTTPS POST request to an OAuth token endpoint with `client_id` and `client_secret` as a JSON body. Parses the JSON response and stores `access_token` in `node.run_state['access_token']`. Properties: `auth_url` (String, required), `client_id` (String, required), `client_secret` (String, required), `access_token` (String, output). Action: `:fetch`.

**Used in**: `cookbooks/nginx-multisite/recipes/security.rb` — once, with:
- `auth_url`: `https://auth.example.com/oauth/token`
- `client_id`: `nginx-multisite`
- `client_secret`: `sup3rs3cr3t` (hardcoded — must be replaced before migration)

**Conversion outcome**: **Existing Ansible modules** — use `ansible.builtin.uri`:
```yaml
- name: Fetch OAuth access token
  ansible.builtin.uri:
    url: "https://auth.example.com/oauth/token"
    method: POST
    body_format: json
    body:
      client_id: "nginx-multisite"
      client_secret: "{{ vault_oauth_client_secret }}"
    return_content: yes
    status_code: 200
  register: oauth_token_response
  no_log: true

- name: Store access token as fact
  ansible.builtin.set_fact:
    access_token: "{{ oauth_token_response.json.access_token }}"
  no_log: true
```
Replace the hardcoded `client_secret` with a variable sourced from AAP credentials or a vault lookup.

---

### 3. `fetch_and_parse_token` (`cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb`)

**Description**: Makes an HTTP GET request to a token URL. Parses the response body using the regex `pattern1:(.+)` and captures the value after the colon. Stores the result in `node.run_state['extracted_token']`. Properties: `token_url` (String, required), `extracted_token` (String, output). Action: `:fetch_and_parse`. Raises an error if the pattern is not found.

**Used in**: `cookbooks/nginx-multisite/recipes/security.rb` — once, with:
- `token_url`: `https://api.example.com/token_endpoint`

**Conversion outcome**: **Existing Ansible modules** — use `ansible.builtin.uri` and `ansible.builtin.set_fact`. However, the regex `pattern1:(.+)` is a placeholder and the actual token format is undocumented:
```yaml
- name: Fetch and parse token from API endpoint
  ansible.builtin.uri:
    url: "https://api.example.com/token_endpoint"
    method: GET
    return_content: yes
  register: token_response
  no_log: true

- name: Parse token from response
  ansible.builtin.set_fact:
    extracted_token: "{{ token_response.content | regex_search('pattern1:(.+)', '\\1') | first }}"
  no_log: true
```
> ⚠️ **Action required**: Replace `pattern1:(.+)` with the actual regex pattern. Consult the team that owns `https://api.example.com/token_endpoint` for the real response format before implementing.

---

### 4. `my_format` (`cookbooks/nginx-multisite/resources/my_format.rb`)

**Description**: Manages entries in a proprietary configuration file format used by an internal "CompanyApp". Each entry is a line of the form `!key=value`. Comment lines (starting with `#`) and unparseable lines are preserved. Actions: `:set` (upsert — removes existing `!key=...` line and appends `!key=value`), `:remove` (deletes the matching `!key=...` line). Properties: `file_path` (String, name property), `entry` (String, required), `value` (String, required for `:set`). Idempotent.

**Used in**: `cookbooks/nginx-multisite/recipes/security.rb` — twice, both targeting `/etc/company/app.conf`:
1. `entry: 'app_mode'`, `value: 'production'` → writes `!app_mode=production`
2. `entry: 'health_port'`, `value: '8080'` → writes `!health_port=8080`

**Conversion outcome**: **Custom Ansible module needed** — the `!key=value` format is proprietary and not handled by `ansible.builtin.lineinfile`. The preservation-of-comment-lines and upsert semantics require a custom module.

**Custom Ansible module specification**:
- **Module name**: `company_app_conf`
- **Parameters**:
  - `path` (str, required): Path to the config file
  - `entry` (str, required): Key name (without the `!` prefix)
  - `value` (str, required for `set`): Value to set
  - `state` (str, default: `present`): `present` or `absent`
- **Behavior**: Read the file (or create if absent). For `state: present`: remove any existing line matching `!<entry
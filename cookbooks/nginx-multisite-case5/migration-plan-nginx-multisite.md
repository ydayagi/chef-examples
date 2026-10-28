---
source-path: .
---

# Migration Plan: nginx-multisite

**TLDR**: This cookbook installs and configures nginx as a multi-site web server hosting three SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) on a single node. It hardens the host with fail2ban, UFW firewall rules, and kernel-level sysctl security parameters, then generates self-signed TLS certificates for each site using a passphrase retrieved from CyberArk Conjur. Each site gets its own document root, static `index.html`, nginx virtual-host configuration, and per-site access/error logs. Two custom token-fetching resources (`fetch_token`, `fetch_and_parse_token`) are also invoked during the security phase, and a third custom resource (`ada_ada`) performs in-place line editing of `/etc/ssh/sshd_config` to enforce SSH hardening.

---

## Service Type and Instances

**Service Type**: Web Server (nginx multi-site with TLS termination)

**Configured Instances**:

- **test.cluster.local**: Test/development environment virtual host
  - Document Root: `/opt/server/test`
  - Port/Socket: 80 (HTTP → 301 redirect to HTTPS), 443 (HTTPS/TLS)
  - SSL: Enabled — certificate: `/etc/ssl/certs/test.cluster.local.crt`, key: `/etc/ssl/private/test.cluster.local.key`
  - Static file deployed: `files/default/test/index.html` → `/opt/server/test/index.html`
  - Nginx config: `/etc/nginx/sites-available/test.cluster.local` (symlinked to `sites-enabled`)
  - Logs: `/var/log/nginx/test.cluster.local_access.log`, `/var/log/nginx/test.cluster.local_error.log`

- **ci.cluster.local**: CI/CD dashboard virtual host
  - Document Root: `/opt/server/ci`
  - Port/Socket: 80 (HTTP → 301 redirect to HTTPS), 443 (HTTPS/TLS)
  - SSL: Enabled — certificate: `/etc/ssl/certs/ci.cluster.local.crt`, key: `/etc/ssl/private/ci.cluster.local.key`
  - Static file deployed: `files/default/ci/index.html` → `/opt/server/ci/index.html`
  - Nginx config: `/etc/nginx/sites-available/ci.cluster.local` (symlinked to `sites-enabled`)
  - Logs: `/var/log/nginx/ci.cluster.local_access.log`, `/var/log/nginx/ci.cluster.local_error.log`

- **status.cluster.local**: System status/monitoring virtual host
  - Document Root: `/opt/server/status`
  - Port/Socket: 80 (HTTP → 301 redirect to HTTPS), 443 (HTTPS/TLS)
  - SSL: Enabled — certificate: `/etc/ssl/certs/status.cluster.local.crt`, key: `/etc/ssl/private/status.cluster.local.key`
  - Static file deployed: `files/default/status/index.html` → `/opt/server/status/index.html`
  - Nginx config: `/etc/nginx/sites-available/status.cluster.local` (symlinked to `sites-enabled`)
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
- Entry point. Includes four sub-recipes in strict order: `security` → `nginx` → `ssl` → `sites`.
- Resources: `include_recipe` (4)

---

**2. security** (`cookbooks/nginx-multisite/recipes/security.rb`):
- Installs packages: `fail2ban`, `ufw` (single `package` resource with array `%w[fail2ban ufw]`).
- Enables and starts the `fail2ban` service.
- Deploys `/etc/fail2ban/jail.local` from `fail2ban.jail.local.erb` (mode `0644`); notifies `:restart` on `service[fail2ban]` (delayed).
  - Template configures five jails: `[DEFAULT]` (bantime=3600, findtime=600, maxretry=3), `[sshd]` (logpath=/var/log/auth.log), `[nginx-http-auth]` (port=http,https, logpath=/var/log/nginx/*error.log), `[nginx-limit-req]` (maxretry=10), `[nginx-botsearch]` (logpath=/var/log/nginx/*access.log, maxretry=2).
- Runs UFW firewall configuration via five `execute` resources (each guarded by `not_if`):
  - `ufw_default_deny`: `ufw --force default deny` (skipped if already set)
  - `ufw_allow_ssh`: `ufw allow ssh` (skipped if 22/tcp already present)
  - `ufw_allow_http`: `ufw allow http` (skipped if 80/tcp already present)
  - `ufw_allow_https`: `ufw allow https` (skipped if 443/tcp already present)
  - `ufw_enable`: `ufw --force enable` (skipped if already active)
- Invokes custom resource `fetch_token['get auth token']`:
  - `auth_url`: `https://auth.example.com/oauth/token`
  - `client_id`: `nginx-multisite`
  - `client_secret`: `sup3rs3cr3t` (**hardcoded secret** — see Credentials section)
  - Action `:fetch` — POSTs JSON to the auth URL, stores `access_token` in `node.run_state['access_token']`
  - Provider: `cookbooks/nginx-multisite/resources/fetch_token.rb`
- Invokes custom resource `fetch_and_parse_token['get parsed token']`:
  - `token_url`: `https://api.example.com/token_endpoint`
  - Action `:fetch_and_parse` — GETs the URL, parses response body for pattern `pattern1:(.+)`, stores result in `node.run_state['extracted_token']`
  - Provider: `cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb`
- Deploys `/etc/sysctl.d/99-security.conf` from `sysctl-security.conf.erb` (mode `0644`); notifies `:run` on `execute[reload_sysctl]` (delayed).
  - Template sets: IP spoofing protection (`rp_filter=1`), ICMP redirect ignore, source routing disable, martian logging, ICMP echo ignore, IPv6 disable, TCP SYN cookie protection (`tcp_syncookies=1`, `tcp_max_syn_backlog=2048`).
- `execute[reload_sysctl]`: `sysctl -p /etc/sysctl.d/99-security.conf` — action `:nothing` (only runs when notified).
- Conditional SSH hardening via custom resource `ada_ada` (provider: `cookbooks/nginx-multisite/resources/ada_ada.rb`):
  - If `node['security']['ssh']['disable_root']` is `true` (default: `true`):
    - `ada_ada '/etc/ssh/sshd_config'` with `line 'PermitRootLogin no'`, `match '^#\?PermitRootLogin'`; notifies `:restart` on `service[ssh]` (delayed).
    - Behaviour: reads `/etc/ssh/sshd_config`, finds the line matching `^#?PermitRootLogin`, replaces the entire line with `PermitRootLogin no`. If no match, appends the line. Creates a timestamped `.backup.<epoch>` file before writing.
  - If `node['security']['ssh']['password_auth']` is `false` (default: `false`):
    - `ada_ada '/etc/ssh/sshd_config'` with `line 'PasswordAuthentication no'`, `match '^#\?PasswordAuthentication'`; notifies `:restart` on `service[ssh]` (delayed).
- `service 'ssh'`: action `:nothing` (only restarts when notified by `ada_ada`).
- Resources: package (1, array), service (2: fail2ban + ssh), template (2), execute (6), fetch_token (1), fetch_and_parse_token (1), ada_ada (2)

---

**3. nginx** (`cookbooks/nginx-multisite/recipes/nginx.rb`):
- Installs package: `nginx`.
- Deploys `/etc/nginx/nginx.conf` from `nginx.conf.erb` (mode `0644`); notifies `:reload` on `service[nginx]` (delayed).
  - Template sets: `user www-data`, `worker_processes auto`, `worker_connections 768`, gzip on, includes `/etc/nginx/conf.d/*.conf` and `/etc/nginx/sites-enabled/*`.
- Deploys `/etc/nginx/conf.d/security.conf` from `security.conf.erb` (mode `0644`); notifies `:reload` on `service[nginx]` (delayed).
  - Template sets: `server_tokens off`, rate-limit zones (`login:10m rate=10r/m`, `api:10m rate=30r/m`), buffer limits (`client_body_buffer_size 1K`, `client_max_body_size 1k`), timeouts (10s), global SSL settings (TLSv1.2/TLSv1.3, strong cipher suite, session cache 10m).
- Enables and starts `service[nginx]` (supports restart, reload, status).
- Iterations: Runs **3 times** for sites — **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - `directory '/opt/server/test'` — owner: `www-data`, group: `www-data`, mode: `0755`, recursive: true
    - `cookbook_file '/opt/server/test/index.html'` — source: `files/default/test/index.html`, owner: `www-data`, group: `www-data`, mode: `0644`
  - **ci.cluster.local**:
    - `directory '/opt/server/ci'` — owner: `www-data`, group: `www-data`, mode: `0755`, recursive: true
    - `cookbook_file '/opt/server/ci/index.html'` — source: `files/default/ci/index.html`, owner: `www-data`, group: `www-data`, mode: `0644`
  - **status.cluster.local**:
    - `directory '/opt/server/status'` — owner: `www-data`, group: `www-data`, mode: `0755`, recursive: true
    - `cookbook_file '/opt/server/status/index.html'` — source: `files/default/status/index.html`, owner: `www-data`, group: `www-data`, mode: `0644`
  - Note: `site_folder` is derived as the first DNS label (e.g., `test.cluster.local` → `test`), which maps to the `files/default/<site_folder>/index.html` cookbook file path.
- Resources: package (1), template (2), service (1), directory (3), cookbook_file (3)

---

**4. ssl** (`cookbooks/nginx-multisite/recipes/ssl.rb`):
- Installs packages: `openssl`, `ca-certificates` (single `package` resource with array `%w[openssl ca-certificates]`).
- Fetches SSL passphrase from CyberArk Conjur using `conjur_variable(node['cyberark']['conjur']['variable'])` — variable path: `production/nginx/ssl_passphrase`, Conjur URL: `https://conjur.example.com`, account: `myorg`. The passphrase is stored in the local Ruby variable `ssl_passphrase` and used inline in `openssl` commands (marked `sensitive true`).
- Creates group `ssl-cert`.
- Creates directory `/etc/ssl/certs` — owner: `root`, group: `root`, mode: `0755`.
- Creates directory `/etc/ssl/private` — owner: `root`, group: `ssl-cert`, mode: `0710`.
- Iterations: Runs **3 times** for sites where `ssl_enabled: true` — **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - `execute 'generate-ssl-cert-test.cluster.local'` — generates self-signed cert:
      - `openssl req -x509 -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/test.cluster.local.key -out /etc/ssl/certs/test.cluster.local.crt -passout pass:<ssl_passphrase> -subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=test.cluster.local/emailAddress=admin@example.com"`
      - `chmod 640 /etc/ssl/private/test.cluster.local.key`
      - `chown root:ssl-cert /etc/ssl/private/test.cluster.local.key`
      - `sensitive true`, guarded by `not_if { File.exist?('/etc/ssl/certs/test.cluster.local.crt') && File.exist?('/etc/ssl/private/test.cluster.local.key') }`
      - Notifies `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - `execute 'generate-ssl-cert-ci.cluster.local'` — generates self-signed cert:
      - `openssl req -x509 -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/ci.cluster.local.key -out /etc/ssl/certs/ci.cluster.local.crt -passout pass:<ssl_passphrase> -subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=ci.cluster.local/emailAddress=admin@example.com"`
      - `chmod 640 /etc/ssl/private/ci.cluster.local.key`
      - `chown root:ssl-cert /etc/ssl/private/ci.cluster.local.key`
      - `sensitive true`, guarded by `not_if { File.exist?('/etc/ssl/certs/ci.cluster.local.crt') && File.exist?('/etc/ssl/private/ci.cluster.local.key') }`
      - Notifies `:reload` on `service[nginx]` (delayed)
  - **status.cluster.local**:
    - `execute 'generate-ssl-cert-status.cluster.local'` — generates self-signed cert:
      - `openssl req -x509 -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/status.cluster.local.key -out /etc/ssl/certs/status.cluster.local.crt -passout pass:<ssl_passphrase> -subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=status.cluster.local/emailAddress=admin@example.com"`
      - `chmod 640 /etc/ssl/private/status.cluster.local.key`
      - `chown root:ssl-cert /etc/ssl/private/status.cluster.local.key`
      - `sensitive true`, guarded by `not_if { File.exist?('/etc/ssl/certs/status.cluster.local.crt') && File.exist?('/etc/ssl/private/status.cluster.local.key') }`
      - Notifies `:reload` on `service[nginx]` (delayed)
- Resources: package (1, array), group (1), directory (2), execute (3)

---

**5. sites** (`cookbooks/nginx-multisite/recipes/sites.rb`):
- Iterations: Runs **3 times** for sites — **test.cluster.local**, **ci.cluster.local**, **status.cluster.local**:
  - **test.cluster.local**:
    - `template '/etc/nginx/sites-available/test.cluster.local'` — source: `site.conf.erb`, mode: `0644`
      - Variables: `server_name=test.cluster.local`, `document_root=/opt/server/test`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/test.cluster.local.crt`, `key_file=/etc/ssl/private/test.cluster.local.key`
      - Template renders: HTTP server block (port 80) with `return 301 https://...`, HTTPS server block (port 443 ssl http2) with SSL cert/key, TLSv1.2/TLSv1.3, HSTS header, security headers (X-Frame-Options DENY, X-Content-Type-Options nosniff, X-XSS-Protection, Referrer-Policy, Content-Security-Policy), gzip, `try_files`, deny `.ht*` and `.git/.svn` locations, per-site access/error logs.
      - Notifies `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/test.cluster.local'` → `/etc/nginx/sites-available/test.cluster.local`; notifies `:reload` on `service[nginx]` (delayed)
  - **ci.cluster.local**:
    - `template '/etc/nginx/sites-available/ci.cluster.local'` — source: `site.conf.erb`, mode: `0644`
      - Variables: `server_name=ci.cluster.local`, `document_root=/opt/server/ci`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/ci.cluster.local.crt`, `key_file=/etc/ssl/private/ci.cluster.local.key`
      - Notifies `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/ci.cluster.local'` → `/etc/nginx/sites-available/ci.cluster.local`; notifies `:reload` on `service[nginx]` (delayed)
  - **status.cluster.local**:
    - `template '/etc/nginx/sites-available/status.cluster.local'` — source: `site.conf.erb`, mode: `0644`
      - Variables: `server_name=status.cluster.local`, `document_root=/opt/server/status`, `ssl_enabled=true`, `cert_file=/etc/ssl/certs/status.cluster.local.crt`, `key_file=/etc/ssl/private/status.cluster.local.key`
      - Notifies `:reload` on `service[nginx]` (delayed)
    - `link '/etc/nginx/sites-enabled/status.cluster.local'` → `/etc/nginx/sites-available/status.cluster.local`; notifies `:reload` on `service[nginx]` (delayed)
- `file '/etc/nginx/sites-enabled/default'` — action `:delete`; notifies `:reload` on `service[nginx]` (delayed)
- Resources: template (3), link (3), file (1)

---

## Custom Resources

### `ada_ada` (`cookbooks/nginx-multisite/resources/ada_ada.rb`)

**Purpose**: In-place line editor for configuration files. Finds a line matching a regex pattern and replaces the entire line, or appends the line if no match is found. Optionally creates a timestamped backup before writing.

**Properties**:
| Property | Type | Required | Default | Description |
|---|---|---|---|---|
| `file_path` | String | Yes (name property) | — | Path to the file to edit |
| `line` | String | Yes | — | The exact line content to write |
| `match` | String | No | — | Ruby regex pattern to find the line to replace |
| `backup` | Boolean | No | `true` | If true, writes `<file_path>.backup.<epoch>` before modifying |

**Action**: `:create` — Uses a `ruby_block` internally to read, modify, and write the file at converge time.

**Usage in cookbook**:
```ruby
# Disable root SSH login
ada_ada '/etc/ssh/sshd_config' do
  line 'PermitRootLogin no'
  match '^#\?PermitRootLogin'
  notifies :restart, 'service[ssh]', :delayed
end

# Disable password authentication
ada_ada '/etc/ssh/sshd_config' do
  line 'PasswordAuthentication no'
  match '^#\?PasswordAuthentication'
  notifies :restart, 'service[ssh]', :delayed
end
```

---

### `fetch_token` (`cookbooks/nginx-multisite/resources/fetch_token.rb`)

**Purpose**: Performs an OAuth2-style client credentials token fetch. POSTs `{ client_id, client_secret }` as JSON to an auth URL and stores the returned `access_token` in `node.run_state['access_token']`.

**Properties**:
| Property | Type | Required | Description |
|---|---|---|---|
| `auth_url` | String | Yes | Full URL of the OAuth token endpoint |
| `client_id` | String | Yes | OAuth client ID |
| `client_secret` | String | Yes | OAuth client secret (**sensitive**) |
| `access_token` | String | No | Output property — populated after fetch |

**Action**: `:fetch` — Uses Ruby `Net::HTTP` to POST JSON, parses response, sets `node.run_state['access_token']`.

**Usage in cookbook**:
```ruby
fetch_token 'get auth token' do
  auth_url 'https://auth.example.com/oauth/token'
  client_id 'nginx-multisite'
  client_secret 'sup3rs3cr3t'   # HARDCODED - must be migrated to a vault
end
```

---

### `fetch_and_parse_token` (`cookbooks/nginx-multisite/resources/fetch_and_parse_token.rb`)

**Purpose**: Performs an HTTP GET to a token URL and parses the response body for a specific pattern (`pattern1:(.+)`), extracting the value after the colon. Stores the result in `node.run_state['extracted_token']`.

**Properties**:
| Property | Type | Required | Description |
|---|---|---|---|
| `token_url` | String | Yes | Full URL to GET |
| `extracted_token` | String | No | Output property — populated after parse |

**Action**: `:fetch_and_parse` — Uses Ruby `Net::HTTP.get_response`, applies regex `/pattern1:(.+)/`, raises an error if pattern not found.

**Important note**: The regex pattern `pattern1:(.+)` appears to be a placeholder/example pattern. The actual production pattern must be confirmed with the cookbook maintainer before migration.

**Usage in cookbook**:
```ruby
fetch_and_parse_token 'get parsed token' do
  token_url 'https://api.example.com/token_endpoint'
end
```

---

## Dependencies

**External cookbook dependencies**:
- `cyberark-conjur` (~> 3.0) — provides the `conjur_variable()` helper used in `cookbooks/nginx-multisite/recipes/ssl.rb` to fetch the SSL passphrase from CyberArk Conjur

**System package dependencies**:
- `nginx` — web server
- `fail2ban` — intrusion prevention
- `ufw` — firewall management
- `openssl` — TLS certificate generation
- `ca-certificates` — CA certificate bundle

**Service dependencies** (systemd services managed):
- `nginx` — enabled, started; reloaded on config/cert/site changes
- `fail2ban` — enabled, started; restarted on jail.local changes
- `ssh` (sshd) — restarted only when `/etc/ssh/sshd_config` is modified by `ada_ada`

---

## Credentials

**Detection Summary**: 4 credentials detected across 3 files

---

### SSL Certificate Passphrase

- **Variable(s)**: `node['cyberark']['conjur']['variable']` → resolved value of Conjur variable `production/nginx/ssl_passphrase`; used inline as `-passout pass:<ssl_passphrase>` in `openssl req` commands
- **Source file(s)**: `cookbooks/nginx-multisite/attributes/default.rb`, `cookbooks/nginx-multisite/recipes/ssl.rb`
- **Current storage**: CyberArk Conjur vault (`conjur_variable()` call from `cyberark-conjur` cookbook ~> 3.0)
- **Source**:
  - **Provider**: CyberArk Conjur
  - **URL**: `https://conjur.example.com`
  - **Path**: `production/nginx/ssl_passphrase`
- **Usage context**: Passphrase for the RSA private key generated for each of the three nginx TLS certificates (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`). Passed as `-passout pass:...` to `openssl req -x509`. The `execute` resource is marked `sensitive true` to suppress log output.

---

### OAuth Client Secret (fetch_token)

- **Variable(s)**: `client_secret` property of `fetch_token 'get auth token'`; hardcoded value: `sup3rs3cr3t`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb`
- **Current storage**: **Hardcoded** directly in the recipe source code
- **Source**:
  - **Provider**: None — hardcoded in source code
  - **URL**: N/A
  - **Path**: N/A
- **Usage context**: OAuth2 client credentials grant — POSTed as `{ client_id: "nginx-multisite", client_secret: "sup3rs3cr3t" }` to `https://auth.example.com/oauth/token`. The returned `access_token` is stored in `node.run_state['access_token']`. **This is a critical security finding**: the secret must be migrated to a secrets manager (AAP Credential, HashiCorp Vault, or CyberArk Conjur) before production use.

---

### OAuth Token Endpoint URL (fetch_and_parse_token)

- **Variable(s)**: `token_url` property of `fetch_and_parse_token 'get parsed token'`; value: `https://api.example.com/token_endpoint`
- **Source file(s)**: `cookbooks/nginx-multisite/recipes/security.rb`
- **Current storage**: Hardcoded in recipe
- **Source**:
  - **Provider**: None — hardcoded in source code; token value destination unknown
  - **URL**: N/A
  - **Path**: N/A
- **Usage context**: HTTP GET to retrieve and parse a token using pattern `pattern1:(.+)`. The extracted value is stored in `node.run_state['extracted_token']`. The parse pattern appears to be a placeholder — confirm actual pattern with cookbook maintainer. The endpoint URL itself may not be sensitive, but the parsed token value likely is.

---

### CyberArk Conjur Connection Parameters

- **Variable(s)**: `node['cyberark']['conjur']['appliance_url']` = `https://conjur.example.com`, `node['cyberark']['conjur']['account']` = `myorg`
- **Source file(s)**: `cookbooks/nginx-multisite/attributes/default.rb`
- **Current storage**: Attribute defaults (non-secret connection parameters)
- **Source**:
  - **Provider**: CyberArk Conjur
  - **URL**: `https://conjur.example.com`
  - **Path**: N/A (connection parameters, not a secret path)
- **Usage context**: Used by the `cyberark-conjur` cookbook to authenticate to the Conjur appliance and retrieve the `production/nginx/ssl_passphrase` variable. The Conjur host identity/API key (not visible in this cookbook) must be configured separately on the node via the `cyberark-conjur` cookbook's own configuration mechanism.

---

## Checks for the Migration

**Files to verify**:
- `/etc/nginx/nginx.conf` — main nginx configuration
- `/etc/nginx/conf.d/security.conf` — global security headers and rate limiting
- `/etc/nginx/sites-available/test.cluster.local` — virtual host config
- `/etc/nginx/sites-available/ci.cluster.local` — virtual host config
- `/etc/nginx/sites-available/status.cluster.local` — virtual host config
- `/etc/nginx/sites-enabled/test.cluster.local` — symlink to sites-available
- `/etc/nginx/sites-enabled/ci.cluster.local` — symlink to sites-available
- `/etc/nginx/sites-enabled/status.cluster.local` — symlink to sites-available
- `/etc/nginx/sites-enabled/default` — must NOT exist (deleted)
- `/opt/server/test/index.html` — static file for test site
- `/opt/server/ci/index.html` — static file for CI site
- `/opt/server/status/index.html` — static file for status site
- `/etc/ssl/certs/test.cluster.local.crt` — TLS certificate
- `/etc/ssl/certs/ci.cluster.local.crt` — TLS certificate
- `/etc/ssl/certs/status.cluster.local.crt` — TLS certificate
- `/etc/ssl/private/test.cluster.local.key` — TLS private key (mode 640, group ssl-cert)
- `/etc/ssl/private/ci.cluster.local.key` — TLS private key (mode 640, group ssl-cert)
- `/etc/ssl/private/status.cluster.local.key` — TLS private key (mode 640, group ssl-cert)
- `/etc/fail2ban/jail.local` — fail2ban jail configuration
- `/etc/sysctl.d/99-security.conf` — kernel security parameters
- `/etc/ssh/sshd_config` — SSH daemon configuration (PermitRootLogin no, PasswordAuthentication no)
- `/etc/ssh/sshd_config.backup.<epoch>` — backup(s) created by ada_ada (one or two files)

**Service endpoints to check**:
- Port 80 (HTTP) — nginx, all three virtual hosts (redirect to HTTPS)
- Port 443 (HTTPS) — nginx, all three virtual hosts (TLS)
- Port 22 (SSH) — allowed through UFW
- Unix sockets: None
- Network interfaces: nginx binds to all interfaces (no `listen` IP specified in templates)

**Templates rendered**:
- `nginx.conf.erb` → `/etc/nginx/nginx.conf` — rendered **1 time**
- `security.conf.erb` → `/etc/nginx/conf.d/security.conf` — rendered **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/test.cluster.local` — rendered **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/ci.cluster.local` — rendered **1 time**
- `site.conf.erb` → `/etc/nginx/sites-available/status.cluster.local` — rendered **1 time**
- `fail2ban.jail.local.erb` → `/etc/fail2ban/jail.local` — rendered **1 time**
- `sysctl-security.conf.erb` → `/etc/sysctl.d/99-security.conf` — rendered **1 time**

Total: `site.conf.erb` renders **3 times** (once per site
# MIGRATION FROM CHEF TO ANSIBLE

## Executive Summary

This repository contains a single Chef cookbook (`nginx-multisite`, version 1.0.0) that provisions and configures Nginx as a multi-site reverse proxy with SSL termination, firewall hardening, and SSH hardening. The cookbook is self-contained — it has no Berksfile or Policyfile, relying on a single external community dependency (`cyberark-conjur ~> 3.0`) and three custom Chef resources defined inline.

The migration scope is moderate in size but carries meaningful security complexity: secrets are fetched live from CyberArk Conjur at converge time, a hardcoded OAuth client secret exists in the security recipe, and self-signed TLS certificates are generated on-node using an OpenSSL shell command. All of these patterns require deliberate re-implementation in Ansible.

**Estimated timeline**: 2–3 weeks for a single engineer, including testing.

---

## Module Migration Plan

This repository contains one Chef cookbook that needs to be migrated to an Ansible role (or a small collection of roles).

---

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
All paths below were confirmed from the live directory listing of this repository.

- **nginx-multisite**:
  - Description: Nginx web server cookbook that installs and configures Nginx for multiple SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`), generates self-signed TLS certificates per vhost via OpenSSL, manages per-site document roots with static `index.html` content, and applies a full security baseline (fail2ban, UFW firewall rules, SSH hardening, and kernel sysctl tuning).
  - Path: `.` (repository root — the cookbook is the repository)
  - Technology: Chef (chef_version `>= 16.0`)
  - Key Features:
    - Nginx installation with a global `nginx.conf` and a per-site `site.conf.erb` template (HTTP→HTTPS redirect, TLS 1.2/1.3, HSTS, CSP, X-Frame-Options, X-Content-Type-Options)
    - Per-vhost self-signed certificate generation using `openssl req -x509` with a passphrase fetched from CyberArk Conjur (`production/nginx/ssl_passphrase`)
    - `sites-available` / `sites-enabled` symlink management; default site removed
    - fail2ban installation and `jail.local` configuration via ERB template
    - UFW firewall configured with default-deny, allowing SSH/HTTP/HTTPS
    - SSH hardening (`PermitRootLogin no`, `PasswordAuthentication no`) via the custom `ada_ada` line-in-file resource
    - Kernel sysctl security tuning via `/etc/sysctl.d/99-security.conf`
    - OAuth token fetch at converge time via two custom resources (`fetch_token`, `fetch_and_parse_token`)

---

### Infrastructure Files

- `metadata.rb`: Cookbook metadata — name, version, supported OS (Ubuntu ≥ 18.04, CentOS ≥ 7), and the single external dependency `cyberark-conjur ~> 3.0`. Drives the Ansible role's `meta/main.yml` and platform matrix.
- `attributes/default.rb`: Hiera-equivalent defaults — vhost map, SSL certificate/key paths, Conjur connection settings, and security feature flags. All values migrate to Ansible `defaults/main.yml`.
- `recipes/default.rb`: Orchestration entry point; calls `security → nginx → ssl → sites` in order. Maps to the task include order in the Ansible role's `tasks/main.yml`.
- `recipes/nginx.rb`: Nginx package install, `nginx.conf` and `security.conf` template rendering, document-root directory creation, static file deployment, and service management.
- `recipes/ssl.rb`: `openssl`/`ca-certificates` package install, `ssl-cert` group creation, certificate/key directory setup, and per-vhost self-signed certificate generation using a Conjur-fetched passphrase.
- `recipes/sites.rb`: Per-vhost `sites-available` config rendering, `sites-enabled` symlink creation, and removal of the default Nginx site.
- `recipes/security.rb`: fail2ban and UFW installation and configuration, OAuth token fetches (custom resources), sysctl security template, and SSH config hardening via `ada_ada`.
- `resources/ada_ada.rb`: Custom Chef resource implementing an idempotent line-in-file/replace operation with regex matching and automatic backup. Migrates directly to Ansible's `ansible.builtin.lineinfile` module.
- `resources/fetch_token.rb`: Custom Chef resource that POSTs `client_id`/`client_secret` to an OAuth endpoint and stores the resulting `access_token` in `node.run_state`. Migrates to an Ansible `uri` task with `register`.
- `resources/fetch_and_parse_token.rb`: Custom Chef resource that GETs a token URL and extracts a value matching the pattern `pattern1:<value>` via regex. Migrates to an Ansible `uri` + `set_fact` with a regex filter.
- `templates/default/nginx.conf.erb`: Global Nginx configuration (worker processes, logging, gzip, virtual-host includes). Migrates to a Jinja2 template.
- `templates/default/site.conf.erb`: Per-vhost server block with conditional SSL, HSTS, security headers, gzip, and location rules. Migrates to a Jinja2 template with `{% if ssl_enabled %}` blocks.
- `templates/default/security.conf.erb`: Nginx-level security headers snippet (referenced by `nginx.rb`). Migrates to a Jinja2 template.
- `templates/default/fail2ban.jail.local.erb`: fail2ban jail configuration. Migrates to a Jinja2 template.
- `templates/default/sysctl-security.conf.erb`: Kernel sysctl hardening parameters. Migrates to a Jinja2 template.
- `files/default/ci/`, `files/default/status/`, `files/default/test/`: Static `index.html` files for each vhost. Migrate to `files/` in the Ansible role and are deployed with `ansible.builtin.copy`.

---

### Target Details

- **Operating System**: Ubuntu ≥ 18.04 or CentOS ≥ 7, as declared in `metadata.rb`. The cookbook uses `www-data` as the Nginx user and `ufw` for the firewall, both of which are Debian/Ubuntu conventions. The Ansible role should default to **Ubuntu 22.04 LTS** and include a conditional for CentOS/RHEL (where `firewalld` replaces `ufw` and the Nginx user is `nginx`).
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified. The Conjur appliance URL (`https://conjur.example.com`) and OAuth endpoint (`https://auth.example.com`) are generic FQDNs with no cloud-provider-specific metadata.

---

## Migration Approach

### Key Dependencies to Address

- **cyberark-conjur (~> 3.0)**: The cookbook uses the `conjur_variable()` helper (provided by this community cookbook) to retrieve the SSL passphrase at converge time. In Ansible, replace with the **CyberArk Conjur Ansible collection** (`cyberark.conjur`) and its `conjur_variable` lookup plugin, or use the Conjur REST API directly via `ansible.builtin.uri` + `ansible.builtin.set_fact`. The Conjur appliance URL, account, and variable path are already parameterised in `attributes/default.rb` and map cleanly to Ansible variables.
- **fetch_token custom resource** (OAuth client credentials flow): Replace with an `ansible.builtin.uri` task (POST with JSON body containing `client_id` and `client_secret`) and `register` the response. Store the token in a fact for downstream tasks.
- **fetch_and_parse_token custom resource** (regex token extraction): Replace with `ansible.builtin.uri` (GET) + `ansible.builtin.set_fact` using the `regex_search` Jinja2 filter to extract the `pattern1:<value>` pattern.
- **ada_ada custom resource** (line-in-file with regex): Replace directly with `ansible.builtin.lineinfile` using its `regexp` and `line` parameters — a one-to-one mapping.

---

### Security Considerations

- **CyberArk Conjur secret (`production/nginx/ssl_passphrase`)**: The SSL certificate passphrase is correctly externalised to Conjur. In Ansible, use the `cyberark.conjur` collection lookup or the Conjur REST API. Never store the passphrase in Ansible variables files or inventory. Use `no_log: true` on any task that handles the passphrase value.
- **Hardcoded OAuth client secret in `recipes/security.rb`**: The `fetch_token` resource call in `security.rb` passes `client_secret: 'sup3rs3cr3t'` as a literal string. **This is a critical security finding.** Before migration, this credential must be rotated and moved to Ansible Vault or a secrets manager. In the Ansible role, reference it as `{{ oauth_client_secret }}` sourced from an Ansible Vault-encrypted variable file.
- **Self-signed TLS certificates**: Certificates are generated on-node with `openssl req -x509`. The `execute` resource is marked `sensitive true`, which suppresses log output in Chef. In Ansible, use `community.crypto.openssl_privatekey` and `community.crypto.x509_certificate` (or `openssl_certificate`) modules, and set `no_log: true` on tasks that handle the passphrase. For production, replace self-signed certificates with CA-signed or Let's Encrypt certificates.
- **SSL/TLS hardening**: The `site.conf.erb` template enforces TLS 1.2/1.3 only, strong cipher suites, HSTS, and a full set of security response headers (CSP, X-Frame-Options, X-Content-Type-Options, X-XSS-Protection, Referrer-Policy). These must be faithfully reproduced in the Jinja2 template — do not use a generic Nginx role template that omits these headers.
- **SSH hardening**: `PermitRootLogin no` and `PasswordAuthentication no` are applied via `ada_ada`. In Ansible, use `ansible.builtin.lineinfile` with `validate` pointing to `sshd -t -f %s` to prevent locking out access on misconfiguration. Ensure the Ansible control node connects via key-based auth before applying `PasswordAuthentication no`.
- **UFW firewall**: UFW is configured via `execute` resources with idempotency guards (`not_if`). In Ansible, use `community.general.ufw` module for idempotent, declarative firewall management. For CentOS/RHEL targets, substitute `ansible.posix.firewalld`.
- **File permissions on TLS private keys**: Keys are `chmod 640` and owned `root:ssl-cert`. Ansible's `ansible.builtin.file` module must replicate these exact permissions; deviating will break Nginx startup or expose private keys.

---

### Technical Challenges

- **Conjur integration at task time**: Chef fetches the Conjur secret during the compile/converge phase using a Ruby helper. Ansible must fetch it before the certificate-generation task runs. Use a `vars_files` lookup or a dedicated pre-task block to retrieve and register the secret, ensuring it is available to the `openssl` tasks that follow.
- **Dynamic vhost loop**: Both `recipes/nginx.rb` and `recipes/sites.rb` iterate over `node['nginx']['sites']` (a hash). In Ansible, this maps to a `loop` over a `nginx_sites` dictionary variable using `dict2items`. The Jinja2 template for `site.conf` must handle the same conditional SSL logic as the ERB template.
- **`fetch_and_parse_token` regex pattern is a placeholder**: The resource matches `pattern1:(.+)` — an obviously non-production pattern. Before migration, the actual token format and endpoint must be clarified with the owning team. The Ansible replacement cannot be written correctly until the real pattern is known.
- **OS-family divergence (Ubuntu vs. CentOS)**: The cookbook supports both but uses Ubuntu-specific tooling (`ufw`, `www-data` user). The Ansible role should use `ansible_os_family` conditionals to switch between `ufw`/`firewalld` and `www-data`/`nginx` user accounts. This adds branching complexity that does not exist in the current Chef code.
- **`ada_ada` backup behaviour**: The custom resource writes a timestamped `.backup.<epoch>` file on every change. Ansible's `lineinfile` supports `backup: yes` but uses a different naming convention. If backup files are audited or consumed downstream, the naming difference must be accounted for.
- **Service restart ordering**: Chef's notification system (`notifies :reload, 'service[nginx]', :delayed`) batches and deduplicates service reloads. Ansible handlers provide the same semantics via `notify` + `handlers`, but the handler must be defined once and notified from multiple tasks — ensure the handler is not duplicated across task files.
- **No Berksfile / dependency lockfile**: There is no `Berksfile` or `Policyfile.rb`, meaning the `cyberark-conjur` cookbook version is only loosely pinned (`~> 3.0`). The exact version in use in production is unknown. Verify the installed version on existing nodes before migration to ensure the Conjur API behaviour being relied upon is understood.

---

### Migration Order

1. **Security baseline (fail2ban, UFW, SSH hardening, sysctl)** — No external secret dependencies; uses only package installs, templates, `lineinfile`, and `ufw` module calls. Low risk, high value as a standalone hardening role. Validates the Ansible role skeleton, variable structure, and handler patterns before tackling secrets.
2. **Nginx core installation and global configuration** — Package install, `nginx.conf` Jinja2 template, `security.conf` snippet, document-root creation, static file deployment, and service management. No secrets involved; validates template rendering and the vhost loop logic.
3. **SSL certificate generation** — Depends on Conjur integration being resolved. Migrate `openssl` package install, directory/group setup, and per-vhost certificate generation using `community.crypto` modules. Requires the Conjur lookup to be working and the passphrase available as a variable.
4. **Vhost site configuration** — Depends on SSL (cert/key paths must exist). Render per-vhost `site.conf` Jinja2 templates, manage `sites-available`/`sites-enabled` symlinks, and remove the default site.
5. **OAuth token fetch tasks** — Depends on clarification of the `fetch_and_parse_token` regex pattern and rotation of the hardcoded `client_secret`. Implement last, after the real endpoint contract is confirmed with the owning team.

---

### Assumptions

1. **Single-cookbook repository**: The repository root is the cookbook itself (no wrapper cookbook, no control repo, no Berksfile). It is assumed this cookbook is applied to nodes directly (e.g., via `chef-client -o nginx-multisite`) rather than through a role or environment file not present in this repository.
2. **Conjur is reachable from Ansible control node**: The migration assumes the Ansible control node (or the managed nodes, depending on lookup strategy) can reach `https://conjur.example.com` at playbook runtime. If Conjur is not available in the target environment, an alternative secrets backend (Ansible Vault, HashiCorp Vault, AWS Secrets Manager) must be chosen before migration begins.
3. **`fetch_and_parse_token` pattern is a placeholder**: The regex `pattern1:(.+)` is not a real production pattern. It is assumed the owning team knows the actual token format and endpoint; this must be clarified before the corresponding Ansible task can be written.
4. **`fetch_token` OAuth endpoint is internal**: `https://auth.example.com/oauth/token` appears to be an internal service. It is assumed this endpoint will remain reachable from Ansible-managed nodes and that the `client_secret` will be rotated and stored in Ansible Vault prior to migration.
5. **Self-signed certificates are acceptable for the target environment**: The cookbook generates self-signed certificates. It is assumed this is intentional (development/internal cluster). If the target environment requires CA-signed or Let's Encrypt certificates, the SSL task block will need a more significant redesign.
6. **Ubuntu is the primary target OS**: The `www-data` user, `ufw`, and `apt`-based package installs suggest Ubuntu is the primary platform. CentOS support is declared in `metadata.rb` but no CentOS-specific conditionals exist in the recipes. The Ansible role will need explicit `when: ansible_os_family == "RedHat"` branches to be truly cross-platform.
7. **No existing Ansible inventory or infrastructure**: It is assumed this is a greenfield Ansible adoption and that no existing Ansible roles, collections, or inventory files constrain the role structure.
8. **`cyberark-conjur` cookbook version in production is unknown**: Without a Berksfile.lock or Policyfile.lock, the exact version of the `cyberark-conjur` cookbook currently deployed is unknown. The `conjur_variable()` helper's behaviour may differ between minor versions of the `~> 3.0` range.
9. **Static site content (`index.html` files) is managed by this cookbook**: The `files/default/ci`, `files/default/status`, and `files/default/test` directories contain static HTML. It is assumed these are intentionally managed as cookbook files and should be migrated to the Ansible role's `files/` directory, not sourced from a separate artifact repository.
10. **SSH access via key-based auth is already in place**: The security recipe disables password authentication for SSH. It is assumed that key-based SSH access for the Ansible control node is already configured on target hosts before the playbook is run, to avoid self-lockout.

# MIGRATION FROM CHEF TO ANSIBLE

## Executive Summary

This repository contains a single Chef cookbook (`nginx-multisite`, v1.0.0) that provisions a hardened Nginx web server hosting three SSL-enabled internal subdomains (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`). The cookbook integrates CyberArk Conjur for secrets retrieval, implements host-level security hardening (fail2ban, UFW, sysctl kernel parameters, SSH hardening), and uses three custom Chef resources for in-line file editing and OAuth token fetching.

**Migration scope**: 1 cookbook, 4 recipes, 3 custom resources, 5 ERB templates, 3 static HTML files, and 1 external dependency (CyberArk Conjur).

**Complexity**: Medium. The Nginx and security hardening logic maps cleanly to well-supported Ansible modules. The primary risk areas are (1) replacing the CyberArk Conjur secrets integration, (2) replicating the custom `fetch_token` / `fetch_and_parse_token` resource behaviour, and (3) a hardcoded `client_secret` credential in `recipes/security.rb` that must be remediated before migration.

**Estimated timeline**: 2–3 sprints (4–6 weeks) for a single engineer, including testing on both Ubuntu and CentOS targets.

---

## Module Migration Plan

This repository contains one Chef cookbook that needs to be migrated to an Ansible role (or a small set of roles).

---

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
All paths below were confirmed from the repository tree and file reads performed during analysis.

- **nginx-multisite**:
  - Description: Nginx multi-site web server cookbook that installs and configures Nginx with three SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`), deploys per-site static `index.html` content, generates self-signed TLS certificates via OpenSSL (passphrase retrieved from CyberArk Conjur), applies a hardened `nginx.conf` and a `security.conf` with rate-limiting and buffer-overflow protections, and manages the `sites-available` / `sites-enabled` symlink pattern.
  - Path: `.` (cookbook root — `nginx-multisite`)
  - Technology: Chef (chef_version `>= 16.0`)
  - Key Features:
    - Multi-vhost Nginx configuration driven by a node-attribute hash (`node['nginx']['sites']`)
    - Per-site self-signed TLS certificate generation with OpenSSL; passphrase fetched at converge time from CyberArk Conjur (`conjur_variable()` helper)
    - HTTP → HTTPS redirect, TLSv1.2/1.3-only, HSTS, and a full set of security response headers (X-Frame-Options, CSP, Referrer-Policy, etc.) in `site.conf.erb`
    - Global Nginx security hardening via `security.conf.erb` (rate-limit zones, buffer limits, timeout tuning, `server_tokens off`)
    - Host firewall via UFW (default-deny, allow SSH/80/443) managed through idempotent `execute` blocks
    - fail2ban with jails for `sshd`, `nginx-http-auth`, `nginx-limit-req`, and `nginx-botsearch`
    - Kernel hardening via `/etc/sysctl.d/99-security.conf` (IP spoofing protection, ICMP redirect suppression, SYN-cookie flood protection, IPv6 disable)
    - SSH hardening: `PermitRootLogin no` and `PasswordAuthentication no` applied via the custom `ada_ada` resource
    - Three custom Chef resources: `ada_ada` (in-place line replacement in config files with backup), `fetch_token` (OAuth2 client-credentials token fetch), `fetch_and_parse_token` (HTTP GET + regex token extraction)

---

### Infrastructure Files

- `metadata.rb`: Cookbook metadata — name, version, supported OS (Ubuntu ≥ 18.04, CentOS ≥ 7), and the single external dependency `cyberark-conjur ~> 3.0`. Must be translated into Ansible `meta/main.yml` and `requirements.yml`.
- `attributes/default.rb`: Node attribute defaults defining the site map, SSL certificate/key paths, CyberArk Conjur connection parameters, and security feature flags. These become Ansible role `defaults/main.yml` variables.
- `recipes/default.rb`: Orchestration entry point — includes the four sub-recipes in order: `security → nginx → ssl → sites`. Maps to an Ansible role `tasks/main.yml` with `import_tasks` or `include_role` calls.
- `recipes/nginx.rb`: Installs Nginx, deploys `nginx.conf` and `security.conf` from templates, manages the `nginx` service, creates document-root directories, and copies static `index.html` files. Maps to Ansible `ansible.builtin.package`, `ansible.builtin.template`, `ansible.builtin.service`, `ansible.builtin.file`, and `ansible.builtin.copy` tasks.
- `recipes/security.rb`: Installs and configures fail2ban and UFW, applies sysctl hardening, hardens SSH config, and calls the two custom token-fetch resources. Maps to Ansible `ansible.builtin.package`, `community.general.ufw`, `ansible.builtin.template`, `ansible.posix.sysctl`, and `ansible.builtin.lineinfile` tasks.
- `recipes/ssl.rb`: Installs OpenSSL/ca-certificates, fetches the SSL passphrase from Conjur, creates certificate directories, and generates per-site self-signed certificates. Maps to Ansible `ansible.builtin.package`, `ansible.builtin.file`, and `ansible.builtin.command` (or `community.crypto.openssl_privatekey` + `community.crypto.x509_certificate`) tasks.
- `recipes/sites.rb`: Creates `sites-available` vhost config files from `site.conf.erb`, symlinks them into `sites-enabled`, and removes the default site. Maps to Ansible `ansible.builtin.template` and `ansible.builtin.file` (state: link / absent) tasks.
- `resources/ada_ada.rb`: Custom resource that performs regex-based in-place line replacement in a file, with timestamped backup. Replace with `ansible.builtin.lineinfile` (which natively supports `regexp`, `line`, and `backup` parameters).
- `resources/fetch_token.rb`: Custom resource that POSTs client credentials to an OAuth2 token endpoint and stores the `access_token` in `node.run_state`. Replace with `ansible.builtin.uri` (method: POST) storing the result in an Ansible variable.
- `resources/fetch_and_parse_token.rb`: Custom resource that GETs a URL and extracts a value matching `pattern1:(.+)` via regex. Replace with `ansible.builtin.uri` + `ansible.builtin.set_fact` using a Jinja2 regex filter (`regex_search`).
- `templates/default/nginx.conf.erb`: Main Nginx configuration (worker processes, events, HTTP block, logging, gzip, include paths). Convert to a static Ansible `files/nginx.conf` or a Jinja2 template `templates/nginx.conf.j2` if parameterisation is needed.
- `templates/default/security.conf.erb`: Nginx security sub-configuration (rate-limit zones, buffer limits, timeouts, global SSL settings). No ERB variables — convert directly to a static file or minimal Jinja2 template.
- `templates/default/site.conf.erb`: Per-vhost Nginx server block with HTTP→HTTPS redirect, SSL config, HSTS, security headers, and gzip. Convert to `templates/site.conf.j2` with Jinja2 conditionals replacing ERB `<% if %>` blocks.
- `templates/default/fail2ban.jail.local.erb`: fail2ban `jail.local` with four jails (sshd, nginx-http-auth, nginx-limit-req, nginx-botsearch). No ERB variables — convert to a static file or `templates/fail2ban.jail.local.j2`.
- `templates/default/sysctl-security.conf.erb`: Kernel hardening parameters for `/etc/sysctl.d/99-security.conf`. No ERB variables — convert to a static file or use `ansible.posix.sysctl` tasks directly.
- `files/default/ci/index.html`: Static HTML placeholder for the `ci.cluster.local` document root. Copy directly into the Ansible role `files/` directory.
- `files/default/status/index.html`: Static HTML placeholder for the `status.cluster.local` document root. Copy directly into the Ansible role `files/` directory.
- `files/default/test/index.html`: Static HTML placeholder for the `test.cluster.local` document root. Copy directly into the Ansible role `files/` directory.

---

### Target Details

- **Operating System**: Ubuntu ≥ 18.04 (primary, given `www-data` user, UFW, `/var/log/auth.log`, and `apt`-style package names) and CentOS ≥ 7 (secondary, declared in `metadata.rb`). The cookbook does not branch on OS family, so the Ansible role should use `ansible_os_family` conditionals to handle package-name and path differences (e.g., `firewalld` vs. `ufw` on CentOS, `sshd` vs. `ssh` service name).
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified. The internal `.cluster.local` domain and self-signed certificates suggest an on-premises or private-cloud deployment.

---

## Migration Approach

### Key Dependencies to Address

- **cyberark-conjur (~> 3.0)**: The cookbook depends on the `cyberark-conjur` Chef supermarket cookbook, which provides the `conjur_variable()` helper used in `recipes/ssl.rb` to retrieve the SSL key passphrase at converge time. In Ansible, replace with the **CyberArk Conjur Ansible collection** (`cyberark.conjur`) and its `conjur_variable` lookup plugin, or use `ansible.builtin.uri` to call the Conjur REST API directly. The Conjur appliance URL, account, and variable path are already externalised in `attributes/default.rb` and will map cleanly to Ansible variables.
- **OAuth2 token endpoint (https://auth.example.com)**: Used by the `fetch_token` resource in `recipes/security.rb`. Replace with `ansible.builtin.uri` (method: POST, body_format: json) and register the response as an Ansible variable.
- **Token parsing endpoint (https://api.example.com/token_endpoint)**: Used by `fetch_and_parse_token`. Replace with `ansible.builtin.uri` + `ansible.builtin.set_fact` using the `regex_search` Jinja2 filter to extract the `pattern1:(.+)` match.
- **community.general.ufw** (Ansible Galaxy): Required to replace the idempotent UFW `execute` blocks. Install via `ansible-galaxy collection install community.general`.
- **ansible.posix** (Ansible Galaxy): Provides `ansible.posix.sysctl` for managing kernel parameters idempotently, replacing the `template` + `execute[reload_sysctl]` pattern.
- **community.crypto** (Ansible Galaxy, optional): Provides `openssl_privatekey` and `x509_certificate` modules as a more idiomatic replacement for the raw `openssl req` shell command used in `recipes/ssl.rb`.

---

### Security Considerations

- **Hardcoded `client_secret` in `recipes/security.rb`**: The `fetch_token` resource is called with `client_secret: 'sup3rs3cr3t'` as a literal string. This is a **critical finding** — the credential is stored in plain text in source control. Before or during migration, this value must be moved to Ansible Vault (`ansible-vault encrypt_string`) or retrieved from CyberArk Conjur / another secrets manager at runtime. The Ansible task should use `no_log: true` to suppress the value from play output.
- **CyberArk Conjur SSL passphrase**: The passphrase for self-signed certificate private keys is fetched from Conjur at runtime (`production/nginx/ssl_passphrase`). The Conjur integration must be replicated in Ansible before the SSL recipe is migrated; the passphrase must never appear in playbook variables or logs. Use the `cyberark.conjur` lookup plugin or Ansible Vault as a fallback for non-Conjur environments.
- **SSL/TLS certificate management**: All three sites use self-signed certificates generated at converge time. The `openssl req` command is marked `sensitive true` in Chef, suppressing output. The equivalent Ansible task must set `no_log: true`. For production use, consider replacing self-signed certificates with certificates from an internal CA or Let's Encrypt.
- **SSH hardening**: `PermitRootLogin no` and `PasswordAuthentication no` are applied via the `ada_ada` resource. In Ansible, `ansible.builtin.lineinfile` with `regexp` and `backup: yes` is a direct equivalent. Ensure the Ansible control node has a non-root SSH user with key-based authentication configured on all targets *before* applying these settings, or the playbook will lock itself out.
- **UFW firewall**: The cookbook enforces a default-deny policy. Ansible's `community.general.ufw` module must be applied in the same order (set default policy first, then add allow rules, then enable) to avoid cutting off the Ansible SSH connection mid-play. Use `community.general.ufw` with `state: enabled` only after all allow rules are in place.
- **Security headers and TLS configuration**: The `site.conf.erb` template enforces HSTS (`max-age=31536000; includeSubDomains`), a strict CSP, and TLSv1.2/1.3-only ciphers. These settings must be preserved verbatim in the Jinja2 template to maintain the security posture.
- **fail2ban jails**: Four jails are configured (sshd, nginx-http-auth, nginx-limit-req, nginx-botsearch). The `jail.local` template has no ERB variables and can be copied as-is; however, the `logpath` values assume Ubuntu (`/var/log/auth.log`). CentOS targets use `/var/log/secure` — add an OS-family conditional in the Jinja2 template.

---

### Technical Challenges

- **Custom `ada_ada` resource → `ansible.builtin.lineinfile`**: The `ada_ada` resource performs regex-based line replacement with a timestamped file backup. `ansible.builtin.lineinfile` covers the core functionality (`regexp`, `line`, `backup`). The timestamped backup naming (`<file>.backup.<epoch>`) is not replicated by Ansible's single-backup behaviour — document this behavioural difference for the operations team.
- **`fetch_token` / `fetch_and_parse_token` resources**: These custom resources embed Ruby HTTP logic. The `fetch_and_parse_token` resource uses a hardcoded regex pattern (`pattern1:(.+)`) that appears to be a placeholder. The actual production pattern must be confirmed before migration; if it is genuinely a placeholder, the resource may not be in active use and could be dropped.
- **Cross-platform support (Ubuntu vs. CentOS)**: The cookbook declares support for both OS families but contains no `platform?` guards. Several assumptions are Ubuntu-specific: `www-data` user/group, `ufw` package, `ssh` service name (`sshd` on CentOS), and `/var/log/auth.log`. The Ansible role must add `when: ansible_os_family == 'Debian'` / `'RedHat'` conditionals, or split into OS-specific task files.
- **Node attribute → Ansible variable mapping**: The `node['nginx']['sites']` hash drives the entire multi-site loop. In Ansible, this becomes a `nginx_sites` dictionary variable in `defaults/main.yml`. All loops in `recipes/nginx.rb`, `recipes/ssl.rb`, and `recipes/sites.rb` must be rewritten as `loop` / `with_dict` task iterations over this variable.
- **Conjur `conjur_variable()` helper**: This is a Chef resource method provided by the `cyberark-conjur` cookbook. There is no direct drop-in equivalent in Ansible core; the `cyberark.conjur` collection must be installed and the Conjur host identity configured on the managed node (or the lookup plugin used from the control node). This is the most complex external dependency to replicate.
- **Service name inconsistency**: Chef uses `service 'ssh'` (Ubuntu service name) throughout. On CentOS the service is `sshd`. The Ansible role should use a variable (e.g., `ssh_service_name`) defaulting to `ssh` on Debian and `sshd` on RedHat.
- **Idempotency of `execute` blocks**: The UFW `execute` blocks use `not_if` shell guards for idempotency. `community.general.ufw` handles idempotency natively. The `execute[reload_sysctl]` block uses `action :nothing` + notify — replace with `ansible.posix.sysctl` (which applies and persists values atomically) or a handler calling `command: sysctl -p`.

---

### Migration Order

1. **Variables and defaults** — Translate `attributes/default.rb` to `defaults/main.yml`; establish the `nginx_sites` variable structure and Conjur connection variables. This unblocks all subsequent tasks.
2. **Security hardening (non-Nginx)** — Migrate `recipes/security.rb` hardening tasks: sysctl (`ansible.posix.sysctl`), fail2ban (`ansible.builtin.package` + `ansible.builtin.template` + `ansible.builtin.service`), SSH hardening (`ansible.builtin.lineinfile`), and UFW (`community.general.ufw`). Exclude the `fetch_token` / `fetch_and_parse_token` calls until the token endpoint purpose is clarified. This is low-risk and high-value — it can be tested independently of Nginx.
3. **Nginx installation and base configuration** — Migrate `recipes/nginx.rb`: install Nginx, deploy `nginx.conf` and `security.conf` templates, create document roots, copy static HTML files, manage the `nginx` service. Straightforward mapping to core Ansible modules.
4. **Secrets integration (CyberArk Conjur)** — Install and configure the `cyberark.conjur` Ansible collection; validate that the `conjur_variable` lookup can retrieve `production/nginx/ssl_passphrase` from the target Conjur instance. This must be completed before the SSL recipe is migrated.
5. **SSL certificate generation** — Migrate `recipes/ssl.rb`: create SSL directories, generate per-site self-signed certificates using `community.crypto` modules (preferred) or `ansible.builtin.command` with `no_log: true`. Validate certificate files are created with correct ownership and permissions.
6. **Nginx virtual host configuration** — Migrate `recipes/sites.rb`: template per-site `site.conf.j2` files into `sites-available`, create `sites-enabled` symlinks, remove the default site, and trigger an Nginx reload handler.
7. **Token fetch resources** — Investigate whether `fetch_token` and `fetch_and_parse_token` are actively used in production (the regex pattern `pattern1:(.+)` suggests a placeholder). If active, migrate to `ansible.builtin.uri` tasks with `no_log: true` and move `client_secret` to Ansible Vault. If unused, remove.
8. **Cross-platform validation** — Add OS-family conditionals for CentOS/RHEL targets; test the full role against both Ubuntu 20.04/22.04 and CentOS 7/8 in a CI pipeline (Molecule recommended).

---

### Assumptions

1. **Single cookbook = single Ansible role**: The entire `nginx-multisite` cookbook is assumed to map to one Ansible role (e.g., `nginx_multisite`). If the security hardening tasks are reusable across other roles, they may be split into a separate `security_baseline` role.
2. **CyberArk Conjur is reachable from Ansible control node or managed nodes**: The migration assumes the Conjur appliance at `https://conjur.example.com` remains available and that either the `cyberark.conjur` lookup plugin (control-node-side) or the Conjur host identity (managed-node-side) can be configured. If Conjur is being decommissioned, an alternative secrets backend (Ansible Vault, HashiCorp Vault, AWS Secrets Manager) must be chosen before migration begins.
3. **`fetch_token` / `fetch_and_parse_token` regex is a placeholder**: The pattern `pattern1:(.+)` in `fetch_and_parse_token.rb` does not resemble a real token format. It is assumed this is a sanitised example and the real pattern must be obtained from the team before migration.
4. **`client_secret: 'sup3rs3cr3t'` is not the production value**: The hardcoded secret in `recipes/security.rb` is assumed to be a placeholder or development value. The real production credential must be sourced from the team and stored in Ansible Vault or Conjur.
5. **Self-signed certificates are intentional for this environment**: The cookbook generates self-signed certificates rather than using a CA or ACME. This is assumed to be correct for the target environment (internal cluster). If production requires CA-signed certificates, the SSL tasks will need significant rework.
6. **Ubuntu is the primary target OS**: The cookbook supports both Ubuntu and CentOS, but all implementation details (package names, user names, log paths, service names) are Ubuntu-centric. CentOS support is treated as secondary and will require additional conditional logic.
7. **No Berksfile or Policyfile present**: No `Berksfile`, `Policyfile.rb`, or `Berksfile.lock` was found in the repository tree. It is assumed cookbook dependencies are managed via the Chef Infra Server's dependency resolver or a wrapper cookbook not present in this repository.
8. **Static HTML files are complete**: The three `index.html` files under `files/default/` are assumed to be the final content for each site's document root, not placeholders.
9. **`www-data` user exists on all targets**: The cookbook assumes `www-data` as the Nginx worker user and file owner. On CentOS, Nginx typically runs as `nginx`. The Ansible role should parameterise this with a variable defaulting per OS family.
10. **No existing Ansible inventory or playbook structure**: The migration plan assumes a greenfield Ansible role structure. If an existing Ansible control repository exists, the new role should be integrated into it following its established conventions.

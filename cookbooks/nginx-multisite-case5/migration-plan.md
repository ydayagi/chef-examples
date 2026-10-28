# MIGRATION FROM CHEF TO ANSIBLE

## Executive Summary

This repository contains a single Chef cookbook (`nginx-multisite`, v1.0.0) that provisions a hardened Nginx web server hosting three SSL-enabled virtual hosts on an internal cluster domain. The cookbook orchestrates four tightly coupled concerns: OS-level security hardening, Nginx installation and configuration, SSL certificate generation, and per-site virtual-host deployment. It also includes three custom Chef resources that implement in-line file editing, OAuth token fetching, and token parsing.

The migration scope is **one cookbook with four recipes, three custom resources, five ERB templates, three static site files, and one external dependency (CyberArk Conjur)**. Overall complexity is **moderate**: the Nginx and site-deployment logic maps cleanly to Ansible, but the CyberArk Conjur secrets integration and the two custom token-fetching resources require careful re-implementation. A **critical security issue** exists in `recipes/security.rb`, where an OAuth `client_secret` is hardcoded in plain text.

**Estimated migration timeline: 2–3 weeks** for a single engineer, including testing.

---

## Module Migration Plan

This repository contains one Chef cookbook that needs individual recipe-level migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **nginx-multisite**:
  - Description: Nginx multi-site web server cookbook that installs and configures Nginx with three SSL-enabled internal virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`), deploys per-site static `index.html` content, generates self-signed TLS certificates via OpenSSL (passphrase retrieved from CyberArk Conjur), applies a hardened `nginx.conf` and a security-focused `conf.d/security.conf` (rate limiting, buffer overflow mitigations, TLS 1.2/1.3 enforcement), and hardens the OS with fail2ban, UFW firewall rules, sysctl kernel parameters, and SSH hardening (`PermitRootLogin no`, `PasswordAuthentication no`).
  - Path: `.` (repository root — the cookbook is the repository)
  - Technology: Chef (cookbook format, `chef_version >= 16.0`)
  - Key Features:
    - Four sequenced recipes: `security` → `nginx` → `ssl` → `sites`
    - Three custom resources: `ada_ada` (in-place line replacement in config files), `fetch_token` (OAuth2 client-credentials token fetch), `fetch_and_parse_token` (HTTP GET + regex token extraction)
    - CyberArk Conjur integration via `conjur_variable()` helper to retrieve the SSL key passphrase at converge time
    - Five ERB templates: `nginx.conf.erb`, `security.conf.erb`, `site.conf.erb`, `fail2ban.jail.local.erb`, `sysctl-security.conf.erb`
    - Supports Ubuntu ≥ 18.04 and CentOS ≥ 7.0

---

### Infrastructure Files

- `metadata.rb`: Cookbook identity, version (`1.0.0`), supported OS matrix (Ubuntu ≥ 18.04, CentOS ≥ 7.0), and single external dependency on `cyberark-conjur ~> 3.0`. Maps to `galaxy.yml` / `requirements.yml` in Ansible.
- `attributes/default.rb`: Defines the three virtual-host site map, SSL certificate/key paths, CyberArk Conjur connection parameters (appliance URL, account, variable path), and security feature flags (fail2ban, UFW, SSH hardening). Maps to Ansible `defaults/main.yml` and `vars/main.yml`.
- `recipes/default.rb`: Orchestration entry point — calls the four sub-recipes in order. Maps to an Ansible role `tasks/main.yml` with `import_tasks` or `include_role` directives.
- `recipes/security.rb`: OS hardening — installs fail2ban and UFW, configures firewall rules, applies sysctl kernel hardening, and enforces SSH settings via the `ada_ada` custom resource. **Contains a hardcoded `client_secret`** (see Security Considerations). Maps to Ansible tasks using `ansible.builtin.package`, `ansible.builtin.ufw`, `ansible.posix.sysctl`, and `ansible.builtin.lineinfile`.
- `recipes/nginx.rb`: Installs Nginx, deploys `nginx.conf` and `security.conf`, manages the `nginx` service, creates document-root directories, and copies static `index.html` files per site. Maps to Ansible tasks using `ansible.builtin.package`, `ansible.builtin.template`, `ansible.builtin.file`, `ansible.builtin.copy`, and `ansible.builtin.service`.
- `recipes/ssl.rb`: Installs `openssl` and `ca-certificates`, creates the `ssl-cert` group, ensures certificate/key directories exist, and generates a self-signed certificate per SSL-enabled site using an `openssl req` shell command with a Conjur-sourced passphrase. Maps to Ansible tasks using `community.crypto.openssl_privatekey`, `community.crypto.x509_certificate`, and `ansible.builtin.group`.
- `recipes/sites.rb`: Renders per-site Nginx `sites-available` configs from `site.conf.erb`, creates `sites-enabled` symlinks, and removes the default site. Maps to Ansible tasks using `ansible.builtin.template` and `ansible.builtin.file`.
- `resources/ada_ada.rb`: Custom resource that performs regex-based in-place line replacement (or append) in arbitrary config files, with optional timestamped backup. Replaces directly with `ansible.builtin.lineinfile` (which natively supports `regexp`, `line`, and `backup`).
- `resources/fetch_token.rb`: Custom resource that POSTs `client_id`/`client_secret` to an OAuth2 token endpoint and stores the `access_token` in `node.run_state`. Must be re-implemented as an Ansible `uri` task storing the result in a registered variable.
- `resources/fetch_and_parse_token.rb`: Custom resource that GETs a token URL and extracts a value matching the regex pattern `pattern1:(.+)`. Must be re-implemented as an Ansible `uri` + `set_fact` task with a regex filter. **The extraction pattern (`pattern1:(.+)`) appears to be a placeholder and must be clarified before migration.**
- `templates/default/nginx.conf.erb`: Main Nginx configuration (worker processes, events, HTTP block, gzip, logging, include paths). Converts directly to a Jinja2 template (`nginx.conf.j2`).
- `templates/default/security.conf.erb`: Nginx security hardening snippet (rate-limit zones, buffer limits, timeout tuning, global TLS settings). Converts directly to a Jinja2 template (`security.conf.j2`).
- `templates/default/site.conf.erb`: Per-vhost Nginx server block with HTTP→HTTPS redirect, TLS 1.2/1.3, HSTS, and security headers (X-Frame-Options, CSP, etc.). Converts directly to a Jinja2 template (`site.conf.j2`).
- `templates/default/fail2ban.jail.local.erb`: fail2ban jail configuration covering `sshd`, `nginx-http-auth`, `nginx-limit-req`, and `nginx-botsearch` jails. Converts directly to a Jinja2 template (`jail.local.j2`).
- `templates/default/sysctl-security.conf.erb`: Kernel hardening parameters (IP spoofing protection, ICMP redirect suppression, SYN-flood protection, IPv6 disable). Converts directly to a Jinja2 template (`sysctl-security.conf.j2`) or uses `ansible.posix.sysctl` tasks directly.
- `files/default/ci/index.html`, `files/default/status/index.html`, `files/default/test/index.html`: Static site content for the three virtual hosts. Migrate to `files/` directory in the Ansible role and deploy with `ansible.builtin.copy`.

---

### Target Details

- **Operating System**: Ubuntu ≥ 18.04 (primary, given `www-data` user, `ufw`, `/var/log/auth.log`, and `apt`-style package names) and CentOS ≥ 7.0 (secondary, declared in `metadata.rb`). The `www-data` owner and UFW usage strongly suggest Ubuntu/Debian as the primary runtime target. Default to **Ubuntu 22.04 LTS** for the Ansible role unless otherwise specified.
- **Virtual Machine Technology**: Not specified. No cloud-init, VM tools packages, or hypervisor-specific configurations are present.
- **Cloud Platform**: Not specified. CyberArk Conjur is used as an external secrets manager but is not cloud-provider-specific.

---

## Migration Approach

### Key Dependencies to Address

- **cyberark-conjur (~> 3.0)**: The cookbook depends on the `cyberark-conjur` Chef supermarket cookbook, which provides the `conjur_variable()` helper used in `recipes/ssl.rb` to retrieve the SSL key passphrase at converge time. Replace with the **CyberArk Conjur Ansible collection** (`cyberark.conjur`) — specifically the `cyberark.conjur.conjur_variable` lookup plugin — to fetch secrets into Ansible variables at play time. Alternatively, use HashiCorp Vault or Ansible Vault if Conjur is being decommissioned.
- **fetch_token custom resource (OAuth2 client-credentials flow)**: No direct Ansible module equivalent. Replace with `ansible.builtin.uri` (POST with JSON body) and `ansible.builtin.set_fact` to store the `access_token` in a play variable. The `client_secret` must be sourced from a secrets manager (see Security Considerations).
- **fetch_and_parse_token custom resource**: Replace with `ansible.builtin.uri` (GET) and `ansible.builtin.set_fact` using the `regex_search` Jinja2 filter. The extraction regex (`pattern1:(.+)`) must be confirmed with the owning team before migration.
- **ada_ada custom resource (line-in-file editor)**: Replace directly with `ansible.builtin.lineinfile`, which provides equivalent `regexp`/`line`/`backup` functionality natively.
- **openssl CLI for self-signed cert generation**: Replace with `community.crypto.openssl_privatekey` and `community.crypto.x509_certificate` (from the `community.crypto` Ansible collection) for idempotent, Ansible-native certificate management. The `ansible-collections` requirement `community.crypto >= 2.0` should be added to `requirements.yml`.

---

### Security Considerations

- **Hardcoded OAuth2 `client_secret` in `recipes/security.rb`**: The `fetch_token` resource is called with `client_secret: 'sup3rs3cr3t'` in plain text. This is a **critical credential exposure**. Before migration, this secret must be rotated, removed from version control history (git-filter-branch / BFG), and re-sourced from CyberArk Conjur, Ansible Vault, or another secrets manager. In Ansible, pass it as an encrypted variable via `ansible-vault encrypt_string` or a Conjur/Vault lookup.
- **CyberArk Conjur SSL passphrase**: The SSL key passphrase is correctly retrieved from Conjur at runtime (`production/nginx/ssl_passphrase`) rather than hardcoded. In Ansible, replicate this pattern using the `cyberark.conjur.conjur_variable` lookup or an equivalent secrets-manager lookup. Ensure the passphrase is never written to Ansible logs (`no_log: true` on tasks that consume it).
- **Self-signed TLS certificates**: All three virtual hosts use self-signed certificates generated at converge time. The passphrase is passed directly to the `openssl req` command via `-passout pass:<value>`, which can expose it in process listings. In Ansible, use `community.crypto` modules which handle key material in memory and avoid shell exposure. Evaluate whether self-signed certificates are appropriate for the target environment or whether a CA-signed / Let's Encrypt workflow should be adopted.
- **SSH hardening (`PermitRootLogin no`, `PasswordAuthentication no`)**: Managed via the `ada_ada` resource modifying `/etc/ssh/sshd_config`. In Ansible, use `ansible.builtin.lineinfile` with `validate` and ensure the SSH service restart is handled safely to avoid locking out the automation user.
- **UFW firewall rules**: Managed via raw `execute` blocks running `ufw` CLI commands. In Ansible, use `community.general.ufw` for idempotent, declarative firewall management.
- **fail2ban jails**: Configured via template. Migrate the template to Jinja2 and manage with `ansible.builtin.template` + `ansible.builtin.service`. No credential exposure in this template.
- **Nginx security headers and TLS configuration**: HSTS, CSP, X-Frame-Options, and TLS 1.2/1.3-only enforcement are defined in `site.conf.erb` and `security.conf.erb`. These translate directly to Jinja2 templates with no secrets involved.
- **Sysctl kernel hardening**: Applied via a config file drop and `sysctl -p`. In Ansible, use `ansible.posix.sysctl` for each parameter to ensure idempotency, or retain the template approach with `ansible.builtin.template` + `ansible.builtin.command`.

---

### Technical Challenges

- **CyberArk Conjur integration at converge time**: The `conjur_variable()` helper is called mid-recipe during the Chef converge phase, making the SSL passphrase available as a Ruby variable. In Ansible, secrets lookups happen at play-variable resolution time (before tasks run), which is a different execution model. Ensure the Conjur lookup plugin is configured and authenticated (Conjur host identity / API key) before the play executes. This may require pre-tasks or a dedicated secrets-retrieval play.
- **Hardcoded `client_secret` remediation**: Beyond the Ansible migration itself, the secret must be purged from git history. This is a prerequisite blocker — the migration should not proceed until the credential is rotated and the history is cleaned.
- **`fetch_and_parse_token` placeholder regex**: The extraction pattern `pattern1:(.+)` is almost certainly a placeholder. The actual token format and endpoint behavior are unknown from the source alone. This resource's purpose and target endpoint must be clarified with the owning team; the migration of this resource is **blocked** until that information is available.
- **Dual OS support (Ubuntu + CentOS)**: The cookbook declares support for both Ubuntu ≥ 18.04 and CentOS ≥ 7.0, but the implementation uses Ubuntu-specific conventions (`www-data` user, `ufw`, `/var/log/auth.log`, `apt` package names). The Ansible role will need `when: ansible_os_family == "Debian"` / `"RedHat"` conditionals, different package names (`httpd` vs `nginx` group ownership, `firewalld` vs `ufw`), and separate service names if CentOS support is to be retained.
- **`ada_ada` backup files**: The custom resource writes timestamped `.backup.<epoch>` files alongside modified config files. `ansible.builtin.lineinfile` uses a different backup naming convention. If backup files are relied upon operationally, the backup strategy should be explicitly defined in the Ansible role.
- **Idempotency of `openssl req` shell command**: The Chef recipe guards certificate generation with `not_if { ::File.exist?(cert_file) && ::File.exist?(key_file) }`. The equivalent Ansible `community.crypto` modules are natively idempotent and should be preferred over a raw `command` module with `creates:` guard.
- **Node run_state for token passing**: Both token resources store results in `node.run_state`, which is Chef's in-memory converge-time state bag. In Ansible, use `register` + `set_fact` to pass values between tasks. Ensure `no_log: true` is set on any task that registers a secret value.

---

### Migration Order

1. **Security hardening tasks** (`recipes/security.rb` → Ansible tasks): Lowest risk for the Nginx service itself; establishes the hardened OS baseline. Implement `ansible.builtin.lineinfile` (replacing `ada_ada`), `community.general.ufw`, `ansible.posix.sysctl`, and `ansible.builtin.template` for fail2ban. **Prerequisite: rotate and remove the hardcoded `client_secret` before committing any Ansible code.**
2. **Nginx installation and base configuration** (`recipes/nginx.rb` → Ansible tasks): Straightforward package + template + service pattern. Migrate `nginx.conf.erb` and `security.conf.erb` to Jinja2. Deploy static site files with `ansible.builtin.copy`.
3. **SSL certificate management** (`recipes/ssl.rb` → Ansible tasks): Implement CyberArk Conjur lookup for the passphrase, then use `community.crypto` modules for certificate generation. Validate `no_log: true` on all tasks handling the passphrase.
4. **Virtual-host site deployment** (`recipes/sites.rb` → Ansible tasks): Migrate `site.conf.erb` to Jinja2, loop over the sites dictionary, manage `sites-available`/`sites-enabled` symlinks, and remove the default site.
5. **Token-fetching logic** (`resources/fetch_token.rb`, `resources/fetch_and_parse_token.rb` → Ansible tasks): Implement last, after the `fetch_and_parse_token` regex pattern is clarified. Use `ansible.builtin.uri` + `ansible.builtin.set_fact` with `no_log: true`.

---

### Assumptions

1. **Primary target OS is Ubuntu** (22.04 LTS assumed) based on `www-data`, `ufw`, and `/var/log/auth.log` usage, despite CentOS also being declared in `metadata.rb`. CentOS support will require additional conditional task branches.
2. **CyberArk Conjur remains the secrets backend** post-migration. If Conjur is being replaced, the secrets strategy must be decided before the SSL and token tasks are migrated.
3. **The `fetch_token` and `fetch_and_parse_token` resources are actively used** in the security recipe. Their endpoints (`https://auth.example.com/oauth/token`, `https://api.example.com/token_endpoint`) appear to be placeholders; actual production URLs and the real token-parsing regex must be confirmed.
4. **Self-signed certificates are intentional** for the target environment (described as "development" in the recipe comment). If this cookbook is also used in production, a proper PKI or ACME/Let's Encrypt workflow should be evaluated during migration.
5. **No Berksfile or Policyfile is present** in the repository tree. It is assumed the cookbook is consumed directly (e.g., via a wrapper cookbook or `chef-client --runlist`) rather than through Berkshelf or Chef Policyfiles. The Ansible equivalent will be a standalone role.
6. **The `cyberark-conjur` Chef cookbook version `~> 3.0`** provides the `conjur_variable()` helper. The equivalent `cyberark.conjur` Ansible collection must be installed and the Conjur host identity configured on target nodes before the role runs.
7. **No existing Ansible inventory or control node** is assumed. The migration plan assumes a greenfield Ansible setup; if an existing Ansible environment is present, role naming and variable namespacing should be aligned with existing conventions.
8. **The three virtual-host domains** (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) are internal DNS names. DNS resolution for these names on target hosts is assumed to be handled outside this cookbook/role.
9. **IPv6 is intentionally disabled** via sysctl (`net.ipv6.conf.all.disable_ipv6 = 1`). This assumption should be validated against the target network environment before applying the hardening role.
10. **The `client_secret` value `sup3rs3cr3t`** in `recipes/security.rb` is a development placeholder, not a production credential. Regardless, it must be treated as compromised and rotated before migration begins.

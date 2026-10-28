# MIGRATION FROM CHEF TO ANSIBLE

## Executive Summary

This repository contains a single Chef cookbook (`nginx-multisite`, v1.0.0) that provisions a hardened Nginx web server hosting three SSL-enabled internal subdomains (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`). The cookbook integrates with CyberArk Conjur for secrets retrieval, applies OS-level security hardening (UFW firewall, fail2ban, sysctl tuning, SSH lockdown), and includes a custom Chef resource (`ada_ada`) for in-place file-line editing.

The migration scope is **one cookbook with four recipes, one custom resource, five templates, three static files, and one external dependency (CyberArk Conjur)**. This is a **low-to-moderate complexity** migration. The primary challenges are replacing the CyberArk Conjur integration with an Ansible-native secrets backend and replicating the custom `ada_ada` line-editing resource using Ansible's `lineinfile` module.

**Estimated timeline**: 1–2 sprints (2–4 weeks) for a single engineer, including testing.

---

## Module Migration Plan

This repository contains one Chef cookbook that needs to be migrated to an Ansible role (or a small set of roles).

---

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **nginx-multisite**:
  - **Description**: Nginx web server cookbook that installs and configures Nginx to serve three SSL-enabled internal subdomains (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`). Manages the full lifecycle: package installation, global `nginx.conf` and security hardening config (`security.conf`), per-site virtual host configs with HTTP→HTTPS redirect, self-signed TLS certificate generation via OpenSSL (passphrase fetched from CyberArk Conjur), static site content deployment, OS firewall (UFW), intrusion prevention (fail2ban with SSH and Nginx jails), kernel-level network hardening (sysctl), and SSH daemon hardening (root login disabled, password auth disabled).
  - **Path**: `.` (repository root — the cookbook is the repository)
  - **Technology**: Chef (chef_version `>= 16.0`)
  - **Key Features**:
    - Four recipes orchestrated by `default.rb`: `security` → `nginx` → `ssl` → `sites`
    - CyberArk Conjur integration (`cyberark-conjur ~> 3.0`) for SSL passphrase retrieval via `conjur_variable()` helper
    - Self-signed RSA-2048 certificate generation per vhost (idempotent, skipped if cert+key already exist)
    - Custom `ada_ada` resource for regex-based in-place line replacement in config files (used for `sshd_config` hardening)
    - ERB templates for `nginx.conf`, per-site `site.conf` (TLSv1.2/1.3, HSTS, CSP, X-Frame-Options, X-Content-Type-Options), `security.conf` (rate limiting zones, buffer overflow mitigations), `fail2ban.jail.local` (SSH + four Nginx jails), and `sysctl-security.conf` (IP spoofing, ICMP, SYN-flood, IPv6 disable)
    - Static `index.html` files deployed to each vhost document root under `/opt/server/{test,ci,status}`
    - UFW rules: default deny, allow SSH/HTTP/HTTPS
    - Attribute-driven site map (site name → document root + ssl_enabled flag)

---

### Infrastructure Files

- `metadata.rb`: Cookbook metadata — name, version, Chef version constraint (`>= 16.0`), supported OS (`ubuntu >= 18.04`, `centos >= 7.0`), and the single external dependency `cyberark-conjur ~> 3.0`. Must be translated into Ansible `meta/main.yml` and `requirements.yml`.
- `attributes/default.rb`: Defines the site map (three vhosts), SSL certificate/key paths, CyberArk Conjur connection parameters (`appliance_url`, `account`, `variable` path), and security feature flags (fail2ban, UFW, SSH hardening). These become Ansible role `defaults/main.yml` variables.
- `resources/ada_ada.rb`: Custom Chef resource that performs regex-based line replacement (or append) in arbitrary files, with optional timestamped backup. Directly replaced by Ansible's built-in `lineinfile` module — no custom code needed in Ansible.
- `files/default/ci/index.html`, `files/default/status/index.html`, `files/default/test/index.html`: Static HTML content deployed to each vhost document root. Migrate as-is to `files/` within the Ansible role.
- `templates/default/nginx.conf.erb`: Global Nginx configuration (worker processes, events, HTTP block, logging, gzip, vhost includes). Migrate to a Jinja2 template (`nginx.conf.j2`).
- `templates/default/site.conf.erb`: Per-vhost server block with HTTP→HTTPS redirect, TLS settings, HSTS, security headers, gzip, and location rules. Migrate to `site.conf.j2`; ERB `<%= @var %>` → Jinja2 `{{ var }}`, ERB `<% if %>` → `{% if %}`.
- `templates/default/security.conf.erb`: Nginx `conf.d` snippet for rate limiting, buffer size limits, timeout hardening, and global SSL settings. Migrate to `security.conf.j2`.
- `templates/default/fail2ban.jail.local.erb`: fail2ban `jail.local` with DEFAULT block and five jails (sshd, nginx-http-auth, nginx-limit-req, nginx-botsearch). Migrate to `fail2ban.jail.local.j2`.
- `templates/default/sysctl-security.conf.erb`: Kernel parameter hardening file for `/etc/sysctl.d/99-security.conf`. Migrate to `sysctl-security.conf.j2` or use Ansible's `ansible.posix.sysctl` module directly.

---

### Target Details

- **Operating System**: Ubuntu 18.04+ (primary) and CentOS 7+ (secondary), as declared in `metadata.rb`. Package names (`nginx`, `fail2ban`, `ufw`), paths (`/etc/nginx/sites-available`, `/var/log/auth.log`, `www-data` user/group), and UFW usage all point to **Ubuntu/Debian** as the primary target. CentOS support will require conditional tasks (different package manager, `firewalld` instead of UFW, `nginx` site config path differences, `sshd` vs `ssh` service name).
- **Virtual Machine Technology**: Not specified. No cloud-init, VM tools, or hypervisor-specific packages are referenced.
- **Cloud Platform**: Not specified. The Conjur appliance URL (`conjur.example.com`) and internal `.cluster.local` domain names suggest an on-premises or private-cloud deployment.

---

## Migration Approach

### Key Dependencies to Address

- **cyberark-conjur (~> 3.0)**: The cookbook uses the `conjur_variable()` helper (a custom Chef function provided by this community cookbook) to fetch the SSL key passphrase at converge time from CyberArk Conjur (`production/nginx/ssl_passphrase`). In Ansible, replace with one of:
  - **`cyberark.conjur` Ansible collection** (`cyberark.conjur.conjur_variable` lookup plugin) — closest functional equivalent, maintains the same secrets backend.
  - **HashiCorp Vault** (`community.hashi_vault.hashi_vault` lookup) — if the organisation is standardising on Vault.
  - **Ansible Vault** (`ansible-vault`) — for simpler environments where a static encrypted variable file is acceptable.
  The chosen approach must be decided before migration begins, as it affects every task that consumes the passphrase.

- **UFW (Uncomplicated Firewall)**: Used via raw `execute` resources in Chef. Replace with the `community.general.ufw` Ansible module for idempotent, declarative firewall management. On CentOS targets, substitute `ansible.posix.firewalld`.

- **Custom `ada_ada` resource**: A bespoke line-editing resource. Directly and fully replaced by Ansible's built-in `ansible.builtin.lineinfile` module — no third-party dependency required.

- **OpenSSL self-signed certificate generation**: Currently done via a shell `execute` block calling `openssl req`. Replace with the `community.crypto.openssl_privatekey`, `community.crypto.openssl_csr`, and `community.crypto.x509_certificate` modules from the `community.crypto` collection for fully idempotent, declarative certificate management.

---

### Security Considerations

- **CyberArk Conjur secrets integration**: The SSL key passphrase is fetched at runtime from Conjur (`production/nginx/ssl_passphrase`). This is the most sensitive migration point. The Ansible equivalent must ensure the secret is never written to disk, never logged (use `no_log: true` on tasks consuming it), and is injected only into the `openssl` command at execution time. The `sensitive true` flag on the Chef `execute` resource must be mirrored with `no_log: true` in Ansible.
- **SSL/TLS certificate private keys**: Keys are written to `/etc/ssl/private/` with `0640` permissions, owned `root:ssl-cert`. The Ansible role must replicate these exact permissions. The passphrase used during key generation must be sourced from the secrets backend — never hardcoded in variables or inventory.
- **SSH hardening via `sshd_config`**: Two directives are enforced — `PermitRootLogin no` and `PasswordAuthentication no`. These are applied using the custom `ada_ada` resource. In Ansible, use `ansible.builtin.lineinfile` with `regexp` and `line` parameters, followed by a handler to restart `sshd`. Misconfiguration here can lock administrators out of hosts — test in a staging environment first and ensure out-of-band console access is available.
- **sysctl hardening**: IPv6 is fully disabled (`net.ipv6.conf.all.disable_ipv6 = 1`). Verify this is intentional for all target hosts before applying, as it may break IPv6-dependent services. Use `ansible.posix.sysctl` with `sysctl_set: true` and `reload: true` for idempotent kernel parameter management.
- **Security headers in Nginx**: The `site.conf.erb` template enforces HSTS (`max-age=31536000; includeSubDomains`), CSP, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, and `X-XSS-Protection`. These must be preserved verbatim in the Jinja2 template — any accidental omission would reduce the security posture of the deployed sites.
- **fail2ban jails**: Five jails are configured (sshd + four Nginx jails). The `nginx-botsearch` jail has `maxretry = 2`, making it aggressive. Ensure the Ansible-deployed `jail.local` template is validated before production rollout to avoid legitimate traffic being banned.
- **Nginx version hiding**: `server_tokens off` is set in `security.conf.erb`. Must be preserved in the migrated template.

---

### Technical Challenges

- **CyberArk Conjur runtime secret injection**: The Chef `conjur_variable()` call happens during the Chef converge phase and injects the passphrase directly into the `openssl` command. Replicating this in Ansible requires the `cyberark.conjur` collection (or equivalent lookup plugin) and careful task design to avoid the secret appearing in Ansible logs or the process list. This is the highest-risk item in the migration.

- **Dual OS support (Ubuntu vs. CentOS)**: The cookbook declares support for both Ubuntu ≥ 18.04 and CentOS ≥ 7, but the implementation is Ubuntu-centric (UFW, `www-data` user, `apt`-style package names, `/etc/nginx/sites-available` layout, `ssh` service name). The Ansible role will need `when: ansible_os_family == "Debian"` / `"RedHat"` conditionals for: firewall management (UFW vs. firewalld), Nginx config layout (`sites-available/sites-enabled` vs. `conf.d`), service names (`ssh` vs. `sshd`), and the `www-data` vs. `nginx` user. If CentOS support is not actually required, scope it out early to reduce complexity.

- **Custom `ada_ada` resource replacement**: The resource performs a regex match-and-replace with an optional timestamped backup. `ansible.builtin.lineinfile` covers the core functionality, but the backup behaviour differs (Ansible creates a single `.bak` file, not timestamped copies). If backup fidelity is required, a custom Ansible module or a `copy` + `lineinfile` pattern will be needed.

- **Idempotent certificate generation**: The Chef `execute` block is guarded by `not_if { ::File.exist?(cert_file) && ::File.exist?(key_file) }`. The `community.crypto` Ansible modules provide native idempotency for key and certificate generation, but the passphrase handling must be carefully mapped — the `openssl_privatekey` module accepts a `passphrase` parameter that must be sourced from the secrets lookup.

- **ERB → Jinja2 template conversion**: Five ERB templates need conversion. The syntax differences are minor (`<%= %>` → `{{ }}`, `<% if %>` → `{% if %}`), but the multi-site loop in `site.conf.erb` and the conditional SSL block must be carefully validated. The `site.conf.erb` template has a structural quirk: the HTTP server block's closing `}` is inside the `<% if @ssl_enabled %>` branch, which must be handled correctly in Jinja2 to avoid malformed Nginx configs.

- **Nginx service name for notify/handler**: Chef uses `service[nginx]` with `:reload` notifications. In Ansible, handlers must be defined for both `reload nginx` and `restart nginx` (and `restart sshd`/`restart fail2ban`). Ensure handler names are consistent across all tasks.

- **Static file deployment path derivation**: The Chef `nginx.rb` recipe derives the subfolder name from the site hostname (`site_name.split('.').first`), mapping `test.cluster.local` → `files/default/test/index.html`. This logic must be replicated in the Ansible role, either by encoding the mapping explicitly in variables or by using a Jinja2 expression in the `copy` task's `src` parameter.

---

### Migration Order

1. **Variables and defaults** — Translate `attributes/default.rb` to `defaults/main.yml`. Define the site map, SSL paths, Conjur connection parameters, and security flags as Ansible variables. This is zero-risk and unblocks all subsequent work.

2. **Secrets backend integration** — Establish the Ansible-to-Conjur (or chosen alternative) lookup before writing any tasks that consume secrets. Validate that `no_log: true` suppresses the passphrase in all output. This is the highest-risk dependency and must be resolved early.

3. **Security hardening role** (`recipes/security.rb` equivalent) — Migrate UFW firewall rules, fail2ban installation and jail configuration, sysctl kernel hardening, and SSH `sshd_config` hardening. These are self-contained and do not depend on Nginx. Use `ansible.posix.sysctl`, `community.general.ufw`, and `ansible.builtin.lineinfile`. Test SSH hardening last, with console access available.

4. **Nginx base role** (`recipes/nginx.rb` equivalent) — Install Nginx, deploy `nginx.conf` and `security.conf` from Jinja2 templates, create document root directories, deploy static `index.html` files, and manage the Nginx service with handlers.

5. **SSL certificate provisioning** (`recipes/ssl.rb` equivalent) — Create the `ssl-cert` group, manage certificate/key directories with correct permissions, and generate per-site self-signed certificates using `community.crypto` modules with the passphrase sourced from the secrets lookup.

6. **Virtual host configuration** (`recipes/sites.rb` equivalent) — Deploy per-site `site.conf` from the Jinja2 template into `sites-available/`, create `sites-enabled/` symlinks, and remove the default site. Trigger Nginx reload via handler.

7. **Integration testing** — Validate all three vhosts respond correctly over HTTPS, security headers are present, fail2ban jails are active, UFW rules are in place, and SSH hardening is applied. Run on Ubuntu first, then CentOS if in scope.

---

### Assumptions

1. **CyberArk Conjur is reachable from Ansible control node or target hosts**: The migration plan assumes the Conjur appliance at `conjur.example.com` remains the secrets backend. If the organisation is migrating away from Conjur, the secrets strategy must be decided before migration begins.

2. **Self-signed certificates are intentional for all environments**: The `ssl.rb` recipe generates self-signed certificates with a comment "for development." It is unclear whether production environments use the same self-signed certs or whether a CA-signed certificate deployment path exists elsewhere. If production requires CA-signed certs, the SSL tasks will need a separate code path.

3. **CentOS support may be vestigial**: The cookbook declares CentOS ≥ 7 support in `metadata.rb`, but the implementation uses Ubuntu-specific tooling throughout. It is assumed CentOS support is aspirational or legacy and may be descoped from the Ansible migration unless explicitly confirmed as a requirement.

4. **The `ada_ada` custom resource is used only for `sshd_config`**: Based on the reviewed recipes, `ada_ada` is only invoked in `security.rb` for two `sshd_config` directives. If it is used elsewhere (e.g., in wrapper cookbooks not present in this repository), those usages must also be mapped to `lineinfile`.

5. **No Berksfile or Policyfile is present**: The repository contains no `Berksfile`, `Policyfile.rb`, or `Berksfile.lock`. It is assumed the cookbook is consumed directly (e.g., via a wrapper cookbook or Chef environment) and that `cyberark-conjur ~> 3.0` is the only external cookbook dependency.

6. **The three vhosts are the complete set**: The site map in `attributes/default.rb` defines exactly three sites (`test`, `ci`, `status`). It is assumed no additional sites are defined in environment-level attributes or wrapper cookbooks outside this repository.

7. **IPv6 disablement is intentional**: The sysctl template disables IPv6 globally. This is assumed to be a deliberate policy decision for the target environment, not an oversight.

8. **The `ssl_passphrase` is used only as the OpenSSL key encryption passphrase**: The Conjur variable `production/nginx/ssl_passphrase` is passed as `-passout` to `openssl req`. It is assumed the same passphrase is not reused for other purposes (e.g., PKCS#12 bundles, application keystores).

9. **Ansible control node has network access to target hosts over SSH**: Standard Ansible connectivity assumption. The SSH hardening applied by this cookbook (password auth disabled) means key-based SSH authentication must be pre-configured on all target hosts before the Ansible role is run for the first time.

10. **The `files/default/` static HTML files are the complete site content**: The three `index.html` files are assumed to be the entirety of the static content for each vhost. If the sites serve dynamic content or additional assets, those are out of scope for this cookbook migration.

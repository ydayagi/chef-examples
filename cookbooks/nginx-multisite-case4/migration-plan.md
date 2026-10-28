# MIGRATION FROM CHEF TO ANSIBLE

## Executive Summary

This repository contains a single Chef cookbook (`nginx-multisite`, v1.0.0) that provisions a hardened Nginx web server hosting multiple SSL-enabled subdomains. The cookbook orchestrates four tightly coupled concerns: OS-level security hardening, Nginx installation and configuration, SSL certificate generation, and per-site virtual-host deployment. It carries one external cookbook dependency (`cyberark-conjur ~> 3.0`) for secrets retrieval and three custom Chef resources that implement in-house utilities (file-line editing, HTTP value fetching, and HTTP value fetch-and-parse).

The migration scope is a single cookbook with moderate complexity. The primary challenges are replacing the CyberArk Conjur integration with an Ansible-native secrets backend, re-implementing the three custom Chef resources as Ansible tasks or modules, and preserving the idempotency guarantees that the custom `ada_ada` resource currently provides for `sshd_config` edits.

**Estimated migration effort:** 2–3 weeks for a single engineer, including testing.

---

## Module Migration Plan

This repository contains one Chef cookbook that is internally decomposed into four recipes, three custom resources, a set of ERB templates, static site files, and a node-attribute defaults file. Each recipe maps to a logical Ansible role or set of tasks.

---

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
All paths below were confirmed from the repository tree and file reads performed during analysis.

- **nginx-multisite** *(cookbook root)*:
  - **Description:** Nginx multi-site web server cookbook that installs and configures Nginx to serve three SSL-enabled internal subdomains (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`), each with its own virtual-host config, self-signed TLS certificate, and static `index.html` content. The cookbook is the single deployable unit; its four recipes are called in sequence by `recipes/default.rb`.
  - **Path:** `.` (repository root)
  - **Technology:** Chef (cookbook, `chef_version >= 16.0`)
  - **Supported OS:** Ubuntu ≥ 18.04, CentOS ≥ 7.0
  - **Key Features:**
    - **`recipes/security.rb`** — Installs `fail2ban` and `ufw`; configures UFW default-deny with SSH/HTTP/HTTPS allow rules; writes `/etc/sysctl.d/99-security.conf` with kernel-level network hardening (IP spoofing protection, ICMP redirect suppression, SYN-cookie flood protection, IPv6 disable); hardens `sshd_config` to disable root login and password authentication via the custom `ada_ada` resource; invokes the `fetch_value` and `fetch_and_parse_value` custom resources against `api.example.com` endpoints.
    - **`recipes/nginx.rb`** — Installs the `nginx` package; deploys `/etc/nginx/nginx.conf` from `nginx.conf.erb` (worker processes, gzip, logging, virtual-host includes); deploys `/etc/nginx/conf.d/security.conf` from `security.conf.erb` (rate-limiting zones, buffer-overflow mitigations, TLS 1.2/1.3 cipher suite); creates per-site document-root directories owned by `www-data`; copies static `index.html` files from `files/default/{ci,status,test}/`.
    - **`recipes/ssl.rb`** — Installs `openssl` and `ca-certificates`; retrieves the SSL key passphrase from CyberArk Conjur (`production/nginx/ssl_passphrase`); creates the `ssl-cert` group; ensures `/etc/ssl/certs` and `/etc/ssl/private` directories exist with correct ownership/permissions; generates a self-signed RSA-2048 certificate per site via `openssl req -x509` (365-day validity, `sensitive true`).
    - **`recipes/sites.rb`** — Renders per-site Nginx virtual-host configs from `site.conf.erb` into `/etc/nginx/sites-available/`; creates symlinks in `/etc/nginx/sites-enabled/`; removes the default Nginx site.
    - **Custom resource `ada_ada`** — In-house file-line editor: matches a regex pattern in a target file and replaces the matched line, or appends the line if no match is found; creates a timestamped `.backup` file before modifying.
    - **Custom resource `fetch_value`** — Issues an HTTP GET to a configurable URL and stores the raw response body in `node.run_state`.
    - **Custom resource `fetch_and_parse_value`** — Issues an HTTP GET, extracts a value matching the pattern `pattern1:<value>` from the response body, and stores it in `node.run_state`.

---

### Infrastructure Files

- `metadata.rb`: Cookbook name, version (`1.0.0`), Chef version constraint (`>= 16.0`), supported OS declarations, and the single external dependency (`cyberark-conjur ~> 3.0`). Maps directly to Ansible `galaxy.yml` / `requirements.yml` during migration.
- `attributes/default.rb`: Node attribute defaults — site definitions (name → document root + SSL flag), SSL certificate/key paths, CyberArk Conjur connection parameters (appliance URL, account, variable path), and security feature toggles (fail2ban, UFW, SSH hardening). These become Ansible role `defaults/main.yml` variables.
- `templates/default/nginx.conf.erb`: Main Nginx configuration; no Chef-specific variables — converts directly to a static Ansible template (`nginx.conf.j2`).
- `templates/default/security.conf.erb`: Nginx security sub-configuration (rate limiting, buffer limits, TLS settings); no Chef variables — converts directly to a static Ansible template.
- `templates/default/site.conf.erb`: Per-vhost Nginx server block with conditional SSL, HTTP→HTTPS redirect, HSTS, security headers, and gzip. Uses ERB variables (`@server_name`, `@document_root`, `@ssl_enabled`, `@cert_file`, `@key_file`) that map cleanly to Jinja2.
- `templates/default/fail2ban.jail.local.erb`: Static fail2ban jail configuration (sshd, nginx-http-auth, nginx-limit-req, nginx-botsearch jails); no ERB variables — converts directly to a static Ansible template.
- `templates/default/sysctl-security.conf.erb`: Static kernel sysctl hardening parameters; no ERB variables — converts directly to a static Ansible template or can be replaced by the `ansible.posix.sysctl` module.
- `files/default/ci/index.html`: Static HTML file served by the `ci.cluster.local` vhost.
- `files/default/status/index.html`: Static HTML file served by the `status.cluster.local` vhost.
- `files/default/test/index.html`: Static HTML file served by the `test.cluster.local` vhost.

---

### Target Details

- **Operating System:** Ubuntu ≥ 18.04 (primary, given `www-data` user, `ufw`, `/var/log/auth.log`, and `apt`-style package names) and CentOS ≥ 7.0 (secondary, declared in `metadata.rb`). Migration should target **Ubuntu 22.04 LTS** as the primary platform; CentOS support should be re-evaluated given CentOS 7 EOL (June 2024) — consider Rocky Linux 9 or RHEL 9 as the Red Hat family target.
- **Virtual Machine Technology:** Not specified in the repository.
- **Cloud Platform:** Not specified in the repository. The internal domain `cluster.local` suggests an on-premises or private-cloud Kubernetes/VM cluster environment.

---

## Migration Approach

### Key Dependencies to Address

- **`cyberark-conjur (~> 3.0)`** *(external Chef cookbook)*: Used in `recipes/ssl.rb` via the `conjur_variable()` helper to retrieve the SSL key passphrase (`production/nginx/ssl_passphrase`) at converge time. **Ansible replacement:** Use the [CyberArk Conjur Ansible collection](https://galaxy.ansible.com/cyberark/conjur) (`cyberark.conjur`) or the `community.hashi_vault` collection if the environment is migrating to HashiCorp Vault. The variable lookup should be implemented as an Ansible `vars_plugin` or `lookup('cyberark.conjur.conjur_variable', ...)` call within the SSL tasks.
- **Custom resource `ada_ada`** *(in-house)*: Provides regex-based line replacement in config files with automatic backup. **Ansible replacement:** The `ansible.builtin.lineinfile` module covers this functionality directly (`regexp`, `line`, `backrefs` parameters). Backup behaviour is handled by `backup: yes`.
- **Custom resource `fetch_value`** *(in-house)*: HTTP GET with raw body storage. **Ansible replacement:** `ansible.builtin.uri` module with `return_content: true`; store result in a registered variable.
- **Custom resource `fetch_and_parse_value`** *(in-house)*: HTTP GET with regex extraction. **Ansible replacement:** `ansible.builtin.uri` + `ansible.builtin.set_fact` with a Jinja2 `regex_search` filter to extract the `pattern1:<value>` pattern. The exact API endpoint (`https://api.example.com/parse_endpoint`) and the purpose of the fetched value are undocumented — this must be clarified before migration.

---

### Security Considerations

- **CyberArk Conjur secret (`production/nginx/ssl_passphrase`):** The SSL private-key passphrase is the only runtime secret. It is correctly never hardcoded — it is fetched from Conjur at converge time in `recipes/ssl.rb` and passed to `openssl` with `sensitive true`. In Ansible, this must be retrieved via a secrets lookup (Conjur or Vault) and the task must set `no_log: true` to prevent passphrase exposure in logs.
- **SSL certificate generation:** Certificates are self-signed and generated on the node using `openssl req -x509`. The passphrase is passed on the command line (`-passout pass:<value>`), which exposes it briefly in the process table. In Ansible, prefer using the `community.crypto.openssl_privatekey` and `community.crypto.x509_certificate` modules, which handle key material without shell exposure and support idempotent regeneration checks.
- **SSH hardening (`sshd_config`):** Root login and password authentication are disabled via the `ada_ada` resource. In Ansible, `ansible.builtin.lineinfile` tasks must be carefully ordered and tested — an incorrect regex could lock out all SSH access. A pre-task connectivity check and a handler-based `sshd` restart with a `validate` parameter are strongly recommended.
- **UFW firewall rules:** Applied via `execute` resources with idempotency guards (`not_if` shell checks). Ansible's `community.general.ufw` module provides declarative, idempotent firewall management and should replace all raw `execute 'ufw_*'` blocks.
- **Kernel sysctl hardening:** IPv6 is globally disabled (`net.ipv6.conf.all.disable_ipv6 = 1`). Verify this is intentional for the target environment before migrating — disabling IPv6 may conflict with cloud or container networking. Use `ansible.posix.sysctl` for idempotent kernel parameter management.
- **Nginx security headers:** `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `X-XSS-Protection`, `Referrer-Policy`, and a restrictive `Content-Security-Policy` are set in `site.conf.erb`. These must be preserved verbatim in the Jinja2 template.
- **fail2ban jails:** Four jails are configured (sshd, nginx-http-auth, nginx-limit-req, nginx-botsearch). The `backend = auto` setting in the `[DEFAULT]` section may need to be changed to `backend = systemd` on Ubuntu 22.04/RHEL 9 where `journald` is the primary log backend.

---

### Technical Challenges

- **Undocumented API endpoints (`fetch_value` / `fetch_and_parse_value`):** `recipes/security.rb` calls both custom HTTP-fetch resources against `https://api.example.com/value_endpoint` and `https://api.example.com/parse_endpoint`, but the fetched values are stored in `node.run_state` and never visibly consumed downstream in the reviewed code. The purpose of these calls is entirely undocumented. **Mitigation:** Audit the full Chef run history or consult the original cookbook author to determine whether these values are consumed by a wrapper cookbook, a report handler, or are vestigial dead code before deciding whether to port them.
- **Multi-OS support (Ubuntu vs. CentOS):** The cookbook declares support for both Ubuntu and CentOS but uses Ubuntu-specific conventions throughout (`www-data` user, `ufw`, `/var/log/auth.log`, `apt` package names). No `platform?` guards exist in the recipes. **Mitigation:** In Ansible, use `ansible_os_family` conditionals and separate variable files (`vars/Debian.yml`, `vars/RedHat.yml`) to handle package name differences (`nginx` vs `nginx`, `ufw` vs `firewalld`), service names, and log paths. Decide whether CentOS/RHEL support is actually required.
- **Self-signed certificate idempotency:** The Chef `execute` resource uses `not_if { ::File.exist?(cert_file) && ::File.exist?(key_file) }` to skip regeneration. This means a corrupted or expired certificate is never replaced. **Mitigation:** Use `community.crypto.x509_certificate` with `force: false` and add a separate task to check certificate expiry, triggering regeneration when within a configurable threshold.
- **ERB → Jinja2 template conversion:** The `site.conf.erb` template uses a conditional block (`<% if @ssl_enabled %>`) that spans two `server {}` blocks. The ERB structure is valid but slightly non-standard. **Mitigation:** Rewrite as a clean Jinja2 `{% if ssl_enabled %}` block; test rendering for both SSL-enabled and SSL-disabled site configurations.
- **Custom `ada_ada` backup files:** The resource writes timestamped backup files (e.g., `/etc/ssh/sshd_config.backup.1700000000`) on every change. These accumulate indefinitely. **Mitigation:** `ansible.builtin.lineinfile` with `backup: yes` creates a single `.bak` file per run, which is cleaner. Document this behavioural difference for operators.
- **Chef `node.run_state` pattern:** Both `fetch_value` and `fetch_and_parse_value` store results in `node.run_state`, a Chef-specific in-memory store scoped to a single converge. In Ansible, registered variables (`register:`) serve the same purpose and are scoped to the playbook run.

---

### Migration Order

The following order minimises risk by establishing the foundation (security hardening) before layering application services on top, and by tackling secrets integration early so it is available for the SSL recipe migration.

1. **Secrets integration setup** — Configure the Ansible CyberArk Conjur (or Vault) lookup plugin and validate that `production/nginx/ssl_passphrase` is retrievable. This is a prerequisite for the SSL role and should be validated in isolation before any other migration work begins.
2. **`security` recipe → `security` Ansible role** — Migrate OS hardening (sysctl, UFW, fail2ban, SSH config) first. This is self-contained, has no dependency on Nginx or SSL, and provides immediate security value. Replace `ada_ada` with `lineinfile`, `execute 'ufw_*'` with `community.general.ufw`, and the sysctl template with `ansible.posix.sysctl`. Resolve the undocumented `fetch_value`/`fetch_and_parse_value` calls before or during this step.
3. **`nginx` recipe → `nginx` Ansible role** — Install Nginx, deploy `nginx.conf` and `security.conf` templates (straightforward ERB→Jinja2 conversion), manage the service, create document roots, and copy static site files. No secrets dependency.
4. **`ssl` recipe → `ssl` Ansible role** — Depends on the secrets integration from step 1. Use `community.crypto` modules to replace the raw `openssl` shell command. Validate certificate generation idempotency and expiry-check logic.
5. **`sites` recipe → `sites` Ansible role** — Deploy per-vhost configs from the converted `site.conf.j2` template, manage `sites-available`/`sites-enabled` symlinks, and remove the default site. Depends on the Nginx role (step 3) and SSL role (step 4).
6. **Integration testing** — Run the full Ansible playbook (equivalent of `recipes/default.rb`) against a clean Ubuntu 22.04 VM and validate all three vhosts respond correctly over HTTPS with valid certificates and security headers.

---

### Assumptions

1. **Single-cookbook scope:** The repository contains only the `nginx-multisite` cookbook with no `Berksfile`, `Policyfile.rb`, or wrapper cookbooks present. It is assumed this cookbook is the complete migration target and is not consumed by a larger Chef environment that would introduce additional dependencies.
2. **CyberArk Conjur availability:** It is assumed the CyberArk Conjur instance at `https://conjur.example.com` (account `myorg`) will remain accessible from Ansible control nodes during and after migration, or that an equivalent secrets backend will be provisioned.
3. **Self-signed certificates are intentional:** The SSL recipe generates self-signed certificates with a 365-day validity. It is assumed this is intentional for the internal `cluster.local` domain and that no public CA (e.g., Let's Encrypt) is required. If a CA-signed certificate workflow is needed, the migration scope expands significantly.
4. **`api.example.com` endpoints are real and reachable:** The `fetch_value` and `fetch_and_parse_value` resources target `https://api.example.com/value_endpoint` and `https://api.example.com/parse_endpoint`. It is assumed these are placeholder URLs in the example repository and that the actual production URLs and the purpose of the fetched values must be supplied by the cookbook's original authors before migration.
5. **Ubuntu is the primary target OS:** Despite the `supports 'centos'` declaration in `metadata.rb`, all implementation details (package names, user names, firewall tool, log paths) are Ubuntu-specific. It is assumed Ubuntu 22.04 LTS is the migration target and that CentOS/RHEL support is either not required or will be scoped separately.
6. **IPv6 disable is intentional:** The sysctl template disables IPv6 globally. It is assumed this is a deliberate network policy decision and not an oversight, as it can break cloud-provider metadata services and container networking on some platforms.
7. **`www-data` user pre-exists:** The Nginx document roots are owned by `www-data`. It is assumed this user is created by the `nginx` package installation (standard on Ubuntu) and does not require explicit provisioning.
8. **No Chef Server / data bags:** No encrypted data bags, Chef Vault items, or Chef Server API calls are present beyond the Conjur integration. It is assumed all configuration is self-contained in this cookbook.
9. **`fail2ban` backend compatibility:** The `backend = auto` setting in `fail2ban.jail.local.erb` is assumed to be acceptable for the target OS. On Ubuntu 22.04 with systemd-journald, this may need to be changed to `backend = systemd` — this should be verified during testing.
10. **Static site content is final:** The three `index.html` files under `files/default/` are assumed to be the definitive site content. If these are generated or managed by a separate pipeline, the Ansible `copy` tasks should be replaced with a deployment mechanism appropriate to that pipeline.

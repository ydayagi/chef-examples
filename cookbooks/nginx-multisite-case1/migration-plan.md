# MIGRATION FROM CHEF TO ANSIBLE

## Executive Summary

This repository contains a single Chef cookbook (`nginx-multisite`, v1.0.0) that provisions a hardened Nginx web server hosting three SSL-enabled internal subdomains (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`). The cookbook orchestrates four tightly coupled concerns: OS-level security hardening, Nginx installation and configuration, SSL certificate generation, and per-site virtual-host deployment. It depends on one external community cookbook (`cyberark-conjur ~> 3.0`) for secrets retrieval.

The migration scope is **one cookbook → one Ansible role** (or a small set of tightly related roles). Complexity is **moderate**: the logic is well-structured, templates map 1-to-1 to Ansible `template` tasks, and the custom `lineinfile` resource has a direct Ansible built-in equivalent. The primary challenge is replacing the CyberArk Conjur Chef resource (`conjur_variable`) with an Ansible-native secrets lookup. No Berksfile or Policyfile was found; the single external dependency is declared only in `metadata.rb`.

**Estimated migration timeline: 3–5 days** for an engineer familiar with both Chef and Ansible, including testing.

---

## Module Migration Plan

This repository contains one Chef cookbook that needs individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **nginx-multisite**:
  - Description: Nginx multi-site web server cookbook that installs and configures Nginx with three SSL-enabled internal subdomains (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`), enforces OS-level security hardening (kernel sysctl parameters, UFW firewall rules, SSH hardening, fail2ban intrusion prevention), generates self-signed TLS certificates per vhost using a passphrase retrieved from CyberArk Conjur, and deploys per-site `index.html` static content.
  - Path: `.` (repository root — the cookbook is the repository)
  - Technology: Chef (chef_version `>= 16.0`)
  - Key Features:
    - **`recipes/default.rb`** — Orchestration entry point; calls `security`, `nginx`, `ssl`, and `sites` recipes in order.
    - **`recipes/security.rb`** — Installs `fail2ban` and `ufw`; configures `/etc/fail2ban/jail.local` (SSH, nginx-http-auth, nginx-limit-req, nginx-botsearch jails); applies kernel hardening via `/etc/sysctl.d/99-security.conf` (IP spoofing protection, ICMP redirect blocking, SYN-cookie flood protection, IPv6 disable); hardens SSH (`PermitRootLogin no`, `PasswordAuthentication no`) using a custom `lineinfile` resource; manages UFW rules (default deny, allow SSH/HTTP/HTTPS).
    - **`recipes/nginx.rb`** — Installs `nginx` package; deploys `nginx.conf` and `conf.d/security.conf` templates; creates per-site document-root directories (`/opt/server/<site>`) owned by `www-data`; copies static `index.html` files from cookbook `files/default/<site>/`; enables and starts the `nginx` service.
    - **`recipes/ssl.rb`** — Installs `openssl` and `ca-certificates`; fetches SSL passphrase from CyberArk Conjur via `conjur_variable()`; creates `ssl-cert` group; ensures `/etc/ssl/certs` and `/etc/ssl/private` directories exist with correct permissions; generates a self-signed RSA-2048 certificate per SSL-enabled site using `openssl req -x509`; marks the `execute` resource `sensitive true` to suppress passphrase from logs.
    - **`recipes/sites.rb`** — Renders per-vhost Nginx config from `site.conf.erb` into `/etc/nginx/sites-available/<site>`; creates symlinks in `sites-enabled`; removes the default Nginx site.
    - **`resources/lineinfile.rb`** — Custom Chef resource that replicates Ansible's `lineinfile` module: matches a regex in a file and replaces the line, or appends if not found; creates a timestamped `.backup` file before modifying.
    - **Templates**: `nginx.conf.erb` (global Nginx config with gzip, logging, vhost includes), `security.conf.erb` (rate-limiting zones, buffer overflow mitigations, global SSL settings), `site.conf.erb` (per-vhost server block with HTTP→HTTPS redirect, TLS 1.2/1.3, HSTS, CSP/XFO/XCTO security headers), `fail2ban.jail.local.erb` (five jails: DEFAULT, sshd, nginx-http-auth, nginx-limit-req, nginx-botsearch), `sysctl-security.conf.erb` (kernel hardening parameters).

---

### Infrastructure Files

- `metadata.rb`: Cookbook metadata — name, version, supported OS (Ubuntu ≥ 18.04, CentOS ≥ 7), Chef version constraint (`>= 16.0`), and the single external dependency (`cyberark-conjur ~> 3.0`). Maps to Ansible `meta/main.yml` and `galaxy_info`.
- `attributes/default.rb`: Node attribute defaults — site definitions (name, document root, SSL flag), SSL certificate/key paths, CyberArk Conjur connection parameters (appliance URL, account, variable path), and security feature flags (fail2ban, UFW, SSH hardening). Maps to Ansible `defaults/main.yml`.
- `files/default/ci/index.html`, `files/default/status/index.html`, `files/default/test/index.html`: Static HTML content served by each vhost. Maps directly to Ansible `files/` directory; deployed with the `copy` module.
- `resources/lineinfile.rb`: Custom Chef resource implementing line-in-file editing. **Replaced entirely by Ansible's built-in `ansible.builtin.lineinfile` module** — no custom code needed in Ansible.

---

### Target Details

- **Operating System**: Ubuntu (≥ 18.04) or CentOS (≥ 7.0), as declared in `metadata.rb`. Configuration artifacts (`www-data` user, `ufw`, `/var/log/auth.log`, `apt`-style paths) strongly indicate **Ubuntu/Debian** as the primary target. Default to **Ubuntu 22.04 LTS** for Ansible migration unless the deployment inventory specifies otherwise.
- **Virtual Machine Technology**: Not specified in the repository. No cloud-init configs, VM tools packages, or hypervisor-specific files are present.
- **Cloud Platform**: Not specified. No cloud provider SDK, metadata endpoint references, or cloud-specific packages are present. The internal `.cluster.local` domain suggests an on-premises or private-cloud deployment.

---

## Migration Approach

### Key Dependencies to Address

- **cyberark-conjur (~> 3.0)**: The cookbook's only external dependency, used in `recipes/ssl.rb` via the `conjur_variable()` helper to retrieve the SSL private-key passphrase at converge time. In Ansible, replace with the [CyberArk Conjur Ansible collection](https://galaxy.ansible.com/cyberark/conjur) (`cyberark.conjur`) and its `conjur_variable` lookup plugin, or use `community.hashi_vault` if the environment is transitioning to HashiCorp Vault. The Conjur appliance URL, account, and variable path are already parameterised in `attributes/default.rb` and map cleanly to Ansible variables.

---

### Security Considerations

- **CyberArk Conjur secrets retrieval**: `recipes/ssl.rb` calls `conjur_variable(node['cyberark']['conjur']['variable'])` to fetch the SSL passphrase at runtime. The passphrase is passed directly to an `openssl` shell command and the resource is marked `sensitive true`. In Ansible, use `cyberark.conjur.conjur_variable` lookup or `no_log: true` on any task that handles the passphrase variable to prevent it appearing in play output or logs.
- **SSL passphrase in shell command**: The `openssl req` command in `recipes/ssl.rb` passes the passphrase via `-passout pass:<value>` on the command line, which can be visible in process listings. Migrate to a file-based passphrase (`-passout file:<path>`) or use Ansible's `community.crypto.openssl_privatekey` module, which handles passphrases securely without shell exposure.
- **Self-signed certificates**: All three sites use self-signed certificates generated at converge time. The Ansible migration should evaluate whether to retain self-signed certs (use `community.crypto.x509_certificate`) or integrate a proper CA/ACME workflow (e.g., `community.crypto.acme_certificate`).
- **SSH hardening**: `PermitRootLogin no` and `PasswordAuthentication no` are enforced via the custom `lineinfile` resource. In Ansible, use `ansible.builtin.lineinfile` with `regexp` and `line` parameters — a direct, safe equivalent.
- **UFW firewall**: Managed via `execute` resources with idempotency guards (`not_if`). In Ansible, use the `community.general.ufw` module for fully declarative, idempotent firewall management.
- **Kernel sysctl hardening**: Applied via a template to `/etc/sysctl.d/99-security.conf`. Use `ansible.posix.sysctl` module for individual parameters, or `ansible.builtin.template` + `ansible.builtin.command: sysctl -p` for a direct template-based approach.
- **fail2ban configuration**: Jail configuration is template-driven. Use `ansible.builtin.template` to deploy `jail.local`; the jail definitions are static and require no secrets handling.
- **Security headers in Nginx**: HSTS, CSP, X-Frame-Options, X-Content-Type-Options, and X-XSS-Protection are embedded in `site.conf.erb`. These carry over directly to the Ansible Jinja2 template equivalent.
- **File permissions on SSL private keys**: `chmod 640` and `chown root:ssl-cert` are applied in the `openssl` shell command. In Ansible, use the `owner`, `group`, and `mode` parameters of `ansible.builtin.file` or the `community.crypto` modules' built-in permission arguments.

---

### Technical Challenges

- **`conjur_variable()` Chef helper → Ansible lookup**: The Chef `cyberark-conjur` cookbook injects a DSL helper method. Ansible requires explicit lookup plugin syntax (`lookup('cyberark.conjur.conjur_variable', ...)`) and Conjur host identity configuration (host factory token or API key) to be pre-established on the managed node or in the Ansible controller environment. This is the highest-risk item and should be validated in a non-production environment first.
- **Custom `lineinfile` resource**: The cookbook ships its own `lineinfile` resource because Chef's built-in equivalent is less ergonomic. Ansible's `ansible.builtin.lineinfile` is a direct, mature replacement — no custom code required. The backup behaviour (timestamped `.backup` files) should be reviewed; Ansible's `backup: yes` creates a single dated backup, which is sufficient.
- **Idempotency of `execute` resources**: Several `execute` blocks in `recipes/security.rb` and `recipes/ssl.rb` use shell-level `not_if` guards for idempotency. These must be translated to Ansible module-native idempotency (e.g., `community.general.ufw` state checks, `community.crypto.x509_certificate` `force: false`) rather than raw `command` tasks with `creates` or `when` guards, to maintain clean idempotency semantics.
- **`sensitive true` on `execute` resources**: Chef's `sensitive true` suppresses resource output in logs. In Ansible, use `no_log: true` on any task that handles the passphrase. Ensure this is applied consistently across all tasks in the SSL play, not just the `openssl` command task.
- **Template variable scoping**: Chef ERB templates receive variables via the `variables()` hash in the `template` resource. Ansible Jinja2 templates use role/play variables directly. The `site.conf.erb` template receives `server_name`, `document_root`, `ssl_enabled`, `cert_file`, and `key_file` — these must be mapped to a loop variable structure (e.g., a list of site dictionaries) in the Ansible role's `defaults/main.yml`.
- **Multi-site loop pattern**: Both `recipes/nginx.rb` and `recipes/sites.rb` iterate over `node['nginx']['sites']` (a hash). In Ansible, this maps to `loop` over a list of site dictionaries. The `site_folder` derivation (`site_name.split('.').first`) must be replicated in Jinja2 (e.g., `{{ item.name.split('.')[0] }}`).
- **`www-data` user assumption**: The cookbook hardcodes `www-data` as the Nginx worker user and document-root owner, which is Debian/Ubuntu-specific. On CentOS/RHEL, the Nginx user is `nginx`. If the Ansible role must support both OS families, add a conditional variable (`nginx_user`) with OS-family-based defaults.

---

### Migration Order

1. **Security hardening tasks** (`recipes/security.rb` → `tasks/security.yml`): No external secrets dependency; uses only built-in Ansible modules (`lineinfile`, `ufw`, `sysctl`, `template`, `service`, `package`). Low risk, high value as a standalone hardening role. Validate idempotency of UFW and sysctl tasks first.
2. **Nginx installation and base configuration** (`recipes/nginx.rb` + templates `nginx.conf.erb`, `security.conf.erb` → `tasks/nginx.yml`): No secrets dependency; straightforward `package`, `template`, `file`, `copy`, and `service` tasks. Confirms the template-variable mapping pattern before tackling the more complex per-site loop.
3. **Static site content deployment** (`recipes/sites.rb` + `files/default/*/index.html` → `tasks/sites.yml`): Introduces the multi-site loop pattern. Validate Jinja2 loop variable scoping and symlink management (`ansible.builtin.file` with `state: link`) before adding SSL complexity.
4. **SSL certificate generation** (`recipes/ssl.rb` → `tasks/ssl.yml`): Highest complexity due to CyberArk Conjur integration and secure passphrase handling. Implement and test the `cyberark.conjur.conjur_variable` lookup in isolation before wiring it into the certificate generation tasks. Consider `community.crypto.openssl_privatekey` and `community.crypto.x509_certificate` modules as the Ansible-native alternative to the raw `openssl` shell command.

---

### Assumptions

1. **No Berksfile or Policyfile**: The repository contains no `Berksfile`, `Policyfile.rb`, or `Berksfile.lock`. It is assumed the cookbook is consumed directly (e.g., via a wrapper cookbook or `chef-solo`) and that `cyberark-conjur ~> 3.0` is the only external cookbook dependency to replicate.
2. **CyberArk Conjur is retained**: The migration plan assumes CyberArk Conjur remains the secrets backend. If the organisation is moving to HashiCorp Vault or AWS Secrets Manager, the lookup plugin and variable path (`production/nginx/ssl_passphrase`) will need to be remapped accordingly.
3. **Self-signed certificates are intentional**: The `openssl req -x509` approach is used for all three sites. It is assumed this is intentional for an internal cluster environment and not a placeholder for a production CA. If a CA or ACME workflow is required, `community.crypto.acme_certificate` or an internal PKI integration must be scoped separately.
4. **Ubuntu is the primary target OS**: The `www-data` user, `ufw`, `/var/log/auth.log`, and `apt`-style assumptions in the cookbook point to Ubuntu/Debian. CentOS support is declared in `metadata.rb` but no CentOS-specific conditionals exist in the recipes. The Ansible role should default to Ubuntu and add CentOS support as a follow-on task if required.
5. **IPv6 is intentionally disabled**: `sysctl-security.conf.erb` sets `net.ipv6.conf.all.disable_ipv6 = 1`. This is assumed to be a deliberate policy decision for the target environment, not an oversight.
6. **ICMP is intentionally blocked**: `net.ipv4.icmp_echo_ignore_all = 1` disables all ICMP echo replies. This may interfere with monitoring and health-check tooling; the Ansible role should expose this as a configurable variable (`security_block_icmp: true`) rather than hardcoding it.
7. **Static `index.html` files are the complete site content**: The `files/default/` directory contains only `index.html` per site. It is assumed no additional application deployment (PHP, Node.js, etc.) is managed by this cookbook.
8. **Single-cookbook repository**: The repository root is the cookbook itself (no `cookbooks/` subdirectory, no control repo structure). The Ansible equivalent is a single role, potentially published to Ansible Galaxy or an internal Automation Hub.
9. **No test infrastructure files**: No `kitchen.yml`, `spec/`, or `test/` directories are present. Ansible migration testing strategy (Molecule, `ansible-lint`) will need to be established from scratch.
10. **`sensitive true` scope**: Only the `execute` resource in `recipes/ssl.rb` is marked `sensitive true`. It is assumed the Conjur appliance URL and account name are not considered sensitive (they are stored in plain-text attributes). Only the `ssl_passphrase` variable value requires `no_log: true` treatment in Ansible.

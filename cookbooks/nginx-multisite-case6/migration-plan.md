# MIGRATION FROM CHEF TO ANSIBLE

## Executive Summary

This repository contains a single Chef cookbook (`nginx-multisite`, version 1.0.0) that provisions a hardened Nginx web server with multiple SSL-enabled virtual hosts, a firewall, intrusion-prevention, and kernel-level security hardening. The cookbook is self-contained — it ships four recipes, five custom resources, five ERB templates, and three static site files — and carries one external dependency on the `cyberark-conjur` Chef cookbook for secrets retrieval.

The migration scope is moderate. The Nginx, SSL, and site-configuration logic maps cleanly to existing Ansible modules (`ansible.builtin.package`, `ansible.builtin.template`, `ansible.builtin.service`, `community.general.ufw`, etc.). The primary complexity lies in replacing three bespoke custom resources that integrate with internal, proprietary systems: an OAuth token fetcher (`fetch_token`), a company-internal secrets platform (`secret_setting`), and a proprietary configuration-file format writer (`my_format`). These have no direct Ansible equivalents and will require custom modules or purpose-built roles. The CyberArk Conjur integration for SSL passphrase retrieval must also be re-implemented using the CyberArk Ansible collection or an equivalent secrets-management approach.

**Estimated timeline**: 3–5 weeks for a single engineer; 2–3 weeks with a two-person team.
- Week 1: Foundation roles (security hardening, Nginx core, UFW/fail2ban)
- Week 2: SSL management, site templating, Conjur/secrets integration
- Week 3: Custom resource replacements, integration testing, documentation
- Week 4–5 (if needed): Parallel-run validation, rollback procedures, team handover

---

## Module Migration Plan

This repository contains one Chef cookbook with four tightly coupled internal recipes that need individual migration planning:

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
All paths below were confirmed from the provided repository tree and file reads.

---

- **nginx-multisite** *(cookbook root)*
  - **Description**: Top-level Chef cookbook that orchestrates the full server provisioning sequence. The default recipe chains four sub-recipes in order: `security` → `nginx` → `ssl` → `sites`. It targets Ubuntu ≥ 18.04 and CentOS ≥ 7.0 and requires Chef ≥ 16.0.
  - **Path**: `.` (cookbook root — `metadata.rb`, `recipes/default.rb`)
  - **Technology**: Chef
  - **Key Features**: Ordered recipe orchestration, multi-OS support declaration, single external dependency pin (`cyberark-conjur ~> 3.0`)

---

- **nginx-multisite::nginx** *(Nginx installation & base configuration)*
  - **Description**: Installs the `nginx` package, deploys the global `nginx.conf` and a `security.conf` drop-in from ERB templates, creates per-site document-root directories owned by `www-data`, copies static `index.html` files for each vhost, and manages the `nginx` service (enabled + started, with delayed reload on config changes).
  - **Path**: `recipes/nginx.rb`, `templates/default/nginx.conf.erb`, `templates/default/security.conf.erb`, `files/default/{ci,status,test}/index.html`
  - **Technology**: Chef
  - **Key Features**: Hiera-driven site loop over `node['nginx']['sites']`, `www-data` ownership enforcement, gzip enabled, security drop-in (rate limiting, buffer overflow protection, TLS 1.2/1.3 only, `server_tokens off`)

---

- **nginx-multisite::ssl** *(SSL certificate provisioning)*
  - **Description**: Installs `openssl` and `ca-certificates`, creates the `ssl-cert` group, provisions certificate and private-key directories with strict permissions (`0755`/`0710`), and generates self-signed RSA-2048 certificates for every SSL-enabled vhost via `openssl req -x509`. The private-key passphrase is fetched at converge time from CyberArk Conjur using the `conjur_variable` helper provided by the `cyberark-conjur` cookbook dependency.
  - **Path**: `recipes/ssl.rb`, `attributes/default.rb`
  - **Technology**: Chef
  - **Key Features**: CyberArk Conjur secret lookup (`production/nginx/ssl_passphrase`), idempotent cert generation (`not_if` file-existence guard), `sensitive true` on the `execute` block, per-site cert/key lifecycle, `ssl-cert` group for key access control

---

- **nginx-multisite::sites** *(Virtual host configuration)*
  - **Description**: Iterates over `node['nginx']['sites']` to render per-vhost Nginx server-block configs from `site.conf.erb` into `/etc/nginx/sites-available/`, creates symlinks in `sites-enabled/`, and removes the default Nginx site. Each vhost config enforces HTTP→HTTPS redirect, TLS 1.2/1.3 with strong cipher suites, HSTS, and a full set of security response headers (X-Frame-Options, X-Content-Type-Options, X-XSS-Protection, Referrer-Policy, Content-Security-Policy).
  - **Path**: `recipes/sites.rb`, `templates/default/site.conf.erb`
  - **Technology**: Chef
  - **Key Features**: Three pre-configured vhosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`), HTTP/2 on port 443, per-vhost access/error logs, `.ht`/`.git`/`.svn` location blocks denied, `sites-available` + `sites-enabled` symlink pattern

---

- **nginx-multisite::security** *(OS-level security hardening)*
  - **Description**: Installs `fail2ban` and `ufw`, deploys `jail.local` from an ERB template (SSH, nginx-http-auth, nginx-limit-req, nginx-botsearch jails; 3600 s ban, 3 retries), configures UFW with default-deny and explicit allow rules for SSH/HTTP/HTTPS, writes kernel hardening parameters to `/etc/sysctl.d/99-security.conf` (IP spoofing protection, ICMP redirect rejection, SYN-cookie flood protection, IPv6 disable), and conditionally hardens `sshd_config` (disables root login and password authentication) via the `ada_ada` custom resource. Also invokes the `fetch_token`, `fetch_and_parse_token`, `my_format`, and `secret_setting` custom resources.
  - **Path**: `recipes/security.rb`, `templates/default/fail2ban.jail.local.erb`, `templates/default/sysctl-security.conf.erb`
  - **Technology**: Chef
  - **Key Features**: UFW idempotency guards via `not_if` shell checks, `sysctl -p` reload on change, SSH hardening driven by node attributes, integration with four custom resources (see below)

---

- **ada_ada** *(Custom resource — in-place config-file line editor)*
  - **Description**: A custom Chef resource that performs regex-based find-and-replace (or append) on arbitrary text configuration files. Supports a `match` regex pattern to locate and overwrite an existing line, or appends the line if no match is found. Creates a timestamped `.backup.<epoch>` file before modifying. Used in `security.rb` to patch `sshd_config` directives (`PermitRootLogin`, `PasswordAuthentication`).
  - **Path**: `resources/ada_ada.rb`
  - **Technology**: Chef Custom Resource
  - **Key Features**: Regex match-and-replace, optional backup, idempotent (skips write if content unchanged), maps directly to Ansible `ansible.builtin.lineinfile`

---

- **fetch_token** *(Custom resource — OAuth2 client-credentials token fetcher)*
  - **Description**: A custom Chef resource that POSTs a JSON body containing `client_id` and `client_secret` to a configurable OAuth2 token endpoint and stores the returned `access_token` in `node.run_state`. **Security issue**: in `security.rb` the resource is invoked with a hardcoded `client_secret` value (`'sup3rs3cr3t'`), exposing a credential in plain text in the recipe source.
  - **Path**: `resources/fetch_token.rb`
  - **Technology**: Chef Custom Resource
  - **Key Features**: Runtime HTTP POST via Ruby `net/http`, result stored in Chef run-state, hardcoded secret in caller (`security.rb`)

---

- **fetch_and_parse_token** *(Custom resource — HTTP token fetcher with regex extraction)*
  - **Description**: A custom Chef resource that performs an HTTP GET against a configurable URL and extracts a value from the response body using the regex pattern `pattern1:(.+)`. The extracted value is stored in `node.run_state['extracted_token']`. The regex pattern and the downstream consumer of the extracted token are not documented in the cookbook; the actual pattern strings appear to be placeholders.
  - **Path**: `resources/fetch_and_parse_token.rb`
  - **Technology**: Chef Custom Resource
  - **Key Features**: Runtime HTTP GET, regex capture group extraction, undocumented pattern (`pattern1:(.+)` appears to be a placeholder requiring clarification before migration)

---

- **my_format** *(Custom resource — proprietary config-file format writer)*
  - **Description**: A custom Chef resource that manages entries in a proprietary `!key=value` configuration format used by an internal application (`/etc/company/app.conf`). Preserves comment lines and non-matching lines. Supports `:set` (upsert) and `:remove` actions. Used in `security.rb` to write `app_mode=production` and `health_port=8080`.
  - **Path**: `resources/my_format.rb`
  - **Technology**: Chef Custom Resource
  - **Key Features**: Proprietary `!key=value` line format, comment-line preservation, upsert semantics, no standard Ansible module equivalent — requires a custom Ansible module or `lineinfile`/`blockinfile` workaround

---

- **secret_setting** *(Custom resource — company-internal secrets platform client)*
  - **Description**: A custom Chef resource that retrieves named secrets from an undocumented internal secrets platform via the proprietary Ruby gem `company_internal_lib` (`CompanyInternal::SettingsStore`). The gem is not distributed with this cookbook and is documented only on an internal wiki. Used in `security.rb` to fetch `service_api_key` scoped to `nginx`. The retrieved value is stored in `node.run_state`.
  - **Path**: `resources/secret_setting.rb`
  - **Technology**: Chef Custom Resource
  - **Key Features**: Dependency on internal-only gem `company_internal_lib`, opaque authentication mechanism, no public documentation — the migration team must obtain the internal wiki documentation and determine the Ansible-compatible equivalent (e.g., HashiCorp Vault, AWS Secrets Manager, or a custom lookup plugin)

---

### Infrastructure Files

- `metadata.rb`: Cookbook identity, version (`1.0.0`), OS support matrix (Ubuntu ≥ 18.04, CentOS ≥ 7.0), Chef version floor (≥ 16.0), and the single external dependency (`cyberark-conjur ~> 3.0`). Maps to Ansible role `meta/main.yml` and `galaxy_info`.
- `attributes/default.rb`: Node attribute defaults — vhost definitions (names, document roots, SSL flags), SSL certificate/key paths, CyberArk Conjur connection parameters (appliance URL, account, variable path), and security feature toggles (fail2ban, UFW, SSH hardening flags). Maps to Ansible role `defaults/main.yml` variables.
- `files/default/ci/index.html`, `files/default/status/index.html`, `files/default/test/index.html`: Static HTML placeholder pages for the three vhosts. Migrate as-is to `files/` in the Ansible role.
- `templates/default/nginx.conf.erb`: Global Nginx configuration (worker processes, events, HTTP block, logging, gzip, include directives). Migrate to a Jinja2 template (`nginx.conf.j2`).
- `templates/default/security.conf.erb`: Nginx security drop-in (`/etc/nginx/conf.d/security.conf`) — rate-limit zones, buffer limits, timeout values, global TLS settings. Migrate to `security.conf.j2`.
- `templates/default/site.conf.erb`: Per-vhost server block with conditional SSL, HTTP→HTTPS redirect, TLS 1.2/1.3, HSTS, and security headers. Migrate to `site.conf.j2`; the ERB conditionals (`<% if @ssl_enabled %>`) map directly to Jinja2 `{% if ssl_enabled %}`.
- `templates/default/fail2ban.jail.local.erb`: fail2ban `jail.local` with SSH, nginx-http-auth, nginx-limit-req, and nginx-botsearch jails. Currently static (no ERB variables used); can be migrated as a static file or a trivial Jinja2 template.
- `templates/default/sysctl-security.conf.erb`: Kernel hardening parameters for `/etc/sysctl.d/99-security.conf`. Currently static (no ERB variables); migrate as a static file or `sysctl` Ansible module calls.

---

### Target Details

- **Operating System**: Ubuntu ≥ 18.04 (primary, given `www-data` user, `ufw`, `/var/log/auth.log` path in fail2ban, and `sites-available`/`sites-enabled` Nginx layout) and CentOS ≥ 7.0 (declared in `metadata.rb` but no CentOS-specific branching is present in the recipes). The Ansible role should default to **Ubuntu 22.04 LTS** and add a CentOS/RHEL 9 compatibility layer if required.
- **Virtual Machine Technology**: Not specified. No cloud-init configs, VM-tools packages, or hypervisor-specific files are present.
- **Cloud Platform**: Not specified. No cloud provider SDK, metadata endpoint calls, or IAM references are present. The CyberArk Conjur appliance URL (`https://conjur.example.com`) suggests an on-premises or private-cloud deployment.

---

## Migration Approach

### Key Dependencies to Address

- **cyberark-conjur (~> 3.0)** *(external Chef cookbook)*: Provides the `conjur_variable` helper used in `recipes/ssl.rb` to retrieve the SSL private-key passphrase at converge time. Replace with the [CyberArk Conjur Ansible collection](https://galaxy.ansible.com/cyberark/conjur) (`cyberark.conjur`) and its `conjur_variable` lookup plugin, or with `ansible.builtin.uri` tasks that call the Conjur REST API directly. The Conjur appliance URL, account, and variable path are already externalised in `attributes/default.rb` and will map cleanly to Ansible variables.

- **company_internal_lib** *(internal Ruby gem — `secret_setting` resource)*: An undocumented proprietary gem used exclusively by the `secret_setting` custom resource. No public source or API documentation exists. The migration team must: (1) obtain the internal wiki documentation, (2) identify the underlying secrets platform (likely an internal Vault or key-management service), and (3) implement an equivalent Ansible lookup plugin or `ansible.builtin.uri` task. This is the highest-risk dependency in the migration.

- **net/http + json** *(Ruby stdlib — `fetch_token` / `fetch_and_parse_token` resources)*: Used for runtime HTTP calls to an OAuth2 token endpoint and a custom token-parsing endpoint. Replace with `ansible.builtin.uri` tasks. The OAuth2 client-credentials flow maps to a POST task with `body_format: json`; the regex extraction maps to an Ansible `set_fact` with a `regex_search` filter.

### Security Considerations

- **Hardcoded OAuth2 client secret** (`security.rb`, `fetch_token` invocation): The `client_secret` property is set to the literal string `'sup3rs3cr3t'` directly in the recipe source code. This credential must be removed from source control immediately and migrated to Ansible Vault, CyberArk Conjur, or the company secrets platform before any Ansible equivalent is written. Treat this as a **critical finding** — rotate the secret if the repository has ever been pushed to a shared or remote Git host.

- **CyberArk Conjur SSL passphrase** (`recipes/ssl.rb`): The passphrase for self-signed certificate private keys is retrieved from Conjur at `production/nginx/ssl_passphrase`. The Conjur appliance URL and account are stored in attributes (not secrets), which is acceptable. The Ansible migration must preserve the Conjur lookup and must not fall back to a hardcoded passphrase. Mark the corresponding Ansible variable as `no_log: true`.

- **`secret_setting` — `service_api_key`** (`recipes/security.rb`): An API key scoped to `nginx` is fetched from the internal secrets platform. The key's purpose and downstream consumer are not documented in the cookbook. The migration team must identify where `node.run_state['service_api_key']` is consumed (possibly by a downstream cookbook or a wrapper not present in this repository) before this can be safely migrated.

- **`fetch_and_parse_token` — undocumented token** (`recipes/security.rb`): The regex pattern `pattern1:(.+)` and the token URL `https://api.example.com/token_endpoint` appear to be placeholders. The actual pattern and endpoint must be confirmed with the cookbook maintainer. The extracted token's downstream use is also undocumented.

- **SSH hardening** (`recipes/security.rb`, `ada_ada` resource): Root login and password authentication are disabled via `sshd_config` patches. These settings are attribute-driven (`node['security']['ssh']['disable_root']`, `node['security']['ssh']['password_auth']`). In Ansible, use `ansible.builtin.lineinfile` with `validate` and ensure the SSH service is not restarted until the Ansible control connection is confirmed to be key-based, to avoid locking out the automation user.

- **UFW firewall rules** (`recipes/security.rb`): Default-deny with explicit allow for ports 22, 80, 443. The `community.general.ufw` Ansible module provides a direct equivalent. Ensure the Ansible control node's SSH port is allowed before the default-deny rule is applied (ordering matters).

- **SSL/TLS configuration**: TLS 1.0 and 1.1 are explicitly excluded; only TLS 1.2 and 1.3 are permitted. Cipher suites are hardcoded in both `security.conf.erb` and `site.conf.erb`. Preserve these settings verbatim in the Jinja2 templates. Consider parameterising the cipher list as an Ansible variable to allow future updates without template edits.

- **Self-signed certificates**: The SSL recipe generates self-signed certificates, which is noted as being for development. Confirm with the team whether production deployments use a different certificate source (e.g., Let's Encrypt, an internal CA, or certificates distributed via Conjur). If so, the Ansible role should support both paths via a variable flag.

- **Kernel hardening** (`sysctl-security.conf.erb`): IPv6 is globally disabled (`net.ipv6.conf.all.disable_ipv6 = 1`). Verify this is intentional for all target hosts before applying; disabling IPv6 can break some cloud-provider metadata services and dual-stack networking.

### Technical Challenges

- **`secret_setting` / `company_internal_lib` black box**: The internal gem has no public documentation and is not distributed with the cookbook. The migration is blocked on obtaining the internal wiki documentation and understanding the underlying secrets platform. **Mitigation**: Escalate to the cookbook maintainer (`admin@example.com`) and the internal platform team before beginning the Ansible role for `security.rb`. Plan for a custom Ansible lookup plugin if no standard integration exists.

- **`fetch_and_parse_token` placeholder pattern**: The regex `pattern1:(.+)` and the endpoint `https://api.example.com/token_endpoint` are almost certainly placeholders, not production values. The actual token URL, response format, and downstream consumer of the extracted token are unknown. **Mitigation**: Treat this resource as a documentation gap; do not migrate it until the real values and purpose are confirmed with the team.

- **Hardcoded `client_secret` in `fetch_token`**: Beyond the security risk, the hardcoded value `'sup3rs3cr3t'` is almost certainly not the real production secret. The actual credential must be retrieved from the secrets platform before the Ansible equivalent can be written. **Mitigation**: Rotate the secret, store it in Ansible Vault or Conjur, and reference it via a variable.

- **`my_format` proprietary config format**: The `!key=value` format used by `/etc/company/app.conf` has no standard Ansible module equivalent. `ansible.builtin.lineinfile` can approximate the upsert behaviour for simple cases, but the comment-preservation and multi-entry semantics require a custom Ansible module or a Python-based `ansible.builtin.script` task. **Mitigation**: Write a small custom Ansible module (`my_format`) that replicates the resource logic; this is a low-complexity Python port of the existing Ruby.

- **`ada_ada` line-editor with backup**: `ansible.builtin.lineinfile` covers the core find-and-replace behaviour. The timestamped backup feature has no direct equivalent but can be approximated with a `backup: yes` parameter (Ansible creates a single backup copy). If the timestamped-backup behaviour is a compliance requirement, a pre-task using `ansible.builtin.copy` with a timestamped destination can replicate it. **Mitigation**: Confirm whether the backup behaviour is a compliance requirement or a convenience feature.

- **Chef run-state token passing**: Both `fetch_token` and `fetch_and_parse_token` store results in `node.run_state`, which is Chef's in-memory inter-resource communication mechanism. In Ansible, the equivalent is `register` + `set_fact`. The migration must trace every downstream consumer of `node.run_state['access_token']` and `node.run_state['extracted_token']` — neither consumer is visible within this cookbook, suggesting a wrapper cookbook or downstream dependency not present in this repository.

- **Multi-OS support (Ubuntu + CentOS)**: The cookbook declares support for both distros but contains no OS-conditional branching. Package names (`nginx`, `fail2ban`, `ufw`), service names, and file paths are Ubuntu-centric (`www-data`, `/var/log/auth.log`, `sites-available`/`sites-enabled`). The Ansible role must add `when: ansible_os_family == 'Debian'` / `'RedHat'` guards, substitute `firewalld` for `ufw` on CentOS/RHEL, and adjust the Nginx directory layout. **Mitigation**: Implement OS-family variables in `vars/Debian.yml` and `vars/RedHat.yml`.

- **Self-signed cert idempotency**: The `not_if` guard checks for the existence of both the cert and key files. In Ansible, `ansible.builtin.stat` + `when` provides the same guard. However, the `openssl` command embeds the passphrase on the command line (`-passout pass:{{ ssl_passphrase }}`), which will be visible in process listings. Use `ansible.builtin.command` with `no_log: true` or switch to the `community.crypto.openssl_privatekey` and `community.crypto.x509_certificate` modules, which handle passphrases securely.

### Migration Order

1. **Security hardening (kernel + UFW + fail2ban)** — Low external dependency, high value, maps cleanly to `community.general.ufw`, `ansible.builtin.sysctl`, and `ansible.builtin.template`. Delivers a standalone hardening role immediately usable by other teams.
2. **Nginx installation and base configuration** — Straightforward package + template + service pattern; no secrets required. Validates the template migration (ERB → Jinja2) and the `www-data` ownership model.
3. **Virtual host site configuration** — Depends on Nginx base being in place. The `site.conf.erb` → `site.conf.j2` conversion is mechanical. Validates the vhost loop and symlink management.
4. **SSH hardening (`ada_ada` replacement)** — Replace `ada_ada` with `ansible.builtin.lineinfile`. Low complexity once the backup-behaviour question is resolved. Must be tested carefully to avoid SSH lockout.
5. **`my_format` config writer** — Write and unit-test the custom Ansible module. Depends on confirming the `/etc/company/app.conf` format with the application team.
6. **CyberArk Conjur SSL integration** — Integrate `cyberark.conjur` collection; migrate SSL certificate generation to `community.crypto` modules. Depends on Conjur connectivity being available in the Ansible control environment.
7. **`fetch_token` OAuth2 integration** — Blocked on secret rotation and confirmation of the real `auth_url` and `client_id`. Implement with `ansible.builtin.uri` once credentials are available in Ansible Vault/Conjur.
8. **`secret_setting` / `company_internal_lib` replacement** — Highest risk; blocked on internal documentation. Implement last, after the secrets platform team provides an API or Ansible integration path.
9. **`fetch_and_parse_token` replacement** — Blocked on clarification of the real endpoint and regex pattern. Implement after the token URL and format are confirmed.

### Assumptions

1. **No Berksfile or Policyfile**: No `Berksfile`, `Policyfile.rb`, or `Policyfile.lock.json` was found. It is assumed the cookbook is consumed directly (e.g., via a wrapper cookbook or a Chef environment) rather than through Berkshelf or Chef Policyfiles. The `cyberark-conjur` cookbook version constraint (`~> 3.0`) must be resolved manually when setting up the Ansible environment.
2. **Self-signed certificates are for non-production use**: The SSL recipe comment states "Generate self-signed certificate for development." It is assumed that production deployments use a different certificate source. The Ansible role should expose a `ssl_cert_source` variable (`self_signed` | `conjur` | `letsencrypt` | `provided`) to support both cases.
3. **`node.run_state` consumers are external**: Neither `node.run_state['access_token']` nor `node.run_state['extracted_token']` is consumed within this cookbook. It is assumed they are consumed by a wrapper cookbook or a downstream cookbook not present in this repository. The migration team must locate and migrate those consumers before removing the token-fetching logic.
4. **`company_internal_lib` gem is available in the Chef environment**: The gem is not vendored in the cookbook. It is assumed it is installed on the Chef node via a separate mechanism (e.g., a base cookbook or a custom Chef omnibus build). The Ansible migration team must identify this mechanism and its Ansible equivalent.
5. **`pattern1:(.+)` is a placeholder**: The regex and endpoint in `fetch_and_parse_token` are assumed to be sanitised placeholders substituted for the real values before publication. The real values must be obtained from the cookbook maintainer.
6. **`sup3rs3cr3t` is not the real production secret**: The hardcoded `client_secret` in `security.rb` is assumed to be a placeholder or a development credential. The real production secret must be retrieved from the secrets platform and stored securely before migration.
7. **CentOS/RHEL support is aspirational**: No CentOS-specific code paths exist in the cookbook despite the `metadata.rb` declaration. It is assumed Ubuntu is the primary (and possibly only) production target. CentOS/RHEL support in the Ansible role should be implemented but may not be immediately required.
8. **IPv6 disable is intentional**: The `sysctl-security.conf.erb` template disables IPv6 globally. It is assumed this is a deliberate policy decision for the target environment, not an oversight.
9. **The `service_api_key` is consumed externally**: The `secret_setting 'service_api_key'` resource stores a value in `node.run_state` but no consumer is visible in this cookbook. It is assumed the key is used by a downstream cookbook, an application deployed separately, or a wrapper not present in this repository.
10. **Ansible control node has network access to Conjur**: The migration assumes the Ansible control node (or the managed nodes, depending on the lookup strategy) can reach `https://conjur.example.com` at playbook execution time.

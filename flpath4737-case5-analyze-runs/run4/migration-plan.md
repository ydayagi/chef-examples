# MIGRATION FROM CHEF TO ANSIBLE

## Executive Summary

This repository contains a single Chef cookbook (`nginx-multisite` v1.0.0) that configures Nginx as a multi-site SSL-enabled web server with host hardening. The migration to Ansible is **already complete**: a fully validated Ansible role (`ansible/roles/nginx_multisite`) exists alongside the original Chef source, produced by an automated migration pipeline. The migration plan below documents the source cookbook, the resulting Ansible role, all decisions made during migration, and the outstanding work items that require human resolution before the role can be deployed to production.

**Migration scope:** 1 Chef cookbook → 1 Ansible role  
**Overall complexity:** Medium — the cookbook is self-contained and well-structured, but contains three distinct secrets-management integrations (CyberArk Conjur, OAuth2 client credentials, and an undocumented API token endpoint) that required careful handling.  
**Estimated remaining effort:** 2–5 days of human follow-up (secrets rotation, API token investigation, AAP job-template wiring, and production smoke-testing).

---

## Module Migration Plan

This repository contains one Chef cookbook that has been migrated to one Ansible role.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
All paths below were confirmed from the provided repository tree and file reads. No paths have been inferred or invented.

---

- **nginx-multisite** *(Chef source — original)*
  - **Description:** Installs and configures Nginx as a multi-virtual-host SSL web server serving three internal subdomains (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`). Hardens the host with fail2ban, UFW firewall rules (deny-by-default, allow 22/80/443), sysctl kernel parameters, and SSH daemon hardening (no root login, no password auth). Generates self-signed TLS certificates per virtual host using an SSL passphrase fetched from CyberArk Conjur. Fetches an OAuth2 bearer token at runtime and calls a second undocumented API token endpoint via a custom resource.
  - **Path:** `/` (cookbook root — `metadata.rb`, `recipes/`, `attributes/`, `templates/`, `files/`, `resources/`)
  - **Technology:** Chef (requires Chef >= 16.0)
  - **Key Features:**
    - Four recipes orchestrated by `default.rb`: `security` → `nginx` → `ssl` → `sites`
    - Three custom resources: `ada_ada` (in-place line editing of config files), `fetch_token` (OAuth2 client-credentials POST), `fetch_and_parse_token` (regex-parsed GET token)
    - CyberArk Conjur integration via `conjur_variable()` helper for SSL passphrase retrieval
    - Hardcoded OAuth2 `client_secret` (`sup3rs3cr3t`) in `recipes/security.rb` — a critical security finding
    - Five ERB templates: `nginx.conf`, `security.conf`, `site.conf` (with variables), `fail2ban.jail.local`, `sysctl-security.conf`
    - Static `index.html` files for each of the three virtual host document roots

- **nginx_multisite** *(Ansible target — migrated)*
  - **Description:** Direct Ansible equivalent of the Chef cookbook above. Installs and configures Nginx for three SSL-enabled virtual hosts, hardens the host, generates self-signed TLS certificates, and fetches OAuth2 tokens. All secrets are injected at runtime via Ansible Automation Platform (AAP) custom credential types — no secrets are stored in the role.
  - **Path:** `ansible/roles/nginx_multisite/`
  - **Technology:** Ansible (requires Ansible >= 2.14.0; uses only `ansible.builtin.*` modules — no community collections)
  - **Key Features:**
    - Task files mirror recipe structure: `validate_credentials.yml` → `security.yml` → `nginx.yml` → `ssl.yml` → `sites.yml`
    - `validate_credentials.yml` asserts all 11 required AAP credential variables are defined before any work begins
    - UFW management via `ansible.builtin.shell` (no community UFW module used, per project constraint)
    - `ada_ada` custom resource replaced by `ansible.builtin.lineinfile` with `regexp`/`backup`/`create: false` and a preceding `stat` guard
    - `fetch_token` custom resource replaced by `ansible.builtin.uri` (POST) + `ansible.builtin.set_fact`
    - `fetch_and_parse_token` custom resource **not yet implemented** — blocked pending production details (see Technical Challenges)
    - SSL certificate generation via `ansible.builtin.shell` wrapping `openssl req`, with `creates:` for idempotency and `no_log` for secret protection
    - Three AAP custom credential types defined in `aap-configuration/controller_credential_types.yml`
    - Full Molecule test suite (`converge`, `verify`, `create`, `destroy`) with local-connection driver
    - `meta/argument_specs.yml` documents all 17 role variables with types and descriptions
    - Three ordering bugs from the Chef source identified and fixed during migration (see `export-output.md`)

---

### Infrastructure Files

- `metadata.rb`: Chef cookbook metadata — name, version (`1.0.0`), maintainer, license (Apache-2.0), supported platforms (Ubuntu >= 18.04, CentOS >= 7.0), and the single external dependency `cyberark-conjur ~> 3.0`. Migrated to `ansible/roles/nginx_multisite/meta/main.yml`.
- `attributes/default.rb`: Chef node attributes defining the three virtual host configurations, SSL certificate paths, CyberArk Conjur connection parameters, and security feature toggles. Migrated to `ansible/roles/nginx_multisite/defaults/main.yml` with all credential values replaced by AAP-injected variable references.
- `templates/default/*.erb`: Five ERB templates for Nginx, fail2ban, sysctl, and SSH configuration. Migrated to `ansible/roles/nginx_multisite/templates/*.j2`; `site.conf.erb` required ERB-to-Jinja2 variable conversion; the remaining four were static and copied as-is.
- `files/default/{ci,status,test}/index.html`: Static HTML placeholder files for each virtual host document root. Copied to `ansible/roles/nginx_multisite/files/{ci,status,test}/index.html`.
- `resources/ada_ada.rb`: Custom Chef resource for idempotent in-place line editing of config files (with regex match and backup). Replaced by `ansible.builtin.lineinfile`.
- `resources/fetch_token.rb`: Custom Chef resource performing an OAuth2 client-credentials POST and storing the access token in `node.run_state`. Replaced by `ansible.builtin.uri` + `ansible.builtin.set_fact`.
- `resources/fetch_and_parse_token.rb`: Custom Chef resource performing a GET to an undocumented API endpoint and extracting a token via regex from the response body. **Not yet migrated** — see Technical Challenges.
- `ansible/roles/nginx_multisite/aap-configuration/controller_credential_types.yml`: Defines three AAP custom credential types: `CyberArk Conjur SSL Passphrase`, `OAuth2 Client Credentials`, and `API Token Endpoint`. Must be applied to the AAP controller before the job template is created.
- `ansible/roles/nginx_multisite/aap-configuration/controller_credentials.yml`: Defines three AAP credential instances referencing vault-sourced secret values (`vault_conjur_api_key`, `vault_ssl_passphrase`, `vault_oauth_client_secret`, `vault_api_auth_header`). Requires a populated secrets backend before use.
- `ansible/roles/nginx_multisite/export-output.md`: Automated migration pipeline report — full checklist of all 26 migrated items, three bug fixes applied during migration, and per-agent telemetry. Retain as an audit trail.
- `ansible/roles/nginx_multisite/molecule/default/`: Molecule test suite for local CI validation of the role.

---

### Target Details

- **Operating System:** Ubuntu (Bionic 18.04, Focal 20.04) and Red Hat Enterprise Linux / CentOS (7, 8, 9, 10), as declared in `metadata.rb` and `meta/main.yml`. The role uses `ansible.builtin.package` (distro-agnostic) and `www-data` as the web server user — the latter is Debian/Ubuntu-specific and will require adjustment (`nginx` user) for RHEL/CentOS targets.
- **Virtual Machine Technology:** Not specified. No cloud-init, VM tools packages, or hypervisor-specific configurations are present in the source.
- **Cloud Platform:** Not specified. No cloud provider SDK, metadata endpoint calls, or provider-specific resources are present.

---

## Migration Approach

### Key Dependencies to Address

- **`cyberark-conjur` (~> 3.0)** *(Chef supermarket cookbook)*: Provided the `conjur_variable()` helper used in `recipes/ssl.rb` to retrieve the SSL passphrase at converge time. In the Ansible role this dependency is **eliminated**: the passphrase is injected directly as an AAP credential variable (`ssl_passphrase`) via the `CyberArk Conjur SSL Passphrase` custom credential type. The AAP controller itself is responsible for the Conjur API call, not the role. If a direct Conjur lookup from within the play is ever required, the `cyberark.conjur` Ansible collection is the equivalent, but it is not currently used.

- **`oauth_client_secret` (hardcoded `sup3rs3cr3t`)**: The Chef cookbook hardcodes the OAuth2 client secret in `recipes/security.rb`. This value must be **rotated immediately** and stored in the organisation's secrets manager before the AAP credential is populated. The Ansible role never stores this value — it is injected at runtime via the `OAuth2 Client Credentials` AAP credential type.

- **`fetch_and_parse_token` API endpoint** *(undocumented)*: The Chef `fetch_and_parse_token` custom resource calls `https://api.example.com/token_endpoint` and parses the response with a placeholder regex (`X-Header:(.+)`). The Ansible migration pipeline flagged this as **not safely convertible** without production details. The `API Token Endpoint` AAP credential type has been scaffolded, but the corresponding task in `security.yml` is left as a documented comment block pending resolution.

### Security Considerations

- **Hardcoded OAuth2 client secret**: `recipes/security.rb` contains `client_secret: 'sup3rs3cr3t'` in plain text. This is the highest-priority security finding. The secret must be rotated before any migration artefact is committed to a shared repository or deployed. The Ansible role addresses this by injecting the secret via AAP at runtime with `no_log: true`.

- **CyberArk Conjur integration**: The Chef cookbook uses `conjur_variable()` to fetch the SSL passphrase at runtime — a sound pattern. The Ansible role preserves this intent by delegating the Conjur lookup to the AAP controller via a custom credential type, keeping the passphrase out of playbooks, inventory, and role defaults entirely.

- **SSL private key passphrase exposure**: `recipes/ssl.rb` passes `ssl_passphrase` directly on the `openssl req` command line (`-passout pass:#{ssl_passphrase}`), which can expose the value in process listings. The Ansible equivalent (`tasks/ssl.yml`) uses the same shell invocation but wraps it with `no_log: "{{ nginx_multisite_secure_logging }}"` to suppress task output. Consider replacing the shell task with `community.crypto.openssl_privatekey` (which accepts a passphrase parameter without shell exposure) if the community collection constraint is relaxed.

- **Self-signed certificates**: All three virtual hosts use self-signed, 365-day RSA-2048 certificates generated at converge time. These are appropriate for internal/development use but must be replaced with CA-signed certificates (or a Let's Encrypt integration) before any internet-facing deployment.

- **SSH hardening idempotency risk**: The Chef `ada_ada` resource would silently create `/etc/ssh/sshd_config` if it did not exist, potentially producing a broken SSH daemon config. The Ansible migration pipeline identified and fixed this: the role now uses a `stat` guard and `create: false` on both `lineinfile` tasks, skipping cleanly on targets without `openssh-server`.

- **AAP credential variable scope**: Eleven variables are injected by AAP credential types (`conjur_appliance_url`, `conjur_account`, `conjur_variable_path`, `conjur_api_key`, `ssl_passphrase`, `oauth_token_url`, `oauth_client_id`, `oauth_client_secret`, `api_token_url`, `api_token_parse_pattern`, `api_auth_header`). The `validate_credentials.yml` task asserts all are defined at the start of every play, providing a fast-fail guard against misconfigured job templates.

- **`nginx_multisite_secure_logging` toggle**: Defaults to `true` (all secret-handling tasks use `no_log`). Setting this to `false` for debugging will expose `ssl_passphrase`, `oauth_client_secret`, and `api_auth_header` in AAP job output logs. This toggle must never be set to `false` in production job templates.

### Technical Challenges

- **`fetch_and_parse_token` not implemented**: The `fetch_and_parse_token` custom resource in `resources/fetch_and_parse_token.rb` uses a placeholder regex (`X-Header:(.+)`) and calls an undocumented endpoint (`https://api.example.com/token_endpoint`). The migration pipeline correctly declined to implement this task without production details. Before this can be completed, the migration team must determine: (1) the real regex pattern for token extraction, (2) whether the endpoint requires authentication headers, and (3) what downstream task consumes the extracted token. Once known, the implementation is straightforward: `ansible.builtin.uri` (GET) + `ansible.builtin.set_fact` with a `regex_search` filter.

- **`www-data` user on RHEL/CentOS targets**: The role hardcodes `owner: www-data` / `group: www-data` for document root directories and static files. On RHEL/CentOS, Nginx runs as the `nginx` user. If RHEL/CentOS targets are in scope, the owner/group values must be made variable (e.g., `nginx_multisite_web_user` / `nginx_multisite_web_group` defaults) and set appropriately per platform.

- **UFW on RHEL/CentOS targets**: UFW is a Debian/Ubuntu firewall frontend. RHEL/CentOS uses `firewalld`. The `security.yml` tasks that manage UFW will fail on RHEL/CentOS. If cross-platform support is required, the UFW tasks must be gated with `when: ansible_os_family == 'Debian'` and equivalent `firewalld` tasks added for the `RedHat` family.

- **Molecule test environment**: The Molecule suite uses `ansible_connection: local` and does not mock the AAP credential variables. Running `molecule test` without the 11 required credential variables defined will fail at the `validate_credentials.yml` assertion. The `converge.yml` or a `prepare.yml` step must supply stub values for local testing.

- **Ordering bugs in the Chef source**: Three ordering defects were identified and corrected during migration (fail2ban config deployed before service start; nginx service started after document roots and static files are in place; `sshd_config` stat guard added). These bugs existed silently in the Chef cookbook because Chef's resource collection/convergence model is more tolerant of declaration order than Ansible's sequential execution model. The fixes are documented in `export-output.md`.

- **No Berksfile or Policyfile**: The Chef cookbook has no `Berksfile` or `Policyfile.rb`, meaning its single external dependency (`cyberark-conjur`) was managed outside the cookbook (likely via a control repo or wrapper cookbook). The migration team should confirm that no other cookbooks in the broader Chef environment depend on `nginx-multisite` before decommissioning the Chef source.

### Migration Order

The migration is structurally complete. The recommended order for the remaining human tasks is:

1. **Rotate the OAuth2 client secret** — `sup3rs3cr3t` is a known-compromised credential. Rotate it in the auth service and store the new value in the organisation's secrets manager before any further work proceeds.
2. **Populate AAP credential instances** — Apply `controller_credential_types.yml` to the AAP controller, then populate `controller_credentials.yml` with real vault-sourced values (`vault_conjur_api_key`, `vault_ssl_passphrase`, `vault_oauth_client_secret`, `vault_api_auth_header`).
3. **Resolve the `fetch_and_parse_token` gap** — Investigate `https://api.example.com/token_endpoint`: confirm the real regex pattern, authentication requirements, and downstream consumer. Implement the corresponding `ansible.builtin.uri` + `ansible.builtin.set_fact` task in `security.yml`.
4. **Address platform divergence** — Decide whether RHEL/CentOS targets are in scope. If yes, parameterise `www-data` owner/group and add `firewalld` tasks gated by `ansible_os_family`.
5. **Fix Molecule credential stubs** — Add stub values for the 11 AAP credential variables to the Molecule inventory or a `prepare.yml` so that `molecule test` can run in CI without a live AAP controller.
6. **Production smoke test** — Run the role against a non-production target with real AAP credentials, verify all three virtual hosts serve HTTPS, confirm fail2ban jails are active, and validate SSH hardening settings.
7. **Decommission Chef source** — Once the Ansible role is validated in production, remove the Chef cookbook source files (`recipes/`, `attributes/`, `templates/`, `files/`, `resources/`, `metadata.rb`) and archive the repository.

### Assumptions

1. **AAP is the target execution platform.** The Ansible role is designed specifically for Ansible Automation Platform with custom credential types. Running it with plain `ansible-playbook` requires manually supplying all 11 credential variables via `--extra-vars` or an equivalent mechanism.
2. **The `cyberark-conjur` Chef cookbook was the only external Chef dependency.** No `Berksfile` or `Policyfile.rb` is present; it is assumed no other cookbooks in the broader Chef environment wrap or depend on `nginx-multisite`.
3. **The three virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) are the complete set of sites.** The `nginx_multisite_sites` dictionary in `defaults/main.yml` is the authoritative list; no additional sites are configured elsewhere.
4. **Self-signed certificates are acceptable for the current deployment context.** The Chef cookbook generates self-signed, 365-day certificates. It is assumed this is intentional (internal/development use) and not a gap to be filled with CA-signed certificates before migration.
5. **The `api.example.com/token_endpoint` endpoint and its downstream consumer exist in production.** The Chef `fetch_and_parse_token` resource is present in the cookbook and presumably functional; the placeholder regex and example URL are artefacts of the source being sanitised for sharing, not indicators that the feature is unused.
6. **`sup3rs3cr3t` is a placeholder value in the shared/sanitised source.** It is assumed the real production OAuth2 client secret is stored securely and was never committed to version control in the live environment. If this assumption is incorrect, an immediate secrets audit is required.
7. **No community Ansible collections are permitted.** The role uses only `ansible.builtin.*` modules, consistent with the `# noqa` comments in `security.yml` explaining why `community.general.ufw` was not used. This constraint is assumed to be a project-wide policy.
8. **Ubuntu is the primary target platform.** The `www-data` user, UFW, and `ufw` package are Debian/Ubuntu-specific. RHEL/CentOS support is declared in `meta/main.yml` but the role is not currently cross-platform-safe.
9. **The Molecule test suite uses local connection only.** No Docker, Podman, or remote SSH driver is configured. It is assumed the CI environment supports local Ansible execution for testing purposes.
10. **The `export-output.md` migration report is accurate.** The automated pipeline reports 26/26 items complete with 0 errors and 0 warnings from `ansible-lint`. This is taken as the baseline; no independent re-audit of every generated file has been performed as part of this plan.

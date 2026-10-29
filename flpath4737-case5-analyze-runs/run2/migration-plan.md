# MIGRATION FROM CHEF TO ANSIBLE

## Executive Summary

This repository contains a single Chef cookbook (`nginx-multisite` v1.0.0) that configures Nginx as a multi-site SSL-enabled web server with host hardening. The migration to Ansible is **already complete**: a fully validated Ansible role (`ansible/roles/nginx_multisite`) exists alongside the original Chef source, produced by an automated migration pipeline. The migration export report confirms 26/26 items completed with zero errors, zero warnings, and zero lint violations.

This document serves as the authoritative record of what was migrated, how credentials were re-architected, what known gaps remain, and what steps are required before the Ansible role can be promoted to production.

**Scope**: 1 Chef cookbook → 1 Ansible role  
**Complexity**: Medium (custom Chef resources, CyberArk Conjur secrets integration, OAuth token fetching, one partially-convertible custom resource)  
**Estimated remaining effort to production-ready**: 3–5 days (credential rotation, API token endpoint clarification, pipeline cutover)

---

## Module Migration Plan

This repository contains one Chef cookbook that maps to one Ansible role:

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
All paths below were confirmed from the provided repository tree and file reads. No paths have been inferred or invented.

- **nginx-multisite**:
  - Description: Nginx multi-site web server with SSL termination, host hardening, and secrets integration. Installs and configures Nginx to serve three SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`), generates self-signed TLS certificates per vhost using a passphrase retrieved from CyberArk Conjur, hardens the host with fail2ban, UFW firewall (deny-by-default, allow 22/80/443), sysctl kernel parameters, and SSH daemon hardening (no root login, no password auth). Also fetches an OAuth2 bearer token and a secondary API token at runtime.
  - Path (Chef source): `/` (cookbook root — `metadata.rb`, `recipes/`, `attributes/`, `templates/`, `files/`, `resources/`)
  - Path (Ansible output): `ansible/roles/nginx_multisite/`
  - Technology: Chef → Ansible
  - Key Features:
    - Nginx installation, global `nginx.conf`, security snippet (`conf.d/security.conf`), per-site virtual host configs in `sites-available/` with symlinks to `sites-enabled/`
    - Self-signed TLS certificate generation via `openssl req` per vhost; passphrase sourced from CyberArk Conjur (`production/nginx/ssl_passphrase`)
    - fail2ban with custom `jail.local`; UFW firewall via shell commands (no community collection used)
    - sysctl kernel hardening via `/etc/sysctl.d/99-security.conf`
    - SSH hardening: `PermitRootLogin no`, `PasswordAuthentication no` via `lineinfile`
    - OAuth2 client-credentials token fetch (`ansible.builtin.uri` POST)
    - Secondary API token fetch via regex parse — **partially converted** (see Technical Challenges)
    - Three custom Chef resources (`ada_ada`, `fetch_token`, `fetch_and_parse_token`) — all addressed in migration
    - Static `index.html` files deployed to each vhost document root
    - AAP credential types and credential objects defined in `aap-configuration/`
    - Molecule test suite (converge, verify, create, destroy) with local connection driver

---

### Infrastructure Files

- `metadata.rb`: Chef cookbook metadata (name, version, `chef_version >= 16.0`, OS support for Ubuntu ≥ 18.04 and CentOS ≥ 7.0, dependency on `cyberark-conjur ~> 3.0`). Migrated to `ansible/roles/nginx_multisite/meta/main.yml`.
- `attributes/default.rb`: Chef node attributes defining site dictionary, SSL paths, Conjur connection parameters, and security flags. Migrated to `ansible/roles/nginx_multisite/defaults/main.yml` with AAP credential variable references replacing hardcoded Conjur values.
- `recipes/default.rb`: Cookbook entry point — orchestrates `security → nginx → ssl → sites` recipe inclusion order. Migrated to `ansible/roles/nginx_multisite/tasks/main.yml` with `validate_credentials.yml` prepended.
- `recipes/nginx.rb`: Nginx package, global config template, security snippet, document root directories, static file deployment, service management. Migrated to `tasks/nginx.yml` (ordering bug fixed: service start moved after content deployment).
- `recipes/security.rb`: fail2ban, UFW, OAuth token fetch, sysctl hardening, SSH config edits. Migrated to `tasks/security.yml` (ordering bug fixed: fail2ban config deployed before service start; stat guard added for `sshd_config`).
- `recipes/ssl.rb`: openssl/ca-certificates install, ssl-cert group, cert/key directory creation, per-site self-signed certificate generation with Conjur-sourced passphrase. Migrated to `tasks/ssl.yml`.
- `recipes/sites.rb`: Per-site virtual host config templates, `sites-enabled` symlinks, default site removal. Migrated to `tasks/sites.yml`.
- `resources/ada_ada.rb`: Custom Chef resource for idempotent line-in-file editing with regex match and backup. Replaced by `ansible.builtin.lineinfile` in `tasks/security.yml`.
- `resources/fetch_token.rb`: Custom Chef resource performing an OAuth2 client-credentials POST and storing the access token in `node.run_state`. Replaced by `ansible.builtin.uri` + `ansible.builtin.set_fact` in `tasks/security.yml`.
- `resources/fetch_and_parse_token.rb`: Custom Chef resource performing a GET to an API endpoint and extracting a token via regex from the response body. **Partially converted** — see Technical Challenges.
- `templates/default/*.erb`: Five ERB templates (nginx.conf, security.conf, site.conf, fail2ban.jail.local, sysctl-security.conf). All migrated to Jinja2 (`.j2`) equivalents in `ansible/roles/nginx_multisite/templates/`. `site.conf.erb` had active ERB variables; the remaining four were static and copied as-is.
- `files/default/{ci,status,test}/index.html`: Static HTML files for each vhost. Copied to `ansible/roles/nginx_multisite/files/{ci,status,test}/index.html`.
- `ansible/roles/nginx_multisite/aap-configuration/controller_credential_types.yml`: Defines three AAP custom credential types: *CyberArk Conjur SSL Passphrase*, *OAuth2 Client Credentials*, *API Token Endpoint*. Must be applied to the AAP controller before the job template is run.
- `ansible/roles/nginx_multisite/aap-configuration/controller_credentials.yml`: Defines three AAP credential objects referencing vault-sourced secrets (`vault_conjur_api_key`, `vault_ssl_passphrase`, `vault_oauth_client_secret`, `vault_api_auth_header`). Requires a populated secrets backend before use.
- `ansible/roles/nginx_multisite/meta/argument_specs.yml`: Full argument specification for all role variables including all AAP-injected credential variables with types and descriptions.
- `ansible/roles/nginx_multisite/molecule/default/`: Complete Molecule test suite — `molecule.yml` (local driver), `converge.yml`, `verify.yml` (4-play verification covering nginx configs, SSL certs, security configs, service state and port checks), `create.yml`, `destroy.yml`.
- `ansible/roles/nginx_multisite/export-output.md`: Automated migration report — 26/26 items complete, 0 errors, 0 warnings, 0 lint violations, documents three bugs found and fixed during review.

---

### Target Details

- **Operating System**: Ubuntu (Bionic/Focal) and RHEL/CentOS-family (7, 8, 9, 10). The Chef cookbook explicitly supports `ubuntu >= 18.04` and `centos >= 7.0`. The Ansible role `meta/main.yml` reflects the same platform matrix. UFW and `www-data` ownership are Ubuntu-centric; CentOS/RHEL targets may require `firewalld` substitution and `nginx` user ownership adjustments.
- **Virtual Machine Technology**: Not specified in the source. Molecule uses a local connection driver (no VM provisioner). No cloud-init, VMware tools, or hypervisor-specific packages are referenced.
- **Cloud Platform**: Not specified. No cloud provider SDK, metadata endpoint, or cloud-specific configuration is present. The Conjur appliance URL (`https://conjur.example.com`) and OAuth endpoint (`https://auth.example.com`) are generic hostnames.

---

## Migration Approach

### Key Dependencies to Address

- **cyberark-conjur (~> 3.0)** *(Chef cookbook dependency)*: The Chef cookbook used the `conjur_variable()` helper from the `cyberark-conjur` cookbook to fetch the SSL passphrase at converge time. In the Ansible role this dependency is **eliminated**: the passphrase is now injected directly as an AAP credential variable (`ssl_passphrase`) via the *CyberArk Conjur SSL Passphrase* custom credential type. The Conjur connection parameters (`conjur_appliance_url`, `conjur_account`, `conjur_variable_path`, `conjur_api_key`) are also injected as extra vars for any downstream Conjur lookup tasks. No `cyberark.conjur` Ansible collection is required.
- **community.general (ufw module)**: The Ansible role deliberately avoids the `community.general.ufw` module (noted with `# noqa: L007` comments) and uses `ansible.builtin.shell` with `changed_when` guards instead. If the team's AAP environment permits community collections in the future, replacing the five UFW shell tasks with `community.general.ufw` tasks would improve idempotency and readability.
- **ansible.builtin only**: The role is constrained to `ansible.builtin` modules throughout (min Ansible version 2.14.0). No Galaxy roles or community collections are declared as dependencies in `meta/main.yml`.

### Security Considerations

- **Hardcoded OAuth client secret** *(CRITICAL — must be rotated before production)*: `recipes/security.rb` contains `client_secret: 'sup3rs3cr3t'` in plain text. This secret is documented in the AAP credential type description as requiring rotation. The Ansible role removes the hardcoded value and injects `oauth_client_secret` at runtime via the *OAuth2 Client Credentials* AAP credential type. **The original secret value must be considered compromised and rotated immediately.**
- **CyberArk Conjur integration**: The Chef cookbook fetched `production/nginx/ssl_passphrase` via `conjur_variable()` at converge time. The Ansible role replaces this with an AAP-injected `ssl_passphrase` credential variable. The Conjur API key (`conjur_api_key`) is marked `secret: true` in the credential type and injected as an extra var — it must never appear in playbooks or inventory.
- **SSL passphrase exposure**: The `ssl_passphrase` is passed directly to `openssl req -passout pass:{{ ssl_passphrase }}` in a shell command. The task carries `no_log: "{{ nginx_multisite_secure_logging }}"` (default `true`) to suppress output. The `nginx_multisite_secure_logging` toggle must remain `true` in all production job templates.
- **API authentication header** (`api_auth_header`): Marked `secret: true` in the AAP credential type. The downstream endpoint (`https://api.example.com/token_endpoint`) and whether this header is actually required are unknown — see Technical Challenges.
- **Self-signed certificates**: All three vhosts use self-signed certificates generated at role runtime. These are appropriate for internal/development clusters but must be replaced with CA-signed certificates (e.g., via Let's Encrypt or an internal PKI) before any public-facing deployment.
- **SSH hardening**: `PermitRootLogin no` and `PasswordAuthentication no` are enforced via `lineinfile`. A `stat` guard ensures the tasks skip cleanly on targets without `openssh-server`. Teams must ensure key-based SSH access is provisioned before applying this role to avoid lockout.
- **UFW firewall**: Default-deny with explicit allow for 22, 80, 443. Shell-based implementation means idempotency relies on stdout string matching — verify `changed_when` conditions against the UFW version on target hosts.
- **Vault/secrets summary by credential**:
  - `ssl_passphrase` — sourced from CyberArk Conjur (`production/nginx/ssl_passphrase`); injected via AAP credential
  - `oauth_client_secret` — previously hardcoded as `'sup3rs3cr3t'`; must be rotated and stored in secrets manager
  - `conjur_api_key` — Conjur host factory token; injected via AAP credential
  - `api_auth_header` — unknown; possibly required by `https://api.example.com/token_endpoint`; injected via AAP credential

### Technical Challenges

- **Partially-converted `fetch_and_parse_token` resource**: The Chef `fetch_and_parse_token` custom resource GETs `https://api.example.com/token_endpoint` and extracts a value via the regex `X-Header:(.+)`. The Ansible `tasks/security.yml` contains a detailed developer note explaining that this task is **not safely convertible** without three pieces of information: (1) the real production regex pattern (the Chef source uses a placeholder `pattern1`), (2) whether the endpoint requires authentication headers, and (3) what downstream task consumes the extracted token. The AAP credential type for this endpoint is defined and the `api_token_url`, `api_token_parse_pattern`, and `api_auth_header` variables are injected — but the actual implementation task is intentionally left as a comment block pending clarification from the owning team.
- **Ubuntu vs. RHEL firewall divergence**: UFW is Ubuntu-specific. The role's shell-based UFW tasks will fail on CentOS/RHEL targets where `firewalld` is the default. If RHEL targets are in scope, conditional firewall management (UFW on Debian-family, firewalld on RHEL-family) must be added.
- **`www-data` user/group**: The Nginx document root ownership uses `www-data`, which is the Debian/Ubuntu default. On RHEL/CentOS, Nginx runs as `nginx`. The role does not currently handle this divergence — a `vars/` file per OS family or `ansible_facts['os_family']` conditionals would be needed.
- **Self-signed certificate idempotency**: Certificate regeneration is gated on `args: creates:` (the `.crt` file path). If a certificate expires or needs to be regenerated, the existing file must be manually removed first. Consider adding an expiry check task or a `force_regenerate` variable for operational flexibility.
- **Molecule test environment**: The Molecule suite uses `ansible_connection: local` with no Docker or VM driver. This means tests run against the controller itself. A containerised driver (e.g., `community.docker.docker`) should be adopted for isolated CI testing before the role is published to Galaxy or an internal hub.
- **`changed_when` accuracy for UFW shell tasks**: The `changed_when` conditions match specific stdout strings from UFW. These strings may differ across UFW versions or locales. Validate against the exact UFW version present on target Ubuntu images.
- **Backup files accumulating**: Both `ada_ada.rb` (now replaced by `lineinfile`) and several Ansible template/copy tasks use `backup: true`. On long-lived hosts this will accumulate timestamped backup files in `/etc/nginx/`, `/etc/fail2ban/`, `/etc/sysctl.d/`, and `/etc/ssh/`. A periodic cleanup task or backup rotation policy should be considered.

### Migration Order

The cookbook is a single unit with no inter-cookbook dependencies (the only external Chef dependency, `cyberark-conjur`, has been eliminated in the Ansible role). The migration order below reflects the remaining operational steps to promote the Ansible role to production:

1. **Credential rotation and secrets population** *(blocker)*: Rotate the hardcoded `oauth_client_secret` (`sup3rs3cr3t`). Populate the secrets backend referenced by `controller_credentials.yml` (`vault_conjur_api_key`, `vault_ssl_passphrase`, `vault_oauth_client_secret`, `vault_api_auth_header`). Apply `controller_credential_types.yml` and `controller_credentials.yml` to the AAP controller.
2. **API token endpoint clarification** *(blocker for full feature parity)*: Engage the owning team to determine the real regex pattern, authentication requirements, and downstream consumer for `fetch_and_parse_token`. Implement the corresponding `ansible.builtin.uri` + `ansible.builtin.set_fact` task in `tasks/security.yml` once confirmed.
3. **OS-family conditional handling** *(required if RHEL targets are in scope)*: Add `vars/RedHat.yml` / `vars/Debian.yml` to handle `www-data` vs. `nginx` user and UFW vs. firewalld divergence. Gate firewall tasks on `ansible_facts['os_family']`.
4. **Molecule CI integration**: Replace the local-connection Molecule driver with a containerised driver. Integrate the Molecule suite into the CI pipeline (GitHub Actions, GitLab CI, or AAP EE build pipeline) to gate merges on passing tests.
5. **Production job template creation and dry-run**: Create the AAP job template, attach all three credential objects, run in `--check` mode against a staging host, verify no unexpected changes.
6. **Chef cookbook decommission**: Once the Ansible role has been validated in production for one full change cycle, remove the Chef cookbook source files and update the repository README to reflect the Ansible-only state.

### Assumptions

1. **AAP (Ansible Automation Platform) is the target execution environment.** The role's credential injection model (`validate_credentials.yml`, `aap-configuration/`) is designed specifically for AAP job templates. Running the role with plain `ansible-playbook` requires manually supplying all credential variables via `--extra-vars` or a vault file.
2. **The Conjur appliance at `https://conjur.example.com` is reachable from AAP execution nodes.** The Conjur connection parameters are injected as extra vars but no Conjur lookup task is present in the role — the `ssl_passphrase` is assumed to be pre-fetched and injected by the AAP credential type at job launch time.
3. **The OAuth endpoint (`https://auth.example.com/oauth/token`) is reachable from target hosts at converge time.** The `ansible.builtin.uri` task runs on the target, not the controller.
4. **The three virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) are internal cluster DNS names.** No public DNS or external certificate authority is assumed.
5. **Self-signed certificates are acceptable for the current deployment context.** The migration preserves the self-signed certificate generation behaviour from the Chef cookbook. If CA-signed certificates are required, the `tasks/ssl.yml` file must be extended.
6. **The `api_token_parse_pattern` placeholder (`pattern1:(.+)`) in the Chef source is not the real production pattern.** The real pattern is unknown and must be confirmed before the `fetch_and_parse_token` equivalent task can be implemented.
7. **The downstream consumer of the `fetch_and_parse_token` extracted token is not present in this repository.** It may exist in another cookbook, a wrapper recipe, or an external system. This must be investigated before the migration can be considered fully feature-complete.
8. **`www-data` is the correct Nginx process user on all target hosts.** If RHEL/CentOS targets are included, this assumption breaks and OS-family conditionals are needed.
9. **The `openssh-server` package is pre-installed on all target hosts.** The `stat` guard in `tasks/security.yml` prevents failures on hosts without it, but SSH hardening will silently skip on such hosts — this may be unexpected behaviour in a security-hardening context.
10. **No Berksfile or Policyfile is present in the repository.** The cookbook has a single external dependency (`cyberark-conjur`) declared only in `metadata.rb`. It is assumed the Chef environment used Berkshelf or a similar resolver, but no lockfile is available to confirm the resolved version.
11. **The migration pipeline's automated validation (ansible-lint, ansible-role-check) is considered sufficient for structural correctness.** Functional validation against live infrastructure has not yet been performed and is the responsibility of the migration team.

# MIGRATION FROM CHEF TO ANSIBLE

## Executive Summary

This repository contains a single Chef cookbook (`nginx-multisite` v1.0.0) that configures Nginx as a multi-site SSL-enabled web server with host hardening. The migration to Ansible is **already complete**: a fully validated Ansible role (`ansible/roles/nginx_multisite`) exists alongside the original Chef source, produced by an automated migration pipeline. The migration plan below documents the source cookbook, the resulting Ansible role, all decisions made during migration, and the outstanding items that require human action before the role can be deployed to production.

**Scope**: 1 Chef cookbook → 1 Ansible role  
**Complexity**: Medium — the cookbook is self-contained but introduces three distinct credential/secrets integrations (CyberArk Conjur, OAuth2 client credentials, and an undocumented API token endpoint), one of which contains a hardcoded secret and one of which has an unknown production regex pattern.  
**Timeline estimate**: 1–2 sprints for credential remediation and production validation; the code migration itself is complete.

---

## Module Migration Plan

This repository contains one Chef cookbook that has been migrated to one Ansible role.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
All paths below were confirmed from the provided repository tree and file reads.

---

- **nginx-multisite**:
  - Description: Nginx multi-site web server with SSL termination, host hardening, and runtime secrets retrieval. Installs and configures Nginx to serve three SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`), generates self-signed TLS certificates per vhost using a passphrase retrieved from CyberArk Conjur, hardens the host with fail2ban, UFW firewall (deny-by-default, allow 22/80/443), sysctl kernel parameters, and SSH daemon hardening (no root login, no password auth). Also fetches an OAuth2 bearer token and a second token from an undocumented API endpoint at runtime.
  - Path (Chef source): `/` (cookbook root — `metadata.rb`, `recipes/`, `attributes/`, `templates/`, `files/`, `resources/`)
  - Path (Ansible output): `ansible/roles/nginx_multisite/`
  - Technology: Chef → Ansible
  - Key Features:
    - Nginx installation, global `nginx.conf`, per-vhost `site.conf` with SSL, security snippet `security.conf`
    - Self-signed TLS certificate generation via `openssl req` per vhost; passphrase sourced from CyberArk Conjur (`production/nginx/ssl_passphrase`)
    - fail2ban with custom `jail.local`; UFW firewall via shell commands; sysctl kernel hardening via `/etc/sysctl.d/99-security.conf`
    - SSH hardening: `PermitRootLogin no`, `PasswordAuthentication no` via `lineinfile`
    - OAuth2 client-credentials token fetch (`ansible.builtin.uri` POST)
    - Custom Chef resources (`ada_ada`, `fetch_token`, `fetch_and_parse_token`) converted to native Ansible modules
    - Three static `index.html` files deployed to each vhost document root
    - Molecule test suite (create / converge / verify / destroy) with local connection driver
    - AAP credential types and credential objects defined in `aap-configuration/`

---

### Infrastructure Files

- `metadata.rb`: Chef cookbook metadata — name `nginx-multisite`, version `1.0.0`, supports Ubuntu ≥ 18.04 and CentOS ≥ 7, declares single external dependency `cyberark-conjur ~> 3.0`. Migrated to `ansible/roles/nginx_multisite/meta/main.yml`.
- `attributes/default.rb`: Chef node attributes defining the three vhost configurations, SSL certificate paths, CyberArk Conjur connection parameters, and security feature toggles. Migrated to `ansible/roles/nginx_multisite/defaults/main.yml`; Conjur/OAuth/API credential values replaced with AAP-injected variables.
- `recipes/default.rb`: Cookbook entry point — orchestrates `security → nginx → ssl → sites` recipe execution order. Migrated to `ansible/roles/nginx_multisite/tasks/main.yml` with an additional `validate_credentials.yml` step prepended.
- `recipes/nginx.rb`: Nginx package install, global config template, security snippet template, document root directory creation, static file deployment, service enable/start. Migrated to `tasks/nginx.yml`; task ordering fixed (service start moved after content deployment).
- `recipes/security.rb`: fail2ban + UFW package install, fail2ban config template, UFW shell commands, OAuth token fetch (`fetch_token` resource), API token fetch (`fetch_and_parse_token` resource), sysctl template, SSH hardening via `ada_ada` resource. Migrated to `tasks/security.yml`; ordering fixed (fail2ban config before service start); `sshd_config` stat guard added.
- `recipes/ssl.rb`: openssl + ca-certificates install, `ssl-cert` group, certificate/key directory creation, per-vhost self-signed cert generation with Conjur-sourced passphrase. Migrated to `tasks/ssl.yml`.
- `recipes/sites.rb`: Per-vhost `site.conf` template deployment, `sites-enabled` symlink creation, default site removal. Migrated to `tasks/sites.yml`.
- `resources/ada_ada.rb`: Custom Chef resource for idempotent line-in-file editing with regex match and backup. Replaced by `ansible.builtin.lineinfile` in `tasks/security.yml`.
- `resources/fetch_token.rb`: Custom Chef resource performing an OAuth2 client-credentials POST and storing the access token in `node.run_state`. Replaced by `ansible.builtin.uri` + `ansible.builtin.set_fact` in `tasks/security.yml`.
- `resources/fetch_and_parse_token.rb`: Custom Chef resource performing a GET to an undocumented API endpoint and extracting a token via regex from the response body. **Not fully converted** — see Technical Challenges below.
- `templates/default/*.erb`: Five ERB templates (nginx.conf, security.conf, site.conf, fail2ban.jail.local, sysctl-security.conf). Migrated to `ansible/roles/nginx_multisite/templates/*.j2`; `site.conf.erb` had ERB variables converted to Jinja2; the remaining four were static and copied as-is.
- `files/default/{ci,status,test}/index.html`: Static HTML placeholder files for each vhost. Copied to `ansible/roles/nginx_multisite/files/{ci,status,test}/index.html`.
- `ansible/roles/nginx_multisite/aap-configuration/controller_credential_types.yml`: Defines three AAP custom credential types: *CyberArk Conjur SSL Passphrase*, *OAuth2 Client Credentials*, *API Token Endpoint*. Must be applied to the AAP controller before the job template is executed.
- `ansible/roles/nginx_multisite/aap-configuration/controller_credentials.yml`: Defines three AAP credential objects referencing the custom types above. Vault variable references (`vault_conjur_api_key`, `vault_ssl_passphrase`, `vault_oauth_client_secret`, `vault_api_auth_header`) must be resolved against the organisation's secrets store before import.
- `ansible/roles/nginx_multisite/meta/argument_specs.yml`: Full argument specification for the role covering all defaults and all AAP-injected credential variables with types and descriptions.
- `ansible/roles/nginx_multisite/molecule/default/`: Complete Molecule test suite — `molecule.yml` (local driver), `create.yml`, `converge.yml`, `destroy.yml`, `verify.yml` (four verification plays covering nginx config, static content, SSL certs, fail2ban/sysctl/sshd, service facts, and port 80/443 checks).
- `ansible/roles/nginx_multisite/export-output.md`: Automated migration pipeline report — 26/26 items completed, 0 lint violations, 0 errors; includes the ReviewAgent findings and fixes applied post-generation.

---

### Target Details

- **Operating System**: Ubuntu (Bionic 18.04, Focal 20.04) and Red Hat Enterprise Linux / CentOS (7, 8, 9, 10), as declared in `metadata.rb` and `meta/main.yml`. UFW and `www-data` user references indicate the primary target is Debian/Ubuntu; CentOS/RHEL support is declared but UFW is not native to RHEL (see Technical Challenges).
- **Virtual Machine Technology**: Not specified in the repository. Molecule uses a local connection driver, suggesting development/CI runs on the controller itself.
- **Cloud Platform**: Not specified. No cloud-provider SDK, metadata endpoint, or cloud-init configuration is present.

---

## Migration Approach

### Key Dependencies to Address

- **cyberark-conjur (~> 3.0)** *(Chef cookbook)*: The Chef `conjur_variable()` helper function (used in `recipes/ssl.rb` to fetch the SSL passphrase at converge time) has been replaced in the Ansible role by an AAP custom credential type (*CyberArk Conjur SSL Passphrase*) that injects `ssl_passphrase` as an extra variable at job-template execution time. The Conjur connection parameters (`conjur_appliance_url`, `conjur_account`, `conjur_variable_path`, `conjur_api_key`) are also injected via the same credential type. **Action required**: populate the AAP credential object with real Conjur values before first production run.

- **fetch_token / OAuth2 client credentials**: The `fetch_token` custom Chef resource (hardcoded `client_secret: 'sup3rs3cr3t'` in `recipes/security.rb`) is replaced by `ansible.builtin.uri` in `tasks/security.yml`. The secret is now injected via the *OAuth2 Client Credentials* AAP credential type. **Action required**: rotate the `sup3rs3cr3t` value immediately and store the real secret in the organisation's vault before importing the AAP credential object.

- **fetch_and_parse_token / API token endpoint**: The `fetch_and_parse_token` custom Chef resource is **not fully converted**. The regex pattern in the source (`X-Header:(.+)`) is a placeholder stub; the real production pattern, whether the endpoint requires authentication headers, and what downstream task consumes the extracted token are all unknown. A developer note in `tasks/security.yml` documents this gap. **Action required**: determine the real regex pattern, authentication requirements, and downstream consumer before implementing the corresponding Ansible task.

---

### Security Considerations

- **Hardcoded OAuth2 client secret**: `recipes/security.rb` contains `client_secret: 'sup3rs3cr3t'` in plain text. This credential is in version control history and must be rotated before the Ansible role is deployed. The Ansible role correctly externalises this to an AAP credential type, but the rotation must happen first.

- **CyberArk Conjur integration**: The Chef cookbook fetches the SSL passphrase from Conjur at converge time using the `cyberark-conjur` cookbook helper. The Ansible role replaces this with AAP credential injection — the passphrase is never written to disk by Ansible and all tasks that handle it carry `no_log: "{{ nginx_multisite_secure_logging }}"`. The `conjur_api_key` is marked `secret: true` in the AAP credential type definition.

- **SSL passphrase exposure**: In `recipes/ssl.rb` the passphrase is interpolated directly into a shell command (`-passout pass:#{ssl_passphrase}`). The Chef resource carries `sensitive true`. The Ansible equivalent uses `no_log` on the shell task. Both approaches prevent the passphrase from appearing in logs, but the value is still transiently visible in the process list. This is an inherent limitation of the `openssl req -passout pass:` interface.

- **Self-signed certificates**: All three vhosts use self-signed certificates valid for 365 days. These are appropriate for internal/development use but must be replaced with CA-signed certificates (e.g., via Let's Encrypt or an internal PKI) before any public-facing deployment.

- **SSH hardening**: `PermitRootLogin no` and `PasswordAuthentication no` are enforced via `lineinfile`. The Ansible role adds a `stat` guard so that the tasks skip cleanly on hosts without `openssh-server` rather than creating a malformed stub `sshd_config`.

- **UFW firewall**: Managed via `ansible.builtin.shell` with `changed_when` guards. The `community.general.ufw` module is explicitly excluded per the role's lint annotations (`# noqa: L007`). This is intentional but means idempotency relies on stdout string matching rather than a declarative module.

- **Vault/secrets summary by credential**:
  | Credential | Chef source | Ansible destination | Secret fields |
  |---|---|---|---|
  | SSL passphrase | `conjur_variable()` helper | AAP credential type *CyberArk Conjur SSL Passphrase* | `conjur_api_key`, `ssl_passphrase` |
  | OAuth2 client secret | Hardcoded `'sup3rs3cr3t'` in `recipes/security.rb` | AAP credential type *OAuth2 Client Credentials* | `oauth_client_secret` |
  | API auth header | Unknown / not in source | AAP credential type *API Token Endpoint* | `api_auth_header` |

- **`nginx_multisite_secure_logging` toggle**: Defaults to `true` (all secret-handling tasks use `no_log: true`). Setting this to `false` for debugging will expose `ssl_passphrase`, `oauth_client_secret`, and `api_auth_header` in Ansible output — this must never be done in production.

---

### Technical Challenges

1. **Incomplete `fetch_and_parse_token` conversion**: The `fetch_and_parse_token` custom Chef resource uses a placeholder regex (`X-Header:(.+)`) and calls an undocumented endpoint (`https://api.example.com/token_endpoint`). The real production regex pattern, any required authentication headers, and the downstream consumer of the extracted token are all unknown. The Ansible role contains a detailed developer note in `tasks/security.yml` but the task itself is not implemented. **Mitigation**: assign a developer to reverse-engineer the production endpoint before the role is considered complete; the AAP credential type for this integration is already defined and ready to receive the real values.

2. **UFW on RHEL/CentOS targets**: The role declares support for CentOS 7–10 and RHEL 7–10, but UFW is a Debian/Ubuntu tool and is not available in default RHEL package repositories. The `nginx_multisite_ufw_enabled` flag can be set to `false` for RHEL targets, but no firewalld or iptables equivalent is implemented. **Mitigation**: add a separate firewall task file for RHEL targets using `ansible.builtin.firewalld` or `ansible.posix.firewalld`, gated on `ansible_os_family == 'RedHat'`.

3. **`www-data` user on RHEL/CentOS**: Nginx on RHEL runs as `nginx`, not `www-data`. Document root ownership and static file ownership are hardcoded to `www-data` throughout the role. **Mitigation**: parameterise the web server user/group (e.g., `nginx_multisite_web_user`) and set the default conditionally based on `ansible_os_family`.

4. **Self-signed certificate idempotency**: Certificate regeneration is gated on `creates:` (the `.crt` file). If a certificate expires or needs to be rotated, the task will not re-run unless the existing `.crt` file is manually deleted. **Mitigation**: add an optional `openssl_certificate` check task or a `force_regenerate_certs` boolean variable to allow controlled rotation.

5. **AAP credential object vault references**: `controller_credentials.yml` references `vault_conjur_api_key`, `vault_ssl_passphrase`, `vault_oauth_client_secret`, and `vault_api_auth_header` — these are expected to be resolved from an external vault (e.g., HashiCorp Vault, CyberArk) at AAP import time. The mechanism for this resolution is not defined in the repository. **Mitigation**: document the vault path conventions and ensure the AAP import pipeline has the necessary vault lookup plugin configured.

6. **Molecule test environment**: The Molecule suite uses `ansible_connection: local`, meaning tests run on the controller itself. This is suitable for CI but means the test environment does not reflect a real target host (no systemd, no real UFW, etc.). Service-state assertions in `verify.yml` may fail in a minimal CI container. **Mitigation**: consider switching to a Docker or Podman driver with a systemd-capable image for more realistic integration testing.

---

### Migration Order

The cookbook is a single unit; there is no multi-module sequencing required. The remaining work is ordered by risk:

1. **Credential remediation** *(blocker)*: Rotate the hardcoded OAuth2 `client_secret` (`sup3rs3cr3t`), store all secrets in the organisation's vault, and populate the three AAP credential objects. This must be completed before any production deployment.

2. **`fetch_and_parse_token` implementation** *(high priority)*: Identify the real API endpoint behaviour, regex pattern, and downstream consumer; implement the missing Ansible task in `tasks/security.yml` using `ansible.builtin.uri` + `ansible.builtin.set_fact` with `regex_search`, following the pattern already used for the OAuth token fetch.

3. **RHEL/CentOS compatibility** *(medium priority)*: Add firewalld support and parameterise the `www-data` web server user for RHEL targets if those platforms are in scope for production.

4. **AAP controller import** *(medium priority)*: Apply `aap-configuration/controller_credential_types.yml` and `aap-configuration/controller_credentials.yml` to the AAP controller using the `infra.controller_configuration` collection or equivalent pipeline.

5. **Production certificate strategy** *(medium priority)*: Replace self-signed certificate generation with a CA-signed certificate workflow (internal PKI or Let's Encrypt) for any non-development deployment.

6. **Molecule CI hardening** *(low priority)*: Switch the Molecule driver to a systemd-capable container image to enable realistic service-state and port-level verification in CI.

---

### Assumptions

1. The three virtual host names (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) are internal DNS names resolvable on the target network; no external DNS configuration is required.
2. The CyberArk Conjur appliance at `https://conjur.example.com` is reachable from the Ansible controller or target hosts at job execution time.
3. The OAuth2 token endpoint (`https://auth.example.com/oauth/token`) is reachable from the target host at converge time; the fetched token's downstream consumer exists but is not present in this repository.
4. The API token endpoint (`https://api.example.com/token_endpoint`) is a real production endpoint — the placeholder regex and stub URL in the Chef source are development artefacts, not the production values.
5. The `ssl_passphrase` stored in Conjur at `production/nginx/ssl_passphrase` is the same passphrase that was used to generate any existing private keys on production hosts; changing it without regenerating certificates will break Nginx.
6. The `www-data` user exists on all target hosts (i.e., targets are Debian/Ubuntu); RHEL/CentOS support declared in `metadata.rb` and `meta/main.yml` is aspirational and not yet fully implemented in the role.
7. The Molecule test suite is intended for local/CI validation only; it does not represent a full integration test against a production-like environment.
8. The `export-output.md` telemetry file is a migration pipeline artefact and is not part of the deployable role; it can be removed from the repository after the migration is accepted.
9. No Berksfile or Policyfile is present in the repository, meaning the `cyberark-conjur` cookbook dependency was resolved via a Berkshelf or Chef Infra Server workflow that is external to this repository and does not need to be migrated.
10. The `ansible/roles/nginx_multisite/export-output.md` review findings (task ordering bugs, missing `sshd_config` stat guard) have already been applied to the role source; the current state of the role in `ansible/roles/nginx_multisite/tasks/` reflects the fixed version.

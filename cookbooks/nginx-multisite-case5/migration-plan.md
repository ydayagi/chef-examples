# MIGRATION FROM CHEF TO ANSIBLE

## Executive Summary

This repository contains a single Chef cookbook (`nginx-multisite` v1.0.0) that configures Nginx as a multi-site SSL-enabled web server with host hardening. The migration to Ansible is **already complete**: a fully validated Ansible role (`ansible/roles/nginx_multisite`) exists alongside the original Chef source, produced by an automated migration pipeline. The migration export report confirms 26/26 items completed with zero errors, zero warnings, and zero lint violations.

This document serves as the authoritative record of what was migrated, how credentials were re-architected, what open items remain, and the recommended handoff sequence for the operations team.

**Scope**: 1 Chef cookbook → 1 Ansible role  
**Complexity**: Medium (custom Chef resources, CyberArk Conjur integration, hardcoded secret requiring rotation, one partially-understood API token flow)  
**Estimated remaining effort**: 2–5 days (secret rotation, API token investigation, AAP job template wiring, smoke testing in a real environment)

---

## Module Migration Plan

This repository contains one Chef cookbook that required individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **nginx-multisite**:
  - Description: Nginx multi-site web server with SSL termination, host hardening, and runtime secret retrieval. Installs and configures Nginx to serve three SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`), generates self-signed TLS certificates per vhost using a passphrase retrieved from CyberArk Conjur, hardens the host with fail2ban, UFW firewall (deny-by-default, allow 22/80/443), sysctl kernel parameters, and SSH daemon hardening (no root login, no password auth). Also fetches an OAuth2 bearer token and a secondary API token at runtime.
  - Path: `/` (cookbook root — `metadata.rb`, `recipes/`, `attributes/`, `templates/`, `files/`, `resources/`)
  - Technology: Chef (>= 16.0)
  - Key Features:
    - Nginx installation, global `nginx.conf`, per-vhost `site.conf` with SSL, security snippet `security.conf`
    - Self-signed TLS certificate generation via `openssl req` with passphrase from CyberArk Conjur (`production/nginx/ssl_passphrase`)
    - fail2ban with custom `jail.local`, UFW firewall rules via shell commands
    - sysctl kernel hardening (`/etc/sysctl.d/99-security.conf`)
    - SSH hardening via custom `ada_ada` resource (line-in-file pattern matching with backup)
    - OAuth2 client-credentials token fetch (`fetch_token` custom resource) — **client secret hardcoded as `sup3rs3cr3t`**
    - Secondary API token fetch and regex parse (`fetch_and_parse_token` custom resource) — regex pattern is a placeholder, downstream consumer unknown
    - Three static `index.html` files deployed per vhost document root

- **nginx_multisite** *(Ansible — migration target)*:
  - Description: Direct Ansible equivalent of the Chef cookbook above, structured as a Galaxy-compatible role. All five recipes map 1:1 to task files. Custom Chef resources replaced with native Ansible modules (`ansible.builtin.lineinfile`, `ansible.builtin.uri`, `ansible.builtin.shell`). Secrets re-architected as AAP custom credential types.
  - Path: `ansible/roles/nginx_multisite/`
  - Technology: Ansible (>= 2.14.0)
  - Key Features:
    - `tasks/main.yml` → orchestration entry point (validate credentials → security → nginx → ssl → sites)
    - `tasks/validate_credentials.yml` → pre-flight `assert` for all 11 required credential variables
    - `tasks/security.yml` → fail2ban, UFW, OAuth token fetch, sysctl, SSH hardening
    - `tasks/nginx.yml` → Nginx install, global config, security snippet, document roots, static files, service
    - `tasks/ssl.yml` → openssl/ca-certificates, ssl-cert group, cert/key directories, self-signed cert generation loop
    - `tasks/sites.yml` → per-vhost `site.conf` templates, symlinks in `sites-enabled`, default site removal
    - `handlers/main.yml` → Reload/restart handlers for nginx, fail2ban, ssh, sysctl
    - `meta/argument_specs.yml` → full role argument specification covering all defaults and AAP-injected variables
    - `aap-configuration/` → AAP custom credential type and credential definitions (3 credential types)
    - `molecule/default/` → complete Molecule test suite (create/converge/verify/destroy)

---

### Infrastructure Files

- `metadata.rb`: Chef cookbook metadata — name, version (`1.0.0`), maintainer, license (Apache-2.0), supported platforms (Ubuntu >= 18.04, CentOS >= 7.0), and the single external dependency `cyberark-conjur ~> 3.0`. Migrated to `ansible/roles/nginx_multisite/meta/main.yml`.
- `attributes/default.rb`: Chef node attribute defaults — vhost dictionary, SSL paths, CyberArk Conjur connection parameters, and security feature flags. Migrated to `ansible/roles/nginx_multisite/defaults/main.yml`; credential values replaced with AAP-injected variable references.
- `resources/ada_ada.rb`: Custom Chef resource implementing a line-in-file editor with regex match and timestamped backup. Replaced in Ansible by `ansible.builtin.lineinfile` with `regexp:`, `backup: true`, and a preceding `ansible.builtin.stat` guard.
- `resources/fetch_token.rb`: Custom Chef resource performing an OAuth2 client-credentials POST and storing the access token in `node.run_state`. Replaced in Ansible by `ansible.builtin.uri` + `ansible.builtin.set_fact` with `no_log`.
- `resources/fetch_and_parse_token.rb`: Custom Chef resource performing a GET to an API endpoint and extracting a token via regex (`X-Header:(.+)`). **Not fully converted** — the regex pattern in the source is a placeholder and the downstream consumer is unknown. A detailed comment block in `tasks/security.yml` documents what must be resolved before implementation.
- `templates/default/*.erb`: Five ERB templates (nginx.conf, security.conf, site.conf, fail2ban.jail.local, sysctl-security.conf). All converted to Jinja2 (`.j2`). Four were static (no ERB variables); `site.conf.erb` had five ERB variables converted to Jinja2 equivalents.
- `files/default/{ci,status,test}/index.html`: Static HTML placeholder files for each vhost document root. Copied as-is to `ansible/roles/nginx_multisite/files/{ci,status,test}/index.html`.
- `ansible/roles/nginx_multisite/aap-configuration/controller_credential_types.yml`: Defines three AAP custom credential types: *CyberArk Conjur SSL Passphrase*, *OAuth2 Client Credentials*, and *API Token Endpoint*. Must be applied to the AAP controller before the job template is created.
- `ansible/roles/nginx_multisite/aap-configuration/controller_credentials.yml`: Defines three AAP credential instances referencing vault variables (`vault_conjur_api_key`, `vault_ssl_passphrase`, `vault_oauth_client_secret`, `vault_api_auth_header`). Requires a backing secrets store (e.g., HashiCorp Vault, AAP credential store) to be populated before use.
- `ansible/roles/nginx_multisite/export-output.md`: Automated migration pipeline report — 26/26 items complete, 3 post-migration review fixes applied (fail2ban ordering, sshd_config stat guard, nginx service ordering), 0 lint violations.
- `ansible/roles/nginx_multisite/molecule/default/`: Full Molecule test suite with local-connection driver. Verifies nginx configs, symlinks, static content, SSL cert/key permissions, fail2ban/sysctl/sshd_config content, service state, and HTTP/HTTPS port availability.

---

### Target Details

- **Operating System**: Ubuntu (Bionic/Focal) and Red Hat Enterprise Linux / CentOS 7–10. Both families are declared in `metadata.rb` (`supports 'ubuntu', '>= 18.04'` and `supports 'centos', '>= 7.0'`) and reflected in `meta/main.yml` platform list. Package names (`nginx`, `fail2ban`, `ufw`, `openssl`, `ca-certificates`) and paths (`/etc/nginx/sites-available`, `www-data` user/group) are Debian/Ubuntu-centric; CentOS/RHEL compatibility would require additional testing (UFW is not native to RHEL; `www-data` group does not exist by default).
- **Virtual Machine Technology**: Not specified. No cloud-init configs, VM tools packages, or hypervisor-specific files are present.
- **Cloud Platform**: Not specified. No cloud provider SDK, metadata endpoint references, or cloud-specific IAM configurations are present.

---

## Migration Approach

### Key Dependencies to Address

- **`cyberark-conjur` Chef supermarket cookbook (~> 3.0)**: Provided the `conjur_variable()` helper used in `recipes/ssl.rb` to retrieve the SSL passphrase at converge time. In the Ansible role this dependency is **eliminated** — the passphrase is now injected directly as an AAP credential variable (`ssl_passphrase`) via the *CyberArk Conjur SSL Passphrase* custom credential type. The AAP controller itself (or a separate lookup plugin, if preferred) is responsible for the Conjur API call. If a direct Conjur lookup from the Ansible play is required, the `cyberark.conjur` Ansible collection would be the equivalent.
- **`fetch_token` custom resource (OAuth2)**: No external library dependency beyond Ruby stdlib (`net/http`, `json`). Replaced by `ansible.builtin.uri`. The OAuth client secret was **hardcoded** (`sup3rs3cr3t`) in `recipes/security.rb` and must be rotated and stored in the AAP credential store before the Ansible role is used in production.
- **`fetch_and_parse_token` custom resource (API token)**: No external library dependency. **Not yet fully implemented** in the Ansible role — see the inline comment block in `tasks/security.yml`. The production regex pattern, endpoint authentication requirements, and downstream consumer must be confirmed by the team before this task can be completed.
- **`ada_ada` custom resource (line-in-file)**: Internal custom resource with no external dependency. Fully replaced by `ansible.builtin.lineinfile` + `ansible.builtin.stat`.

---

### Security Considerations

- **Hardcoded OAuth2 client secret** (`sup3rs3cr3t` in `recipes/security.rb`): This is the most critical security finding. The secret is committed in plaintext to the repository. **Action required before any production deployment**: rotate the secret, store it in a secrets manager, and supply it exclusively via the AAP *OAuth2 Client Credentials* credential type. The Ansible role correctly marks this variable `no_log` and never defines it in defaults.
- **CyberArk Conjur integration**: The Chef cookbook used the `conjur_variable()` helper to fetch `production/nginx/ssl_passphrase` at runtime. The Ansible role replaces this with an AAP credential type that injects `ssl_passphrase`, `conjur_appliance_url`, `conjur_account`, `conjur_variable_path`, and `conjur_api_key` as extra vars. The Conjur API key is marked `secret: true` in the credential type definition. The actual Conjur lookup call is not performed inside the role — the AAP controller is expected to resolve it, or the team must add a `cyberark.conjur` lookup task if in-play resolution is required.
- **SSL private key passphrase exposure**: The `openssl req` command in `recipes/ssl.rb` passes the passphrase via `-passout pass:#{ssl_passphrase}` on the command line, which is visible in process listings. The Ansible equivalent uses the same shell approach but wraps the task with `no_log: "{{ nginx_multisite_secure_logging }}"` (default `true`) to suppress output. Consider using `-passout file:` or a named pipe for stricter environments.
- **Self-signed certificates**: All three vhosts use self-signed, 365-day RSA-2048 certificates generated at converge time. These are appropriate for internal/development use only. For production, replace with certificates from an internal CA or a public CA (e.g., Let's Encrypt via `certbot`).
- **SSH hardening via `lineinfile`**: The `ada_ada` resource (and its Ansible `lineinfile` equivalent) modifies `/etc/ssh/sshd_config` in-place rather than managing the full file. This is intentional (out-of-scope for a full sshd_config template) but means other sshd settings are not under configuration management. A stat guard was added post-migration to prevent creating a stub file on hosts without `openssh-server`.
- **UFW managed via shell commands**: UFW has no `ansible.builtin` module. The role uses `ansible.builtin.shell` with `changed_when` tied to stdout content. This is idempotent but less declarative than a dedicated firewall module. If the `community.general` collection is permitted in future, `community.general.ufw` would be the preferred replacement.
- **API token endpoint (`fetch_and_parse_token`)**: The endpoint URL (`https://api.example.com/token_endpoint`), authentication requirements, and the regex pattern are all unknown or placeholder values. The `api_auth_header` credential variable is marked `secret: true` in the AAP credential type, but the task itself is not yet implemented. Until this is resolved, the role will validate that `api_auth_header` is defined (via `validate_credentials.yml`) but will not use it.
- **Credential variable pre-flight validation**: `tasks/validate_credentials.yml` asserts all 11 required credential variables are defined before any work begins, providing a fast-fail guard against misconfigured AAP job templates.

---

### Technical Challenges

- **Unresolved `fetch_and_parse_token` implementation**: The Chef `fetch_and_parse_token` resource uses a placeholder regex (`X-Header:(.+)`) and calls an undocumented endpoint. The downstream consumer of the extracted token is not present anywhere in the cookbook. This is the only item that could not be fully migrated. **Mitigation**: The migration pipeline left a detailed comment block in `tasks/security.yml` listing the three questions that must be answered. Assign a developer with access to the original system to investigate and implement the `ansible.builtin.uri` + `ansible.builtin.set_fact` pattern documented in the comment.
- **CentOS/RHEL platform parity**: The cookbook declares CentOS >= 7.0 support, but the implementation is Debian/Ubuntu-centric (`ufw`, `www-data` user/group, `sites-available`/`sites-enabled` directory layout). On RHEL/CentOS, UFW is not available (use `firewalld`), the nginx package layout differs, and the web server user is `nginx` not `www-data`. **Mitigation**: Add `ansible_os_family` conditionals or separate variable files (`vars/RedHat.yml`) if RHEL/CentOS support is required. Molecule tests currently run with a local connection and do not cover RHEL.
- **Self-signed certificate idempotency**: The `openssl req` task uses `args: creates:` to skip regeneration if the `.crt` file already exists. This means certificate renewal (after expiry) requires manual deletion of the cert file or a separate renewal play. **Mitigation**: Document the 365-day expiry and add a monitoring alert or a separate renewal task if this is used in long-lived environments.
- **UFW `changed_when` reliability**: The `changed_when` conditions for UFW shell tasks rely on specific stdout strings (`'Default incoming policy changed'`, `'Rules updated'`, `'Firewall is active and enabled'`). These strings may differ across UFW versions or locales. **Mitigation**: Test against the exact UFW version present on target hosts; adjust strings if needed.
- **AAP credential type bootstrap**: The `aap-configuration/` YAML files define credential types and credentials but do not include a playbook to apply them. They are intended for use with the `infra.controller_configuration` collection or manual import. **Mitigation**: Create a bootstrap playbook that applies `controller_credential_types.yml` and `controller_credentials.yml` to the AAP controller before the first job template run.
- **Molecule test environment**: The Molecule suite uses `ansible_connection: local`, which means it tests task logic but not actual service behaviour on a real OS. Port 80/443 assertions in `verify.yml` will only pass if nginx is genuinely running on the test host. **Mitigation**: For full integration testing, configure a Docker or VM driver with a supported Ubuntu image.

---

### Migration Order

The cookbook is a single unit; the migration is already complete. The recommended **deployment handoff sequence** is:

1. **Secret rotation and AAP credential population** *(blocker — do first)*: Rotate the OAuth2 client secret (currently `sup3rs3cr3t`), obtain the real Conjur API key and SSL passphrase, and populate all `vault_*` variables referenced in `controller_credentials.yml` in the backing secrets store.
2. **AAP controller bootstrap**: Apply `aap-configuration/controller_credential_types.yml` and `controller_credentials.yml` to the AAP controller (via `infra.controller_configuration` or the AAP UI). Verify all three credential types appear and the credential instances resolve without errors.
3. **`fetch_and_parse_token` investigation and implementation**: Assign a developer to determine the real regex pattern, endpoint authentication, and downstream consumer. Implement the `ansible.builtin.uri` + `ansible.builtin.set_fact` task in `tasks/security.yml` following the comment block instructions.
4. **Molecule smoke test on Ubuntu**: Run `molecule test` against a real Ubuntu 20.04 (Focal) Docker or VM instance to validate the full converge/verify cycle end-to-end.
5. **CentOS/RHEL compatibility assessment**: Decide whether RHEL/CentOS support is required. If yes, add OS-family conditionals and extend Molecule scenarios before promoting to production.
6. **Production job template creation and first run**: Create the AAP job template, attach all three credential types, run against a non-production host, and validate nginx is serving all three vhosts over HTTPS.

---

### Assumptions

1. **AAP (Ansible Automation Platform) is the target execution environment.** The credential type architecture, `no_log` patterns, and `validate_credentials.yml` pre-flight all assume AAP job templates with custom credential types. If plain `ansible-playbook` CLI is used instead, the credential injection mechanism must be redesigned (e.g., Ansible Vault, environment variables, or a lookup plugin).
2. **The CyberArk Conjur lookup is performed by AAP, not inside the role.** The role receives `ssl_passphrase` as an already-resolved extra var. If the team requires the role to perform the Conjur API call itself, the `cyberark.conjur` Ansible collection must be added as a dependency and a lookup task inserted in `tasks/ssl.yml`.
3. **Self-signed certificates are acceptable for the target environment.** The migration preserves the Chef cookbook's self-signed certificate generation. If production-grade certificates are required, the SSL task file must be replaced with a CA-signed or ACME-based certificate workflow.
4. **The three vhosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`) are the complete set.** The `nginx_multisite_sites` dictionary in `defaults/main.yml` mirrors the Chef attributes exactly. Additional vhosts can be added via inventory/group vars without modifying the role.
5. **Ubuntu (Bionic/Focal) is the primary target OS.** CentOS/RHEL is declared as supported in metadata but the implementation is Debian-centric. No RHEL-specific task branches exist in the migrated role.
6. **The `fetch_and_parse_token` token is not consumed by any other task in this cookbook.** The Chef source contains no downstream use of `node.run_state['extracted_token']` within the cookbook. If another cookbook or wrapper recipe consumed it, that dependency is not captured here.
7. **The OAuth2 token (`nginx_multisite_access_token`) is fetched for a downstream purpose not visible in this cookbook.** The token is stored as a fact but not used by any subsequent task in the role. The same assumption applies as for the API token above.
8. **`www-data` user and group pre-exist on target hosts.** The role creates document root directories owned by `www-data` but does not create the user/group. On Ubuntu this user is created by the `nginx` package; on other platforms this may need to be added.
9. **The `openssh-server` package is pre-installed on target hosts.** The SSH hardening tasks skip gracefully if `/etc/ssh/sshd_config` is absent (stat guard added post-migration), but the intent is that SSH is present and the hardening takes effect.
10. **The `api_auth_header` credential variable may be optional.** The `controller_credential_types.yml` definition does not list `api_auth_header` in the `required` array, suggesting the API endpoint may not always require authentication. The `validate_credentials.yml` assert does require it to be defined, which is a conservative stance — this should be revisited once the endpoint is understood.

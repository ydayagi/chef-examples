# MIGRATION FROM CHEF TO ANSIBLE

## Executive Summary

This repository contains a single Chef cookbook (`nginx-multisite` v1.0.0) that configures Nginx as a multi-site SSL-enabled web server with host hardening. The migration scope is narrow but non-trivial: the cookbook bundles three custom Chef resources (two of which perform runtime credential fetching), integrates with CyberArk Conjur for secrets management, and contains a hardcoded OAuth client secret that must be rotated before any Ansible deployment.

**The Ansible migration is already substantially complete.** An `ansible/roles/nginx_multisite/` role exists alongside the Chef source, produced by an automated migration tool. The role has passed lint validation (0 errors, 0 warnings), includes Molecule tests, and has AAP credential-type definitions. The remaining work is operational: secret rotation, resolution of one incomplete task stub (`fetch_and_parse_token`), and AAP controller onboarding.

| Dimension | Detail |
|---|---|
| Source technology | Chef (>= 16.0) |
| Cookbooks | 1 (`nginx-multisite`) |
| Custom Chef resources | 3 (`ada_ada`, `fetch_token`, `fetch_and_parse_token`) |
| External cookbook dependency | 1 (`cyberark-conjur ~> 3.0`) |
| Target | Ansible role `nginx_multisite` (Ansible >= 2.14) |
| Migration status | Role generated and validated; operational blockers remain |
| Estimated remaining effort | 3–5 days (secret rotation + stub resolution + AAP onboarding) |

---

## Module Migration Plan

This repository contains one Chef cookbook that maps to one Ansible role:

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

- **nginx-multisite**:
  - Description: Nginx multi-site web server with SSL termination, host hardening, and runtime credential fetching. Installs and configures Nginx to serve three SSL-enabled virtual hosts (`test.cluster.local`, `ci.cluster.local`, `status.cluster.local`), generates self-signed TLS certificates per vhost using a passphrase retrieved from CyberArk Conjur, hardens the host with fail2ban, UFW firewall (deny-by-default, allow 22/80/443), sysctl kernel parameters, and SSH daemon hardening (no root login, no password auth). Also fetches an OAuth2 bearer token and a second token from an undocumented API endpoint at runtime.
  - Path: `.` (cookbook root — `metadata.rb`, `recipes/`, `attributes/`, `resources/`, `templates/`, `files/`)
  - Technology: Chef
  - Key Features:
    - Nginx installation, `nginx.conf` and `security.conf` templates, per-site `sites-available/` config with symlinks to `sites-enabled/`
    - Self-signed TLS certificate generation via `openssl req` per vhost; passphrase sourced from CyberArk Conjur (`production/nginx/ssl_passphrase`)
    - fail2ban with custom `jail.local`; UFW firewall via shell commands; sysctl kernel hardening via `/etc/sysctl.d/99-security.conf`
    - SSH hardening via custom `ada_ada` resource (line-in-file with regex match and timestamped backup)
    - OAuth2 client-credentials token fetch (`fetch_token` resource) — **client secret `sup3rs3cr3t` is hardcoded in `recipes/security.rb`**
    - Undocumented API token fetch and regex parse (`fetch_and_parse_token` resource) — regex pattern is a placeholder; downstream consumer unknown
    - Static `index.html` files deployed to each vhost document root

- **nginx_multisite** *(Ansible target role)*:
  - Description: Migrated Ansible role equivalent of the Chef cookbook above, already generated and lint-validated.
  - Path: `ansible/roles/nginx_multisite/`
  - Technology: Ansible (>= 2.14)
  - Key Features:
    - Task files mirror Chef recipes: `security.yml`, `nginx.yml`, `ssl.yml`, `sites.yml`, `validate_credentials.yml`
    - Jinja2 templates converted from all five ERB templates
    - AAP credential types and credential objects defined in `aap-configuration/`
    - `meta/argument_specs.yml` covers all role variables and AAP-injected secrets
    - Molecule test suite (`converge`, `verify`, `create`, `destroy`) with local connection driver
    - Three ordering/idempotency bugs identified by the automated review agent and fixed before validation

---

### Infrastructure Files

- `metadata.rb`: Chef cookbook metadata — name, version (`1.0.0`), maintainer, license (Apache-2.0), supported platforms (Ubuntu >= 18.04, CentOS >= 7.0), and the single external dependency `cyberark-conjur ~> 3.0`. Maps to `ansible/roles/nginx_multisite/meta/main.yml`.
- `attributes/default.rb`: Chef node attributes defining the three vhost configurations, SSL certificate paths, CyberArk Conjur connection parameters, and security feature toggles. Fully converted to `ansible/roles/nginx_multisite/defaults/main.yml`.
- `recipes/default.rb`: Cookbook entry point — orchestrates recipe inclusion order (`security → nginx → ssl → sites`). Maps to `ansible/roles/nginx_multisite/tasks/main.yml` (with `validate_credentials` prepended).
- `recipes/security.rb`: Host hardening — fail2ban, UFW, OAuth token fetch, sysctl, SSH hardening. Contains the hardcoded `client_secret: 'sup3rs3cr3t'`. Maps to `ansible/roles/nginx_multisite/tasks/security.yml`.
- `recipes/nginx.rb`: Nginx package install, `nginx.conf`/`security.conf` templates, document root creation, static file deployment, service management. Maps to `ansible/roles/nginx_multisite/tasks/nginx.yml`.
- `recipes/ssl.rb`: SSL package install, `ssl-cert` group, certificate/key directory creation, per-vhost self-signed cert generation using Conjur-fetched passphrase. Maps to `ansible/roles/nginx_multisite/tasks/ssl.yml`.
- `recipes/sites.rb`: Per-vhost `site.conf` template, `sites-enabled` symlinks, removal of the default Nginx site. Maps to `ansible/roles/nginx_multisite/tasks/sites.yml`.
- `resources/ada_ada.rb`: Custom Chef resource for idempotent line-in-file editing with regex match and timestamped backup. Replaced by `ansible.builtin.lineinfile` with `regexp`/`backup` parameters.
- `resources/fetch_token.rb`: Custom Chef resource performing an OAuth2 client-credentials POST and storing the access token in `node.run_state`. Replaced by `ansible.builtin.uri` + `ansible.builtin.set_fact` in `tasks/security.yml`.
- `resources/fetch_and_parse_token.rb`: Custom Chef resource performing a GET to an undocumented API endpoint and extracting a token via regex from the response body. **Not fully converted** — a documented stub with resolution instructions exists in `tasks/security.yml`.
- `templates/default/*.erb`: Five ERB templates (nginx.conf, security.conf, site.conf, fail2ban.jail.local, sysctl-security.conf). All converted to Jinja2 (`.j2`) in `ansible/roles/nginx_multisite/templates/`.
- `files/default/{ci,status,test}/index.html`: Static HTML files for each vhost. Copied to `ansible/roles/nginx_multisite/files/{ci,status,test}/index.html`.
- `ansible/roles/nginx_multisite/aap-configuration/controller_credential_types.yml`: Defines three custom AAP credential types: `CyberArk Conjur SSL Passphrase`, `OAuth2 Client Credentials`, `API Token Endpoint`. Must be applied to the AAP controller before the role can run.
- `ansible/roles/nginx_multisite/aap-configuration/controller_credentials.yml`: Defines three AAP credential objects referencing vault-backed variables. Requires vault population before use.
- `ansible/roles/nginx_multisite/meta/argument_specs.yml`: Full argument specification for all role variables and AAP-injected secrets. Enables AAP input validation at job-template level.
- `ansible/roles/nginx_multisite/molecule/default/`: Molecule test suite for local-connection testing of the role.
- `ansible/roles/nginx_multisite/export-output.md`: Automated migration tool output — 26/26 items completed, 0 lint violations, review findings and fixes documented.

---

### Target Details

- **Operating System**: Ubuntu (>= 18.04, focal/bionic confirmed in `meta/main.yml`) and RHEL/CentOS family (>= 7, EL 7–10 in Ansible meta). Primary hardening tooling (`ufw`, `fail2ban`, `www-data` user/group) is Debian/Ubuntu-centric; CentOS/RHEL targets will require firewalld vs. UFW handling and `nginx` user substitution.
- **Virtual Machine Technology**: Not specified. No cloud-init, VM tools packages, or hypervisor-specific configurations are present.
- **Cloud Platform**: Not specified. No cloud provider SDK, metadata endpoint references, or cloud-specific IAM configurations are present.

---

## Migration Approach

### Key Dependencies to Address

- **`cyberark-conjur` (~> 3.0)** *(Chef cookbook)*: The Conjur integration in Chef uses the `conjur_variable()` helper function to fetch the SSL passphrase at converge time. In the Ansible role this is replaced by an AAP custom credential type (`CyberArk Conjur SSL Passphrase`) that injects `ssl_passphrase` as an extra variable at job runtime. The Conjur appliance URL, account, variable path, and API key must be populated in the AAP vault before the role can run. No `cyberark.conjur` Ansible collection is required — the credential injector pattern is used instead.

- **`fetch_and_parse_token` custom resource** *(unresolved stub)*: The `fetch_and_parse_token` resource GETs `https://api.example.com/token_endpoint` and extracts a value via the regex `X-Header:(.+)`. The Ansible `tasks/security.yml` contains a detailed stub comment explaining that: (1) the regex pattern `pattern1:(.+)` is a placeholder, (2) the endpoint may require an auth header not visible in the source, and (3) the downstream consumer of the extracted token is unknown. This must be resolved with the owning team before the Ansible role is considered feature-complete.

- **OAuth2 client secret rotation** *(hardcoded credential)*: `recipes/security.rb` contains `client_secret: 'sup3rs3cr3t'` in plain text. The Ansible role replaces this with the AAP `OAuth2 Client Credentials` credential type injecting `oauth_client_secret` at runtime. **The secret must be rotated before the Ansible role is deployed to any environment** — the current value is compromised by its presence in source control history.

---

### Security Considerations

- **Hardcoded OAuth2 client secret**: `recipes/security.rb` line `client_secret: 'sup3rs3cr3t'` is committed in plain text. This credential must be treated as compromised. Rotate the secret at the OAuth2 provider, store the new value in the AAP vault, and confirm the `OAuth2 Client Credentials` AAP credential object is populated before first Ansible run.

- **CyberArk Conjur integration**: The Chef cookbook fetches the SSL private key passphrase from Conjur at `production/nginx/ssl_passphrase`. The Ansible role replicates this via an AAP custom credential type. The Conjur API key (`conjur_api_key`) is marked `secret: true` in the credential type definition and injected via `extra_vars` with `no_log` protection. Ensure the Conjur host identity used by AAP has least-privilege access to only the required variable path.

- **SSL private key passphrase exposure**: The passphrase is passed directly to `openssl req -passout pass:{{ ssl_passphrase }}` on the command line. The Ansible task correctly sets `no_log: "{{ nginx_multisite_secure_logging }}"` (default `true`) to suppress the command from logs. Verify that AAP job output verbosity is not set to a level that would expose the passphrase in the job stdout.

- **Self-signed certificates**: All three vhosts use self-signed certificates valid for 365 days. These are appropriate for internal cluster use but will require a certificate rotation strategy (cron, scheduled AAP job, or replacement with a CA-signed workflow) before expiry.

- **SSH hardening idempotency guard**: The Ansible role adds a `stat` pre-check before modifying `/etc/ssh/sshd_config` to avoid creating a malformed stub on minimal images without `openssh-server`. Confirm that all target hosts have `openssh-server` installed, or accept that SSH hardening tasks will be skipped on hosts where it is absent.

- **UFW via shell tasks**: UFW management uses `ansible.builtin.shell` (no native UFW module, community collections excluded per project constraints). The `changed_when` conditions are tied to stdout content strings. Validate these strings against the UFW version on target hosts, as output wording varies between Ubuntu releases.

- **`no_log` toggle**: `nginx_multisite_secure_logging` defaults to `true`. This variable must never be set to `false` in production inventory or AAP job templates, as it would expose `ssl_passphrase`, `oauth_client_secret`, and `api_auth_header` in job output.

- **API token endpoint auth header**: The `api_auth_header` field in the `API Token Endpoint` credential type is marked `secret: true`. Its value and whether it is actually required by the endpoint are unknown — this must be confirmed as part of resolving the `fetch_and_parse_token` stub.

---

### Technical Challenges

- **`fetch_and_parse_token` stub resolution**: The most significant open item. The original Chef resource uses a placeholder regex (`X-Header:(.+)`) and the endpoint URL `https://api.example.com/token_endpoint` is clearly a stand-in. The migration team must: (1) identify the real endpoint and its authentication requirements, (2) determine the actual response format and correct regex pattern, and (3) identify what downstream task consumes the extracted token. Until this is resolved, the Ansible role is functionally incomplete relative to the Chef cookbook.

- **CentOS/RHEL platform parity**: The cookbook declares support for CentOS >= 7.0, but the hardening tooling (`ufw`, `www-data` group, `fail2ban` package name) is Ubuntu-centric. On RHEL/CentOS targets, `ufw` is not available (use `firewalld`), the web server user is `nginx` not `www-data`, and `fail2ban` package availability varies by EPEL version. The Ansible role inherits this gap — platform-conditional tasks will be needed if RHEL/CentOS targets are in scope.

- **Self-signed certificate idempotency**: The `openssl req` task uses `args: creates:` to skip regeneration if the `.crt` file already exists. This means certificate renewal (e.g., after expiry) requires manual deletion of the cert file or a separate renewal play. A certificate lifecycle management strategy should be defined before production deployment.

- **AAP controller onboarding**: The `aap-configuration/` YAML files define credential types and credentials but must be applied to the AAP controller (e.g., via `awx.awx` collection or the AAP UI) before any job template using this role can run. This is an operational step with no Chef equivalent — it requires AAP admin access and vault variable population.

- **Molecule test environment**: The Molecule suite uses `ansible_connection: local`, which means tests run against the Molecule host itself. This is suitable for CI but means the test does not validate network-level behavior (actual HTTP responses on 80/443, real UFW rule enforcement). A staging environment test against a real VM is recommended before production rollout.

- **Source control secret history**: The hardcoded `client_secret: 'sup3rs3cr3t'` in `recipes/security.rb` is present in git history. If this repository is or was accessible beyond the immediate team, a full git history rewrite (e.g., `git filter-repo`) should be considered in addition to secret rotation.

---

### Migration Order

The Ansible role is already generated and validated. The remaining steps are ordered by risk and dependency:

1. **Secret rotation and vault population** *(blocker for all subsequent steps)*: Rotate the OAuth2 client secret (`sup3rs3cr3t`), populate the AAP vault with all credential variables (`vault_conjur_api_key`, `vault_ssl_passphrase`, `vault_oauth_client_secret`, `vault_api_auth_header`), and confirm Conjur connectivity from the AAP controller.

2. **`fetch_and_parse_token` stub resolution** *(functional completeness)*: Engage the team owning `https://api.example.com/token_endpoint` to determine the real endpoint URL, authentication requirements, response format, correct regex pattern, and downstream consumer. Implement the `ansible.builtin.uri` + `ansible.builtin.set_fact` task in `tasks/security.yml` following the pattern already used for the OAuth token fetch.

3. **AAP controller onboarding** *(operational prerequisite)*: Apply `controller_credential_types.yml` and `controller_credentials.yml` to the AAP controller. Create a job template referencing the `nginx_multisite` role and attach all three credential objects. Validate that extra-var injection works correctly for all secret fields.

4. **Platform scope confirmation** *(risk reduction)*: Confirm whether CentOS/RHEL targets are in scope. If yes, add platform-conditional tasks for `firewalld` vs. `ufw` and `nginx` vs. `www-data` user/group before staging deployment.

5. **Staging deployment and validation** *(pre-production gate)*: Run the Ansible role against a staging VM (not Molecule local connection) to validate end-to-end: Nginx serving all three vhosts, SSL certificates generated and accessible, fail2ban active with correct jails, UFW rules enforced, SSH hardening applied.

6. **Production rollout** *(final step)*: After staging sign-off, deploy to production. Schedule a certificate renewal job (or document the manual renewal procedure) before the 365-day cert expiry window.

---

### Assumptions

1. **The Ansible role in `ansible/roles/nginx_multisite/` is the authoritative migration output** and should be treated as the starting point, not regenerated from scratch. The export summary confirms 26/26 items completed with 0 lint violations.

2. **`https://auth.example.com/oauth/token` and `https://api.example.com/token_endpoint` are placeholder URLs** substituted for real internal endpoints. The actual URLs, along with the real OAuth client ID and the real API token parse pattern, must be supplied by the owning team.

3. **The `cyberark-conjur` Chef cookbook dependency is used solely for the `conjur_variable()` helper** to fetch the SSL passphrase. No other Conjur features (host enrollment, policy management) are used by this cookbook.

4. **The `ada_ada` custom resource is fully replaced by `ansible.builtin.lineinfile`** and does not require a custom Ansible module. The timestamped backup behavior of `ada_ada` is approximated by `backup: true` on `lineinfile` (which creates a single `.bak` file, not timestamped copies).

5. **The three static `index.html` files are placeholder content** (the file names suggest CI, status, and test environments). Their content is not examined in this plan; if they contain environment-specific URLs or tokens, they should be reviewed before deployment.

6. **UFW is the intended firewall manager on all target hosts.** If any targets use `firewalld` (common on RHEL/CentOS), the UFW shell tasks will fail silently or error. This assumption should be validated against the target host inventory.

7. **The `ssl-cert` group is expected to exist or be creatable on all target hosts.** On some minimal Ubuntu images this group is created by the `ssl-cert` package rather than being a base OS group. The Ansible role creates it explicitly, which is correct, but the assumption is that no conflicting GID assignment exists.

8. **Molecule tests are intended for CI pipeline use only** (local connection driver). They do not substitute for integration testing against real infrastructure.

9. **No Berksfile or Policyfile is present in the repository.** The single external dependency (`cyberark-conjur ~> 3.0`) is declared only in `metadata.rb`. It is assumed that the Chef environment used a Berkshelf-based workflow, but no lockfile is available to confirm the exact resolved version.

10. **The `nginx_multisite_secure_logging` variable must remain `true` in all non-debug contexts.** Any inventory, group_vars, or AAP survey that sets this to `false` will expose secrets in job output. This constraint should be enforced via AAP survey validation or role documentation.

# FLPATH-4737 retest cases — nginx-multisite

Five copies of the `nginx-multisite` cookbook, one per execution performed for
FLPATH-4737 (custom code detection in Chef). Each copy contains only source
files — no migration plans or generated Ansible output.

| Copy | State | Original result | Converter |
|---|---|---|---|
| `nginx-multisite-case1` | `security.rb` uses the custom `lineinfile` resource (the two `sed` execute blocks replaced) | converted correctly | unmodified |
| `nginx-multisite-case2` | same, resource renamed to `ada_ada` (`provides :ada_ada`) | converted correctly (behavior-based, not name-based) | unmodified |
| `nginx-multisite-case3` | case2 plus `fetch_token` and `fetch_and_parse_token` custom resources, one call each in `security.rb` | `fetch_token` converted, `fetch_and_parse_token` silently dropped | unmodified |
| `nginx-multisite-case4` | case2 plus auth-free `fetch_value` and `fetch_and_parse_value` resources | both convert (regression check of the fix) | with the analyze-prompt fix (step 7) |
| `nginx-multisite-case5` | identical source state to case3 (OAuth pair) | both convert — the case that failed in case3 now passes | with the analyze-prompt fix (step 7) |

The converter fix for cases 4 and 5 is step 7 ("Detect and describe custom
resources and libraries") in `prompts/chef_analysis_system.md`, on the
`flpath4737-chef` branch of the x2a-convertor repository.

## Retest results (2026-10-28)

- **case4, case5** (with the fix): both custom fetch resources converted in
  each — `ansible.builtin.uri` tasks plus regex parsing. Reproduced the
  original post-fix runs.
- **case1, case2** (unmodified converter): converted correctly, matching the
  original runs.
- **case3** (unmodified converter, the original drop case): the drop did
  **not** reproduce — both `fetch_token` and `fetch_and_parse_token` were
  converted this run. Like the Puppet equivalent, the original drop was
  nondeterministic: with no detection instruction in the analyze prompt,
  whether a custom resource survives depends on the LLM volunteering it. The
  fix makes detection instructed rather than left to chance.
- Side finding: when `--module-migration-plan` is passed as an absolute path,
  the module selector LLM sometimes answers with a repository-root-relative
  path (e.g. `cookbooks/nginx-multisite-case3`) instead of the plan's
  `Path: .`, and the run fails on path validation with no recovery. Passing
  the plan as a relative path (as `full-migrate` does) avoids it.

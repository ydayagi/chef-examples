#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: (c) 2024, x2a
# Apache-2.0 License

"""
Ansible module: company_app_conf

Manages entries in the proprietary CompanyApp configuration file format.
Each entry is a line of the form ``!key=value``. Comment lines (starting
with ``#``) and unparseable lines are preserved as-is.

Converted from Chef custom resource ``my_format``
(cookbooks/nginx-multisite/resources/my_format.rb).
"""

from __future__ import absolute_import, division, print_function
__metaclass__ = type

DOCUMENTATION = r"""
---
module: company_app_conf
short_description: Manage entries in a CompanyApp proprietary config file
description:
  - Manages C(!key=value) entries in a proprietary CompanyApp configuration
    file format.
  - Comment lines (starting with C(#)) and unparseable lines are preserved.
  - Supports upsert (C(state=present)) and removal (C(state=absent)).
  - Idempotent: the file is only written when the content would change.
options:
  path:
    description:
      - Path to the CompanyApp configuration file.
      - The file is created if it does not exist when C(state=present).
    type: str
    required: true
  entry:
    description:
      - Key name (without the leading C(!) prefix).
    type: str
    required: true
  value:
    description:
      - Value to set for the entry.
      - Required when C(state=present).
    type: str
    required: false
    default: null
  state:
    description:
      - C(present) to upsert the entry; C(absent) to remove it.
    type: str
    choices: [present, absent]
    default: present
author:
  - x2a migration
"""

EXAMPLES = r"""
- name: Set app_mode in company app config
  company_app_conf:
    path: /etc/company/app.conf
    entry: app_mode
    value: production
    state: present

- name: Set health_port in company app config
  company_app_conf:
    path: /etc/company/app.conf
    entry: health_port
    value: "8080"
    state: present

- name: Remove an entry from company app config
  company_app_conf:
    path: /etc/company/app.conf
    entry: deprecated_key
    state: absent
"""

RETURN = r"""
path:
  description: Path to the configuration file that was managed.
  returned: always
  type: str
  sample: /etc/company/app.conf
entry:
  description: The key name that was managed.
  returned: always
  type: str
  sample: app_mode
"""

import os

from ansible.module_utils.basic import AnsibleModule


def _parse_lines(raw_lines):
    """Return list of lines stripped of trailing newlines."""
    return [line.rstrip('\n').rstrip('\r') for line in raw_lines]


def _is_entry_line(line, entry):
    """Return True if *line* is a ``!<entry>=...`` line for the given key."""
    if not line.startswith('!'):
        return False
    rest = line[1:]
    key, sep, _value = rest.partition('=')
    return sep == '=' and key.strip() == entry


def run_module():
    module_args = dict(
        path=dict(type='str', required=True),
        entry=dict(type='str', required=True),
        value=dict(type='str', required=False, default=None),
        state=dict(type='str', default='present', choices=['present', 'absent']),
    )

    result = dict(changed=False, path='', entry='')

    module = AnsibleModule(argument_spec=module_args, supports_check_mode=True)

    path = module.params['path']
    entry = module.params['entry']
    value = module.params['value']
    state = module.params['state']

    result['path'] = path
    result['entry'] = entry

    if state == 'present' and value is None:
        module.fail_json(msg="'value' is required when state=present", **result)

    # Read existing content
    if os.path.exists(path):
        with open(path, 'r') as fh:
            lines = _parse_lines(fh.readlines())
    else:
        lines = []

    original_lines = list(lines)

    if state == 'present':
        # Remove any existing line for this entry
        lines = [line for line in lines if not _is_entry_line(line, entry)]
        # Append the new entry
        lines.append('!{}={}'.format(entry, value))
    else:  # state == 'absent'
        lines = [line for line in lines if not _is_entry_line(line, entry)]

    if lines == original_lines:
        # No change needed
        module.exit_json(**result)

    result['changed'] = True

    if not module.check_mode:
        # Ensure parent directory exists
        parent_dir = os.path.dirname(path)
        if parent_dir and not os.path.exists(parent_dir):
            os.makedirs(parent_dir)

        with open(path, 'w') as fh:
            for line in lines:
                fh.write(line + '\n')

    module.exit_json(**result)


def main():
    run_module()


if __name__ == '__main__':
    main()

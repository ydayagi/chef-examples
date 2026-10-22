resource_name :secret_setting
provides :secret_setting

property :setting_name, String, name_property: true
property :scope, String, default: 'node'

default_action :fetch

action :fetch do
  # Fetches a setting from the Company Secrets Platform via the internal gem
  # 'company_internal_lib' (not part of this cookbook). The gem handles the
  # platform connection, authentication, and encrypted transport; its API is
  # documented only in the internal wiki.
  require 'company_internal_lib'

  store = CompanyInternal::SettingsStore.new(scope: new_resource.scope)
  value = store.get(new_resource.setting_name)

  node.run_state[new_resource.setting_name] = value
end

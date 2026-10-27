resource_name :fetch_value
provides :fetch_value

property :value_url, String, required: true
property :fetched_value, String

action :fetch do
  require 'net/http'
  require 'uri'

  uri = URI.parse(new_resource.value_url)
  response = Net::HTTP.get_response(uri)

  new_resource.fetched_value = response.body
  node.run_state['fetched_value'] = response.body
end

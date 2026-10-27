resource_name :fetch_and_parse_value
provides :fetch_and_parse_value

property :value_url, String, required: true
property :parsed_value, String

action :fetch_and_parse do
  require 'net/http'
  require 'uri'

  uri = URI.parse(new_resource.value_url)
  response = Net::HTTP.get_response(uri)

  # Matches string pattern 'pattern1:pattern2' and captures pattern2
  if response.body =~ /pattern1:(.+)/
    parsed_value = Regexp.last_match(1).strip
    new_resource.parsed_value = parsed_value
    node.run_state['parsed_value'] = parsed_value
  else
    raise "Failed to parse value pattern from response body."
  end
end

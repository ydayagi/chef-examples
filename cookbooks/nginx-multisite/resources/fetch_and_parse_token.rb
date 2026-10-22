resource_name :fetch_and_parse_token
provides :fetch_and_parse_token

property :token_url, String, required: true
property :extracted_token, String

action :fetch_and_parse do
  require 'net/http'
  require 'uri'

  uri = URI.parse(new_resource.token_url)
  response = Net::HTTP.get_response(uri)

  # Matches a line like 'X-Header:value' and captures the value
  if response.body =~ /X-Header:(.+)/
    parsed_value = Regexp.last_match(1).strip
    new_resource.extracted_token = parsed_value
    node.run_state['extracted_token'] = parsed_value
  else
    raise "Failed to parse token pattern from response body."
  end
end

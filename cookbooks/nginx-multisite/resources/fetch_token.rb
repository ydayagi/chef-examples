resource_name :fetch_token
provides :fetch_token

property :auth_url, String, required: true
property :client_id, String, required: true
property :client_secret, String, required: true
property :access_token, String

action :fetch do
  require 'net/http'
  require 'json'
  require 'uri'

  uri = URI.parse(new_resource.auth_url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')

  request = Net::HTTP::Post.new(uri.path, { 'Content-Type' => 'application/json' })
  request.body = {
    client_id: new_resource.client_id,
    client_secret: new_resource.client_secret
  }.to_json

  response = http.request(request)
  payload = JSON.parse(response.body)

  new_resource.access_token = payload['access_token']
  node.run_state['access_token'] = payload['access_token']
end

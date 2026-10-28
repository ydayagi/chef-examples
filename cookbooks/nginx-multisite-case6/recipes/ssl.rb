package %w[openssl ca-certificates] do
  action :install
end

# Fetch SSL passphrase from CyberArk Conjur
ssl_passphrase = conjur_variable(node['cyberark']['conjur']['variable'])

group 'ssl-cert' do
  action :create
end

directory node['nginx']['ssl']['certificate_path'] do
  owner 'root'
  group 'root'
  mode '0755'
  action :create
end

directory node['nginx']['ssl']['private_key_path'] do
  owner 'root'
  group 'ssl-cert'
  mode '0710'
  action :create
end

node['nginx']['sites'].each do |site_name, config|
  next unless config['ssl_enabled']
  
  cert_file = "#{node['nginx']['ssl']['certificate_path']}/#{site_name}.crt"
  key_file = "#{node['nginx']['ssl']['private_key_path']}/#{site_name}.key"
  
  # Generate self-signed certificate for development
  execute "generate-ssl-cert-#{site_name}" do
    command <<-EOH
      openssl req -x509 -days 365 -newkey rsa:2048 \
        -keyout #{key_file} \
        -out #{cert_file} \
        -passout pass:#{ssl_passphrase} \
        -subj "/C=US/ST=Example/L=Example/O=Example Org/OU=IT/CN=#{site_name}/emailAddress=admin@example.com"
      chmod 640 #{key_file}
      chown root:ssl-cert #{key_file}
    EOH
    sensitive true
    not_if { ::File.exist?(cert_file) && ::File.exist?(key_file) }
    notifies :reload, 'service[nginx]', :delayed
  end
end
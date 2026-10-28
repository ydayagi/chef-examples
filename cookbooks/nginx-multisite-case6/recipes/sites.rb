node['nginx']['sites'].each do |site_name, config|
  template "/etc/nginx/sites-available/#{site_name}" do
    source 'site.conf.erb'
    variables(
      server_name: site_name,
      document_root: config['document_root'],
      ssl_enabled: config['ssl_enabled'],
      cert_file: "#{node['nginx']['ssl']['certificate_path']}/#{site_name}.crt",
      key_file: "#{node['nginx']['ssl']['private_key_path']}/#{site_name}.key"
    )
    mode '0644'
    notifies :reload, 'service[nginx]', :delayed
  end

  link "/etc/nginx/sites-enabled/#{site_name}" do
    to "/etc/nginx/sites-available/#{site_name}"
    action :create
    notifies :reload, 'service[nginx]', :delayed
  end
end

file '/etc/nginx/sites-enabled/default' do
  action :delete
  notifies :reload, 'service[nginx]', :delayed
end
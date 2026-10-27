package 'nginx' do
  action :install
end

template '/etc/nginx/nginx.conf' do
  source 'nginx.conf.erb'
  mode '0644'
  notifies :reload, 'service[nginx]', :delayed
end

template '/etc/nginx/conf.d/security.conf' do
  source 'security.conf.erb'
  mode '0644'
  notifies :reload, 'service[nginx]', :delayed
end

service 'nginx' do
  supports restart: true, reload: true, status: true
  action [:enable, :start]
end

node['nginx']['sites'].each do |site_name, config|
  directory config['document_root'] do
    owner 'www-data'
    group 'www-data'
    mode '0755'
    recursive true
    action :create
  end
  
  site_folder = site_name.split('.').first
  
  cookbook_file "#{config['document_root']}/index.html" do
    source "#{site_folder}/index.html"
    owner 'www-data'
    group 'www-data'
    mode '0644'
    action :create
  end
end
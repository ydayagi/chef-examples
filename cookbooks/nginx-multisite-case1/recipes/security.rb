package %w[fail2ban ufw] do
  action :install
end

service 'fail2ban' do
  action [:enable, :start]
end

template '/etc/fail2ban/jail.local' do
  source 'fail2ban.jail.local.erb'
  mode '0644'
  notifies :restart, 'service[fail2ban]', :delayed
end

execute 'ufw_default_deny' do
  command 'ufw --force default deny'
  not_if 'ufw status | grep -q "Default: deny"'
end

execute 'ufw_allow_ssh' do
  command 'ufw allow ssh'
  not_if 'ufw status | grep -q "22/tcp"'
end

execute 'ufw_allow_http' do
  command 'ufw allow http'
  not_if 'ufw status | grep -q "80/tcp"'
end

execute 'ufw_allow_https' do
  command 'ufw allow https'
  not_if 'ufw status | grep -q "443/tcp"'
end

execute 'ufw_enable' do
  command 'ufw --force enable'
  not_if 'ufw status | grep -q "Status: active"'
end

template '/etc/sysctl.d/99-security.conf' do
  source 'sysctl-security.conf.erb'
  mode '0644'
  notifies :run, 'execute[reload_sysctl]', :delayed
end

execute 'reload_sysctl' do
  command 'sysctl -p /etc/sysctl.d/99-security.conf'
  action :nothing
end

if node['security']['ssh']['disable_root']
  lineinfile '/etc/ssh/sshd_config' do
    line 'PermitRootLogin no'
    match '^#\?PermitRootLogin'
    notifies :restart, 'service[ssh]', :delayed
  end
end

if node['security']['ssh']['password_auth'] == false
  lineinfile '/etc/ssh/sshd_config' do
    line 'PasswordAuthentication no'
    match '^#\?PasswordAuthentication'
    notifies :restart, 'service[ssh]', :delayed
  end
end

service 'ssh' do
  action :nothing
end

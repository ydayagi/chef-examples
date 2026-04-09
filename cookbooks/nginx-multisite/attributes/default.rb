default['nginx']['sites'] = {
  'test.cluster.local' => {
    'document_root' => '/opt/server/test',
    'ssl_enabled' => true
  },
  'ci.cluster.local' => {
    'document_root' => '/opt/server/ci',
    'ssl_enabled' => true
  },
  'status.cluster.local' => {
    'document_root' => '/opt/server/status',
    'ssl_enabled' => true
  }
}

default['nginx']['ssl']['certificate_path'] = '/etc/ssl/certs'
default['nginx']['ssl']['private_key_path'] = '/etc/ssl/private'

# CyberArk Conjur - fetch SSL passphrase from vault instead of hardcoding
default['cyberark']['conjur']['appliance_url'] = 'https://conjur.example.com'
default['cyberark']['conjur']['account'] = 'myorg'
default['cyberark']['conjur']['variable'] = 'production/nginx/ssl_passphrase'

default['security']['fail2ban']['enabled'] = true
default['security']['ufw']['enabled'] = true
default['security']['ssh']['disable_root'] = true
default['security']['ssh']['password_auth'] = false
name             'nginx-multisite'
maintainer       'Chef Example'
maintainer_email 'admin@example.com'
license          'Apache-2.0'
description      'Configures nginx with multiple SSL-enabled subdomains'
version          '1.0.0'
chef_version     '>= 16.0'

supports 'ubuntu', '>= 18.04'
supports 'centos', '>= 7.0'

depends 'cyberark-conjur', '~> 3.0'
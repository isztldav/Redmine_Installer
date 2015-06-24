#!/usr/bin/env bash

VERSION="3.0"
MYSQLPASSWORD="asd123"

#### UPDATE AND PACKAGE
sudo apt-get update
#sudo apt-get -y upgrade
sudo apt-get -y install autoconf git subversion curl bison \
    imagemagick libmagickwand-dev build-essential libmariadbclient-dev libssl-dev \
    libreadline-dev libyaml-dev zlib1g-dev python-software-properties

#### GO HOME
cd ~

#### GIT RUBY
git clone git://github.com/sstephenson/rbenv.git .rbenv
git clone git://github.com/sstephenson/ruby-build.git ~/.rbenv/plugins/ruby-build

#### INSTALL RUBY
echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bash_profile
echo 'eval "$(rbenv init -)"' >> ~/.bash_profile
#exec $SHELL -l
source ~/.bash_profile


rbenv install 2.1.2
rbenv global 2.1.2

#### INSTALL REDMINE

svn co http://svn.redmine.org/redmine/branches/$VERSION-stable redmine
cd redmine
mkdir -p tmp/pids tmp/sockets public/plugin_assets
chmod -R 755 files log tmp public/plugin_assets

cat <<EOF >config/puma.rb
#!/usr/bin/env puma

# start puma with:
# RAILS_ENV=production bundle exec puma -C ./config/puma.rb

application_path = '/home/${USER}/redmine'
directory application_path
environment 'production'
daemonize true
pidfile "#{application_path}/tmp/pids/puma.pid"
state_path "#{application_path}/tmp/pids/puma.state"
stdout_redirect "#{application_path}/log/puma.stdout.log", "#{application_path}/log/puma.stderr.log"
bind "unix://#{application_path}/tmp/sockets/redmine.sock"
EOF

#### INSTALL MYSQL

sudo debconf-set-selections <<< 'mysql-server mysql-server/root_password password '$MYSQLPASSWORD
sudo debconf-set-selections <<< 'mysql-server mysql-server/root_password_again password '$MYSQLPASSWORD
sudo apt-get -y install mysql-server
mysql -u root -p$MYSQLPASSWORD -e "CREATE DATABASE redmine CHARACTER SET utf8;"
mysql -u root -p$MYSQLPASSWORD -e "CREATE USER 'redmine'@'localhost' IDENTIFIED BY '$MYSQLPASSWORD';"
mysql -u root -p$MYSQLPASSWORD -e "GRANT ALL PRIVILEGES ON redmine.* TO 'redmine'@'localhost';"
mysql -u root -p$MYSQLPASSWORD -e "\q"

cp config/database.yml.example config/database.yml
cat <<EOF >config/database.yml
production:
  adapter: mysql2
  database: redmine
  host: localhost
  username: redmine
  password: ${MYSQLPASSWORD}
  encoding: utf8
EOF

#### INSTALL GEMS
echo "gem: --no-ri --no-rdoc" >> ~/.gemrc
echo -e "# Gemfile.local\ngem 'puma'" >> Gemfile.local
gem install bundler
rbenv rehash
bundle install --without development test

RAILS_ENV=production rake db:migrate
RAILS_ENV=production REDMINE_LANG=en rake redmine:load_default_data
rake generate_secret_token

#### INIT

sudo touch /etc/init.d/redmine
cat <<EOF > redmineINIT

#! /bin/sh
### BEGIN INIT INFO
# Provides:          redmine
# Required-Start:    \$local_fs \$remote_fs \$network \$syslog
# Required-Stop:     \$local_fs \$remote_fs \$network $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Starts redmine with puma
# Description:       Starts redmine from /home/redmine/redmine.
### END INIT INFO


# Do NOT "set -e"

APP_USER=${USER}
APP_NAME=redmine
APP_ROOT="/home/\$APP_USER/\$APP_NAME"
RAILS_ENV=production

RBENV_ROOT="/home/\$APP_USER/.rbenv"
PATH="$RBENV_ROOT/bin:\$RBENV_ROOT/shims:$PATH"
SET_PATH="cd \$APP_ROOT; rbenv rehash"
DAEMON="bundle exec puma"
DAEMON_ARGS="-C \$APP_ROOT/config/puma.rb -e \$RAILS_ENV"
CMD="$SET_PATH; \$DAEMON \$DAEMON_ARGS"
NAME=redmine
DESC="Redmine Service"
PIDFILE="\$APP_ROOT/tmp/pids/puma.pid"
SCRIPTNAME="/etc/init.d/\$NAME"

cd $APP_ROOT || exit 1

sig () {
        test -s "\$PIDFILE" && kill -$1 \`cat \$PIDFILE\`
}

case \$1 in
  start)
        sig 0 && echo >&2 "Already running" && exit 0
        su - \$APP_USER -c "\$CMD"
        ;;
  stop)
        sig QUIT && exit 0
        echo >&2 "Not running"
        ;;
  restart|reload)
        sig USR2 && echo "Restarting" && exit 0
        echo >&2 "Couldn't restart"
        ;;
  status)
        sig 0 && echo >&2 "Running " && exit 0
        echo >&2 "Not running" && exit 1
        ;;
  *)
        echo "Usage: \$SCRIPTNAME {start|stop|restart|status}" >&2
        exit 1
        ;;
esac

:
EOF

sudo mv redmineINIT /etc/init.d/redmine
sudo chmod +x /etc/init.d/redmine
sudo update-rc.d redmine defaults
sudo service redmine start

#### NGINX
sudo touch /etc/nginx/sites-available/redmine

cat <<EOF >redmineNGINX
upstream puma_redmine {
  server unix:/home/${USER}/redmine/tmp/sockets/redmine.sock fail_timeout=0;
  #server 127.0.0.1:3000;
}

server {
  server_name localhost;
  listen 80;
  root /home/${USER}/redmine/public;

  location / {
    try_files \$uri/index.html \$uri.html \$uri @ruby;
  }

  location @ruby {
    proxy_set_header Host \$http_host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP  \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_redirect off;
    proxy_read_timeout 300;
    proxy_pass http://puma_redmine;
  }
}
EOF

sudo mv redmineNGINX /etc/nginx/sites-available/redmine
sudo ln -s /etc/nginx/sites-available/redmine /etc/nginx/sites-enabled/redmine
sudo unlink /etc/nginx/sites-enabled/default
sudo rm /etc/nginx/sites-available/default
sudo service nginx restart

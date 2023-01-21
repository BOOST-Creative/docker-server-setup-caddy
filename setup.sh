#! /bin/bash

# exit on error
set -e

# clear screen
clear

# variables
GREEN="\e[32m"
CYAN="\e[36m"
YELLOW="\e[33m"
ENDCOLOR="\e[0m"
REPO="BOOST-Creative/docker-server-setup"
CUR_TIMEZONE=$(timedatectl show | grep zone | sed 's/Timezone=//g');
MARIA_DB_ROOT_PASSWORD=$(< /dev/urandom tr -dc A-Z-a-z-0-9 | head -c"${1:-20}")
NPM_DB_PASSWORD=$(< /dev/urandom tr -dc A-Z-a-z-0-9 | head -c"${1:-20}")
KOPIA_PASSWORD=$(< /dev/urandom tr -dc A-Z-a-z-0-9 | head -c"${1:-10}")

# intro message
echo -e "${GREEN}Welcome! This script should be run as the root user on a new Debian or Ubuntu server.${ENDCOLOR}\n"

# change timezone (works on debian / ubuntu / fedora)
read -r -p "$(echo -e "The system time zone is ${YELLOW}$CUR_TIMEZONE${ENDCOLOR}. Do you want to change it (y/n)?${ENDCOLOR} ")" yn
if [[ $yn =~ ^[Yy]$ ]]; then
  if command -v dpkg-reconfigure &> /dev/null; then
    dpkg-reconfigure tzdata;
  else
    read -r -p "Enter time zone: " new_timezone;
    if timedatectl set-timezone "$new_timezone"; then
      echo -e "${GREEN}Time zone has changed to: $new_timezone ${ENDCOLOR}"
    else
      echo -e "Run ${CYAN}timedatectl list-timezones${ENDCOLOR} to view all time zones";
      exit;
    fi
  fi
fi

# create user account (works on debian / ubuntu / fedora)
read -r -p "$(echo -e "\nEnter username for the user to be created: ")" username
while [[ ! $username =~ ^[a-z][-a-z0-9]*$ ]]; do
  read -r -p "Invalid format. Enter username for the user to be created: " username
done
useradd -m -s /bin/bash "$username"
passwd "$username"
usermod -aG sudo "$username" || usermod -aG wheel "$username"

echo ""

# SSH port prompt
read -r -p "Which port do you want to use for SSH (not 6900-6905 please)? " ssh_port
while (( ssh_port < 1000 || ssh_port > 65000)); do
  read -r -p "Please use a number between 1000 and 65000: " ssh_port
done

# add ssh key
mkdir -p /home/"$username"/.ssh
# check if root has authorized_keys already
if [ -s /root/.ssh/authorized_keys ]
then
  cp /root/.ssh/authorized_keys /home/"$username"/.ssh/authorized_keys
else
  # if no keys, ask for key instead
  read -r -p "Please paste your public SSH key: " sshkey
  echo "$sshkey" >> /home/"$username"/.ssh/authorized_keys
fi
# fix permissions
chown -R "$username": /home/"$username"/.ssh

# add / update packages
echo -e "${CYAN}Updating system & packages...${ENDCOLOR}"

# kopia
curl -s https://kopia.io/signing-key | gpg --dearmor -o /usr/share/keyrings/kopia-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/kopia-keyring.gpg] http://packages.kopia.io/apt/ stable main" | tee /etc/apt/sources.list.d/kopia.list

# install docker
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh

# update system - apt update runs in docker script
apt upgrade -y
apt install git kopia apache2-utils unattended-upgrades -y

# unattended-upgrades
echo -e "${CYAN}Setting up unattended-upgrades...${ENDCOLOR}"
dpkg-reconfigure --priority=low unattended-upgrades

# docker stuff
echo -e "${CYAN}Setting up docker containers...${ENDCOLOR}"

# clone repo and copy files
rm -r /tmp/docker-server ||:
git clone --depth=1 "https://github.com/$REPO.git" /tmp/docker-server
mkdir -p /home/"$username"/server/fail2ban /home/"$username"/server/backups /home/"$username"/sites
cp -r /tmp/docker-server/fail2ban /home/"$username"/server/fail2ban/data
cp /tmp/docker-server/docker-compose.yml /home/"$username"/server/docker-compose.yml
cp /tmp/docker-server/firewall.sh /home/"$username"/firewall.sh
sed -i "s/REPLACE_ME/$ssh_port/" "/home/$username/firewall.sh"

# create docker networks
docker network create "$username"
docker network create database

# replace docker compose file with user input, and start
sed -i "s/CHANGE_TO_USERNAME/$username/" "/home/$username/server/docker-compose.yml"
sed -i "s/MARIA_DB_ROOT_PASSWORD/$MARIA_DB_ROOT_PASSWORD/" "/home/$username/server/docker-compose.yml"
sed -i "s/NPM_DB_PASSWORD/$NPM_DB_PASSWORD/" "/home/$username/server/docker-compose.yml"
sed -i "s/USER_UID/$(id -u $username)/" "/home/$username/server/docker-compose.yml"
sed -i "s/USER_GID/$(id -g $username)/" "/home/$username/server/docker-compose.yml"
sed -i "s|USER_TIMEZONE|$(timedatectl show | grep zone | sed 's/Timezone=//g')|" "/home/$username/server/docker-compose.yml"
docker compose -f /home/"$username"/server/docker-compose.yml up -d

# dummy logs so fail2ban doesn't shut down
mkdir -p /home/"$username"/server/npm/data/logs
touch /home/"$username"/server/npm/data/logs/proxy-host-{1..5}_access.log

# add custom http nginx config
# mkdir -p /home/"$username"/server/npm/data/nginx/custom
# cp /tmp/docker-server/nginx/http.conf /home/"$username"/server/npm/data/nginx/custom/http.conf

# fix permissions
chown "$username": /home/"$username"/sites /home/"$username"/server/docker-compose.yml /home/"$username"/firewall.sh
# nobody user bc that's what wp container uses
chown -R nobody:nogroup /home/"$username"/server/filebrowser

# add user to docker users
usermod -aG docker "$username"

# generate password file for kopia server
htpasswd -bc /root/kopiap.txt kopia "$KOPIA_PASSWORD" > /dev/null 2>&1

# make file for wp-fail2ban logs
touch "/home/$username/server/wp-fail2ban.log"

# set up automated jobs with systemd
cp /tmp/docker-server/systemd/* /etc/systemd/system
sed -i "s/USERNAME/$username/" /etc/systemd/system/kopiaServer.service

cp /tmp/docker-server/export_mariadb.sh /root/.export_mariadb.sh
chmod +x /root/.export_mariadb.sh
sed -i "s/USERNAME/$username/" /root/.export_mariadb.sh

systemctl daemon-reload
# systemd timer to reload fail2ban jail every six hours
systemctl start reloadFail2ban.timer
systemctl enable reloadFail2ban.timer > /dev/null 2>&1
# systemd timer to backup mariadb every day at 2am
systemctl start mariadbBackup.timer
systemctl enable mariadbBackup.timer > /dev/null 2>&1
# kopia server
systemctl start kopiaServer.service
systemctl enable kopiaServer.service > /dev/null 2>&1

# update SSH config
echo -e "\n${CYAN}Updating SSH config...${ENDCOLOR}"
{
  echo "Port $ssh_port" 
  echo "PermitRootLogin prohibit-password"
  echo "PubkeyAuthentication yes"
  echo "PasswordAuthentication no"
  echo "X11Forwarding no"
} >> /etc/ssh/sshd_config

echo -e "${CYAN}Restarting SSH daemon...${ENDCOLOR}\n"
systemctl restart sshd

# verify ssh key is correct
cat /home/"$username"/.ssh/authorized_keys
read -r -p "$(echo -e "\nIs the above SSH key(s) correct (y/n)? ")" ssh_correct
while [[ ! $ssh_correct =~ ^[Yy]$ ]]; do
  read -r -p "Please paste your public SSH key: " sshkey
  echo "$sshkey" >> /home/"$username"/.ssh/authorized_keys
  cat /home/"$username"/.ssh/authorized_keys
  read -r -p "$(echo -e "\nIs the above SSH key(s) correct (y/n)? ")" ssh_correct
done

# aliases / .bashrc stuff
{
  echo 'alias dcu="docker compose up -d"';
  echo 'alias dcd="docker compose down"';
  echo 'alias dcu="docker compose up -d"';
  echo 'alias dcr="docker compose restart"';
  echo 'alias boost="curl -s https://raw.githubusercontent.com/BOOST-Creative/docker-server-setup/main/boost.sh > ~/.boost.sh && chmod +x ~/.boost.sh && ~/.boost.sh"';
  echo 'alias ctop="docker run --rm -ti --name=ctop --volume /var/run/docker.sock:/var/run/docker.sock:ro quay.io/vektorlab/ctop:latest"';
  echo 'echo -e "\nPortainer: \e[34mhttp://localhost:6900\n\e[0mNginx Proxy Manager: \e[34mhttp://localhost:6901\n\e[0mphpMyAdmin: \e[34mhttp://localhost:6902\n\e[0mFile Browser: \e[34mhttp://localhost:6903\n\e[0mKopia: \e[34mhttp://localhost:6904\e[0m (kopia:'"$KOPIA_PASSWORD"')\nDozzle: \e[34mhttp://localhost:6905\n\n\e[0mRun ctop to manage containers and view metrics.\n"';
  echo 'type ~/firewall.sh &>/dev/null && ./firewall.sh';
} >> "/home/$username/.bashrc"

# Success Message
echo -e "\n${GREEN}Setup complete 👍. Please log back in as $username on port $ssh_port.${ENDCOLOR}"
echo -e "${GREEN}Firewall script will run on first login.${ENDCOLOR}"
echo -e "${GREEN}Update your SSH config file with the info below${ENDCOLOR}"

echo -e "\n\033[1m🚨\e[31m ENABLE HETZNER FIREWALL NOW 🚨${ENDCOLOR}\n"

echo "Host $(hostname)"
echo "    HostName $(curl -s ifconfig.me)"
echo "    Port $ssh_port"
echo "    User $username"
echo "    LocalForward 6900 127.0.0.1:6900"
echo "    LocalForward 6901 127.0.0.1:6901"
echo "    LocalForward 6902 127.0.0.1:6902"
echo "    LocalForward 6903 127.0.0.1:6903"
echo "    LocalForward 6904 127.0.0.1:6904"
echo "    LocalForward 6905 127.0.0.1:6905"
echo "    ServerAliveInterval 60"
echo -e "    ServerAliveCountMax 10\n"

# clean up script
rm ./setup.sh

# change timezone (works on debian / ubuntu / fedora)
read -r -p "$(echo -e "${YELLOW}Do you want to reboot now (y/n)?${ENDCOLOR} ")" yn
if [[ $yn =~ ^[Yy]$ ]]
then
  reboot;
fi


## BOOST setup script for Debian / Ubuntu servers

Run as root on a fresh installation. This is a specific setup for our org.

```bash
curl -s https://raw.githubusercontent.com/BOOST-Creative/docker-server-setup-caddy/main/setup.sh > setup.sh && chmod +x ./setup.sh && ./setup.sh
```

> [!IMPORTANT]
> fail2ban is disabled on this setup until we have time to work on normalizing proxied (ie cloudflare) and non-proxied IPs in caddy / fail2ban / iptables. We can't always control what clients are doing with their DNS. Recommended to use [solid security](https://wordpress.org/plugins/better-wp-security/) + [cloudflare turnstile](https://wordpress.org/plugins/simple-cloudflare-turnstile/) on wordpress and handle security for other services as needed (authelia, cloudflare waf and bot fight, etc).


### Hardens and configures system

- Creates non-root user with sudo and docker privileges.

- Updates packages and optionally enables unattended-upgrades.

- Changes SSH port and disables password login.

- Configures firewall to block ingress except on ports 80, 443, and your chosen SSH port.

- Fail2ban working out of the box to block malicious bot traffic to public web applications.

- Ensures the server is set to your preferred time zone.

- Adds aliases like `dcu` / `dcd` / `dcr` for docker compose up / down / restart.

### Installs docker, docker compose, and selected services

Besides Caddy, all services are tunneled through SSH and not publicly accessible. The following are installed by default:

- **[Caddy Docker Proxy](https://github.com/lucaslorentz/caddy-docker-proxy)** for publicly exposing services with automatic SSL.

- **[Fail2ban](https://github.com/crazy-max/docker-fail2ban)** needs to be updated to work w/ caddy logs but will work w/ wp-fail2ban.

- **[MariaDB database](https://hub.docker.com/r/linuxserver/mariadb)** for storing data.

- **[phpMyAdmin](https://hub.docker.com/r/linuxserver/phpmyadmin)** for graphical administration of the MariaDB database.

- **[File Browser](https://github.com/filebrowser/filebrowser)** for graphical file management.

- **[Watchtower](https://github.com/containrrr/watchtower)** to automatically update running containers to the latest image version.

- **[Dozzle](https://github.com/amir20/dozzle)** for browsing container logs.

- **[Kopia](https://github.com/kopia/kopia)** for backups.

These are defined and can be disabled in `~/server/docker-compose.yml`. (Except the Kopia server which is a systemd service.)

## boost command

The command `boost` runs a [helper script](https://github.com/BOOST-Creative/boost-server-cli) that automates a lot of repetitive tasks.

![CLI example gif](https://raw.githubusercontent.com/BOOST-Creative/boost-server-cli/main/assets/example.gif)

## Notes

There is a docker network with the same name as your username. If you create new containers in that that network, you can use caddy as a reverse proxy.

If you need to open a port for Wireguard or another service, [allow the port in iptables](https://www.digitalocean.com/community/tutorials/iptables-essentials-common-firewall-rules-and-commands) and run `sudo netfilter-persistent save` to save rules.

Individual MariaDB databases are automatically saved to disk each day for backup in `~/server/backups/mariadb`. To run the export job manually, use `/root/.export_mariadb.sh`.

To remove access for an SSH key, edit `~/.ssh/authorized_keys` and remove the line containing the key.

If you're running wordpress sites created via the `boost` command, wp-fail2ban events are logged to `~/server/wp-fail2ban.log`. This file is automatically monitored by the fail2ban container, and you can use it to review security related events. For example, use `grep "Accepted" ~/server/wp-fail2ban.log` to view succesful logins if you want to whitelist IPs. The timestamps in this file are unfortunately locked to GMT. If you know how to change the timezone for syslog in Alpine Linux, let me know.

## Working with Fail2ban

You can view logs for Fail2ban in Dozzle or by using `docker logs fail2ban`.

The jail is reloaded every six hours with a systemd timer to pick up log files from new proxy hosts.

Additional rules may be added to the container in `~/server/fail2ban`. Use the FORWARD chain (not INPUT or DOCKER-USER) and make sure the filter regex is using the NPM log format - `[Client <HOST>]`.

**Unban all IPs** If you get into a tricky situation.

```bash
docker exec fail2ban sh -c "fail2ban-client set npm-docker unbanip --all"
```

## Logs

You can view / search / download container logs with **[Dozzle](http://localhost:6905)**. For wordpress containers, this will show both nginx and php-fpm output.

## Cloudflare

Don't proxy through cloudflare if you're using wp-fail2ban. It will ban the proxy servers and screw things up.

Either don't proxy through cloudflare and use wp-fail2ban, or proxy through cloudflare and use [solid security](https://wordpress.org/plugins/better-wp-security/).
# setup_nginx_proxy.sh Documentation

## Overview

`setup_nginx_proxy.sh` is an interactive Bash script that automates the setup of an NGINX reverse proxy using Docker, with optional HTTPS support via Let's Encrypt. It is designed to work on macOS and Linux systems.

## Features

- Installs Docker if not present
- Creates a Docker network for NGINX and target containers
- Sets up NGINX as a reverse proxy for a specified domain
- Supports proxying to a host port or another Docker container
- Optionally serves static files from a custom directory
- Optionally enables HTTPS with Let's Encrypt certificates
- Handles certificate renewal

## Usage

Run the script in your terminal:

```bash
bash setup_nginx_proxy.sh
```

The script will prompt you for the following information:

1. **Docker Installation**: Installs Docker if not found.
2. **Remove Existing Container**: Optionally removes any existing NGINX container with the default or specified name.
3. **NGINX Container Name**: Enter a name for the NGINX container (default: `my-nginx`).
4. **Domain Name**: Enter the domain name to proxy (e.g., `example.com`).
5. **Target Type**: Choose whether to proxy to a host port or another Docker container.
   - If host: Enter the target port on the host.
   - If container: Enter the container name and target port.
6. **Custom Root Path**: Optionally specify a directory to serve static files. If left blank, a default welcome page is used.
7. **Enable HTTPS**: Optionally enable HTTPS with Let's Encrypt. If enabled, you will be prompted for your email and whether to use staging mode.

## What the Script Does

- Creates necessary directories for NGINX config and static files
- Sets up a Docker network (`ngxm-net`)
- Generates an NGINX config for your domain
- Runs the NGINX container with the appropriate mounts and network settings
- Validates the NGINX configuration
- Optionally obtains or renews Let's Encrypt certificates using Certbot
- Reloads NGINX with HTTPS configuration if enabled

## Requirements

- Bash shell
- Internet connection
- Sudo privileges (for Docker installation and certificate management)
- DNS for your domain must point to your server

## Notes

- The script uses `/etc/letsencrypt` and `/var/lib/letsencrypt` on the host for certificate storage.
- The script creates a default static site at `~/ngxm/public_html/nginx_default` if no custom root is specified.
- For HTTPS, port 80 and 443 must be open and accessible.

## Troubleshooting

- If you see errors about Docker or permissions, ensure your user is in the `docker` group and restart your shell.
- If Let's Encrypt fails, check that your domain's DNS is correct and ports 80/443 are open.

## License

MIT or as specified by the project.

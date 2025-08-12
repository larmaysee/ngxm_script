#!/usr/bin/env bash

# setup_nginx_proxy.sh
# This script performs a specific task based on the user's selection.
# Please review the code to understand its functionality and usage.

set -euo pipefail

# check if docker command available
# if not install docker
if ! command -v docker &> /dev/null; then
    # confirm user to install docker
    read -rp "Docker is not installed. Do you want to install it.? This will run curl -fsSL https://get.docker.com/ | sh (y/n): " INSTALL_DOCKER
    if [[ "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then
        echo "Installing Docker..."
        # install docker
        curl -fsSL https://get.docker.com/ | sh
        echo "Docker installed successfully."
    else
        echo "Docker installation aborted."
        exit 1
    fi
    
    usermod -aG docker $USER
    echo "User $USER added to the docker group."
    newgrp docker
    echo "Docker group activated."

    exit 0
fi


NGINX_NAME=${NGINX_NAME:-my-nginx}

NGINX_HOME="$HOME/ngxm"
CONF_DIR="$NGINX_HOME/conf.d"
CERT_DIR_HOST="/etc/letsencrypt"
VARLIB_HOST="/var/lib/letsencrypt"
DOCKER_NET="ngxm-net"
WEBROOT="$NGINX_HOME/public_html"
DEFAULT_PAGE="$WEBROOT/nginx_default/index.html"

mkdir -p "$CONF_DIR"
mkdir -p "$WEBROOT"
mkdir -p "$WEBROOT/nginx_default"

# Create a Docker network for container-to-container communication
docker network create "$DOCKER_NET" || true

# Ask for docker container remove or not
read -rp "Remove existing Docker container $NGINX_NAME? (y/n): " REMOVE_CONTAINER
if [[ "$REMOVE_CONTAINER" =~ ^[Yy]$ ]]; then
    if docker ps -a --format '{{.Names}}' | grep -q "$NGINX_NAME"; then
        docker stop "$NGINX_NAME" 2>/dev/null || true
        docker rm -f "$NGINX_NAME" 2>/dev/null || true
    fi
fi

# Ask for nginx container name
read -rp "Enter container name for NGINX (default: $NGINX_NAME): " INPUT_NAME
NGINX_NAME="${INPUT_NAME:-$NGINX_NAME}"

# Ask for domain name
read -rp "Enter your domain name: " DOMAIN

# Ask for target type
read -rp "Is your target running on [h]ost or [c]ontainer? " TARGET_TYPE
if [[ "$TARGET_TYPE" =~ ^[Hh]$ ]]; then
    read -rp "Enter target port on host: " TARGET_PORT
    UPSTREAM_URL="host.docker.internal:$TARGET_PORT"
    ADD_HOST_FLAG="--add-host=host.docker.internal:host-gateway"
else
    read -rp "Enter container name: " CONTAINER_NAME
    read -rp "Enter target port: " TARGET_PORT
    docker network connect "$DOCKER_NET" "$CONTAINER_NAME" || true
    UPSTREAM_URL="$CONTAINER_NAME:$TARGET_PORT"
    ADD_HOST_FLAG=""
fi

# Ask for custom root path for static site
read -rp "Specify custom root path for HTTP (leave blank for default welcome page): " CUSTOM_ROOT
if [[ -z "$CUSTOM_ROOT" ]]; then
    # Use default welcome page
    CUSTOM_ROOT="$WEBROOT/nginx_default"
    mkdir -p "$CUSTOM_ROOT"
    echo "<h1>Welcome to $DOMAIN via NGINX Proxy</h1>" > "$CUSTOM_ROOT/index.html"
    ROOT_PATH="/var/www/html/nginx_default"
    STATIC_MOUNT="-v $CUSTOM_ROOT:$ROOT_PATH"
elif [[ -d "$CUSTOM_ROOT" ]]; then
    # Use user specified directory
    FOLDER_NAME=$(basename "$CUSTOM_ROOT")
    ROOT_PATH="/var/www/html/$FOLDER_NAME"
    STATIC_MOUNT="-v $CUSTOM_ROOT:$ROOT_PATH"
else
    echo "❌ Error: Custom root path '$CUSTOM_ROOT' does not exist."
    exit 1
fi

# Ask for https
read -rp "Enable HTTPS with Let's Encrypt now? (y/n): " USE_HTTPS

# HTTP config
cat > "$CONF_DIR/$DOMAIN.conf" <<NGINXCONF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        root $ROOT_PATH;
        index index.html;
        try_files \$uri @proxy;
    }
    location @proxy {
        proxy_pass http://$UPSTREAM_URL;

        # WebSocket headers
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXCONF

# Run nginx in HTTP mode first
docker rm -f "$NGINX_NAME" 2>/dev/null || true
docker run -d \
  --name "$NGINX_NAME" \
  --restart unless-stopped \
  --network "$DOCKER_NET" \
  $ADD_HOST_FLAG \
  -p 80:80 -p 443:443 \
  -v "$CONF_DIR":/etc/nginx/conf.d \
  -v "$CERT_DIR_HOST":"$CERT_DIR_HOST" \
  -v "$VARLIB_HOST":"$VARLIB_HOST" \
  -v "$NGINX_HOME/www":/var/www/certbot \
  $STATIC_MOUNT \
  nginx:latest

echo "✅ HTTP reverse proxy set up for $DOMAIN → localhost:$TARGET_PORT"

# Test nginx config
NGINX_TEST_OUTPUT=$(docker exec "$NGINX_NAME" nginx -t 2>&1)
if [[ $? -eq 0 ]]; then
    echo "✅ NGINX configuration is valid"
    docker exec "$NGINX_NAME" nginx -s reload
else
    echo "❌ NGINX configuration is invalid"
    echo "$NGINX_TEST_OUTPUT"
    exit 1
fi

echo "⏳ Waiting for DNS to propagate..."
sleep 5

if ! curl -s "http://$DOMAIN/.well-known/acme-challenge/test" >/dev/null; then
    echo "⚠️ Could not reach $DOMAIN over HTTP. Certbot may fail."
    exit 1
fi

if [[ "$USE_HTTPS" =~ ^[Yy]$ ]]; then
    read -rp "Enter your email for Let's Encrypt: " EMAIL
    read -rp "Use Let's Encrypt staging mode? (y/n): " USE_STAGING
    STAGING_FLAG=""
    if [[ "$USE_STAGING" =~ ^[Yy]$ ]]; then
        STAGING_FLAG="--staging"
    fi

    # Check if certificates already exist
    if [ -d "$CERT_DIR_HOST/live/$DOMAIN" ]; then
        echo "✅ Certificates already exist for $DOMAIN"
        read -rp "Do you want to renew the certificates? (y/n): " RENEW_CERTS
        if [[ "$RENEW_CERTS" =~ ^[Yy]$ ]]; then
            echo "🔄 Renewing certificates for $DOMAIN"
            CERTBOT_ACTION="renew"
        else
            echo "✅ Skipping certificate renewal for $DOMAIN"
            CERTBOT_ACTION=""
        fi
    else
        echo "⚠️ No certificates found for $DOMAIN"
        CERTBOT_ACTION="issue"
    fi

    if [[ "$CERTBOT_ACTION" == "renew" ]]; then
        docker run --rm -it \
          -v "$CERT_DIR_HOST":"$CERT_DIR_HOST" \
          -v "$VARLIB_HOST":"$VARLIB_HOST" \
          -v "$NGINX_HOME/www":/var/www/certbot \
          certbot/certbot renew $STAGING_FLAG
    elif [[ "$CERTBOT_ACTION" == "issue" ]]; then
        docker run --rm -it \
          -v "$CERT_DIR_HOST":"$CERT_DIR_HOST" \
          -v "$VARLIB_HOST":"$VARLIB_HOST" \
          -v "$NGINX_HOME/www":/var/www/certbot \
          certbot/certbot certonly \
            --webroot --webroot-path=/var/www/certbot \
            $STAGING_FLAG \
            --email "$EMAIL" --agree-tos --no-eff-email \
            -d "$DOMAIN"
    fi

    # HTTPS config
    cat > "$CONF_DIR/$DOMAIN.conf" <<NGINXSSL
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    location / {
        root $ROOT_PATH;
        index index.html;
        try_files \$uri @proxy;
    }
    location @proxy {
        proxy_pass http://$UPSTREAM_URL;

        # WebSocket headers
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXSSL

    docker exec "$NGINX_NAME" nginx -s reload
    echo "✅ HTTPS reverse proxy set up for $DOMAIN → localhost:$TARGET_PORT"
fi
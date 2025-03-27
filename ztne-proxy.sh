#!/bin/bash

set -e

PROJECT_DIR="$HOME/ztne-proxy"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Check and install cloudflared if not found
if ! command -v cloudflared &> /dev/null; then
  echo "[+] Installing cloudflared CLI..."
  sudo curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
  sudo chmod +x /usr/local/bin/cloudflared
fi

# Step 1: Log in to Cloudflare and get origin cert
if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
  echo "[+] Logging into Cloudflare. This will open a browser window."
  cloudflared login
else
  echo "[✓] Already authenticated with Cloudflare. Skipping login."
fi

# Step 2: Ask for tunnel name
read -p "Enter a name for your tunnel: " TUNNEL_NAME

# Check if tunnel already exists
if cloudflared tunnel list | awk '{print $2}' | grep -q "^$TUNNEL_NAME$"; then
  echo "[!] Tunnel with name '$TUNNEL_NAME' already exists."
  read -p "Do you want to continue using this existing tunnel? (y/n): " USE_EXISTING
  if [[ "$USE_EXISTING" =~ ^[Yy]$ ]]; then
    echo "[✓] Using existing tunnel '$TUNNEL_NAME'."
  else
    echo "[-] Aborting setup. Please choose a different tunnel name."
    exit 1
  fi
else
  cloudflared tunnel create "$TUNNEL_NAME"
fi

# Step 3: Ask for hostname
read -p "Enter the hostname (e.g. npm.example.com): " HOSTNAME

# Step 4: Ask which port to expose through tunnel (80, 443, or both)
echo "Which port do you want to expose through the tunnel?"
echo "1) Port 80 (HTTP)"
echo "2) Port 443 (HTTPS)"
echo "3) Both 80 and 443"
read -p "Enter your choice (1/2/3): " PORT_CHOICE

case $PORT_CHOICE in
  1)
    TARGET_PORT=80
    ;;
  2)
    TARGET_PORT=443
    ;;
  3)
    TARGET_PORT=both
    ;;
  *)
    echo "Invalid choice. Defaulting to port 80."
    TARGET_PORT=80
    ;;
esac

# Step 5: Get tunnel ID and copy correct credentials file
TUNNEL_ID=$(cloudflared tunnel list | awk -v name="$TUNNEL_NAME" '$2 == name {print $1}')
CRED_SRC_FILE="$HOME/.cloudflared/$TUNNEL_ID.json"
CLOUD_FOLDER="$PROJECT_DIR/cloudflared"
mkdir -p "$CLOUD_FOLDER"
cp "$CRED_SRC_FILE" "$CLOUD_FOLDER/$TUNNEL_NAME.json"
cp "$HOME/.cloudflared/cert.pem" "$CLOUD_FOLDER/cert.pem"

# Step 6: Create config.yml
cat > "$CLOUD_FOLDER/config.yml" <<EOF
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/$TUNNEL_NAME.json

ingress:
EOF

if [[ "$TARGET_PORT" == "80" || "$TARGET_PORT" == "both" ]]; then
  echo "  - hostname: $HOSTNAME" >> "$CLOUD_FOLDER/config.yml"
  echo "    service: http://npm:80" >> "$CLOUD_FOLDER/config.yml"
fi

if [[ "$TARGET_PORT" == "443" || "$TARGET_PORT" == "both" ]]; then
  echo "  - hostname: $HOSTNAME" >> "$CLOUD_FOLDER/config.yml"
  echo "    service: https://npm:443" >> "$CLOUD_FOLDER/config.yml"
fi

echo "  - service: http_status:404" >> "$CLOUD_FOLDER/config.yml"

# Step 7: Create DNS record in Cloudflare
echo "[+] Creating DNS record for $HOSTNAME pointing to tunnel..."
cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME"

# Step 8: Create docker-compose.yml
cat > "$PROJECT_DIR/docker-compose.yml" <<COMPOSE
version: '3.8'

services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --config /etc/cloudflared/config.yml run
    environment:
      - TUNNEL_ORIGIN_CERT=/etc/cloudflared/cert.pem
    volumes:
      - ./cloudflared:/etc/cloudflared
COMPOSE

# Step 9: Start containers
echo "[+] Starting your services with Docker Compose..."
docker-compose up -d

# Final instructions
echo "[✓] Setup complete!"
echo "Access your Nginx Proxy Manager UI at: http://$HOSTNAME"
echo "Default credentials: admin@example.com / changeme"
echo "A DNS record for $HOSTNAME has been created in your Cloudflare zone."

#!/bin/bash
# Outline WebSocket + Nginx Setup

set -e

echo "=== Enter installation data ==="
read -p "Enter your domain (e.g., vpn.example.com): " DOMAIN
read -p "Enter email for SSL certificates: " EMAIL

OUTLINE_PATH="ws$(openssl rand -hex 12)"
BASE_PORT=17543

echo ""
echo "=== Installing dependencies ==="
apt update
apt install -y nginx-light python3 python3-dev python3-venv libaugeas-dev gcc curl jq qrencode

echo "=== Installing Certbot ==="
python3 -m venv /opt/certbot/
/opt/certbot/bin/pip install --upgrade pip
/opt/certbot/bin/pip install certbot
ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

echo "=== Obtaining SSL certificate (stopping nginx) ==="
# Stopping nginx for certificate acquisition
systemctl stop nginx

# Obtaining certificate
certbot certonly --standalone \
    -d $DOMAIN \
    --email $EMAIL \
    --non-interactive \
    --agree-tos \
    --preferred-challenges http

# Starting nginx back
systemctl start nginx

echo "=== Installing Outline Server ==="
mkdir -p /opt/outline
cd /opt/outline
wget -q https://github.com/Jigsaw-Code/outline-ss-server/releases/download/v1.9.2/outline-ss-server_1.9.2_linux_x86_64.tar.gz
tar -xf outline-ss-server_1.9.2_linux_x86_64.tar.gz
rm outline-ss-server_1.9.2_linux_x86_64.tar.gz

echo "=== Creating server configuration ==="
cat > config.yaml <<EOF
web:
  servers:
    - id: server1
      listen:
        - "127.0.0.1:$BASE_PORT"

services:
  - listeners:
      - type: websocket-stream
        web_server: server1
        path: "/$OUTLINE_PATH/tcp"
      - type: websocket-packet
        web_server: server1
        path: "/$OUTLINE_PATH/udp"
EOF

echo "=== Configuring Nginx ==="
cat > /etc/nginx/conf.d/outline.conf <<EOF
upstream outline {
    server localhost:$BASE_PORT;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;

    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # WebSocket for Outline
    location /$OUTLINE_PATH/ {
        proxy_pass http://outline;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # Config files
    location ~ ^/outline-config-[a-f0-9]+\.txt$ {
        root /var/www/html/outline;
        try_files \$uri =404;
        add_header Content-Type text/plain;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    location / {
        return 200 'Outline VPN Server\\nWebSocket: /$OUTLINE_PATH/';
        add_header Content-Type text/plain;
    }
}
EOF

mkdir -p /var/www/html/outline
systemctl restart nginx

echo "=== Configuring systemd service ==="
cat > /etc/systemd/system/outline-websocket.service <<EOF
[Unit]
Description=Outline WebSocket Server
After=network.target nginx.service

[Service]
Type=simple
WorkingDirectory=/opt/outline
ExecStart=/opt/outline/outline-ss-server --config /opt/outline/config.yaml --replay_history 10000
Restart=on-failure
RestartSec=5
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable outline-websocket

echo "=== Creating management scripts ==="

# outline-addkey
cat > /usr/local/bin/outline-addkey <<'EOF'
#!/bin/bash
if [ -z "$1" ]; then
    echo "Usage: outline-addkey <device_name>"
    exit 1
fi

DEVICE_NAME="$1"
CONFIG_FILE="/opt/outline/config.yaml"
WEB_DIR="/var/www/html/outline"

# Getting data
DOMAIN=$(grep -m1 "server_name" /etc/nginx/conf.d/outline.conf | awk '{print $2}' | tr -d ';')
OUTLINE_PATH=$(grep -m1 "path:" "$CONFIG_FILE" | awk -F'"' '{print $2}' | cut -d'/' -f2)

# Generating data
KEY_ID="key_$(openssl rand -hex 4)"
KEY_SECRET=$(openssl rand -hex 16)
CONFIG_HASH=$(echo -n "$KEY_SECRET$DEVICE_NAME" | sha256sum | cut -c1-8)
CONFIG_FILENAME="outline-config-$CONFIG_HASH.txt"
CONFIG_PATH="$WEB_DIR/$CONFIG_FILENAME"

echo "Adding key for: $DEVICE_NAME"

# 1. Finding where to add keys:
# Looking for line with "listeners:" and adding keys: after the listeners block ends
if ! grep -q "keys:" "$CONFIG_FILE"; then
    # Finding line after listeners block (after 4 lines)
    LINE_NUM=$(grep -n "listeners:" "$CONFIG_FILE" | head -1 | cut -d: -f1)
    if [ -n "$LINE_NUM" ]; then
        # Adding after 5 lines (AFTER two listeners)
        INSERT_LINE=$((LINE_NUM + 5))
        sed -i "${INSERT_LINE}a\    keys:" "$CONFIG_FILE"  # ← 'a' instead of 'i' to insert AFTER
    fi
fi


# 2. Adding the key
tee -a "$CONFIG_FILE" > /dev/null <<EOL
      - id: '$KEY_ID'
        cipher: chacha20-ietf-poly1305
        secret: $KEY_SECRET
        name: "$DEVICE_NAME"
EOL

# 3. Creating client config
mkdir -p "$WEB_DIR"
tee "$CONFIG_PATH" > /dev/null <<EOL
transport:
  \$type: tcpudp

  tcp:
    \$type: shadowsocks
    endpoint:
      \$type: websocket
      url: wss://$DOMAIN/$OUTLINE_PATH/tcp
    cipher: chacha20-ietf-poly1305
    secret: $KEY_SECRET

  udp:
    \$type: shadowsocks
    endpoint:
      \$type: websocket
      url: wss://$DOMAIN/$OUTLINE_PATH/udp
    cipher: chacha20-ietf-poly1305
    secret: $KEY_SECRET
EOL

# 4. Restarting
systemctl restart outline-websocket
sleep 2

echo ""
echo "✅ Key added!"
echo "   Device: $DEVICE_NAME"
echo "   File: $CONFIG_FILENAME"
echo "   Link: ssconf://$DOMAIN/$CONFIG_FILENAME"
echo ""
echo "📱 QR code:"
echo "ssconf://$DOMAIN/$CONFIG_FILENAME" | qrencode -t ansiutf8 2>/dev/null || echo "Install qrencode: apt install qrencode"
EOF

# outline-removekey
cat > /usr/local/bin/outline-removekey <<'EOF'
#!/bin/bash
if [ -z "$1" ]; then
    echo "Usage: outline-removekey <filename>"
    ls -1 /var/www/html/outline/*.txt 2>/dev/null | xargs -I {} basename {}
    exit 1
fi

CONFIG_FILENAME="$1"
CONFIG_FILE="/opt/outline/config.yaml"
WEB_DIR="/var/www/html/outline"
FULL_PATH="$WEB_DIR/$CONFIG_FILENAME"

if [ ! -f "$FULL_PATH" ]; then
    echo "❌ File not found"
    exit 1
fi

SECRET=$(grep "secret:" "$FULL_PATH" | head -1 | awk '{print $2}')
if [ -z "$SECRET" ]; then
    echo "❌ Could not find secret key"
    exit 1
fi

LINE_NUM=$(grep -n "secret: $SECRET" "$CONFIG_FILE" | head -1 | cut -d: -f1)

if [ -n "$LINE_NUM" ]; then
    START_LINE=$((LINE_NUM - 3))
    if [ "$START_LINE" -ge 1 ]; then
        sed -i "${START_LINE},${LINE_NUM}d" "$CONFIG_FILE"
    fi
    
    if grep -q "keys:" "$CONFIG_FILE" && ! grep -A1 "keys:" "$CONFIG_FILE" | grep -q "^\s\{6\}- id:"; then
        sed -i '/keys:/d' "$CONFIG_FILE"
    fi
fi

rm -f "$FULL_PATH"
systemctl restart outline-websocket

echo "✅ Key removed: $CONFIG_FILENAME"
EOF

# outline-listkeys
cat > /usr/local/bin/outline-listkeys <<'EOF'
#!/bin/bash
CONFIG_FILE="/opt/outline/config.yaml"
WEB_DIR="/var/www/html/outline"
DOMAIN=$(grep -m1 "server_name" /etc/nginx/conf.d/outline.conf | awk '{print $2}' | tr -d ';')

echo "📋 Outline keys:"
echo "================="

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config not found"
    exit 1
fi

if grep -q "keys:" "$CONFIG_FILE"; then
    awk '
    /keys:/ { in_keys=1; next }
    in_keys && /^[[:space:]]{6}- id:/ {
        id = $3
        gsub(/\x27/, "", id)
        getline
        getline
        secret = $2
        getline
        if ($0 ~ /name: "/) {
            name = substr($0, index($0, "\"")+1)
            sub(/"$/, "", name)
        } else {
            name = $2
        }
        
        cmd = "grep -l " secret " /var/www/html/outline/*.txt 2>/dev/null"
        cmd | getline config_file
        close(cmd)
        
        if (config_file) {
            filename = gensub(/.*\//, "", "g", config_file)
            print "Device: " name
            print "File: " filename
            print "Link: ssconf://'$DOMAIN'/" filename
            print "---"
        }
    }
    ' "$CONFIG_FILE"
else
    echo "No keys"
fi

echo ""
echo "Configuration files:"
ls -1 "$WEB_DIR"/*.txt 2>/dev/null || echo "  No files"
EOF

chmod +x /usr/local/bin/outline-addkey
chmod +x /usr/local/bin/outline-listkeys
chmod +x /usr/local/bin/outline-removekey

echo "=== Setting up automatic certificate renewal ==="
echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook \"systemctl reload nginx\"" > /etc/cron.d/certbot-renew

echo "=== Starting service ==="
systemctl start outline-websocket

echo ""
echo "=============================================="
echo "✅ INSTALLATION COMPLETED!"
echo "=============================================="
echo "Domain: https://$DOMAIN"
echo "WebSocket path: /$OUTLINE_PATH/"
echo ""
echo "🛠️ Commands:"
echo "outline-addkey 'Device Name'  - Add key (with QR)"
echo "outline-listkeys              - List keys"
echo "outline-removekey <file>      - Remove key"
echo "=============================================="

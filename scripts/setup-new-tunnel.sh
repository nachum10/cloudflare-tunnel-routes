#!/usr/bin/env bash
# One-time setup of a new Cloudflare tunnel on a fresh machine/account.
# Usage: setup-new-tunnel.sh <tunnel-name>
#
# Performs:
#   1. cloudflared login (opens browser)
#   2. cloudflared tunnel create <name>
#   3. Writes a starter config.yml with only the catch-all 404
#   4. Optionally installs as systemd service

set -eu

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <tunnel-name>"
    echo "Example: $0 my-server"
    exit 1
fi

tunnel_name="$1"

if ! command -v cloudflared >/dev/null 2>&1; then
    cat <<EOF >&2
ERROR: cloudflared not installed.

Install instructions:
  Linux:   https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
  macOS:   brew install cloudflared
  Windows: winget install --id Cloudflare.cloudflared

EOF
    exit 1
fi

# Step 1: Login (opens browser; idempotent if already logged in)
if [ ! -f "$HOME/.cloudflared/cert.pem" ] && [ ! -f "/etc/cloudflared/cert.pem" ]; then
    echo "==> Logging in to Cloudflare (browser will open)..."
    cloudflared tunnel login
else
    echo "==> Already authenticated (cert.pem exists)."
fi

# Step 2: Create tunnel
echo "==> Creating tunnel '$tunnel_name'..."
create_output="$(cloudflared tunnel create "$tunnel_name" 2>&1)" || {
    if echo "$create_output" | grep -qi "already exists"; then
        echo "    Tunnel '$tunnel_name' already exists."
    else
        echo "ERROR: $create_output" >&2
        exit 1
    fi
}
echo "$create_output"

# Step 3: Get tunnel ID + credentials path
tunnel_id="$(cloudflared tunnel list -o json 2>/dev/null \
    | grep -B1 -A1 "\"name\":\"$tunnel_name\"" \
    | grep '"id"' | head -1 | cut -d'"' -f4)"

if [ -z "$tunnel_id" ]; then
    # Fallback: parse from text output
    tunnel_id="$(cloudflared tunnel list 2>/dev/null | awk -v n="$tunnel_name" '$2 == n {print $1}')"
fi

if [ -z "$tunnel_id" ]; then
    echo "ERROR: Could not determine tunnel ID for '$tunnel_name'" >&2
    exit 1
fi

credentials_file="$HOME/.cloudflared/${tunnel_id}.json"
echo "==> Tunnel ID: $tunnel_id"
echo "==> Credentials: $credentials_file"

# Step 4: Write starter config
config_path="$HOME/.cloudflared/config.yml"
if [ -f "$config_path" ]; then
    backup="${config_path}.bak.$(date +%Y%m%d-%H%M%S)"
    echo "==> Existing config found; backing up to $backup"
    cp "$config_path" "$backup"
else
    echo "==> Writing starter config to $config_path"
    cat > "$config_path" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${credentials_file}
ingress:
  - service: http_status:404
EOF
fi

# Step 5: Optionally install as systemd service (Linux only)
if [ "$(uname)" = "Linux" ] && command -v systemctl >/dev/null 2>&1; then
    echo
    read -r -p "Install cloudflared as a systemd service? [y/N] " ans
    if [ "${ans,,}" = "y" ]; then
        # systemd service runs as root and reads /etc/cloudflared/config.yml
        sudo mkdir -p /etc/cloudflared
        sudo cp "$config_path" /etc/cloudflared/config.yml
        sudo cp "$credentials_file" /etc/cloudflared/
        sudo cloudflared service install
        sudo systemctl enable --now cloudflared
        echo "==> Service installed. Status:"
        sudo systemctl status cloudflared --no-pager -n 5
    fi
fi

cat <<EOF

==> Setup complete!

Add your first route:
  add-route.sh app.yourdomain.com 8080

EOF

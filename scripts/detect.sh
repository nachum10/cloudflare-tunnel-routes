#!/usr/bin/env bash
# Detect cloudflared installation and active tunnel configuration.
# Outputs key=value lines for easy parsing by other scripts.
# Exit 0 if a tunnel is detected, 1 if not.

set -u

found_binary=""
found_config=""
found_tunnel_id=""
found_credentials=""
needs_sudo="false"
service_mode="unknown"  # systemd|manual|none

# 1) Locate cloudflared binary
if command -v cloudflared >/dev/null 2>&1; then
    found_binary="$(command -v cloudflared)"
fi

# 2) Locate config file (check standard locations in order)
candidate_configs=(
    "/etc/cloudflared/config.yml"
    "/etc/cloudflared/config.yaml"
    "$HOME/.cloudflared/config.yml"
    "$HOME/.cloudflared/config.yaml"
)
for cfg in "${candidate_configs[@]}"; do
    if [ -f "$cfg" ]; then
        found_config="$cfg"
        break
    fi
done

# 3) Determine if sudo needed for the config file
if [ -n "$found_config" ]; then
    if [ ! -w "$found_config" ]; then
        needs_sudo="true"
    fi
fi

# 4) Extract tunnel ID and credentials path from config
if [ -n "$found_config" ]; then
    reader="cat"
    if [ "$needs_sudo" = "true" ]; then
        reader="sudo cat"
    fi
    found_tunnel_id="$($reader "$found_config" 2>/dev/null | grep -E '^tunnel:' | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")"
    found_credentials="$($reader "$found_config" 2>/dev/null | grep -E '^credentials-file:' | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")"
fi

# 5) Determine how cloudflared is being managed
if systemctl list-unit-files 2>/dev/null | grep -qE '^cloudflared\.service'; then
    service_mode="systemd"
elif pgrep -f "cloudflared.*tunnel.*run" >/dev/null 2>&1; then
    service_mode="manual"
else
    service_mode="none"
fi

# Output
echo "binary=${found_binary}"
echo "config=${found_config}"
echo "tunnel_id=${found_tunnel_id}"
echo "credentials=${found_credentials}"
echo "needs_sudo=${needs_sudo}"
echo "service_mode=${service_mode}"

# Exit code: success only if we have binary + config + tunnel_id
if [ -n "$found_binary" ] && [ -n "$found_config" ] && [ -n "$found_tunnel_id" ]; then
    exit 0
else
    exit 1
fi

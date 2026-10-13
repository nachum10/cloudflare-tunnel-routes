#!/usr/bin/env bash
# One-time setup of a new Cloudflare tunnel on a fresh machine/account.
# Usage: setup-new-tunnel.sh <tunnel-name> [--yes]
#
# Performs:
#   1. cloudflared login (opens browser)
#   2. cloudflared tunnel create <name>
#   3. Writes a starter config.yml with only the catch-all 404
#      (never over an existing one)
#   4. Optionally installs as systemd service (prompt, or --yes)
#
# Exit status: 0 = done, 1 = failed,
#              3 = tunnel ready but an existing config.yml was left alone -
#                  follow the printed steps to point it at the new tunnel.

set -eu
export LC_ALL=C

assume_yes="false"
tunnel_name=""
for arg in "$@"; do
    case "$arg" in
        --yes|-y) assume_yes="true" ;;
        -*) echo "Unknown argument: $arg" >&2; exit 1 ;;
        *)
            if [ -n "$tunnel_name" ]; then
                echo "Unexpected extra argument: $arg" >&2; exit 1
            fi
            tunnel_name="$arg"
            ;;
    esac
done

if [ -z "$tunnel_name" ]; then
    echo "Usage: $0 <tunnel-name> [--yes]"
    echo "Example: $0 my-server"
    echo "  --yes  install the systemd service without asking (non-interactive)"
    exit 1
fi

# The name reaches cloudflared argv, a JSON comparison and log lines.
if ! [[ "$tunnel_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
    echo "ERROR: invalid tunnel name: $tunnel_name" >&2
    echo "       Allowed: letters, digits, '.', '_', '-' (start with a letter or digit, max 63)." >&2
    exit 1
fi

# Where the systemd service reads its config. Overridable ONLY so the test
# suite can point it into a scratch dir - not a supported setting.
etc_dir="${CFTR_SYSTEM_DIR:-/etc/cloudflared}"

if ! command -v cloudflared >/dev/null 2>&1; then
    cat <<EOF >&2
ERROR: cloudflared not installed.

Install instructions:
  Linux:   https://pkg.cloudflare.com/  (official apt/yum repositories)
  macOS:   brew install cloudflared
  Other:   https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/

EOF
    exit 1
fi

uuid_re='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

# Step 1: Login (opens browser; idempotent if already logged in)
if [ ! -f "$HOME/.cloudflared/cert.pem" ] && [ ! -f "$etc_dir/cert.pem" ]; then
    echo "==> Logging in to Cloudflare (browser will open)..."
    cloudflared tunnel login
else
    echo "==> Already authenticated (cert.pem exists)."
fi

# Step 2: Create tunnel. Its output ends with
#   "Created tunnel <name> with id <uuid>"
# which is where we take the ID from.
echo "==> Creating tunnel '$tunnel_name'..."
tunnel_id=""
create_rc=0
create_output="$(cloudflared tunnel create "$tunnel_name" 2>&1)" || create_rc=$?
echo "$create_output"
if [ "$create_rc" -eq 0 ]; then
    if [[ "$create_output" =~ Created\ tunnel\ ([^[:space:]]+)\ with\ id\ ($uuid_re) ]] \
        && [ "${BASH_REMATCH[1]}" = "$tunnel_name" ]; then
        tunnel_id="${BASH_REMATCH[2]}"
    fi
else
    case "$create_output" in
        *"already exists"*)
            echo "    Tunnel '$tunnel_name' already exists - looking up its ID."
            ;;
        *)
            echo "ERROR: tunnel create failed." >&2
            exit 1
            ;;
    esac
fi

# Step 3: Fallback for an existing tunnel: `tunnel info --output json`
# prints an object whose first two keys are "id" and "name". Parse exactly
# that shape and require the name to match.
if [ -z "$tunnel_id" ]; then
    info_json="$(cloudflared tunnel info --output json "$tunnel_name" 2>/dev/null || true)"
    if [[ "$info_json" =~ ^[[:space:]]*\{[[:space:]]*\"id\":[[:space:]]*\"($uuid_re)\",[[:space:]]*\"name\":[[:space:]]*\"([^\"]*)\" ]] \
        && [ "${BASH_REMATCH[2]}" = "$tunnel_name" ]; then
        tunnel_id="${BASH_REMATCH[1]}"
    fi
fi

if [ -z "$tunnel_id" ]; then
    echo "ERROR: Could not determine tunnel ID for '$tunnel_name'" >&2
    echo "       Check with: cloudflared tunnel info $tunnel_name" >&2
    exit 1
fi

credentials_file="$HOME/.cloudflared/${tunnel_id}.json"
echo "==> Tunnel ID: $tunnel_id"
echo "==> Credentials: $credentials_file"
if [ ! -f "$credentials_file" ]; then
    echo "WARN: $credentials_file does not exist on this machine." >&2
    echo "      (A tunnel created elsewhere needs its credentials JSON copied here.)" >&2
fi

# Step 4: Write starter config - but never over an existing one: it may
# already route other hostnames for another tunnel.
config_path="$HOME/.cloudflared/config.yml"
config_written="false"
if [ -e "$config_path" ]; then
    echo
    echo "==> Existing config found at $config_path - left UNCHANGED."
    echo "    To use the new tunnel there, edit it yourself (back it up first):"
    echo "      tunnel: ${tunnel_id}"
    echo "      credentials-file: ${credentials_file}"
    echo "    and keep '- service: http_status:404' as the LAST ingress entry."
else
    echo "==> Writing starter config to $config_path"
    mkdir -p "$HOME/.cloudflared"
    cat > "$config_path" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${credentials_file}
ingress:
  - service: http_status:404
EOF
    config_written="true"
fi

# Step 5: Optionally install as systemd service (Linux only)
if [ "$config_written" = "true" ] && [ "$(uname)" = "Linux" ] && command -v systemctl >/dev/null 2>&1; then
    echo
    ans="n"
    if [ "$assume_yes" = "true" ]; then
        ans="y"
    elif [ -t 0 ]; then
        read -r -p "Install cloudflared as a systemd service? [y/N] " ans || ans="n"
    else
        echo "==> Not a terminal: skipping the systemd service install."
        echo "    Re-run with --yes to install it non-interactively."
    fi
    case "$ans" in
        y|Y|yes|Yes|YES)
            # systemd service runs as root and reads $etc_dir/config.yml
            sudo mkdir -p "$etc_dir"
            sudo chmod 0755 "$etc_dir"
            if [ -e "$etc_dir/config.yml" ]; then
                etc_backup="$etc_dir/config.yml.bak.$(date +%Y%m%d-%H%M%S)"
                echo "==> Backing up existing $etc_dir/config.yml to $etc_backup"
                sudo cp -p "$etc_dir/config.yml" "$etc_backup"
            fi
            sudo cp "$config_path" "$etc_dir/config.yml"
            sudo chmod 0644 "$etc_dir/config.yml"
            sudo cp "$credentials_file" "$etc_dir/"
            # Tunnel credentials are bearer-equivalent secrets; lock them down
            # regardless of the source umask.
            sudo chown root:root "$etc_dir/$(basename "$credentials_file")"
            sudo chmod 0600 "$etc_dir/$(basename "$credentials_file")"
            sudo cloudflared service install
            sudo systemctl enable --now cloudflared
            echo "==> Service installed."
            sudo systemctl is-active cloudflared || true
            ;;
    esac
fi

if [ "$config_written" = "false" ]; then
    cat <<EOF

==> Tunnel '$tunnel_name' is ready, but setup is NOT complete:
    $config_path was not changed (see above). Point it at the new tunnel,
    then add your first route.

EOF
    exit 3
fi

cat <<EOF

==> Setup complete!

Add your first route:
  add-route.sh app.yourdomain.com 8080

EOF

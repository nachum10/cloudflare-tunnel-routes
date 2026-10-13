#!/usr/bin/env bash
# Detect cloudflared installation and active tunnel configuration.
# Outputs key=value lines for easy parsing by other scripts.
# Exit 0 if a tunnel is detected, 1 if not.

set -u
export LC_ALL=C

found_binary=""
found_config=""
found_tunnel_id=""
found_credentials=""
needs_sudo="false"
service_mode="unknown"  # systemd|ambiguous|manual|none
service_unit=""         # the systemd unit serving THIS config (systemd mode)
service_candidates=""   # comma-separated units when ambiguous
remote_managed="false"  # unit runs `tunnel run --token` (ingress is remote)

# Optional environment overrides for hosts running multiple tunnels:
#   CFTR_CONFIG=/path/to/config.yml   -- target a specific config file
#   CFTR_BINARY=/path/to/cloudflared  -- use a specific cloudflared binary
#   CFTR_SERVICE=cloudflared-x.service -- systemd unit to restart
# When set, we skip auto-detection of that field.

# 1) Locate cloudflared binary
if [ -n "${CFTR_BINARY:-}" ]; then
    if [ ! -x "$CFTR_BINARY" ]; then
        echo "ERROR: CFTR_BINARY=$CFTR_BINARY is not an executable file." >&2
        exit 2
    fi
    found_binary="$CFTR_BINARY"
elif command -v cloudflared >/dev/null 2>&1; then
    found_binary="$(command -v cloudflared)"
fi

# 2) Locate config file
if [ -n "${CFTR_CONFIG:-}" ]; then
    if [ ! -f "$CFTR_CONFIG" ]; then
        echo "ERROR: CFTR_CONFIG=$CFTR_CONFIG does not exist." >&2
        exit 2
    fi
    found_config="$CFTR_CONFIG"
else
    # Check standard locations in order
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
fi

# 3) Determine if sudo needed for the config file. Edits replace the file
# atomically (temp file + mv in the same directory) and keep its owner,
# so we also need a writable directory and, unless root, to own the file.
if [ -n "$found_config" ]; then
    # For a symlinked config the edit lands next to the link's TARGET.
    real_config="$found_config"
    hops=0
    while [ -L "$real_config" ] && [ "$hops" -lt 40 ]; do
        hops=$((hops + 1))
        link="$(readlink "$real_config" 2>/dev/null)" || break
        case "$link" in
            /*) real_config="$link" ;;
            *)  real_config="$(dirname "$real_config")/$link" ;;
        esac
    done
    if [ ! -w "$found_config" ] || [ ! -w "$(dirname "$real_config")" ]; then
        needs_sudo="true"
    elif [ "$(id -u)" != "0" ] && [ ! -O "$found_config" ]; then
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

# 5) Determine how cloudflared is being managed - and WHICH unit serves
# this config. A host may run several tunnels (one unit per config), so
# "cloudflared.service exists" is not enough: restarting the wrong unit
# leaves the edited tunnel stale and bounces an unrelated one.
unit_re='^[A-Za-z0-9][A-Za-z0-9@._:-]*$'

exec_start_of() {
    # e.g. "{ path=/usr/bin/cloudflared ; argv[]=/usr/bin/cloudflared
    #        --config /etc/cloudflared/config.yml tunnel run ; ... }"
    systemctl show -p ExecStart --value "$1" 2>/dev/null || true
}
# Whole-argv-token match: `--config X` or `--config=X`, never a substring.
references_config() {
    local argv=" $1 "
    [[ "$argv" == *" --config $found_config "* || "$argv" == *" --config=$found_config "* ]]
}
uses_token() {
    local argv=" $1 "
    [[ "$argv" == *" --token "* || "$argv" == *" --token="* ]]
}

if [ -n "${CFTR_SERVICE:-}" ]; then
    if ! [[ "$CFTR_SERVICE" =~ $unit_re ]]; then
        echo "ERROR: CFTR_SERVICE=$CFTR_SERVICE is not a valid unit name." >&2
        exit 2
    fi
    service_mode="systemd"
    service_unit="$CFTR_SERVICE"
    if uses_token "$(exec_start_of "$service_unit")"; then
        remote_managed="true"
    fi
else
    matches=()
    if [ -n "$found_config" ] && command -v systemctl >/dev/null 2>&1; then
        while read -r unit _; do
            [[ "$unit" =~ $unit_re && "$unit" == *.service ]] || continue
            es="$(exec_start_of "$unit")"
            if references_config "$es"; then
                matches+=("$unit")
                uses_token "$es" && remote_managed="true"
            fi
        done < <(systemctl list-units 'cloudflared*' --all --no-legend --plain 2>/dev/null || true)
    fi
    if [ "${#matches[@]}" -eq 1 ]; then
        service_mode="systemd"
        service_unit="${matches[0]}"
    elif [ "${#matches[@]}" -gt 1 ]; then
        service_mode="ambiguous"
        service_candidates="$(IFS=,; printf '%s' "${matches[*]}")"
    elif pgrep -f "cloudflared.*tunnel.*run" >/dev/null 2>&1; then
        service_mode="manual"
    else
        service_mode="none"
    fi
fi

# Validate all values against strict patterns BEFORE emitting them.
# Consumers must NEVER `eval` this output (use `while IFS='=' read -r k v`),
# but defense-in-depth: refuse to emit anything that doesn't match expected shape.
validate() {
    # $1 = name, $2 = value, $3 = regex (POSIX ERE), $4 = "allow_empty" optional
    if [ -z "$2" ]; then
        if [ "${4:-}" = "allow_empty" ]; then
            return 0
        fi
        return 1
    fi
    if ! printf '%s' "$2" | grep -Eq "$3"; then
        echo "ERROR: detect.sh: refusing to emit suspicious '$1' value." >&2
        echo "       Inspect ${found_config:-config} for tampering." >&2
        return 2
    fi
    return 0
}

# Allowed shapes:
#   - binary/config/credentials: absolute path, conservative charset
#   - tunnel_id: UUID-ish (hex + dashes), 8..40 chars
#   - needs_sudo: true|false
#   - service_mode: systemd|ambiguous|manual|none|unknown
#   - service_unit / service_candidates: systemd unit name(s)
#   - remote_managed: true|false
path_re='^/[A-Za-z0-9_./+@:-]+$'
uuid_re='^[A-Fa-f0-9-]{8,40}$'

validate binary       "$found_binary"      "$path_re" allow_empty || exit 2
validate config       "$found_config"      "$path_re" allow_empty || exit 2
validate credentials  "$found_credentials" "$path_re" allow_empty || exit 2
validate tunnel_id    "$found_tunnel_id"   "$uuid_re" allow_empty || exit 2
validate needs_sudo   "$needs_sudo"        '^(true|false)$'       || exit 2
validate service_mode "$service_mode"      '^(systemd|ambiguous|manual|none|unknown)$' || exit 2
validate service_unit "$service_unit"      "$unit_re" allow_empty || exit 2
validate service_candidates "$service_candidates" '^[A-Za-z0-9][A-Za-z0-9@._:,-]*$' allow_empty || exit 2
validate remote_managed "$remote_managed"  '^(true|false)$'       || exit 2

# Output
echo "binary=${found_binary}"
echo "config=${found_config}"
echo "tunnel_id=${found_tunnel_id}"
echo "credentials=${found_credentials}"
echo "needs_sudo=${needs_sudo}"
echo "service_mode=${service_mode}"
echo "service_unit=${service_unit}"
echo "service_candidates=${service_candidates}"
echo "remote_managed=${remote_managed}"

# Exit code: success only if we have binary + config + tunnel_id
if [ -n "$found_binary" ] && [ -n "$found_config" ] && [ -n "$found_tunnel_id" ]; then
    exit 0
else
    exit 1
fi

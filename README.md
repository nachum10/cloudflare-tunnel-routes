# cloudflare-tunnel-routes

> **Stop losing your Gradio demo link on every restart.**
> Replace `gradio share=True` (and `ngrok`, and `streamlit run --share`) with a **permanent HTTPS URL** on a domain you own — in one command. No deployment, no Cloudflare dashboard.

```bash
bash scripts/add-route.sh demo.example.com 7860
# → https://demo.example.com   (TLS by Cloudflare, persists across restarts)
```

Works as a plain Bash CLI, as a [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills), and is friendly to AI coding agents (Claude / Cursor / Codex) via [`AGENTS.md`](./AGENTS.md), [`llms.txt`](./llms.txt), and [`.cursor/rules/`](./.cursor/rules/).

## When to use this — at a glance

| Your need | Use this? | Better alternative |
|---|:-:|---|
| Gradio / Streamlit / FastAPI demo with a **permanent URL** | ✅ | — |
| Webhook receiver URL (GitHub / Stripe / Slack) on a laptop | ✅ | — |
| Run multiple services under one domain via path routing | ✅ | — |
| **Throwaway** URL for one-off sharing | ❌ | [`cloudflared --url`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/) or `ngrok` |
| Managed hosting (no laptop / always-on infra) | ❌ | Hugging Face Spaces, Modal, Vercel, Fly |
| **No Cloudflare-managed domain** | ❌ | `ngrok` (free TLD), `cloudflared --url` |
| Auth / SSO / IP allowlist | ❌ alone | combine with [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/applications/) |

See [`USE_CASES.md`](./USE_CASES.md) for the agent-readable decision matrix and copy-paste user phrasings, and [`PROMPTS.md`](./PROMPTS.md) for ready-made prompts.

[![tests](https://github.com/nachum10/cloudflare-tunnel-routes/actions/workflows/test.yml/badge.svg)](https://github.com/nachum10/cloudflare-tunnel-routes/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-green.svg)]()
[![Platforms: Linux | macOS | Windows](https://img.shields.io/badge/Platforms-Linux%20%7C%20macOS%20%7C%20Windows-blue.svg)]()
[![Claude Code Skill](https://img.shields.io/badge/Claude%20Code-Skill-D97757?logo=anthropic&logoColor=white)](https://docs.claude.com/en/docs/claude-code/skills)
[![Agent-installable](https://img.shields.io/badge/AI%20agents-installable-7c3aed)](./AGENTS.md)
[![Zero dependencies](https://img.shields.io/badge/dependencies-zero-success)]()

---

## Table of contents

- [What it does](#what-it-does)
- [Why](#why)
- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Operations reference](#operations-reference)
- [Use cases](#use-cases)
- [Architecture](#architecture)
- [Safety guarantees](#safety-guarantees)
- [Troubleshooting](#troubleshooting)
- [Comparison with alternatives](#comparison-with-alternatives)
- [FAQ](#faq)
- [Contributing](#contributing)
- [License](#license)

---

## Use with Claude Code

```bash
git clone https://github.com/nachum10/cloudflare-tunnel-routes.git
cd cloudflare-tunnel-routes
./install.sh
```

Then in any Claude Code session, just describe the problem in your own words:

> my Gradio share link keeps changing — give me a permanent one at demo.example.com on port 7860

Claude Code will pick up the skill automatically. The `SKILL.md` description fires on phrasings like:

- *"replace `share=True`"* / *"permanent Gradio URL"*
- *"stable URL for localhost:7860"* / *"persistent link for my local AI demo"*
- *"ngrok alternative on my own domain"*
- *"add a Cloudflare route for project X"* / *"expose port X at https://Y"*
- *"persistent webhook URL on my laptop"* / *"publish on a subdomain"*

It will not fire when you actually want a throwaway URL, managed hosting, or when you don't own a domain in Cloudflare — see [`USE_CASES.md`](./USE_CASES.md) for the full decision matrix.

---

## What it does

Expose any local service on your machine to the public internet at a permanent HTTPS URL via Cloudflare Tunnel, with one command:

```bash
add-route.sh demo.example.com 7860
# https://demo.example.com → http://127.0.0.1:7860
# (Free TLS, free DDoS protection, persistent across restarts.)
```

The skill is **portable**: works on any machine, any Cloudflare account, any Linux distribution, macOS, and Windows. The only requirement is that `cloudflared` is installed.

---

## Why

If you've ever needed to share a local app over the internet, you've probably tried:

| Approach | Pain |
|---|---|
| `gradio share=True` | URL changes on every restart, breaks shared links. |
| `ngrok` (free) | URL changes on every restart, requires running another worker. |
| `cloudflare quick tunnel` (`trycloudflare.com`) | Random URL on every run. |
| Cloudflare Tunnel (manual) | Need to log into the dashboard, edit YAML by hand, restart the daemon, fight YAML indentation. |
| Full deployment (Vercel, Fly, Hugging Face) | Requires packaging, env config, codebase cleanup - too heavy for a quick demo. |

This skill keeps the **persistent URL** advantage of a real Cloudflare Tunnel but removes the dashboard / manual-YAML pain. Everything happens locally through `cloudflared` and the `config.yml` file.

---

## How it works

Cloudflare Tunnel creates an outbound connection from your machine to the Cloudflare edge network. Cloudflare then routes incoming HTTPS traffic for the configured hostnames back through that tunnel to your local services.

```
   Public visitor                  Cloudflare edge                 Your machine
        │                                 │                              │
        │  GET https://demo.example.com   │                              │
        ├────────────────────────────────►│                              │
        │                                 │  via persistent tunnel       │
        │                                 ├─────────────────────────────►│
        │                                 │                              │
        │                                 │  HTTP request to             │
        │                                 │  http://127.0.0.1:7860       │
        │                                 │                              ▼
        │                                 │                       [your app]
        │                                 │◄─────────────────────────────┤
        │◄────────────────────────────────┤                              │
        │  HTTPS response (TLS by CF)     │                              │
```

The `config.yml` ingress rules tell `cloudflared` which incoming hostname maps to which local service. This skill edits that YAML with a backup-validate-rollback workflow (described below).

> **YAML editing scope.** Mutating operations (add-route / remove-route) use line-oriented `awk`/`grep`, **not** a full YAML parser. This is intentional: a real parser would round-trip the file and clobber comments, anchors, and the user's chosen indentation/quoting style. The current approach works well on the canonical shape `cloudflared` itself produces (and the shape this skill produces). If your `config.yml` is **hand-crafted** with advanced YAML — anchors / aliases, multi-line block scalars, comments inside ingress entries, mixed indentation — **always run `--dry-run` first** and inspect the diff against the latest `.bak`. The read-only `list-routes.sh` automatically uses `yq` when it is on `PATH` for accurate parsing of complex configs; install [yq](https://github.com/mikefarah/yq) to enable that path. A full YAML parser for *editing* operations is an explicit non-goal.

The flow is:

1. **Detection** - finds your `config.yml` (in `/etc/cloudflared/`, `~/.cloudflared/`, or wherever), reads tunnel ID, figures out whether `sudo` and `systemctl` are needed.
2. **DNS** - calls `cloudflared tunnel route dns` to create the CNAME pointing to the tunnel.
3. **Ingress** - inserts a new `- hostname / service` block immediately above the catch-all `service: http_status:404`.
4. **Validate** - runs `cloudflared tunnel ingress validate` to confirm the new YAML is valid.
5. **Reload** - `systemctl restart cloudflared` (systemd mode) or `pkill -HUP cloudflared` (manual mode). The change is live in ~2 seconds.
6. **Auto-rollback** - if validation fails, the timestamped backup is restored automatically.

---

## Prerequisites

| Requirement | How to install / get |
|---|---|
| `cloudflared` binary | See OS-specific install commands below |
| Cloudflare account (free) | https://dash.cloudflare.com/sign-up |
| A domain in your Cloudflare account | Buy from any registrar (~$10/year), or transfer an existing one. Add it to Cloudflare and point its nameservers. |
| `bash` (4+) and `awk` (gawk or busybox) | Pre-installed on Linux/macOS; use WSL or Git Bash on Windows |

### Installing `cloudflared`

**Debian/Ubuntu (recommended for servers):**
```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb
```

**Generic Linux (binary):**
```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared
sudo chmod +x /usr/local/bin/cloudflared
```

**macOS:**
```bash
brew install cloudflared
```

**Windows (PowerShell as admin):**
```powershell
winget install --id Cloudflare.cloudflared
```

Verify:
```bash
cloudflared --version
# cloudflared version 2026.1.2 (built ...)
```

---

## Installation

### Option A - As a Claude Code skill (recommended for Claude users)

```bash
git clone https://github.com/nachum10/cloudflare-tunnel-routes.git ~/Apps/cloudflare-tunnel-routes
cd ~/Apps/cloudflare-tunnel-routes
./install.sh
```

`install.sh` symlinks the repo to `~/.claude/skills/cloudflare-tunnel-routes/` so Claude Code auto-invokes it whenever you ask "add a Cloudflare route for project X".

### Option B - Standalone CLI (no Claude needed)

```bash
git clone https://github.com/nachum10/cloudflare-tunnel-routes.git
cd cloudflare-tunnel-routes
chmod +x scripts/*.sh
# Optional: add to PATH
export PATH="$PWD/scripts:$PATH"
```

---

## Quick start

### First time (one-time per machine)

If you don't already have a tunnel:

```bash
bash scripts/setup-new-tunnel.sh my-server
# 1. Opens browser for `cloudflared tunnel login`
# 2. Creates a tunnel named "my-server"
# 3. Writes a starter ~/.cloudflared/config.yml
# 4. Optionally installs cloudflared as a systemd service
```

If you already have a tunnel, skip this step - `detect.sh` will find it automatically.

### Add your first route

```bash
bash scripts/add-route.sh app.example.com 8080
```

Output:
```
==> Tunnel: bc41dca4-c261-409c-8a15-60f26d790fed
==> Config: /etc/cloudflared/config.yml
==> Adding: app.example.com -> http://127.0.0.1:8080

==> Creating DNS CNAME for app.example.com...
2026-05-10T12:34:56Z INF Added CNAME app.example.com which will route to this tunnel
==> Backing up config to /etc/cloudflared/config.yml.bak.20260510-123456
==> Inserting ingress block before catch-all...
==> Validating config...
Validating rules from /etc/cloudflared/config.yml
OK
==> Restarting cloudflared (systemd)...
    Active.

==> Done. Test with: curl -I https://app.example.com/
```

Wait ~5 seconds for DNS propagation, then:

```bash
curl -I https://app.example.com
# HTTP/2 200
```

---

## Operations reference

### `detect.sh` - Inspect current installation

```bash
bash scripts/detect.sh
```

Outputs key=value lines:
```
binary=/usr/local/bin/cloudflared
config=/etc/cloudflared/config.yml
tunnel_id=bc41dca4-c261-409c-8a15-60f26d790fed
credentials=/root/.cloudflared/bc41dca4-c261-409c-8a15-60f26d790fed.json
needs_sudo=true
service_mode=systemd
```

Exit 0 if a tunnel is detected, 1 if not.

### `list-routes.sh` - Show all current routes

```bash
bash scripts/list-routes.sh
```

```
Tunnel: bc41dca4-c261-409c-8a15-60f26d790fed
Config: /etc/cloudflared/config.yml
---
app.example.com                                      -> http://127.0.0.1:8080
api.example.com                                      -> http://127.0.0.1:3000
example.com               /docs.*                    -> http://127.0.0.1:9000
```

### `add-route.sh` - Add a new route

```bash
# Subdomain → local port
bash scripts/add-route.sh app.example.com 8080

# Subdomain → full URL
bash scripts/add-route.sh api.example.com http://127.0.0.1:3000

# Path-based route on apex domain (quote the path so the shell doesn't glob it)
bash scripts/add-route.sh example.com 9000 --path "/docs.*"
```

**Idempotent**: re-running with the same args is safe - duplicate DNS records and config blocks are detected and skipped.

### `remove-route.sh` - Remove an ingress block

```bash
bash scripts/remove-route.sh app.example.com
bash scripts/remove-route.sh example.com --path "/docs.*"
bash scripts/remove-route.sh api.example.com --keep-dns   # skip the DNS hint
```

The script removes the ingress block from `config.yml` and reloads `cloudflared`. **It does not delete the DNS CNAME** - `cloudflared` exposes no API for that. By default it prints dashboard / API instructions for finishing the cleanup; pass `--keep-dns` to suppress the hint when scripting bulk removals.

### `setup-new-tunnel.sh` - One-time setup on a fresh machine

```bash
bash scripts/setup-new-tunnel.sh my-server
```

Performs:
1. `cloudflared tunnel login` (opens browser, requires confirmation)
2. `cloudflared tunnel create my-server`
3. Writes a starter `~/.cloudflared/config.yml`
4. Optionally installs as a systemd service (Linux only)

---

## Dry-run and multi-tunnel hosts

`add-route.sh` and `remove-route.sh` accept `--dry-run` (full file preview) and `--diff` (unified diff against the current `config.yml`). No files modified, no daemon restarted. `--diff` implies `--dry-run` and uses [delta](https://github.com/dandavison/delta) or [colordiff](https://www.colordiff.org/) when on `PATH`, plain `diff -u` otherwise:

```bash
bash scripts/add-route.sh app.example.com 8080 --dry-run
bash scripts/add-route.sh app.example.com 8080 --diff
bash scripts/remove-route.sh old.example.com --diff
```

Optional `--comment "TEXT"` (on `add-route.sh` only) inserts a single YAML comment line above the new ingress block. Off by default, opt-in only:

```bash
bash scripts/add-route.sh demo.example.com 7860 --comment "Gradio object-detection demo"
```

Produces:

```yaml
  # Added by cloudflare-tunnel-routes on 2026-05-10 | Gradio object-detection demo
  - hostname: demo.example.com
    service: http://127.0.0.1:7860
```

If you have more than one tunnel/config on a host, the auto-detection picks the first config it finds. Override it with environment variables:

```bash
CFTR_CONFIG=/etc/cloudflared/secondary.yml bash scripts/add-route.sh app.example.com 8080
CFTR_BINARY=/opt/cloudflared/bin/cloudflared bash scripts/list-routes.sh
```

## Tests

A hermetic test suite lives in `tests/run-tests.sh` (78 tests, no real cloudflared / DNS calls):

```bash
bash tests/run-tests.sh
```

Covers input validation, idempotency, catch-all sanity checks, remove-route correctness, and `detect.sh` rejection of tampered configs. CI runs the same suite on every push and PR — see the **tests** badge at the top.

---

## Examples

End-to-end recipes for common stacks live in [`examples/`](./examples/):

- [Gradio](./examples/gradio.md) — replace `share=True` with a permanent URL
- [Streamlit](./examples/streamlit.md) — local dashboard with stable HTTPS
- [FastAPI](./examples/fastapi.md) — personal API server with optional path-based routing
- [Webhooks](./examples/webhooks.md) — receive GitHub / Stripe / Slack webhooks on your laptop
- [Docker](./examples/docker.md) — expose a containerized service (single container or compose)

Each one is a copy-pasteable `run app → add-route → curl` flow.

---

## Use cases

### 1. Persistent demo URL for ML/AI prototypes

Replace `gradio share=True` (random ngrok-style URL that changes per restart) with a permanent URL:

```bash
# One-time:
bash scripts/add-route.sh demo.example.com 7860

# In your gradio app (no `share=True`):
demo.launch(server_name="0.0.0.0", server_port=7860)
```

`https://demo.example.com` works forever, even after restarts and reboots.

### 2. Multiple projects on the same host

```bash
bash scripts/add-route.sh app1.example.com 9001
bash scripts/add-route.sh app2.example.com 9002
bash scripts/add-route.sh api.example.com  9003
```

Each subdomain free TLS, free DDoS protection, no ports exposed in your firewall.

### 3. Path-based subapps on a single domain

```bash
bash scripts/add-route.sh example.com 9010 --path "/api.*"
bash scripts/add-route.sh example.com 9020 --path "/admin.*"
bash scripts/add-route.sh example.com 9030 --path "/docs.*"
```

### 4. Replace `localhost` for webhook testing

For Stripe / Twilio / GitHub webhooks pointed at a local dev server:

```bash
bash scripts/add-route.sh webhooks.example.com 4000
# Stripe sends POST → https://webhooks.example.com/hook → http://localhost:4000/hook
```

---

## Architecture

```
~/Apps/cloudflare-tunnel-routes/
├── README.md                       (this file)
├── LICENSE                         (MIT)
├── SKILL.md                        (Claude Code skill metadata)
├── install.sh                      (symlink installer)
├── .gitignore
├── scripts/
│   ├── detect.sh                   (runtime detection - 60 lines)
│   ├── list-routes.sh              (config parser - 30 lines)
│   ├── add-route.sh                (DNS + ingress + validate + reload - 170 lines)
│   ├── remove-route.sh             (ingress removal + reload - 100 lines)
│   └── setup-new-tunnel.sh         (one-time setup - 100 lines)
└── references/
    └── troubleshooting.md          (loaded by Claude on demand)
```

The scripts have **no external dependencies** beyond `cloudflared`, `bash`, and `awk` - they're plain POSIX-style shell with `awk` for safe YAML editing (no `sed -i` magic that risks corrupting indentation).

---

## Safety guarantees

Every destructive operation includes safety nets:

| Risk | Mitigation |
|---|---|
| Edit corrupts `config.yml` | Timestamped backup created BEFORE every edit (`config.yml.bak.<timestamp>`) |
| Validation fails after edit | Backup automatically restored; cloudflared NOT restarted |
| Duplicate DNS / ingress | Detected; the script reports "already exists" and skips |
| `sudo` not available | Detected by `needs_sudo` check; script exits with clear error |
| Catch-all 404 ordering broken | Insert always happens BEFORE the `http_status:404` line |
| Service won't start after restart | Logs are dumped via `systemctl status` for debugging |

If a script fails midway, your previous `config.yml` is in `config.yml.bak.<timestamp>` - restore with `cp`.

---

## Troubleshooting

See [`references/troubleshooting.md`](./references/troubleshooting.md) for the full guide. Common issues:

- **"404 Not Found" from the tunnel after add** - DNS propagation lag (~30-60s) or local service not listening on the configured port. Test with `curl -I http://127.0.0.1:<port>` first.
- **"A, AAAA, or CNAME record with that host already exists"** - Pre-existing DNS record blocks the CNAME. Delete it via the Cloudflare dashboard, then re-run `add-route.sh`.
- **"tunnel not found" / "credentials file not found"** - Config copied between machines but credentials weren't. Run `setup-new-tunnel.sh` again or copy the credentials JSON.
- **Permission denied on `/etc/cloudflared/config.yml`** - The scripts auto-detect `needs_sudo`; just make sure `sudo` is available.

---

## Comparison with alternatives

| Solution | Persistent URL | Setup time | Self-hosted | TLS | Free | Downside |
|---|---|---|---|---|---|---|
| **This skill** | ✅ Yes | ~5 min one-time | ✅ Yes (your domain) | ✅ Free CF TLS | ✅ Free | Needs domain (~$10/yr) |
| `gradio share=True` | ❌ Changes per restart | 0 sec | ❌ Via gradio.live | ✅ Yes | ✅ Free | URL breaks on restart |
| `ngrok` free | ❌ Changes per restart | 1 min | ❌ Via ngrok | ✅ Yes | ✅ Free (limited) | URL breaks on restart |
| `ngrok` paid | ✅ Yes (reserved domain) | 1 min | ❌ Via ngrok | ✅ Yes | ❌ ~$10/mo | Subscription |
| `gradipin` | ✅ Yes | 1 min | ❌ Via 3rd-party server | ✅ Yes | ✅ Free | 3rd-party dependency |
| Vercel / Netlify / HF Spaces | ✅ Yes | ~30 min first time | ❌ | ✅ Yes | ✅ Free tier | Requires deployment + packaging |
| Manual Cloudflare Tunnel | ✅ Yes | ~30 min per route | ✅ Yes | ✅ Yes | ✅ Free | Dashboard / YAML drudgery |

---

## FAQ

### Q: Do I need a paid Cloudflare account?
**A:** No. Cloudflare Tunnel and DNS are free on the standard plan.

### Q: Can I use a free domain (e.g., `.tk`)?
**A:** Cloudflare requires the domain to be added to your account with their nameservers. Most free TLDs work; some (like `.tk`) have intermittent issues. Recommended: a real domain from Namecheap / Cloudflare Registrar (~$10/year for `.com`).

### Q: Is the tunnel secure?
**A:** The transport is: the tunnel itself is an outbound TLS connection from your machine to Cloudflare, so nothing inbound is opened on your firewall, and Cloudflare terminates TLS at the edge with their certificate. **The application you expose is not** - by default the URL is public to anyone who can reach Cloudflare. If the local service has no auth, anyone with the URL can hit it. For anything sensitive add **Cloudflare Access** (SSO / IP allowlist / one-time PIN), enable rate limiting / WAF rules, and consider a Cloudflare Tunnel "service token" if you only want machine-to-machine access. This skill does **not** configure those for you.

### Q: Can I run multiple tunnels on the same machine?
**A:** Yes, but `detect.sh` picks the first config it finds. To target a specific tunnel, point it at the right `config.yml` manually or modify `detect.sh`.

### Q: What if my IP changes?
**A:** No issue - the tunnel is outbound, so dynamic IPs work fine. This makes it perfect for home servers, laptops, or NATed environments.

### Q: Does this work with Docker containers?
**A:** Yes, but containers must bind to `0.0.0.0:port` (not `127.0.0.1:port`) so cloudflared can reach them, OR use `--network host`.

### Q: Can I use this for production?
**A:** It's perfectly fine for personal projects, demos, and small production workloads. For high-volume production, also consider Cloudflare's enterprise tunnel features and load balancing.

---

## Contributing

PRs welcome. Before submitting:

1. Test scripts on a non-production tunnel.
2. Run `bash -n scripts/*.sh` for syntax check.
3. Run `bash tests/run-tests.sh` and make sure it passes.
4. Update README + `references/troubleshooting.md` if you change behavior.

Areas where help is welcome:
- Windows-native PowerShell port (currently requires WSL/Git Bash).
- DNS deletion via Cloudflare API (requires API token handling).
- macOS / BSD compatibility testing (the test suite assumes GNU coreutils).

---

## License

MIT - see [LICENSE](./LICENSE).

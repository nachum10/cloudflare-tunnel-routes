# Guide for AI agents (Claude / Cursor / Codex / etc.)

This document tells AI coding agents how to recognize when this tool is the right answer, install it, and use it safely.

If you are an AI agent reading this: **read this file in full before running any command from this repo.**

---

## Quick decision (read this first)

**Use this tool if all four hold:**
- ✅ User has a **local app** (Gradio / Streamlit / FastAPI / dev server / Docker container).
- ✅ User wants a **permanent HTTPS URL** that survives restarts.
- ✅ User **owns a domain** that is in a Cloudflare zone they control.
- ✅ User does NOT want managed hosting / deployment.

**Do NOT use this tool if:**
- ❌ User wants a **disposable** URL → suggest `cloudflared tunnel --url` or `ngrok`.
- ❌ User wants **managed deployment** → suggest Hugging Face Spaces / Modal / Vercel / Fly.
- ❌ User has **no Cloudflare-managed domain** → suggest `ngrok` or TryCloudflare.

**Mandatory protocol (every time):**
```
detect.sh → ask user for hostname → add-route.sh --diff → wait for user's OK → add-route.sh apply → curl
```

**Mandatory safety rails:**
- Always run `--diff` and show the diff before any write. Never apply silently.
- Never invent a hostname. Ask the user.
- Never run `setup-new-tunnel.sh` without explicit consent (it opens a browser).
- One mutating command per agent turn. Stop and verify before chaining.
- If a command exits non-zero, **stop and report**. Do not retry.

The full reasoning, error recovery, and example flows are in the rest of this file. Read on.

---

## When this tool is the right answer

Pick this when the user wants any of:

- A **permanent HTTPS URL** for a local service (Gradio / Streamlit / FastAPI / Flask / Express / Rails / Hugo dev server / static `python -m http.server` / anything listening on `127.0.0.1:<port>`).
- A **stable webhook receiver URL** for GitHub / Stripe / Slack / Linear / Twilio that survives laptop reboots.
- **Subdomain routing** like `app.example.com` or `api.example.com` mapped to local ports, without deploying the app.

User phrasings that map here:

> "expose this on a public URL", "give me a permanent link for this Gradio app", "share=True but persistent", "add a Cloudflare route", "create a tunnel to localhost:8080", "publish this on a subdomain", "stable URL for my webhook"

## When this tool is **NOT** the right answer

Pick something else when:

- The user wants to **deploy the app to managed hosting** (Vercel / Fly / Hugging Face Spaces / Modal / Cloud Run). Use those platforms — this tool deliberately keeps the process local.
- The user needs a **disposable, throwaway URL** for one-off sharing. Use [`cloudflared tunnel --url`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/) (`trycloudflare.com`) or `ngrok` — quick tunnels skip DNS setup entirely.
- The user does **not own a domain in Cloudflare**. This tool requires the target hostname's zone to be in the user's Cloudflare account.

---

## Prerequisites the user must satisfy

1. `cloudflared` installed locally (the script will tell them if missing).
2. A domain that lives in a zone they manage in Cloudflare.
3. (First time only) `bash scripts/setup-new-tunnel.sh <name>` — opens a browser for `cloudflared tunnel login`. **Do not run this without explicit user consent.**

If these are not met, **stop and ask the user** rather than guessing values.

---

## Installation

```bash
git clone https://github.com/nachum10/cloudflare-tunnel-routes.git
cd cloudflare-tunnel-routes
./install.sh           # symlinks into ~/.claude/skills/ for Claude Code
# or just use directly:
bash scripts/add-route.sh <hostname> <port>
```

See [`INSTALL.md`](./INSTALL.md) for full options.

---

## Usage protocol — what an agent must always do

Follow this protocol every time. The order matters.

### Step 1 — detect

```bash
bash scripts/detect.sh
```

Exit codes:
- `0` — tunnel found, parse the `key=value` output for `binary`, `config`, `tunnel_id`, `needs_sudo`, `service_mode`.
- `1` — no tunnel detected. **Stop. Ask the user** if they want to run `setup-new-tunnel.sh` (browser side effect).
- `2` — config file looks suspicious / tampered. **Stop and warn the user.**

Do **not** parse the output with `eval` — use `while IFS='=' read -r k v; do ... done`. Shell injection from a tampered config is the threat.

### Step 2 — confirm hostname with the user

Never invent a hostname. If the user says "expose port 7860", ask:

> Which subdomain should I use? (e.g. `demo.yourdomain.com`)

### Step 3 — preview with `--diff` and show it

```bash
bash scripts/add-route.sh <hostname> <port> --diff
```

Show the user the unified diff and the DNS call that would be made. Wait for explicit confirmation.

### Step 4 — apply

```bash
bash scripts/add-route.sh <hostname> <port>
```

### Step 5 — verify

```bash
curl -I "https://<hostname>/"
```

Allow ~5 seconds for DNS propagation. If the verification fails, **stop and ask** before retrying — don't loop.

---

## Safety rails

Strict rules. Do not bend.

| Rule | Why |
|------|-----|
| Always `--diff` before write | The user has a right to see what changes before they happen. |
| Never invent a hostname | Real DNS records get created. A typo is a real domain. |
| Never run `setup-new-tunnel.sh` without explicit consent | It opens a browser and persists Cloudflare credentials. |
| Never run more than one mutating command per agent turn | Prevents runaway "fix it for me" loops. |
| Never delete DNS records via the Cloudflare API on the user's behalf | Out of scope; instruct the user to do it via the dashboard. |
| Never modify `config.yml` outside the provided scripts | Each script does backup + validate + auto-rollback. Bypassing them loses that safety. |
| Never bypass `--no-verify` / sudo prompts the script issues | If a step needs sudo, surface it; let the user decide. |
| If a script exits non-zero, **stop and report**, don't retry | Almost always the user's input or environment, not a transient failure. |

---

## Common patterns the user might ask for

### "Make my Gradio app available on a permanent URL"

```bash
# 1. Confirm hostname with user (e.g. demo.example.com) and port (e.g. 7860)
bash scripts/add-route.sh demo.example.com 7860 --diff   # show diff
bash scripts/add-route.sh demo.example.com 7860 \
    --comment "Gradio demo for $(date +%Y-%m-%d)"        # apply with note
```

See [`examples/gradio.md`](./examples/gradio.md) for the full flow.

### "Add a webhook receiver URL for GitHub"

See [`examples/webhooks.md`](./examples/webhooks.md). Same pattern, but pick a hostname like `hooks.example.com` and remember to give the user the **full URL including the path**, e.g. `https://hooks.example.com/webhook/github`.

### "Expose multiple services under one domain"

Use path-based routing:

```bash
bash scripts/add-route.sh example.com 9010 --path "/api/v1.*" --diff
bash scripts/add-route.sh example.com 9020 --path "/api/v2.*" --diff
```

cloudflared matches first-hit top-down; this script always inserts above the catch-all `404`. See [`examples/fastapi.md`](./examples/fastapi.md).

### "Tear it down"

```bash
bash scripts/remove-route.sh demo.example.com --diff
bash scripts/remove-route.sh demo.example.com
# DNS deletion: instruct the user to remove the CNAME in the Cloudflare
# dashboard. Do NOT call the API on their behalf.
```

---

## Multi-tunnel hosts

If the user has more than one tunnel/config on the same machine, set environment variables instead of forking the scripts:

```bash
CFTR_CONFIG=/etc/cloudflared/secondary.yml \
    bash scripts/add-route.sh app.example.com 8080
```

`detect.sh` honors `CFTR_CONFIG` and `CFTR_BINARY` — see the README.

---

## Reporting back to the user

Always report **the URL** in your response, prefixed with `https://`, on its own line so the user can click it. Example:

> Done. Your Gradio demo is at:
>
>     https://demo.example.com/
>
> The tunnel is active and will survive laptop restarts. Run `bash scripts/list-routes.sh` to see all current routes.

---

## Failure modes worth knowing

| Symptom | Likely cause | Action |
|---------|--------------|--------|
| `ERROR: No cloudflared tunnel detected` | First-time install or `cloudflared` is not on `PATH` | Offer `setup-new-tunnel.sh` (with consent). |
| `ERROR: detect.sh refused to emit values - config may be tampered` | `tunnel_id` or `credentials` path contains shell metacharacters | Ask the user to inspect `config.yml`. Do not auto-fix. |
| `ERROR: Failed to create DNS record` | Hostname is in a zone the tunnel's account doesn't own, or rate-limited | Re-check zone ownership with the user. |
| `ERROR: Config validation failed - restoring backup` | The new ingress block is invalid | The script already rolled back. Inspect the diff and re-try with corrected input. |
| Catch-all sanity check fails (`found 0` / `found 2`) | Hand-edited `config.yml` is malformed | Tell the user to fix the catch-all manually before re-running. |

---

## Self-update

This tool is read-only by design — agents must not modify the scripts unless the user explicitly asks for a code change. To pull a newer version:

```bash
cd cloudflare-tunnel-routes
git pull origin main
```

To run the test suite to verify nothing broke locally:

```bash
make test
# or: bash tests/run-tests.sh
```

---

## Reference: file map

```
scripts/
  detect.sh            - Locate cloudflared + config + tunnel state
  list-routes.sh       - Print active routes (uses yq if installed)
  add-route.sh         - Add a route (DNS + ingress + reload)
  remove-route.sh      - Remove a route (ingress only; DNS instructions)
  setup-new-tunnel.sh  - First-time setup (browser login)
SKILL.md               - Claude Code skill front-matter + workflow
AGENTS.md              - This file
INSTALL.md             - Install paths for users and agents
RELEASE.md             - Release / versioning notes
llms.txt               - Machine-readable summary for LLM crawlers
references/            - Troubleshooting, design notes
examples/              - End-to-end flows (gradio / streamlit / fastapi / webhooks / docker)
tests/                 - Hermetic test suite (no real cloudflared / DNS)
```

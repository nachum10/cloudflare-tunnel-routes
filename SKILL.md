---
name: cloudflare-tunnel-routes
description: Give any local port (Gradio, Streamlit, FastAPI, webhook receiver, dev server, Docker container) a permanent HTTPS URL on a domain the user owns - in one command, no deployment. Use when the user says "my Gradio share link keeps changing", "replace share=True with a permanent URL", "stable URL for localhost:7860", "permanent link for my local AI demo", "ngrok alternative on my own domain", "expose port X at https://Y.example.com", "persistent webhook URL on my laptop", "add a Cloudflare route/subdomain for project X", or any phrasing about wanting a stable HTTPS URL for a service that stays local instead of being deployed. Do NOT use for throwaway URLs (suggest `cloudflared --url` or `ngrok`), managed hosting (HF Spaces, Modal, Vercel), or when the user has no Cloudflare-managed domain.
---

# Cloudflare Tunnel Routes

Manage `cloudflared` tunnel ingress routes via CLI scripts. No browser, no Cloudflare dashboard - everything happens through the local `cloudflared` binary and the tunnel's `config.yml`.

## When to Use

Trigger this skill when the user wants to:

- Expose a local service (port `XXXX`) at a public HTTPS URL
- Add a new subdomain to an existing Cloudflare tunnel
- See which subdomains are currently routed through the tunnel
- Remove a subdomain from the tunnel
- Set up a brand-new tunnel on a fresh machine

Common phrasings: "add a Cloudflare route", "create a tunnel link", "publish this on a subdomain", "expose port X", "make this accessible on the internet".

## Prerequisites

The user must have:

1. **`cloudflared` installed** locally — `brew install cloudflared`, `apt install cloudflared`, or [download a binary](https://github.com/cloudflare/cloudflared/releases). Run `cloudflared --version` to check.
2. **A Cloudflare account** — free at https://dash.cloudflare.com.
3. **A domain managed in that Cloudflare account** — i.e. its DNS zone lives in Cloudflare. The hostname the user wants to expose (e.g. `demo.example.com`) must be on a domain they control via this account; otherwise DNS record creation will fail. If the domain is registered elsewhere, the user can move the zone to Cloudflare for free, or fall back to `ngrok` / `cloudflared --url`.
4. **An existing tunnel, OR explicit consent to create one** — run `scripts/detect.sh` first. If it returns exit code 1 (no tunnel), `scripts/setup-new-tunnel.sh <name>` will create one, but it opens a browser for `cloudflared tunnel login` — never invoke it without the user's explicit OK.

To verify everything is in place: run `bash scripts/detect.sh` and check that it exits `0` and reports a real `tunnel_id`.

## Operations

### 1. Inspect current state

Always run detection first to know what to work with:

```bash
bash scripts/detect.sh
```

Output keys: `binary`, `config`, `tunnel_id`, `credentials`, `needs_sudo`, `service_mode` (`systemd`/`ambiguous`/`manual`/`none`), `service_unit` (the systemd unit whose `ExecStart` passes this config via `--config`), `service_candidates` (when ambiguous), `remote_managed` (`true` if that unit runs `tunnel run --token`, in which case local ingress is ignored). Set `CFTR_SERVICE=<unit>` to name the unit explicitly.

### 2. List existing routes

```bash
bash scripts/list-routes.sh
```

Displays each `hostname [path] -> service` from the active config.

### 3. Add a new route

Builds the new config (block inserted before the catch-all 404), validates it, adds the DNS CNAME, then swaps the config in and restarts cloudflared - all in one command:

```bash
# Subdomain → local port
bash scripts/add-route.sh app.example.com 8080

# Subdomain → full URL (e.g. for HTTPS upstream)
bash scripts/add-route.sh api.example.com http://127.0.0.1:3000

# Path-based route on an existing apex domain
bash scripts/add-route.sh example.com 9015 --path /myapp
```

Behavior:
- Validates the candidate config FIRST. If validation fails, nothing happens: no DNS record, config untouched.
- DNS: a record already routed to this tunnel is fine (idempotent). A conflicting A/AAAA/CNAME record pointing elsewhere is an error; the script prints the opt-in `cloudflared tunnel route dns --overwrite-dns ...` command but never runs it.
- If the ingress block already exists, the config is left alone and nothing is restarted.
- Backs up `config.yml` to `config.yml.bak.<timestamp>.<random>` (5 most recent kept), then replaces it atomically with the same owner, group and mode.
- Restarts only the systemd unit that serves this config (or `CFTR_SERVICE`). If that restart fails, the backup is restored and the unit restarted again (exit 1).
- If no single unit can be identified (several units use this config, or cloudflared runs by hand), nothing is restarted: the config is written and the script exits **3** ("NOT reloaded") with the manual restart command. cloudflared has no reload signal; SIGHUP stops it, so the script never sends one.
- If DNS was created but a later step failed, it prints dashboard instructions for deleting the now-orphaned CNAME (it never deletes DNS itself).

### 4. Remove a route

```bash
bash scripts/remove-route.sh oldproject.example.com
bash scripts/remove-route.sh example.com --path /oldapp
```

Removes the ingress block (everything indented under its `- hostname:` line, including comments, `originRequest` and Access settings) with the same validate / backup / atomic replace / targeted restart path as `add-route.sh` (exit 3 = not reloaded); prints API instructions for deleting the DNS CNAME (cloudflared CLI cannot delete DNS records).

### 5. Set up a new tunnel (one-time per machine)

```bash
bash scripts/setup-new-tunnel.sh my-server
```

Performs `cloudflared tunnel login` (opens browser), `cloudflared tunnel create`, writes a starter `~/.cloudflared/config.yml`, and optionally installs as a systemd service.

## Workflow for "Add a Cloudflare route for project X on port Y"

1. Run `bash scripts/detect.sh`. If exit code is non-zero, tell the user a tunnel needs to be set up first and offer `setup-new-tunnel.sh`.
2. Confirm the hostname with the user (e.g. `projectx.theirdomain.com`). Domain must be in a zone the tunnel's Cloudflare account owns.
3. Preview with `bash scripts/add-route.sh <hostname> <port> --diff` and **show the diff to the user**. Wait for confirmation before applying.
4. Run `bash scripts/add-route.sh <hostname> <port>` to apply.
   - Exit **3** means the config is written but cloudflared was NOT restarted: relay the printed restart command to the user and stop.
5. Verify with `curl -I https://<hostname>` (allow ~5s for DNS propagation).

### Safety rails for AI agents

- **Always preview first** with `--diff` (or `--dry-run` for full output). Never apply changes silently.
- **Confirm hostname spelling** with the user before running. A typo creates a real DNS record.
- **Never invent hostnames** for the user — ask if you're unsure which subdomain they want.
- **One change per turn** — after `add-route.sh` succeeds, stop and let the user verify before chaining more changes.
- **Don't delete DNS records.** `remove-route.sh` only edits ingress; the DNS CNAME stays until the user removes it via the Cloudflare dashboard or API.
- **Don't run `setup-new-tunnel.sh` without explicit consent** — it opens a browser for `cloudflared tunnel login`, which is a side effect the user must initiate.

## Important Notes

- **Catch-all order matters.** The line `service: http_status:404` MUST stay last in the ingress list. `add-route.sh` inserts new entries immediately above it.
- **Path-based routes go before host-only routes for the same hostname.** Cloudflared matches first-hit, top-down, so a host-only rule would shadow a later path rule. When you add a `--path` route for a hostname that already has a host-only rule, `add-route.sh` inserts the new rule directly above that host-only rule (and above its comment lines); otherwise it inserts above the catch-all.
- **Multi-tunnel hosts.** Each config is restarted through the systemd unit whose `ExecStart` contains `--config <that file>`. Set `CFTR_SERVICE=<unit>` if the unit does not pass `--config`, or when several units share a config.
- **DNS deletion needs the dashboard or API.** `cloudflared` only creates DNS records, never deletes them.
- **Hostnames must live in a zone owned by the authenticated account.** If the user wants `myapp.someoneelse.com`, that won't work unless the user manages that zone in Cloudflare.
- **Sudo is auto-detected.** If `config.yml` lives in `/etc/cloudflared/` and isn't writable, scripts wrap edits with `sudo` automatically.

## See Also

- `references/troubleshooting.md` - common errors and fixes (404 from tunnel, "tunnel not found", DNS conflicts, etc.)

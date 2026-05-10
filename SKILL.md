---
name: cloudflare-tunnel-routes
description: Manage Cloudflare Tunnel ingress routes from the command line - add a new subdomain pointing to a local port, list current routes, remove routes, or set up a brand new tunnel. Use when the user wants to expose a local service to the internet via Cloudflare Tunnel (cloudflared), publish a project under a subdomain, get a public HTTPS URL for a localhost port, or asks "add a Cloudflare link/route/subdomain for project X". Works on any machine and any Cloudflare account - the only prerequisite is that `cloudflared` is installed.
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

The only requirement is `cloudflared` installed and authenticated. To verify, run `scripts/detect.sh` first - it returns key=value lines describing the current state, and exits non-zero if no tunnel is configured.

If detection fails, run `scripts/setup-new-tunnel.sh <name>` which handles login, tunnel creation, and starter config.

## Operations

### 1. Inspect current state

Always run detection first to know what to work with:

```bash
bash scripts/detect.sh
```

Output keys: `binary`, `config`, `tunnel_id`, `credentials`, `needs_sudo`, `service_mode` (`systemd`/`manual`/`none`).

### 2. List existing routes

```bash
bash scripts/list-routes.sh
```

Displays each `hostname [path] -> service` from the active config.

### 3. Add a new route

Adds DNS CNAME, inserts ingress block into `config.yml` (before the catch-all 404), validates the config, and restarts cloudflared - all in one command:

```bash
# Subdomain → local port
bash scripts/add-route.sh app.example.com 8080

# Subdomain → full URL (e.g. for HTTPS upstream)
bash scripts/add-route.sh api.example.com http://127.0.0.1:3000

# Path-based route on an existing apex domain
bash scripts/add-route.sh example.com 9015 --path /myapp
```

Behavior:
- Idempotent: if the DNS record or ingress block already exists, it skips that step.
- Backs up `config.yml` to `config.yml.bak.<timestamp>` before editing.
- Validates the new config; restores the backup automatically if validation fails.
- Restarts via `systemctl restart cloudflared` (systemd mode) or `pkill -HUP` (manual mode).

### 4. Remove a route

```bash
bash scripts/remove-route.sh oldproject.example.com
bash scripts/remove-route.sh example.com --path /oldapp
```

Removes the ingress block; prints API instructions for deleting the DNS CNAME (cloudflared CLI cannot delete DNS records).

### 5. Set up a new tunnel (one-time per machine)

```bash
bash scripts/setup-new-tunnel.sh my-server
```

Performs `cloudflared tunnel login` (opens browser), `cloudflared tunnel create`, writes a starter `~/.cloudflared/config.yml`, and optionally installs as a systemd service.

## Workflow for "Add a Cloudflare route for project X on port Y"

1. Run `bash scripts/detect.sh`. If exit code is non-zero, tell the user a tunnel needs to be set up first and offer `setup-new-tunnel.sh`.
2. Confirm the hostname with the user (e.g. `projectx.theirdomain.com`). Domain must be in a zone the tunnel's Cloudflare account owns.
3. Run `bash scripts/add-route.sh <hostname> <port>`.
4. Verify with `curl -I https://<hostname>` (allow ~5s for DNS propagation).

## Important Notes

- **Catch-all order matters.** The line `service: http_status:404` MUST stay last in the ingress list. `add-route.sh` inserts new entries immediately above it.
- **Path-based routes go before host-only routes for the same hostname.** Cloudflared matches first-hit, top-down. The script's insertion point preserves user-managed order.
- **DNS deletion needs the dashboard or API.** `cloudflared` only creates DNS records, never deletes them.
- **Hostnames must live in a zone owned by the authenticated account.** If the user wants `myapp.someoneelse.com`, that won't work unless the user manages that zone in Cloudflare.
- **Sudo is auto-detected.** If `config.yml` lives in `/etc/cloudflared/` and isn't writable, scripts wrap edits with `sudo` automatically.

## See Also

- `references/troubleshooting.md` - common errors and fixes (404 from tunnel, "tunnel not found", DNS conflicts, etc.)

# Troubleshooting Cloudflare Tunnel Routes

## "404 Not Found" served by the tunnel

The catch-all `service: http_status:404` matched because no ingress rule matched the incoming hostname.

Check:
1. `bash scripts/list-routes.sh` - is the hostname in the list?
2. If yes, verify the local service is listening: `curl -I http://127.0.0.1:<port>`
3. If the hostname is missing from the list, the ingress edit failed. Inspect `config.yml.bak.*` files.

## "An A, AAAA, or CNAME record with that host already exists"

A non-tunnel DNS record (e.g. an A record from before) is blocking the CNAME. `add-route.sh` stops with exit 1 and leaves `config.yml` untouched. Two options:
1. Delete the conflicting record in Cloudflare dashboard, then re-run `add-route.sh`.
2. If you are sure the name should move to this tunnel, run the command the script printed yourself (`cloudflared tunnel route dns --overwrite-dns <tunnel> <hostname>`), then re-run `add-route.sh`. The script never overwrites DNS on its own.

## "tunnel <id> not found" / "credentials file not found"

The `credentials-file:` path in `config.yml` doesn't exist on this machine. Common causes:
- Config copied from another machine but credentials weren't copied.
- Tunnel was deleted via the Cloudflare dashboard.

Fix: run `cloudflared tunnel list` to see existing tunnels, then either re-create credentials with `cloudflared tunnel token <id>` or run `setup-new-tunnel.sh` for a fresh tunnel.

## After `add-route.sh`, the URL still 404s

Possible causes:
1. **DNS propagation lag** - wait 30-60 seconds, retry.
2. **Cloudflared didn't restart** - if the script exited with status 3, it wrote the config but could not tell which cloudflared to restart (several systemd units use this config, or cloudflared runs by hand). Restart it as printed, or re-run with `CFTR_SERVICE=<unit>`. Otherwise check `systemctl status <unit>` (systemd) or `pgrep -af cloudflared` (manual).
3. **Path conflict** - a hostname-only rule above a path-based rule for the same hostname wins. `add-route.sh` now inserts new `--path` rules above an existing hostname-only rule, but older or hand-edited configs may still have the wrong order: move the more-specific (path-based) entry FIRST.
4. **Remotely-managed tunnel** - if the unit runs `cloudflared tunnel run --token ...`, cloudflared ignores the local `ingress:` list (the scripts warn about this). Manage routes in the Zero Trust dashboard instead.
5. **Wrong upstream port** - test locally: `curl -I http://127.0.0.1:<port>`.

## "context deadline exceeded" / "no healthy origins"

Cloudflared can't reach the local service. Either:
- Service isn't running on the configured port.
- Service is bound to `127.0.0.1` only but cloudflared runs in a different network namespace (e.g. Docker). Use `0.0.0.0:port` or the host-network mode.

## Validation step says "ingress validate" failed

The script restores the previous config automatically. Common causes of invalid config:
- A YAML indentation error introduced by manual edits to the file.
- Duplicate `service: http_status:404` entries (must be exactly one, at the end).

To diagnose: `cloudflared --config /path/to/config.yml tunnel ingress validate`.

## Permission denied editing `/etc/cloudflared/config.yml`

The detection script sets `needs_sudo=true` automatically and the helper scripts call `sudo` accordingly. If the user lacks sudo on this machine, instruct them to either:
- Move the config to `~/.cloudflared/config.yml` (and run cloudflared as their user), OR
- Have an admin run the scripts.

## Multiple tunnels on the same machine

`detect.sh` picks the first matching `config.yml` in this order:
1. `/etc/cloudflared/config.yml`
2. `/etc/cloudflared/config.yaml`
3. `~/.cloudflared/config.yml`
4. `~/.cloudflared/config.yaml`

To target a non-default tunnel, set `CFTR_CONFIG=/path/to/other.yml` (and, if needed, `CFTR_BINARY=/path/to/cloudflared`) when running the scripts. They restart only the systemd unit whose `ExecStart` passes that config via `--config`; if none or several match, nothing is restarted and they exit 3. Name the unit with `CFTR_SERVICE=<unit>` in that case.

## "needs root: re-run in a terminal or with sudo"

The config is readable only by root and `sudo` needs a password, but there is no terminal to type it into (e.g. an AI agent or CI running the script). `detect.sh` uses `sudo -n` there instead of hanging on a hidden prompt, and exits 3. Run the command yourself in a terminal, or with `sudo`.

## "refusing to run ... as root"

When the config needs `sudo`, the scripts run `cloudflared tunnel ingress validate` as root. They refuse unless the `cloudflared` binary (after following symlinks) is owned by root and not group- or world-writable, because anyone able to rewrite it would otherwise get root. Install `cloudflared` from the official packages (owned by root), or fix the ownership/permissions.

## "another cftr run holds the lock"

Only one `add-route.sh` / `remove-route.sh` may change a config at a time. Wait for the other run to finish. Where `flock` is missing (macOS) the lock is a directory `config.yml.lock.d` next to the config; if a crashed run left it behind and nothing else is running, remove that directory.

## How to remove a DNS CNAME (the script can't)

Cloudflared CLI only creates DNS records. To delete:

**Via dashboard:** Cloudflare → Domain → DNS → find the CNAME → Delete.

**Via API:**
```bash
ZONE_ID="<your zone id>"
HOSTNAME="oldproject.example.com"
TOKEN="<api token with DNS:Edit on zone>"

# Find record ID
RECORD_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$HOSTNAME" \
    | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

# Delete
curl -X DELETE -H "Authorization: Bearer $TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID"
```

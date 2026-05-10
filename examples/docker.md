# Expose a Docker container

Run a service in Docker on your laptop / home server, give it a permanent HTTPS URL.

The recipe is identical to the bare-metal cases — `cloudflared` only cares about the local TCP port. Whether the listener is a Python process, a Go binary, or a Docker container is invisible to the tunnel.

## Container

Any image that exposes an HTTP port works. Example: a tiny static site.

```bash
docker run -d --rm \
    --name demo \
    -p 127.0.0.1:8080:80 \
    nginx:alpine
```

Note the `-p 127.0.0.1:8080:80` — bind only to localhost. The tunnel handles public access; nothing should be on `0.0.0.0`.

## Add the route

```bash
bash scripts/add-route.sh demo.example.com 8080 \
    --comment "nginx-alpine demo"
```

Verify:

```bash
curl -sI https://demo.example.com/ | head -1
#   HTTP/2 200
```

## docker compose

Same idea — bind to `127.0.0.1` and let the tunnel front it.

`compose.yml`:

```yaml
services:
  app:
    image: ghcr.io/youruser/yourapp:latest
    ports:
      - "127.0.0.1:9000:9000"
    restart: unless-stopped
```

```bash
docker compose up -d
bash scripts/add-route.sh app.example.com 9000 --comment "App via docker compose"
```

## Multiple containers behind one domain

Path-based routing keeps things tidy:

```bash
docker run -d -p 127.0.0.1:9001:80 --name web nginx:alpine
docker run -d -p 127.0.0.1:9002:80 --name api ghcr.io/youruser/api:latest

bash scripts/add-route.sh example.com 9001 --path "/web.*"  --comment "static site"
bash scripts/add-route.sh example.com 9002 --path "/api.*"  --comment "JSON API"
```

## Tear-down

```bash
docker stop demo
bash scripts/remove-route.sh demo.example.com
# DNS CNAME stays — remove it via the Cloudflare dashboard if you don't want it.
```

## Notes

- **Don't run `cloudflared` inside the container.** This skill assumes the tunnel daemon runs on the host, not inside an app image. Cloudflare provides a separate `cloudflare/cloudflared` image if you want fully containerized tunneling — but then you wouldn't use these scripts anyway.
- **Networking gotcha on Linux:** if Docker bypasses the loopback (e.g. with `--network=host`), make sure the listener still ends up on `127.0.0.1`. `cloudflared` reaches services via loopback by default.
- **WSL:** the same pattern works under WSL2; bind containers to `127.0.0.1` inside WSL and run `cloudflared` from WSL too. Don't mix Windows-side and WSL-side processes for the same tunnel.

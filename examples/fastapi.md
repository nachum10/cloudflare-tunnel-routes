# Expose a FastAPI service

Useful for shipping a quick API from your laptop / home server without renting cloud compute or dealing with Vercel/Fly cold starts.

## App

`main.py`:

```python
from fastapi import FastAPI

app = FastAPI()

@app.get("/health")
def health():
    return {"ok": True}

@app.get("/")
def root():
    return {"message": "Hello from a permanent URL"}
```

## Run + expose

```bash
# 1. Start uvicorn, localhost-only
uvicorn main:app --host 127.0.0.1 --port 3000 &

# 2. Tunnel route
bash scripts/add-route.sh api.example.com http://127.0.0.1:3000 \
    --comment "Personal FastAPI service"

# 3. Verify
curl -s https://api.example.com/health
#   {"ok":true}
```

## Path-based routing on a single domain

You can host several APIs under one domain by adding paths:

```bash
bash scripts/add-route.sh example.com 3000 --path "/api/v1.*" --comment "v1 API"
bash scripts/add-route.sh example.com 3001 --path "/api/v2.*" --comment "v2 API"
```

`cloudflared` matches first-hit, top-down. `add-route.sh` inserts new rules above the catch-all `404`, so the order you add them in is kept. One exception keeps path rules reachable: if `example.com` already has a host-only rule (no `path:`), a new `--path` rule for `example.com` is inserted directly *above* that host-only rule, because the host-only rule would otherwise match every request first.

## Production hardening

A public URL with no auth is exactly that — public. For anything sensitive, add a [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/applications/configure-apps/self-hosted-apps/) policy on the hostname (SSO / IP allowlist / one-time PIN), and consider a [WAF rule](https://developers.cloudflare.com/waf/) for rate limiting.

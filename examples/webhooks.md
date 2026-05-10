# Receive webhooks on your laptop

Most webhook providers (GitHub, Stripe, Slack, Linear, Twilio…) need a public HTTPS URL they can `POST` to. A persistent Cloudflare Tunnel route is the cleanest way to receive them on a local dev machine without spinning up a server.

## Receiver

`webhook_server.py` (FastAPI; same idea works in any framework):

```python
import json
from fastapi import FastAPI, Request

app = FastAPI()

@app.post("/webhook/github")
async def github(req: Request):
    payload = await req.json()
    print(json.dumps(payload, indent=2))
    return {"received": True}
```

## Run + expose

```bash
# 1. Start the receiver locally
uvicorn webhook_server:app --host 127.0.0.1 --port 4000 &

# 2. Add a tunnel route - permanent URL even after laptop restarts
bash scripts/add-route.sh hooks.example.com 4000 \
    --comment "Local webhook receiver"

# 3. Point GitHub / Stripe / Slack at:
#    https://hooks.example.com/webhook/github
```

## Smoke test

Hit it from your phone or another machine to confirm it's reachable:

```bash
curl -sS -X POST https://hooks.example.com/webhook/github \
    -H 'Content-Type: application/json' \
    -d '{"event":"ping"}'
```

## Two providers, one domain

Use path-based routing so each provider gets a distinct URL but you only run one tunnel:

```bash
bash scripts/add-route.sh hooks.example.com 4000 --path "/github.*" --comment "GitHub hooks"
bash scripts/add-route.sh hooks.example.com 4001 --path "/stripe.*" --comment "Stripe hooks"
```

## Verify provider signatures

Cloudflare terminates TLS at the edge, so the request body and headers reach your local service unchanged. That means signature verification (HMAC, JWT, etc.) works exactly as documented by the provider — no extra steps.

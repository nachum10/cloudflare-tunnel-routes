# Expose a Gradio app

Replace `share=True` (random ngrok-style URL that resets every restart) with a permanent Cloudflare Tunnel URL.

## App

`app.py`:

```python
import gradio as gr

def greet(name: str) -> str:
    return f"Hello, {name}!"

# Bind to localhost on a fixed port - the tunnel handles public access.
gr.Interface(fn=greet, inputs="text", outputs="text").launch(
    server_name="127.0.0.1",
    server_port=7860,
)
```

## Run + expose

```bash
# 1. Start the app (foreground or systemd / pm2 / tmux - your choice)
python app.py &

# 2. Wire up the tunnel route - one time per hostname
bash scripts/add-route.sh demo.example.com 7860 \
    --comment "Gradio greeter demo"

# 3. Verify
curl -I https://demo.example.com/
#   HTTP/2 200
#   ...
```

The URL `https://demo.example.com/` is now permanent — restart the Python process whenever you want; the route stays.

## Tear-down

```bash
bash scripts/remove-route.sh demo.example.com
# then delete the DNS CNAME via the Cloudflare dashboard
```

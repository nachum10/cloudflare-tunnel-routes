# Prompts — copy-paste recipes

Ready-to-use prompts for Claude Code, Cursor, Codex, and Continue. Pick one, fill in the blanks, paste.

All of these assume:
- `cloudflared` is installed
- A tunnel is set up (run `bash scripts/setup-new-tunnel.sh <name>` once if not)
- The target hostname is on a domain in your Cloudflare account

---

## Claude Code

### Install + expose Gradio

```text
Install cloudflare-tunnel-routes from
https://github.com/nachum10/cloudflare-tunnel-routes
and use it to expose my Gradio app on port 7860 at demo.example.com.

Always run --diff before applying so I can see what changes.
```

### Replace `share=True` for an existing app

```text
My Gradio app's share link keeps changing on every restart. Use
the cloudflare-tunnel-routes skill to give it a permanent URL at
demo.example.com pointing to localhost:7860. Show the diff first.
```

### Webhook receiver for GitHub

```text
I'm running a webhook receiver locally on port 4000. Use
cloudflare-tunnel-routes to expose it at hooks.example.com so
GitHub can POST to https://hooks.example.com/webhook/github.
Add a comment "GitHub webhook receiver" to the new ingress block.
```

### List + clean up old routes

```text
Show me all the Cloudflare tunnel routes I have configured.
Then remove any route pointing to a port that's no longer in use,
asking me before each removal.
```

---

## Cursor

(Trigger the [Cursor Project Rule](./.cursor/rules/cloudflare-tunnel-routes.mdc) by mentioning "Cloudflare tunnel" or "permanent URL" in your prompt.)

### Expose FastAPI

```text
Use the cloudflare-tunnel-routes scripts in this workspace to
create a persistent Cloudflare Tunnel URL for my local FastAPI app
running on port 8000. Hostname: api.example.com. Preview the diff
before applying.
```

### Path-based routing under one domain

```text
Set up two ingress routes on example.com using cloudflare-tunnel-routes:
  - /api/v1.*  →  localhost:9001
  - /api/v2.*  →  localhost:9002

Use --diff for both, apply after I confirm.
```

---

## Codex (OpenAI / GitHub Copilot Chat)

### Add route with --diff

```text
Use the cloudflare-tunnel-routes repo to add a tunnel route for my
Streamlit dashboard on localhost:8501 at dash.example.com.

Steps:
1. Run scripts/detect.sh and confirm a tunnel exists.
2. Show me the diff with `add-route.sh dash.example.com 8501 --diff`.
3. Wait for my OK.
4. Apply with `add-route.sh dash.example.com 8501`.
5. Verify with `curl -I https://dash.example.com/`.
```

### Container exposure

```text
I have a docker container listening on 127.0.0.1:9000. Use
cloudflare-tunnel-routes to give it a permanent HTTPS URL at
app.example.com. Ask me to confirm before any change.
```

---

## Continue / generic IDE assistants

### One-shot deploy-style ask

```text
Read AGENTS.md and llms.txt in this repo, then use
cloudflare-tunnel-routes to map my local app on port {{PORT}} to
{{HOSTNAME}}. Always preview with --diff and stop on the first
non-zero exit.
```

### Bulk migration

```text
I'm migrating from ngrok. I have these mappings:

  - 7860 → demo.example.com
  - 8501 → dash.example.com
  - 4000 → hooks.example.com

For each, use cloudflare-tunnel-routes to add the route. Preview
each one with --diff and confirm with me before applying.
```

---

## Tips for writing your own prompts

| Include | Why |
|---|---|
| The repo URL or "use the cloudflare-tunnel-routes skill" | helps the agent locate the tool |
| The exact port number | prevents the agent from guessing |
| The exact hostname (or "ask me") | prevents typo'd DNS records |
| "Preview with --diff first" / "show me the diff" | enforces the safety rail explicitly |
| "Stop on the first non-zero exit" | prevents retry loops |
| Optional: `--comment "..."` text | leaves a paper trail in `config.yml` |

If you want the agent to follow the safety protocol mechanically, add this footer to any prompt:

> Follow the protocol in `.cursor/rules/cloudflare-tunnel-routes.mdc` (or `AGENTS.md`): detect → ask → diff → confirm → apply → curl. One mutating command per turn.

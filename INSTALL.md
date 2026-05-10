# Installation

`cloudflare-tunnel-routes` is a collection of Bash scripts. There is nothing to compile and no runtime dependency to install beyond `cloudflared` itself. Pick the install style that matches your environment.

---

## TL;DR

```bash
git clone https://github.com/nachum10/cloudflare-tunnel-routes.git
cd cloudflare-tunnel-routes
./install.sh        # symlink as Claude Code skill (optional but recommended)
```

That's it. Now you can call any script directly:

```bash
bash scripts/add-route.sh demo.example.com 7860
```

---

## Prerequisites

| Requirement | Why | How |
|---|---|---|
| `bash` 4+ | scripts use `mapfile`, `[[ ]]`, etc. | preinstalled on Linux/macOS; on Windows use WSL or Git Bash |
| `awk`, `grep`, `sed`, `diff` | text processing | preinstalled everywhere |
| `cloudflared` | the actual tunnel | see below |
| Cloudflare account + domain | required for routing | free; sign up at https://dash.cloudflare.com |
| `yq` (optional) | nicer output for `list-routes.sh` on complex configs | `brew install yq` / `apt install yq` / [download](https://github.com/mikefarah/yq) |

### Install `cloudflared`

**macOS:**
```bash
brew install cloudflared
```

**Debian / Ubuntu:**
```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb
```

**Generic Linux:**
```bash
sudo curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared
sudo chmod +x /usr/local/bin/cloudflared
```

**Windows (PowerShell as admin):**
```powershell
winget install --id Cloudflare.cloudflared
```

Verify:
```bash
cloudflared --version
```

---

## Install path 1 — As a Claude Code skill (recommended for Claude users)

```bash
git clone https://github.com/nachum10/cloudflare-tunnel-routes.git ~/Apps/cloudflare-tunnel-routes
cd ~/Apps/cloudflare-tunnel-routes
./install.sh
```

`install.sh` symlinks the repo to `~/.claude/skills/cloudflare-tunnel-routes/`. Claude Code auto-discovers it via the `SKILL.md` front-matter and invokes it whenever the user says "add a Cloudflare route", "expose port X", "publish on a subdomain", etc.

To verify Claude Code picked it up: open a new session and ask "list my Cloudflare tunnel routes". Claude Code should run `bash scripts/list-routes.sh` from this repo.

---

## Install path 2 — As a plain Bash CLI

```bash
git clone https://github.com/nachum10/cloudflare-tunnel-routes.git
cd cloudflare-tunnel-routes
chmod +x scripts/*.sh
# optional: add to PATH
export PATH="$PWD/scripts:$PATH"
```

Then run `add-route.sh app.example.com 8080` from any directory.

---

## Install path 3 — For AI coding agents (Cursor / Codex / etc.)

If your environment is an AI coding agent that already has shell access, add the project to the workspace and read [`AGENTS.md`](./AGENTS.md). It documents the recognition criteria, the install command, the mandatory safety rails (always preview with `--diff`, never invent hostnames, etc.), and example flows for Gradio / Streamlit / FastAPI / webhooks.

The agent should keep `llms.txt` and `AGENTS.md` in its context for any session where the user is working with local services that might benefit from a permanent URL.

---

## First-time tunnel setup

If you've never used `cloudflared` on this machine:

```bash
bash scripts/setup-new-tunnel.sh my-server
```

This:
1. Opens a browser to log into Cloudflare (`cloudflared tunnel login`).
2. Creates a tunnel named `my-server`.
3. Writes a starter `~/.cloudflared/config.yml` with only the catch-all `404`.
4. Optionally installs `cloudflared` as a `systemd` service (Linux only).

You only need to run this once per machine.

---

## Uninstall

```bash
# Remove the Claude Code skill symlink (if installed)
rm ~/.claude/skills/cloudflare-tunnel-routes

# Remove the repo
rm -rf ~/Apps/cloudflare-tunnel-routes
```

The tunnel itself, the DNS records, and `cloudflared` stay — uninstalling this tool only removes the helper scripts. To remove the tunnel: `cloudflared tunnel delete <name>` and clean up DNS in the Cloudflare dashboard.

---

## Verify the install

Run the hermetic test suite — it doesn't touch your real `cloudflared` config:

```bash
make test
# or:
bash tests/run-tests.sh
```

Expected: `PASS: <N>`, `FAIL: 0`.

---

## Troubleshooting install issues

| Symptom | Fix |
|---|---|
| `command not found: bash` on macOS | run with `/bin/bash scripts/...`; older macOS bash is fine |
| `mapfile: command not found` | bash < 4. Upgrade with `brew install bash`. |
| Scripts not executable | `chmod +x scripts/*.sh` |
| Claude Code doesn't pick up the skill | restart Claude Code; verify `~/.claude/skills/cloudflare-tunnel-routes/SKILL.md` exists and is readable |
| `cloudflared: command not found` | install per the prerequisites table above |

For runtime errors (after install) see [`references/troubleshooting.md`](./references/troubleshooting.md).

# Release process

`cloudflare-tunnel-routes` follows [SemVer](https://semver.org/) — but in practice this is a small Bash project where the public surface is the CLI flags and the script filenames. The rules below tell you when each part of `MAJOR.MINOR.PATCH` should bump.

---

## What counts as a breaking change (MAJOR)

Bump `MAJOR` when any of these change in a way that would break an existing user or agent calling the tool:

- A script is **renamed**, **removed**, or **moved** out of `scripts/`.
- An existing CLI flag changes meaning (e.g. `--keep-dns` would now actually delete DNS).
- An environment variable name changes (`CFTR_CONFIG`, `CFTR_BINARY`).
- The `SKILL.md` `name` field changes.
- The exit-code contract of `detect.sh` changes (currently: `0` ok, `1` no tunnel, `2` tampered).
- A safety rail documented in `AGENTS.md` is relaxed.

## What counts as a feature (MINOR)

Bump `MINOR` for additive, backwards-compatible changes:

- New script in `scripts/`.
- New CLI flag that defaults to off.
- New environment variable override.
- New `examples/*.md`.
- New optional integration (e.g. `yq` codepath in `list-routes.sh`).

## What counts as a patch (PATCH)

Bump `PATCH` for:

- Bug fixes that don't change documented behavior.
- README / docs improvements.
- Test additions and refactors.
- Internal awk/grep refactors that produce the same output.

---

## Cutting a release

1. **Make sure `main` is green.** Check the GitHub Actions badge or run `make test` locally.

2. **Update CHANGELOG-style notes.** A single-paragraph release description in the `gh release create` body is enough for now; we don't keep a separate `CHANGELOG.md`.

3. **Tag and push.**

   ```bash
   git tag -a v0.X.0 -m "v0.X.0 - <one-line summary>"
   git push origin v0.X.0
   ```

4. **Create the GitHub release.**

   ```bash
   gh release create v0.X.0 \
       --title "v0.X.0 - <one-line summary>" \
       --notes "$(cat <<'EOF'
   Highlights:
   - <bullet>
   - <bullet>

   Breaking changes:
   - none / <bullet>

   Verify: bash tests/run-tests.sh
   EOF
   )"
   ```

5. **Verify the release page** has the badge build associated and links work (`AGENTS.md`, `INSTALL.md`, `examples/`).

---

## Pre-release checklist

Before tagging, run:

```bash
make lint           # syntax check
make test           # full suite
bash scripts/detect.sh && echo "detect smoke ok"
```

And eyeball:

- `README.md` Top section reflects the actual feature set.
- `SKILL.md` description still matches user phrasings the skill should fire on.
- `AGENTS.md` safety rails still match script behavior.
- `llms.txt` links still resolve.
- `INSTALL.md` install commands still work on a clean clone.
- `examples/*.md` flows still match script flags.

---

## Versioning history

| Version | Highlights |
|---------|-----------|
| [`v0.1.0`](https://github.com/nachum10/cloudflare-tunnel-routes/releases/tag/v0.1.0) (2026-05-10) | Initial public release. Full CLI: `add-route`, `remove-route`, `list-routes`, `detect`, `setup-new-tunnel`. `--dry-run`, `--diff`, `--comment`. `CFTR_CONFIG` / `CFTR_BINARY` env overrides. `yq` optional path for `list-routes`. 78-test hermetic suite. CI on every push/PR. Claude Code skill + `AGENTS.md` + `llms.txt` + Cursor Project Rule for AI agents. |

(Future entries get appended here when each release is cut.)

---

## What is NOT shipped

These are explicit non-goals for v0.x — listed so contributors don't open PRs for them:

- A full YAML parser for mutating ops (round-trips clobber comments/style; `awk` is intentional).
- Cloudflare DNS API integration (out of scope; user removes records via dashboard or their own tooling).
- A web UI / TUI (different product surface; possible v1.x layer 3 if demand emerges).
- A formatting / normalization tool for `config.yml` (would change file shape behind the user's back).
- Auto-update / self-update from `main` (use `git pull`).

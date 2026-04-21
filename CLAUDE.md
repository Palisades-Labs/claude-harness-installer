# CLAUDE.md — claude-harness-installer

*Last Edited: 2026-04-21*

Operator notes for editing the bootstrap installer. Not shipped to end users.

## Read first

For architecture, lifecycle, and the full gotcha catalog, read these directives — they're the canonical source and apply across the whole harness, not just this repo:

- `~/.claude/directives/palisades-labs-harness.md` — three-repo architecture, three roles, lifecycle walkthroughs, credential discipline, distribution model.
- `~/.claude/directives/palisades-labs-harness-troubleshooting.md` — every known failure mode plus the guard or fix for it. Read the **§ Session gotchas — 2026-04-21** subsection in particular before editing `bootstrap.sh`.

This file covers only the operator workflow specific to editing the installer scripts.

## Update procedure

1. Edit `bootstrap.sh` or `bootstrap.ps1` locally.
2. Test on a sandbox machine (claude-test-1 / Felino / fresh VM). Drill both the golden path and at least the wrong-passphrase edge case.
3. Commit with a message naming the bug pattern the change guards against — the existing commit log is a good model.
4. Push to `main`. **`raw.githubusercontent.com` can take 5–30+ minutes to refresh.** During active debugging, expect to use commit-SHA-pinned URLs or `scp` the script directly until the CDN catches up.
5. If the change alters the install-command interface (new required env var, new positional arg), update `~/repos/plugin-client-admin/skills/generate-installer/SKILL.md` in the same change — cross-layer invariant.

## Cross-layer references

When you change `bootstrap.sh` / `bootstrap.ps1` CLI surface, update these in the same change:

- `~/repos/claude-harness-installer/README.md` — user-facing doc
- `~/repos/claude-harness-installer/EMPLOYEE-GUIDE.md` — plain-English employee install guide
- `~/repos/claude-harness-master/readme-template.md` — employee-facing (rendered per client)
- `~/repos/claude-harness-master/admin-guide-template.md` — admin-facing (rendered per client → `ADMIN.md` via `onboard-client.sh`)
- `~/repos/plugin-client-admin/skills/generate-installer/SKILL.md` — emits the install command; must match bootstrap arg parsing exactly
- `~/.claude/skills/onboard-client/` — derives the same marketplace name from `<org>/<repo>` as bootstrap does (strip `-claude-harness` then `-harness`)

## Drift notes (open gaps)

- **Version floor not enforced for Claude Code itself.** Bootstrap doesn't check `claude --version`. A machine with old Claude installed silently passes; downstream errors look like marketplace auth bugs. Consider documenting "ensure Claude Code 2.1.109+" in the EMPLOYEE-GUIDE prereqs section, and let `claude doctor` surface the actual mismatch.
- **Windows PowerShell drill incomplete.** The 2026-04-21 drill covered only macOS via `claude-test-1`. `bootstrap.ps1` changes are untested end-to-end. Track as TODO until a Windows machine is available.
- **`/onboard-client` template backfill not automated.** When new templates land (e.g., `admin-guide-template.md` → `ADMIN.md` wiring in 2026-04-18), only newly-onboarded clients receive them. Already-onboarded clients need a one-shot manual backfill.

# CLAUDE.md — claude-harness-installer

*Last Edited: 2026-04-18*

Operator notes for future Claude Code / Aaron sessions editing this repo. Not shipped to end users.

## Purpose

Single-file curl|bash bootstrapper that installs the Palisades-Labs Claude Code harness on a developer's laptop. Ships from this public repo so client employees don't need read access to `claude-harness-master`. Two scripts:

- `bootstrap.sh` — macOS + Linux
- `bootstrap.ps1` — Windows

Both serve two audiences via a mode flag:

| Mode | Flag | GITHUB_TOKEN source | Who | Touches `gh` |
|---|---|---|---|---|
| Employee | (default) | env var, pre-baked into the install command | Client teammates | Never |
| Admin | `--admin` / `-Admin` | `gh auth token` (after `gh auth login --web`) | Consultant + client admins | Yes |

## Prereqs

`bootstrap.sh` installs these if missing: `jq`, `git`, `rsync`, `node`, `npm`, `age`. Plus `gh` in admin mode. `bootstrap.ps1` does the same via `winget` → `choco` fallback.

`age` is load-bearing: added in commit `2dcc8ca` for credential decryption. If it's not installed, the credentials step fails silently and the harness loses access to team API keys (Tavily, etc.).

## Passphrase lifecycle

1. **Admin generates** via `/tools:manage-credentials` on their own machine (after admin bootstrap). Skill encrypts `credentials.env.age` with `age --encrypt --passphrase`, pushes to the client's harness repo, prints the passphrase for distribution. (Consultant may run it from the master repo for demos, drills, or emergency rotations — not the canonical path.)
2. **Admin distributes** to employees out-of-band (Slack DM, 1Password share, in-person) — never in the install command itself. `/generate-installer` emits a separate passphrase block explicitly labeled for separate distribution.
3. **Bootstrap prompts** the employee once via `read -rs` (bash) / `Read-Host -AsSecureString` (PowerShell). Input lands on fd 3 (tty), not stdin.
4. **Bootstrap stores** the passphrase:
   - macOS: `security add-generic-password -a $USER -s palisades-labs-harness -w <pass>` (Keychain)
   - Linux: `~/.claude/credentials/.passphrase` chmod 600
   - Windows: DPAPI-protected file `~/.claude/credentials/.passphrase`
5. **Bootstrap decrypts** the repo's `credentials.env.age` → `~/.claude/credentials/credentials.env` (mode 600). Shell rc gets a `set -a; source …; set +a` stanza so future terminals load the vars.

If `credentials.env.age` is missing from the repo, bootstrap logs a warn and proceeds. Re-running after the admin populates it picks up the creds.

## Idempotence

Every mutating step is guarded:

- rc-file markers (`# Palisades-Labs claude-harness-installer: GITHUB_TOKEN` and `# Palisades-Labs claude-harness-installer: credentials source`) prevent duplicate exports.
- macOS `.bash_profile` wiring (`1aacd2b`) uses a marker comment for idempotence.
- `settings.json` merge uses `jq` to produce the target state, then `cmp -s` to short-circuit writes when the desired state already matches. PowerShell equivalent compares pre/post JSON strings.
- `git config --global url.X.insteadOf Y` is an overwrite-same-value no-op.
- `ssh-keygen -F github.com` gates the `ssh-keyscan` append.
- Keychain entry is `security delete … || true` before `add` to preserve re-run safety.

Running bootstrap twice in a row must print `[ok]` / `already present` lines for every step and leave no file modified. This is the single most important invariant — treat any diff across re-runs as a bug.

## Known issues + guards

| Issue | Where | Guard |
|---|---|---|
| curl\|bash corrupted by child processes reading stdin mid-script | bash | Entire body wrapped in `main()` — bash parses the full file before executing. Pattern from `rustup`/`nvm`. |
| `[[ -r /dev/tty ]]` returns true under non-interactive SSH but `open()` fails with "Device not configured" | bash | `(exec 3</dev/tty) 2>/dev/null` subshell probe (`50c22b5`). Subshell's fd 3 dies with it; parent stays clean. |
| `exec < /dev/tty` steals bash's stdin, halts the script when invoked as `curl | bash` | bash | Put tty on fd 3 instead; use `<&3` for interactive reads. |
| Claude Code marketplace cloner uses SSH URLs; employees have no SSH keys on their GH accounts | both | `git config --global url."https://github.com/".insteadOf "git@github.com:"` + inline env-var credential helper in employee mode. |
| macOS Terminal.app launches bash as a *login* shell, which sources `.bash_profile` but not `.bashrc` | bash | `1aacd2b` wires `.bash_profile` to source `.bashrc`. Without it, baked env vars never load in new terminals. |
| Claude Code <2.1.109 has plugin marketplace auth bugs | npm installer | Bootstrap currently only checks binary presence, not version. **Gap** — should probably force-upgrade when below the floor. |
| Admin mode re-run prompts for passphrase again | bash / ps | **Gap to verify in drill** — if keychain already has the entry, re-prompting is user-hostile. |
| Passphrase `read -rs <&3` dies under non-interactive SSH (EOF + `set -e`) | bash | `|| HARNESS_PASSPHRASE=""` absorbs EOF so the "No passphrase entered" warn path handles it. Surfaced 2026-04-18 drill when admin bootstrap was run over non-TTY SSH; script died silently (exit code masked by `| tee`) after the GITHUB_TOKEN export but before the settings merge. |

## Update procedure

1. Edit `bootstrap.sh` or `bootstrap.ps1` locally.
2. Test on a sandbox machine (Felino / Laptop 2 / fresh VM). Drill both golden path and at least the wrong-passphrase edge case.
3. Commit with a message that mentions the bug pattern the change guards against — the existing log (`50c22b5`, `95d7d71`, etc.) is a good model.
4. Push to `main`. The next `curl` from any install command hits the new version — there's no versioning or CDN cache to flush.
5. If the change alters the install-command interface (new required env var, new positional arg), update `tools-template/skills/generate-installer/SKILL.md` in the same PR — cross-layer invariant.

## Cross-layer references

These files must stay aligned with this repo. When you change `bootstrap.sh` / `bootstrap.ps1` CLI surface, update these in the same change:

- `~/repos/claude-harness-installer/README.md` — user-facing doc
- `~/repos/claude-harness-master/readme-template.md` — employee-facing (rendered per client)
- `~/repos/claude-harness-master/admin-guide-template.md` — admin-facing (rendered per client → `ADMIN.md` via `onboard-client.sh`)
- `~/repos/claude-harness-master/tools-template/skills/generate-installer/SKILL.md` — emits the install command; must match bootstrap arg parsing exactly
- `~/.claude/skills/onboard-client/` — derives the same marketplace name from `<org>/<repo>` as bootstrap does (strip `-claude-harness` suffix)

## Drift notes (open gaps flagged 2026-04-18)

- **Version floor not enforced.** Bootstrap checks `command -v claude` but not `claude --version`. A machine with 2.1.92 installed passes the check silently and then fails marketplace auth inside Claude. Consider `npm install -g @anthropic-ai/claude-code@latest` unconditionally, or a version comparison.
- **Windows PowerShell drill missing.** The 2026-04-18 drill covers only macOS; `bootstrap.ps1` changes (`2dcc8ca`, `efa7422`) are untested end-to-end. Track as TODO until a Windows machine is available.
- **Existing clients don't get new template additions.** `onboard-client.sh` skips template render when scaffold already exists (by design — resume is safe). New additions like ADMIN.md (wired 2026-04-18) reach only newly-onboarded clients. Backfill is manual until a generic mechanism exists.

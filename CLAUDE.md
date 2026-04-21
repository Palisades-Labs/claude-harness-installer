# CLAUDE.md — claude-harness-installer

*Last Edited: 2026-04-21*

Operator notes for future Claude Code / Aaron sessions editing this repo. Not shipped to end users.

## Purpose

Single-file curl|bash bootstrapper that decrypts the client harness's encrypted credentials file on a developer's laptop. Ships from this public repo so client employees don't need read access to `claude-harness-master`. Two scripts:

- `bootstrap.sh` — macOS + Linux
- `bootstrap.ps1` — Windows

**Decrypt-only** (post-2026-04-15 migration). The script does NOT install Claude Code, fetch GitHub PATs, register marketplaces, or merge `settings.json`. Those are handled by Claude Desktop (marketplace add + sync) and the user's existing Claude Code install. The script's single job: take the age-encrypted `credentials/credentials.env.age` that Claude Desktop synced from the marketplace clone, prompt for the passphrase, decrypt it to `~/.claude/credentials/credentials.env`, and add a source stanza to the shell rc.

## Prereqs

`bootstrap.sh` auto-installs `age` from GitHub releases to `~/.local/bin/age` if missing — no Homebrew or sudo required. The current implementation downloads the pinned version `v1.3.1` (hardcoded; `_install_age` in the script). Bumping the version is a one-line edit.

`age` is the only external dependency in the decrypt-only flow. If the auto-install fails (network error, unsupported architecture), the script exits with a clear message pointing at https://github.com/FiloSottile/age/releases.

**Resolved 2026-04-21:** `_install_age` now also writes `export PATH="$HOME/.local/bin:$PATH"` to the user's shell rc (`.zshrc` or `.bashrc`) with marker comment `# Palisades-Labs claude-harness-installer: ~/.local/bin on PATH (for age)`. Re-runs from a fresh terminal find `age` without re-downloading. Idempotence preserved via the `grep -Fq "$path_marker"` guard.

## Passphrase lifecycle

1. **Admin sets** the passphrase in their own password manager (1Password, Bitwarden) BEFORE invoking `/client-admin:manage-credentials`. They paste it at `age`'s native passphrase prompt; `age` confirms and encrypts. The passphrase never enters Claude's chat context.
2. **Admin distributes** to employees out-of-band (1Password share preferred; Slack DM / in-person as fallback) — never in the same message as the install command. `/client-admin:generate-installer` defaults to placeholder mode for the passphrase block (the admin substitutes the real value in the outgoing message draft, not back into the chat).
3. **Bootstrap prompts** the employee once via `read -rs <&3` (bash) or `Read-Host -AsSecureString` (PowerShell). Input lands on fd 3 (`/dev/tty`), not stdin (which is the curl pipe).
4. **Bootstrap stores** the passphrase:
   - macOS: `security add-generic-password -a $USER -s palisades-labs-harness -w <pass>` (Keychain). Wraps in conditional — failure here is acceptable (non-GUI session, "User interaction is not allowed") and falls through to a "passphrase will be re-prompted on next run" warn.
   - Linux: `~/.claude/credentials/.passphrase` chmod 600.
   - Windows: DPAPI-protected file `~/.claude/credentials/.passphrase`.
5. **Bootstrap decrypts** the marketplace-synced `credentials/credentials.env.age` → `~/.claude/credentials/credentials.env` (mode 600). Shell rc gets a `set -a; source …; set +a` stanza so future terminals load the vars.

If `credentials/credentials.env.age` is missing from the marketplace clone, bootstrap fails with a clear "marketplace not synced yet" error. The fix path is in Claude Desktop (wait for sync to complete, or remove + re-add the marketplace).

## Idempotence

Every mutating step is guarded:

- rc-file marker (`# Palisades-Labs claude-harness-installer: credentials source`) prevents duplicate exports.
- macOS `.bash_profile` wiring uses a marker comment for idempotence (sources `.bashrc` from `.bash_profile` to fix the login-shell quirk).
- Keychain entry is `security delete … || true` before `add` to preserve re-run safety.

Running bootstrap twice in a row must print `[ok]` / `already present` lines for every step and leave no file modified beyond `credentials.env` (rewritten with the freshly-decrypted contents). Treat any other diff across re-runs as a bug.

## Known issues + guards

| Issue | Where | Guard |
|---|---|---|
| curl\|bash corrupted by child processes reading stdin mid-script | bash | Entire body wrapped in `main()` — bash parses the full file before executing. Pattern from `rustup`/`nvm`. |
| `[[ -r /dev/tty ]]` returns true under non-interactive SSH but `open()` fails with "Device not configured" | bash | `(exec 3</dev/tty) 2>/dev/null` subshell probe. Subshell's fd 3 dies with it; parent stays clean. |
| `exec < /dev/tty` steals bash's stdin, halts the script when invoked as `curl | bash` | bash | Put tty on fd 3 instead; use `<&3` for interactive reads. |
| macOS Terminal.app launches bash as a *login* shell, which sources `.bash_profile` but not `.bashrc` | bash | `.bash_profile` wired to source `.bashrc`. Without it, baked env vars never load in new terminals. |
| Passphrase `read -rs <&3` dies under non-interactive SSH (EOF + `set -e`) | bash | `\|\| HARNESS_PASSPHRASE=""` absorbs EOF so the "No passphrase entered" warn path handles it. Surfaced 2026-04-18 drill when admin bootstrap was run over non-TTY SSH. |
| `security add-generic-password` fails with "User interaction is not allowed" under non-GUI session, killing the decrypt step | bash (macOS only) | Wrap in `if ... 2>/dev/null; then ok; else warn; fi`. Keychain storage is a re-run convenience, not a requirement. |
| Marketplace name derivation doesn't strip `-harness` (only `-claude-harness`) | bash | **FIXED 2026-04-21** — `MARKETPLACE_NAME="${REPO_NAME%-claude-harness}"` then `MARKETPLACE_NAME="${MARKETPLACE_NAME%-harness}"` (handles both naming conventions). Bug surfaced when `test-client-harness` mapped to `test-client-harness` instead of `test-client`. |
| `credentials.env.age` lookup at marketplace root, not in `credentials/` subdirectory | bash | **FIXED 2026-04-21** — `AGE_FILE` path now includes `credentials/` prefix to match where `manage-credentials` writes it. |
| `age` auto-install adds to PATH for current run only, not rc file | bash | **FIXED 2026-04-21** — `_install_age` writes `export PATH="$HOME/.local/bin:$PATH"` to user's rc with marker comment. Re-runs from fresh terminal find `age` without re-downloading. |
| `raw.githubusercontent.com` CDN can lag 5–30+ minutes after a push | distribution | Use commit-SHA-pinned URL, or `scp` directly to test machine, or fetch via `gh api ... | base64 -d`. Documented in `~/.claude/directives/palisades-labs-harness-troubleshooting.md` § Session gotchas — 2026-04-21. |
| Plugin cache (`~/.claude/plugins/cache/<mp>/`) is separate from marketplace clone (`~/.claude/plugins/marketplaces/<mp>/`) | client install | `claude plugin marketplace update` updates clone but NOT cache; must `rm -rf` cache after pushing skill updates. Documented in troubleshooting directive. |

## Update procedure

1. Edit `bootstrap.sh` or `bootstrap.ps1` locally.
2. Test on a sandbox machine (claude-test-1 / Felino / fresh VM). Drill both golden path and at least the wrong-passphrase edge case.
3. Commit with a message that mentions the bug pattern the change guards against — the existing log is a good model.
4. Push to `main`. **The CDN can take 5–30+ minutes to refresh.** During active debugging, expect to use commit-SHA-pinned URLs or `scp` the script directly until the CDN catches up.
5. If the change alters the install-command interface (new required env var, new positional arg), update `~/repos/plugin-client-admin/skills/generate-installer/SKILL.md` in the same change — cross-layer invariant.

## Cross-layer references

These files must stay aligned with this repo. When you change `bootstrap.sh` / `bootstrap.ps1` CLI surface, update these in the same change:

- `~/repos/claude-harness-installer/README.md` — user-facing doc
- `~/repos/claude-harness-installer/EMPLOYEE-GUIDE.md` — plain-English employee install guide
- `~/repos/claude-harness-master/readme-template.md` — employee-facing (rendered per client)
- `~/repos/claude-harness-master/admin-guide-template.md` — admin-facing (rendered per client → `ADMIN.md` via `onboard-client.sh`)
- `~/repos/plugin-client-admin/skills/generate-installer/SKILL.md` — emits the install command; must match bootstrap arg parsing exactly
- `~/.claude/skills/onboard-client/` — derives the same marketplace name from `<org>/<repo>` as bootstrap does (strip `-claude-harness` then `-harness`)

## Drift notes (open gaps)

- **Version floor not enforced for Claude Code itself.** Bootstrap doesn't check `claude --version`. A machine with old Claude installed silently passes; downstream errors look like marketplace auth bugs. Consider documenting "ensure Claude Code 2.1.109+" in the EMPLOYEE-GUIDE prereqs section, and let `claude doctor` surface the actual mismatch.
- **Windows PowerShell drill incomplete.** The 2026-04-21 drill covers only macOS via `claude-test-1`. `bootstrap.ps1` changes are untested end-to-end. Track as TODO until a Windows machine is available.
- **Existing clients don't get new template additions.** `onboard-client.sh` skips template render when scaffold already exists (by design — resume is safe). New additions like ADMIN.md reach only newly-onboarded clients. Backfill is manual until a generic mechanism exists.

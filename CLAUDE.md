# CLAUDE.md — claude-harness-installer

*Last Edited: 2026-10-02*

Maintainer notes. This repo is public: never commit a customer name, a repo name, an
address or a secret. Everything customer-specific comes from the customer's 1Password
item "Claude Setup Access" at run time.

## What lives here

- `install.sh` — the generic first step (`install.sh <1password-sign-in-address> [--admin] [--dry-run]`).
  It installs Homebrew (pinned installer commit, `HOMEBREW_INSTALL_COMMIT`), the 1Password app
  and CLI beta, waits for 1Password using only the no-prompt `op account list`, calls
  `op account get` once, saves the item's read-only token with the osxkeychain helper for the
  one repo URL, shallow-clones the repo and runs its `setup/setup.sh` with `HARNESS_SRC`.
- `tests/test_install_dryrun.sh` — stubbed tests (no real installs, 1Password reads or Keychain writes).
- `v2.sh` — the previous GitHub-sign-in shim. Delete it in its own PR once the customer guides show
  `install.sh` and that command has run successfully from `main`.

## Rules

- The token only ever travels through a pipe into `git credential approve` sent to our helper
  alone (`git -c credential.helper= -c credential.helper=<helper> ...`). Never put it in argv,
  output or a file. The test fails if it appears anywhere.
- A Mac whose own `gh` sign-in already reaches the repo is left alone, so the read-only token
  never takes over a maintainer's pushes.
- The hand-off contract with each customer's private repo: `setup/setup.sh` exists, receives
  `--admin`/`--dry-run`, and reads `HARNESS_SRC` (the download) and `HARNESS_REF` (hidden: a branch
  for pre-merge testing). Change `install.sh` and the customer's `setup.sh` together when that
  contract changes.
- Messages people see are plain English: what's wrong and exactly what to do.
- Hidden test hooks: `SETUP_BREW_CANDIDATES` (where to look for Homebrew) and
  `SETUP_CREDENTIAL_HELPER` (default `osxkeychain`; tests use `store` in a throwaway HOME).

## Shipping

1. Branch, edit, `shellcheck install.sh && bash tests/test_install_dryrun.sh`.
2. PR, review, merge to `main`.
3. `raw.githubusercontent.com` can take 5–30+ minutes to refresh. While testing, fetch the script
   from the branch or a commit URL instead of `main`.

# claude-harness-installer

Public bootstrap script for installing the Palisades-Labs Claude Code harness into a developer's local environment.

## Usage

Each Palisades-Labs client gets a private GitHub repo containing their own customized Claude Code harness (base + overlay). To install, a developer runs one command — their team's champion or admin gives them the exact line to paste, with their repo's `<org>/<repo>` baked in.

```bash
curl -fsSL https://raw.githubusercontent.com/Palisades-Labs/claude-harness-installer/main/bootstrap.sh \
  | bash -s -- <org>/<repo>
```

Example (hypothetical):

```bash
curl -fsSL https://raw.githubusercontent.com/Palisades-Labs/claude-harness-installer/main/bootstrap.sh \
  | bash -s -- Palisades-Labs/insidescale-claude-harness
```

The arg is always a full `<org>/<repo>` path, not a bare slug. This way the same bootstrap script services both Palisades-Labs-hosted and client-hosted harness repos.

## What it does

All steps are additive and idempotent — running it twice changes nothing the second time.

1. Installs prerequisites (`jq`, `gh`, `node`, `npm`) via Homebrew (macOS) or apt/dnf/yum (Linux).
2. Installs the Claude Code CLI (`npm i -g @anthropic-ai/claude-code`).
3. Runs `gh auth login` if you aren't already authenticated.
4. Appends `export GITHUB_TOKEN=$(gh auth token)` to `~/.zshrc` or `~/.bashrc` (once). This works around Claude Code's private-repo marketplace auth ([issue #17201](https://github.com/anthropics/claude-code/issues/17201)).
5. Merges the client marketplace and its two enabled plugins (`base@<client>` and `<client>@<client>`) into `~/.claude/settings.json`. Existing keys are preserved.

## Platform support

- macOS (Apple Silicon + Intel)
- Linux (Debian/Ubuntu, RHEL/Fedora)
- Windows: use WSL.

## Troubleshooting

- **Bootstrap can't run `gh auth login`:** the script reclaims the terminal for interactive prompts (`exec < /dev/tty`), but if your environment has no TTY (some CI contexts), run `gh auth login` once by hand first, then re-run bootstrap.
- **`claude` prompts "marketplace not found":** open a new terminal so the updated shell rc (with `GITHUB_TOKEN`) is sourced.
- **Bootstrap refuses to touch `~/.claude/settings.json`:** the file exists but isn't valid JSON. Fix it (or rename it aside) and re-run.

## Maintenance

Maintained by Aaron Melamed (aaron@iteroapp.ai) / Palisades Labs.

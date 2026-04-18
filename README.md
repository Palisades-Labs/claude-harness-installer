# claude-harness-installer

Public bootstrap for installing the Palisades-Labs Claude Code harness on a developer's machine. Two audiences, two modes:

- **Employees** — paste the install command your admin sent you. Zero personal GitHub setup. A read-only token is already baked into the command.
- **Admins** — run with `--admin` once on your own machine. Signs you into GitHub in a browser, then sets up the harness so you can run `/manage-credentials` and `/generate-installer` for your team.

## Employee install

Your admin will send you a multi-line command. On a Mac, open **Terminal**; on Windows, open **PowerShell**. Paste all lines together, press Enter.

The Mac version looks like:

```bash
export GITHUB_TOKEN=github_pat_...
curl -fsSL https://raw.githubusercontent.com/Palisades-Labs/claude-harness-installer/main/bootstrap.sh \
  | bash -s -- <org>/<repo>
```

Partway through, you'll see:

```
[bootstrap] Setup passphrase:
```

That's a short secret your admin sent you **separately** (via Slack DM, in person, email — anything that isn't the install command itself). Type or paste it; it won't echo. Press Enter.

When the script finishes, close the terminal window, open a new one, run `claude`.

## Admin install

Once per machine, to set up your own harness:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Palisades-Labs/claude-harness-installer/main/bootstrap.sh) \
  --admin <org>/<repo>
```

This runs `gh auth login --web` to sign you in, derives `GITHUB_TOKEN` from `gh auth token`, then does everything an employee install does — including prompting for the team's setup passphrase so your machine can decrypt the shared credentials file.

After install, open a new terminal, run `claude`, then `/generate-installer` to produce the one-liner you'll send your team.

## What it does (both modes)

Every step is additive and idempotent — running it twice changes nothing the second time.

1. Installs prerequisites via Homebrew (macOS), `apt` / `dnf` / `yum` (Linux), or `winget` / `choco` (Windows): `jq`, `git`, `rsync`, `node`, `npm`, `age`. Admin mode also installs `gh`.
2. Installs the Claude Code CLI globally: `npm i -g @anthropic-ai/claude-code`.
3. Sets a git URL rewrite (`git@github.com:` → `https://github.com/`) plus a credential helper so Claude's plugin marketplace cloner can authenticate over HTTPS with the token we set up.
4. Appends `export GITHUB_TOKEN=…` to your shell rc once. Employee: the baked-in PAT literal. Admin: a `gh auth token` expression.
5. Prompts once for the setup passphrase and stores it securely — macOS Keychain (`palisades-labs-harness`), `~/.claude/credentials/.passphrase` with mode 600 on Linux, DPAPI on Windows.
6. Clones the harness repo and decrypts `credentials.env.age` → `~/.claude/credentials/credentials.env` (mode 600). This is how team API keys (Tavily, etc.) reach your machine. Fails safely if the repo doesn't have a credentials file yet.
7. Appends a one-time source stanza so future terminals auto-load `credentials.env` as environment variables.
8. Merges the client marketplace + enabled plugins (`tools@<client>` and `<client>@<client>`) into `~/.claude/settings.json`. Adds deny rules so Claude can't read `.env*`, `~/.claude/credentials/**`, `~/.ssh/**`, or `~/.aws/**`.

## Platform support

- macOS (Apple Silicon + Intel) — `bootstrap.sh`
- Linux (Debian/Ubuntu, RHEL/Fedora) — `bootstrap.sh`
- Windows — `bootstrap.ps1`

## Troubleshooting

- **"claude: command not found" after install.** Open a new terminal window — the installer added a tool that only shows up in fresh shells.
- **`/plugin list` is empty, or Claude says "marketplace not found".** Same fix: new terminal. Your `GITHUB_TOKEN` doesn't load in the shell that was open before install finished.
- **Passphrase prompt rejects your input.** Hit Enter to skip, then re-run the one-liner with the correct passphrase. Re-running is safe; nothing you've done is lost. If you don't have the passphrase, ping your admin.
- **Credentials never arrive.** The installer logs `[warn] credentials.env.age not found in repo — API keys not set up yet. Admin must run /manage-credentials first.` when the repo hasn't had its credentials populated. Ask your admin to run `/manage-credentials`, then re-run the one-liner.
- **Bootstrap refuses to touch `~/.claude/settings.json`.** The file exists but isn't valid JSON. Fix or rename it, then re-run.
- **Admin mode: `gh auth login` can't open a browser.** Some CI / headless contexts have no TTY. Run `gh auth login` once manually, then re-run bootstrap with `--admin`.

## Maintenance

Maintained by Aaron Melamed (aaron@iteroapp.ai) / Palisades Labs.

#!/usr/bin/env bash
# Palisades-Labs Claude Code harness bootstrap (decrypt-only).
#
# Decrypts the client's age-encrypted credentials file (shipped via Claude
# Desktop marketplace sync) into ~/.claude/credentials/credentials.env so
# skills that need API keys (Tavily, Avoma, etc.) can read them at runtime.
#
# Usage:
#     bash <(curl -fsSL https://raw.githubusercontent.com/Palisades-Labs/claude-harness-installer/main/bootstrap.sh) --decrypt <org>/<repo>
#
# Prereq: the client marketplace must already be added + synced in Claude
# Desktop. Bootstrap reads credentials.env.age from
#     ~/.claude/plugins/marketplaces/<marketplace-name>/credentials/credentials.env.age
# where marketplace_name = basename(repo) with any "-claude-harness" suffix stripped.
# If that file is missing, bootstrap errors with "marketplace not synced yet".
#
# What this does (idempotent):
#   1. Verifies `age` is installed.
#   2. Derives marketplace_name from <org>/<repo>.
#   3. Confirms the marketplace sync directory + credentials.env.age exist.
#   4. Prompts for the setup passphrase your admin sent you separately.
#   5. Stores passphrase in macOS Keychain / Linux ~/.claude/credentials/.passphrase (chmod 600).
#   6. Decrypts to ~/.claude/credentials/credentials.env (chmod 600).
#   7. Adds a one-time source stanza to your shell rc so new terminals pick up the keys.
#
# Does NOT: install Claude Code, fetch PATs, merge settings.json, or register
# the marketplace. Those are handled by Claude Desktop / separate installer paths.

set -euo pipefail

log() { printf "\033[1;34m[bootstrap]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[error]\033[0m %s\n" "$*" >&2; }

# Wrap the entire script body in main() so that, when this is invoked via
# `curl … | bash`, bash parses the whole script (reading every byte from the
# pipe) BEFORE any executable line runs. Standard pattern used by rustup,
# oh-my-zsh, nvm, etc.
main() {
DECRYPT_MODE=0
POS_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --decrypt) DECRYPT_MODE=1 ;;
    -h|--help)
      cat <<'USAGE'
Usage: bootstrap.sh --decrypt <org>/<repo>

Decrypts credentials.env.age from the synced Claude Desktop marketplace
directory and writes ~/.claude/credentials/credentials.env (chmod 600).

Prereq: marketplace must be added and synced in Claude Desktop first.
USAGE
      exit 0 ;;
    *) POS_ARGS+=("$arg") ;;
  esac
done

CLIENT_REPO="${POS_ARGS[0]:-}"
if [[ "$DECRYPT_MODE" -ne 1 || -z "$CLIENT_REPO" || "$CLIENT_REPO" != */* ]]; then
  err "Usage: bootstrap.sh --decrypt <org>/<repo>  (e.g. Palisades-Labs/insidescale-claude-harness)"
  err "Prereq: add + sync the client marketplace in Claude Desktop before running."
  exit 1
fi

REPO_NAME="${CLIENT_REPO##*/}"
# Strip '-claude-harness' or '-harness' suffix to match the marketplace key
# Claude Desktop uses (e.g. test-client-harness → test-client).
MARKETPLACE_NAME="${REPO_NAME%-claude-harness}"
MARKETPLACE_NAME="${MARKETPLACE_NAME%-harness}"

log "Client repo:       $CLIENT_REPO"
log "Marketplace name:  $MARKETPLACE_NAME"

# `age` is the only external dependency in the decrypt-only flow. Auto-install
# from GitHub releases if missing — no Homebrew or sudo required.
_install_age() {
  log "age not found — downloading from GitHub releases..."
  local os arch version tmpdir
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
    x86_64)        arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) err "Unsupported architecture: $(uname -m). Install age manually: https://github.com/FiloSottile/age/releases"; exit 1 ;;
  esac
  version="v1.3.1"
  tmpdir="$(mktemp -d)"
  curl -fsSL "https://github.com/FiloSottile/age/releases/download/${version}/age-${version}-${os}-${arch}.tar.gz" \
    | tar -xz -C "$tmpdir"
  mkdir -p "$HOME/.local/bin"
  mv "$tmpdir/age/age" "$HOME/.local/bin/age"
  chmod +x "$HOME/.local/bin/age"
  rm -rf "$tmpdir"
  export PATH="$HOME/.local/bin:$PATH"
  log "[ok] age ${version} installed to ~/.local/bin/age"

  # Persist ~/.local/bin to PATH in the user's rc file so future terminals
  # (including bootstrap re-runs) find age without re-downloading. Marker
  # comment guards idempotence — re-runs of bootstrap won't duplicate the line.
  local rc_file
  case "$(basename "${SHELL:-}")" in
    zsh)  rc_file="$HOME/.zshrc" ;;
    bash) rc_file="$HOME/.bashrc" ;;
    *)    rc_file="$( [[ "$(uname -s)" == "Darwin" ]] && echo "$HOME/.zshrc" || echo "$HOME/.bashrc" )" ;;
  esac
  touch "$rc_file"
  local path_marker="# Palisades-Labs claude-harness-installer: ~/.local/bin on PATH (for age)"
  if ! grep -Fq "$path_marker" "$rc_file"; then
    {
      printf '\n%s\n' "$path_marker"
      printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    } >> "$rc_file"
    log "[ok] Added ~/.local/bin to PATH in $rc_file"
  fi
}

# age may exist outside PATH (e.g. /opt/homebrew/bin on Apple Silicon without
# Homebrew shell init). Check common locations before downloading.
if ! command -v age &>/dev/null; then
  for _candidate in /opt/homebrew/bin/age /usr/local/bin/age "$HOME/.local/bin/age"; do
    if [[ -x "$_candidate" ]]; then
      export PATH="$(dirname "$_candidate"):$PATH"
      break
    fi
  done
fi

if ! command -v age &>/dev/null; then
  _install_age
fi

# When piped via `curl | bash`, bash reads this script FROM stdin. Replacing
# stdin with /dev/tty (`exec < /dev/tty`) breaks that — bash stops reading the
# remainder of the script and starts waiting for terminal input instead.
#
# Instead, put /dev/tty on fd 3 so interactive commands below can read from it
# via `<&3` while bash's stdin stays pointed at the pipe.
#
# The `[[ -r /dev/tty ]]` test is INSUFFICIENT: under non-interactive SSH (no
# pty allocated), /dev/tty exists as a filesystem entry with mode 0666 and
# `[[ -r ]]` returns true, but the actual open() fails with "Device not
# configured" because the process has no controlling terminal. With `set -e`,
# the failed redirect kills the script. So we test by attempting the open in
# a subshell — the subshell's fd 3 dies with it, leaving the parent's fd 3
# untouched until the real exec below.
if (exec 3</dev/tty) 2>/dev/null; then
  exec 3</dev/tty
else
  # No TTY available (non-interactive SSH, CI, cron) — fall back to current stdin.
  exec 3<&0
fi

OS="$(uname -s)"

# -----------------------------------------------------------------------------
# Shell rc derivation (needed for the credentials source stanza)
# -----------------------------------------------------------------------------
case "$(basename "${SHELL:-}")" in
  zsh)  RC_FILE="$HOME/.zshrc" ;;
  bash) RC_FILE="$HOME/.bashrc" ;;
  *)    RC_FILE="$( [[ "$OS" == "Darwin" ]] && echo "$HOME/.zshrc" || echo "$HOME/.bashrc" )" ;;
esac
touch "$RC_FILE"

# On macOS, Terminal.app opens bash as a LOGIN shell, which sources
# .bash_profile but NOT .bashrc. So exports written to .bashrc never load
# in new terminal tabs and any GUI-launched tool (like Claude Code) inherits
# an env without the credentials. Fix: ensure .bash_profile sources .bashrc.
# Idempotent — skips if already wired up.
if [[ "$OS" == "Darwin" ]] && [[ "$(basename "${SHELL:-}")" == "bash" ]]; then
  PROFILE="$HOME/.bash_profile"
  touch "$PROFILE"
  PROFILE_MARKER="# Palisades-Labs claude-harness-installer: source .bashrc on login"
  if grep -Fq "$PROFILE_MARKER" "$PROFILE"; then
    log "[ok] ~/.bash_profile already sources ~/.bashrc"
  else
    log "Ensuring ~/.bash_profile sources ~/.bashrc (macOS bash login-shell quirk)"
    {
      printf '\n%s\n' "$PROFILE_MARKER"
      printf '[ -r ~/.bashrc ] && source ~/.bashrc\n'
    } >> "$PROFILE"
  fi
fi

# -----------------------------------------------------------------------------
# Collect setup passphrase, store in Keychain / file, decrypt credentials
# -----------------------------------------------------------------------------
CREDS_DIR="$HOME/.claude/credentials"
mkdir -p "$CREDS_DIR" && chmod 700 "$CREDS_DIR"

# Verify the age-encrypted credentials file exists in the Desktop-synced
# marketplace directory BEFORE prompting for the passphrase. No point asking
# for a secret if the input file is missing.
AGE_FILE="$HOME/.claude/plugins/marketplaces/$MARKETPLACE_NAME/credentials/credentials.env.age"
if [[ ! -f "$AGE_FILE" ]]; then
  err "credentials.env.age not found at ~/.claude/plugins/marketplaces/$MARKETPLACE_NAME/credentials/credentials.env.age — marketplace not synced yet. Add it in Claude Desktop and wait for sync before re-running."
  exit 1
fi

log "You will be prompted for the setup passphrase your admin sent you separately."
printf "[bootstrap] Setup passphrase: "
# read can fail under non-interactive invocation (e.g. ssh without a pty) when
# fd 3 fell back to a closed stdin at the top-of-script probe — EOF makes
# `read` exit non-zero, which `set -e` would otherwise escalate into a script
# death mid-install. Treat read failure the same as an empty passphrase so the
# "No passphrase entered" warn branch below handles it uniformly.
read -rs HARNESS_PASSPHRASE <&3 || HARNESS_PASSPHRASE=""
echo ""
if [[ -z "$HARNESS_PASSPHRASE" ]]; then
  log "[warn] No passphrase entered — credential decryption skipped. API tools won't work until re-run with passphrase."
else
  # Store passphrase securely (never in a shell rc file)
  if [[ "$OS" == "Darwin" ]]; then
    security delete-generic-password -a "$USER" -s "palisades-labs-harness" &>/dev/null || true
    # Keychain storage is a convenience for re-run ergonomics, not a requirement.
    # It fails with "User interaction is not allowed" when the invoking session
    # can't talk to the security agent (headless SSH, non-GUI admin sessions).
    # Don't let that kill the decrypt step below.
    # Pipe passphrase via stdin, not argv — macOS `ps auxww` reveals argv.
    if printf '%s' "$HARNESS_PASSPHRASE" | security add-generic-password -a "$USER" -s "palisades-labs-harness" -w 2>/dev/null; then
      log "[ok] Passphrase stored in macOS Keychain (palisades-labs-harness)"
    else
      log "[warn] Could not store passphrase in Keychain (likely non-GUI session). Re-runs will re-prompt."
    fi
  else
    # Tighten umask in subshell so the file is 600 at creation — no write-then-chmod race.
    ( umask 077 && printf '%s' "$HARNESS_PASSPHRASE" > "$CREDS_DIR/.passphrase" )
    log "[ok] Passphrase stored at ~/.claude/credentials/.passphrase (chmod 600)"
  fi

  # Decrypt the Desktop-synced credentials.env.age directly (no clone).
  printf '%s\n' "$HARNESS_PASSPHRASE" | \
    age --decrypt -o "$CREDS_DIR/credentials.env" "$AGE_FILE"
  chmod 600 "$CREDS_DIR/credentials.env"
  log "[ok] Credentials decrypted to ~/.claude/credentials/credentials.env"
fi

# Source stanza in rc file — API keys load from credentials.env, not from individual exports
CREDS_MARKER="# Palisades-Labs claude-harness-installer: credentials source"
if grep -Fq "$CREDS_MARKER" "$RC_FILE"; then
  log "[ok] Credentials source stanza already present in $RC_FILE"
else
  {
    printf '\n%s\n' "$CREDS_MARKER"
    printf 'if [ -f "$HOME/.claude/credentials/credentials.env" ]; then\n'
    printf '  set -a; source "$HOME/.claude/credentials/credentials.env"; set +a\n'
    printf 'fi\n'
  } >> "$RC_FILE"
  log "[ok] Added credentials source stanza to $RC_FILE"
fi

# -----------------------------------------------------------------------------
# Inject harness orientation into ~/.claude/CLAUDE.md
# -----------------------------------------------------------------------------
# Claude Code auto-loads ~/.claude/CLAUDE.md in every session, regardless of
# working directory. The harness ships home-claude.md at its repo root with
# orientation content (skill namespace, credentials path, authoring guidance).
# We splice it into ~/.claude/CLAUDE.md between marketplace-scoped markers so
# multiple harnesses can coexist and re-runs idempotently update the block
# without touching the user's own global instructions.
HOME_CLAUDE_SRC="$HOME/.claude/plugins/marketplaces/$MARKETPLACE_NAME/home-claude.md"
HOME_CLAUDE_DST="$HOME/.claude/CLAUDE.md"
BEGIN_MARKER="<!-- claude-harness orientation: $MARKETPLACE_NAME (begin) -->"
END_MARKER="<!-- claude-harness orientation: $MARKETPLACE_NAME (end) -->"

if [[ -f "$HOME_CLAUDE_SRC" ]]; then
  mkdir -p "$(dirname "$HOME_CLAUDE_DST")"
  touch "$HOME_CLAUDE_DST"
  # Write to a tmp file then atomically replace — avoids partial-write corruption
  # if bootstrap is interrupted mid-splice.
  TMP_CLAUDE_MD="$(mktemp)"
  if grep -Fq "$BEGIN_MARKER" "$HOME_CLAUDE_DST" 2>/dev/null; then
    # Existing block — replace content between markers in-place.
    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v src="$HOME_CLAUDE_SRC" '
      $0 == begin { print; while ((getline line < src) > 0) print line; close(src); skip=1; next }
      $0 == end   { print; skip=0; next }
      !skip       { print }
    ' "$HOME_CLAUDE_DST" > "$TMP_CLAUDE_MD"
    mv "$TMP_CLAUDE_MD" "$HOME_CLAUDE_DST"
    log "[ok] Updated $MARKETPLACE_NAME orientation block in ~/.claude/CLAUDE.md"
  else
    # First install — append a new block. Leading newline if file is non-empty
    # and doesn't already end with one.
    cp "$HOME_CLAUDE_DST" "$TMP_CLAUDE_MD"
    if [[ -s "$TMP_CLAUDE_MD" ]] && [[ "$(tail -c1 "$TMP_CLAUDE_MD" | wc -l)" -eq 0 ]]; then
      printf '\n' >> "$TMP_CLAUDE_MD"
    fi
    {
      printf '\n%s\n' "$BEGIN_MARKER"
      cat "$HOME_CLAUDE_SRC"
      printf '%s\n' "$END_MARKER"
    } >> "$TMP_CLAUDE_MD"
    mv "$TMP_CLAUDE_MD" "$HOME_CLAUDE_DST"
    log "[ok] Added $MARKETPLACE_NAME orientation block to ~/.claude/CLAUDE.md"
  fi
else
  log "[info] No home-claude.md in this marketplace — skipping ~/.claude/CLAUDE.md injection."
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo ""
log "Bootstrap complete."
echo ""
echo "Next steps:"
echo "  1. Open a new terminal and run: claude"
echo ""
}

main "$@"

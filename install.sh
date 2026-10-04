#!/usr/bin/env bash
# Claude setup, first step. Public and generic: it holds no customer names and no
# secrets. Everything specific comes from the customer's own 1Password account.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Palisades-Labs/claude-harness-installer/main/install.sh) <1password-sign-in-address> [--admin] [--dry-run]
#   e.g. ... install.sh yourteam.1password.com
#
# What it does, in order:
#   1. stops unless this is a Mac and the account is an administrator
#   2. installs Homebrew if missing (one Mac password prompt), and puts it on PATH
#   3. installs the 1Password app and the 1Password command-line tool (beta) if missing
#   4. waits until 1Password is signed in to <address> with the CLI integration on
#   5. reads the item "Claude Setup Access" (fields `repo` = owner/name and
#      `credential` = a read-only access key for that repo) and saves the key for
#      that one repo URL in the macOS Keychain. The key goes through a pipe only:
#      never printed, never in a process argument or a file.
#   6. downloads that repo (shallow) to a temporary folder with the key, which also
#      proves the access works, and runs its setup/setup.sh with HARNESS_SRC set
#
# --admin and --dry-run are passed on to setup.sh. --dry-run here only prints the
# plan: it reads nothing from 1Password and changes nothing.
# HARNESS_REF=<branch> (hidden, for testing before merge) downloads that branch and
# is passed on to setup.sh.

ITEM="Claude Setup Access"
# Homebrew's installer, pinned to a reviewed commit (2026-10-01).
HOMEBREW_INSTALL_COMMIT="09c62fc577ec170172b0a184060f141a2c622dc1"
# Where Homebrew lives when it is installed but not on PATH. Overridable for tests.
BREW_CANDIDATES="${SETUP_BREW_CANDIDATES-/opt/homebrew/bin/brew /usr/local/bin/brew}"
# Git credential helper that keeps the key. Tests use "store" in a throwaway HOME.
HELPER="${SETUP_CREDENTIAL_HELPER:-osxkeychain}"

say() { printf '%s\n' "$*"; }
die() { say "$*"; exit 1; }
run() { if [ "$DRY" = 1 ]; then say "[dry-run] $*"; else "$@"; fi; }

# Homebrew queries keep stdout; changes keep all output in a private setup log.
# The public installer embeds this block because it runs before downloading setup.
export HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTO_UPDATE=1

brew_preflight() {
  local prefix dir owner
  type -P brew >/dev/null 2>&1 || return 0
  prefix="$(command brew --prefix 2>/dev/null)" || return 1
  [ -n "$prefix" ] && [ -d "$prefix" ] || {
    say "Homebrew isn't answering on this Mac. Tell Aaron before running setup again."
    return 1
  }
  for dir in "$prefix" "$prefix/bin" "$prefix/sbin" "$prefix/etc" "$prefix/var" "$prefix/opt" "$prefix/lib" "$prefix/share" "$prefix/Cellar" "$prefix/Caskroom" "$prefix/Frameworks" "$prefix/Homebrew"; do
    [ -e "$dir" ] || continue
    if [ ! -w "$dir" ]; then
      owner="$(stat -f %Su "$dir" 2>/dev/null)" || owner="another account"
      say "Homebrew on this Mac belongs to another user account ($owner). Run setup from that account, or tell Aaron."
      return 1
    fi
  done
}

brew_log_init() {
  [ -n "${SETUP_BREW_LOG:-}" ] && [ -f "$SETUP_BREW_LOG" ] && return 0
  local dir="$HOME/Library/Logs/claude-setup"
  if ! mkdir -p "$dir" || ! chmod 700 "$dir"; then
    say "Couldn't create the setup log folder at $dir. Tell Aaron."
    return 1
  fi
  SETUP_BREW_LOG="$(mktemp "$dir/homebrew.XXXXXX")" || return 1
  export SETUP_BREW_LOG
}

brew_failure() {
  printf '%s\n' "Homebrew couldn't finish this step. Run setup again; if it fails again, send Aaron this log: $SETUP_BREW_LOG" >&2
  tail -n 5 "$SETUP_BREW_LOG" >&2
}

brew() {
  if [ "${DRY:-0}" = 1 ]; then
    case "${1:-}" in
      update|install|upgrade|uninstall|fetch) say "[dry-run] brew $*"; return 0;;
      *) command brew "$@" 2>/dev/null; return;;
    esac
  fi
  brew_log_init || return 1
  case "${1:-}" in
    update|install|upgrade|uninstall|fetch)
      if command brew "$@" >>"$SETUP_BREW_LOG" 2>&1; then return 0; fi
      brew_failure
      return 1;;
    *) command brew "$@" 2>>"$SETUP_BREW_LOG";;
  esac
}

# This exported prefix is inherited by setup's helpers: one explicit refresh per run.
brew_update_once() {
  local prefix
  prefix="$(command brew --prefix 2>/dev/null)" || return 1
  [ "${SETUP_BREW_UPDATED:-}" = "$prefix" ] && return 0
  say "Checking for the latest versions of the tools..."
  brew update || return 1
  if [ "${DRY:-0}" != 1 ]; then export SETUP_BREW_UPDATED="$prefix"; fi
}

# Download both casks before removing the working CLI. Keep its executable as a
# last resort if Homebrew cannot restore even its already-downloaded regular cask.
swap_op_beta() {
  local old backup
  say "Downloading the replacement 1Password tool before changing the current one..."
  brew fetch --cask 1password-cli@beta && brew fetch --cask 1password-cli || return 1
  old="$(command -v op)" || return 1
  backup="$(mktemp -d)" || return 1
  if ! cp -pL "$old" "$backup/op"; then rmdir "$backup"; return 1; fi
  if ! brew uninstall --cask 1password-cli; then
    if ! op_present; then mv -f "$backup/op" "$old" || return 1; fi
    rm -f "$backup/op"; rmdir "$backup"
    return 1
  fi
  if brew install --cask 1password-cli@beta && op_present; then
    rm -f "$backup/op"; rmdir "$backup"
    return 0
  fi
  say "The replacement didn't install. Restoring the regular 1Password tool..."
  if brew install --cask 1password-cli && op_present; then
    say "The regular 1Password tool was put back. Run setup again later; if it repeats, tell Aaron."
  else
    # mv replaces a broken Homebrew symlink rather than following its removed target.
    if mv -f "$backup/op" "$old" && op_present; then
      say "The previous 1Password tool was put back, but Homebrew couldn't repair its installation. Tell Aaron before running setup again."
    else
      say "Couldn't restore the 1Password tool. Tell Aaron; the saved copy is at $backup/op."
      return 1
    fi
  fi
  rm -f "$backup/op"; rmdir "$backup"
  return 1
}

op_present() {
  local p
  hash -r
  p="$(command -v op 2>/dev/null)" || return 1
  [ -n "$p" ] && [ -x "$p" ]
}

usage() {
  say "Usage: install.sh <your 1Password sign-in address> [--admin] [--dry-run]"
  say "Example: install.sh yourteam.1password.com"
  say "Copy the full command from your setup guide; it already includes the address."
  exit 2
}

# Replace a file's contents with a command's output, all or nothing: the output goes
# to a temporary file next to the real file (a symlink is followed, so a symlinked
# ~/.zshrc stays a symlink), the permissions are kept, and only then is it moved into
# place. Any failure leaves the original file exactly as it was.
safe_replace() { # <file> <command...>
  local file="$1" target link tmp mode
  shift
  target="$file"
  while [ -L "$target" ]; do
    link="$(readlink "$target")" || return 1
    case "$link" in /*) target="$link";; *) target="$(dirname "$target")/$link";; esac
  done
  tmp="$(mktemp "$(dirname "$target")/.$(basename "$target").XXXXXX" 2>/dev/null)" || return 1
  [ -n "$tmp" ] || return 1
  if "$@" > "$tmp"; then
    if [ -e "$target" ]; then mode="$(stat -f %Lp "$target")"; else mode=644; fi
    if chmod "$mode" "$tmp" && mv -f "$tmp" "$target"; then return 0; fi
  fi
  rm -f "$tmp"
  return 1
}

prepend() { printf '%s\n' "$1"; if [ -f "$2" ]; then cat "$2"; fi; }

# Put a line at the top of ~/.zprofile and ~/.zshrc unless the file already has
# <already>. At the top, so any PATH change the person makes later still wins.
persist_line() { # <line> <already>
  local rc
  for rc in "$HOME/.zprofile" "$HOME/.zshrc"; do
    if [ -f "$rc" ] && grep -qF -- "$2" "$rc"; then continue; fi
    if [ "$DRY" = 1 ]; then say "[dry-run] add to $rc: $1"; continue; fi
    safe_replace "$rc" prepend "$1" "$rc" \
      || say "Couldn't add the Homebrew line to $rc; the file was left unchanged. Setup carries on."
  done
}

brew_on_path() {
  local b
  type -P brew >/dev/null 2>&1 && return 0
  for b in $BREW_CANDIDATES; do
    if [ -x "$b" ]; then eval "$("$b" shellenv 2>/dev/null)"; break; fi
  done
  type -P brew >/dev/null 2>&1
}

# True when the `op` that runs is 2.40.0-beta.02 or newer (or stable 2.40.0+).
op_new_enough() {
  local v major minor patch beta
  v="$(op --version 2>/dev/null | head -1)" || return 1
  v="$(printf '%s\n' "$v" | sed -nE 's/^([0-9]+)\.([0-9]+)\.([0-9]+)(-beta\.([0-9]+))?$/\1 \2 \3 \5/p')"
  [ -n "$v" ] || return 1
  read -r major minor patch beta <<EOF
$v
EOF
  [ "$major" -ne 2 ] && { [ "$major" -gt 2 ]; return; }
  [ "$minor" -ne 40 ] && { [ "$minor" -gt 40 ]; return; }
  [ "$patch" -gt 0 ] && return 0
  [ -z "${beta:-}" ] || [ "$beta" -ge 2 ]
}

preflight() {
  [ "$(uname -s)" = "Darwin" ] || die "This setup works on a Mac only. Tell the person who manages Claude setup for your team which computer you're using."
  [ "$(id -u)" != 0 ] || die "Don't run this with sudo. Paste the command from your setup guide exactly as it is."
  brew_on_path || true
  brew_preflight || exit 1
  id -Gn | grep -qw admin || die "Your Mac account needs to be an administrator to install the tools Claude uses. Ask whoever manages this Mac to make your account an administrator (System Settings > Users & Groups), then run this again."
}

ensure_homebrew() {
  local keepalive rc
  if brew_on_path; then
    say "Homebrew is installed."
  elif [ "$DRY" = 1 ]; then
    say "[dry-run] sudo -v (your Mac password, once), then install Homebrew from Homebrew/install@$HOMEBREW_INSTALL_COMMIT"
    return 0
  else
    say "Installing Homebrew, the tool that installs everything else. This takes a few minutes."
    say "It needs your Mac password once: type the password you use to log in to this Mac and press Return."
    say "Nothing appears while you type; that's normal."
    sudo -v || die "That password didn't work. Run the command again and type the password you use to log in to this Mac."
    # Keep the password valid while Homebrew downloads Apple's command line tools.
    ( while sudo -n -v 2>/dev/null && kill -0 "$$" 2>/dev/null; do sleep 50; done ) &
    keepalive=$!
    brew_log_init || exit 1
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/Homebrew/install/$HOMEBREW_INSTALL_COMMIT/install.sh")" >>"$SETUP_BREW_LOG" 2>&1
    rc=$?
    kill "$keepalive" 2>/dev/null
    if [ "$rc" != 0 ] || ! brew_on_path; then
      brew_failure
      die "Homebrew didn't install. Check the internet connection and run the command again. If it fails again, send the last few lines above to the person who manages Claude setup for your team."
    fi
  fi
  brew_preflight || exit 1
  brew_update_once || exit 1
  persist_line "eval \"\$($(type -P brew) shellenv)\"  # Claude setup: Homebrew on PATH" "brew shellenv"
}

ensure_1password() {
  if [ ! -d "/Applications/1Password.app" ]; then
    say "Installing the 1Password app..."
    run brew install -q --cask 1password || die "Couldn't install the 1Password app. Run the command again; if it fails again, install 1Password from 1password.com/downloads and run the command again."
  fi
  hash -r
  if ! command -v op >/dev/null 2>&1; then
    say "Installing the 1Password command-line tool..."
    run brew install -q --cask 1password-cli@beta || die "Couldn't install the 1Password command-line tool. Run the command again."
  elif ! op_new_enough; then
    if brew list --cask 1password-cli@beta >/dev/null 2>&1; then
      say "Updating the 1Password command-line tool..."
      run brew upgrade --cask 1password-cli@beta || exit 1
    elif brew list --cask 1password-cli >/dev/null 2>&1; then
      if [ "$DRY" = 1 ]; then say "[dry-run] download the beta before replacing the regular 1Password tool";
      else swap_op_beta || exit 1; fi
    else
      die "The 1Password tool wasn't installed by Homebrew. Tell Aaron before running setup again."
    fi
  fi
  if [ "$DRY" != 1 ] && ! op_new_enough; then die "The 1Password tool is still too old. Tell Aaron before running setup again."; fi
}

has_account() { printf '%s' "$1" | grep -qF "\"$ADDR\""; }

# Where 1Password stands, using only `op account list`, which never prompts.
op_state() {
  local out forced
  pgrep -xq 1Password 2>/dev/null || { echo closed; return; }
  out="$(op account list --format=json </dev/null 2>&1)" || out=""
  if has_account "$out"; then echo ready; return; fi
  forced="$(OP_BIOMETRIC_UNLOCK_ENABLED=true op account list --format=json </dev/null 2>&1)" || forced=""
  if has_account "$forced"; then echo integration-off
  elif printf '%s' "$forced" | grep -q '"url"'; then echo no-account
  else echo locked; fi
}

explain_state() {
  case "$1" in
    closed) say "Opening 1Password. Sign in if it asks."
            open -a 1Password >/dev/null 2>&1 || true;;
    integration-off)
      say "One 1Password setting to turn on: in 1Password, open Settings > Developer and turn on"
      say "\"Integrate with 1Password CLI\". Opening that page for you now."
      open "onepassword://settings/developers" >/dev/null 2>&1 || true;;
    no-account)
      say "1Password is open, but your $ADDR account isn't in it yet."
      say "In 1Password, add that account (or accept the invitation email you received) and sign in.";;
    locked)
      say "1Password is locked or isn't answering. Unlock it with Touch ID or your 1Password password."
      say "Also check that Settings > Developer > \"Integrate with 1Password CLI\" is turned on.";;
  esac
}

wait_for_1password() {
  local state last="" waited=0 tries=0 out
  if [ "$DRY" = 1 ]; then
    say "[dry-run] wait until 1Password shows $ADDR (op account list), then op account get --account $ADDR once"
    return 0
  fi
  while :; do
    state="$(op_state)"
    if [ "$state" = ready ]; then
      # The one call that asks for approval (Touch ID or your Mac password).
      say "1Password may ask you to approve access. Approve it with Touch ID or your Mac password."
      if out="$(op account get --account "$ADDR" </dev/null 2>&1)"; then return 0; fi
      tries=$((tries + 1))
      case "$out" in
        *dismissed*|*timeout*) say "The 1Password approval was cancelled or timed out. Asking again...";;
        *) say "1Password didn't give access yet. Trying again...";;
      esac
      [ "$tries" -lt 3 ] || die "1Password didn't give access after three tries. Unlock 1Password, then run the command again."
      last=""
    elif [ "$state" != "$last" ]; then
      explain_state "$state"
      say "Waiting for that; this carries on by itself once it's done. (To stop, press Control-C.)"
      last="$state"
    fi
    sleep 3
    waited=$((waited + 3))
    [ "$waited" -lt 1800 ] || die "Stopped waiting for 1Password after 30 minutes. Run the command again when 1Password is ready."
  done
}

# True when git itself, with this Mac's own sign-in and no prompts, reaches the repo.
# Then its git setup is left alone (the key would otherwise take over that repo's pushes).
own_github_access() { # <owner/repo>
  GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git -c credential.interactive=false \
    ls-remote "https://github.com/$1.git" HEAD >/dev/null 2>&1
}

# Send one credential record to our helper only (never to the person's other helpers).
credential() { # <approve|reject|fill>; record on stdin
  GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git -c credential.interactive=false \
    -c credential.helper= -c "credential.helper=$HELPER" -c credential.useHttpPath=true credential "$1"
}

# Check the helper's answer without printing or writing any part of the key.
saved_key_available() { # <repo path>
  printf 'protocol=https\nhost=github.com\npath=%s\nusername=x-access-token\n\n' "$1" \
    | credential fill 2>/dev/null \
    | awk '/^username=x-access-token$/ { user=1 } /^password=./ { password=1 } END { exit !(user && password) }'
}

# Our repo-scoped git settings carry this marker key (git ignores unknown keys), so a
# later run removes only what it added, never a person's own settings for the repo.
MARKER_KEY="claudeSetupManaged"

# Remove what an earlier run added for <repo>, for each URL form that carries our
# marker: our settings, and the saved key (sent to our helper only). Unmarked
# settings are never touched.
forget_access_key() { # <owner/repo>
  local url path k
  for url in "https://github.com/$1.git" "https://github.com/$1"; do
    [ "$(git config --global --get "credential.$url.$MARKER_KEY" 2>/dev/null)" = true ] || continue
    for k in helper useHttpPath username "$MARKER_KEY"; do
      git config --global --unset-all "credential.$url.$k" >/dev/null 2>&1
    done
    case "$url" in *.git) path="$1.git";; *) path="$1";; esac
    printf 'protocol=https\nhost=github.com\npath=%s\nusername=x-access-token\n\n' "$path" | credential reject >/dev/null 2>&1
  done
}

# True when any credential setting for <repo>'s URLs exists that we didn't add (in any
# git config this Mac reads). Run after forget_access_key, so only unmarked ones are left.
own_repo_settings() { # <owner/repo>
  git config --list --name-only 2>/dev/null \
    | grep -qiF -e "credential.https://github.com/$1.git." -e "credential.https://github.com/$1."
}

# A 1Password read failed: was it a missed approval (the fix is to approve), or not?
approval_missed() { grep -qiE 'authorization timeout|dismissed|timed out' "$1" 2>/dev/null; }
APPROVAL_MSG="The 1Password approval wasn't given in time. Run the command again and approve the 1Password prompt (Touch ID or your Mac password)."

# Step 5. Sets REPO.
save_access_key() {
  local token url path rc=0 errf keychain_info
  if [ "$DRY" = 1 ]; then
    say "[dry-run] read the repo name and access key from the 1Password item \"$ITEM\" and save the key in the Keychain for that repo only"
    return 0
  fi
  errf="$(mktemp 2>/dev/null)" || errf=/dev/null
  REPO="$(op item get "$ITEM" --account "$ADDR" --fields label=repo </dev/null 2>"$errf")" || REPO=""
  if ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
    if approval_missed "$errf"; then
      say "$APPROVAL_MSG"
    else
      say "Couldn't find the \"$ITEM\" item in your 1Password (or its repo field is empty)."
      say "Ask the person who manages Claude setup for your team to share it with you, then run the command again."
    fi
    [ "$errf" = /dev/null ] || rm -f "$errf"
    return 1
  fi
  # Read the key before changing anything, so a missed approval leaves the Mac as it was.
  token="$(op item get "$ITEM" --account "$ADDR" --fields label=credential --reveal </dev/null 2>"$errf")" || token=""
  if [ -z "$token" ]; then
    if approval_missed "$errf"; then say "$APPROVAL_MSG"; else say "The \"$ITEM\" item has no access key in its credential field. Tell the person who manages Claude setup for your team."; fi
    [ "$errf" = /dev/null ] || rm -f "$errf"
    return 1
  fi
  [ "$errf" = /dev/null ] || rm -f "$errf"
  # Ask git without anything an earlier run added: does this Mac's own sign-in work?
  forget_access_key "$REPO"
  if own_github_access "$REPO"; then
    token=""
    say "This Mac already reaches $REPO with its own GitHub sign-in; keeping that."
    return 0
  fi
  # The person has their own git settings for this repo and they don't work right now:
  # leave them exactly as they are and add nothing.
  if own_repo_settings "$REPO"; then
    token=""
    say "This Mac has its own git sign-in settings for $REPO, and they don't reach it right now."
    say "They were left as they are and the shared access key wasn't added. Check your own GitHub sign-in, or ask the person who manages Claude setup for your team."
    return 1
  fi
  # Only our helper answers for this repo, as user x-access-token (a host-wide GitHub
  # username setting would otherwise hide the key). Other GitHub use is untouched.
  for url in "https://github.com/$REPO.git" "https://github.com/$REPO"; do
    git config --global --add "credential.$url.helper" ""
    git config --global --add "credential.$url.helper" "$HELPER"
    git config --global "credential.$url.useHttpPath" true
    git config --global "credential.$url.username" x-access-token
    git config --global "credential.$url.$MARKER_KEY" true
  done
  # printf is a shell builtin: the key reaches git's stdin, never a process argument.
  for path in "$REPO.git" "$REPO"; do
    printf 'protocol=https\nhost=github.com\npath=%s\nusername=x-access-token\npassword=%s\n\n' "$path" "$token" | credential approve >/dev/null 2>&1 || rc=1
    saved_key_available "$path" || rc=1
  done
  token=""
  if [ "$rc" != 0 ]; then
    keychain_info="$(security show-keychain-info 2>&1)" || :
    if grep -qF 'User interaction is not allowed' <<<"$keychain_info"; then
      say "Your Mac's Keychain is locked or this isn't a desktop Terminal session. Open Terminal on the Mac itself (not over remote login), unlock if asked, and run the command again."
    else
      say "Couldn't save and verify the access key in the Keychain. Run the command again; if it repeats, tell the person who manages Claude setup for your team."
    fi
    return 1
  fi
  say "Saved the access key in the Keychain (used only for $REPO)."
}

# Step 6. Sets SRC_DIR (a temporary folder; the caller removes it).
download_setup() {
  if [ "$DRY" = 1 ]; then
    say "[dry-run] git clone --depth 1 ${HARNESS_REF:+--branch $HARNESS_REF }https://github.com/<repo from 1Password>.git, then run its setup/setup.sh $*"
    return 0
  fi
  WORK="$(mktemp -d -t claude-setup)"
  say "Downloading your team's setup files..."
  if ! GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 ${HARNESS_REF:+--branch "$HARNESS_REF"} "https://github.com/$REPO.git" "$WORK/repo"; then
    say "Couldn't download $REPO with the access key from 1Password."
    say "The key may have expired. Tell the person who manages Claude setup for your team."
    return 1
  fi
  [ -f "$WORK/repo/setup/setup.sh" ] || { say "$REPO has no setup/setup.sh. Tell the person who manages Claude setup for your team."; return 1; }
  SRC_DIR="$WORK/repo"
}

main() {
  local a rc
  set -uo pipefail
  ADDR=""; DRY=0; PASS=(); REPO=""; WORK=""; SRC_DIR=""
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY=1; PASS+=("$a");;
      --admin) PASS+=("$a");;
      -h|--help) usage;;
      -*) say "Unknown option: $a"; usage;;
      *) [ -z "$ADDR" ] || usage; ADDR="$a";;
    esac
  done
  [ -n "$ADDR" ] || usage
  printf '%s' "$ADDR" | grep -qE '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' || { say "\"$ADDR\" doesn't look like a 1Password sign-in address."; usage; }
  trap '[ -n "$WORK" ] && rm -rf "$WORK"' EXIT

  say "== Checking this Mac"
  preflight
  say "== Homebrew"
  ensure_homebrew
  say "== 1Password"
  ensure_1password
  wait_for_1password
  say "== Access to your team's setup files"
  save_access_key || exit 1
  download_setup "${PASS[@]+"${PASS[@]}"}" || exit 1
  if [ "$DRY" = 1 ]; then say "(dry run — nothing was changed)"; exit 0; fi

  say "== Running your team's setup"
  HARNESS_SRC="$SRC_DIR" HARNESS_REF="${HARNESS_REF:-}" bash "$SRC_DIR/setup/setup.sh" "${PASS[@]+"${PASS[@]}"}"
  rc=$?
  exit "$rc"
}

# Run only when executed (bash install.sh, bash <(curl ...), curl ... | bash), not
# when sourced by a test.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi

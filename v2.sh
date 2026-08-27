#!/usr/bin/env bash
# Palisades-Labs harness v2 shim: bootstraps a bare Mac far enough to fetch the
# private setup script via GitHub CLI, then hands off to it.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Palisades-Labs/claude-harness-installer/main/v2.sh) <org>/<repo> [--admin] [--dry-run]
#
# Everything real lives in the client repo at setup/setup.sh — this file stays
# a thin public fetcher so the one-liner works against a private repo.
set -euo pipefail
main() {
  REPO="${1:?usage: v2.sh <org>/<repo> [--admin] [--dry-run]}"
  shift || true # remaining args are forwarded to setup.sh verbatim

  # Fresh-Mac bootstrap: a factory Mac has neither developer tools, Homebrew, nor gh.
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "[v2] Installing Apple's command line tools — click Install on the dialog,"
    echo "[v2] then RE-RUN this same command when it finishes."
    xcode-select --install || true
    exit 1
  fi
  if ! command -v brew >/dev/null 2>&1; then
    echo "[v2] Installing Homebrew (you may be asked for your Mac password)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
  fi
  command -v gh >/dev/null 2>&1 || { echo "[v2] Installing the GitHub tool..."; brew install -q gh; }
  gh auth status >/dev/null 2>&1 || gh auth login

  TMP="$(mktemp -t harness-setup-XXXXXX.sh)"
  trap 'rm -f "$TMP"' EXIT
  if ! gh api -H "Accept: application/vnd.github.raw" "/repos/$REPO/contents/setup/setup.sh" > "$TMP" 2>/dev/null; then
    echo "[v2] Could not fetch the setup script from $REPO."
    echo "[v2] Your GitHub account may not have access yet — ask your admin to invite you"
    echo "[v2] to the repo (read access), accept the email invite, and re-run this command."
    exit 1
  fi
  exec bash "$TMP" "$@"
}
main "$@"

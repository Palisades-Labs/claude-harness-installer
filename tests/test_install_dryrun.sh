#!/usr/bin/env bash
# Tests for install.sh with stubbed uname, id, brew, op, pgrep, git, gh, sudo,
# sleep and open. Nothing real is installed, read from 1Password, or saved in the
# Keychain: every case gets a fresh temp HOME and PATH="$STUB:/usr/bin:/bin".
# The fake access key exists only in the FAKE_TOKEN environment variable; the stubs
# compare against it and never write it anywhere.
# No -e: assertion conditions may fail; the FAILURES counter decides.
set -uo pipefail
INSTALL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh"
FAILURES=0
FAKE_TOKEN="github_pat_FAKEinstallerTESTONLY42"
export FAKE_TOKEN
ADDR="acme.1password.com"

assert() { if [ "$2" -eq 0 ]; then echo "ok   - $1"; else echo "FAIL - $1"; FAILURES=$((FAILURES+1)); fi }

new_case() {
  T="$(mktemp -d)"; H="$T/home"; STUB="$T/stub"; EVENTS="$T/events.log"; STATE="$T/state"
  mkdir -p "$H" "$STUB" "$STATE"; : > "$EVENTS"
  for t in brew sudo open osascript; do
    printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "$EVENTS"\nexit 0\n' "$t" > "$STUB/$t"
  done
  cat > "$STUB/brew" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = --prefix ] && { echo "$STATE/prefix"; exit 0; }
printf 'brew %s\n' "$*" >> "$EVENTS"
printf 'stub brew noisy output\n'
if [ "${1:-}" = update ]; then
  printf 'brew quiet flags=%s/%s/%s\n' "$HOMEBREW_NO_ENV_HINTS" "$HOMEBREW_NO_INSTALL_CLEANUP" "$HOMEBREW_NO_AUTO_UPDATE" >> "$EVENTS"
  if [ "${STUB_UPDATE_RC:-0}" = 1 ]; then for n in 1 2 3 4 5 6 7 8; do echo "failure detail $n"; done; fi
  exit "${STUB_UPDATE_RC:-0}"
fi
[ "${1:-}" = fetch ] && exit "${STUB_FETCH_RC:-0}"
if [ "${1:-}" = list ]; then [ "${*: -1}" = "1password-cli" ] && [ "${STUB_REGULAR:-0}" = 1 ]; exit $?; fi
if [ "${1:-}" = uninstall ]; then rm -f "$(dirname "$0")/op"; fi
if [ "${1:-}" = install ]; then
  case "${*: -1}" in
    1password-cli@beta)
      [ "${STUB_BETA_RC:-0}" = 0 ] || exit 1
      cp "$STATE/op.template" "$(dirname "$0")/op"; echo 2.40.0-beta.02 > "$STATE/version";;
    1password-cli)
      [ "${STUB_STABLE_RC:-0}" = 0 ] || exit 1
      cp "$STATE/op.template" "$(dirname "$0")/op";;
  esac
fi
exit 0
STUB
  mkdir -p "$STATE/prefix"
  printf '#!/bin/sh\necho Darwin\n' > "$STUB/uname"
  printf '#!/bin/sh\n[ "$1" = "-u" ] && { echo 501; exit 0; }\necho "${STUB_GROUPS:-staff everyone admin}"\n' > "$STUB/id"
  printf '#!/bin/sh\nexit 0\n' > "$STUB/sleep"
  printf '#!/bin/sh\n[ "${STUB_APP_CLOSED:-0}" != 1 ]\n' > "$STUB/pgrep"

  # op: `account list` shows the address unless STUB_LIST_STATE says otherwise for
  # the first STUB_LIST_TIMES plain calls (integration-off / no-account / locked);
  # `item get` returns the repo field or the fake key.
  cat > "$STUB/op" <<'STUB'
#!/usr/bin/env bash
printf 'op %s\n' "$*" >> "$EVENTS"
case "$1 ${2:-}" in
  "--version ") if [ -f "$STATE/version" ]; then cat "$STATE/version"; else echo "${STUB_OP_VERSION:-2.40.0-beta.02}"; fi;;
  "account list")
    n=$(cat "$STATE/lists" 2>/dev/null || echo 0)
    forced=0; [ "${OP_BIOMETRIC_UNLOCK_ENABLED:-}" = true ] && forced=1
    [ "$forced" = 0 ] && { n=$((n+1)); echo "$n" > "$STATE/lists"; }
    if [ "$n" -le "${STUB_LIST_TIMES:-0}" ]; then
      case "${STUB_LIST_STATE:-}" in
        integration-off) [ "$forced" = 1 ] && echo '[{"url":"acme.1password.com"}]' || echo '[]';;
        no-account) echo '[{"url":"my.1password.com"}]';;
        *) echo '[]';;
      esac
    else
      echo '[{"url":"my.1password.com"},{"url":"acme.1password.com"}]'
    fi;;
  "account get") echo "URL: acme.1password.com";;
  "item get")
    [ -n "${STUB_ITEM_ERROR:-}" ] && { echo "[ERROR] 2026/10/02 23:18:31 $STUB_ITEM_ERROR" >&2; exit 1; }
    case "$*" in
      *label=repo*) echo "acme-co/acme-harness";;
      *label=credential*--reveal*) printf '%s\n' "$FAKE_TOKEN";;
    esac;;
esac
exit 0
STUB

  # git: logs argv. `config` runs the real git against the temp HOME. `credential
  # approve` records only whether the key matched and keeps a "saved" marker that
  # `reject` removes. `ls-remote` works only with this Mac's own sign-in
  # (STUB_OWN_ACCESS=1) or with our helper configured and the key saved. `clone`
  # creates a checkout whose setup/setup.sh records how it was started.
  cat > "$STUB/git" <<'STUB'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$EVENTS"
case " $* " in
  *" config "*) exec /usr/bin/git "$@";;
  *" ls-remote "*)
    [ "${STUB_OWN_ACCESS:-0}" = 1 ] && exit 0
    /usr/bin/git config --global --get-all credential.https://github.com/acme-co/acme-harness.git.helper 2>/dev/null | grep -q . && [ -e "$STATE/key-saved" ] && exit 0
    exit 128;;
esac
case "$*" in
  *"credential approve"*)
    p=""; pw=""; while IFS= read -r l && [ -n "$l" ]; do case "$l" in path=*) p="${l#path=}";; password=*) pw="${l#password=}";; esac; done
    touch "$STATE/key-saved"
    if [ "$pw" = "$FAKE_TOKEN" ]; then echo "approve path=$p key_matches=1" >> "$EVENTS"; else echo "approve path=$p key_matches=0" >> "$EVENTS"; fi;;
  *"credential reject"*)
    p=""; while IFS= read -r l && [ -n "$l" ]; do case "$l" in path=*) p="${l#path=}";; esac; done
    rm -f "$STATE/key-saved"; echo "reject path=$p" >> "$EVENTS";;
  clone*)
    for a in "$@"; do dest="$a"; done
    mkdir -p "$dest/setup"
    printf '#!/usr/bin/env bash\nprintf "src=%%s ref=%%s args=%%s\\n" "$HARNESS_SRC" "$HARNESS_REF" "$*" >> "$EVENTS"\nexit "${STUB_SETUP_RC:-0}"\n' > "$dest/setup/setup.sh";;
esac
exit 0
STUB
  chmod +x "$STUB"/*
  cp "$STUB/op" "$STATE/op.template"
}

run_case() { # [VAR=value...] <args...> -> OUT, RC
  OUT="$(cd "$T" && env GIT_CONFIG_NOSYSTEM=1 HOME="$H" EVENTS="$EVENTS" STATE="$STATE" SETUP_BREW_CANDIDATES="" \
    PATH="$STUB:/usr/bin:/bin" "$@" 2>&1)"; RC=$?
}
line_of() { grep -n -- "$1" "$EVENTS" | head -1 | cut -d: -f1; }

# ---- Argument and machine checks ----
new_case
run_case bash "$INSTALL"
[ "$RC" = 2 ] && grep -q "Usage: install.sh" <<<"$OUT"; assert "no address: usage, exit 2" $?
run_case bash "$INSTALL" "not an address"
[ "$RC" = 2 ] && grep -q "doesn't look like a 1Password sign-in address" <<<"$OUT"; assert "bad address: says so, exit 2" $?
printf '#!/bin/sh\necho Linux\n' > "$STUB/uname"
run_case bash "$INSTALL" "$ADDR"
[ "$RC" = 1 ] && grep -q "works on a Mac only" <<<"$OUT"; assert "non-Mac: plain refusal" $?
new_case
run_case env STUB_GROUPS="staff everyone" bash "$INSTALL" "$ADDR"
[ "$RC" = 1 ] && grep -q "needs to be an administrator" <<<"$OUT" && [ ! -s "$EVENTS" ]; assert "non-admin: one-line explanation, nothing run" $?

# ---- Dry run, everything already installed ----
new_case
run_case bash "$INSTALL" "$ADDR" --dry-run --admin
[ "$RC" = 0 ]; assert "dry-run: exits 0" $?
grep -q "wait until 1Password shows $ADDR" <<<"$OUT" && grep -q 'Claude Setup Access' <<<"$OUT" && grep -q 'git clone --depth 1' <<<"$OUT" && grep -q 'setup/setup.sh --dry-run --admin' <<<"$OUT"; assert "dry-run: shows the 1Password wait, the item, the download and the setup hand-off" $?
# No customer data: the only 1Password address in the script is the example, the only
# repos it names are Homebrew's installer and this one, and the dry run mentions no
# address but the one it was given.
! grep -oE '[A-Za-z0-9-]+\.1password\.(com|ca|eu)' "$INSTALL" | grep -vqx 'yourteam.1password.com' \
  && ! grep -oE 'github(usercontent)?\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$INSTALL" | grep -vqE 'com/(Homebrew/install|Palisades-Labs/claude-harness-installer)$' \
  && [ "$(grep -oE '[A-Za-z0-9-]+\.1password\.(com|ca|eu)' <<<"$OUT" | sort -u)" = "$ADDR" ]; assert "no customer data in the script or its dry-run output" $?
! grep -qE '^op (item|account get)' "$EVENTS" && ! grep -q '^git ' "$EVENTS" && ! grep -qE '^brew install' "$EVENTS"; assert "dry-run: reads nothing from 1Password, runs no git, installs nothing" $?
[ -z "$(ls -A "$H")" ]; assert "dry-run: changes nothing in HOME" $?

# ---- Dry run on a Mac without Homebrew ----
new_case; rm "$STUB/brew"
run_case bash "$INSTALL" "$ADDR" --dry-run
[ "$RC" = 0 ] && grep -q "Homebrew/install@09c62fc577ec170172b0a184060f141a2c622dc1" <<<"$OUT" && grep -q "sudo -v" <<<"$OUT" && ! grep -q '^sudo' "$EVENTS"; assert "no Homebrew: plans the pinned installer after one sudo -v, runs nothing" $?

# ---- Full stubbed run ----
new_case
run_case env HARNESS_REF=feat/test bash "$INSTALL" "$ADDR" --admin
[ "$RC" = 0 ]; assert "full run: exits with setup's result (0)" $?
grep -q 'approve path=acme-co/acme-harness.git key_matches=1' "$EVENTS" && grep -q 'approve path=acme-co/acme-harness key_matches=1' "$EVENTS"; assert "key saved for the repo's .git and bare paths, through stdin" $?
grep -q 'git config --global --add credential.https://github.com/acme-co/acme-harness.git.helper $' "$EVENTS" && grep -q 'git config --global --add credential.https://github.com/acme-co/acme-harness.git.helper osxkeychain' "$EVENTS" && grep -q 'git config --global credential.https://github.com/acme-co/acme-harness.useHttpPath true' "$EVENTS"; assert "helper scoped to this repo: reset, osxkeychain, useHttpPath" $?
! grep '^git ' "$EVENTS" | grep 'credential approve' | grep -qv -- '-c credential.helper= -c credential.helper=osxkeychain'; assert "approve goes to our helper only" $?
grep -q '^git clone -q --depth 1 --branch feat/test https://github.com/acme-co/acme-harness.git ' "$EVENTS"; assert "shallow clone of the item's repo at HARNESS_REF" $?
SRC_LINE="$(grep '^src=' "$EVENTS")"
grep -q 'ref=feat/test args=--admin$' <<<"$SRC_LINE"; assert "setup.sh gets HARNESS_REF and --admin" $?
SRC_DIR="$(sed -nE 's/^src=([^ ]*) .*/\1/p' <<<"$SRC_LINE")"
[ -n "$SRC_DIR" ] && [ ! -e "$SRC_DIR" ]; assert "temporary download removed afterwards" $?
A=$(line_of '^op account get'); I=$(line_of '^op item get'); C=$(line_of '^git clone')
[ -n "$A" ] && [ -n "$I" ] && [ -n "$C" ] && [ "$A" -lt "$I" ] && [ "$I" -lt "$C" ]; assert "order: sign-in check, item read, download" $?
[ "$(grep -c '^op account get' "$EVENTS")" = 1 ]; assert "op account get called once (one approval)" $?
! grep -qF -- "$FAKE_TOKEN" <<<"$OUT"; assert "key never in output" $?
! grep -rqF -- "$FAKE_TOKEN" "$T"; assert "key never in any argv log or file" $?
for rc in .zprofile .zshrc; do [ "$(grep -c '# Claude setup: Homebrew on PATH' "$H/$rc")" = 1 ]; assert "$rc: Homebrew line added" $?; done
run_case bash "$INSTALL" "$ADDR"
for rc in .zprofile .zshrc; do [ "$(grep -c 'brew shellenv' "$H/$rc")" = 1 ]; assert "$rc: second run adds no second line" $?; done
run_case env STUB_SETUP_RC=3 bash "$INSTALL" "$ADDR"
[ "$RC" = 3 ]; assert "setup's failure is passed on" $?

# ---- The 1Password approval was missed: says to approve it, changes nothing ----
new_case
run_case env STUB_ITEM_ERROR="error initializing client: authorization timeout" bash "$INSTALL" "$ADDR"
[ "$RC" = 1 ] && grep -q "approval wasn't given in time" <<<"$OUT" && ! grep -q "Couldn't find" <<<"$OUT" && ! grep -qE '^git (config|clone)' "$EVENTS"; assert "missed approval: says to approve the prompt, no git change, no download" $?

# ---- 1Password not ready yet: one plain message per state, then it carries on ----
for spec in "integration-off|Integrate with 1Password CLI" "no-account|account isn't in it yet" "locked|locked or isn't answering"; do
  new_case
  run_case env STUB_LIST_STATE="${spec%%|*}" STUB_LIST_TIMES=3 bash "$INSTALL" "$ADDR"
  [ "$RC" = 0 ] && [ "$(grep -c -- "${spec#*|}" <<<"$OUT")" = 1 ] && [ "$(grep -c '^op account get' "$EVENTS")" = 1 ]; assert "${spec%%|*}: explained once, waits, then one op account get" $?
done
new_case
run_case env STUB_LIST_STATE=integration-off STUB_LIST_TIMES=2 bash "$INSTALL" "$ADDR"
[ "$(grep -c '^open onepassword://settings/developers' "$EVENTS")" = 1 ]; assert "integration off: opens the Developer settings page once" $?
new_case
run_case env STUB_APP_CLOSED=1 bash -c 'source "$1"; ADDR=acme.1password.com; op_state' _ "$INSTALL"
[ "$OUT" = closed ] && ! grep -q '^op ' "$EVENTS"; assert "app not running: reported as closed, op never asked (also: sourcing runs nothing)" $?

# ---- Own access is decided by git itself (I2); our settings go away once it works ----
U1="https://github.com/acme-co/acme-harness.git"; U2="https://github.com/acme-co/acme-harness"
ours() { for u in "$U1" "$U2"; do for k in helper useHttpPath username claudeSetupManaged; do HOME="$H" GIT_CONFIG_NOSYSTEM=1 /usr/bin/git config --global --get-all "credential.$u.$k" 2>/dev/null | sed "s#^#$k=#"; done; done; }
# test_gh_signed_in_without_git_creds: gh would say yes, git says no -> the key is saved
new_case
printf '#!/bin/sh\nprintf "gh %%s\\n" "$*" >> "$EVENTS"\nexit 0\n' > "$STUB/gh"; chmod +x "$STUB/gh"
run_case bash "$INSTALL" "$ADDR"
[ "$RC" = 0 ] && grep -q 'key_matches=1' "$EVENTS" && ! grep -q '^gh ' "$EVENTS" && grep -q "^git -c credential.interactive=false ls-remote $U1 HEAD" "$EVENTS"; assert "test_gh_signed_in_without_git_creds: probes with git ls-remote (prompts off), saves the key" $?
[ "$(ours | tr '\n' ' ')" = "helper= helper=osxkeychain useHttpPath=true username=x-access-token claudeSetupManaged=true helper= helper=osxkeychain useHttpPath=true username=x-access-token claudeSetupManaged=true " ]; assert "test_username_scoped: both URL forms set username=x-access-token and the claudeSetupManaged marker" $?
# test_no_flip_flop: a second run without own access keeps the key
run_case bash "$INSTALL" "$ADDR"
[ "$RC" = 0 ] && [ "$(ours | grep -c 'username=x-access-token')" = 2 ] && [ -e "$STATE/key-saved" ]; assert "test_no_flip_flop: second run without own access keeps the key" $?
# test_own_access_removes_overrides: own sign-in works now -> our settings and saved key removed, download still runs
run_case env STUB_OWN_ACCESS=1 bash "$INSTALL" "$ADDR"
[ "$RC" = 0 ] && [ -z "$(ours)" ] && [ ! -e "$STATE/key-saved" ] && grep -q 'reject path=acme-co/acme-harness.git' "$EVENTS" && grep -q '^git clone' "$EVENTS"; assert "test_own_access_removes_overrides: a marked earlier run is removed (settings, marker, saved key) and re-evaluated; download runs" $?

# test_maintainer_own_helper_kept (I4): a repo-specific personal helper (no marker) that
# works is kept, no key is saved or removed, and the download still runs
new_case
HOME="$H" GIT_CONFIG_NOSYSTEM=1 /usr/bin/git config --global credential."$U1".helper '!my-personal-helper'
run_case env STUB_OWN_ACCESS=1 bash "$INSTALL" "$ADDR"
[ "$RC" = 0 ] && [ "$(ours | tr '\n' ' ')" = "helper=!my-personal-helper " ] && ! grep -qE 'approve|reject path' "$EVENTS" && ! grep -q 'config --global --unset-all' "$EVENTS" && grep -q '^git clone' "$EVENTS"; assert "test_maintainer_own_helper_kept: personal repo helper untouched, no key saved or rejected" $?
# ...and when it doesn't work right now: still untouched, nothing added, plain message, no download
: > "$EVENTS"
run_case bash "$INSTALL" "$ADDR"
[ "$RC" = 1 ] && [ "$(ours | tr '\n' ' ')" = "helper=!my-personal-helper " ] && ! grep -qE 'approve|reject path|^git clone' "$EVENTS" && grep -q "has its own git sign-in settings" <<<"$OUT"; assert "test_maintainer_own_helper_failing_untouched: unmarked settings left, no key added, says so, exit 1" $?

# test_host_username_regression (I3), real git + store helper: a host-wide github.com
# username must not hide the key saved for x-access-token.
new_case
printf '#!/usr/bin/env bash\ncase " $* " in *" ls-remote "*) exit 128;; *" clone "*) for a in "$@"; do d="$a"; done; mkdir -p "$d/setup"; printf "#!/bin/sh\\nexit 0\\n" > "$d/setup/setup.sh"; exit 0;; esac\nexec /usr/bin/git "$@"\n' > "$STUB/git"; chmod +x "$STUB/git"
HOME="$H" GIT_CONFIG_NOSYSTEM=1 /usr/bin/git config --global credential.https://github.com.username personal-user
run_case env SETUP_CREDENTIAL_HELPER=store bash "$INSTALL" "$ADDR"
FILL="$(cd "$T" && printf 'protocol=https\nhost=github.com\npath=acme-co/acme-harness.git\n\n' | env HOME="$H" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 /usr/bin/git credential fill 2>/dev/null)"
[ "$RC" = 0 ] && grep -qx 'username=x-access-token' <<<"$FILL" && [ "$(sed -n 's/^password=//p' <<<"$FILL")" = "$FAKE_TOKEN" ]; assert "test_host_username_regression: git credential fill returns the key despite credential.https://github.com.username" $?
FILL=""

# ---- I1: startup files are rewritten all or nothing ----
# test_rc_unwritable_tmpdir: TMPDIR doesn't exist -> line still added, content kept
new_case; printf 'export KEEP=1\n' > "$H/.zshrc"
run_case env TMPDIR="$T/does-not-exist" bash "$INSTALL" "$ADDR"
head -1 "$H/.zshrc" | grep -q 'Claude setup: Homebrew on PATH' && grep -qx 'export KEEP=1' "$H/.zshrc"; assert "test_rc_unwritable_tmpdir: missing TMPDIR doesn't matter; line added, content kept" $?
# test_rc_mktemp_fails_leaves_file: no temporary file possible -> .zshrc byte-identical, says so
new_case; printf 'export KEEP=1\n' > "$H/.zshrc"; cp "$H/.zshrc" "$T/zshrc.orig"
chmod 555 "$H"
run_case bash -c 'source "$1"; DRY=0; persist_line "eval brew-line  # Claude setup: Homebrew on PATH" "brew shellenv"' _ "$INSTALL"
chmod 755 "$H"
cmp -s "$H/.zshrc" "$T/zshrc.orig" && grep -q "left unchanged" <<<"$OUT"; assert "test_rc_mktemp_fails_leaves_file: .zshrc byte-identical, says so" $?
# test_rc_symlink_kept: a symlinked .zshrc stays a symlink; its target is updated and keeps its mode
new_case; mkdir -p "$T/dotfiles"; printf 'export KEEP=1\n' > "$T/dotfiles/zshrc"; chmod 640 "$T/dotfiles/zshrc"; ln -s "$T/dotfiles/zshrc" "$H/.zshrc"
run_case bash "$INSTALL" "$ADDR"
[ -L "$H/.zshrc" ] && head -1 "$T/dotfiles/zshrc" | grep -q 'Claude setup: Homebrew on PATH' && [ "$(stat -f %Lp "$T/dotfiles/zshrc")" = 640 ]; assert "test_rc_symlink_kept: symlink kept, target updated, mode 640 kept" $?

# C1: ownership rejection precedes startup-file, 1Password and git changes.
new_case; chmod 555 "$STATE/prefix"
run_case bash "$INSTALL" "$ADDR"
[ "$RC" = 1 ] && grep -q "belongs to another user account" <<<"$OUT" && [ -z "$(ls -A "$H")" ] && [ ! -s "$EVENTS" ]; assert "unwritable prefix: stop before any change" $?
chmod 755 "$STATE/prefix"
new_case; mkdir "$STATE/prefix/Caskroom"; chmod 555 "$STATE/prefix/Caskroom"
run_case bash "$INSTALL" "$ADDR"
[ "$RC" = 1 ] && [ -x "$STUB/op" ] && [ ! -s "$EVENTS" ]; assert "unwritable cask folder: keep op and change nothing" $?
chmod 755 "$STATE/prefix/Caskroom"
# C2: stale regular CLI, failed beta download.
new_case
run_case env STUB_REGULAR=1 STUB_OP_VERSION=2.39.0 STUB_FETCH_RC=1 bash "$INSTALL" "$ADDR"
[ "$RC" = 1 ] && [ -x "$STUB/op" ] && ! grep -q '^brew uninstall' "$EVENTS" && ! grep -q '^op item' "$EVENTS"; assert "failed beta fetch: keep regular op, stop before access-key reads" $?
new_case
run_case env STUB_REGULAR=1 STUB_OP_VERSION=2.39.0 bash "$INSTALL" "$ADDR"
F=$(line_of '^brew fetch --cask 1password-cli@beta$'); U=$(line_of '^brew uninstall --cask 1password-cli$')
[ "$RC" = 0 ] && [ -n "$F" ] && [ -n "$U" ] && [ "$F" -lt "$U" ]; assert "regular CLI: fetch beta before uninstall, install successfully" $?
new_case
run_case env STUB_REGULAR=1 STUB_OP_VERSION=2.39.0 STUB_BETA_RC=1 bash "$INSTALL" "$ADDR"
[ "$RC" = 1 ] && [ -x "$STUB/op" ] && grep -q '^brew install --cask 1password-cli$' "$EVENTS" && grep -q 'regular 1Password tool was put back' <<<"$OUT"; assert "failed beta install: restore regular op and stop" $?
new_case
run_case env STUB_REGULAR=1 STUB_OP_VERSION=2.39.0 STUB_BETA_RC=1 STUB_STABLE_RC=1 bash "$INSTALL" "$ADDR"
[ "$RC" = 1 ] && [ -x "$STUB/op" ] && grep -q 'previous 1Password tool was put back' <<<"$OUT"; assert "both installs fail: saved executable keeps op available" $?
# C4: one refresh; only the failure tail escapes the private log.
new_case
run_case bash "$INSTALL" "$ADDR"
[ "$RC" = 0 ] && [ "$(grep -c '^brew update$' "$EVENTS")" = 1 ] && ! grep -q 'stub brew noisy output' <<<"$OUT" && grep -rq 'stub brew noisy output' "$H/Library/Logs/claude-setup"; assert "one quiet brew refresh with detailed output in the log" $?
grep -q '^brew quiet flags=1/1/1$' "$EVENTS"; assert "brew disables hints, cleanup and automatic refresh" $?
new_case
run_case env STUB_UPDATE_RC=1 bash "$INSTALL" "$ADDR"
[ "$RC" = 1 ] && grep -q 'Library/Logs/claude-setup' <<<"$OUT" && grep -q 'failure detail 8' <<<"$OUT" && ! grep -q '^op ' "$EVENTS"; assert "refresh failure: show log tail and path, stop before 1Password" $?
grep -q 'failure detail 4' <<<"$OUT" && grep -q 'failure detail 8' <<<"$OUT" && ! grep -qE 'failure detail [123]$' <<<"$OUT"; assert "Homebrew failure shows exactly its last five log lines" $?
# C3: public handoff inherits stdin and never redirects a CLI from /dev/tty.
! grep -q '/dev/tty' "$INSTALL"; assert "installer never redirects the CLI from /dev/tty" $?

echo "---"
if [ "$FAILURES" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILURES FAILURES"; exit 1; fi

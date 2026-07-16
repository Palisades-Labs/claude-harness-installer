# Palisades-Labs Claude Code harness bootstrap (decrypt-only, Windows).
#
# Decrypts the client's age-encrypted credentials file (shipped via Claude
# Desktop marketplace sync) into ~/.claude/credentials/credentials.env so
# skills that need API keys (Tavily, Avoma, etc.) can read them at runtime.
#
# Usage (one-liner, via iwr|iex — set env vars first so param binding works):
#     $env:DECRYPT_MODE='1'; $env:CLIENT_REPO='<org>/<repo>'; `
#       iwr -useb https://raw.githubusercontent.com/Palisades-Labs/claude-harness-installer/main/bootstrap.ps1 | iex
#
# Or locally:
#     .\bootstrap.ps1 -Decrypt -Repo <org>/<repo>
#
# Prereq: the client marketplace must already be added + synced in Claude
# Desktop. Bootstrap probes ~/.claude/plugins/marketplaces/ for a directory
# matching one of these names (in order):
#   1. <repo-basename>                              (e.g. insidescale-claude-harness)
#   2. <repo-basename> minus -claude-harness suffix (e.g. insidescale)
#   3. <repo-basename> minus -harness suffix
# It picks the first one that contains credentials/credentials.env.age. If
# none match, errors with "marketplace not synced yet".
#
# What this does (idempotent):
#   1. Verifies `age` is installed.
#   2. Probes for the marketplace directory by name candidates.
#   3. Confirms the marketplace sync directory + credentials.env.age exist.
#   4. Prompts for the setup passphrase your admin sent you separately.
#   5. Stores passphrase DPAPI-protected at ~/.claude/credentials/.passphrase.
#   6. Decrypts to ~/.claude/credentials/credentials.env (owner-only ACL).
#   7. Adds a one-time source stanza to your PowerShell $PROFILE so new
#      shells pick up the keys.
#   8. Splices the harness's orientation content into ~/.claude/CLAUDE.md.
#      Prefers the plugin overlay CLAUDE.md (team-facing operating rules) at
#      plugins/<primary-plugin>/CLAUDE.md, falling back to the marketplace
#      root CLAUDE.md (maintainer overview) when no plugin overlay exists.
#
# Does NOT: install Claude Code, fetch PATs, merge settings.json, or register
# the marketplace. Those are handled by Claude Desktop / separate installer paths.

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Decrypt,
    [string]$Repo
)

$ErrorActionPreference = 'Stop'

function Log  { param([string]$Msg) Write-Host "[bootstrap] $Msg" -ForegroundColor Cyan }
function Warn { param([string]$Msg) Write-Host "[warn] $Msg"      -ForegroundColor Yellow }
function Die  { param([string]$Msg) Write-Host "[error] $Msg"     -ForegroundColor Red; exit 1 }

# -----------------------------------------------------------------------------
# 0) Validate args
# -----------------------------------------------------------------------------
# When invoked via `iwr | iex`, param() binding is skipped — fall back to env vars.
if (-not $Repo)    { $Repo = $env:CLIENT_REPO }
if (-not $Decrypt -and $env:DECRYPT_MODE -eq '1') { $Decrypt = $true }

if (-not $Decrypt -or -not $Repo -or $Repo -notmatch '^[^/]+/[^/]+$') {
    Write-Host "[error] Usage: bootstrap.ps1 -Decrypt -Repo <org>/<repo>  (e.g. Palisades-Labs/insidescale-claude-harness)" -ForegroundColor Red
    Write-Host "[error] Prereq: add + sync the client marketplace in Claude Desktop before running." -ForegroundColor Red
    exit 1
}

$RepoName = $Repo.Split('/')[-1]

# Find the marketplace directory by probing common name conventions. The
# directory name on disk equals the `name` field in marketplace.json, which a
# client can set to anything — historically the stripped form (e.g.
# `insidescale`), but increasingly the full repo name. Try each candidate in
# order, picking the first that has the expected credentials.env.age inside.
# Mirrors the same probe in bootstrap.sh.
$MarketplaceName = ''
$NameCandidates = @(
    $RepoName,
    ($RepoName -replace '-claude-harness$', ''),
    ($RepoName -replace '-harness$', '')
)
foreach ($_candidate in $NameCandidates) {
    $probe = Join-Path $HOME ".claude\plugins\marketplaces\$_candidate\credentials\credentials.env.age"
    if (Test-Path -LiteralPath $probe) {
        $MarketplaceName = $_candidate
        break
    }
}
# Fallback if no candidate matched — keep the legacy derivation so the
# downstream "marketplace not synced yet" error names a useful path.
if (-not $MarketplaceName) {
    $MarketplaceName = $RepoName -replace '-claude-harness$', ''
    $MarketplaceName = $MarketplaceName -replace '-harness$', ''
}

Log "Client repo:       $Repo"
Log "Marketplace name:  $MarketplaceName"

# -----------------------------------------------------------------------------
# 1) Verify age is installed
# -----------------------------------------------------------------------------
# `age` is the only external dependency in the decrypt-only flow. Fail loud
# on missing — decrypt is user-interactive, so a cryptic error deep in the
# script is worse than a clear prereq-missing message up front.
if (-not (Get-Command age -ErrorAction SilentlyContinue)) {
    Die "age is not installed. Install it via 'winget install FiloSottile.age' or 'choco install age', then re-run."
}

# -----------------------------------------------------------------------------
# 2) Verify credentials.env.age exists in the Desktop-synced marketplace dir
# -----------------------------------------------------------------------------
$CredsDir = Join-Path $HOME '.claude\credentials'
# The marketplace directory is the Claude Desktop checkout of the client repo;
# everything we read (the .age below, the CLAUDE.md later) lives under it.
$MarketplaceDir = Join-Path $HOME ".claude\plugins\marketplaces\$MarketplaceName"
# Path matches bootstrap.sh: the encrypted credentials file lives in a
# `credentials/` subdirectory of the marketplace. (Earlier bootstrap.ps1
# omitted the subdir, which would have failed against any real harness.)
$AgeFile  = Join-Path $MarketplaceDir 'credentials\credentials.env.age'

# Auto-heal a stale marketplace checkout BEFORE reading its credentials (parity
# with bootstrap.sh). Claude Desktop is supposed to keep this checkout current
# with GitHub, but that sync can silently freeze (observed in the field: a
# checkout stuck weeks / dozens of commits behind, so every decrypt produced
# stale credentials with no error surfaced). If the marketplace is a git
# checkout behind its upstream, fast-forward it here so we always decrypt the
# CURRENT credentials. ff-only is non-destructive and fails closed: on a
# dirty/diverged/offline/auth-gated checkout it leaves the tree untouched, warns,
# and we decrypt whatever is present rather than blocking the user.
# We must never HANG on this fetch/pull. GIT_TERMINAL_PROMPT=0 disables git's
# built-in terminal prompter, and `-c credential.interactive=false` tells a
# credential helper (Git Credential Manager on Windows) not to pop its own GUI
# auth dialog — together they make a private-repo auth failure fail fast instead
# of blocking.
if ((Test-Path -LiteralPath (Join-Path $MarketplaceDir '.git') -PathType Container) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $prevGTP = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = '0'
    # git writes progress to stderr and returns non-zero on a failed fetch/pull;
    # under $ErrorActionPreference='Stop' (set above) PowerShell 7.4+ would THROW
    # on that non-zero exit instead of setting $LASTEXITCODE, which would abort
    # bootstrap on an offline/diverged checkout. Run the probe under 'Continue'
    # and gate purely on $LASTEXITCODE so every failure path just warns + proceeds.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        git -c credential.interactive=false -C $MarketplaceDir fetch -q origin 2>$null
        if ($LASTEXITCODE -eq 0) {
            $behind = (git -C $MarketplaceDir rev-list --count 'HEAD..@{u}' 2>$null)
            if ($LASTEXITCODE -eq 0 -and $behind -match '^\d+$' -and [int]$behind -gt 0) {
                Log "Marketplace checkout is $behind commit(s) behind — updating so credentials are current."
                git -c credential.interactive=false -C $MarketplaceDir pull --ff-only -q 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Log "[ok] Marketplace updated to latest — decrypting current credentials."
                } else {
                    Warn "Could not fast-forward the marketplace checkout (dirty, diverged, or offline). Credentials may be STALE. In Claude Desktop, run: /plugin marketplace update $MarketplaceName"
                }
            }
        } else {
            Warn "Could not reach GitHub to check for marketplace updates (offline?) — using the currently-synced credentials."
        }
    } finally {
        $ErrorActionPreference = $prevEAP
        # Restore GIT_TERMINAL_PROMPT to its prior state (unset it if it was unset).
        if ($null -eq $prevGTP) { Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue }
        else { $env:GIT_TERMINAL_PROMPT = $prevGTP }
    }
}

# Check BEFORE prompting for the passphrase. No point asking for a secret if
# the input file is missing. Error wording matches bootstrap.sh byte-for-byte
# (with forward slashes in the path, per the bash version).
if (-not (Test-Path -LiteralPath $AgeFile)) {
    Die "credentials.env.age not found at ~/.claude/plugins/marketplaces/$MarketplaceName/credentials/credentials.env.age — marketplace not synced yet. Add it in Claude Desktop and wait for sync before re-running."
}

# -----------------------------------------------------------------------------
# 3) Collect setup passphrase
# -----------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $CredsDir)) {
    New-Item -ItemType Directory -Path $CredsDir -Force | Out-Null
}

Log "You will be prompted for the setup passphrase your admin sent you separately."
try {
    $securePassphrase = Read-Host -Prompt "[bootstrap] Setup passphrase (from your admin, separate from install command)" -AsSecureString
} catch {
    # Non-interactive stdin (iwr|iex through piped input, CI, etc.) — Read-Host
    # throws instead of returning empty under $ErrorActionPreference = 'Stop'.
    # Treat EOF as empty passphrase so the "No passphrase entered" warn branch
    # handles it uniformly. Mirrors bootstrap.sh:156 `|| HARNESS_PASSPHRASE=""`.
    $securePassphrase = $null
}

# Empty-passphrase test: pull length from the SecureString without extracting
# plaintext. If the user just hit Enter, Length is 0.
if (-not $securePassphrase -or $securePassphrase.Length -eq 0) {
    Warn "No passphrase entered — credential decryption skipped. API tools won't work until re-run with passphrase."
} else {
    # -------------------------------------------------------------------------
    # 4) Store passphrase DPAPI-protected (owner-only, machine-locked)
    # -------------------------------------------------------------------------
    $PassphraseFile = Join-Path $CredsDir '.passphrase'

    # Create the file first with tight ACL BEFORE writing secrets — no window
    # where the file is readable by anyone but the owner. PowerShell equivalent
    # of the bash `( umask 077 && ... )` pattern.
    if (-not (Test-Path -LiteralPath $PassphraseFile)) {
        New-Item -ItemType File -Path $PassphraseFile -Force | Out-Null
    }
    # Strip inherited ACEs and grant ONLY the current user Read+Write.
    # Native exes don't elevate non-zero exits through $ErrorActionPreference —
    # check $LASTEXITCODE explicitly so silent icacls failure doesn't leave the
    # file with inherited ACLs before we write the secret.
    & icacls $PassphraseFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "icacls failed on $PassphraseFile (exit $LASTEXITCODE)" }

    # DPAPI: only the same user on the same machine can decrypt. No -Key
    # parameter → default DPAPI protection.
    $encrypted = ConvertFrom-SecureString $securePassphrase
    Set-Content -Path $PassphraseFile -Value $encrypted -NoNewline
    Log "[ok] Passphrase stored (DPAPI-protected) at ~/.claude/credentials/.passphrase"

    # -------------------------------------------------------------------------
    # 5) Decrypt credentials.env.age → credentials.env
    # -------------------------------------------------------------------------
    $CredsFile = Join-Path $CredsDir 'credentials.env'

    # Create output file with tight ACL BEFORE age writes to it.
    if (-not (Test-Path -LiteralPath $CredsFile)) {
        New-Item -ItemType File -Path $CredsFile -Force | Out-Null
    }
    & icacls $CredsFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "icacls failed on $CredsFile (exit $LASTEXITCODE)" }

    # Extract plaintext passphrase through BSTR, scrub BSTR after use.
    # The $plain .NET string is immutable so can't be zeroed — BSTR zeroing
    # is the best we can do to minimize exposure.
    # Passphrase goes to age via stdin (piped), NEVER on argv.
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassphrase)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $plain | & age --decrypt -o $CredsFile $AgeFile
        if ($LASTEXITCODE -ne 0) {
            Die "age --decrypt failed (exit $LASTEXITCODE). Wrong passphrase, or credentials.env.age is malformed."
        }
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    # Re-lock ACL after age wrote the file — age may recreate via atomic
    # rename which can restore inheritance.
    & icacls $CredsFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "icacls failed on $CredsFile (exit $LASTEXITCODE)" }
    Log "[ok] Credentials decrypted to ~/.claude/credentials/credentials.env"
}

# -----------------------------------------------------------------------------
# 6) Ensure $PROFILE sources credentials.env on shell start (idempotent)
# -----------------------------------------------------------------------------
$profilePath = $PROFILE
$profileDir  = Split-Path -Parent $profilePath
if (-not (Test-Path -LiteralPath $profileDir))  { New-Item -ItemType Directory -Path $profileDir  -Force | Out-Null }
if (-not (Test-Path -LiteralPath $profilePath)) { New-Item -ItemType File      -Path $profilePath -Force | Out-Null }

$credsMarker = '# Palisades-Labs claude-harness-installer: credentials source'
$alreadyPresent = $false
if (Test-Path -LiteralPath $profilePath) {
    $alreadyPresent = [bool](Select-String -LiteralPath $profilePath -SimpleMatch -Pattern $credsMarker -Quiet)
}

if ($alreadyPresent) {
    Log "[ok] Credentials source stanza already present in $profilePath"
} else {
    $credsFilePath = Join-Path $CredsDir 'credentials.env'
    $stanza = @"

$credsMarker
if (Test-Path '$credsFilePath') { Get-Content '$credsFilePath' | Where-Object { `$_ -match '^[A-Z_]+=.' } | ForEach-Object { `$k,`$v = `$_ -split '=',2; Set-Item "env:`$k" `$v } }
"@
    Add-Content -Path $profilePath -Value $stanza
    Log "[ok] Added credentials source stanza to $profilePath"
}

# -----------------------------------------------------------------------------
# 7) Inject harness orientation into ~/.claude/CLAUDE.md
# -----------------------------------------------------------------------------
# Claude Code auto-loads ~/.claude/CLAUDE.md in every session. Splice the
# harness's CLAUDE.md content between marketplace-scoped markers so multiple
# harnesses can coexist and re-runs idempotently update the block without
# touching the user's own content.
#
# Source selection mirrors bootstrap.sh's delegation logic: prefer the plugin
# overlay CLAUDE.md (team-facing operating rules) when present, fall back to
# the marketplace root CLAUDE.md (maintainer overview) otherwise. Convention:
# the "primary" plugin's directory name matches the marketplace name.
# $MarketplaceDir is defined above (before the decrypt step).
$PrimaryPluginDir = Join-Path $MarketplaceDir "plugins\$MarketplaceName"
$PluginOverlay    = Join-Path $PrimaryPluginDir 'CLAUDE.md'
$RepoRootClaude   = Join-Path $MarketplaceDir 'CLAUDE.md'

if (Test-Path -LiteralPath $PluginOverlay) {
    $HomeClaudeSrc = $PluginOverlay
} else {
    $HomeClaudeSrc = $RepoRootClaude
}
$HomeClaudeDst = Join-Path $HOME '.claude\CLAUDE.md'
$BeginMarker = "<!-- claude-harness orientation: $MarketplaceName (begin) -->"
$EndMarker   = "<!-- claude-harness orientation: $MarketplaceName (end) -->"

if (Test-Path -LiteralPath $HomeClaudeSrc) {
    $dstDir = Split-Path -Parent $HomeClaudeDst
    if (-not (Test-Path -LiteralPath $dstDir))  { New-Item -ItemType Directory -Path $dstDir  -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $HomeClaudeDst)) { New-Item -ItemType File -Path $HomeClaudeDst -Force | Out-Null }

    $existing = Get-Content -LiteralPath $HomeClaudeDst -Raw -ErrorAction SilentlyContinue
    if ($null -eq $existing) { $existing = '' }
    $orientation = Get-Content -LiteralPath $HomeClaudeSrc -Raw

    if ($existing -match [regex]::Escape($BeginMarker)) {
        # Existing block — replace content between markers in-place. Use a
        # MatchEvaluator so $-substitutions (e.g. dollar signs in the orientation
        # content) are passed through literally.
        $pattern = [regex]::Escape($BeginMarker) + '[\s\S]*?' + [regex]::Escape($EndMarker)
        $replacement = "$BeginMarker`n$orientation$EndMarker"
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement }
        $updated = [regex]::Replace($existing, $pattern, $evaluator)
        # Set-Content rewrites atomically on Windows (temp + rename).
        Set-Content -LiteralPath $HomeClaudeDst -Value $updated -NoNewline
        Log "[ok] Updated $MarketplaceName orientation block in ~/.claude/CLAUDE.md"
    } else {
        # First install — append a new block, preserving any existing content.
        $sep = ''
        if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { $sep = "`n" }
        $block = "$sep`n$BeginMarker`n$orientation$EndMarker`n"
        Add-Content -LiteralPath $HomeClaudeDst -Value $block -NoNewline
        Log "[ok] Added $MarketplaceName orientation block to ~/.claude/CLAUDE.md"
    }
} else {
    Log "[info] No CLAUDE.md in this marketplace — skipping ~/.claude/CLAUDE.md injection."
}

# -----------------------------------------------------------------------------
# 8) Done
# -----------------------------------------------------------------------------
Write-Host ''
Log "Bootstrap complete."
Write-Host ''
Write-Host "Next steps:"
Write-Host "  1. Open a new PowerShell window and run: claude"
Write-Host ''

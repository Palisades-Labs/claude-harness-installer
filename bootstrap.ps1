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
# Desktop. Bootstrap reads credentials.env.age from
#     ~/.claude/plugins/marketplaces/<marketplace-name>/credentials.env.age
# where marketplace_name = basename(repo) with any "-claude-harness" suffix stripped.
# If that file is missing, bootstrap errors with "marketplace not synced yet".
#
# What this does (idempotent):
#   1. Verifies `age` is installed.
#   2. Derives marketplace_name from <org>/<repo>.
#   3. Confirms the marketplace sync directory + credentials.env.age exist.
#   4. Prompts for the setup passphrase your admin sent you separately.
#   5. Stores passphrase DPAPI-protected at ~/.claude/credentials/.passphrase.
#   6. Decrypts to ~/.claude/credentials/credentials.env (owner-only ACL).
#   7. Adds a one-time source stanza to your PowerShell $PROFILE so new
#      shells pick up the keys.
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
# Strip '-claude-harness' suffix if present; matches bootstrap.sh and /onboard-client.
# This is the Option C invariant.
$MarketplaceName = $RepoName -replace '-claude-harness$', ''

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
$AgeFile  = Join-Path $HOME ".claude\plugins\marketplaces\$MarketplaceName\credentials.env.age"

# Check BEFORE prompting for the passphrase. No point asking for a secret if
# the input file is missing. Error wording matches bootstrap.sh byte-for-byte
# (with forward slashes in the path, per the bash version).
if (-not (Test-Path -LiteralPath $AgeFile)) {
    Die "credentials.env.age not found at ~/.claude/plugins/marketplaces/$MarketplaceName/credentials.env.age — marketplace not synced yet. Add it in Claude Desktop and wait for sync before re-running."
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
# 7) Done
# -----------------------------------------------------------------------------
Write-Host ''
Log "Bootstrap complete."
Write-Host ''
Write-Host "Next steps:"
Write-Host "  1. Open a new PowerShell window and run: claude"
Write-Host ''

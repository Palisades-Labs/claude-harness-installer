# Palisades-Labs Claude Code harness bootstrap (Windows PowerShell).
#
# Two modes:
#
#   Employee (default) — zero personal GitHub account setup. The installer
#     expects $env:GITHUB_TOKEN to already be set (a fine-grained read-only
#     PAT baked into the command your admin sent you). Never calls `gh auth`.
#     Never prompts for anything.
#
#     Employees never run this script directly — they paste the one-liner
#     their admin sent them, which looks like:
#
#       Set-ExecutionPolicy -Scope Process Bypass -Force
#       $env:GITHUB_TOKEN='<baked-pat>'
#       $env:CLIENT_REPO='<org>/<repo>'
#       iwr -useb https://raw.githubusercontent.com/Palisades-Labs/claude-harness-installer/main/bootstrap.ps1 | iex
#
#   Admin (-Admin) — interactive setup for consultant and client-admin
#     machines. Drives `gh auth login --web`, prompts for a Tavily API key,
#     and derives GITHUB_TOKEN from `gh auth token` (safe only on admin's
#     own machine).
#
#     .\bootstrap.ps1 -Admin -ClientRepo <org>/<repo>
#
# What this does (both modes, additive / idempotent):
#   1. Installs prerequisites via winget → choco fallback: git, node, jq,
#      rsync (+ gh in admin mode).
#   2. Installs Claude Code CLI: `npm i -g @anthropic-ai/claude-code`.
#   3. Appends `$env:GITHUB_TOKEN = ...` to your PowerShell $PROFILE (once).
#   4. Merges the client marketplace + enabled plugins into
#      %USERPROFILE%\.claude\settings.json without touching unrelated keys.
#
# Admin mode additionally:
#   5. Ensures `gh auth login` (streamlined web flow).
#   6. Prompts for a Tavily API key and appends to $PROFILE.

[CmdletBinding()]
param(
    [string]$ClientRepo,
    [switch]$Admin
)

# When invoked via `iwr | iex`, param() binding is skipped — fall back to env vars.
if (-not $ClientRepo) { $ClientRepo = $env:CLIENT_REPO }
if (-not $Admin -and $env:ADMIN_MODE -eq '1') { $Admin = $true }

$ErrorActionPreference = 'Stop'

function Log  { param([string]$Msg) Write-Host "[bootstrap] $Msg" -ForegroundColor Cyan }
function Warn { param([string]$Msg) Write-Host "[warn] $Msg"      -ForegroundColor Yellow }
function Die  { param([string]$Msg) Write-Host "[error] $Msg"     -ForegroundColor Red; exit 1 }

# -----------------------------------------------------------------------------
# 0) Validate args + mode
# -----------------------------------------------------------------------------
if (-not $ClientRepo -or $ClientRepo -notmatch '^[^/]+/[^/]+$') {
    Die "Usage: bootstrap.ps1 [-Admin] -ClientRepo <org>/<repo>  (or set `$env:CLIENT_REPO)"
}

# Employee mode (default) never touches gh — the PAT must be pre-set.
if (-not $Admin -and -not $env:GITHUB_TOKEN) {
    Write-Host "[error] GITHUB_TOKEN is not set." -ForegroundColor Red
    Write-Host "[error] If you didn't see an install command from your admin, ask them to send you one — it embeds the token you need." -ForegroundColor Red
    Write-Host "[error] (If you are a consultant or client admin setting up your own machine, re-run with -Admin for interactive setup.)" -ForegroundColor Red
    exit 1
}

$RepoName = $ClientRepo.Split('/')[-1]
# Strip '-claude-harness' suffix if present; matches bootstrap.sh and /onboard-client.
$MarketplaceName = $RepoName -replace '-claude-harness$', ''

if ($Admin) { Log "Mode:              ADMIN (interactive)" }
else        { Log "Mode:              employee" }
Log "Client repo:       $ClientRepo"
Log "Marketplace name:  $MarketplaceName"

# -----------------------------------------------------------------------------
# 1) Install prerequisites (winget → choco fallback)
# -----------------------------------------------------------------------------
# Refresh PATH after each install so later Get-Command sees the new tool.
function Refresh-Path {
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
}

function Install-Via-Winget {
    param([string]$Id)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $false }
    Log "  winget install --id $Id --silent ..."
    winget install --id $Id --silent --accept-package-agreements --accept-source-agreements -e | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    Refresh-Path
    return $true
}

function Install-Via-Choco {
    param([string]$Id)
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { return $false }
    Log "  choco install $Id -y ..."
    choco install $Id -y --no-progress | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    Refresh-Path
    return $true
}

function Ensure-Tool {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$WingetId,
        [string]$ChocoId,
        [Parameter(Mandatory)][string]$ManualUrl
    )
    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Log "[ok] $Command present"
        return
    }
    Log "Installing $Command..."
    if ($WingetId -and (Install-Via-Winget $WingetId)) { return }
    if ($ChocoId  -and (Install-Via-Choco  $ChocoId )) { return }
    Die "Could not install $Command. Neither winget nor choco is available (or the package is unavailable). Install manually: $ManualUrl"
}

Ensure-Tool -Command git   -WingetId 'Git.Git'            -ChocoId 'git'        -ManualUrl 'https://git-scm.com/download/win'
Ensure-Tool -Command node  -WingetId 'OpenJS.NodeJS.LTS'  -ChocoId 'nodejs-lts' -ManualUrl 'https://nodejs.org/en/download'
Ensure-Tool -Command jq    -WingetId 'jqlang.jq'          -ChocoId 'jq'         -ManualUrl 'https://jqlang.github.io/jq/download/'
# rsync is not on winget by default; choco's `rsync` package covers it.
Ensure-Tool -Command rsync -WingetId ''                   -ChocoId 'rsync'      -ManualUrl 'https://community.chocolatey.org/packages/rsync'
if ($Admin) {
    Ensure-Tool -Command gh -WingetId 'GitHub.cli' -ChocoId 'gh' -ManualUrl 'https://cli.github.com/'
}

# -----------------------------------------------------------------------------
# 2) Install Claude Code CLI
# -----------------------------------------------------------------------------
if (Get-Command claude -ErrorAction SilentlyContinue) {
    $ver = (claude --version 2>$null)
    if (-not $ver) { $ver = 'unknown' }
    Log "[ok] claude present ($ver)"
} else {
    Log "Installing Claude Code CLI (npm i -g @anthropic-ai/claude-code)..."
    npm install -g '@anthropic-ai/claude-code'
    Refresh-Path
}

# -----------------------------------------------------------------------------
# 3) Ensure gh auth (admin mode only)
# -----------------------------------------------------------------------------
if ($Admin) {
    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Log "[ok] gh already authenticated"
    } else {
        Log "Launching 'gh auth login' (github.com, HTTPS, web browser)..."
        gh auth login --hostname github.com --git-protocol https --web
    }
}

# -----------------------------------------------------------------------------
# 4) Ensure GITHUB_TOKEN export in $PROFILE (additive, idempotent via marker)
# -----------------------------------------------------------------------------
$profilePath = $PROFILE
$profileDir  = Split-Path -Parent $profilePath
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Path $profilePath -Force | Out-Null }

$profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
if (-not $profileContent) { $profileContent = '' }

$tokenMarker = '# Palisades-Labs claude-harness-installer: GITHUB_TOKEN'
if ($profileContent.Contains($tokenMarker)) {
    Log "[ok] GITHUB_TOKEN export already present in $profilePath"
} else {
    Log "Adding GITHUB_TOKEN export to $profilePath"
    if ($Admin) {
        # Admin: derive from gh auth at shell-startup time. Mirrors the bash
        # admin flow; safe on admin's own machine.
        $tokenLine = '$env:GITHUB_TOKEN = (gh auth token 2>$null)'
    } else {
        # Employee: bake the pre-set token literal. Escape single quotes
        # defensively even though GitHub PATs don't contain them.
        $escaped = $env:GITHUB_TOKEN.Replace("'", "''")
        $tokenLine = "`$env:GITHUB_TOKEN = '$escaped'"
    }
    Add-Content -Path $profilePath -Value "`n$tokenMarker`n$tokenLine"
}

# -----------------------------------------------------------------------------
# 4b) Ensure TAVILY_API_KEY export in $PROFILE (admin mode only)
# -----------------------------------------------------------------------------
if ($Admin) {
    $tavilyMarker = '# Palisades-Labs claude-harness-installer: TAVILY_API_KEY'
    $profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if ($profileContent -and $profileContent.Contains($tavilyMarker)) {
        Log "[ok] TAVILY_API_KEY export already present in $profilePath"
    } else {
        $tavilyKey = Read-Host "Enter your Tavily API key (get one at https://tavily.com, press Enter to skip)"
        if ($tavilyKey) {
            Log "Adding TAVILY_API_KEY export to $profilePath"
            $escaped = $tavilyKey.Replace("'", "''")
            Add-Content -Path $profilePath -Value "`n$tavilyMarker`n`$env:TAVILY_API_KEY = '$escaped'"
        } else {
            Warn "Skipped TAVILY_API_KEY. Tavily tools will fail until you set it."
            Warn "  Add this line to $profilePath later: `$env:TAVILY_API_KEY = '<your-key>'"
        }
    }
}

# -----------------------------------------------------------------------------
# 5) Additive merge into %USERPROFILE%\.claude\settings.json
# -----------------------------------------------------------------------------
$settingsDir  = Join-Path $HOME '.claude'
$settingsPath = Join-Path $settingsDir 'settings.json'
if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }
if (-not (Test-Path $settingsPath)) { '{}' | Set-Content -Path $settingsPath -NoNewline; Log "Created empty $settingsPath" }

try {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
} catch {
    Die "$settingsPath is not valid JSON. Refusing to modify. Fix it first, then re-run."
}

# Snapshot current JSON for idempotent-rerun signal.
$beforeJson = ($settings | ConvertTo-Json -Depth 100 -Compress)

# Ensure extraKnownMarketplaces object exists.
if (-not $settings.PSObject.Properties['extraKnownMarketplaces']) {
    $settings | Add-Member -NotePropertyName extraKnownMarketplaces -NotePropertyValue ([pscustomobject]@{}) -Force
}
$mpSource = [pscustomobject]@{ source = [pscustomobject]@{ source = 'github'; repo = $ClientRepo } }
$settings.extraKnownMarketplaces | Add-Member -NotePropertyName $MarketplaceName -NotePropertyValue $mpSource -Force

# Ensure enabledPlugins object exists.
if (-not $settings.PSObject.Properties['enabledPlugins']) {
    $settings | Add-Member -NotePropertyName enabledPlugins -NotePropertyValue ([pscustomobject]@{}) -Force
}
$settings.enabledPlugins | Add-Member -NotePropertyName "base@$MarketplaceName"              -NotePropertyValue $true -Force
$settings.enabledPlugins | Add-Member -NotePropertyName "$MarketplaceName@$MarketplaceName"  -NotePropertyValue $true -Force

$afterJson = ($settings | ConvertTo-Json -Depth 100 -Compress)
if ($beforeJson -eq $afterJson) {
    Log "[ok] settings.json already has the right marketplace + plugins"
} else {
    ($settings | ConvertTo-Json -Depth 100) | Set-Content -Path $settingsPath
    Log "[ok] settings.json updated (additive merge)"
}

# -----------------------------------------------------------------------------
# 6) Done
# -----------------------------------------------------------------------------
Write-Host ''
Log "Bootstrap complete."
Write-Host ''
Write-Host "Next steps:"
Write-Host "  1. Open a NEW PowerShell window so `$env:GITHUB_TOKEN gets picked up."
Write-Host "  2. Run: claude"
Write-Host "  3. Inside Claude, check: /plugin list"
if ($Admin) {
    Write-Host "  4. Inside Claude, run /generate-installer to produce your team's install command."
}
Write-Host ''

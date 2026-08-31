# Sync-Core.ps1 -- keep the shared core/ engine identical across vaults.
#
# core/ holds everything that is true regardless of which vault you are in:
#   - identity-core.md : durable voice, honesty labels, workflow preferences
#   - engine.md        : the domain-neutral q-alias / handoff / lesson protocol
#   - scripts/         : the vault-agnostic engine scripts
#
# Exactly one vault is canonical (`core_canonical: true` in its
# vault.config.json). Every other vault pulls core/ from it. This is what stops
# the two vaults from drifting once you fix a bug in one of them.
#
# Usage:
#   Sync-Core.ps1                      # pull canonical core into this vault
#   Sync-Core.ps1 -CheckOnly           # report drift only; exit 2 if different
#   Sync-Core.ps1 -To <vaultRoot>      # push this vault's core into another vault
#   Sync-Core.ps1 -AllowFetch          # permit the git fallback during -CheckOnly
#   Sync-Core.ps1 -WhatIf              # show what would change
#
# Resolving the canonical source, in order:
#   1. core_source_path  -- a sibling vault root on this machine (fastest)
#   2. core_source_repo  -- "<owner>/<repo>", fetched over git when the local
#      path is absent. This is what makes canonical a property of the REPO
#      rather than of whichever machine happens to have the other vault cloned.
#      Only core/ is materialized (sparse checkout), so a work vault's customer
#      content never lands on a personal machine, and vice versa.
#
# The git fallback is deliberately SKIPPED during -CheckOnly unless -AllowFetch
# is passed, because Test-VaultHealth.ps1 runs -CheckOnly on every session
# start. Session start must stay fast and must work offline.
#
# Exit codes: 0 = in sync or synced, 1 = error, 2 = drift found (-CheckOnly).

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$VaultRoot,
    [string]$To,
    [switch]$CheckOnly,
    [switch]$AllowFetch,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_VaultCommon.ps1')

$dot = Get-VaultRoot -VaultRoot $VaultRoot
$cfg = Get-VaultConfig -Root $dot

function Say($msg, $color = 'Gray') { if (-not $Quiet) { Write-Host $msg -ForegroundColor $color } }

function Get-CoreFingerprint([string]$coreDir) {
    if (-not (Test-Path $coreDir)) { return @{} }
    $map = @{}
    foreach ($f in Get-ChildItem -Path $coreDir -Recurse -File) {
        $rel = $f.FullName.Substring($coreDir.Length).TrimStart('\')
        $map[$rel] = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash
    }
    return $map
}

function Compare-Core([hashtable]$src, [hashtable]$dst) {
    $diffs = @()
    foreach ($k in $src.Keys) {
        if (-not $dst.ContainsKey($k)) { $diffs += "ADD    $k" }
        elseif ($dst[$k] -ne $src[$k]) { $diffs += "UPDATE $k" }
    }
    foreach ($k in $dst.Keys) {
        if (-not $src.ContainsKey($k)) { $diffs += "EXTRA  $k (only in target)" }
    }
    return $diffs
}

function Copy-Core([string]$srcCore, [string]$dstCore) {
    New-Item -ItemType Directory -Force -Path $dstCore | Out-Null
    foreach ($f in Get-ChildItem -Path $srcCore -Recurse -File) {
        $rel    = $f.FullName.Substring($srcCore.Length).TrimStart('\')
        $target = Join-Path $dstCore $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        Copy-Item -Force -LiteralPath $f.FullName -Destination $target
    }
}

function Get-CoreFromGit {
    <#
      Shallow, sparse fetch of just core/ from the canonical repo into a temp
      directory. Returns the temp clone path, or $null on failure.

      Auth: the repo is private, so a token for the vault's pinned gh account is
      exported as GH_TOKEN for the duration of the clone. It is never embedded
      in a command string, so it cannot leak into logs or transcripts.
    #>
    param([Parameter(Mandatory)][string]$Slug, [string]$Ref = 'main', [string]$GhUser)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Say "X git not found; cannot fetch core from $Slug" 'Red'; return $null
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('vault-core-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $oldToken = $env:GH_TOKEN
    try {
        if ($GhUser -and (Get-Command gh -ErrorAction SilentlyContinue)) {
            $tok = & gh auth token --user $GhUser 2>$null
            if ($tok) { $env:GH_TOKEN = $tok }
        }
        Say "Fetching core/ from $Slug ($Ref)..." 'Cyan'
        $out = & git clone --depth 1 --branch $Ref --filter=blob:none --sparse "https://github.com/$Slug.git" $tmp 2>&1
        if ($LASTEXITCODE -ne 0) {
            Say "X Could not clone $Slug : $out" 'Red'
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            return $null
        }
        # Materialize ONLY core/, so the other vault's domain content never lands here.
        & git -C $tmp sparse-checkout set core 2>&1 | Out-Null
        if (-not (Test-Path (Join-Path $tmp 'core'))) {
            Say "X $Slug has no core/ directory" 'Red'
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            return $null
        }
        return $tmp
    } catch {
        Say "X Fetch failed: $_" 'Red'
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    } finally {
        $env:GH_TOKEN = $oldToken
    }
}

# ---------------------------------------------------------------- push mode
if ($To) {
    $srcCore = Join-Path $dot 'core'
    $dstRoot = $To.TrimEnd('\')
    $dstCore = Join-Path $dstRoot 'core'

    if (-not (Test-Path $srcCore)) { Write-Host "X No core/ in $dot" -ForegroundColor Red; exit 1 }
    if (-not (Test-Path $dstRoot)) { Write-Host "X Target vault not found: $dstRoot" -ForegroundColor Red; exit 1 }

    $diffs = Compare-Core (Get-CoreFingerprint $srcCore) (Get-CoreFingerprint $dstCore)
    if ($diffs.Count -eq 0) { Say "OK core/ already identical in $dstRoot" 'Green'; exit 0 }

    Say "core/ changes to apply to $dstRoot :" 'Cyan'
    $diffs | ForEach-Object { Say "  $_" }
    if ($CheckOnly) { exit 2 }

    if ($PSCmdlet.ShouldProcess($dstRoot, "copy core/ from $dot")) {
        Copy-Core $srcCore $dstCore
        Say "OK core/ pushed into $dstRoot" 'Green'
        Say "Reminder: the target .gitignore is an allowlist. It needs these lines:" 'Yellow'
        Say '  !core/' 'Yellow'
        Say '  !core/**' 'Yellow'
        Say '  !vault.config.json' 'Yellow'
    }
    exit 0
}

# ---------------------------------------------------------------- pull mode
if ($cfg.core_canonical) {
    Say "This vault [$($cfg.name)] is the canonical core source. Nothing to pull." 'Green'
    Say "To distribute: Sync-Core.ps1 -To <otherVaultRoot>"
    exit 0
}

$srcCore   = $null
$srcLabel  = $null
$tempClone = $null

# 1. Local canonical vault on this machine.
if ($cfg.PSObject.Properties.Name -contains 'core_source_path' -and $cfg.core_source_path) {
    $p = [Environment]::ExpandEnvironmentVariables($cfg.core_source_path).TrimEnd('\')
    if (Test-Path (Join-Path $p 'core')) {
        $srcCore  = Join-Path $p 'core'
        $srcLabel = $p
    }
}

# 2. Git fallback: canonical is a repo, not a machine. Skipped during -CheckOnly
#    unless -AllowFetch, because the health check runs -CheckOnly every session
#    start and must stay fast and offline-safe.
if (-not $srcCore -and $cfg.PSObject.Properties.Name -contains 'core_source_repo' -and $cfg.core_source_repo) {
    if ($CheckOnly -and -not $AllowFetch) {
        Say "Canonical vault not on this machine; skipping the git check (use -AllowFetch to force)." 'Yellow'
        exit 0
    }
    $ref = 'main'
    if ($cfg.PSObject.Properties.Name -contains 'core_source_ref' -and $cfg.core_source_ref) { $ref = $cfg.core_source_ref }
    $tempClone = Get-CoreFromGit -Slug $cfg.core_source_repo -Ref $ref -GhUser $cfg.gh_user
    if (-not $tempClone) { exit 1 }
    $srcCore  = Join-Path $tempClone 'core'
    $srcLabel = "$($cfg.core_source_repo)@$ref"
}

if (-not $srcCore) {
    Say "No canonical core source available (set core_source_path or core_source_repo in $dot\vault.config.json)." 'Yellow'
    exit 0
}

try {
    $dstCore = Join-Path $dot 'core'
    $diffs   = Compare-Core (Get-CoreFingerprint $srcCore) (Get-CoreFingerprint $dstCore)

    if ($diffs.Count -eq 0) { Say "OK core/ in sync with $srcLabel" 'Green'; exit 0 }

    Say "core/ drift vs canonical ($srcLabel):" 'Yellow'
    $diffs | ForEach-Object { Say "  $_" }
    if ($CheckOnly) { exit 2 }

    if ($PSCmdlet.ShouldProcess($dot, "pull core/ from $srcLabel")) {
        Copy-Core $srcCore $dstCore
        Say "OK core/ pulled from $srcLabel" 'Green'
    }
    exit 0
} finally {
    if ($tempClone) { Remove-Item $tempClone -Recurse -Force -ErrorAction SilentlyContinue }
}

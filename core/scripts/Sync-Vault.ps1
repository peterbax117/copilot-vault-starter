# Sync-Vault.ps1 (core) -- auto-commit + push a vault if dirty, then mirror.
#
# Vault-agnostic port of the original ms-copilot-vault sync script. The vault
# root and every per-vault setting (remote, gh account, mirror target, task
# name) come from <root>\vault.config.json via _VaultCommon.ps1.
#
# The vault root is itself the git working tree. Its .gitignore is an allowlist
# (`*` then `!` exceptions), so only curated files are ever committed.
#
# Safe to run frequently (scheduled task every 15 min). Writes structured state
# to m-vault-sync-state.json so Test-VaultHealth.ps1 can surface failures at
# session start.
#
# ASCII-only on purpose: may run under Windows PowerShell 5.1 or a task.

[CmdletBinding()]
param(
    [string]$VaultRoot,
    [switch]$Quiet,
    [switch]$NoPush,
    [switch]$NoMirror
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_VaultCommon.ps1')

$dot       = Get-VaultRoot -VaultRoot $VaultRoot
$cfg       = Get-VaultConfig -Root $dot
$mirror    = $cfg.mirror_path
$logDir    = "$dot\m-vault-logs"
$stateFile = "$dot\m-vault-sync-state.json"
$sentinel  = "$dot\VAULT-SYNC-PROBLEM.txt"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = "$logDir\sync-$(Get-Date -Format 'yyyyMM').log"

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $log -Value $line
    if (-not $Quiet) { Write-Host $line }
}

function Read-State {
    if (Test-Path $stateFile) {
        try { return (Get-Content $stateFile -Raw | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{
        last_run             = $null
        last_success         = $null
        consecutive_failures = 0
        last_error           = $null
        ahead_of_origin      = 0
    }
}

function Write-State($state) {
    $state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
}

function Invoke-VaultPush {
    param([int]$MaxAttempts = 2, [int]$BackoffSeconds = 5)

    # A specific gh account can be pinned per vault. Without it, fall back to
    # whatever credential helper git already has configured.
    $useHelper = $false
    $helper    = ''
    if ($cfg.gh_user) {
        $token = & gh auth token --user $cfg.gh_user 2>$null
        if (-not $token) {
            return @{ ok = $false; error = "no $($cfg.gh_user) token (run: gh auth login --user $($cfg.gh_user))" }
        }
        # Inline credential helper feeds the pinned account's token to raw git as
        # the password. Clear the account-scoped 'manager' helper first so gh's
        # active account cannot shadow it. The token is never logged.
        $helper    = "!f() { echo username=x-access-token; echo password=$token; }; f"
        $useHelper = $true
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($useHelper) {
            $pushOut = git -c "credential.helper=" -c "credential.helper=$helper" push 2>&1
        } else {
            $pushOut = git push 2>&1
        }

        if ($LASTEXITCODE -eq 0) {
            # Do not trust the exit code alone: verify nothing is still ahead.
            $stillAhead = 0
            try { $stillAhead = [int](git rev-list --count '@{u}..HEAD' 2>$null) } catch { $stillAhead = 0 }
            if ($stillAhead -eq 0) {
                return @{ ok = $true; attempts = $attempt }
            }
            Write-Log "PUSH attempt $attempt/$MaxAttempts exited 0 but $stillAhead commit(s) still ahead"
            $pushOut = "push exited 0 but $stillAhead commit(s) still ahead of origin"
        } else {
            Write-Log "PUSH attempt $attempt/$MaxAttempts failed: $pushOut"
        }
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $BackoffSeconds }
    }
    return @{ ok = $false; error = "push failed after $MaxAttempts attempts: $pushOut" }
}

function Update-Sentinel {
    param($state)
    if ($state.consecutive_failures -ge 3) {
        $body = @"
Vault sync has failed $($state.consecutive_failures) times in a row.
Vault:         $dot
Last attempt:  $($state.last_run)
Last success:  $($state.last_success)
Ahead by:      $($state.ahead_of_origin) commits
Last error:    $($state.last_error)

To investigate:
  & "$dot\core\scripts\Sync-Vault.ps1"
  & "$dot\core\scripts\Test-VaultHealth.ps1"
"@
        Set-Content -Path $sentinel -Value $body -Encoding UTF8
    } else {
        Remove-Item $sentinel -ErrorAction SilentlyContinue
    }
}

Set-Location $dot
$state = Read-State
$state.last_run = (Get-Date).ToString('o')
$runError = $null

try {
    $status = git status --porcelain 2>$null

    if ($status) {
        Write-Log "Changes detected, committing"
        git add -A 2>&1 | Out-Null
        $msg = "auto: vault sync $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        git commit -m $msg 2>&1 | Out-Null
        Write-Log "Committed: $msg"
    } else {
        Write-Log "No changes"
    }

    # Always check ahead-of-origin (covers cases where prior pushes failed).
    $ahead = 0
    try { $ahead = [int](git rev-list --count '@{u}..HEAD' 2>$null) } catch { $ahead = 0 }
    $state.ahead_of_origin = $ahead

    if ($ahead -gt 0 -and -not $NoPush) {
        Write-Log "Local is $ahead commits ahead of origin; attempting push"
        $push = Invoke-VaultPush
        if ($push.ok) {
            Write-Log "Pushed to origin (attempts: $($push.attempts))"
            $state.ahead_of_origin = 0
        } else {
            $runError = $push.error
            Write-Log "PUSH FAILED: $runError"
        }
    }

    if (-not $NoMirror -and $mirror) {
        New-Item -ItemType Directory -Force -Path $mirror | Out-Null
        foreach ($f in $cfg.mirror_files) {
            $src = Join-Path $dot $f
            if (Test-Path $src) { Copy-Item -Force $src (Join-Path $mirror (Split-Path $f -Leaf)) }
        }
        foreach ($d in $cfg.mirror_dirs) {
            $src = Join-Path $dot $d
            if (Test-Path $src) { Copy-Item -Force -Recurse $src $mirror }
        }
        Write-Log "Mirrored to: $mirror"
    }
} catch {
    $runError = "$_"
    Write-Log "ERROR: $runError"
}

if ($runError) {
    $state.consecutive_failures = [int]$state.consecutive_failures + 1
    $state.last_error = $runError
} else {
    $state.consecutive_failures = 0
    $state.last_success = $state.last_run
    $state.last_error = $null
}

Write-State $state
Update-Sentinel $state

if ($runError) { exit 1 } else { exit 0 }

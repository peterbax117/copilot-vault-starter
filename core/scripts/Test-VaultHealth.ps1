# Test-VaultHealth.ps1 (core) -- sanity check for session start. Exits 1 on problem.
#
# Vault-agnostic port. The vault root is itself the git working tree (no
# symlinks). Verifies: required files present and non-empty, git repo intact,
# scheduled task alive, sync state shows recent success, no unpushed commits,
# no sentinel, and core not drifted from canonical. Budget overruns are
# advisory so the vault can still load and be repaired in-session.

[CmdletBinding()]
param(
    [string]$VaultRoot,
    [switch]$Fix
)

. (Join-Path $PSScriptRoot '_VaultCommon.ps1')
$dot = Get-VaultRoot -VaultRoot $VaultRoot
$cfg = Get-VaultConfig -Root $dot

$problems  = @()
$stateFile = "$dot\m-vault-sync-state.json"

# Optional per-vault self-heal hook. Anything a specific vault needs to repair
# before the checks run (for example MCP config drift) goes in this script.
# Advisory and non-fatal: it never blocks the health check or changes the exit code.
$repair = "$dot\scripts\Repair-VaultLocal.ps1"
if (Test-Path $repair) {
    try { & $repair -Quiet | Out-Null } catch { }
}

# 1. Working tree is a git repo
if (-not (Test-Path "$dot\.git")) {
    $problems += "Not a git repo: $dot\.git missing"
}

# 2. Required files present and non-empty. Use Get-Content, not Get-Item:
#    Get-Item.Length lies for symlinks and OneDrive placeholders.
foreach ($f in $cfg.required_files) {
    $p = Join-Path $dot $f
    if (-not (Test-Path $p)) { $problems += "Missing: $f"; continue }
    try {
        $chars = (Get-Content $p -Raw -ErrorAction Stop).Length
        if ($chars -lt 100) { $problems += "Suspiciously small ($chars chars): $f" }
    } catch {
        $problems += "Cannot read $f ($_)"
    }
}

# 2b. Archive directory present
if (-not (Test-Path "$dot\archive")) {
    $problems += "Missing: archive/ directory"
}

# 3. Sync state freshness + push health
$stateAhead = 0
if (Test-Path $stateFile) {
    try {
        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($state.last_run) {
            $lastRun = [datetime]::Parse($state.last_run)
            $minSinceRun = (New-TimeSpan -Start $lastRun -End (Get-Date)).TotalMinutes
            if ($minSinceRun -gt 30) {
                $problems += ("Sync stale: last run was {0:N0} min ago (scheduled task may be dead)" -f $minSinceRun)
            }
        } else {
            $problems += "Sync state has no last_run timestamp"
        }
        if ([int]$state.consecutive_failures -ge 1) {
            $problems += "Sync has $($state.consecutive_failures) consecutive failure(s); last error: $($state.last_error)"
        }
        $stateAhead = [int]$state.ahead_of_origin
        if ($stateAhead -gt 0) {
            $problems += "Local is $stateAhead commits ahead of origin (unpushed)"
        }
    } catch {
        $problems += "Cannot parse sync state file: $_"
    }
} else {
    $problems += "Sync state file missing: $stateFile (sync may have never run)"
}

# 3b. Live unpushed-commit check.
#     The state file above is only as fresh as the last Sync-Vault run, so a
#     commit made since then is invisible to it and the vault can report
#     "healthy" while sitting on unpushed work. Ask git directly and only add a
#     problem the cached value did not already cover.
if (Get-Command git -ErrorAction SilentlyContinue) {
    try {
        $aheadRaw = & git -C $dot rev-list --count '@{upstream}..HEAD' 2>$null
        if ($LASTEXITCODE -eq 0 -and $aheadRaw) {
            $liveAhead = [int]("$aheadRaw".Trim())
            if ($liveAhead -gt 0 -and $stateAhead -le 0) {
                $problems += "Local is $liveAhead commit(s) ahead of origin (unpushed; newer than the last sync-state write)"
            }
        }
    } catch { }
}

# 4. Scheduled task alive
# 4. Scheduled task alive.
#    schtasks.exe rather than Get-ScheduledTask: the CIM call costs ~1.1s and was
#    by itself more than half of total session-start time. schtasks returns the
#    same status in ~50ms. Assumes an en-US Windows for the 'Disabled' string;
#    a localized status simply will not match, which fails open rather than
#    blocking session start.
$taskCsv = & schtasks.exe /query /TN $cfg.task_name /FO CSV 2>$null
if ($LASTEXITCODE -ne 0 -or -not $taskCsv) {
    $problems += "Scheduled task '$($cfg.task_name)' not registered"
} else {
    try {
        $status = @($taskCsv | ConvertFrom-Csv)[0].Status
        if ($status -eq 'Disabled') {
            $problems += "Scheduled task '$($cfg.task_name)' is disabled"
        }
    } catch {
        # Unparseable output is not worth blocking a session over.
    }
}

# 5. Sentinel file (set by Sync-Vault.ps1 on persistent failure)
$sentinel = "$dot\VAULT-SYNC-PROBLEM.txt"
if (Test-Path $sentinel) {
    $problems += "Sentinel file present (>=3 consecutive failures): $sentinel"
}

# 6. Budget check (advisory)
$budgetScript = "$dot\core\scripts\Test-VaultBudgets.ps1"
if (Test-Path $budgetScript) {
    & $budgetScript -VaultRoot $dot -Quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "! Vault word budget exceeded. Load the vault, then run core\scripts\Test-VaultBudgets.ps1 and repair it in-session." -ForegroundColor Yellow
    }
}

# 7. Core drift check (advisory). Only meaningful on a non-canonical vault that
#    has a sibling canonical vault available on this machine.
$coreSync = "$dot\core\scripts\Sync-Core.ps1"
if ((Test-Path $coreSync) -and (-not $cfg.core_canonical)) {
    try {
        & $coreSync -VaultRoot $dot -CheckOnly -Quiet | Out-Null
        if ($LASTEXITCODE -eq 2) {
            Write-Host "! core/ differs from the canonical vault. Run core\scripts\Sync-Core.ps1 to reconcile." -ForegroundColor Yellow
        }
    } catch { }
}

if ($problems.Count -eq 0) {
    Write-Host "OK Vault healthy [$($cfg.name)]: required files present and readable; archive/ intact; sync current." -ForegroundColor Green
    exit 0
} else {
    Write-Host "X Vault problems detected [$($cfg.name)]:" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ""
    if ($Fix) {
        $before = @($problems)
        Write-Host "Attempting fixes for $($before.Count) problem(s):" -ForegroundColor Yellow
        $before | ForEach-Object { Write-Host "  -> $_" -ForegroundColor Yellow }
        Write-Host ""

        Write-Host "  [repair] Sync-Vault (commit + push pending vault changes)" -ForegroundColor Yellow
        $syncOut = & "$dot\core\scripts\Sync-Vault.ps1" -VaultRoot $dot 2>&1
        $syncExit = $LASTEXITCODE
        $syncOut | ForEach-Object { Write-Host "           $_" -ForegroundColor DarkGray }
        Write-Host "           Sync-Vault exit code: $syncExit" -ForegroundColor DarkGray
        Write-Host ""

        Write-Host "Re-running health check..." -ForegroundColor Yellow
        & "$dot\core\scripts\Test-VaultHealth.ps1" -VaultRoot $dot
        $afterExit = $LASTEXITCODE
        Write-Host ""

        if ($afterExit -eq 0) {
            Write-Host "OK -Fix resolved all $($before.Count) problem(s):" -ForegroundColor Green
            $before | ForEach-Object { Write-Host "  [resolved] $_" -ForegroundColor Green }
        } else {
            Write-Host "X -Fix did NOT resolve everything. Problems that remain are listed above." -ForegroundColor Red
            Write-Host "  Originally detected:" -ForegroundColor Red
            $before | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
            Write-Host "  Next: & `"$dot\bootstrap.ps1`"" -ForegroundColor Yellow
        }
        exit $afterExit
    } else {
        Write-Host "Recovery options:" -ForegroundColor Yellow
        Write-Host "  - Run sync manually:   & `"$dot\core\scripts\Sync-Vault.ps1`""
        Write-Host "  - Auto-fix attempt:    & `"$dot\core\scripts\Test-VaultHealth.ps1`" -Fix"
        Write-Host "  - Re-bootstrap:        & `"$dot\bootstrap.ps1`""
        exit 1
    }
}

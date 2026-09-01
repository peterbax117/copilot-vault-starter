# Start-Session.ps1 (core) -- the single mandatory session-start command.
#
# Collapses the session-start steps into ONE call:
#   1. run the vault health check (structural/sync failures block; word-budget
#      overruns warn so they can be repaired after the vault loads)
#   2. surface the sync-problem sentinel, due reminders, and handoff sprawl
#   3. print a BOOTSTRAP MANIFEST naming the files the agent must load, so the
#      same mandatory call still declares exactly what must load. The agent then
#      reads each listed file via its own tool call, so every load is
#      INDIVIDUALLY VISIBLE and no single big blob spills to a temp file.
#   4. write an audit marker so a skipped session-start is a detectable event.
#
# Vault-agnostic: works for any vault root with a vault.config.json.
# ASCII-only on purpose: may run under Windows PowerShell 5.1 or a task.

[CmdletBinding()]
param(
    [string]$VaultRoot,
    [switch]$Quiet  # suppress the bootstrap manifest (health check + sentinel only)
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_VaultCommon.ps1')

$dot = Get-VaultRoot -VaultRoot $VaultRoot
$cfg = Get-VaultConfig -Root $dot

# 1. Vault health check. Non-zero structural/sync failures mean STOP.
& "$dot\core\scripts\Test-VaultHealth.ps1" -VaultRoot $dot
$healthExit = $LASTEXITCODE
if ($healthExit -ne 0) {
    Write-Host ""
    Write-Host "SESSION-START BLOCKED: vault health check failed (exit $healthExit)." -ForegroundColor Red
    Write-Host "Report it and run: & `"$dot\core\scripts\Test-VaultHealth.ps1`" -Fix"
    exit $healthExit
}

# Sync-problem sentinel (auto-sync failed >= 3x in a row).
$syncProblem = Join-Path $dot 'VAULT-SYNC-PROBLEM.txt'
if (Test-Path $syncProblem) {
    Write-Host ""
    Write-Host "WARNING: VAULT-SYNC-PROBLEM.txt present -- auto-sync failed >=3x. See qvault." -ForegroundColor Yellow
}

# Durable reminders -- unlike a session-scoped scheduler, this file survives
# across sessions. Check for due rows, surface them, advance next_due.
$remindersPath = Join-Path $dot 'reminders.md'
if (Test-Path $remindersPath) {
    $today = Get-Date -Format 'yyyy-MM-dd'
    $lines = Get-Content $remindersPath
    $dueBlock = @()
    $outLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '^\|\s*([\w-]+)\s*\|\s*([\w:,]+)\s*\|\s*(\d{4}-\d{2}-\d{2})\s*\|\s*(.*?)\s*\|\s*$') {
            $rid = $Matches[1]; $cadence = $Matches[2]; $nextDue = $Matches[3]; $prompt = $Matches[4]
            if ($nextDue -le $today) {
                $dueBlock += "  - [$rid] (was due $nextDue): $prompt"
                # Advance next_due per cadence.
                if ($cadence -match '^monthly:(.+)$') {
                    $days = $Matches[1].Split(',') | ForEach-Object { [int]$_ } | Sort-Object
                    $cursor = (Get-Date).Date
                    $newDue = $null
                    for ($k = 0; $k -lt 62; $k++) {
                        $cursor = $cursor.AddDays(1)
                        if ($days -contains $cursor.Day) { $newDue = $cursor.ToString('yyyy-MM-dd'); break }
                    }
                    if ($newDue) { $line = "| $rid | $cadence | $newDue | $prompt |" }
                } elseif ($cadence -match '^weekly:(\d)$') {
                    $targetDow = [int]$Matches[1]
                    $cursor = (Get-Date).Date
                    for ($k = 0; $k -lt 8; $k++) {
                        $cursor = $cursor.AddDays(1)
                        if ([int]$cursor.DayOfWeek -eq $targetDow) { break }
                    }
                    $line = "| $rid | $cadence | $($cursor.ToString('yyyy-MM-dd')) | $prompt |"
                }
            }
        }
        $outLines.Add($line)
    }
    if ($dueBlock.Count -gt 0) {
        Set-Content -Path $remindersPath -Value $outLines -Encoding utf8
        Write-Host ""
        Write-Host "===== DUE REMINDERS =====" -ForegroundColor Cyan
        $dueBlock | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }
        Write-Host "(next_due advanced in reminders.md; act on these now)" -ForegroundColor Cyan
        Write-Host "===== END DUE REMINDERS ====="
    }
}

# Handoff-sprawl nudge -- OPEN handoffs are meant to be transient. When they
# pile up past the cap, surface a banner suggesting qmerge.
$handoffIndex = Join-Path $dot 'handoffs\index.md'
$openCap = [int]$cfg.open_handoff_cap
if (Test-Path $handoffIndex) {
    $openCount = (Get-Content $handoffIndex | Where-Object { $_ -match '^\|\s*OPEN\s*\|' }).Count
    if ($openCount -gt $openCap) {
        Write-Host ""
        Write-Host "===== HANDOFF SPRAWL =====" -ForegroundColor Yellow
        Write-Host ("  {0} OPEN handoffs (cap {1}). Run qmerge to consolidate finished ones into their project charters." -f $openCount, $openCap) -ForegroundColor Yellow
        Write-Host "===== END HANDOFF SPRAWL ====="
    }
}

# Bootstrap manifest -- declare the required files; the agent reads each one via
# its own tool call, so every load is individually visible.
if (-not $Quiet) {
    Write-Output ""
    Write-Output "===== BOOTSTRAP MANIFEST -- READ EACH FILE BELOW IN FULL NOW ====="
    Write-Output ("  vault: {0}  [{1}]" -f $dot, $cfg.name)
    $i = 0
    foreach ($rel in $cfg.bootstrap_files) {
        $i++
        $f = Join-Path $dot ($rel -replace '/', '\')
        if (Test-Path $f) {
            $bytes = (Get-Item $f).Length
            $words = Get-VaultWordCount -Text (Get-Content $f -Raw)
            Write-Output ("  {0}. {1}  ({2} words, {3:N1} KB)" -f $i, $f, $words, ($bytes / 1KB))
        } else {
            Write-Output ("  {0}. {1}  [MISSING]" -f $i, $f)
        }
    }
    Write-Output "Read all of the above via the view tool (one visible Read each), then post the turn-1 marker."
    Write-Output "===== END MANIFEST ====="
}

# Audit marker: append one JSONL line per session-start + overwrite a "latest"
# pointer, so a skipped start is detectable after the fact.
$now = (Get-Date).ToString('o')
$record = [ordered]@{
    started_at = $now
    vault      = $cfg.name
    root       = $dot
    pid        = $PID
    host       = $env:COMPUTERNAME
    user       = $env:USERNAME
    id         = [guid]::NewGuid().ToString()
}
$json = ($record | ConvertTo-Json -Compress)
Add-Content -Path (Join-Path $dot 'm-session-start.jsonl') -Value $json -Encoding utf8
Set-Content -Path (Join-Path $dot 'm-session-start.json') -Value $json -Encoding utf8

Write-Host ""
Write-Host "session-start OK [$($cfg.name)]: vault healthy, bootstrap loaded, marker written ($now)." -ForegroundColor Green
exit 0

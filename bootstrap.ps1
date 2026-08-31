# bootstrap.ps1 — set up this vault on a machine: initial sync, optional mirror,
# and register the 15-minute auto-sync scheduled task.
#
# Run AFTER you have:
#   1. Created your own private git repo and cloned it into $env:USERPROFILE\.copilot
#      (or wherever $env:COPILOT_HOME points), so the vault root is a git tree.
#   2. Copied vault.config.json.template to vault.config.json and filled it in.
#   3. Written at least a first pass of user.md, memory.md, copilot-instructions.md,
#      and core/identity-core.md.
#
# IMPORTANT: destructive if $VaultRoot\.git already belongs to a DIFFERENT repo.
# Use only on a vault you created for this purpose.

[CmdletBinding()]
param(
    [string]$VaultRoot,
    [switch]$SkipScheduledTask
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'core\scripts\_VaultCommon.ps1')
$dot = Get-VaultRoot -VaultRoot $VaultRoot
$cfg = Get-VaultConfig -Root $dot

Write-Host "Bootstrapping vault '$($cfg.name)' in $dot" -ForegroundColor Cyan

if (-not (Test-Path "$dot\.git")) {
    throw "$dot is not a git working tree. Create your own repo and clone it into $dot first."
}
if (-not (Test-Path "$dot\vault.config.json")) {
    throw "Missing vault.config.json. Copy vault.config.json.template to vault.config.json and fill it in."
}
foreach ($f in $cfg.required_files) {
    if (-not (Test-Path "$dot\$f")) { throw "Missing required file: $f" }
}

# 1. Initial sync (no push) to materialize state + any mirror.
Write-Host "Running initial sync (no push)..." -ForegroundColor Cyan
& "$dot\core\scripts\Sync-Vault.ps1" -VaultRoot $dot -NoPush -Quiet
Write-Host "  sync state initialized" -ForegroundColor Green

# 2. Scheduled task: commit + push + mirror every 15 min, only if dirty.
if (-not $SkipScheduledTask) {
    $taskName = $cfg.task_name
    $vbs      = "$dot\core\scripts\Invoke-VaultSyncHidden.vbs"
    $action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"$dot`""
    $trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 15)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Auto-commit + push $($cfg.name) vault every 15 min if dirty" | Out-Null
    Write-Host "  scheduled task '$taskName' registered (every 15 min)" -ForegroundColor Green
}

# 3. Health check.
Write-Host "Health check:" -ForegroundColor Cyan
& "$dot\core\scripts\Test-VaultHealth.ps1" -VaultRoot $dot

Write-Host ""
Write-Host "Done. Vault is live at $dot." -ForegroundColor Green

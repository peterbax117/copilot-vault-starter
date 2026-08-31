# Resolve-Lessons.ps1 (core) -- move processed / rejected lessons out of the
# pending queue.
#
# Deterministic lifecycle ONLY. The `qlearn` workflow (agent plus human
# approval) decides what each lesson becomes in archive/learned-rules.md; this
# script just files the inbox entry away afterward so it is not reconsidered
# next pass.
#
# Moves the entry to inbox\processed\ (or inbox\rejected\) and flips its
# `status:` field. Those subfolders are gitignored (local audit trail); the
# pending top-level entries ARE tracked so they propagate across machines.
#
# Examples:
#   Resolve-Lessons.ps1 -Id 1a2b3c4d5e6f            # one lesson -> processed
#   Resolve-Lessons.ps1 -Id a1,b2 -Action rejected  # several -> rejected
#   Resolve-Lessons.ps1 -All                        # clear the whole pending queue

[CmdletBinding()]
param(
    [string[]]$Id,
    [switch]$All,
    [ValidateSet('processed','rejected')][string]$Action = 'processed',
    [string]$VaultRoot,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_VaultCommon.ps1')

$dot   = Get-VaultRoot -VaultRoot $VaultRoot
$inbox = Join-Path $dot 'inbox'
if (-not (Test-Path $inbox)) { Write-Host "No inbox." -ForegroundColor Yellow; exit 0 }
if (-not $All -and -not $Id) { Write-Host "Specify -Id <ids> or -All." -ForegroundColor Yellow; exit 1 }

$dest = Join-Path $inbox $Action
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$moved = @()
foreach ($f in Get-ChildItem -Path $inbox -Filter *.md -File -ErrorAction SilentlyContinue) {
    $raw = Get-Content $f.FullName -Raw
    if ($raw -notmatch '(?ms)\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n') { continue }
    $fm = $matches[1]
    if ($fm -notmatch '(?m)^\s*status\s*:\s*pending') { continue }
    $idv = ''
    # [ \t]* rather than \s*: \s matches newlines and would run past the field.
    if ($fm -match '(?m)^[ \t]*id[ \t]*:[ \t]*(.*)$') { $idv = $matches[1].Trim() }

    if ($All -or ($Id -contains $idv)) {
        $new = $raw -replace '(?m)^(\s*status\s*:\s*).*$', "`${1}$Action"
        Set-Content -Path (Join-Path $dest $f.Name) -Value $new -Encoding UTF8
        Remove-Item $f.FullName
        $moved += $idv
    }
}

if (-not $Quiet) {
    if ($moved) { Write-Host "$Action $($moved.Count) lesson(s): $($moved -join ', ')" -ForegroundColor Green }
    else { Write-Host "No matching pending lessons." -ForegroundColor Yellow }
}

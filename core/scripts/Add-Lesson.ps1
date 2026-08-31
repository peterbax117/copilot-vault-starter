# Add-Lesson.ps1 (core) -- append-only capture of a correction / preference /
# observation into the vault inbox, for later single-writer consolidation (the
# `qlearn` workflow).
#
# One file per entry, append-only, so it is safe under concurrent sessions (no
# merge conflicts). Deterministic content-hash id makes it idempotent
# (re-capturing the same lesson is a no-op).
#
# The agent calls this when it is corrected or told a standing preference. It
# does NOT edit any curated file: capture only.
#
# Examples:
#   Add-Lesson.ps1 -Signal explicit_correction `
#     -Context "Drafting an email" -Did "Signed off with the wrong closing" `
#     -Want "Use the user's preferred sign-off"
#   Add-Lesson.ps1 -Signal preference -Want "Prefer HTML for human-read deliverables"

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Want,
    [string]$Context = '',
    [string]$Did = '',
    [ValidateSet('explicit_correction','observation','preference')]
    [string]$Signal = 'explicit_correction',
    [string]$Source = 'cli',
    [string]$Session = '',
    [string]$VaultRoot,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_VaultCommon.ps1')

$dot   = Get-VaultRoot -VaultRoot $VaultRoot
$inbox = Join-Path $dot 'inbox'
New-Item -ItemType Directory -Force -Path $inbox | Out-Null

# Content hash for dedup/idempotency (normalize case + whitespace).
$norm  = (($Want, $Did, $Context) -join '|').ToLower() -replace '\s+', ' '
$md5   = [System.Security.Cryptography.MD5]::Create()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($norm.Trim())
$id    = ([System.BitConverter]::ToString($md5.ComputeHash($bytes)) -replace '-').ToLower().Substring(0, 12)

# Skip if this lesson was already captured (pending or already processed/rejected).
$existing = Get-ChildItem -Path $inbox -Recurse -Filter "*-$id.md" -ErrorAction SilentlyContinue
if ($existing) {
    if (-not $Quiet) { Write-Host "Duplicate lesson ($id) already captured: $($existing[0].Name)" -ForegroundColor Yellow }
    return
}

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$created = (Get-Date).ToString('o')
$file    = Join-Path $inbox "$stamp-$id.md"

$entry = @"
---
id: $id
created_at: $created
source: $Source
session: $Session
signal: $Signal
status: pending
---
context: $Context
did: $Did
want: $Want
"@

Set-Content -Path $file -Value $entry -Encoding UTF8
if (-not $Quiet) { Write-Host "Captured lesson $id -> inbox\$stamp-$id.md" -ForegroundColor Green }


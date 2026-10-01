# Get-PendingLessons.ps1 (core) -- list pending vault inbox lessons.
#
# READ-ONLY. The `qlearn` workflow calls this (with -Json) to load the pending
# queue, then the agent applies the ExpeL ADD/UPDATE/DELETE/UPVOTE/DOWNVOTE
# reasoning over archive/learned-rules.md. This script makes no decisions.

[CmdletBinding()]
param(
    [string]$VaultRoot,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_VaultCommon.ps1')

$dot   = Get-VaultRoot -VaultRoot $VaultRoot
$inbox = Join-Path $dot 'inbox'

function Get-Field([string]$key, [string]$src) {
    # [ \t]* rather than \s*: \s matches newlines, so an empty field would
    # otherwise swallow the value of the following line.
    if ($src -match "(?m)^[ \t]*$key[ \t]*:[ \t]*(.*)$") { return $matches[1].Trim() }
    return ''
}

function Get-LessonBodyFields([string]$src, [string]$fileName) {
    $fields = @{ Context = ''; Did = ''; Want = '' }
    $seen = @{}
    $labels = [regex]::Matches($src, '(?im)^[ \t]*(context|did|want)[ \t]*:[ \t]*')
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $label = $labels[$i]
        $key = $label.Groups[1].Value
        if ($seen.ContainsKey($key)) {
            throw "Duplicate lesson body field '$key' in '$fileName'; the body is ambiguous."
        }
        $seen[$key] = $true
        $start = $label.Index + $label.Length
        $end = if ($i + 1 -lt $labels.Count) { $labels[$i + 1].Index } else { $src.Length }
        $length = $end - $start
        $fields[$key] = $src.Substring($start, $length).Trim()
    }
    return [pscustomobject]$fields
}

$results = @()
if (Test-Path $inbox) {
    foreach ($f in Get-ChildItem -Path $inbox -Filter *.md -File -ErrorAction SilentlyContinue) {
        $raw = Get-Content $f.FullName -Raw
        if ($raw -notmatch '(?ms)\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n(.*)') { continue }
        $fm = $matches[1]; $body = $matches[2]
        if ((Get-Field 'status' $fm) -ne 'pending') { continue }
        $fields = Get-LessonBodyFields $body $f.Name
        $results += [pscustomobject]@{
            Id      = Get-Field 'id' $fm
            Created = Get-Field 'created_at' $fm
            Source  = Get-Field 'source' $fm
            Signal  = Get-Field 'signal' $fm
            Context = $fields.Context
            Did     = $fields.Did
            Want    = $fields.Want
            File    = $f.Name
        }
    }
}

if ($Json) { $results | ConvertTo-Json -Depth 4; exit 0 }
if (-not $results) { Write-Host "No pending lessons." -ForegroundColor Green; exit 0 }
$results | Format-List

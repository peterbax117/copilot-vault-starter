# Test-VaultBudgets.ps1 (core) -- word-budget enforcement for vault markdown.
#
# Reads YAML-ish frontmatter from each .md file in <root>\ and <root>\archive\.
# If a file declares `budget_words: N` (soft) and/or `hard_cap_words: M` (hard),
# its body word count is compared. Body = everything after the closing `---`.
#
# Exit codes:
#   0 = all files within hard cap (some may be over soft budget, WARN only)
#   1 = at least one file exceeds hard cap
#
# Use -Json for machine-readable output. Use -Quiet to print only problems.

[CmdletBinding()]
param(
    [string]$VaultRoot,
    [switch]$Json,
    [switch]$Quiet
)

. (Join-Path $PSScriptRoot '_VaultCommon.ps1')
$dot = Get-VaultRoot -VaultRoot $VaultRoot

$files = @()
$files += Get-ChildItem -Path $dot -Filter *.md -File -ErrorAction SilentlyContinue
$files += Get-ChildItem -Path "$dot\archive" -Filter *.md -File -Recurse -ErrorAction SilentlyContinue
$files += Get-ChildItem -Path "$dot\core" -Filter *.md -File -ErrorAction SilentlyContinue

$results = @()
$anyFail = $false

foreach ($f in $files) {
    $raw = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { continue }

    # Frontmatter must be at file start: ---\n...\n---\n
    if ($raw -notmatch '(?ms)\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n(.*)') { continue }
    $fm   = $matches[1]
    $body = $matches[2]

    if ($fm -notmatch '(?m)^\s*budget_words:\s*(\d+)') { continue }
    $budget = [int]$matches[1]

    $hardCap = if ($fm -match '(?m)^\s*hard_cap_words:\s*(\d+)') { [int]$matches[1] } else { $budget }

    $words = Get-VaultWordCount -Text $body
    $pct   = if ($budget -gt 0) { [math]::Round(($words / $budget) * 100, 0) } else { 0 }

    if ($words -gt $hardCap) {
        $status  = 'FAIL'
        $anyFail = $true
    } elseif ($words -gt $budget) {
        $status = 'WARN'
    } else {
        $status = 'OK'
    }

    $results += [pscustomobject]@{
        File     = $f.FullName.Substring($dot.Length + 1)
        Words    = $words
        Budget   = $budget
        HardCap  = $hardCap
        UsagePct = $pct
        Status   = $status
    }
}

if ($Json) {
    $results | ConvertTo-Json -Depth 3
    if ($anyFail) { exit 1 } else { exit 0 }
}

if (-not $Quiet) {
    if ($results.Count -eq 0) {
        Write-Host "No budgeted files found (no frontmatter with budget_words)." -ForegroundColor Yellow
        exit 0
    }
    $results | Sort-Object @{e='Status';desc=$true}, File | Format-Table -AutoSize
}

$fails = @($results | Where-Object Status -eq 'FAIL')
$warns = @($results | Where-Object Status -eq 'WARN')

if ($fails.Count -gt 0) {
    Write-Host "X $($fails.Count) file(s) exceed hard_cap_words. Compress or demote to archive/." -ForegroundColor Red
    exit 1
}

if ($warns.Count -gt 0) {
    Write-Host "! $($warns.Count) file(s) over soft budget. Consider trimming." -ForegroundColor Yellow
} elseif (-not $Quiet) {
    Write-Host "OK All budgeted files within limits." -ForegroundColor Green
}

exit 0

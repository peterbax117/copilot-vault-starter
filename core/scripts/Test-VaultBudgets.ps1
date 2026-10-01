# Test-VaultBudgets.ps1 (core) -- word-budget enforcement for vault markdown.
#
# Reads YAML-ish frontmatter in root/, archive/ recursively and core/ directly.
# If a file declares `budget_words: N` (soft) and/or `hard_cap_words: M` (hard),
# its body word count is compared. Body = everything after the closing `---`.
#
# Exit codes:
#   0 = no hard failure or assessment error, including no declared budgets
#   1 = at least one file exceeds hard cap
#   2 = invalid declarations or incomplete file scanning (takes precedence)
#
# Use -Json for machine-readable output. Use -Quiet to print only problems.

[CmdletBinding()]
param(
    [string]$VaultRoot,
    [switch]$Json,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_VaultCommon.ps1')
$dot = Get-VaultRoot -VaultRoot $VaultRoot

function New-BudgetError([string]$File, [string]$Message) {
    [pscustomobject]@{
        File = $File; Words = $null; Budget = $null; HardCap = $null
        UsagePct = $null; Status = 'ERROR'; Error = $Message
    }
}

function Measure-Budget([string]$Raw, [string]$File) {
    $header = [regex]::Match($Raw, '(?s)\A---[ \t]*\r?\n(?<header>.*?)(?m:^---[ \t]*(?:\r?\n|\z))(?<body>.*)\z')
    if (-not $header.Success) {
        if ($Raw -match '\A---[ \t]*(?:\r?\n|\z)' -and
            $Raw -match '(?im)^[ \t]*(budget_words|hard_cap_words)(?=[ \t:]|\r?$)') {
            throw 'Budget declaration has no valid closing frontmatter delimiter.'
        }
        return
    }
    $fields = [regex]::Matches($header.Groups['header'].Value,
        '(?im)^[ \t]*(budget_words|hard_cap_words)(?=[ \t:]|\r?$)([^\r\n]*)\r?$')
    $limits = @{}
    foreach ($field in $fields) {
        $key = $field.Groups[1].Value.ToLowerInvariant()
        if ($limits.ContainsKey($key)) { throw "Duplicate declaration: $key" }
        $number = [regex]::Match($field.Groups[2].Value, '^[ \t]*:[ \t]*([0-9]+)(?:[ \t]+#.*)?[ \t]*$')
        $value = 0
        if (-not $number.Success -or -not [int]::TryParse($number.Groups[1].Value, [ref]$value)) {
            throw "Invalid $key; expected a nonnegative integer no greater than 2147483647."
        }
        $limits[$key] = $value
    }
    $hasBudget = $limits.ContainsKey('budget_words')
    $hasHardCap = $limits.ContainsKey('hard_cap_words')
    if (-not $hasBudget -and -not $hasHardCap) { return }
    $budget = if ($hasBudget) { $limits['budget_words'] } else { $null }
    $hardCap = if ($hasHardCap) { $limits['hard_cap_words'] } else { $budget }
    if ($hasBudget -and $hardCap -lt $budget) { throw 'hard_cap_words cannot be below budget_words.' }
    $body = $header.Groups['body'].Value
    $words = if ([string]::IsNullOrEmpty($body)) { 0 } else { Get-VaultWordCount -Text $body }
    $pct = if (-not $hasBudget) { $null } elseif ($budget -gt 0) {
        [math]::Round(($words / $budget) * 100, 0)
    } else { 0 }
    if ($words -gt $hardCap) {
        $status = 'FAIL'
    } elseif ($hasBudget -and $words -gt $budget) {
        $status = 'WARN'
    } else {
        $status = 'OK'
    }
    [pscustomobject]@{
        File = $File; Words = $words; Budget = $budget; HardCap = $hardCap
        UsagePct = $pct; Status = $status
    }
}

$files = @()
$results = @()
foreach ($folder in @('', 'archive', 'core')) {
    $path = if ($folder) { Join-Path $dot $folder } else { $dot }
    try {
        if ($folder -and -not (Test-Path -LiteralPath $path -ErrorAction Stop)) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Container -ErrorAction Stop)) {
            throw 'Expected a directory.'
        }
        $files += Get-ChildItem -LiteralPath $path -Filter *.md -File -Force `
            -Recurse:($folder -eq 'archive') -ErrorAction Stop
    } catch {
        $results += New-BudgetError $path "Cannot enumerate Markdown files: $_"
    }
}
foreach ($f in $files) {
    $relative = $f.FullName.Substring($dot.Length + 1)
    try {
        $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        $row = Measure-Budget -Raw $raw -File $relative
        if ($null -ne $row) { $results += $row }
    } catch {
        $results += New-BudgetError $relative "$_"
    }
}

$errors = @($results | Where-Object Status -eq 'ERROR')
$fails = @($results | Where-Object Status -eq 'FAIL')
$warns = @($results | Where-Object Status -eq 'WARN')
$exitCode = if ($errors.Count -gt 0) { 2 } elseif ($fails.Count -gt 0) { 1 } else { 0 }

if ($Json) {
    if ($results.Count -eq 0) { Write-Output '[]' } else { $results | ConvertTo-Json -Depth 3 }
    exit $exitCode
}

if (-not $Quiet) {
    if ($results.Count -eq 0) {
        Write-Host "No budget declarations found; no budgets were evaluated." -ForegroundColor Yellow
        exit 0
    }
    $results | Sort-Object @{e='Status';desc=$true}, File | Format-Table -AutoSize
}

$errors | ForEach-Object { Write-Host "X Cannot check '$($_.File)': $($_.Error)" -ForegroundColor Red }

if ($fails.Count -gt 0) {
    Write-Host "X $($fails.Count) file(s) exceed hard_cap_words. Compress or demote to archive/." -ForegroundColor Red
}

if ($warns.Count -gt 0) {
    Write-Host "! $($warns.Count) file(s) over soft budget. Consider trimming." -ForegroundColor Yellow
} elseif (-not $Quiet -and $exitCode -eq 0) {
    Write-Host "OK All budgeted files within limits." -ForegroundColor Green
}

exit $exitCode

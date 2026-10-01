# Sync-Vault.ps1 (core) -- auto-commit + push a vault if dirty, then mirror.
#
# Vault-agnostic port of the original ms-copilot-vault sync script. The vault
# root and every per-vault setting (remote, gh account, mirror target, task
# name) come from <root>\vault.config.json via _VaultCommon.ps1.
#
# Only eligible memory changes may be auto-published. Runtime and governance
# changes require a PR and approved activation from the remote sync branch.
#
# Safe to run frequently (scheduled task every 15 min). Writes structured state
# to m-vault-sync-state.json so Test-VaultHealth.ps1 can surface failures at
# session start.

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
        try { return (Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json) } catch {
            throw "Sync state read failed: $_"
        }
    }
    return [pscustomobject]@{
        last_run             = $null
        last_success         = $null
        consecutive_failures = 0
        last_error           = $null
        last_failure_stage   = $null
        ahead_of_origin      = 0
    }
}

function Write-State($state) {
    $state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
}

function Invoke-VaultGit {
    param([string[]]$Arguments, [string]$Operation, [switch]$AllowFailure)

    $previousPreference = $ErrorActionPreference
    try {
        # PS5 treats native stderr as an error even when git exits successfully.
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $dot @Arguments 2>&1)
        $gitExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $text = $output -join "`n"
    if ($gitExit -ne 0 -and -not $AllowFailure) {
        throw "Git $Operation failed (exit $gitExit): $text"
    }
    # Parsed output must be stdout only: git writes warnings (for example
    # LF/CRLF notices) to stderr, and mixing them in corrupts -z path lists (#34).
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
    return [pscustomobject]@{ ExitCode = $gitExit; Output = $stdout; Stderr = $stderr; Text = $text }
}

function Test-VaultPublicationGuard {
    # On unless the setting is the JSON boolean false. No working-tree value may
    # choose which config is trusted: once the repo has any remote-tracking ref
    # or an upstream, only the config published on HEAD's real upstream counts,
    # and anything unreadable keeps the guard on. Only a vault that has never
    # fetched or pushed (starter bootstrap) uses its working-tree config.
    $upstream = Invoke-VaultGit -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}') -Operation 'upstream inspection' -AllowFailure
    $remoteRefs = Invoke-VaultGit -Arguments @('for-each-ref', '--count=1', '--format=%(refname)', 'refs/remotes') -Operation 'remote ref inspection' -AllowFailure
    if ($remoteRefs.ExitCode -ne 0) { return $true }
    if ($upstream.ExitCode -ne 0 -and -not $remoteRefs.Output.Trim()) {
        $value = $cfg.memory_publication_guard
    } elseif ($upstream.ExitCode -eq 0) {
        # Trust only origin/<current branch>; anything else keeps the guard on.
        $branch = Invoke-VaultGit -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD') -Operation 'branch inspection' -AllowFailure
        if ($branch.ExitCode -ne 0) { return $true }
        $expected = "refs/remotes/origin/$($branch.Output.Trim())"
        $upstreamFull = Invoke-VaultGit -Arguments @('rev-parse', '--symbolic-full-name', '@{upstream}') -Operation 'upstream inspection' -AllowFailure
        if ($upstreamFull.ExitCode -ne 0 -or $upstreamFull.Output.Trim() -cne $expected) { return $true }
        $shown = Invoke-VaultGit -Arguments @('show', "${expected}:vault.config.json") -Operation 'published config inspection' -AllowFailure
        if ($shown.ExitCode -ne 0) { return $true }
        try { $published = $shown.Output | ConvertFrom-Json -ErrorAction Stop } catch { return $true }
        $value = $published.memory_publication_guard
    } else {
        return $true
    }
    return -not (($value -is [bool]) -and (-not $value))
}

function Assert-VaultMemoryPublication {
    if (-not (Test-VaultPublicationGuard)) { return }
    $branch = (Invoke-VaultGit -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD') -Operation 'branch inspection').Output.Trim()
    if ($branch -cne $cfg.sync_branch) {
        throw "Auto-sync requires branch '$($cfg.sync_branch)', not '$branch'. Use an issue-linked PR for development."
    }
    $upstream = (Invoke-VaultGit -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}') -Operation 'upstream inspection').Output.Trim()
    if ($upstream -cne "origin/$($cfg.sync_branch)") {
        throw "Auto-sync requires upstream 'origin/$($cfg.sync_branch)', not '$upstream'."
    }
    $dirty = (Invoke-VaultGit -Arguments @('diff', '--name-only', '--no-renames', '-z', 'HEAD', '--') -Operation 'working-tree inspection').Output
    $staged = (Invoke-VaultGit -Arguments @('diff', '--cached', '--name-only', '--no-renames', '-z', '--') -Operation 'index inspection').Output
    $untracked = (Invoke-VaultGit -Arguments @('ls-files', '--others', '--exclude-standard', '-z') -Operation 'untracked-file inspection').Output
    # Inspect every local commit, not just its net diff: a revert still publishes history.
    $committed = (Invoke-VaultGit -Arguments @('log', '--format=', '--name-only', '--no-renames', '-z', '-m', '@{upstream}..HEAD', '--') -Operation 'pending-history inspection').Output
    $blocked = @(
        "$dirty`0$staged`0$untracked`0$committed".Split([char]0) |
            ForEach-Object { $_.Trim([char[]]"`r`n") } |
            Where-Object {
                $_ -and $_ -notmatch '^(?:(?:user|memory)\.md|(?:archive|projects|handoffs|inbox)/[^/]+\.md)$'
            } |
            Sort-Object -Unique
    )
    if ($blocked.Count -gt 0) {
        throw "Runtime/governance changes require an issue-linked PR and approved activation: $($blocked -join '; ')"
    }
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
            $pushResult = Invoke-VaultGit -Arguments @('-c', 'credential.helper=', '-c', "credential.helper=$helper", 'push') -Operation 'push' -AllowFailure
        } else {
            $pushResult = Invoke-VaultGit -Arguments @('push') -Operation 'push' -AllowFailure
        }
        $pushOut = $pushResult.Text

        if ($pushResult.ExitCode -eq 0) {
            # Do not trust the exit code alone: verify nothing is still ahead.
            $stillAhead = [int](Invoke-VaultGit -Arguments @('rev-list', '--count', '@{upstream}..HEAD') -Operation 'post-push inspection').Output
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
$state = [pscustomobject]@{
    last_run = $null; last_success = $null; consecutive_failures = 0
    last_error = $null; last_failure_stage = $null; ahead_of_origin = 0
}
$activeStage = 'state-read'
$failureStage = $null
$runError = $null
try {
    $state = Read-State
} catch {
    $runError = "$_"
}
if (-not ($state.PSObject.Properties.Name -contains 'last_failure_stage')) {
    $state | Add-Member -NotePropertyName last_failure_stage -NotePropertyValue $null
}
$state.last_run = (Get-Date).ToString('o')

try {
    if ($runError) { throw $runError }
    $activeStage = 'publication-policy'
    Assert-VaultMemoryPublication
    $activeStage = 'git-status'
    $status = (Invoke-VaultGit -Arguments @('status', '--porcelain') -Operation 'status').Output

    if ($status) {
        Write-Log "Changes detected, committing"
        $activeStage = 'git-staging'
        Invoke-VaultGit -Arguments @('add', '-A') -Operation 'staging' | Out-Null
        $activeStage = 'publication-policy'
        Assert-VaultMemoryPublication
        $msg = "auto: vault sync $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        $activeStage = 'git-commit'
        Invoke-VaultGit -Arguments @('commit', '-m', $msg) -Operation 'commit' | Out-Null
        Write-Log "Committed: $msg"
    } else {
        Write-Log "No changes"
    }

    # Always check ahead-of-origin (covers cases where prior pushes failed).
    $activeStage = 'publication-policy'
    Assert-VaultMemoryPublication
    $activeStage = 'git-upstream'
    $noUpstream = (-not (Test-VaultPublicationGuard)) -and
        ((Invoke-VaultGit -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}') -Operation 'upstream inspection' -AllowFailure).ExitCode -ne 0)
    if ($noUpstream) {
        # Unguarded fresh vault (starter bootstrap) before its first push.
        Write-Log "No upstream configured yet; skipping push. Publish once with: git push -u origin HEAD"
        $ahead = 0
    } else {
        $ahead = [int](Invoke-VaultGit -Arguments @('rev-list', '--count', '@{upstream}..HEAD') -Operation 'pending-commit inspection').Output
    }
    $state.ahead_of_origin = $ahead

    if ($ahead -gt 0 -and -not $NoPush) {
        $activeStage = 'git-push'
        Write-Log "Local is $ahead commits ahead of origin; attempting push"
        $push = Invoke-VaultPush
        if ($push.ok) {
            Write-Log "Pushed to origin (attempts: $($push.attempts))"
            $state.ahead_of_origin = 0
        } else {
            $runError = $push.error
            $failureStage = 'git-push'
            Write-Log "PUSH FAILED: $runError"
        }
    }

    if (-not $NoMirror -and $mirror) {
        $activeStage = 'publication-policy'
        Assert-VaultMemoryPublication
        $activeStage = 'mirror'
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
    if (-not $failureStage) { $failureStage = $activeStage }
    Write-Log "ERROR: $runError"
}

if ($runError) {
    $state.consecutive_failures = [int]$state.consecutive_failures + 1
    $state.last_error = $runError
    $state.last_failure_stage = $failureStage
} else {
    $state.consecutive_failures = 0
    $state.last_success = $state.last_run
    $state.last_error = $null
    $state.last_failure_stage = $null
}

Write-State $state
Update-Sentinel $state

if ($runError) { exit 1 } else { exit 0 }

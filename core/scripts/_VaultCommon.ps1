# _VaultCommon.ps1 -- shared helpers for the core vault engine.
#
# Dot-source this from any core script:
#   . (Join-Path $PSScriptRoot '_VaultCommon.ps1')
#
# The core engine is vault-agnostic: the same scripts drive the work vault
# (~/.copilot) and the personal vault (~/.copilot-personal). Everything that
# differs between the two lives in <root>\vault.config.json.
#
# ASCII-only on purpose: may run under Windows PowerShell 5.1 or a scheduled task.

function Get-VaultRoot {
    <#
      Resolution order:
        1. -VaultRoot argument passed by the caller
        2. $env:COPILOT_VAULT_ROOT
        3. the grandparent of this script's directory (<root>\core\scripts\)
        4. $env:COPILOT_HOME
        5. $env:USERPROFILE\.copilot
    #>
    param([string]$VaultRoot)

    if ($VaultRoot) { return (Resolve-Path -LiteralPath $VaultRoot).Path }
    if ($env:COPILOT_VAULT_ROOT) { return $env:COPILOT_VAULT_ROOT.TrimEnd('\') }

    $fromScript = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if ($fromScript -and (Test-Path (Join-Path $fromScript 'vault.config.json'))) { return $fromScript }

    if ($env:COPILOT_HOME) { return $env:COPILOT_HOME.TrimEnd('\') }
    return "$env:USERPROFILE\.copilot"
}

function Get-VaultConfig {
    <#
      Reads <root>\vault.config.json and fills in defaults. Any path value may
      contain environment placeholders such as %USERPROFILE%.
    #>
    param([Parameter(Mandatory)][string]$Root)

    $defaults = [ordered]@{
        name             = (Split-Path $Root -Leaf)
        remote_slug      = ''
        gh_user          = ''
        mirror_path      = ''
        task_name        = 'CopilotVaultSync'
        required_files   = @('user.md', 'memory.md', 'copilot-instructions.md')
        bootstrap_files  = @('user.md', 'memory.md', 'archive/learned-rules.md')
        mirror_files     = @('user.md', 'memory.md', 'copilot-instructions.md', 'README.md')
        mirror_dirs      = @('archive', 'core')
        open_handoff_cap = 12
        core_canonical   = $false
    }

    $cfgPath = Join-Path $Root 'vault.config.json'
    if (Test-Path $cfgPath) {
        try {
            $loaded = Get-Content $cfgPath -Raw | ConvertFrom-Json
            foreach ($prop in $loaded.PSObject.Properties) {
                $defaults[$prop.Name] = $prop.Value
            }
        } catch {
            throw "Cannot parse $cfgPath : $_"
        }
    }

    $cfg = [pscustomobject]$defaults
    if ($cfg.mirror_path) {
        $cfg.mirror_path = [Environment]::ExpandEnvironmentVariables($cfg.mirror_path)
    }
    $cfg | Add-Member -NotePropertyName Root -NotePropertyValue $Root -Force
    return $cfg
}

function Get-VaultWordCount {
    <#
      Counts maximal non-whitespace runs. Exactly equivalent to the previous
      "-split '\s+' | Where-Object { $_ -match '\S' }" pipeline, including for
      Unicode whitespace such as NBSP, but roughly 11x faster because it is a
      single regex pass with no pipeline. This runs over every budgeted file at
      session start, where the old version cost about 400ms on its own.

      A plain String.Split on a fixed char set is faster still, but is NOT
      equivalent: it misses Unicode whitespace and would silently undercount.
    #>
    param([Parameter(Mandatory)][string]$Text)
    return [regex]::Matches($Text, '\S+').Count
}

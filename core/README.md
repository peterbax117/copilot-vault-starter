# core/ — the portable engine

Everything in `core/` is **domain-neutral machinery**. You should not need to
edit it to adopt the vault; you configure behavior through `vault.config.json`
at the vault root and through your own content files (`user.md`, `memory.md`,
`archive/`).

- `engine.md` — the vault protocol: session-start precondition, retrieval,
  the `q` aliases, lesson capture, budget enforcement. Loaded on demand (the
  agent reads it when it needs an alias's exact steps).
- `identity-core.md` — your durable persona (voice, honesty labels, workflow
  preferences, output format). Loaded every session. **This is a template — fill
  it in.**
- `scripts/` — the PowerShell engine. All of these read `vault.config.json` via
  `_VaultCommon.ps1`, so the same scripts work for any vault on any machine:
  - `Start-Session.ps1` — the one mandatory session-start command.
  - `Test-VaultHealth.ps1` — session-start sanity check.
  - `Test-VaultBudgets.ps1` — enforces the `budget_words` caps.
  - `Sync-Vault.ps1` — auto-commit + push + optional mirror (run every 15 min).
  - `Add-Lesson.ps1` / `Get-PendingLessons.ps1` / `Resolve-Lessons.ps1` — the
    capture → `qlearn` → rules loop.
  - `Sync-Core.ps1` — reconcile `core/` between two vaults (only needed if you
    run more than one vault, e.g. work + personal).
  - `Invoke-VaultSyncHidden.vbs` — window-less shim for the scheduled task.

If you only ever run one vault, you can ignore `Sync-Core.ps1` and the
`core_canonical` config flag entirely.

# SETUP.md — stand up a Copilot CLI vault from this starter

**Audience:** an AI coding agent (or a technical human) setting up the vault for
a user. Follow the phases in order. The agent should run the commands itself and
only ask the user for the interview answers and for the one GitHub step that
needs their account.

**Goal:** turn the user's Copilot CLI home into a git-backed vault with durable
identity, tiered memory, session continuity, and the capture→`qlearn`→rules
loop.

**Assumptions:** Windows + PowerShell; the user has Git, and the GitHub CLI
(`gh`) if they want automated push. This starter lives at some source path
(e.g. `C:\code\copilot-vault-starter`); below it is `$SRC`.

---

## Phase 0 — Decide the vault root and check prerequisites

1. The vault root (`$VAULT`) is the Copilot CLI home: `$env:COPILOT_HOME` if set,
   otherwise `$env:USERPROFILE\.copilot`. Confirm which with the user.
2. Check tools:
   ```powershell
   git --version
   gh --version      # optional but recommended
   $PSVersionTable.PSVersion
   ```
3. Determine whether `$VAULT` **already exists** (an existing Copilot CLI user)
   or not (fresh). Both paths are supported below. Do NOT delete an existing
   `$VAULT` — it holds the user's CLI runtime state. The `.gitignore` in this
   starter is an **allowlist** (`*` then `!` exceptions), so initializing git in
   an existing home only ever tracks the curated vault files; all runtime state
   stays untracked.

---

## Phase 1 — Create the user's private vault repo

The vault holds personal context, so the repo MUST be private and owned by the
user.

Ask the user to create an empty **private** repo (no README) under their own
account, or do it with `gh` on their behalf:

```powershell
gh repo create <user>/<vault-repo> --private --clone=false
```

Record the slug `<user>/<vault-repo>` and their `gh` username — you need both for
`vault.config.json`.

---

## Phase 2 — Put the starter files into the vault root

### Path A — existing `$VAULT` (init git in place; recommended for current CLI users)

```powershell
$VAULT = $env:COPILOT_HOME; if (-not $VAULT) { $VAULT = "$env:USERPROFILE\.copilot" }
$SRC   = "C:\code\copilot-vault-starter"   # adjust to where this starter lives

# Copy every starter file EXCEPT the config template (handled in Phase 3).
Get-ChildItem $SRC -Force | Where-Object { $_.Name -ne 'vault.config.json.template' -and $_.Name -ne '.git' } |
  ForEach-Object { Copy-Item $_.FullName -Destination $VAULT -Recurse -Force }

# Make the vault a git working tree pointed at the user's repo.
git -C $VAULT init
git -C $VAULT remote add origin "https://github.com/<user>/<vault-repo>.git"
```

If the user already has a `copilot-instructions.md`, `user.md`, or `memory.md`
in `$VAULT`, do NOT overwrite blindly — diff and merge with their consent.

### Path B — fresh machine (clone, then copy)

```powershell
$VAULT = "$env:USERPROFILE\.copilot"
git clone "https://github.com/<user>/<vault-repo>.git" $VAULT   # empty repo
Get-ChildItem $SRC -Force | Where-Object { $_.Name -ne 'vault.config.json.template' -and $_.Name -ne '.git' } |
  ForEach-Object { Copy-Item $_.FullName -Destination $VAULT -Recurse -Force }
```

---

## Phase 3 — Write `vault.config.json`

Copy the template and fill it in:

```powershell
Copy-Item "$VAULT\vault.config.json.template" "$VAULT\vault.config.json"
```

Edit `$VAULT\vault.config.json`:

| Field | Set to |
|---|---|
| `name` | short label for the vault (e.g. `"main"`) |
| `remote_slug` | `"<user>/<vault-repo>"` |
| `gh_user` | the user's `gh` account, or `""` to use git's default credential helper |
| `mirror_path` | a cloud-synced folder to mirror curated files to, or `""` for none. Env vars like `%USERPROFILE%` are expanded. |
| `task_name` | leave as `"CopilotVaultSync"` unless it collides |
| `core_canonical` | `true` for a single vault. Only set to `false` on a second vault that pulls `core/` from a canonical one. |

Leave the `*_files` / `*_dirs` / `open_handoff_cap` defaults unless you have a
reason to change them.

---

## Phase 4 — Interview the user and fill the content files

This is the part only a human can answer. Ask, then write their answers into the
files. Keep each file under its `budget_words` frontmatter cap.

**Interview questions:**

1. **Identity** (→ `user.md` "Identity"): role/team; any multiple accounts or
   identities the agent must keep straight and the hard rules for each;
   environment quirks.
2. **Voice** (→ `core/identity-core.md` "Writing voice"): how should the agent
   write? Any banned words/phrases? Punctuation rules (e.g. an em-dash ban)?
   Email tone and sign-off?
3. **Terminology** (→ `user.md` "Domain terminology"): internal tools/acronyms
   to use correctly; any "do not confuse X with Y" rules.
4. **File output** (→ `user.md` "File-output preferences" and
   `core/identity-core.md` "Workspace layout"/"Output format"): where do
   deliverables go? where do repos get cloned? HTML vs Markdown defaults?
5. **Standing rules** (→ `memory.md` "Directives"): any always/never rules they
   already know they want. Add one row each; deeper detail goes to an
   `archive/<topic>.md` with a trigger row in `memory.md`.

Then:
- Remove the `<<< FILL IN >>>` and `TEMPLATE` markers from the files you edited.
- Delete `archive/example-topic.md` once they have (or don't need) a real topic
  file. If you delete it and add no other archive file, keep the `archive/`
  folder from disappearing (git won't track an empty dir — a placeholder or the
  present `learned-rules.md` covers this).
- Update the `last_audit:` frontmatter from `TEMPLATE` to today's date on files
  you finished.

---

## Phase 5 — Bootstrap (initial sync + scheduled task)

```powershell
& "$VAULT\bootstrap.ps1"
```

This runs an initial no-push sync, registers the 15-minute `CopilotVaultSync`
task, and runs the health check. Then do the first push:

```powershell
git -C $VAULT add -A
git -C $VAULT commit -m "Initial vault"
git -C $VAULT push -u origin HEAD
```

If `gh_user` is set and the push 404s or auth-fails, see "Gotchas" below.

---

## Phase 6 — Verify (do not declare success on a red result)

```powershell
& "$VAULT\core\scripts\Start-Session.ps1"
```

A healthy result prints `OK Vault healthy [...]` and a BOOTSTRAP MANIFEST listing
`user.md`, `memory.md`, `core/identity-core.md`, `archive/learned-rules.md` with
non-zero word counts. If it prints problems, fix them (it lists recovery
options) before telling the user it's done. Common first-run issues:

- **Budget check failed** — a content file exceeds its `hard_cap_words`; trim it
  or raise the cap in that file's frontmatter.
- **Sync stale / task not registered** — re-run `bootstrap.ps1`.
- **Unpushed commits** — run the Phase 5 push.

Finally, tell the user the session-start ritual: **every new Copilot CLI session,
the first action is** `& "$env:USERPROFILE\.copilot\core\scripts\Start-Session.ps1"`,
then read the manifest files. The `copilot-instructions.md` in the vault already
tells the agent to do this automatically.

---

## Gotchas

- **Two GitHub accounts (e.g. a corporate/EMU account that can't see a personal
  private repo).** If the active `gh` account differs from the repo owner, a push
  can 404 (not 401). Set `gh_user` in `vault.config.json` to the account that
  owns the repo; `Sync-Vault.ps1` then pushes with a token from
  `gh auth token --user <gh_user>` via an inline credential helper. Make sure
  that account is logged in: `gh auth login --user <gh_user>`.
- **Single vs multiple vaults.** For one vault, keep `core_canonical: true` and
  ignore `qcore`/`Sync-Core.ps1`. Only if the user runs a second vault (e.g.
  work + personal) does core reconciliation matter; then one vault is canonical
  and the other pulls `core/` from it.
- **Mirror is optional.** Leave `mirror_path` empty if there's no cloud folder to
  copy to. The git repo is the primary backup.
- **ASCII-only scripts.** The engine scripts are ASCII-only on purpose (they may
  run under PowerShell 5.1 or a scheduled task). Keep them that way.
- **Never make the vault repo public.** It accumulates personal context.

---

## Manual setup (condensed, for a human doing it without an agent)

1. Create a private repo you own.
2. Copy this starter's files into `~\.copilot` (Path A/B in Phase 2).
3. `git init` (or clone), `git remote add origin ...`.
4. `vault.config.json` from the template; fill in repo/user/mirror.
5. Fill `user.md`, `core/identity-core.md`, and seed `memory.md`.
6. `& "$VAULT\bootstrap.ps1"`, then commit and push.
7. `& "$VAULT\core\scripts\Start-Session.ps1"` and confirm it's green.

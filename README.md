# copilot-vault-starter

A de-personalized starter for a **git-backed memory + behavior system** for a
GitHub Copilot CLI agent. It gives your agent a durable identity, cross-session
continuity, and a self-improvement loop, backed up to git (and optionally
mirrored to a cloud folder) and health-checked at the start of every session.

This is the reusable engine with **blank content**. You (or an AI agent
following `SETUP.md`) fill in the personal pieces.

---

## Mental model (four ideas)

1. **The home directory IS the repo.** Your Copilot CLI home (`~\.copilot`, or
   wherever `COPILOT_HOME` points) is itself a git working tree. The agent's
   config files and its git-backed memory are the same files. No separate vault
   folder, no symlinks.
2. **Tiered memory.** A few small files load *every turn* (`user.md`,
   `memory.md`, `copilot-instructions.md`, `core/identity-core.md`,
   `archive/learned-rules.md`); everything else is *grepped on demand*
   (`archive/<topic>.md`) via a trigger list in `memory.md`. Small always-on
   context, deep knowledge base.
3. **Continuity layers.** `handoffs/` capture "where I left off" per session;
   `projects/` are longer-lived initiative charters. `qresume`/`qend`/`qdone`
   drive the lifecycle.
4. **Self-improvement loop.** Corrections are captured append-only into
   `inbox/`, then a manual `qlearn` pass consolidates them into scored rules in
   `archive/learned-rules.md`. Capture is cheap; consolidation is human-approved.

---

## What's portable vs what you fill in

| Portable engine (use as-is) | Your content (fill in) |
|---|---|
| `core/engine.md`, `core/scripts/*` | `user.md`, `memory.md` |
| `copilot-instructions.md` (generic) | `core/identity-core.md` (persona template) |
| `bootstrap.ps1`, `.gitignore` | `archive/`, `projects/`, `handoffs/`, `inbox/` |
| `vault.config.json.template` | `vault.config.json` (your repo/paths) |

The scripts are **config-driven**: every machine- or account-specific value
lives in `vault.config.json`, so you never edit PowerShell to adopt this.

---

## The `q` command system

Type these tokens (case-insensitive) anywhere in a message. Full steps are in
`core/engine.md`.

| Command | Purpose |
|---|---|
| `qnew` | Reload `user.md` + `memory.md` in full (and grep an `archive/<topic>.md` on a trigger). |
| `qresume` | Read `handoffs/index.md`, list OPEN handoffs, synthesize a brief, propose next actions. |
| `qend` / `qend <focus>` | Write a handoff for the next session (only if work needs carrying forward). |
| `qdone` | Close the active handoff: OPEN→DONE, move to `handoffs/_done/` (local-only). |
| `qmerge` | Batch-close finished handoffs into their project charters. |
| `qvault` | Health check + force sync (commit/push/mirror) + show last commit and state. |
| `qprojects` / `qproject <name>` | List / open + update initiative charters. |
| `qlearn` | Promote captured lessons (`inbox/`) into scored rules (human-approved). |
| `qcore` | Reconcile the shared `core/` engine (only if you run more than one vault). |

---

## Two ways to set it up

- **Have an AI agent do it:** open this folder in Copilot CLI and say
  *"Follow SETUP.md to set up my vault."* The agent interviews you for the
  personal bits and runs the commands. See `SETUP.md`.
- **Do it yourself:** follow the manual steps in `SETUP.md` under
  "Manual setup".

---

## Requirements

- Windows + PowerShell (5.1 or 7).
- Git, and the GitHub CLI (`gh`) if you want automated push with a pinned
  account.
- A **private** git repo you own for the vault (never a public one — this holds
  personal context).

---

## Recovery story

| Failure | Recovery |
|---|---|
| Machine loss | Clone your repo on the new machine, run `bootstrap.ps1` (~2 min) |
| Git host outage | Pull files from your mirror folder (if `mirror_path` is set) |
| Agent corrupts a file | `git -C <vault> log` / `git revert` |

See `SETUP.md` for the full procedure and `core/README.md` for what each engine
piece does.

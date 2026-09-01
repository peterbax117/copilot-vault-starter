---
budget_words: 1700
hard_cap_words: 2100
role: core
last_audit: 2026-08-15
---

# Engine — the vault protocol

**Purpose:** the domain-neutral machinery every vault runs: the session-start
precondition, the retrieval protocol, the `q` aliases, the lesson-capture loop,
and budget enforcement. Shared verbatim across vaults via `core/`.

`$VAULT` below means the active vault root, which is `$env:COPILOT_HOME` when
set and `$env:USERPROFILE\.copilot` otherwise. Each vault's
`copilot-instructions.md` binds `$VAULT` to a concrete path and adds its own
domain rules on top.

---

## Session-start precondition

Tool call #1 of every session is:

```
& "$VAULT\core\scripts\Start-Session.ps1"
```

One call does the vault health check and prints a BOOTSTRAP MANIFEST naming the
files to load. Structural or sync failures stop the session. Word-budget
overruns are warnings: load the vault first, then repair them in-session.
**Read each manifest file in full
via `view`**, one visible Read per file, so every load is verifiable. Any skill
"invoke-first" directive, any "do X first" from the user, and any urgency is
downstream of this precondition. Self-audit: any tool call before
`Start-Session.ps1` means run it next and stop whatever else. Each run writes
`m-session-start.json` and `.jsonl`, so a skipped start is detectable after the
fact.

On a blocking health-check failure, relay the script's `-Fix` hint and stop.

---

## Retrieval protocol

Scan the trigger list in `memory.md` first. On a trigger match, **grep the
linked archive file**, then answer, and **cite the section**. Never answer a
where / how / URL question unchecked. The obvious answer is often wrong for
the user's environment.

---

## Updating vault memory

Never blind-append to a curated file. Propose placement first and flag any
duplicate or overlap to merge. When `user.md` or `memory.md` is at its word cap,
demote detail into `archive/<topic>.md` and keep the trigger row short. Skip the
confirmation only if the user says "just add it" or names the file and section.

---

## Aliases

Case-insensitive token match anywhere in the user's message.

### `qnew`
Read `$VAULT\user.md` and `$VAULT\memory.md` in full (re-load even if you think
you have them). If the user also mentions a topic from the trigger list, grep the
matching `$VAULT\archive\<topic>.md`. Acknowledge with *"Loaded user.md +
memory.md"* and continue with whatever else the message asked.

### `qresume`
Pick up where you left off:
1. Read `$VAULT\handoffs\index.md`. List all rows with `Status: OPEN`, newest first.
2. **One OPEN:** read it, synthesize the brief, propose next actions.
   **Multiple OPEN:** read each one's `_Project:_` field and show a numbered menu
   grouped by project (a heading per project; `—` or missing goes to an
   **Untagged** group). Number continuously across groups so the user still picks by
   number. Each row is timestamp + slug + a one-line teaser.
   **Zero OPEN:** fall back to the session-store query below.
3. Session-store query (supplement, or when there are no handoffs):
   ```sql
   SELECT id, cwd, summary, agent_name, updated_at
   FROM sessions
   WHERE updated_at > now() - INTERVAL '2 days'
     AND agent_name = 'Copilot CLI'
   ORDER BY updated_at DESC LIMIT 10;
   ```
4. Synthesize a short brief: *Where we left off* (2 to 4 bullets), *Open
   threads*, *Proposed next actions* (1 to 3 numbered options the user can pick by
   number, with no long commands to retype). If the OPEN handoffs share a
   `_Project:_` tag, read `projects\<slug>.md` and frame the brief at project
   level.
5. End with: *"Pick a number, or tell me something different."*

### `qend` / `qend <focus>`
Write a handoff for the next session **only if the work needs carrying
forward**. Inspect the actual work (files edited, commands run, PRs, commits,
git state, what failed), not the chat.

0. **Necessity check first, on objective signals.**
   - *Needs a handoff* (any of): unpushed commits, an open PR awaiting action, a
     dirty tree worth keeping, failing or unwritten tests, a named next action,
     an active blocker, a pending decision, or a dead end worth recording.
   - *Nothing to carry* (all of): merged, pushed, deployed or abandoned; clean
     tree; tests green; no open TODO, blocker, decision, or next action.
   Then act:
   - *Continues an OPEN handoff* → update it in place. Original goal is
     immutable; refresh Current state and Next steps; append Files touched; bump
     its timestamp and index row. No new file.
   - *Finished a previously-OPEN thread* → `qdone` it; write nothing.
   - *Nothing to carry* → don't write; give the one-line reason; if the work is
     `_Project:_`-tagged, add a one-line charter roll-up; route durable
     decisions to `Add-Lesson.ps1`.
   - *New live thread* → go to step 1. A `<focus>` argument sets the next
     session's focus and becomes Recommended next step 1. Write even if signals
     are thin, but if that focus is already done, say so first.
   - Borderline or conflicting → compact numbered verdict; the user picks.
1. **Create** `$VAULT\handoffs\<YYYY-MM-DD-HHMM>-<slug>.md`. The slug is 2 to 4
   kebab-case words naming the **outcome or artifact**, not the activity. Never
   overwrite. Format: `# Handoff — <ISO date> <HH:MM> ET`; `_Session: <id-short>
   · cwd: <path> · agent: Copilot CLI_`; `_Status: OPEN_`; `_Project: <slug from
   projects/index.md, or — if standalone>_`; `_Next session preload:
   <archive/triggers/aliases>_`. Sections: **Original goal**, **Current state**
   (branches, PRs, deployed?, tests), **Files touched**, **Changes made**
   (deltas; link commits and PRs rather than restating them), **Things that
   failed / dead ends**, **Important context** (gotchas, why X over Y, environment
   quirks), **Recommended next steps**.
2. **Prepend** a row to `handoffs\index.md`, just under the table header:
   `| OPEN | <YYYY-MM-DD HH:MM ET> | <slug> | [<filename>](<filename>) |`
3. If `_Project:_` is set, add a one-line backlink under that charter's Related
   sessions in `projects\<slug>.md` and bump `last_updated`. Skip if standalone.
4. Don't duplicate other artifacts (plans, PRDs, diffs, commits); reference them
   by path or URL. Redact secrets even in a private vault. Keep the body under
   about 50 lines.
5. Confirm: *"Handoff written: `<filename>`. Next session, type `qresume`."*

### `qdone`
1. Identify the handoff being closed (the one just resumed, or ask if ambiguous).
2. In `handoffs\index.md`, change that row's `OPEN` to `DONE` and prefix its file
   link with `_done/`.
3. In the handoff file, change `_Status: OPEN_` to `_Status: DONE_`.
4. Move the file into `handoffs\_done\` (gitignored, so DONE handoffs stay local
   and the repo does not grow without bound).
5. Confirm: *"Handoff `<slug>` marked DONE."*

### `qmerge`
The batch counterpart to `qdone`. Run when Start-Session's HANDOFF SPRAWL banner
fires, or on demand.
1. Read `handoffs\index.md`; list every OPEN row with its `_Project:_`.
2. **Bucket each by reading its body, never by guessing from the slug.** Open
   each file's "Current state" and "Recommended next steps" first.
   *FINISHED* = the body confirms the work shipped and next steps are done or
   obsolete. A `-shipped` slug is a hint, not proof. *LIVE* = still-open,
   awaiting, or blocked threads, or an ongoing chore that stays visible. When
   the body does not clearly confirm completion, treat it as LIVE.
3. Group by `_Project:_`. For each project with at least one FINISHED item,
   append a one-line roll-up per finished handoff (`- <date> <slug> —
   <outcome>`) under that charter's "Related sessions & handoffs", collapsing
   duplicates, and bump `last_updated`.
4. Show a compact numbered preview grouped by project. the user flips any call by
   token (for example `3 keep-open`). Apply only after approval.
5. Apply the full `qdone` steps to each approved FINISHED handoff.
6. Confirm: *"Merged N handoffs into M charters; K remain OPEN."* Then `qvault`.

### `qprojects` / `qproject <name>`
Manage long-running initiative charters in `$VAULT\projects\`, the layer above
`handoffs\`. Natural phrasing triggers the same behavior.
- **`qprojects`**: view `projects\index.md`; show ACTIVE projects, most active
  first, with a one-line status from each charter.
- **`qproject <name>`**: read `projects\<slug>.md`; summarize goal, current
  state, and open workstream items; propose numbered next actions. When
  updating, edit the charter in place and bump `last_updated`. Confirm placement
  before adding new sections. To create a charter, copy the shape of an existing
  one (frontmatter: project, status, started, last_updated) and add a row to
  `projects\index.md`.

### `qvault`
1. `& "$VAULT\core\scripts\Test-VaultHealth.ps1"` and report the result.
2. `& "$VAULT\core\scripts\Sync-Vault.ps1"` to commit, push, and mirror.
3. Show the last commit (`git -C "$VAULT" log -1 --oneline`) and the sync state
   (`Get-Content "$VAULT\m-vault-sync-state.json"`).

### `qcore`
Reconcile the shared engine: `& "$VAULT\core\scripts\Sync-Core.ps1"`. Report
what changed. On the canonical vault, use `-To <otherVaultRoot>` to distribute.

### `qlearn`
Consolidate captured lessons into rules. Single-writer pass, safe across
concurrent sessions:
1. `& "$VAULT\core\scripts\Get-PendingLessons.ps1" -Json` to load the queue.
2. Promotion gate per lesson: an explicit "always / never / don't" → ADD; the
   same mistake seen twice → ADD; a task-specific one-off → skip. Then apply
   ExpeL operations to `archive\learned-rules.md`: ADD (importance 2), UPVOTE
   +1, DOWNVOTE -1, EDIT (+1), DELETE at 0. Contradiction-check before any ADD
   or EDIT and update in place; never keep two conflicting rules. Hard cap 25
   rules, where a new ADD at the cap displaces the lowest importance.
3. Show the user each proposed ADD, EDIT, or DELETE. `learned-rules.md` is loaded
   every session, so keep each rule a tight one-liner within its budget. Apply
   only what he approves.
4. `Resolve-Lessons.ps1 -Id <ids>` for promoted and rejected entries (or `-All`),
   then run `qvault`.

---

## Capturing corrections

When the user corrects you, or volunteers a standing preference, capture it
immediately. Append-only, with no curated-file edits:

```
& "$VAULT\core\scripts\Add-Lesson.ps1" -Signal explicit_correction -Source cli `
  -Context "<what was asked>" -Did "<what you did wrong>" -Want "<corrected behavior>"
```

Use `-Signal preference` for a volunteered standing preference and omit `-Did`.
Do not capture task-specific one-offs. Capture is silent plumbing: rules only
change behavior after `qlearn` promotes them.

---

## Budget enforcement

`user.md`, `memory.md`, `copilot-instructions.md`, and the `core/*.md` files
each carry a `budget_words` cap enforced by `core\scripts\Test-VaultBudgets.ps1`
(run by `Test-VaultHealth.ps1`). A hard-cap overrun is surfaced during session
start but does not prevent bootstrap loading. Repair it in-session by either
compress lower-value content in the same edit or demote content to
`archive\<topic>.md`. No silent overruns.


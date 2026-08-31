---
budget_words: 1024
hard_cap_words: 1024
role: memory
last_audit: TEMPLATE
---

# Memory — Cross-Session Cheat Sheet

**Purpose:** durable, always-on facts and rules, plus the trigger list that
points at deeper `archive/<topic>.md` files. Identity lives in `user.md`; deep
dives live in `archive/`.

## Retrieval protocol

Scan the trigger list first. On a match, **grep the linked archive**, then
answer and **cite the section**. Never answer a where/how/URL question unchecked.

---

## Directives   `<<< FILL IN >>>`

A compact, numbered table of your standing rules. Each row is a one-liner with a
pointer to where the detail lives. Example rows (replace with your own):

| # | Rule | Source |
|---|------|--------|
| D1 | User-facing files go to `<your deliverables folder>`, not a temp dir | user.md |
| D2 | HTML for human-read deliverables; Markdown for repo files | core/identity-core.md |

---

## Reference quick-hits   `<<< FILL IN >>>`

Facts you keep re-deriving and want the agent to stop guessing. One row each,
with the authoritative detail in an archive file.

| Topic | Fact | Detail |
|-------|------|--------|
| (example) | (the non-obvious answer) | archive/<topic>.md |

---

## Trigger list — grep these topics BEFORE answering   `<<< FILL IN >>>`

When the user's message touches one of these topics, grep the linked archive
file before answering. Add a row per topic as your knowledge base grows.

- <topic keyword> / <synonym> → archive/<topic>.md
- (see archive/example-topic.md for the shape of a topic file)

---

## File map

| Path | Role |
|------|------|
| `copilot-instructions.md` | Agent runtime rules + aliases. Loaded every turn. |
| `user.md` | Identity + preferences. Loaded every turn. |
| `memory.md` | THIS file — cheat sheet. Loaded every turn. |
| `core/identity-core.md` | Durable persona. Loaded every turn. |
| `archive/learned-rules.md` | Scored rules learned from corrections (via `qlearn`). Loaded every turn. |
| `archive/*.md` | Topic deep-dives. Grepped on demand per the trigger list. |
| `projects/` + `index.md` | Long-running initiative charters (synced). |
| `handoffs/` + `index.md` | Session continuity notes. `qresume`/`qend`/`qdone`. |

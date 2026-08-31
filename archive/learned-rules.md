---
budget_words: 1024
hard_cap_words: 1200
role: archive
topic: learned-rules
last_audit: TEMPLATE
---

# Learned Rules (auto-consolidated)

**What this is:** the `qlearn`-maintained rulebook, built from the lessons the
agent captures in `inbox/` when you correct it or state a standing preference.
Each rule is a tight one-liner. Loaded every session.

**Lifecycle (ExpeL):** ADD at importance 2 · UPVOTE +1 · DOWNVOTE -1 · EDIT +1 ·
DELETE at 0. Hard cap 25 rules; a new ADD at the cap displaces the lowest. Never
keep two contradictory rules.

**Promotion gate:** an explicit "always / never / don't" → ADD; the same mistake
seen twice → ADD; a task-specific one-off → stays in `inbox/`, never promoted.

---

## Rules

_(empty — rules appear here after your first `qlearn` pass. Until then, this file
just needs to exist so the session-start manifest and health check are happy.)_

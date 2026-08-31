---
budget_words: 2048
hard_cap_words: 4096
role: archive
topic: example-topic
last_audit: TEMPLATE
---

# Example Topic (delete or replace)

**This file exists to show the shape of an on-demand knowledge file.** Archive
files are NOT loaded every session — they are grepped only when the user's
message matches a trigger row in `memory.md`. That is what keeps the always-on
context small while letting the knowledge base grow without limit.

## How to use archive files

1. When you learn a durable fact that is too detailed for `memory.md`, put it
   here (or in a new `archive/<topic>.md`).
2. Add a one-line trigger row in `memory.md` under "Trigger list" pointing at
   this file, with the keywords that should make the agent grep it.
3. Give each fact enough context to act on, and cite where it came from (a URL,
   a file path, or `User input: "<quote>"`).

## Example fact

- **The internal widget portal is at `https://widgets.example.internal`**, not
  the public `widgets.example.com`. Verified 20XX-XX-XX. (Replace this with a
  real fact, or delete this whole file once you have your own.)

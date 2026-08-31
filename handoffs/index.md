# Handoffs — index

Per-session continuity notes. `qend` writes one when work needs carrying
forward; `qresume` reads the OPEN rows; `qdone` flips a row to DONE and moves the
file to `_done/` (local-only). Newest rows go directly under the header.

| Status | When | Slug | File |
|--------|------|------|------|

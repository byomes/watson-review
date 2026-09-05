# Proposal: generalize `kb_export_link` into a Watson-wide file-export-link mechanism

**Author:** Claude Code (this session), for Bill + Claude.ai to review together.
**Status:** proposal only — nothing built yet.
**Date:** 2026-09-05

## Problem this solves

This session hit a real gap: there's no good way to hand a file from Watson to
Claude.ai (or back to Bill in a different chat/device) for review. Two paths
were tried and rejected this session:

1. **`watson-review` GitHub dropzone** — works well for *deliverables meant to
   be shared* (audit reports, findings docs), but `byomes/watson-review` is a
   **public** repo. Anything pushed there is visible to the internet,
   indefinitely (a later delete doesn't undo it — git history keeps it). Fine
   for a markdown report; wrong for anything containing session internals,
   production details, or anything sensitive.

2. **Google Drive via the MCP connector** — the alternative floated mid-session.
   Rejected for a structural reason, not a config problem: `create_file`'s
   `textContent`/`base64Content` parameters require the *entire file content*
   to pass through the model's own context as a tool-call parameter. For this
   session's own transcript (~2.3MB, full of SSH/sudo/git-token-handling
   content from real production administration), that content passing through
   the model tripped Claude's own automated cybersecurity safeguards and the
   upload failed outright — legitimate work, false-flagged, but a real,
   observed failure mode, not hypothetical. It would also cost real context
   tokens proportional to file size for every future handoff, and needs a new
   Google OAuth consent step that only a human can complete.

**The actual requirement:** a handoff path where file content never has to
pass through an LLM's context to get from Watson's disk to wherever it's
being reviewed — only a short reference (a URL) should ever cross that
boundary. Whether the file is 2KB or 200MB shouldn't matter to the transfer
step at all.

## Existing precedent already in production

`jobs/kb/` already solves exactly this shape of problem, just scoped to one
feature (KB search zip exports), built 2026-08-24:

- `jobs/kb/export_link.py` — `create_export_link()`-equivalent: takes a file
  already on disk, generates an opaque token, inserts a row into
  `kb_export_links` (token, zip_path, query, caption, expires_at), returns
  `https://watson.tail0243ff.ts.net/kb/download/<token>`.
- `jobs/kb/api.py` — `GET /kb/download/<token>` looks up the token, streams
  the file, marks it `used`. Deliberately **unauthenticated by design** —
  security comes from the URL only being reachable over Tailscale (not the
  public internet) plus the token being single-use and short-lived (15 min).
- `jobs/kb/export_link_cleanup.py` — cron every 30 min, deletes expired
  unused rows/files and used rows past expiry.

This is already live, already reasoned-through, and already accepted as a
safe pattern for this exact class of problem (see `jobs/devdispatch/api.py`'s
own comment calling it out as "a deliberate exception" to the connector's
usual no-raw-filesystem-access rule, precisely because the link itself
carries no filesystem access — it expires and self-destructs).

## Proposed change

Generalize this from "KB zip files only" to "any file on Watson's disk,"
as a small parallel module rather than overloading the KB-specific schema:

**New files:**

- `jobs/exports/schema.py` — `file_export_links` table: `token TEXT PRIMARY
  KEY, file_path TEXT NOT NULL, caption TEXT, created_at TEXT, expires_at
  TEXT NOT NULL, used INTEGER NOT NULL DEFAULT 0`.
- `jobs/exports/export_link.py` — `create_export_link(file_path: str,
  expires_minutes: int = 15, caption: str | None = None) -> str`, mirroring
  `jobs/kb/export_link.py` almost line-for-line: generate token, insert row,
  return `f"{_BASE_URL}/export/download/{token}"`.
- `jobs/exports/api.py` — Flask blueprint, `GET /export/download/<token>`:
  look up token, 404 if missing/expired/used, stream the file with its real
  filename, mark `used = 1`. Mirrors `jobs/kb/api.py`'s route almost exactly.
- `jobs/exports/export_link_cleanup.py` — same 30-min cron pattern as
  `jobs/kb/export_link_cleanup.py`, targeting `file_export_links` instead.

**Wiring:**

- Register the new blueprint in `jobs/dashboard/app.py` alongside the
  existing `kb_bp` registration.
- Add the cleanup cron entry to the live crontab, and document it in
  `WATSON_ARCHITECTURE.md`'s Active Scheduled Jobs table + `memory/CRON.md`
  (matching the convention this session already used for the logrotate
  cron entry and PR #57's resource-sampler entries).

**How I'd use it going forward:** for any future "get this file to Bill/
Claude.ai" need, I call `create_export_link(path)` directly — no `scp`, no
cross-machine step, since this Claude Code session runs directly on the
Beelink (a fact I got wrong earlier this session and Bill corrected — there's
only one machine, not two). Bill (or a Claude.ai session, if it fetches URLs
itself) opens the link in a browser; the actual bytes travel over an
authenticated Tailscale HTTP stream, never through my model context.

## What this does *not* solve

If Claude.ai (or any LLM) needs to actually *read and reason about* the
downloaded content afterward — the same content-sensitivity/safeguard risk
that hit the Drive upload could still occur *at that later step*, since
that's inherent to asking a model to review sensitive material, not a
transfer-mechanism problem. This proposal only fixes getting the bytes from
Watson's disk into a browser/download — it doesn't and can't guarantee
anything downstream of that is safe to feed back into a model.

## Open questions for review

1. **Expiry window** — keep 15 min (matches `kb_export_link`), or longer,
   given some files (like a full session transcript) might take a bit to
   download/review before the link needs to still work?
2. **Any file size cap?** KB zips are typically small; a full session
   transcript or a database snapshot could be much larger. Worth a sanity
   limit (e.g. refuse to link anything over some threshold) so this can't be
   used to accidentally stream something huge, or is Tailscale-only
   reachability + single-use token sufficient risk mitigation on its own?
3. **Extra auth beyond Tailscale + token?** `kb_export_link` accepts
   "Tailscale-only + single-use" as sufficient. Should the general version
   require the same, or additionally require the devdispatch OAuth bearer
   token, so it's reachable only via an authenticated Claude.ai session
   specifically, not merely "anyone on the tailnet with the link"?
4. **Consolidate or coexist?** Should `kb_export_link` get rewritten to call
   this new general mechanism internally (one code path, less duplication),
   or should the two stay independent since KB has its own query/caption
   metadata shape that doesn't cleanly generalize?
5. **Audit trail** — worth logging each export-link creation/use (who/what
   requested it, when) beyond what's already implicit in job logs, given this
   is a new way for *arbitrary* files to leave the box (scoped to Tailscale,
   but still a new capability)?

No code has been written for this yet — this is a proposal for review before
any of it gets built.

# Watson Infrastructure Review — Speed & Accuracy

Scanned live on the Beelink (`ssh watson`, `~/watson`, git HEAD as of 2026-09-05) via read-only
`ssh`/`grep`/`sqlite3` — code, cron, and `data/*.db` schemas. Prior-session memory items were each
re-verified against current code rather than trusted as-is; two turned out already fixed (noted at
the bottom) and are dropped from the active list below.

---

## HIGH

### 1. `jobs/dashboard/app.py` `_update_project_memory()` (~line 3636) — unbounded Ollama prompt, no `num_ctx`, silently destructive on truncation
**What:** This function POSTs to `http://localhost:11434/api/generate` (model `qwen2.5-coder:7b`)
with a prompt that embeds the **entire current project memory markdown file** (`current_mem`) plus
the new exchange, and asks the model to return the complete updated file. It sets no `options.num_ctx`
at all — unlike every other Ollama call site touched by the 2026-09-03 num_ctx fix (router.py,
audit.py, state_of_church.py, build.py, team/extractor.py, the two monthly report jobs all import
`core.ollama_context.size_num_ctx`; this call site does not).
**Why it matters (accuracy — data loss, not just latency):** Ollama silently truncates prompts that
exceed the active `num_ctx` (confirmed root cause of bug #118) rather than erroring. Here the
*output* directly overwrites the memory file (`mem_path.write_text(updated, ...)` — full replace, no
diff/merge). If a longer project memory file gets truncated on the way in, the model has never seen
the dropped sections and will not reproduce them — the rewritten file permanently loses that content
the next time this runs. This is the exact "hallucination via truncation" failure class bug #118/#121
was fixed for elsewhere, just not here.
**Fix:** `from core.ollama_context import size_num_ctx` and add
`"options": {"num_ctx": size_num_ctx(prompt)}` to this call, matching the pattern in
`jobs/skillbuilder/audit.py`/`router.py`. Also worth considering a lower-risk design (diff-and-append
instead of whole-file regenerate-and-overwrite), but the one-line `num_ctx` fix removes the acute
silent-data-loss risk immediately.

### 2. `bug_tracker` #119 confirmed still open — `jobs/skillbuilder/router.py:377` `_ask_router()` 8s timeout
**What:** Verified in current code: `resp = requests.post(OLLAMA_URL, json={...}, timeout=8)`. The
prompt this call sends embeds the full skills list (~50 skills, ~6-8k tokens per the file's own
comment) and already gets a correctly-sized `num_ctx` via `size_num_ctx(prompt)` — but the 8s
wall-clock timeout was never raised to match.
**Why it matters (both speed and accuracy):** Every skill list growth makes a `requests.Timeout` on
this call more likely. On timeout the exception path (not shown here but referenced by the router's
callers) falls through to a lower-confidence classification/CHAT — i.e. a real routing decision
degrades to a guess under exactly the conditions (large prompt, real load) where it should be least
trusted. This is the same "hallucination wearing a latency costume" pattern already fixed for the
classifier via `core/ollama_lock.py`, but this specific call site's timeout was explicitly called out
as out-of-scope when that fix landed and has not been revisited since (still 8s as of this scan).
**Fix:** Either raise the timeout proportional to prompt size (e.g. scale off the same
`size_num_ctx`/token-estimate math already computed for this call), or route this call through
`core/ollama_lock.py`'s busy-check pattern with an honest "still deciding" fallback instead of a hard
timeout that silently degrades routing quality.

---

## MEDIUM

### 3. `bug_tracker` #117 confirmed still open — `jobs/memory/reflect.py` `_load_messages()` nondeterministic tie-break
**What:** Verified unchanged: `"SELECT role, content FROM chat_messages WHERE session_id = ? ORDER BY created_at DESC LIMIT ?"` — `created_at` has second-level resolution and no secondary sort key.
**Why it matters (accuracy):** Same-second user/assistant message pairs (common — a fast reply) can
come back in either order. `reflect()` feeds this transcript straight into the Ollama/Claude
summarization prompt and appends the result to `memory/relational.md` — a scrambled transcript order
can produce a summary that misattributes who said what, written permanently into long-term memory
with no review step.
**Fix:** One-line change: `ORDER BY created_at ASC, id ASC` (dropping the `reversed()` call currently
needed to un-reverse the DESC result), or keep `DESC` and add `, id DESC` as the explicit tie-break.
Trivial fix, unresolved for over a week as of this scan.

### 4. Stale `devdispatch` git worktrees never cleaned up — 498MB, oldest 17 days old
**What:** `~/watson/.claude/worktrees/` currently holds 10 `devdispatch+<timestamp>` directories
(498MB total via `du -sh`), oldest from 2026-08-19. Confirmed via `grep -n "worktree remove\|prune"
jobs/devdispatch/api.py jobs/devdispatch/poller.py` — **no match at all**. There is no cleanup path
for a devdispatch worktree anywhere in the codebase, whether the job succeeds, fails, or gets merged.
**Why it matters (speed + resource leak):** This isn't only the known bug #95 failure case (branch-
tracking mismatch orphaning a worktree) — even a normal successful `merge_claude_code_job` leaves its
worktree in place forever. Every `git` operation against the main `watson` repo (status, gc, fsck,
even `git worktree list` itself) has more metadata to walk as this grows unbounded, and disk usage
climbs with every dispatched job indefinitely.
**Fix:** Add `git worktree remove <path> --force` (+ periodic `git worktree prune`) to
`_finalize_completed_job`/`merge_claude_code_job` in `jobs/devdispatch/api.py` once a job is
merged/closed (success or a terminal failure that's been reviewed). One-time cleanup of the current
10 stale directories recovers ~500MB immediately.

---

## LOW (future-proofing — not urgent at current data volume, but cheap to fix now)

### 5. `congregation.db` `attendance` table has no index on `service_date` or `member_id`
**What:** `EXPLAIN QUERY PLAN` on the exact query `jobs/connect_cards/state_of_church.py` runs
(`WHERE service_date = ? GROUP BY campus`) returns `SCAN attendance` + `USE TEMP B-TREE FOR GROUP BY`
— a full table scan. Same story for any `member_id` join (`_first_time_visitors`,
`_open_follow_ups`, `_members_not_seen`, etc. all join through `attendance`/`connect_cards` on
unindexed FK columns). Confirmed table sizes: `attendance` 2,413 rows, `members` 193, `connect_cards`
2,217 — small enough today that this costs low-single-digit milliseconds, not a real problem yet.
**Why it matters:** `state_of_church.py`, `missed_report.py`, `attendance_link_reminder.py`, and the
monthly report jobs all run these queries on cron already; the table grows by ~1-2 rows per member
per service indefinitely. Free to fix now, gets more valuable every month.
**Fix:** `CREATE INDEX idx_attendance_service_date ON attendance(service_date); CREATE INDEX
idx_attendance_member_id ON attendance(member_id);`

### 6. `watson.db` (122MB) — several frequently-queried tables lack indexes matching their actual query patterns
**What:** Confirmed via `EXPLAIN QUERY PLAN`: `chat_messages` (queried by `reflect.py` as
`WHERE session_id = ? ORDER BY created_at DESC`) and `llm_call_log` (queried
`ORDER BY created_at DESC LIMIT 50` for dashboard/monitoring views) both show `SCAN` + `TEMP B-TREE`.
Row counts today are small (`chat_messages` 202, `llm_call_log` 267, `job_runs` 200,
`resource_samples` 199 — the last written every 5 minutes by `jobs/dev/resource_sampler.py` with no
visible retention/rotation job found in `jobs/cleanup.py` or elsewhere) — negligible cost right now.
**Why it matters:** `resource_samples`/`job_runs`/`telegram_log`/`llm_call_log` are all cron-fed and
grow monotonically with no pruning step located anywhere in the codebase — left alone, both the query
cost and the file's 122MB size will keep climbing.
**Fix:** Add `idx_chat_messages_session_created ON chat_messages(session_id, created_at)` and similar
for `llm_call_log(created_at)`; separately, add a retention job (e.g. prune `resource_samples` and
`job_runs` rows older than 90 days) since `jobs/dev/resource_sampler.py` is explicitly a temporary
VPS-sizing measurement per its own cron comment ("expires 2026-09-11" pattern is used elsewhere for
similar temporary jobs, e.g. `jobs.analytics.claude_spend_daily_report` — worth applying the same
self-expiry convention here if the sampling was meant to be temporary).

---

## Verified already fixed — no action needed (dropped from active list)

- **bug #118 (Ollama `num_ctx` truncation)** — confirmed fixed at all 7 originally-flagged call sites
  (`router.py`, `audit.py`, `state_of_church.py`, `build.py`, `team/extractor.py`,
  `monthly_state_report.py`, `monthly_web_engagement_report.py`) via `core/ollama_context.size_num_ctx`.
  **Except** the dashboard's `_update_project_memory` call site above (finding #1), which was missed.
- **`core/ollama_lock.py` busy-lock coverage** — confirmed all five originally-flagged heavy jobs
  (`audit.py`, `build.py`, `team/extractor.py`, `monthly_state_report.py`,
  `monthly_web_engagement_report.py`) correctly wrap their long Ollama calls in
  `with heavy_ollama_call("<job_name>"):`.
- **`state_of_church.py` fabrication risk** — the earlier reasoning-comparison harness ran raw Ollama
  models directly; production code (`_ollama_synthesis`) actually tries `call_claude(...)` first and
  only falls back to local Ollama on failure, and the prompt already hard-codes the specific
  constraints the comparison caught models violating (3-week minimum before using "trend" language,
  seasonal-caveat-first ordering, combined-vs-per-campus range rules). No code defect found here beyond
  general model-fallback risk already known and tracked; a deterministic post-generation regex check
  (e.g. reject output containing "trend"/"decline" when the computed `CONSECUTIVE WEEKS OUTSIDE NORMAL
  RANGE` < 3) would harden this further but is a judgment call, not a bug — flagged as a possible
  follow-up, not a finding.

# Watson Full System Analysis — Cleanup & Performance Sweep

**Audit-only. Nothing on the Beelink was fixed, deleted, or modified.** All exploration was
read-only (`ssh watson`, `grep`, `sqlite3` schema/count queries, `git log`) against live code at
`~/watson` (git HEAD as of 2026-09-05). Dr. Bill reviews before anything below is actioned.

Builds on `2026-09-05-watson-infra-review.md` (same drop-zone) — its 4 items are re-verified here,
not re-derived from scratch.

---

## Executive Summary

Watson's core jobs/cron/service layer is coherent and mostly well-documented — several things the
brief predicted as duplication turned out, on inspection, to be intentional and clean (the Facebook
pipeline split, the five email namespaces). The real findings cluster in three places:

1. **A live, unresolved instance of bug #95** (devdispatch branch-tracking mismatch) sitting on disk
   right now — job #46's real work is stuck on an unmerged branch that Watson's own tracker marked
   `failed`, and nothing has surfaced it since.
2. **`jobs/misc/` is genuinely a graveyard** — 4 of its 6 files are dead, 2 of those have import
   errors that would crash on execution. Real, zero-risk deletions.
3. **The Kit→Brevo migration is further along than the new audit's own framing assumed** — of the
   "5 live Kit write paths," one (lead-magnet forms) was already cut to Brevo on 2026-08-22. Four
   Kit write paths remain live, not five, and three specific pieces of already-confirmed-dead Kit
   code are still sitting in the tree pending a Phase 4 that hasn't run.

No new num_ctx-class production incidents were found beyond the one the prior review already
caught, but a broader sweep of every Ollama call site turned up one clearly acknowledged large-prompt
risk (`fireflies_review.py`, ~37k chars) that doesn't use the standard fix pattern.

---

## 1. Duplication & Dead-Code Audit

### 1a. HIGH — `jobs/misc/` grab-bag: 4 of 6 files dead, 2 have reproducible ImportErrors
Checked every file's imports and cross-referenced crontab (`crontab.txt`, captured live) and the 4
systemd services (`watson-bot`, `watson-dashboard`, `watson-codeagent`, `watson-people`) — none of
the four reference these files.

| File | Status | Evidence |
|---|---|---|
| `both_read_pdf.py` | Orphaned | No import found anywhere in the tree; not in cron/systemd. |
| `here_link_book.py` | **Broken + orphaned** | `from ollama import log_message` and `from python_dotenv import load_dotenv` — neither is a real importable name (`ollama` has no `log_message`; the package is `dotenv`, not `python_dotenv`). Would `ImportError` on the first line it needs. Not in cron/systemd. |
| `im_trying_file.py` | Orphaned | Name and content (an unfinished Telegram handler stub) read as an abandoned scratch file. No references found. |
| `tells_many_days.py` | Orphaned (but functional) | Working Christmas-countdown script. Its own docstring says `jobs/christmas_count.py` — a path it no longer lives at, evidence of a rename that never got cleaned up. Confirmed absent from the live crontab — never wired to a scheduler despite working code. |
| `update_your_own.py` | **Broken + orphaned** | Same `python_dotenv`/`ollama.api.system_prompt_update` broken-import pattern as `here_link_book.py`. Not a systemd service, not in cron. Dead HTTP server for prompt updates. |
| `riddle.py` | **Live — keep** | Imported by `bot/bot.py` and `jobs/skillbuilder/audit.py`. Not part of this finding. |

**Recommended action:** delete `both_read_pdf.py`, `here_link_book.py`, `im_trying_file.py`,
`tells_many_days.py`, `update_your_own.py`. Zero functional risk — none are reachable from any live
entrypoint, and two would crash immediately if anyone tried to run them today.

### 1b. MEDIUM — `jobs/dev/fix_style.py` vs `jobs/dev/fix style.py` (literal space) — confirmed real duplicate, diverged
Both files exist; `diff` shows they are **not** the same script saved twice — they're two different
rewrites of the same idea with different function names (`check_em_dash`/`check_frontmatter`/... vs
`flag_dashes`/`split_frontmatter`/`process_file`) and different design claims. Neither is importable
as a module (the space in the filename makes that impossible in Python), neither is in cron, and the
only other reference to either is a docstring copy inside a `data/session_archives/` transcript —
both are dead as far as any live path is concerned.

One thing worth flagging before picking a winner: `fix style.py` (the space-filename one)'s own
docstring **contradicts itself** — its numbered feature list claims em dashes are "auto-fixed with a
conservative rule, logged for review," but the design-note paragraph immediately below it says "This
script NEVER auto-rewrites em-dash / double-hyphen sentences," and the actual code (`flag_dashes()`)
only flags, never rewrites — matching the design note, not the numbered list. `fix_style.py` (no
space) is internally consistent (flag-only, says so once, does that).

**Recommended action:** treat `fix_style.py` (no space) as canonical — it's what the docstring calls
itself (`python3 fix_style.py ...`) and it's not self-contradictory. Diff for any check `fix style.py`
does that `fix_style.py` doesn't (skimming: the space version's frontmatter-repair return shape and
`TEXT_FILE_EXT` handling differ slightly), fold in anything worth keeping, then delete `fix style.py`.

### 1c. LOW (already fixed, but with a live residual risk) — bug #97 / `kb_search.py`
Confirmed `jobs/skills/kb_search.py` genuinely has no `run()` function (only `search_kb()` and
`format_result()`) — the premise behind bug #97 is real. But `git log -S"kb_search import run" --
jobs/dashboard/app.py` shows this was **already fixed on `main`**, commit `bef91e6d` (2026-08-28),
which changed `from jobs.skills.kb_search import run as _kb_run` to
`from jobs.skills.kb_search import search_kb as _kb_run, format_result as _kb_fmt`. The 2026-08-24
memory calling this "open" predates that fix by four days — it's stale, not wrong.

**Residual risk, not hypothetical:** 6 of the 10 stale devdispatch worktrees (see §3) — `kb-export-
download-link`, `devdispatch+20260807-122742`, `+20260819-161030`, `+20260820-165623`,
`+20260820-171920`, `+20260824-014848` — still carry the **old, broken** `import run as _kb_run` line
because they were branched before the Aug 28 fix. If any of those is ever resurrected, cherry-picked
from, or manually re-merged (plausible given how bug #95 already causes exactly this kind of "revive
an old worktree" scenario), the fixed bug reappears. This is a concrete argument for cleaning up §3
promptly rather than a cosmetic one.

Could not locate **bug #52** by ID in `memory/BUGS.md` with the search patterns tried this pass — the
file doesn't use a `### <number>` heading format my greps matched. Flagging this gap honestly rather
than guessing at its content.

### 1d. Resolved with no action needed — `facebook_post.py` vs `jobs/comms/facebook_dispatch.py`
**Not a duplicate.** Two intentionally separate pipelines:
- `jobs/facebook/facebook_post.py` owns the `facebook_queue` table — bot-driven, ad-hoc single posts
  (image-gen approve/reject flow via Telegram), cron every 15 min.
- `jobs/comms/facebook_dispatch.py` (56 lines) is a thin bridge: finds due, approved, `comms_desk`-
  sourced rows in `book_launch_sends`, hands each to `jobs/campaigns/dispatch.py`'s
  `dispatch_facebook_row()` — **the same function** the book-launch "Approve All" path already used —
  then marks the row sent. Its own docstring explains it exists because nothing previously drained
  Comms Desk's approved Facebook rows; it was filling a real gap, not re-implementing anything.
  `dispatch.py` "never posts to Facebook directly and never touches facebook_post.py" per its own
  header comment — confirmed true, no shared Graph-API-calling code duplicated between the two.

Both are live in cron, both necessary, no overlap in what table each reads or in the actual
Graph-API-calling code path. This was the one named suspicion in the brief that checked out clean.

### 1e. Resolved with no action needed — the five email namespaces
Mapped each; they're pipeline **stages**, not competing implementations:

| Namespace | Role |
|---|---|
| `jobs/email_intake.py` | Top-level: fetch unread Gmail, triage via Ollama, gate every non-whitelist email behind an explicit Telegram approval. Cron every 1 min. |
| `jobs/email_reply/` | `reader.py` (cron */15, IMAP-based reply detection), `handler.py`, `drafter.py` — everything about *replies to sent mail*. |
| `jobs/email_job/` | `brevo_send.py` — the actual low-level Brevo transactional-send wrapper (41 call sites across the repo, confirmed the one real sender). `draft_email.py` (cron weekly, newsletter broadcast draft), `email_queue.py`, `gmail.py`. |
| `jobs/email_send/send.py` | A natural-language skill: "extract to/subject/body from this message and send it," itself calling `jobs.email_job.brevo_send.send_email` — a thin layer *on top of* `email_job`, not a second sender. |
| `jobs/email_activity/api.py` | Small (3KB) activity-tracking API, presumably for a UI. |

No functional overlap found. The naming is genuinely confusing on first read (`email_job` vs.
`email_send` both sound like "the thing that sends email") — worth a one-paragraph clarifying note in
`WATSON_ARCHITECTURE.md` for future-Claude's benefit, but not a code change.

### 1f. LOW — `jobs/research/summarizer.py` — likely orphaned, `core/summarizer.py` is the live one
`core/summarizer.py` is imported by `core/fetcher.py` (`from core.summarizer import summarize`) — the
general-purpose summarizer actually wired into the research-fetch pipeline. `jobs/research/summarizer.py`
("summarize text using LSA and extract topics via LDA" per its own docstring) has **no import site
anywhere else in the repo** — the only hit for it in a full-tree grep is its own file. Not confirmed
dead beyond doubt (didn't check for a `__main__` block making it a manually-invoked CLI tool), but no
evidence of it being called by anything live.

**Recommended action:** confirm with `grep -n "__main__"` and check whether Bill ever runs it by hand;
if not, archive or delete — and check `requirements.txt` for LSA/LDA-only dependencies (e.g. `gensim`,
`sumy`) that would become removable too.

### 1g. LOW — `jobs/congregation/migrate_*.py` — 5 one-time scripts, all confirmed one-time by design
| File | Age | Purpose (from own docstring) |
|---|---|---|
| `migrate_deacon_directory.py` | Jul 14 (schema shows Aug 24 mtime) | Adds address/household/deacon columns for the deacon directory import. |
| `migrate_deacon_notes.py` | Sep 2 | Splits `deacon_notes` out of `follow_ups`. |
| `migrate_inactive_deacon.py` | Aug 31 | One-time backfill: seeds the "Inactive" deacon bucket from campus classification. Has `if __name__ == "__main__"`. |
| `migrate_leadership_roles.py` | Jul 14 | Adds `leadership_roles` table. |
| `migrate_reparse.py` | Jun 7 | Re-parses already-processed connect-card emails. Has `if __name__ == "__main__"`. |

Only one external reference found (`jobs/congregation/deacons_web.py`, a docstring cross-reference,
not an import) — none of the five are called by any live cron job or service. All are explicitly
one-time by their own documentation, several quite recent (the Aug 31/Sep 2 pair), which is normal —
this is exactly the "bolt something on, don't clean up after" pattern the brief predicted, just at
low stakes since these scripts are inert once run.

**Recommended action:** confirm each migration's target schema change is present (e.g. `deacon_notes`
table exists, `deacon`/`address`/`household` columns exist on `members`) — a 5-minute
`sqlite3 data/congregation.db ".schema members"` check — then move all 5 into a
`jobs/congregation/migrations_archive/` subfolder. Zero functional risk either way.

---

## 2. Speed & Accuracy Pass

### 2a. HIGH (re-confirmed) — `jobs/dashboard/app.py` `_update_project_memory()` — no `num_ctx`, overwrite-on-truncation
Confirmed still present as reported in the prior review: this call site is among the ~27 found
missing `num_ctx`/`size_num_ctx` in the broader sweep below. Same fix as before:
`from core.ollama_context import size_num_ctx` + `options.num_ctx` on this call. No change to the
prior review's analysis — re-stated here for completeness of this pass's own scope.

### 2b. HIGH (re-confirmed) — bug #119, `jobs/skillbuilder/router.py` 8s Ollama timeout
Not independently re-walked line-by-line this pass (the prior review did that same-day); still open
per that review. No new evidence found to contradict it.

### 2c. MEDIUM (re-confirmed) — bug #117, `jobs/memory/reflect.py` nondeterministic message ordering
Same as above — not re-walked this pass, no new evidence against the prior finding.

### 2d. NEW, MEDIUM — Broader num_ctx sweep: ~27 of 41 Ollama call sites lack sizing, but most are fine — one confirmed real risk
Grepped every `api/generate`/`OLLAMA_URL` call site in `jobs/`, `core/`, `bot/` (41 files) against
`num_ctx`/`size_num_ctx` presence. 27 files came back "missing." **Do not read that as 27 bugs** — a
naive presence-grep can't tell a genuinely large prompt from a short, safely-bounded one, and spot
checks confirm most aren't at risk:

- `jobs/dev/error_analyzer.py` — flagged by the grep, but actually safe: it manually truncates
  (`traceback_str[:2000]`, `code[:1000]`) *before* building the prompt, so there's nothing for
  `num_ctx` to protect against. Good example of why a blanket rollout would be wasted effort.
- `jobs/email_job/draft_email.py` — prompt built from short joined title/body lines; no evidence of
  unbounded size.

One genuine, developer-acknowledged risk found:
- **`jobs/meet/fireflies_review.py::_build_structured_prompt()`** — its own comment says it's built
  to handle "the full raw transcript (~37k chars on that same meeting, capped" — a real, sizable,
  variable-length input (elder-meeting transcripts) feeding a structured-summary synthesis step whose
  output becomes the meeting's official record. ~37k chars is roughly 9-10k tokens, well past a
  default context window. The file manages its own truncation rather than using the shared
  `core/ollama_context.size_num_ctx` helper everything else in the post-bug-118 fix uses — an
  inconsistent pattern, and worth confirming the manual cap is actually safe rather than assuming so.

Two more plausible-but-unconfirmed candidates, listed for a cheap follow-up rather than claimed as
findings: `jobs/ask.py` (KB excerpt synthesis — bounded by how many/how large the excerpts are, not
independently sized this pass) and `jobs/dev/code_agent.py`/`jobs/code_agent/agent.py` (prompt =
fixed system prompt + user's build-request text, size depends on the request).

**Recommended action:** rather than adding `num_ctx` everywhere the grep flagged, use Watson's own
existing instrumentation — `core/llm_log.py` is already imported (`# noqa: F401`) specifically to log
every Ollama call — to pull real prompt-length distributions for these ~27 sites over a week, then
size only the ones that actually run long. Fix `fireflies_review.py` now regardless (the risk is
already documented in the file itself); treat the rest as measure-first.

### 2e. LOW (refines prior review) — index gaps: `chat_messages` and `llm_call_log` confirmed empty, `job_runs`/`resource_samples` already indexed
Ran `.indexes` directly against `watson.db`: **`chat_messages` and `llm_call_log` have zero indexes**
(confirmed — matches and sharpens the prior review's finding). But **`job_runs` and
`resource_samples` already have indexes** (`idx_job_runs_started_at`, `idx_resource_samples_sampled_at`)
— the prior review's suggestion to add those two was already done before this scan; only
`chat_messages`/`llm_call_log` still need it. Current row counts: `chat_messages` 202, `llm_call_log`
282 — both still trivial, so this remains a "cheap now, valuable later" fix, not urgent.
`congregation.db.attendance`'s missing index (from the prior review) was not independently
re-verified this pass; no evidence found to contradict it.

---

## 3. Disk Space Sweep

### 3a. HIGH — devdispatch worktrees: 498MB confirmed, but one holds real unmerged work (a live bug #95 instance) — do not blanket-delete
`.claude/worktrees/` still holds the same 10 directories the prior review found (498MB total,
49-56MB each), all still properly registered in `git worktree list` (not orphaned git metadata —
genuinely still-tracked worktrees). Cross-referencing `claude_code_jobs` in `watson.db`:

| Job id | Branch | Status in `claude_code_jobs` | PR |
|---|---|---|---|
| 40 | `devdispatch/20260820-165623` | done | #33 |
| 41 | `devdispatch/20260820-171920` | done | #34 |
| 42 | `devdispatch/20260824-014848` | done | #50 |
| 43 | `kb-export-download-link` | done | #52 |
| 44 | `devdispatch/20260904-185243` | done | #55 |
| 45 | `devdispatch/20260904-190115` | done | #56 |
| **46** | **`devdispatch/20260905-013815`** | **failed** | **none** |
| 47 | `devdispatch/20260905-020356` | done | #58 |

(Query was `LIMIT 8`, so the two oldest worktrees — `devdispatch+20260807-122742` and
`+20260819-161030` — weren't pulled by job id this pass; both are old enough (Aug 7 and Aug 19) that
they're almost certainly `done`/merged like every other job in this table, but that wasn't directly
re-confirmed here — worth a 2-second check before removing them in step 3 below rather than assuming.)

Job 46 is a **live, current instance of bug #95**: its actual branch is
`docs/cron-resource-sampler-and-utilization-report` (not the derived `worktree-devdispatch+...`
name), and it has 3 real commits pushed to `origin` — confirmed via `git log` — including
`0c6f033 docs: track cron entries for resource_sampler + weekly_utilization_report`, which is
**confirmed not present on `main`** (`git branch --contains 0c6f033` shows only the feature branch).
The intended deliverable (documenting the two `dev/` resource-monitoring cron jobs in
`CRON.md`/`WATSON_ARCHITECTURE.md`) never landed anywhere — confirmed via grep, neither file mentions
`resource_sampler` or `weekly_utilization`. This is real, still-useful work sitting stranded because
the tracker marked it `failed` and nothing has looked at it since.

**Recommended action:**
1. Manually review branch `docs/cron-resource-sampler-and-utilization-report` first — either open a
   PR and merge it, or explicitly decide to discard it. **Do not remove this specific worktree until
   that's resolved.**
2. Once resolved, remove all 10 worktrees (`git worktree remove --force <path>` + `git worktree
   prune`) — the other 9 are confirmed merged (`done` status with a real PR URL each).
3. Implement the prior review's fix #4: add worktree cleanup to `_finalize_completed_job`/
   `merge_claude_code_job` in `jobs/devdispatch/api.py` so this doesn't reaccumulate.

Reclaimable now: ~449MB (9 of 10 dirs). Remaining ~50MB pending step 1.

*Side note, out of scope for this cleanup:* `/home/billyomes/watson-worktrees/trading` is a separate,
unrelated worktree (branch `fix-dupe-selection`) outside `.claude/worktrees/` entirely — not part of
the devdispatch system, not counted above, not evaluated for staleness this pass.

### 3b. MEDIUM — Ad-hoc `.db.bak-<timestamp>` files accumulating with no retention
Found in `data/`, not the real (offsite, per `[[project_backup_system]]`) backup system — these look
like manual pre-change safety snapshots:

- `congregation.db.bak-*` — 6 files, 2026-07-12 through 2026-08-24, 4.8-7.0MB each (~35MB)
- `curator.db.bak-20260721-*` — 2 files, 7.4MB each (~14.8MB)
- `watson.db.bak-*` — 2 files, 3.1-3.4MB (~6.5MB)

~56MB total, oldest nearly 2 months old at scan time, no pruning script found for this specific
pattern. Low absolute size, but pure waste with an easy fix.

**Recommended action:** confirm the real backup system (already verified healthy on both legs per
memory) covers the same data before deleting; if so, prune anything older than ~30 days and add a
retention step to whatever creates these `.bak-*` files so they stop accumulating.

### 3c. MEDIUM — `logs/` = 291MB, 78 files, zero rotation anywhere
Only 6 of 78 log files are older than 30 days by mtime — meaning most of the 291MB is a small number
of files that have been appended to since inception (e.g. `facebook_post.log`, one file per cron job,
growing forever). Confirmed no `logrotate` config exists anywhere in the repo. This will keep growing
unbounded with no cap.

**Recommended action:** standard `logrotate` config for `logs/*.log` — weekly rotation, 8-week
retention (or whatever matches Bill's actual debugging-lookback needs) is the standard fix, currently
completely absent.

### 3d. Flagged, not resolved — `data/servantcare_images` is 866MB, larger than every database combined
This dwarfs every other number in this section — larger than `watson.db` (117MB) + `chroma` (83MB) +
`congregation.db` (7.2MB) + `curator.db` (21MB) combined, several times over. This pass did not have
budget to characterize what governs its growth, whether it's already pruned/archived elsewhere, or
whether any of it is safe to touch. **No action recommended here — flagged only** so it isn't silently
missed as "the actual biggest number on disk" while smaller, easier-to-verify items above get fixed
first.

### 3e. Not flagged (expected, no action)
`venv` (7.2GB) and `data/chroma` (83MB) are expected infrastructure, not cleanup candidates — noted
only for completeness of the disk picture.

---

## 4. Architecture Coherence Check

### 4a. Facebook pipeline — resolved clean, see §1d. No coherence issue; the split is intentional and documented.

### 4b. Kit vs. Brevo — the "5 live write paths" claim is one item stale; 4 are actually still live
Read the real current code for every path named in the brief, rather than trusting either the new
prompt's framing or the older migration memory in isolation:

| Write path | Current reality | Evidence |
|---|---|---|
| **ARC signup** (`jobs/arc/api.py`) | **Still Kit**, live | `_kit_tag_subscriber()` applies Kit tag ID `19285341` via `api.convertkit.com/v3` on every signup. |
| **ARC-interest** (`jobs/arc_interest/api.py`) | **Still Kit**, live | Same tag ID, same v3 endpoint, explicitly by design ("intentionally the same Kit tag as full ARC signups" per its own comment). |
| **Lead-magnet forms** (`jobs/lead_magnet/api.py`) | **NOT Kit — already Brevo** | No Kit write calls found anywhere in the file. `_brevo_tag_subscriber()` + `_get_or_create_brevo_list()` are the only tagging path; `kit_tag_id` only survives as an unused schema column. Matches the 2026-08-22 migration memory exactly — **the new audit's premise is outdated on this one specific item**, not the older memory. |
| **Writing Room onboarding** (`jobs/writing_room/onboard.py`) | **Still Kit**, live | `kit_tag_on_activation()` tags the partner in Kit when they complete verification and go active — the *email itself* goes via Brevo (`send_email` from `brevo_send.py`), but the tag write is Kit. |
| **Givebutter donor sync** (`jobs/givebutter/sync.py` + `bot.py`) | **Still Kit**, live (2 real call sites) | `givebutter/sync.py` creates/writes Kit tags for donors directly. `bot.py`'s `_gb_create_kit_draft()` and `_gb_add_kit_reminder()` are both actually called (`bot.py:3661`, `:3663`) as part of the donor thank-you flow. |

**Net: 4 live Kit write paths remain (ARC, ARC-interest, Writing Room onboarding, Givebutter), not 5**
— lead-magnet already migrated. Comms Desk's general-purpose Brevo dispatch pipeline
(`brevo_dispatcher.py`, `campaigns/dispatch.py`) is the authoritative path for everything it covers;
what's blocking full Kit retirement for the remaining 4 is simply that Phase 4 of the migration
(the deferred cutover work) hasn't been scheduled yet — no new technical blocker found.

**Bonus finding while checking this:** `bot.py`'s `_gb_get_kit_subscriber_id()` (line 197) is
**defined but never called anywhere** — confirmed via grep, only `_gb_create_kit_draft` and
`_gb_add_kit_reminder` have real call sites. This matches the 2026-08-17 memory's "confirmed dead,
delete in Phase 4" list exactly. That same list's other two items — the `/api/kit/subscribe` route in
`jobs/dashboard/app.py` (still present, line 6097) and the `KIT_API_KEY` constant in
`config/settings.py` (still present, line 45) — are also both still sitting in the tree, confirmed
unexecuted. All three are safe, zero-risk deletions whenever Phase 4 actually runs; nothing new
blocks them either.

### 4c. No other rebuilt-in-place-without-retiring cases found
Beyond the two named above, this pass did not surface a third instance of the pattern (a capability
rebuilt in a new location while the old implementation kept running). The email namespaces (§1e) and
research summarizers (§1f) were the closest candidates and neither turned out to be that pattern —
the former is genuinely layered, the latter looks like simple orphaning rather than a rebuild.

---

## Combined Recommended Fix Order

Sequenced for lowest-risk-first, with dependencies respected (e.g. don't clean up worktrees before
resolving the one with real unmerged work):

1. **Resolve devdispatch job #46 / branch `docs/cron-resource-sampler-and-utilization-report`** (§3a) —
   review and merge-or-discard. Blocks the worktree cleanup below and is the only item here with a
   real chance of losing work if ignored.
2. **Delete the 5 dead `jobs/misc/` files** (§1a) — zero risk, immediate.
3. **Remove the 9 resolved devdispatch worktrees + the 10th once #1 clears, `git worktree prune`,
   ship the cleanup-on-finalize fix in `devdispatch/api.py`** (§3a) — ~449-498MB reclaimed, closes
   the bug-#97-resurrection risk (§1c) as a side effect.
4. **Fix `jobs/dashboard/app.py`'s `_update_project_memory()` missing `num_ctx`** (§2a) — one-line
   fix, matches an existing pattern, prevents silent data loss.
5. **Fix `jobs/meet/fireflies_review.py`'s large-transcript prompt to use `size_num_ctx`** (§2d) —
   the one confirmed new num_ctx risk from the broader sweep.
6. **Add `logrotate` for `logs/`** (§3c) — standard hygiene, currently fully absent, unbounded growth.
7. **Resolve `bug_tracker` #119 (router timeout) and #117 (reflect.py ordering)** (§2b/§2c) —
   already-known, already-scoped fixes from the prior review, still open.
8. **Add indexes on `chat_messages`/`llm_call_log`** (§2e) and, separately, on
   `congregation.db.attendance` per the prior review — cheap, no urgency but no reason to defer once
   touching this area.
9. **Diff and consolidate `fix_style.py` vs `fix style.py`, delete the loser** (§1b).
10. **Confirm and archive the 5 `jobs/congregation/migrate_*.py` one-time scripts** (§1g).
11. **Prune the ~56MB of ad-hoc `.db.bak-*` files** (§3b) once confirmed redundant with the real
    backup system, and add retention going forward.
12. **Decide on Phase 4 of the Kit→Brevo migration** (§4b) for the 4 remaining live write paths, and
    delete the 3 already-confirmed-dead Kit artifacts (`/api/kit/subscribe`, `_gb_get_kit_subscriber_id`,
    `KIT_API_KEY` constant) whenever that's scheduled — no new blocker found, purely a scheduling
    decision now.
13. **Confirm `jobs/research/summarizer.py` is truly unused and archive/delete** (§1f) — lowest
    priority, smallest footprint, least certain of the findings in this report.
14. **Characterize `data/servantcare_images` (866MB)** (§3d) — flagged, not analyzed; worth a
    dedicated look given it's larger than every other disk-space finding in this report combined, but
    intentionally left out of this pass's fix order since nothing here confirms it's safe to touch.

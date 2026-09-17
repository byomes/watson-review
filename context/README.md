# watson-review — context drop-zone

This repo is **not** a mirror of `watson`. It's a place to drop one-off,
large, or non-production files — session transcripts, research dumps, log
excerpts — that Bill wants Claude to read in a Claude.ai chat, without
cluttering the production `watson` repo.

## How it works

Files live in `context/` at predictable, dated paths, e.g.:

```
context/2026-09-03-session-transcript.md
context/2026-09-03-audit-log.txt
```

Use `send_context.sh` (repo root) to add a file:

```
./send_context.sh <local_file> [dest_name]
```

It copies the file into `context/` under today's date, commits, pushes, and
prints the raw URL to hand to Claude:

```
https://raw.githubusercontent.com/byomes/watson-review/main/context/<date>-<dest_name>
```

## Not in scope here

- No sync from `watson`'s history — this repo intentionally has none of it.
- No cron, no automation — manual/on-demand only.
- No automatic retention/cleanup — prune `context/` by hand if it grows large.

## One exception: nightly writing digests

`context/<project>-master.md` files (e.g. `context/guardrails-master.md`)
are the one automated thing here. `jobs/writing_digest/nightly_digest.py`
on the Beelink updates them nightly with that book project's current
outline, outstanding items, and work log, then commits and pushes here.

Unlike everything else in this repo, these paths are fixed, not dated.
That's the point: the raw URL never changes, so Bill adds it once to a
project's Claude.ai custom instructions and every future session there
fetches the latest content automatically. Don't delete or rename a
`*-master.md` file without updating `ENABLED_PROJECTS` in that script and
whatever's pasted into the matching Claude.ai project, or the link goes
dead silently.

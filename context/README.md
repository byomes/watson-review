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

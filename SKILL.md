---
name: intercom
description: Turn-by-turn messaging between independent Claude Code sessions via a shared append-only file under ~/.claude/comms/ (each side is woken when the other replies). Use to coordinate, hand off, or hold a back-and-forth with another Claude Code session — e.g. "talk to the other session", "coordinate with the backend session", "open an intercom channel", or when given a channel id to join.
---

# Intercom — inter-session communication

Two independent Claude Code sessions hold a turn-by-turn conversation while each
keeps working. Messages flow through a shared append-only file ("channel"); a
backgrounded watcher wakes you when the other side replies. All ops go through
one script:

```bash
INTERCOM=~/.claude/skills/intercom/intercom.sh
```

Stock bash only, no installs. Same-machine by default; to link **different
machines** both sides set `INTERCOM_DIR` to a shared path. Optional speed-up:
`brew install fswatch` (macOS) / `apt install inotify-tools` (Linux) swaps 2s
polling for instant file events. Setup details live in `README.md`.

## Label: pick one, reuse it

Every command needs `--me <label>` — a short name for THIS session (`backend`,
`frontend`, …; letters/digits/`-`/`_`). Choose once, **reuse it verbatim**.

> ⚠️ The label is your identity: read-state (watermarks) is tracked per-label. A
> typo mints a *new* participant and silently replays all history as unread.
> `read`/`watch` warn on stderr for an unknown label — heed it and fix the typo.

## Start or join

**Start:** `"$INTERCOM" open --me backend --topic "deploy coord"` prints the
channel id plus a `---8<---`-delimited join prompt. Relay that block verbatim to
the user to paste into the other session — that's all the other side needs.

**Join:** the user hands you an id — just start the loop below (no explicit join
step). Run `read` first if you want the existing backlog.

## The conversation loop (every turn)

**Reply and re-arm in one call**, run in the BACKGROUND (Bash tool's
`run_in_background`) so you go straight back to your own work:

```bash
"$INTERCOM" send --me backend --id "$ID" --msg "Migration 0028 applied." --watch
```

`--watch` sends, then re-arms the watcher in the same process — "reply" and "keep
listening" become one action, so there's no re-arm step to forget. It blocks
(backgrounded) until the other side writes, prints their message(s), and exits,
which re-invokes you. Then check the exit code:

- **`0`** — new message(s) printed; act on them, then reply again with `send … --watch`.
- **`10`** — no activity for 1 hour. The watcher waited the whole hour itself (you
  did NOT re-arm during it) and fired a desktop alert. **Alert the user** (surface
  it / call `PushNotification`) and **ask before re-arming** — don't silently
  continue; the other session may be done or away.
- **`20`** — the other side closed the channel; stop, the conversation is over.

Variants:
- Multiline: `printf 'a\nb\n' | "$INTERCOM" send --me backend --id "$ID" - --watch`
- Listen without sending (e.g. right after joining): `"$INTERCOM" watch --me backend --id "$ID"` (backgrounded).
- Read on demand: `"$INTERCOM" read --me backend --id "$ID"`.

## Other commands

```bash
"$INTERCOM" close  --me backend --id "$ID"                        # end; other watcher exits 20
"$INTERCOM" list  [--me backend]                                  # channels + participants (+unread with --me)
"$INTERCOM" status --id "$ID"                                     # read-receipts: per-participant read position
"$INTERCOM" send  --me backend --id "$ID" --json '{"schema":"v2"}'  # validated typed payload
```

- **Read-receipts** (`status`, plus the `recipients read: …` line every `send`
  prints) confirm the other side *saw* a message without an ack turn — they write
  nothing and wake nobody. Retire the handshake: send "LOCKED; object only if you
  disagree", then confirm via `status`. A read *is* the ack.
- **`--json`** validates (rejects malformed) and tags `type:json`, so both sides
  share canonical bytes — no paraphrasing drift. Composes with `--watch`.
- **`list` participants** = opener + senders + anyone watching/reading, so it
  doubles as a presence/roster check.

## How it works (to reason about it)

- **Channel file** `~/.claude/comms/<id>__<lastmod>.txt`, append-only; the
  `__<lastmod>` suffix is rewritten on each write, so change-detection is a cheap glob.
- **Watermark** per-`(label, channel)` under `.state/`: `read`/`watch` surface
  only messages newer than yours and never your own, shown compactly as
  `from#seq: <body>` (`[json]` for typed) — the on-disk `=====` framing is stripped.
- **Attach = now:** a first `watch` starts from the current latest message (only
  future messages surface). Pull history with `read` first.
- **Event-driven** via fswatch/inotifywait when present (one write wakes all
  watchers), else a 2s poll. Writes are serialized by a `mkdir` mutex.

## Gotchas

- **Stop guard:** you may be blocked from ending a turn if you leave a channel
  open with no watcher armed — re-arm (`send … --watch` / `watch`) or `close` it, then stop.
- Override the 1h idle cap with `INTERCOM_WATCH_MAX_SECS`; the comms dir with
  `INTERCOM_DIR` (both sides must agree).

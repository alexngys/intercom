# Intercom — inter-session communication skill

Lets two (or more) independent Claude Code sessions hold a turn-by-turn
conversation while each keeps doing its own work. Sessions exchange messages
through a shared append-only file under `~/.claude/comms/`; a backgrounded
watcher wakes a session the moment the other side replies.

## Why use it?

Run more than one Claude Code session and they're islands — you become the
copy-paste wire between them, relaying "the API is ready", "here's the schema",
"did you finish?" by hand. Intercom removes you from that loop: the sessions
talk to each other directly and keep working while they wait.

- **No human relay.** Sessions coordinate on their own — you stop shuttling
  context between terminals and stop being the bottleneck.
- **Non-blocking.** A session fires a message and goes right back to its own
  task; it's *woken* the instant a reply lands, so nobody sits idle polling.
- **Parallelism that actually cooperates.** Split a job across a `backend` and a
  `frontend` session and let them negotiate the contract in real time instead of
  guessing and re-doing work.
- **Read-receipts, not ack turns.** Each side can *see* the other read a message
  without a wasted "got it" round-trip — hand off a decision and confirm it
  landed, silently.
- **Zero infrastructure.** Stock bash, no daemon, no network, no API keys, no
  installs. It's just files under your home dir; delete them and it's gone.
- **Won't silently drop the ball.** An optional Stop hook blocks a session from
  ending its turn while it still owes the other side a reply.

## What you can do with it

- **Split a feature across sessions** — one builds the backend, one the
  frontend; they agree on the API shape as they go.
- **Hand off work** — a planning session passes a spec to an implementing
  session and waits for "done" before reviewing.
- **Long-running coordination** — a session kicks off a migration/deploy and
  pings another when it's safe to proceed.

---

This README is for the **person installing** the skill. For how a session *uses*
it, see `SKILL.md` (Claude reads that automatically).

---

## Install

**Quickest — clone straight into your skills dir:**

```bash
git clone https://github.com/alexngys/intercom.git ~/.claude/skills/intercom
```

Start a new Claude Code session and it's picked up automatically. To update
later, pull the latest:

```bash
git -C ~/.claude/skills/intercom pull
```

**Or install manually:**

1. **Place the folder** at one of:
   - `~/.claude/skills/intercom/` — personal, available in every session, or
   - `<repo>/.claude/skills/intercom/` — shared with anyone who works in that repo.

2. **Make the script executable:**
   ```bash
   chmod +x ~/.claude/skills/intercom/intercom.sh
   ```

3. **Start a new Claude Code session.** Skills are auto-discovered — no install
   command, no registration, no restart of anything else.

That's the whole setup. The skill creates `~/.claude/comms/` itself on first use.

## Prerequisites

Already present on any stock macOS or Linux — nothing to install:
`bash` (works on macOS's bash 3.2), `date`, `od`, `tr`, `grep`, `sed`, `awk`,
`mkdir`, `mv`, `sleep`. No package manager step, no dependencies, no API keys,
no daemon, no network.

## Optional

- **Faster wake-ups (event-driven instead of 2s polling):**
  ```bash
  brew install fswatch        # macOS
  sudo apt install inotify-tools   # Linux (provides inotifywait)
  ```
  Purely a latency improvement; the skill works without it.

## Scope — important

Sessions coordinate through files in `~/.claude/comms/`, which is **local to one
machine**:

- **Same machine, multiple sessions** → works out of the box.
- **Different machines / people** → point both sides at a shared filesystem:
  ```bash
  export INTERCOM_DIR=/path/to/shared/comms   # set in both sessions, same path
  ```
  A real shared mount (NFS, etc.) is best. Sync folders (Dropbox/iCloud) work but
  add propagation latency, so the back-and-forth lags by the sync delay.

## Environment overrides

| Variable | Default | Purpose |
|---|---|---|
| `INTERCOM_DIR` | `~/.claude/comms` | Where channels live (must match across sessions) |
| `INTERCOM_POLL_SECS` | `2` | Poll interval when no file-watcher is installed |
| `INTERCOM_WATCH_MAX_SECS` | `3600` (60 min) | Idle budget: `watch` waits this long on its own, then fires a desktop alert and exits `10` |
| `GUARD_STALE_MIN` | `60` | Stop-guard only nags about channels touched within this many minutes |

## Optional: the Stop guard (never forget to re-arm)

`intercom-stop-guard.sh` is a Claude Code **Stop hook**. If a session ends a turn
while it's still on an *open* channel with *no watcher armed*, the guard blocks the
stop once and tells the model to re-arm (`send … --watch`) or `close`. Without it,
a forgotten re-arm means you silently stop getting woken.

Wire it in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
        "command": "~/.claude/skills/intercom/intercom-stop-guard.sh" } ] }
    ]
  }
}
```

It is **fail-open**: no label in the transcript, channel closed, a live watcher
exists, the channel is stale (> `GUARD_STALE_MIN`), or `stop_hook_active` is set →
it allows the stop. It never wedges a session and never nags non-intercom work.

## Tests

`./test.sh` — self-contained regression suite (throwaway `INTERCOM_DIR`), covers
every subcommand, all three `watch` exit codes, read-receipts, typed JSON, the
label warning, and all guard branches. Exit 0 = green.

## Quick manual smoke test

```bash
S=~/.claude/skills/intercom/intercom.sh
ID=$("$S" open --me a --topic test | grep -oE '[a-f0-9]{6}-[0-9T]+Z' | head -1)
"$S" send --me a --id "$ID" --msg "hello"
"$S" read --me b --id "$ID"     # should print a's message
"$S" status --id "$ID"          # read-receipts: b caught-up, a behind
"$S" close --me a --id "$ID"
```

## Subcommands

| Command | Purpose |
|---|---|
| `open --me <label> [--topic ...]` | Create a channel; prints its id + a join prompt |
| `send --me <label> --id <id> (--msg ... \| --json ... \| -) [--watch]` | Post a message; `--watch` re-arms the watcher in the same call; `--json` sends a validated typed payload |
| `read --me <label> --id <id>` | Print messages newer than your watermark |
| `watch --me <label> --id <id>` | Block (background) until the other side writes; exits `0`=new msg, `10`=1h idle (alerts user), `20`=closed |
| `status [--me <label>] --id <id>` | Read-receipts: how far each participant has read (no write, no wake) |
| `list [--me <label>]` | All channels + participants; with `--me`, an unread count |
| `close --me <label> --id <id>` | Post a close marker; the other watcher exits `20` |

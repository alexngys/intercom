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
| `INTERCOM_NO_SENTINEL` | unset | Set to `1` to stop `watch` spawning the out-of-session sentinel |
| `INTERCOM_NO_PS` | unset | Set to `1` to silence watcher-liveness warnings (required when the two sides are on different machines) |
| `INTERCOM_SENTINEL_POLL_SECS` | `20` | Sentinel poll interval |
| `INTERCOM_SENTINEL_GRACE_SECS` | `120` | How long an unread message may sit before the sentinel decides nobody is listening |
| `INTERCOM_SENTINEL_RENOTIFY_SECS` | `1800` | Minimum gap between repeat notifications for the same unread message |
| `INTERCOM_SENTINEL_IDLE_SECS` | `7200` | The sentinel stops covering a channel with no writes (or re-registration) for this long |
| `INTERCOM_SENTINEL_MAX_SECS` | `86400` | Sentinel lifetime cap (it is restarted on demand) |
| `INTERCOM_REAP_WINDOW_SECS` | `1800` | How far back watcher kills count toward UNSTABLE |
| `INTERCOM_REAP_FAST_SECS` | `600` | A watcher killed younger than this counts as a fast reap |
| `INTERCOM_REAP_LIMIT` | `2` | Fast reaps within the window that mark a channel UNSTABLE |

## Closing a channel: half-close

`close` is a **FIN**, not a kill switch: it means *"I am done sending"*. You keep
receiving, and the channel only becomes fully closed once every participant has
closed their side. The peer's watcher reports a half-close as exit `21` (still
live) versus `20` for a full close (over).

```
  A: close          →  closing-by: A       B's watcher exits 21, B may still send
  B: close          →  closing-by: B       → --- CHANNEL CLOSED ---, both exit 20
  A: close --force  →  hard close now, for a peer that is gone
```

`send` into a fully closed channel fails rather than appending bytes nobody will
read. Sending after your own half-close retracts it (`reopen-by:`).

## The sentinel (why a watcher dying stops mattering)

`watch` runs as a background child of Claude Code, and the harness reaps it —
across real sessions, 119 of 131 watcher deaths were external kills, at a median
of 29 minutes into a 60-minute budget. The reap lands during the idle stretch
*after* a turn ends, so the Stop guard has already run and no further Stop fires:
nothing in the session can notice, and the channel just goes quiet.

So every `watch` (and every Stop-guard pass) also spawns a **sentinel**: a
double-forked, `setsid`'d process that lives outside the session and survives the
reap. It cannot wake the model — only a completing background task does that — so
when a message sits unread with no watcher armed, it fires a desktop notification
at the human instead. It is a pure observer: it never advances a watermark, never
writes to the channel.

There is **one sentinel per machine** (per `INTERCOM_DIR`), not one per channel.
Every process costs about 1 MB even when it does nothing, so a sentinel for each
channel was wasted memory. `watch` and the Stop guard add the channel to the
sentinel's list under `.state/.sentinel/`, starting the sentinel if it isn't
running. The sentinel drops a channel once it closes or has been idle for
`INTERCOM_SENTINEL_IDLE_SECS`, and exits when its list is empty. With no live
conversations, intercom runs no processes at all.

Complementing it, `send` warns (and notifies) when the peer has no watcher armed,
so a message is never left waiting on a session that cannot hear it.

### Watchers that keep dying

Under memory pressure a watcher can be killed seconds after it is armed, every
time. Each watcher leaves an arm record under `.state/`. A clean exit removes it.
A SIGTERM is logged by the watcher itself on the way out. A SIGKILL leaves the
record, and the next scan (by the sentinel, `status`, the next `watch`, or the
Stop guard) logs it. Both kinds land in `<id>.reaps`. When enough kills come
soon after arming, the channel is **UNSTABLE**: `status` says so, a new `watch`
warns that it probably won't survive, and the Stop guard stops asking for a
re-arm that can't hold. The sentinel's notification is then the delivery path.

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

On an UNSTABLE channel (watchers keep being killed soon after arming) it also
allows the stop, and shows the user a `systemMessage` explaining that the session
won't be woken and the sentinel will notify them. Otherwise the guard would
loop: arm → killed → blocked → arm.

## Tests

`./test.sh` — self-contained regression suite (throwaway `INTERCOM_DIR`), covers
every subcommand, all four `watch` exit codes, the half-close protocol, close
never stranding a final message, read-receipts, typed JSON, the label warning,
sentinel detachment, reap tracking (clean exit / SIGTERM / SIGKILL / UNSTABLE),
and all guard branches. Exit 0 = green.

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
| `read --me <label> --id <id>` | Print messages newer than your watermark, and advance it |
| `tail --id <id> [-n N] [--me <label>]` | Raw last-N messages straight from the log — every message, ignores/touches no watermark; recovery / source-of-truth view |
| `watch --me <label> --id <id>` | Block (background) until the other side writes; a **doorbell** — shows new messages but does not advance your watermark. Exits `0`=new msg, `10`=1h idle (alerts user), `20`=fully closed, `21`=peer half-closed. Also arms the sentinel |
| `sentinel [--me <label> --id <id>] [--spawn]` | The machine's out-of-session watchdog. `--spawn` adds the channel to its list and starts it (detached) if needed; without `--spawn` it runs in the foreground. It notifies the human when a message is unread with no watcher armed |
| `status [--me <label>] --id <id>` | Read-receipts: how far each participant has read, who is done sending, whether any watcher is armed, and recent watcher kills / UNSTABLE (no write, no wake) |
| `health --me <label> --id <id>` | Machine-readable `key=value` watcher/reap state (what the Stop guard reads) |
| `list [--me <label>]` | All channels + participants; with `--me`, an unread count. Marks `[half]` for half-closed |
| `close --me <label> --id <id> [--force]` | Half-close: "done sending", peer's watcher exits `21`. Full close once all sides have. `--force` hard-closes now |

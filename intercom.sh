#!/usr/bin/env bash
#
# intercom.sh — inter-team communication channel for Claude Code sessions.
#
# Two independent sessions hold a turn-by-turn conversation through a shared,
# append-only file under ~/.claude/comms/. Each session keeps doing its own work
# and is re-invoked (via a backgrounded `watch`) when the other side replies.
#
# Subcommands: open | send | read | tail | watch | sentinel | status | list | close
# See SKILL.md for usage from a Claude Code session.

set -euo pipefail

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
COMMS_DIR="${INTERCOM_DIR:-$HOME/.claude/comms}"
STATE_DIR="$COMMS_DIR/.state"
LOCK_DIR="$COMMS_DIR/.locks"

WATCH_POLL_SECS="${INTERCOM_POLL_SECS:-2}"      # how often watch re-globs
WATCH_MAX_SECS="${INTERCOM_WATCH_MAX_SECS:-3600}" # 60 min idle, then exit 10 (alert user)

# Exit codes used by `watch` (SKILL.md depends on these):
EX_NEW=0      # new messages from the other side were printed
EX_TIMEOUT=10 # no activity for the full idle budget; caller should ALERT the user
EX_CLOSED=20  # channel is fully closed (every side FIN'd, or a --force close); stop
EX_FIN=21     # the other side half-closed (done sending, still receiving); you may still send

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
die() { echo "intercom: $*" >&2; exit 1; }

now_utc() { date -u +%Y%m%dT%H%M%SZ; }

# Best-effort desktop alert to the human. Used when `watch` hits its idle
# budget: the backgrounded watcher can't print to the user directly, so we fire
# an OS notification that surfaces even while the session is doing other work.
# Keep args free of double quotes (osascript is quote-sensitive).
alert_user() {
  local title="$1" body="$2"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$body\" with title \"$title\" sound name \"Submarine\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$body" >/dev/null 2>&1 || true
  fi
  printf '\a' >&2   # terminal bell fallback
}

ensure_dirs() { mkdir -p "$COMMS_DIR" "$STATE_DIR" "$LOCK_DIR"; }

# Resolve the current on-disk filename for a channel id (glob on the mutable
# __<lastmod> suffix). Prints the full path, or empty if not found.
channel_path() {
  local id="$1"
  local matches=( "$COMMS_DIR/${id}__"*.txt )
  # If the glob didn't match, bash leaves the literal pattern in place.
  if [[ -e "${matches[0]:-}" ]]; then
    printf '%s\n' "${matches[0]}"
  fi
}

require_channel() {
  local id="$1" p
  p="$(channel_path "$id")"
  [[ -n "$p" ]] || die "no channel found for id '$id'"
  printf '%s\n' "$p"
}

# Portable mutex via mkdir (macOS ships no flock). Auto-released on exit.
acquire_lock() {
  local id="$1"
  local lock="$LOCK_DIR/$id"
  local waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    # Steal a stale lock after ~30s so a crashed session can't wedge a channel.
    if (( waited > 300 )); then
      rmdir "$lock" 2>/dev/null || true
    fi
  done
  # shellcheck disable=SC2064
  trap "rmdir '$lock' 2>/dev/null || true" EXIT
}

# Release a held lock early (e.g. so `send --watch` doesn't hold it while it
# blocks in the watch loop, which would wedge the other side's sends).
release_lock() {
  rmdir "$LOCK_DIR/$1" 2>/dev/null || true
  trap - EXIT
}

# Highest MSG seq currently in a channel file (0 if none).
max_seq() {
  local path="$1"
  grep -Eo '^===== MSG [0-9]+ ' "$path" 2>/dev/null \
    | grep -Eo '[0-9]+' | sort -n | tail -1 || true
}

# Author (from:<label>) of the highest-seq message, or empty.
last_author() {
  local path="$1"
  grep -E '^===== MSG [0-9]+ \| from:' "$path" 2>/dev/null \
    | tail -1 | sed -E 's/.*from:([^ ]+).*/\1/' || true
}

# Label that FULLY closed the channel (`closed-by:`), or empty while it's open.
# A full close means every participant has half-closed, or someone used --force.
closed_by() {
  local path="$1"
  grep -m1 '^closed-by: ' "$path" 2>/dev/null | sed 's/^closed-by: //' || true
}

# Labels currently half-closed ("FIN": done sending, still receiving). The log is
# append-only, so a retraction is a later `reopen-by:` line rather than an edit —
# a side that half-closed and then sends again reopens its half automatically.
fin_labels() {
  local path="$1"
  awk '
    /^closing-by: / { l = $2; if (!(l in seen)) { seen[l] = 1; order[++n] = l }; state[l] = "fin" }
    /^reopen-by: /  { l = $2; state[l] = "open" }
    END { for (i = 1; i <= n; i++) if (state[order[i]] == "fin") print order[i] }
  ' "$path" 2>/dev/null || true
}

has_fin() { fin_labels "$1" | grep -qxF "$2"; }

# Everyone except me who has half-closed, comma-joined (empty if none).
peer_fins() {
  local path="$1" me="$2"
  fin_labels "$path" | grep -vxF "$me" | paste -sd, - || true
}

# Is a `watch` alive for this channel on THIS machine (excluding my own process)?
# Same probe the Stop guard uses. Cross-machine setups have no visibility into
# the peer's process table — set INTERCOM_NO_PS=1 there to silence the warning.
watcher_alive() {
  local id="$1" pid args
  [[ -n "${INTERCOM_NO_PS:-}" ]] && return 0
  while read -r pid args; do
    [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
    [[ "$args" == *intercom.sh* && "$args" == *"$id"* && "$args" != *sentinel* ]] || continue
    [[ "$args" == *" watch "* || "$args" == *" watch" || "$args" == *--watch* ]] && return 0
  done < <(ps -Ao pid=,args= 2>/dev/null)
  return 1
}

# Distinct participant labels in a channel: the opener, every message sender, AND
# anyone who has read/watched (they own a per-label watermark under .state). The
# last part is what lets a pure reader — who never sends — still show up for
# presence and read-receipts. Derived from disk, so it can't drift from reality.
participants() {
  local path="$1" id wf
  id="$(basename "$path")"; id="${id%%__*}"
  {
    grep -m1 '^opened-by: ' "$path" 2>/dev/null | sed 's/^opened-by: //'
    grep -E '^===== MSG [0-9]+ \| from:' "$path" 2>/dev/null \
      | sed -E 's/.*from:([^ ]+).*/\1/'
    for wf in "$STATE_DIR"/*/"$id"; do
      [[ -e "$wf" ]] && basename "$(dirname "$wf")"
    done
  } 2>/dev/null | grep -v '^$' | sort -u || true   # never fail (empty channel -> no rows)
}

# Warn (never fail) when --me is a brand-new label on a channel that already has
# participants — the classic typo footgun: a new label silently forks its own
# per-label watermark and replays the whole history as "unread". Read/watch only.
warn_new_label() {
  [[ -n "${_WARNED_LABEL:-}" ]] && return 0   # at most once per process (watch calls read)
  local label="$1" path="$2" known
  known="$(participants "$path")"
  [[ -z "$known" ]] && return 0
  grep -qxF "$label" <<<"$known" && return 0
  _WARNED_LABEL=1
  {
    echo "intercom: WARNING — label '$label' is new to this channel."
    echo "intercom:   known participants: $(printf '%s' "$known" | paste -sd, -)"
    echo "intercom:   if that's a typo, your watermark resets and history replays. Reuse your existing label."
  } >&2
}

# Compact read-receipt for the OTHER participants: how far each has read vs the
# latest seq. Pure pull from per-label watermarks in .state — no channel-file
# write (the log stays append-only) and no wake cycle burned. Prints one line,
# or nothing if nobody else has joined yet.
receipts_line() {
  local path="$1" me="$2" top="$3" p wm out=""
  while IFS= read -r p; do
    [[ -z "$p" || "$p" == "$me" ]] && continue
    wm="$(get_watermark "$p" "$ID")"; (( wm > top )) && wm=$top
    out+="${out:+, }$p $wm/$top"
  done <<< "$(participants "$path")"
  if [[ -n "$out" ]]; then echo "recipients read: $out"; fi
}

watermark_file() {
  local label="$1" id="$2"
  printf '%s\n' "$STATE_DIR/$label/$id"
}

get_watermark() {
  local wf; wf="$(watermark_file "$1" "$2")"
  [[ -f "$wf" ]] && cat "$wf" || echo 0
}

set_watermark() {
  local label="$1" id="$2" seq="$3" wf
  wf="$(watermark_file "$label" "$id")"
  mkdir -p "$(dirname "$wf")"
  printf '%s\n' "$seq" > "$wf"
}

# Delivery marker: the highest seq a `--peek` has PRINTED. Distinct from the
# watermark (the durable "I've seen it" ACK) — a peek delivers without acking, so
# on its own the watermark cannot tell "the watcher showed me this but I haven't
# acked it" from "this arrived and nobody has ever seen it". `send` needs exactly
# that distinction to know whether its ack would swallow something (see cmd_send).
# Residual window, much narrower than the bug it fixes: if a peek is SIGTERMed
# between printing and this write, delivery is recorded for output that was lost.
# The watermark still hasn't moved in that case, so `read`/`tail` re-delivers.
delivered_file() { printf '%s\n' "$STATE_DIR/$1/$2.peek"; }

get_delivered() {
  local df; df="$(delivered_file "$1" "$2")"
  [[ -f "$df" ]] && cat "$df" || echo 0
}

set_delivered() {
  local df; df="$(delivered_file "$1" "$2")"
  mkdir -p "$(dirname "$df")"
  printf '%s\n' "$3" > "$df"
}

# Highest seq I've been shown by ANY route — the durable ack or a peek's
# delivery. What "unread" means for the sentinel and for close's unread warning.
shown_seq() {
  local wm del
  wm="$(get_watermark "$1" "$2")"; del="$(get_delivered "$1" "$2")"
  (( wm > del )) && printf '%s\n' "$wm" || printf '%s\n' "$del"
}

# Which peer FINs I've already been told about, so a re-armed watcher doesn't
# exit 21 on every poll for a half-close it already reported (that would spin the
# session: wake, re-arm, wake, …). Suffixed files never collide with the bare
# `<id>` watermark that `participants` globs for.
fin_ackfile() { printf '%s\n' "$STATE_DIR/$1/$2.fin"; }

# Sentinel bookkeeping. All suffixed, all outside the watermark namespace.
sentinel_pidfile()  { printf '%s\n' "$STATE_DIR/$1/$2.sentinel.pid"; }
sentinel_logfile()  { printf '%s\n' "$STATE_DIR/$1/$2.sentinel.log"; }

sentinel_running() {
  local pf pid; pf="$(sentinel_pidfile "$1" "$2")"
  [[ -f "$pf" ]] || return 1
  pid="$(cat "$pf" 2>/dev/null)"; [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# Highest seq NOT from $2 — the newest INBOUND message. The watcher used to gate
# on the last message's author instead, which goes blind whenever my own message
# is last (exactly the crossed-write case) even though older inbound messages sit
# unread above my watermark.
max_inbound_seq() {
  local path="$1" me="$2"
  grep -E '^===== MSG [0-9]+ \| from:' "$path" 2>/dev/null \
    | grep -vF "| from:$me |" \
    | grep -Eo '^===== MSG [0-9]+' | grep -Eo '[0-9]+' | sort -n | tail -1 || true
}

# Rename a channel file so its __<lastmod> suffix reflects "now".
touch_stamp() {
  local path="$1" id="$2"
  local newpath="$COMMS_DIR/${id}__$(now_utc).txt"
  if [[ "$path" != "$newpath" ]]; then
    mv -f "$path" "$newpath"
  fi
  printf '%s\n' "$newpath"
}

# ----------------------------------------------------------------------------
# Arg parsing (shared)
# ----------------------------------------------------------------------------
ME="" ; ID="" ; TOPIC="" ; MSG="" ; JSON="" ; READ_STDIN=0 ; WATCH_AFTER=0
PEEK=0 ; TAIL_N=20 ; FORCE=0 ; SPAWN=0
parse_args() {
  while (( $# )); do
    case "$1" in
      --me)    ME="$2"; shift 2 ;;
      --id)    ID="$2"; shift 2 ;;
      --topic) TOPIC="$2"; shift 2 ;;
      --msg)   MSG="$2"; shift 2 ;;
      --json)  JSON="$2"; shift 2 ;;
      --watch) WATCH_AFTER=1; shift ;;
      --peek)  PEEK=1; shift ;;        # print without advancing the watermark
      --force) FORCE=1; shift ;;       # close: hard-close both sides (dead peer)
      --spawn) SPAWN=1; shift ;;       # sentinel: detach and return immediately
      -n)      TAIL_N="$2"; shift 2 ;; # tail: how many recent messages to show
      -)       READ_STDIN=1; shift ;;
      *)       die "unknown argument: $1" ;;
    esac
  done
}

valid_label() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || die "label must match [A-Za-z0-9_-]+ (got '$1')"
}

# Validate a JSON payload. Real check via python3 or jq; if neither exists, skip
# with a one-line note rather than silently pretending or hard-failing.
validate_json() {
  local s="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$s" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$s" | jq -e . >/dev/null 2>&1
  else
    echo "intercom: note — no python3/jq available to validate --json; sending as-is." >&2
    return 0
  fi
}

# ----------------------------------------------------------------------------
# Subcommands
# ----------------------------------------------------------------------------
cmd_open() {
  parse_args "$@"
  [[ -n "$ME" ]] || die "open requires --me <label>"
  valid_label "$ME"
  ensure_dirs

  local rand created id path
  # 3 random bytes -> 6 hex chars. (Reading a fixed count avoids the SIGPIPE
  # that `tr </dev/urandom | head` triggers under pipefail.)
  rand="$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  created="$(now_utc)"
  id="${rand}-${created}"
  path="$COMMS_DIR/${id}__${created}.txt"

  {
    echo "===== CHANNEL $id ====="
    echo "topic: ${TOPIC:-(none)}"
    echo "opened-by: $ME"
    echo "opened-at: $created"
    echo "======================"
    echo
  } > "$path"

  set_watermark "$ME" "$id" 0
  echo "Channel opened. id: $id"
  echo
  echo "Paste this prompt into the OTHER Claude Code session to connect it:"
  echo "---8<------------------------------------------------------------"
  echo "Use the intercom skill to join channel $id. Pick a short label for"
  echo "yourself (e.g. session-B), read the waiting message, reply to it, then"
  echo "arm \`watch\` in the background and keep the conversation going until the"
  echo "channel is closed. Don't close early: close only once nothing is outstanding"
  echo "on either side and the other session has confirmed it has no follow-ups."
  echo "------------------------------------------------------------>8---"
}

cmd_send() {
  parse_args "$@"
  [[ -n "$ME" ]] || die "send requires --me <label>"
  [[ -n "$ID" ]] || die "send requires --id <id>"
  valid_label "$ME"

  if (( READ_STDIN )); then
    MSG="$(cat)"
  fi

  # --json <payload>: send a typed, validated message. Both sides then share the
  # exact same canonical bytes (no re-typing a schema to "confirm" it).
  local type=""
  if [[ -n "$JSON" ]]; then
    validate_json "$JSON" || die "--json payload is not valid JSON"
    MSG="$JSON"; type="json"
  fi
  [[ -n "$MSG" ]] || die "send requires --msg \"...\", --json '...', or - (stdin)"

  acquire_lock "$ID"
  local path; path="$(require_channel "$ID")"

  # A CLOSED channel is write-dead. `send` used to append happily past the close
  # marker: the bytes landed on disk, the peer's watcher had already exited 20 and
  # nobody was ever coming back to read them. Fail loudly instead of writing into
  # a void — the caller can reopen a fresh channel.
  local closer; closer="$(closed_by "$path")"
  [[ -n "$closer" ]] && die "channel $ID is CLOSED (by $closer) — nothing sent. Messages appended after a close are never delivered; open a new channel."

  # I half-closed earlier and I'm sending again: retract my FIN. Append-only, so
  # the retraction is a new line rather than an edit.
  if has_fin "$path" "$ME"; then
    { echo "reopen-by: $ME"; echo "reopen-at: $(now_utc)"; echo; } >> "$path"
    echo "[intercom] note — you had half-closed your side; sending reopens it."
  fi
  local pfins; pfins="$(peer_fins "$path" "$ME")"
  [[ -n "$pfins" ]] && echo "[intercom] note — $pfins already said they're done sending (half-closed); they still receive this."

  # CROSSED WRITE. A message can land between my last read and this send — most
  # often while I'm composing this very reply, when no watcher is armed (the
  # watcher exits the moment it delivers). The ack at the bottom of this function
  # sets my watermark to MY seq, which is always the highest in the file, so an
  # inbound message nobody has shown me gets marked read having never been seen:
  # `read` then reports "no new messages" while `tail` still holds it. Silent and
  # permanent. This is the last instant we can still catch it, so surface it here
  # — in the send's own foreground output, which the harness captures reliably —
  # and only then let the ack proceed.
  local pre_wm pre_del pre_shown pre_inbound
  pre_wm="$(get_watermark "$ME" "$ID")"
  pre_del="$(get_delivered "$ME" "$ID")"
  pre_shown=$(( pre_wm > pre_del ? pre_wm : pre_del ))
  pre_inbound="$(max_inbound_seq "$path" "$ME")"; pre_inbound="${pre_inbound:-0}"
  if (( pre_inbound > pre_shown )); then
    echo "[intercom] ⚠ CROSSED WRITE on $ID — inbound message(s) you have never been shown:"
    cmd_read --me "$ME" --id "$ID" --peek
    echo "[intercom] ↑ the above crossed with the message you are sending. Your send acks them,"
    echo "[intercom] so read them now and follow up if your message did not take them into account."
  fi

  local seq; seq=$(( $(max_seq "$path") + 1 ))
  local ts; ts="$(now_utc)"
  {
    echo "===== MSG $seq | from:$ME | ts:$ts${type:+ | type:$type} ====="
    printf '%s\n' "$MSG"
    echo "===== END $seq ====="
    echo
  } >> "$path"

  path="$(touch_stamp "$path" "$ID")"
  # Advance my own watermark so I never re-read my own message.
  set_watermark "$ME" "$ID" "$seq"
  release_lock "$ID"                   # done writing — don't hold the lock past here
  echo "sent MSG $seq on $ID"
  receipts_line "$path" "$ME" "$seq"   # who's read up to where (append-only-safe pull)

  # PEER LIVENESS. The other side's watcher is a background child of THEIR Claude
  # Code process, and the harness reaps it on idle — after their Stop hook has
  # already run and passed, so nothing on their side can notice it died. A send
  # into a channel with no armed watcher therefore vanishes silently. This is the
  # last point where a human is still in the loop, so check here and escalate.
  if ! watcher_alive "$ID"; then
    local others; others="$(participants "$path" | grep -vxF "$ME" | paste -sd, - || true)"
    if [[ -n "$others" ]]; then
      echo "[intercom] ⚠ no live watcher for $ID on this machine — $others will NOT be woken by this message."
      echo "[intercom]   Their watcher was most likely reaped. The message is safe on disk (\`read\`/\`tail\` still has it),"
      echo "[intercom]   but that session needs a poke before it will see anything. Tell the user."
      alert_user "intercom: nobody listening on $ID" "MSG $seq sent but no watcher is armed - $others will not wake."
    else
      echo "[intercom] note — nobody has joined $ID yet; this message waits until they do."
    fi
  fi

  # --watch: re-arm the watcher in the same process, so "reply" and "keep
  # listening" are one atomic action — no separate re-arm step to forget.
  if (( WATCH_AFTER )); then
    valid_label "$ME"
    cmd_watch --me "$ME" --id "$ID"
  fi
}

# Print messages with seq > watermark and from != me; advance the watermark
# UNLESS --peek. The watermark (a durable file under .state/) is the "I've seen
# this" ACK; stdout is the ephemeral delivery. A backgrounded watcher can be
# SIGTERMed at a turn boundary AFTER it advanced the watermark but BEFORE its
# stdout reached the model — durable ACK, lost delivery => the message is
# swallowed forever. So the killable watcher path reads with --peek (delivers,
# never ACKs); the watermark only advances in a foreground `read` (whose output
# the harness reliably captures) or when you `send` a reply (which advances your
# watermark past everything inbound). Losing a --peek's output costs nothing:
# the watermark hasn't moved, so `read`/`tail` re-delivers.
cmd_read() {
  parse_args "$@"
  [[ -n "$ME" ]] || die "read requires --me <label>"
  [[ -n "$ID" ]] || die "read requires --id <id>"

  local path; path="$(require_channel "$ID")"
  warn_new_label "$ME" "$path"
  local wm; wm="$(get_watermark "$ME" "$ID")"
  local top; top="$(max_seq "$path")"; top="${top:-0}"

  if (( top <= wm )); then
    echo "(no new messages; watermark=$wm)"
    return 0
  fi

  # Compact display: keep the on-disk framing for parsing, but show the model
  # only "from#seq: <body>" (drop the ===== frames and ts — pure token overhead).
  awk -v wm="$wm" -v me="$ME" '
    /^===== MSG [0-9]+ \| from:/ {
      seq = $3
      from = $5; sub(/^from:/, "", from)
      typ = ""
      for (i = 6; i <= NF; i++) if ($i ~ /^type:/) { typ = $i; sub(/^type:/, "", typ) }
      printing = (seq + 0 > wm && from != me)
      if (printing) print from "#" seq (typ == "" ? "" : " [" typ "]") ":"
      next
    }
    /^===== END [0-9]+ =====/ { if (printing) print ""; printing = 0; next }
    { if (printing) print }
  ' "$path"

  if (( PEEK )); then
    set_delivered "$ME" "$ID" "$top"      # shown, deliberately NOT acked
  else
    set_watermark "$ME" "$ID" "$top"      # foreground read: output is reliably captured, so ack
  fi
}

# Raw recovery view: print the last -n messages (default 20) straight from the
# append-only channel file — EVERY message, from anyone, regardless of any
# watermark, and touching NO state (no read, no write, no wake). This is the
# source of truth: because `watch`/`read` can never hide a message from it, run
# `tail` after a watcher dies (exit 143/144 or an empty "no new messages") to
# confirm nothing was swallowed. Own messages are shown too, so it doubles as a
# full transcript. --me is optional and only used to tag "[you]".
cmd_tail() {
  parse_args "$@"
  [[ -n "$ID" ]] || die "tail requires --id <id>"
  local path; path="$(require_channel "$ID")"
  local top closer
  top="$(max_seq "$path")"; top="${top:-0}"
  closer="$(closed_by "$path")"
  echo "channel $ID | latest:seq $top | showing last $TAIL_N${closer:+ | CLOSED by $closer}"
  awk -v n="$TAIL_N" -v me="$ME" '
    /^===== MSG [0-9]+ \| from:/ {
      c++; seq[c] = $3
      f = $5; sub(/^from:/, "", f); frm[c] = f
      typ[c] = ""
      for (i = 6; i <= NF; i++) if ($i ~ /^type:/) { t = $i; sub(/^type:/, "", t); typ[c] = t }
      body[c] = ""; inblk = 1; next
    }
    /^===== END [0-9]+ =====/ { inblk = 0; next }
    { if (inblk) body[c] = body[c] $0 "\n" }
    END {
      if (c == 0) { print "(no messages yet)"; exit }
      start = c - n + 1; if (start < 1) start = 1
      for (i = start; i <= c; i++) {
        you = (me != "" && frm[i] == me) ? " [you]" : ""
        print frm[i] "#" seq[i] (typ[i] == "" ? "" : " [" typ[i] "]") you ":"
        printf "%s", body[i]; print ""
      }
    }
  ' "$path"
}

# Block until the comms dir changes or `timeout` secs elapse.
# Returns: 0 = change detected, 1 = timed out, 2 = no event tool (poll instead).
# Uses kernel file events (fswatch/inotifywait) when available — this is the
# "event-driven" path: the rename done by a writer wakes every listener, so a
# single write broadcasts to all sessions watching the channel, no polling.
wait_for_change() {
  local timeout="$1"
  (( timeout > 0 )) || return 1
  if command -v fswatch >/dev/null 2>&1; then
    local wpid tpid rc=0
    fswatch -1 "$COMMS_DIR" >/dev/null 2>&1 & wpid=$!
    ( sleep "$timeout"; kill "$wpid" 2>/dev/null ) & tpid=$!
    wait "$wpid" 2>/dev/null || rc=1
    # Always reap the timer child, on EVERY path. Orphaned, it inherits our
    # stdout and holds a backgrounded watcher's pipe open for the whole timeout
    # after this process is gone — the caller sees a watcher that looks alive for
    # an hour after it died, and we leak one `sleep` per failed iteration.
    kill "$tpid" 2>/dev/null || true
    wait "$tpid" 2>/dev/null || true
    return $rc
  elif command -v inotifywait >/dev/null 2>&1; then
    inotifywait -q -t "$timeout" -e create,moved_to,modify,close_write \
      "$COMMS_DIR" >/dev/null 2>&1 && return 0 || return 1
  fi
  return 2
}

# Re-check the channel after a wakeup; exits the process if there's something
# actionable (new inbound messages or a close). $SEEN_STAMP persists the last
# filename stamp we observed so our own writes / noise don't re-trigger.
_watch_check() {
  local path cur_stamp wm
  path="$(channel_path "$ID")"
  [[ -n "$path" ]] || die "channel '$ID' disappeared"
  # Deliberately NO early-return on an unchanged filename stamp. The __<lastmod>
  # suffix has 1-second granularity and touch_stamp skips the rename when the new
  # name equals the old one, so two writes in the same second leave the filename
  # byte-identical — a stamp gate then goes blind until some LATER write happens
  # to bump it, which on a "your turn now" pause is never, and the watcher sits
  # out its whole idle budget with a message already on disk. Re-derive the real
  # state from the file instead; three greps every couple of seconds is nothing.
  cur_stamp="$(basename "$path")"
  SEEN_STAMP="$cur_stamp"

  wm="$(get_watermark "$ME" "$ID")"

  local closer inbound pfins ackf
  closer="$(closed_by "$path")"
  pfins="$(peer_fins "$path" "$ME")"
  inbound="$(max_inbound_seq "$path" "$ME")"; inbound="${inbound:-0}"

  # DRAIN BEFORE REPORTING A CLOSE. The close check used to run first and exit
  # immediately, so a message written just before a close was never printed — the
  # watcher woke, saw `closed-by:`, and the caller stopped on exit 20 with the
  # final message still sitting unshown on disk. That is not rare: across 63
  # closed channels, 42 stranded their last message exactly this way. Deliver
  # first, then report the close in the SAME output, so exit 20/21 always carries
  # whatever was said on the way out.
  if (( inbound > wm )); then
    echo "[intercom] new on $ID:"       # per-message "from#seq:" carries the rest
    cmd_read --me "$ME" --id "$ID" --peek   # doorbell: deliver, but DON'T advance
    echo "[intercom] (shown via watcher; watermark unchanged — your reply's \`send\` acks it, or run \`read\`/\`tail\` if this output was truncated)"
    if [[ -n "$closer" ]]; then
      echo "[intercom] ⚠ channel $ID is CLOSED (by $closer) — the above is the FINAL delivery. You cannot reply; \`read\` to ack, then stop."
      exit $EX_CLOSED
    fi
    if [[ -n "$pfins" ]]; then
      ackf="$(fin_ackfile "$ME" "$ID")"; mkdir -p "$(dirname "$ackf")"
      printf '%s\n' "$pfins" > "$ackf"
      echo "[intercom] $pfins has half-closed $ID (done sending, still receiving) — reply if you still need them, then \`close\` your side."
      exit $EX_FIN
    fi
    exit $EX_NEW
  fi

  # Fully closed with nothing left to deliver: the conversation is over.
  if [[ -n "$closer" ]]; then
    echo "[intercom] channel $ID closed by ${closer:-?}"
    exit $EX_CLOSED
  fi

  # Peer half-closed and I have nothing unread. Report it ONCE — re-arming after a
  # half-close must not exit 21 on every poll, or the session spins on wake/re-arm.
  if [[ -n "$pfins" ]]; then
    ackf="$(fin_ackfile "$ME" "$ID")"
    if [[ "$(cat "$ackf" 2>/dev/null || true)" != "$pfins" ]]; then
      mkdir -p "$(dirname "$ackf")"; printf '%s\n' "$pfins" > "$ackf"
      echo "[intercom] $pfins half-closed $ID (done sending, still receiving)."
      echo "[intercom] Send anything still outstanding; \`close\` your side when done (that ends the channel)."
      exit $EX_FIN
    fi
  fi
  return 0
}

cmd_watch() {
  parse_args "$@"
  [[ -n "$ME" ]] || die "watch requires --me <label>"
  [[ -n "$ID" ]] || die "watch requires --id <id>"
  valid_label "$ME"

  local path; path="$(require_channel "$ID")"
  warn_new_label "$ME" "$path"
  # First-time attach: seed the watermark at the CURRENT top, so a session that
  # only watches surfaces just messages that arrive from here on — no surprise
  # full-backlog dump. (To pull existing history, run `read` first; the join
  # prompt tells joiners to. A returning watcher keeps its own watermark.)
  if [[ ! -f "$(watermark_file "$ME" "$ID")" ]]; then
    local seed; seed="$(max_seq "$path")"; set_watermark "$ME" "$ID" "${seed:-0}"
  fi

  # Arm the out-of-session safety net alongside every watcher. This process is
  # the one that gets reaped; the sentinel is what still notices afterwards.
  [[ -z "${INTERCOM_NO_SENTINEL:-}" ]] && spawn_sentinel "$ME" "$ID"

  SEEN_STAMP="$(basename "$path")"
  local mode="poll" elapsed=0 rc
  command -v fswatch >/dev/null 2>&1 && mode="event"
  command -v inotifywait >/dev/null 2>&1 && mode="event"
  [[ "$mode" == "event" ]] && echo "[intercom] watching $ID (event-driven)" \
                            || echo "[intercom] watching $ID (polling every ${WATCH_POLL_SECS}s)"

  SECONDS=0
  while true; do
    if [[ "$mode" == "event" ]]; then
      # `rc=$?` on its own line would be too late: under `set -e` a non-zero
      # return from a bare simple command kills the shell before the assignment
      # ever runs. That made every event-mode timeout (and any fswatch hiccup)
      # exit 1 SILENTLY — no idle alert, no EX_TIMEOUT, and the rc==2
      # degrade-to-polling branch below was unreachable dead code.
      rc=0; wait_for_change "$(( WATCH_MAX_SECS - SECONDS ))" || rc=$?
      if (( rc == 2 )); then mode="poll"; continue; fi   # tool vanished; degrade
      # A working event tool returns non-zero only when OUR timer killed it, i.e.
      # the budget is spent. Non-zero while time is left means the tool itself
      # failed (couldn't start, hit a descriptor limit, watched dir replaced) —
      # that is not an idle conversation, so don't fire the "nobody replied for
      # an hour" alert. Fall back to polling and keep the channel alive.
      if (( rc == 1 && SECONDS < WATCH_MAX_SECS )); then mode="poll"; continue; fi
      _watch_check
      if (( SECONDS >= WATCH_MAX_SECS )); then rc=1; fi
    else
      sleep "$WATCH_POLL_SECS"
      elapsed=$(( elapsed + WATCH_POLL_SECS ))
      _watch_check
      (( elapsed >= WATCH_MAX_SECS )) && rc=1 || rc=0
    fi
    if (( rc == 1 )); then
      local mins=$(( WATCH_MAX_SECS / 60 ))
      alert_user "intercom: no reply on $ID" "No activity for ${mins}m — the other session may be away."
      echo "[intercom] ⏰ TIMEOUT: no activity on $ID for ${mins}m (idle budget reached)."
      echo "[intercom] ALERT THE USER — they may be away. Ask whether to keep waiting before re-arming; do NOT silently re-arm."
      exit $EX_TIMEOUT
    fi
  done
}

# ----------------------------------------------------------------------------
# Sentinel — the out-of-session safety net.
#
# The in-session `watch` is a background child of the Claude Code process, and
# the harness reaps it: of 131 observed watcher deaths, 119 were external kills,
# at a median of 29 minutes into a 60-minute budget. The damaging part is WHEN it
# dies — during the idle stretch after a turn ends, which is after the Stop guard
# has already run and passed. Nothing inside the session can notice, no further
# Stop fires, and the channel simply goes quiet until a human happens to poke it.
#
# The sentinel is deliberately NOT a child of the session: it double-forks into
# its own session (setsid), so a session reap, resume, compaction, or exit leaves
# it running. It cannot wake the model — only a completing background task does
# that — so its job is to wake the HUMAN: when a message sits unread with no
# watcher armed, it fires an OS notification naming the session that went deaf.
#
# It is a pure observer: never advances a watermark, never writes a .peek, never
# appends to the channel. Losing one costs nothing but the notification.
cmd_sentinel() {
  parse_args "$@"
  [[ -n "$ME" ]] || die "sentinel requires --me <label>"
  [[ -n "$ID" ]] || die "sentinel requires --id <id>"
  valid_label "$ME"
  ensure_dirs

  if (( SPAWN )); then spawn_sentinel "$ME" "$ID"; return 0; fi

  sentinel_running "$ME" "$ID" && { echo "sentinel already running for $ME/$ID"; return 0; }

  local pf; pf="$(sentinel_pidfile "$ME" "$ID")"
  mkdir -p "$(dirname "$pf")"; printf '%s\n' "$$" > "$pf"
  # shellcheck disable=SC2064
  trap "rm -f '$pf' 2>/dev/null || true" EXIT

  local poll="${INTERCOM_SENTINEL_POLL_SECS:-20}"
  local grace="${INTERCOM_SENTINEL_GRACE_SECS:-120}"     # let the real watcher win first
  local renotify="${INTERCOM_SENTINEL_RENOTIFY_SECS:-1800}"
  local maxlife="${INTERCOM_SENTINEL_MAX_SECS:-86400}"
  local deaf_since=0 last_seq=0 last_at=0
  local path shown inbound

  echo "[sentinel] watching $ID as $ME (pid $$, poll ${poll}s, grace ${grace}s)"
  SECONDS=0
  while (( SECONDS < maxlife )); do
    sleep "$poll"
    path="$(channel_path "$ID")"
    [[ -n "$path" ]] || { echo "[sentinel] channel file gone; exiting"; return 0; }
    if [[ -n "$(closed_by "$path")" ]]; then
      echo "[sentinel] channel closed; exiting"
      return 0
    fi
    shown="$(shown_seq "$ME" "$ID")"
    inbound="$(max_inbound_seq "$path" "$ME")"; inbound="${inbound:-0}"
    if (( inbound <= shown )); then deaf_since=0; continue; fi
    # Unread. If a watcher is armed it will deliver — that's the normal path.
    if watcher_alive "$ID"; then deaf_since=0; continue; fi
    (( deaf_since == 0 )) && deaf_since=$SECONDS
    (( SECONDS - deaf_since < grace )) && continue
    if (( inbound != last_seq || SECONDS - last_at >= renotify )); then
      echo "[sentinel] $(now_utc) unread MSG $inbound, no watcher armed — notifying"
      alert_user "intercom: $ME is not listening on $ID" \
                 "MSG $inbound is unread and no watcher is armed - that session was reaped and needs a poke."
      last_seq=$inbound; last_at=$SECONDS
    fi
  done
  echo "[sentinel] max lifetime reached; exiting"
}

# Detach a sentinel from this process tree and return immediately. Double-fork +
# setsid so it is reparented to init with no controlling terminal — a session-wide
# reap or a Claude Code restart must not take it with them. macOS ships no
# setsid(1), hence python3; the nohup fallback is weaker (survives SIGHUP only)
# but better than nothing.
spawn_sentinel() {
  local me="$1" id="$2" log self
  sentinel_running "$me" "$id" && return 0
  log="$(sentinel_logfile "$me" "$id")"
  mkdir -p "$(dirname "$log")"
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  if command -v python3 >/dev/null 2>&1; then
    INTERCOM_DIR="$COMMS_DIR" python3 -c '
import os, sys
script, me, cid, log = sys.argv[1:5]
if os.fork() > 0: sys.exit(0)          # parent returns to the shell at once
os.setsid()                            # new session: no controlling terminal
if os.fork() > 0: os._exit(0)          # grandchild cannot reacquire one
os.chdir("/")
fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
os.dup2(fd, 1); os.dup2(fd, 2)
null = os.open(os.devnull, os.O_RDONLY); os.dup2(null, 0)
os.execv(script, [script, "sentinel", "--me", me, "--id", cid])
' "$self" "$me" "$id" "$log" 2>/dev/null || true
  else
    INTERCOM_DIR="$COMMS_DIR" nohup "$self" sentinel --me "$me" --id "$id" >>"$log" 2>&1 &
    disown 2>/dev/null || true
  fi
}

cmd_list() {
  parse_args "$@"
  ensure_dirs
  local found=0 f base id stamp author topic state parts top wm unread
  shopt -s nullglob
  for f in "$COMMS_DIR"/*__*.txt; do
    found=1
    base="$(basename "$f")"
    id="${base%%__*}"
    stamp="${base##*__}"; stamp="${stamp%.txt}"
    author="$(last_author "$f")"
    topic="$(grep -m1 '^topic: ' "$f" | sed 's/^topic: //')"
    parts="$(participants "$f" | paste -sd, -)"
    top="$(max_seq "$f")"; top="${top:-0}"
    if grep -q '^--- CHANNEL CLOSED ---' "$f"; then
      state="closed"
    elif [[ -n "$(fin_labels "$f")" ]]; then
      state="half"
    else
      state="open"
    fi
    printf '%-8s  id:%s\n' "[$state]" "$id"
    printf '          topic:%s\n' "${topic:-(none)}"
    [[ "$state" == "half" ]] && printf '          half-closed-by:%s (done sending, still receiving)\n' "$(fin_labels "$f" | paste -sd, -)"
    printf '          participants:%s  last:%s by %s\n' "${parts:-?}" "$top" "${author:-?}"
    if [[ -n "$ME" ]]; then
      wm="$(get_watermark "$ME" "$id")"
      unread=$(( top - wm )); (( unread < 0 )) && unread=0
      printf '          unread(%s):%s\n' "$ME" "$unread"
    fi
    printf '          lastmod:%s\n\n' "$stamp"
  done
  (( found )) || echo "(no channels)"
}

# Read-receipts: show how far each participant has read, so a sender can confirm
# delivery WITHOUT waiting for a reply (retires the explicit ack round-trip).
# Pull-only from .state watermarks — no log write, no wake cycle.
cmd_status() {
  parse_args "$@"
  [[ -n "$ID" ]] || die "status requires --id <id>"
  local path top closer p wm mark
  path="$(require_channel "$ID")"
  top="$(max_seq "$path")"; top="${top:-0}"
  closer="$(closed_by "$path")"
  local fins; fins="$(fin_labels "$path" | paste -sd, - || true)"
  echo "channel $ID | latest:seq $top${closer:+ | CLOSED by $closer}${fins:+ | half-closed: $fins}"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    wm="$(get_watermark "$p" "$ID")"; (( wm > top )) && wm=$top
    (( wm >= top )) && mark="caught-up" || mark="behind"
    printf '  %-12s read %s/%s (%s)%s%s\n' "$p" "$wm" "$top" "$mark" \
      "$([[ "$p" == "$ME" ]] && printf ' [you]')" \
      "$(has_fin "$path" "$p" && printf ' [done sending]')"
  done <<< "$(participants "$path")"
  if [[ -z "$closer" ]] && ! watcher_alive "$ID"; then
    echo "  ⚠ no watcher armed on this machine — nobody will be woken by a new message"
  fi
}

# HALF-CLOSE (a FIN, as in TCP). `close` used to be unilateral and instant: one
# side wrote the close marker and the other's watcher exited 20 mid-conversation,
# whether or not it still had something to say — and whether or not it had even
# been shown the last message. Now `close` means "I am done SENDING": I keep
# receiving, and the channel only goes fully closed once every participant has
# said it. `--force` keeps the old hard close for a peer that is genuinely gone —
# a strictly mutual close would deadlock exactly then, which (given how often a
# watcher gets reaped) is the common case, not the rare one.
cmd_close() {
  parse_args "$@"
  [[ -n "$ME" ]] || die "close requires --me <label>"
  [[ -n "$ID" ]] || die "close requires --id <id>"
  valid_label "$ME"

  acquire_lock "$ID"
  local path; path="$(require_channel "$ID")"

  local closer; closer="$(closed_by "$path")"
  if [[ -n "$closer" ]]; then
    echo "channel $ID is already fully closed (by $closer) — nothing to do"
    return 0
  fi

  # Don't walk away from something you were never shown. This is a half-close, so
  # the message isn't lost either way, but you should see it before you stop
  # talking — peek only, so a later `read` still delivers it.
  local shown inbound
  shown="$(shown_seq "$ME" "$ID")"
  inbound="$(max_inbound_seq "$path" "$ME")"; inbound="${inbound:-0}"
  if (( inbound > shown )); then
    echo "[intercom] ⚠ you have inbound message(s) you were never shown on $ID:"
    cmd_read --me "$ME" --id "$ID" --peek
    echo "[intercom] ↑ read these before you stop; your half-close does NOT discard them."
  fi

  # The classic premature close: the peer spoke last and never got a reply. Not
  # blocked (a half-close still receives), but say so while it can still be
  # undone by sending.
  local last; last="$(last_author "$path")"
  if [[ -n "$last" && "$last" != "$ME" && -z "$(peer_fins "$path" "$ME")" ]]; then
    echo "[intercom] ⚠ the last message is from $last and you never replied. Are you closing too early?"
    echo "[intercom]   Close only once nothing is outstanding and they've confirmed there are no follow-ups;"
    echo "[intercom]   sending anything now reopens your side."
  fi

  if ! has_fin "$path" "$ME"; then
    { echo "closing-by: $ME"; echo "closing-at: $(now_utc)"; echo; } >> "$path"
  fi

  # Everyone who hasn't FIN'd yet. A label that once read the channel and then
  # vanished would hold it half-open forever — that's what --force is for.
  local pending
  pending="$(comm -23 <(participants "$path") <(fin_labels "$path" | sort -u) | paste -sd, - || true)"

  if (( FORCE )) || [[ -z "$pending" ]]; then
    {
      echo "--- CHANNEL CLOSED ---"
      echo "closed-by: $ME"
      echo "closed-at: $(now_utc)"
      (( FORCE )) && [[ -n "$pending" ]] && echo "close-mode: forced (did not wait for: $pending)"
      echo
    } >> "$path"
    touch_stamp "$path" "$ID" >/dev/null
    if (( FORCE )) && [[ -n "$pending" ]]; then
      echo "force-closed $ID (did not wait for: $pending)"
    else
      echo "closed $ID (all participants half-closed)"
    fi
  else
    touch_stamp "$path" "$ID" >/dev/null
    echo "half-closed $ID — you are done sending, still receiving."
    echo "waiting on: $pending  (channel closes when they close too; \`close --force\` to end it now)"
    echo "Keep your watcher armed until it fully closes (exit 20) — they may still follow up."
  fi
}

# ----------------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------------
[[ $# -ge 1 ]] || die "usage: intercom.sh {open|send|read|tail|watch|sentinel|status|list|close} [args]"
sub="$1"; shift || true
case "$sub" in
  open)     cmd_open     "$@" ;;
  send)     cmd_send     "$@" ;;
  read)     cmd_read     "$@" ;;
  tail)     cmd_tail     "$@" ;;
  watch)    cmd_watch    "$@" ;;
  sentinel) cmd_sentinel "$@" ;;
  status)   cmd_status   "$@" ;;
  list)     cmd_list     "$@" ;;
  close)    cmd_close    "$@" ;;
  *) die "unknown subcommand: $sub" ;;
esac

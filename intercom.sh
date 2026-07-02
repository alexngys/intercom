#!/usr/bin/env bash
#
# intercom.sh — inter-team communication channel for Claude Code sessions.
#
# Two independent sessions hold a turn-by-turn conversation through a shared,
# append-only file under ~/.claude/comms/. Each session keeps doing its own work
# and is re-invoked (via a backgrounded `watch`) when the other side replies.
#
# Subcommands: open | send | read | watch | list | close
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
EX_CLOSED=20  # channel was closed by the other side; caller should stop

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

# Label that closed the channel (from the `closed-by:` line), or empty if open.
closed_by() {
  local path="$1"
  grep -m1 '^closed-by: ' "$path" 2>/dev/null | sed 's/^closed-by: //' || true
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
PEEK=0 ; TAIL_N=20
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
  echo "channel is closed."
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

  (( PEEK )) || set_watermark "$ME" "$ID" "$top"
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
    local wpid tpid
    fswatch -1 "$COMMS_DIR" >/dev/null 2>&1 & wpid=$!
    ( sleep "$timeout"; kill "$wpid" 2>/dev/null ) & tpid=$!
    if wait "$wpid" 2>/dev/null; then kill "$tpid" 2>/dev/null; return 0; fi
    return 1
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
  local path cur_stamp author wm top
  path="$(channel_path "$ID")"
  [[ -n "$path" ]] || die "channel '$ID' disappeared"
  cur_stamp="$(basename "$path")"
  [[ "$cur_stamp" == "$SEEN_STAMP" ]] && return 0
  SEEN_STAMP="$cur_stamp"

  author="$(last_author "$path")"
  wm="$(get_watermark "$ME" "$ID")"
  top="$(max_seq "$path")"; top="${top:-0}"

  # Stop the moment the channel is closed — by anyone. (Keyed off `closed-by:`,
  # not the last message author, so a close still fires even when I sent last.)
  local closer; closer="$(closed_by "$path")"
  if [[ -n "$closer" ]]; then
    echo "[intercom] channel $ID closed by ${closer:-?}"
    exit $EX_CLOSED
  fi
  if (( top > wm )) && [[ "$author" != "$ME" ]]; then
    echo "[intercom] new on $ID:"       # per-message "from#seq:" carries the rest
    cmd_read --me "$ME" --id "$ID" --peek   # doorbell: deliver, but DON'T advance
    echo "[intercom] (shown via watcher; watermark unchanged — your reply's \`send\` acks it, or run \`read\`/\`tail\` if this output was truncated)"
    exit $EX_NEW
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

  SEEN_STAMP="$(basename "$path")"
  local mode="poll" elapsed=0 rc
  command -v fswatch >/dev/null 2>&1 && mode="event"
  command -v inotifywait >/dev/null 2>&1 && mode="event"
  [[ "$mode" == "event" ]] && echo "[intercom] watching $ID (event-driven)" \
                            || echo "[intercom] watching $ID (polling every ${WATCH_POLL_SECS}s)"

  SECONDS=0
  while true; do
    if [[ "$mode" == "event" ]]; then
      wait_for_change "$(( WATCH_MAX_SECS - SECONDS ))"; rc=$?
      if (( rc == 2 )); then mode="poll"; continue; fi   # tool vanished; degrade
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
    if grep -q '^--- CHANNEL CLOSED ---' "$f"; then state="closed"; else state="open"; fi
    printf '%-8s  id:%s\n' "[$state]" "$id"
    printf '          topic:%s\n' "${topic:-(none)}"
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
  echo "channel $ID | latest:seq $top${closer:+ | CLOSED by $closer}"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    wm="$(get_watermark "$p" "$ID")"; (( wm > top )) && wm=$top
    (( wm >= top )) && mark="caught-up" || mark="behind"
    printf '  %-12s read %s/%s (%s)%s\n' "$p" "$wm" "$top" "$mark" \
      "$([[ "$p" == "$ME" ]] && printf ' [you]')"
  done <<< "$(participants "$path")"
}

cmd_close() {
  parse_args "$@"
  [[ -n "$ME" ]] || die "close requires --me <label>"
  [[ -n "$ID" ]] || die "close requires --id <id>"

  acquire_lock "$ID"
  local path; path="$(require_channel "$ID")"
  {
    echo "--- CHANNEL CLOSED ---"
    echo "closed-by: $ME"
    echo "closed-at: $(now_utc)"
    echo
  } >> "$path"
  touch_stamp "$path" "$ID" >/dev/null
  echo "closed $ID"
}

# ----------------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------------
[[ $# -ge 1 ]] || die "usage: intercom.sh {open|send|read|tail|watch|status|list|close} [args]"
sub="$1"; shift || true
case "$sub" in
  open)   cmd_open   "$@" ;;
  send)   cmd_send   "$@" ;;
  read)   cmd_read   "$@" ;;
  tail)   cmd_tail   "$@" ;;
  watch)  cmd_watch  "$@" ;;
  status) cmd_status "$@" ;;
  list)   cmd_list   "$@" ;;
  close)  cmd_close  "$@" ;;
  *) die "unknown subcommand: $sub" ;;
esac

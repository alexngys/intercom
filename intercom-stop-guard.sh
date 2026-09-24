#!/usr/bin/env bash
#
# intercom-stop-guard.sh — Claude Code *Stop* hook.
#
# If THIS session is on an OPEN intercom channel but has no watcher armed, block
# the stop and nudge the model to re-arm (or close) — otherwise it would never be
# woken when the other side replies. Scoped to (session's `--me` label) ∩ (channel
# ids that appear in this session's transcript): the label alone is not a session
# identity, since .state/<label>/ is shared by every session using that label.
#
# Exception: a channel whose watchers keep getting killed soon after arming
# (memory pressure). A re-arm cannot hold there, and demanding one loops
# arm → killed → blocked → arm. The stop is allowed instead, and the user is told
# via systemMessage that the sentinel is the delivery path.
#
# Fail-open EVERYWHERE: a Stop guard must never wedge a session. Any uncertainty
# -> allow the stop.
#
# Reads the hook JSON on stdin: { transcript_path, stop_hook_active, ... }.
# To block, prints {"decision":"block","reason":"..."} and exits 0.

set -u

COMMS_DIR="${INTERCOM_DIR:-$HOME/.claude/comms}"
STATE_DIR="$COMMS_DIR/.state"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERCOM="$SELF_DIR/intercom.sh"

allow() { exit 0; }   # let the stop proceed
kv() { grep -m1 "^$1=" <<<"$health" | cut -d= -f2-; }   # key=value lookup in $health

json_str() {  # JSON-encode $1 for the "reason" value
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
  else
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

input="$(cat 2>/dev/null || true)"

# Only nudge once per stop sequence — if we already blocked, let it through so we
# can't wedge the session in a loop.
if printf '%s' "$input" | grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  allow
fi

# Session's intercom label, from the most recent `--me <label>` in the transcript.
transcript="$(printf '%s' "$input" \
  | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
[[ -n "$transcript" && -f "$transcript" ]] || allow

me="$(tail -n 2000 "$transcript" 2>/dev/null \
  | grep -oE -- '--me [A-Za-z0-9_-]+' | tail -1 | awk '{print $2}')"
[[ -n "$me" ]] || allow                      # session never used intercom

# Channel ids THIS session actually touched.
#
# The label is NOT a session identity: two sessions on the same repo routinely
# pick the same `--me` (both "backend"), and .state/<label>/ is shared between
# them. A label-only scan therefore blocks session A's stop over session B's
# open channel — a channel A has never seen and cannot re-arm. Intersect with the
# ids present in this transcript to get a per-session view.
#
# A channel id is a distinctive token (6 hex + `-` + UTC stamp) and every
# open/watch banner prints it verbatim, so any channel with recent activity in
# this session leaves its literal id in the transcript. Also accept `--id <tok>`
# for robustness; a literal `$ID` from the documented `--id "$ID"` idiom simply
# matches no state entry.
#
# Scanned over a byte-tail rather than the 2000-line window used for the label:
# with `--id "$ID"` the id may appear only in command OUTPUT, which is sparser
# than the commands themselves.
scan_bytes="${GUARD_SCAN_BYTES:-4000000}"
mine="$( { tail -c "$scan_bytes" "$transcript" | grep -oE '[0-9a-f]{6}-[0-9]{8}T[0-9]{6}Z'
           tail -c "$scan_bytes" "$transcript" | grep -oE -- '--id [A-Za-z0-9_.-]+' \
             | awk '{print $2}'; } 2>/dev/null | sort -u)"
[[ -n "$mine" ]] || allow                    # no channel attributable to this session

# Open channels this label has touched (a watermark file exists per interaction),
# that currently have NO live watcher process.
[[ -d "$STATE_DIR/$me" ]] || allow
shopt -s nullglob
unguarded_id=""
degraded=()     # one note per channel whose watchers are being reaped
for wf in "$STATE_DIR/$me"/*; do
  id="$(basename "$wf")"
  # Same label, different session -> not ours to re-arm or to be nagged about.
  printf '%s\n' "$mine" | grep -qxF -- "$id" || continue
  files=( "$COMMS_DIR/${id}__"*.txt )
  (( ${#files[@]} )) || continue             # channel file gone
  grep -q '^--- CHANNEL CLOSED ---' "${files[0]}" && continue   # already closed
  # Skip stale/abandoned channels: the footgun is "just replied, forgot to
  # re-arm", which is inherently recent. If nothing touched it in the last hour,
  # you're not mid-conversation — don't nag (and don't false-block a session that
  # merely reused an old label).
  [[ -n "$(find "${files[0]}" -mmin "-${GUARD_STALE_MIN:-60}" 2>/dev/null)" ]] || continue
  # Arm the out-of-session sentinel for every live channel, whatever we decide
  # about the stop. This hook is the LAST thing that runs before the idle window
  # in which the harness reaps the in-session watcher — after that no Stop fires
  # again, so this is the final chance to leave something behind that can still
  # reach the human. Idempotent (pidfile-guarded) and returns immediately.
  "$INTERCOM" sentinel --me "$me" --id "$id" --spawn >/dev/null 2>&1 || true
  # One probe for both questions: is a watcher armed, and do armed watchers
  # survive? (Fail-open: if `health` itself fails, kv yields "" and we fall
  # through to the plain re-arm nudge, same as before.)
  health="$("$INTERCOM" health --me "$me" --id "$id" 2>/dev/null || true)"
  [[ "$(kv watcher)" == 1 ]] && continue
  # Re-arm is futile when the last few watchers were killed within minutes of
  # arming. Don't block — hand delivery to the sentinel and say so.
  if [[ "$(kv unstable)" == 1 ]]; then
    note="${id}: watcher killed $(kv reaps_fast)x soon after arming (last lived $(kv last_lived)s)"
    [[ "$(kv sentinel)" == 1 ]] \
      && note+="; the sentinel will send a desktop notification when a message arrives" \
      || note+="; NO sentinel is running, so nothing will notify you"
    degraded+=("$note")
    continue
  fi
  unguarded_id="$id"; break
done

if [[ -z "$unguarded_id" ]]; then
  (( ${#degraded[@]} )) || allow
  msg="intercom: not re-arming — watchers keep getting killed (likely memory pressure). This session will NOT be woken by replies. $(printf '%s. ' "${degraded[@]}")Check the channel yourself (\`intercom.sh read\`) when notified."
  printf '{"systemMessage":%s}\n' "$(json_str "$msg")"
  exit 0
fi

reason="You still have an OPEN intercom channel ${unguarded_id} (as ${me}) with no watcher armed — you will NOT be woken if the other session replies. Before you stop, either re-arm it in the BACKGROUND ('${INTERCOM} watch --me ${me} --id ${unguarded_id}', or reply with 'send ... --watch'), or close it ('${INTERCOM} close --me ${me} --id ${unguarded_id}') if the conversation is finished."
printf '{"decision":"block","reason":%s}\n' "$(json_str "$reason")"
exit 0

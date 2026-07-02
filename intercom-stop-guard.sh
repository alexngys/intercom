#!/usr/bin/env bash
#
# intercom-stop-guard.sh — Claude Code *Stop* hook.
#
# If THIS session is on an OPEN intercom channel but has no watcher armed, block
# the stop and nudge the model to re-arm (or close) — otherwise it would never be
# woken when the other side replies. Scoped by the session's intercom *label*
# (which the model writes literally as `--me <label>`), not by channel id.
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

# Open channels this label has touched (a watermark file exists per interaction),
# that currently have NO live watcher process.
[[ -d "$STATE_DIR/$me" ]] || allow
shopt -s nullglob
unguarded_id=""
for wf in "$STATE_DIR/$me"/*; do
  id="$(basename "$wf")"
  files=( "$COMMS_DIR/${id}__"*.txt )
  (( ${#files[@]} )) || continue             # channel file gone
  grep -q '^--- CHANNEL CLOSED ---' "${files[0]}" && continue   # already closed
  # Skip stale/abandoned channels: the footgun is "just replied, forgot to
  # re-arm", which is inherently recent. If nothing touched it in the last hour,
  # you're not mid-conversation — don't nag (and don't false-block a session that
  # merely reused an old label).
  [[ -n "$(find "${files[0]}" -mmin "-${GUARD_STALE_MIN:-60}" 2>/dev/null)" ]] || continue
  # A live watcher = an intercom.sh process for this id running `watch`/`--watch`.
  if ps -Ao args= 2>/dev/null | grep -F 'intercom.sh' \
       | grep -F -- "$id" | grep -Eq 'watch'; then
    continue
  fi
  unguarded_id="$id"; break
done
[[ -n "$unguarded_id" ]] || allow

reason="You still have an OPEN intercom channel ${unguarded_id} (as ${me}) with no watcher armed — you will NOT be woken if the other session replies. Before you stop, either re-arm it in the BACKGROUND ('${INTERCOM} watch --me ${me} --id ${unguarded_id}', or reply with 'send ... --watch'), or close it ('${INTERCOM} close --me ${me} --id ${unguarded_id}') if the conversation is finished."
printf '{"decision":"block","reason":%s}\n' "$(json_str "$reason")"
exit 0

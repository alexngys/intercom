#!/usr/bin/env bash
#
# test.sh — regression suite for the intercom skill. Self-contained: creates a
# throwaway INTERCOM_DIR, exercises every subcommand + the Stop guard, asserts.
#
# Run: ./test.sh   (exit 0 = all pass). Forces polling mode (PATH=/usr/bin:/bin)
# so watch timings are deterministic regardless of fswatch/inotify availability.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/intercom.sh"
GUARD="$HERE/intercom-stop-guard.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
no()   { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }

WORK="$(mktemp -d)"; export INTERCOM_DIR="$WORK"
trap 'rm -rf "$WORK"' EXIT
# Force poll mode + fast idle budget for the watch tests.
POLL=(env INTERCOM_WATCH_MAX_SECS=3 INTERCOM_POLL_SECS=1 PATH=/usr/bin:/bin)
newid() { "$S" open --me "$1" ${2:+--topic "$2"} 2>/dev/null | grep -Eo 'id: .*' | sed 's/id: //'; }

echo "== basic send/read =="
ID="$(newid A topic1)"
has "open prints id" "$ID" "-"
out="$("$S" send --me A --id "$ID" --msg hello)"; eq "send exits 0" "$?" "0"
has "send confirms" "$out" "sent MSG 1"
out="$("$S" read --me B --id "$ID" 2>/dev/null)"; has "B reads A's msg" "$out" "hello"

echo "== plain send with no readers must exit 0 (regression) =="
ID2="$(newid X)"; "$S" send --me X --id "$ID2" --msg solo >/dev/null; eq "solo send exit" "$?" "0"

echo "== read-receipts =="
st="$("$S" status --id "$ID")"
has "status: B caught-up after read" "$st" "B "
has "status shows top seq" "$st" "seq 1"
"$S" send --me A --id "$ID" --msg second >/dev/null
st="$("$S" status --id "$ID")"
has "status: B now behind" "$st" "behind"

echo "== typed json =="
"$S" send --me A --id "$ID" --json '{"k":1}' >/dev/null; eq "valid json exit" "$?" "0"
has "json tagged in on-disk log" "$(cat "$WORK/${ID}__"*.txt)" "type:json"
out="$("$S" read --me B --id "$ID" 2>/dev/null)"; has "json marked in display" "$out" "[json]"
"$S" send --me A --id "$ID" --json '{bad,}' >/dev/null 2>&1; eq "invalid json rejected" "$?" "1"

echo "== compact display: no ===== framing, has from#seq =="
"$S" send --me A --id "$ID" --msg framecheck >/dev/null
out="$("$S" read --me B --id "$ID" 2>/dev/null)"
has "compact shows from#seq" "$out" "A#"
no "compact drops ===== framing" "$out" "====="

echo "== label typo warning =="
w="$("$S" read --me A-typo --id "$ID" 2>&1 >/dev/null)"; has "typo warns" "$w" "WARNING"
w="$("$S" read --me A --id "$ID" 2>&1 >/dev/null)"; no "known label silent" "$w" "WARNING"

echo "== list =="
lst="$("$S" list --me A)"
has "list participants" "$lst" "participants:A,A-typo,B"
has "list unread col" "$lst" "unread(A)"

echo "== watch: fresh watcher seeds at top (no backlog dump) =="
IDF="$(newid A)"; "$S" send --me A --id "$IDF" --msg old1 >/dev/null; "$S" send --me A --id "$IDF" --msg old2 >/dev/null
( sleep 1; "$S" send --me A --id "$IDF" --msg freshmsg >/dev/null 2>&1 ) &
out="$("${POLL[@]}" INTERCOM_WATCH_MAX_SECS=30 "$S" watch --me C --id "$IDF" 2>/dev/null)"
has "watcher sees new msg" "$out" "freshmsg"
no "watcher skips backlog" "$out" "old1"

echo "== watch: message path (empty channel) -> exit 0 =="
IDW="$(newid A)"
( sleep 1; "$S" send --me B --id "$IDW" --msg ping >/dev/null 2>&1 ) &
"${POLL[@]}" INTERCOM_WATCH_MAX_SECS=30 "$S" watch --me A --id "$IDW" >/dev/null 2>&1; eq "watch new-msg" "$?" "0"

echo "== watch: close path -> exit 20 (even when I sent last) =="
"$S" send --me A --id "$IDW" --msg last >/dev/null
( sleep 1; "$S" close --me B --id "$IDW" >/dev/null 2>&1 ) &
"${POLL[@]}" INTERCOM_WATCH_MAX_SECS=30 "$S" watch --me A --id "$IDW" >/dev/null 2>&1; eq "watch close" "$?" "20"

echo "== watch: idle timeout -> exit 10 + directive =="
IDT="$(newid A)"
out="$("${POLL[@]}" "$S" watch --me A --id "$IDT" 2>&1)"; rc=$?
eq "watch timeout code" "$rc" "10"; has "timeout alerts user" "$out" "ALERT THE USER"

echo "== send --watch: replies then re-arms in one process =="
IDR="$(newid A)"
( sleep 1; "$S" send --me B --id "$IDR" --msg reply >/dev/null 2>&1 ) &
"${POLL[@]}" INTERCOM_WATCH_MAX_SECS=30 "$S" send --me A --id "$IDR" --msg go --watch >/dev/null 2>&1
eq "send --watch exit" "$?" "0"
[[ -d "$WORK/.locks/$IDR" ]] && bad "send --watch left lock" || ok "send --watch released lock"

echo "== read --peek: delivers without advancing watermark =="
IDP="$(newid A)"; "$S" send --me A --id "$IDP" --msg peekmsg >/dev/null
out="$("$S" read --me B --id "$IDP" --peek 2>/dev/null)"; has "peek delivers content" "$out" "peekmsg"
out="$("$S" read --me B --id "$IDP" 2>/dev/null)"; has "peek left it unread (re-delivers)" "$out" "peekmsg"
out="$("$S" read --me B --id "$IDP" 2>/dev/null)"; has "non-peek read then advances" "$out" "no new messages"

echo "== watcher is a doorbell: catching a msg must NOT swallow it (regression) =="
IDD="$(newid A)"
( sleep 1; "$S" send --me B --id "$IDD" --msg confirmed >/dev/null 2>&1 ) &
out="$("${POLL[@]}" INTERCOM_WATCH_MAX_SECS=30 "$S" watch --me A --id "$IDD" 2>/dev/null)"
has "watcher doorbell shows the msg" "$out" "confirmed"
# The fix: watcher used --peek, so it did NOT advance A's watermark. A foreground
# read must therefore still RECOVER the message (old code swallowed it here).
out="$("$S" read --me A --id "$IDD" 2>/dev/null)"; has "foreground read recovers (no swallow)" "$out" "confirmed"

echo "== tail: watermark-free recovery view =="
IDL="$(newid A)"
"$S" send --me A --id "$IDL" --msg t1 >/dev/null
"$S" send --me B --id "$IDL" --msg t2 >/dev/null
"$S" read --me A --id "$IDL" >/dev/null 2>&1     # advance A fully
out="$("$S" tail --id "$IDL" --me A 2>/dev/null)"
has "tail shows inbound regardless of watermark" "$out" "t2"
has "tail shows own messages too" "$out" "t1"
has "tail tags own with [you]" "$out" "[you]"
"$S" send --me A --id "$IDL" --msg t3 >/dev/null
out="$("$S" tail --id "$IDL" -n 1 2>/dev/null)"
has "tail -n 1 shows newest" "$out" "t3"
no  "tail -n 1 drops older" "$out" "t1"
st="$("$S" status --id "$IDL")"; has "tail advanced no watermark" "$st" "behind"

echo "== stop guard =="
mkfake() { local f="$WORK/transcript.jsonl"; printf '{"role":"x","text":"ran %s --me %s --id ..."}\n' "$S" "$1" > "$f"; echo "$f"; }
hookin() { printf '{"transcript_path":"%s","stop_hook_active":false}' "$1"; }
# open channel, label G participated (read it), no watcher -> BLOCK
IDG="$(newid H)"; "$S" send --me H --id "$IDG" --msg hi >/dev/null; "$S" read --me G --id "$IDG" >/dev/null 2>&1
TR="$(mkfake G)"
out="$(hookin "$TR" | "$GUARD")"; has "guard blocks open+no-watcher" "$out" '"decision":"block"'
has "guard names the channel" "$out" "$IDG"
# with a live watcher -> ALLOW
( "${POLL[@]}" INTERCOM_WATCH_MAX_SECS=8 "$S" watch --me G --id "$IDG" >/dev/null 2>&1 ) &
WPID=$!; sleep 1
out="$(hookin "$TR" | "$GUARD")"; eq "guard allows when watcher live" "${out:-EMPTY}" "EMPTY"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
# stale open channel (untouched > 1h) -> ALLOW (abandoned, not mid-conversation)
IDS="$(newid P)"; "$S" send --me P --id "$IDS" --msg x >/dev/null; "$S" read --me Q --id "$IDS" >/dev/null 2>&1
sf=( "$WORK/${IDS}__"*.txt ); touch -t 202001010000 "${sf[0]}"
out="$(hookin "$(mkfake Q)" | "$GUARD")"; eq "guard skips stale channel" "${out:-EMPTY}" "EMPTY"
# closed channel -> ALLOW
"$S" close --me H --id "$IDG" >/dev/null
out="$(hookin "$TR" | "$GUARD")"; eq "guard allows when closed" "${out:-EMPTY}" "EMPTY"
# stop_hook_active true -> ALLOW (loop guard)
out="$(printf '{"transcript_path":"%s","stop_hook_active":true}' "$TR" | "$GUARD")"
eq "guard respects stop_hook_active" "${out:-EMPTY}" "EMPTY"
# no --me in transcript -> ALLOW
printf '{"role":"x","text":"nothing here"}\n' > "$WORK/empty.jsonl"
out="$(printf '{"transcript_path":"%s/empty.jsonl","stop_hook_active":false}' "$WORK" | "$GUARD")"
eq "guard allows non-intercom session" "${out:-EMPTY}" "EMPTY"

echo "== crossed write: a send must not ack a message it never showed me =="
# B writes while A is composing (no watcher armed — the watcher exits on delivery,
# so this is the whole time A is thinking). A then sends without having read.
IDX="$(newid A crossed)"
"$S" send --me B --id "$IDX" --msg "B-CROSSED" >/dev/null
out="$("$S" send --me A --id "$IDX" --msg "A-blind-reply")"
has "send warns about the crossed write" "$out" "CROSSED WRITE"
has "send shows the swallowed message body" "$out" "B-CROSSED"
# ...and having shown it in captured foreground output, the ack is then legitimate.
out="$("$S" read --me A --id "$IDX" 2>/dev/null)"; has "acked after being shown" "$out" "no new messages"

# A message the watcher already peeked must NOT be re-printed by the next send.
IDY="$(newid A nonoise)"
"$S" send --me B --id "$IDY" --msg "B-seen" >/dev/null
"$S" read --me A --id "$IDY" --peek >/dev/null          # doorbell delivered it
out="$("$S" send --me A --id "$IDY" --msg "A-reply")"
no "no crossed-write noise for an already-delivered msg" "$out" "CROSSED WRITE"

echo "== unread inbound already on disk at attach, with no later write =="
# How this arises in the wild: the other side's message lands in the SAME SECOND
# as my own send. touch_stamp renames to <id>__<now>.txt at 1s granularity and
# skips the rename when the name is unchanged, so the filename is byte-identical
# and a watcher gating on it sees "nothing changed" — then nothing else is ever
# written (it's my turn to be replied to), so the gate never lifts and the
# watcher sits out its entire idle budget on top of a message already on disk.
# Asserted deterministically here as "unread inbound present, no write after
# attach" — same state, no dependence on wall-clock luck.
IDS="$(newid A samesec)"
"$S" send --me B --id "$IDS" --msg first >/dev/null
"$S" read --me A --id "$IDS" >/dev/null 2>&1          # watermark = 1
"$S" send --me B --id "$IDS" --msg samesecmsg >/dev/null   # seq 2, unread
out="$("${POLL[@]}" "$S" watch --me A --id "$IDS" 2>/dev/null)"; rc=$?
eq "watch fires on inbound already present at attach" "$rc" "0"
has "watch delivered it" "$out" "samesecmsg"

echo "== watcher must not go blind when my own message is last =="
# Inbound arrives, then I write. `last_author` is now me, but their message is
# still unread — gating on the last author would sit out the whole idle budget.
IDL="$(newid A lastauthor)"
"$S" send --me B --id "$IDL" --msg "B-earlier" >/dev/null
"$S" read --me A --id "$IDL" --peek >/dev/null     # delivered, deliberately not acked
"$S" send --me A --id "$IDL" --msg "A-later" >/dev/null 2>&1
"$S" read --me A --id "$IDL" --peek >/dev/null
printf '2\n' > "$INTERCOM_DIR/.state/A/$IDL"       # simulate: acked #1 only, #2 is mine
"$S" send --me B --id "$IDL" --msg "B-newest" >/dev/null
out="$("${POLL[@]}" "$S" watch --me A --id "$IDL" 2>/dev/null)"; rc=$?
eq "watch fires on inbound above watermark" "$rc" "0"
has "watch delivered it" "$out" "B-newest"

echo "== event mode: a failing event tool must not silently kill the watcher =="
# Under `set -e`, `wait_for_change ...; rc=$?` exits the shell before rc is ever
# assigned: every event-mode timeout died with a bare 1, no idle alert at all.
FAKE="$WORK/fakebin"; mkdir -p "$FAKE"
printf '#!/bin/sh\nexit 1\n' > "$FAKE/fswatch"; chmod +x "$FAKE/fswatch"
IDE="$(newid A eventmode)"
# Redirect to a FILE, not a pipe: an orphaned timer child inherits the pipe and
# blocks the capture for the whole timeout, which would hide the very leak we are
# asserting on (and makes a dead watcher look alive to its caller).
rc=0; env INTERCOM_WATCH_MAX_SECS=3 PATH="$FAKE:/usr/bin:/bin" \
  "$S" watch --me A --id "$IDE" > "$WORK/ev.out" 2>&1 || rc=$?
out="$(cat "$WORK/ev.out")"
leaked="$(ps -Ao args= 2>/dev/null | grep -c '[s]leep 3$' || true)"
eq "no orphaned timer child left behind" "$leaked" "0"
eq "failing event tool does not exit a bare 1" "$rc" "10"
has "degrades to polling instead of dying" "$out" "TIMEOUT"

echo
echo "==== $PASS passed, $FAIL failed ===="
(( FAIL == 0 ))

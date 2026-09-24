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
# Wait (up to 5s) for a watcher on $1 to show up in the process table — a fixed
# `sleep 1` races watcher startup on a loaded machine.
wait_watcher() { local i; for i in $(seq 50); do
  ps -Ao args= | grep -F intercom.sh | grep -F -- "$1" | grep -q ' watch ' && return 0; sleep 0.1; done; }
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

echo "== watch: peer half-close -> exit 21 (not a hard stop) =="
"$S" send --me A --id "$IDW" --msg last >/dev/null
( sleep 1; "$S" close --me B --id "$IDW" >/dev/null 2>&1 ) &
out="$("${POLL[@]}" INTERCOM_WATCH_MAX_SECS=30 "$S" watch --me A --id "$IDW" 2>&1)"; rc=$?
eq "watch peer-fin" "$rc" "21"
has "fin names the peer" "$out" "half-closed"
# and once reported, a re-armed watcher must NOT spin on the same FIN
out="$("${POLL[@]}" INTERCOM_WATCH_MAX_SECS=3 "$S" watch --me A --id "$IDW" 2>&1)"; rc=$?
eq "same FIN not re-reported" "$rc" "10"

echo "== close: mutual FIN closes the channel; watch then exits 20 =="
"$S" close --me A --id "$IDW" >/dev/null 2>&1
out="$("$S" tail --id "$IDW" -n 1 2>&1)"; has "channel now CLOSED" "$out" "CLOSED by A"
out="$("${POLL[@]}" INTERCOM_WATCH_MAX_SECS=5 "$S" watch --me B --id "$IDW" 2>&1)"; rc=$?
eq "watch closed" "$rc" "20"

echo "== half-close is not a hard close: peer can still send, closer still receives =="
IDH="$(newid A)"
"$S" send --me A --id "$IDH" --msg hi >/dev/null
"$S" read --me B --id "$IDH" >/dev/null 2>&1
out="$("$S" close --me A --id "$IDH" 2>&1)"
has "close reports half-closed" "$out" "half-closed"
has "close names who it waits on" "$out" "waiting on: B"
no "half-close did not hard close" "$(cat "$WORK/$IDH"__*.txt)" "--- CHANNEL CLOSED ---"
out="$("$S" send --me B --id "$IDH" --msg "still here" 2>&1)"; rc=$?
eq "peer can still send after my FIN" "$rc" "0"
has "peer warned about my FIN" "$out" "done sending"
out="$("$S" read --me A --id "$IDH" 2>&1)"; has "half-closer still receives" "$out" "still here"
out="$("$S" send --me A --id "$IDH" --msg "actually one more" 2>&1)"
has "sending reopens my half" "$out" "reopens it"
no "my FIN was retracted" "$("$S" close --me B --id "$IDH" 2>&1)" "all participants half-closed"

echo "== close warns when the peer spoke last and got no reply =="
IDE2="$(newid A)"
"$S" send --me A --id "$IDE2" --msg "q?" >/dev/null; "$S" send --me B --id "$IDE2" --msg "one more thing" >/dev/null
out="$("$S" close --me A --id "$IDE2" 2>&1)"
has "unreplied close warns" "$out" "closing too early"
has "half-close says keep watching" "$out" "Keep your watcher armed"
IDE3="$(newid A)"
"$S" send --me B --id "$IDE3" --msg "done on my side" >/dev/null; "$S" send --me A --id "$IDE3" --msg "thanks" >/dev/null 2>&1
no "no warning when I spoke last" "$("$S" close --me A --id "$IDE3" 2>&1)" "closing too early"
IDE4="$(newid A)"
"$S" send --me A --id "$IDE4" --msg x >/dev/null 2>&1; "$S" send --me B --id "$IDE4" --msg bye >/dev/null
"$S" close --me B --id "$IDE4" >/dev/null 2>&1
no "no warning when peer already half-closed" "$("$S" close --me A --id "$IDE4" 2>&1)" "closing too early"

echo "== close --force ends it even with a live peer =="
IDF="$(newid A)"
"$S" send --me A --id "$IDF" --msg x >/dev/null; "$S" read --me B --id "$IDF" >/dev/null 2>&1
out="$("$S" close --me A --id "$IDF" --force 2>&1)"
has "force closes" "$out" "force-closed"
has "records who was cut off" "$(cat "$WORK/$IDF"__*.txt)" "close-mode: forced"

echo "== send into a closed channel must fail, not append into the void =="
out="$("$S" send --me B --id "$IDF" --msg "hello?" 2>&1)"; rc=$?
eq "send on closed exits non-zero" "$rc" "1"
has "send explains the close" "$out" "is CLOSED"
eq "nothing was appended" "$(grep -c '^===== MSG ' "$WORK/$IDF"__*.txt)" "1"

echo "== close must not strand the last message (42/63 channels did) =="
IDD="$(newid A)"
"$S" send --me A --id "$IDD" --msg first >/dev/null
"$S" read --me B --id "$IDD" >/dev/null 2>&1        # B is caught up, then goes away
# Both the message AND the close are on disk before B's watcher looks — the exact
# interleaving that used to lose the message (closer check ran first, exit 20).
"$S" send --me A --id "$IDD" --msg "FINAL WORD" >/dev/null 2>&1
"$S" close --me A --id "$IDD" --force >/dev/null 2>&1
out="$("${POLL[@]}" INTERCOM_WATCH_MAX_SECS=30 "$S" watch --me B --id "$IDD" 2>&1)"; rc=$?
has "final message was delivered, not swallowed" "$out" "FINAL WORD"
has "close reported in the same output" "$out" "CLOSED"
eq "still exits 20" "$rc" "20"

echo "== double close is a no-op =="
out="$("$S" close --me A --id "$IDF" 2>&1)"; eq "second close exits 0" "$?" "0"
has "second close says so" "$out" "already fully closed"
eq "only one close marker" "$(grep -c '^--- CHANNEL CLOSED ---' "$WORK/$IDF"__*.txt)" "1"

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
# A fake transcript names the label AND the channel id, like a real one does
# (the guard scopes to this session's ids, not to every channel sharing a label).
mkfake() { local f="$WORK/transcript-$1.jsonl"
  printf '{"role":"x","text":"ran %s --me %s --id %s"}\n' "$S" "$1" "${2:-}" > "$f"; echo "$f"; }
hookin() { printf '{"transcript_path":"%s","stop_hook_active":false}' "$1"; }
# open channel, label G participated (read it), no watcher -> BLOCK
IDG="$(newid H)"; "$S" send --me H --id "$IDG" --msg hi >/dev/null; "$S" read --me G --id "$IDG" >/dev/null 2>&1
TR="$(mkfake G "$IDG")"
out="$(hookin "$TR" | "$GUARD")"; has "guard blocks open+no-watcher" "$out" '"decision":"block"'
has "guard names the channel" "$out" "$IDG"
# with a live watcher -> ALLOW
( "${POLL[@]}" INTERCOM_WATCH_MAX_SECS=8 "$S" watch --me G --id "$IDG" >/dev/null 2>&1 ) &
WPID=$!; wait_watcher "$IDG"
out="$(hookin "$TR" | "$GUARD")"; eq "guard allows when watcher live" "${out:-EMPTY}" "EMPTY"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
# stale open channel (untouched > 1h) -> ALLOW (abandoned, not mid-conversation)
IDS="$(newid P)"; "$S" send --me P --id "$IDS" --msg x >/dev/null; "$S" read --me Q --id "$IDS" >/dev/null 2>&1
sf=( "$WORK/${IDS}__"*.txt ); touch -t 202001010000 "${sf[0]}"
out="$(hookin "$(mkfake Q "$IDS")" | "$GUARD")"; eq "guard skips stale channel" "${out:-EMPTY}" "EMPTY"
# half-closed by the PEER -> still BLOCK: a FIN from H means H is done sending,
# G keeps receiving, so G still needs a watcher armed.
"$S" close --me H --id "$IDG" >/dev/null
out="$(hookin "$TR" | "$GUARD")"; has "guard still blocks on peer half-close" "$out" '"decision":"block"'
# fully closed (every side FIN'd) -> ALLOW
"$S" close --me G --id "$IDG" >/dev/null
out="$(hookin "$TR" | "$GUARD")"; eq "guard allows when closed" "${out:-EMPTY}" "EMPTY"
# stop_hook_active true -> ALLOW (loop guard)
out="$(printf '{"transcript_path":"%s","stop_hook_active":true}' "$TR" | "$GUARD")"
eq "guard respects stop_hook_active" "${out:-EMPTY}" "EMPTY"
# no --me in transcript -> ALLOW
printf '{"role":"x","text":"nothing here"}\n' > "$WORK/empty.jsonl"
out="$(printf '{"transcript_path":"%s/empty.jsonl","stop_hook_active":false}' "$WORK" | "$GUARD")"
eq "guard allows non-intercom session" "${out:-EMPTY}" "EMPTY"

echo "== stop guard: same label, different channels (no cross-session bleed) =="
# Two sessions on one repo both call themselves M and share .state/M/. Each is on
# its own channel, both open with no watcher armed. Neither may be nagged about
# the other's channel — it isn't in its transcript and it cannot re-arm it.
IDM1="$(newid W)"; "$S" send --me W --id "$IDM1" --msg one >/dev/null
"$S" read --me M --id "$IDM1" >/dev/null 2>&1
IDM2="$(newid W)"; "$S" send --me W --id "$IDM2" --msg two >/dev/null
"$S" read --me M --id "$IDM2" >/dev/null 2>&1
out="$(hookin "$(mkfake M "$IDM2")" | "$GUARD")"
has "guard blocks on this session's channel" "$out" "$IDM2"
no  "guard ignores same-label channel from another session" "$out" "$IDM1"
# ...and once THIS session's channel is closed, the sibling's open one must not
# keep it from stopping.
"$S" close --me W --id "$IDM2" >/dev/null; "$S" close --me M --id "$IDM2" >/dev/null
out="$(hookin "$(mkfake M "$IDM2")" | "$GUARD")"
eq "guard allows when only another session's channel is open" "${out:-EMPTY}" "EMPTY"
# A transcript with a label but no id at all -> fail open (never wedge a session).
out="$(hookin "$(mkfake M)" | "$GUARD")"
eq "guard fails open when no id in transcript" "${out:-EMPTY}" "EMPTY"

echo "== reap tracking: a clean exit is not a reap =="
IDK="$(newid A reaps)"; "$S" read --me B --id "$IDK" >/dev/null 2>&1
NS=(env INTERCOM_NO_SENTINEL=1)
"${NS[@]}" "${POLL[@]}" "$S" watch --me B --id "$IDK" >/dev/null 2>&1   # idle timeout, exit 10
[[ -e "$WORK/.state/B/$IDK.reaps" ]] && bad "timeout logged as a reap" || ok "timeout is not a reap"
ls "$WORK/.state/B/$IDK".watch.* >/dev/null 2>&1 && bad "clean exit left an arm record" || ok "clean exit removes arm record"

echo "== reap tracking: SIGTERM is logged by the watcher itself =="
"${NS[@]}" "${POLL[@]}" INTERCOM_WATCH_MAX_SECS=30 "$S" watch --me B --id "$IDK" > "$WORK/term.out" 2>&1 &
WPID=$!; wait_watcher "$IDK"; sleep 0.5; kill -TERM "$WPID"; wait "$WPID"; rc=$?
eq "reaped watcher exits 143" "$rc" "143"
has "reaped watcher says so" "$(cat "$WORK/term.out")" "killed externally"
has "TERM reap logged" "$(cat "$WORK/.state/B/$IDK.reaps" 2>/dev/null)" " TERM"
ls "$WORK/.state/B/$IDK".watch.* >/dev/null 2>&1 && bad "TERM left an arm record" || ok "TERM removes arm record"
st="$("$S" status --id "$IDK")"
has "status reports the reap" "$st" "watcher reaped 1×"
no  "one reap is not UNSTABLE" "$st" "UNSTABLE"

echo "== reap tracking: SIGKILL leaves a record the next scan picks up =="
"${NS[@]}" "${POLL[@]}" INTERCOM_WATCH_MAX_SECS=30 "$S" watch --me B --id "$IDK" >/dev/null 2>&1 &
WPID=$!; wait_watcher "$IDK"; sleep 0.5; kill -KILL "$WPID"; wait "$WPID" 2>/dev/null
h="$("$S" health --me B --id "$IDK")"
has "SIGKILL reap logged as gone" "$(cat "$WORK/.state/B/$IDK.reaps")" " gone"
has "two fast reaps => unstable" "$h" "unstable=1"
has "health: no watcher" "$h" "watcher=0"
has "status flags UNSTABLE" "$("$S" status --id "$IDK")" "UNSTABLE"
out="$("${NS[@]}" "${POLL[@]}" INTERCOM_WATCH_MAX_SECS=2 "$S" watch --me B --id "$IDK" 2>&1)"
has "arming on an unstable channel warns" "$out" "Do NOT tell the user"
# Old reaps age out of the window.
h="$(INTERCOM_REAP_WINDOW_SECS=0 "$S" health --me B --id "$IDK")"
has "reaps outside the window don't count" "$h" "unstable=0"

echo "== stop guard: backs off instead of looping on an unstable channel =="
TRK="$(mkfake B "$IDK")"
out="$(hookin "$TRK" | "$GUARD")"
no  "guard does not block when re-arm cannot hold" "$out" '"decision":"block"'
has "guard tells the user why" "$out" '"systemMessage"'
has "guard names the channel" "$out" "$IDK"
out="$(hookin "$TRK" | INTERCOM_REAP_WINDOW_SECS=0 "$GUARD")"
has "guard blocks again once the reaps age out" "$out" '"decision":"block"'
out="$(hookin "$TRK" | INTERCOM_REAP_WINDOW_SECS=0 INTERCOM_NO_PS=1 "$GUARD")"
has "INTERCOM_NO_PS does not disable the guard" "$out" '"decision":"block"'

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

echo "== send warns when nobody is armed to receive it =="
IDN="$(newid A)"
"$S" send --me A --id "$IDN" --msg one >/dev/null
"$S" read --me B --id "$IDN" >/dev/null 2>&1        # B is now a participant, not watching
out="$(INTERCOM_NO_SENTINEL=1 "$S" send --me A --id "$IDN" --msg two 2>&1)"
has "send flags the deaf peer" "$out" "no live watcher"
has "send names who won't wake" "$out" "B"
# ...and stays quiet when a watcher IS armed. B must be caught up first, or the
# watcher delivers the backlog and exits before the next send ever looks for it.
"$S" read --me B --id "$IDN" >/dev/null 2>&1
( env INTERCOM_POLL_SECS=1 INTERCOM_WATCH_MAX_SECS=8 INTERCOM_NO_SENTINEL=1 PATH=/usr/bin:/bin \
    "$S" watch --me B --id "$IDN" >/dev/null 2>&1 ) &
WPID=$!; wait_watcher "$IDN"
out="$(INTERCOM_NO_SENTINEL=1 "$S" send --me A --id "$IDN" --msg three 2>&1)"
no "no false alarm while a watcher lives" "$out" "no live watcher"
wait $WPID 2>/dev/null || true

echo "== sentinel: detaches, survives its spawner, notifies, stays a pure observer =="
# Its own comms dir, so it gets a fresh daemon with fast timings (the machine's
# ONE sentinel keeps the settings of whoever started it).
SD="$WORK/sent"; mkdir -p "$SD"
SEN=(env INTERCOM_DIR="$SD" INTERCOM_SENTINEL_POLL_SECS=1 INTERCOM_SENTINEL_GRACE_SECS=1)
IDS="$(INTERCOM_DIR="$SD" newid A sentinel)"
INTERCOM_DIR="$SD" "$S" read --me B --id "$IDS" >/dev/null 2>&1
# Spawn from a subshell that exits immediately: if the sentinel were a plain
# child it would die with it. That is the entire point of the double-fork.
( "${SEN[@]}" "$S" sentinel --me B --id "$IDS" --spawn >/dev/null 2>&1 ) &
wait $! 2>/dev/null || true
sleep 2
PF="$SD/.state/.sentinel/run/pid"
if [[ -f "$PF" ]] && kill -0 "$(cat "$PF")" 2>/dev/null; then ok "sentinel outlived its spawner"
else bad "sentinel outlived its spawner (no live pid at $PF)"; fi
SPID="$(cat "$PF" 2>/dev/null || echo 0)"
# Detachment evidence: it sits in a different process group than us (setsid), and
# it has been reparented to init (ppid 1) — so killing our tree cannot reach it.
# (macOS `ps -o sess=` reports 0, hence pgid+ppid rather than a session compare.)
SPGID="$(ps -o pgid= -p "$SPID" 2>/dev/null | tr -d ' ' || true)"
OURPGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
SPPID="$(ps -o ppid= -p "$SPID" 2>/dev/null | tr -d ' ' || true)"
if [[ "$SPID" != 0 && -n "$SPGID" && "$SPGID" != "$OURPGID" ]]; then
  ok "sentinel left our process group"
else bad "sentinel shares our process group (pgid=$SPGID ours=$OURPGID)"; fi
eq "sentinel reparented to init" "$SPPID" "1"

echo "== sentinel: ONE process covers every channel =="
IDS2="$(INTERCOM_DIR="$SD" newid A second)"
"${SEN[@]}" "$S" sentinel --me B --id "$IDS2" --spawn >/dev/null 2>&1
"${SEN[@]}" "$S" sentinel --me B --id "$IDS2" --spawn >/dev/null 2>&1   # repeat is a no-op
sleep 1
eq "second channel reuses the same daemon" "$(cat "$PF" 2>/dev/null)" "$SPID"
[[ -f "$SD/.state/.sentinel/B@$IDS2" ]] && ok "second channel registered" || bad "second channel registered"
eq "health sees the sentinel" "$(INTERCOM_DIR="$SD" "$S" health --me B --id "$IDS2" | grep '^sentinel=')" "sentinel=1"

echo "== sentinel: notifies without touching read state =="
WM_BEFORE="$(cat "$SD/.state/B/$IDS" 2>/dev/null || echo 0)"
INTERCOM_DIR="$SD" "$S" send --me A --id "$IDS" --msg "unread and unwatched" >/dev/null 2>&1
sleep 5
eq "sentinel never touched the watermark" "$(cat "$SD/.state/B/$IDS" 2>/dev/null || echo 0)" "$WM_BEFORE"
[[ -f "$SD/.state/B/$IDS.peek" ]] && bad "sentinel wrote a delivery marker" || ok "sentinel wrote no delivery marker"
has "sentinel logged the deaf channel" "$(cat "$SD/.state/.sentinel/log" 2>/dev/null || true)" "no watcher armed"

echo "== sentinel: drops closed and idle channels, then exits =="
INTERCOM_DIR="$SD" "$S" close --me B --id "$IDS" --force >/dev/null 2>&1
sleep 3
[[ -f "$SD/.state/.sentinel/B@$IDS" ]] && bad "closed channel dropped" || ok "closed channel dropped"
if kill -0 "$SPID" 2>/dev/null; then ok "still running for the other channel"
else bad "still running for the other channel"; fi
# Age the remaining channel and its registration past the idle limit. A running
# daemon keeps the limit it started with, so restart it with a short one.
kill "$SPID" 2>/dev/null; sleep 1
sf=( "$SD/${IDS2}__"*.txt ); touch -t 202001010000 "${sf[0]}"
printf '1 0 0 0\n' > "$SD/.state/.sentinel/B@$IDS2"
( env INTERCOM_DIR="$SD" INTERCOM_SENTINEL_POLL_SECS=1 INTERCOM_SENTINEL_IDLE_SECS=60 \
    "$S" sentinel >/dev/null 2>&1 & )
sleep 3
[[ -f "$SD/.state/.sentinel/B@$IDS2" ]] && bad "idle channel dropped" || ok "idle channel dropped"
SPID2="$(cat "$PF" 2>/dev/null || echo 0)"
if [[ "$SPID2" != 0 ]] && kill -0 "$SPID2" 2>/dev/null; then bad "exits once nothing is left"; kill "$SPID2" 2>/dev/null
else ok "exits once nothing is left"; fi
[[ -d "$SD/.state/.sentinel/run" ]] && bad "released its lock" || ok "released its lock"
# ...and a later spawn starts a fresh one.
IDS3="$(INTERCOM_DIR="$SD" newid A third)"
"${SEN[@]}" "$S" sentinel --me B --id "$IDS3" --spawn >/dev/null 2>&1; sleep 1
if [[ -f "$PF" ]] && kill -0 "$(cat "$PF")" 2>/dev/null; then ok "next spawn starts a new daemon"
else bad "next spawn starts a new daemon"; fi

# Leave no detached processes behind from this run.
for pf in "$WORK"/.state/.sentinel/run/pid "$SD"/.state/.sentinel/run/pid; do
  [[ -f "$pf" ]] && kill "$(cat "$pf" 2>/dev/null || echo 0)" 2>/dev/null || true
done

echo
echo "==== $PASS passed, $FAIL failed ===="
(( FAIL == 0 ))

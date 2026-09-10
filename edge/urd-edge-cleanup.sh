#!/bin/bash
# ===========================================================================
#  urd-edge-cleanup.sh - stop OUR collection on this Edge and verify.
#
#  Use it in two situations:
#    a) the window is over and the files have been copied out
#    b) you want to ABORT a run and start again with a corrected config
#
#  RUN this ON every EDGE OF THE CLUSTER.
#     A span session is not confined to the Edge where you created it.
#     Creating one on a single Edge also creates span-<N> on the other Edge
#     that owns the same LIF. Verified in the lab: created on <edge01> only,
#     span-1 appeared on <edge02> as well. If it is not removed, mirroring
#     keeps running and keeps loading the dataplane.
#
#  ------------------------------------------------------------------------
#  SAFETY RULES - this script runs on a production Edge. It must never touch
#  anything that is not ours. Every destructive action is narrowed as follows:
#
#   1. PROCESSES
#      Only tcpdump processes whose "-w" path is inside $OUT are stopped, and
#      only our own script names. Someone else's tcpdump, or a capture written
#      anywhere else, is left alone. Never a bare "pkill tcpdump".
#
#   2. SPAN SESSIONS
#      Only the ids in CAP_SESSION_VPCT1 / CAP_SESSION_LBT1 are released.
#      Sessions created by anyone else are not touched.
#      "--all-sessions" releases 0-7 - use it only when you are certain no one
#      else is capturing on this Edge.
#
#   3. FILES  (--all only)
#      $OUT itself is never handed to "rm -rf" blindly. The path is validated
#      first, and then only OUR OWN subtrees are removed:
#          $OUT/pcap  $OUT/stats-<EDGE_TAG>  $OUT/sessions-<EDGE_TAG>
#      $OUT is then removed only if it became empty.
#
#   4. Nothing is deleted unless you pass --all. Default keeps every file.
#  ------------------------------------------------------------------------
#
#  USAGE
#      bash urd-edge-cleanup.sh                 # stop ours, KEEP the files
#      bash urd-edge-cleanup.sh --all           # also delete our own files
#      bash urd-edge-cleanup.sh --dry-run       # show what it would do only
#      bash urd-edge-cleanup.sh --all-sessions  # also release span ids 0-7
# ===========================================================================
. "$(dirname "${BASH_SOURCE[0]}")/urd-edge-lib.sh"

DELETE=0; DRY=0; ALLSESS=0
for a in "$@"; do
  case "$a" in
    --all)          DELETE=1 ;;
    --dry-run|-n)   DRY=1 ;;
    --all-sessions) ALLSESS=1 ;;
    *) echo "unknown option: $a" >&2
       echo "usage: $(basename "$0") [--all] [--dry-run] [--all-sessions]" >&2; exit 2 ;;
  esac
done
[ "$DRY" = 1 ] && log "DRY RUN - nothing will be stopped or deleted"

run() { if [ "$DRY" = 1 ]; then echo "    would run: $*"; else "$@"; fi; }

log "$(hostname) cleanup start"
rm -f "$OUT"/.urd-end-* 2>/dev/null   # stale "ends in" markers

# --------------------------------------------------------------------------
# 0) SAFETY: validate $OUT before it is used for matching or deletion
# --------------------------------------------------------------------------
case "$OUT" in
  /*) ;;
  *)  die "OUT is not an absolute path: '$OUT'. refusing to do anything." ;;
esac
case "$OUT" in
  *..*) die "OUT contains '..': '$OUT'. refusing." ;;
esac
# must be at least /a/b, and the last element must look like ours
DEPTH=$(echo "$OUT" | awk -F/ '{n=0; for(i=1;i<=NF;i++) if($i!="") n++; print n}')
[ "$DEPTH" -ge 2 ] || die "OUT is too shallow: '$OUT'. refusing."
case "$(basename "$OUT")" in
  *urd*) ;;
  *) die "OUT does not look like a collection dir (no 'urd' in '$OUT'). refusing." ;;
esac

# --------------------------------------------------------------------------
# 1) stop OUR captures - matched by the output path, not by "tcpdump"
# --------------------------------------------------------------------------
# our tcpdump command line always contains  -w <OUT>/pcap/urd-...
CAPPAT="tcpdump.*-w $OUT/pcap/urd-"

# PIDs matching a pattern, excluding this script and its parent shell
pids_of() {
  pgrep -f "$1" 2>/dev/null | grep -v "^$$\$" | grep -v "^$PPID\$"
}

P=$(pids_of "$CAPPAT")
if [ -n "$P" ]; then
  log "  stopping $(echo "$P" | grep -c .) capture(s) writing into $OUT/pcap"
  for p in $P; do
    echo "      pid $p : $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-110)"
  done
  # INT lets tcpdump close the pcap cleanly
  [ "$DRY" = 1 ] || kill -INT $P 2>/dev/null
  [ "$DRY" = 1 ] || sleep 3
else
  log "  captures: none of ours running"
fi

OTHER=$(pgrep -cf "tcpdump" 2>/dev/null); OTHER=${OTHER:-0}
STILL=$(pids_of "$CAPPAT" | grep -c .)
if [ "$OTHER" -gt "$STILL" ]; then
  log "  note: other tcpdump process(es) are running on this Edge. not touched."
fi

# --------------------------------------------------------------------------
# 2) stop OUR scripts - names are unique to this toolkit
# --------------------------------------------------------------------------
stop_script() {   # $1 = exact script filename
  # bare name, not "/$1": a collector started as "bash urd-edge-stats.sh"
  # has no slash in its command line and would otherwise survive the cleanup.
  local P; P=$(pids_of "$1")
  [ -z "$P" ] && return 0
  log "  stopping $1 ($(echo "$P" | grep -c .))"
  [ "$DRY" = 1 ] && return 0
  kill $P 2>/dev/null
  sleep 3
  P=$(pids_of "$1")
  if [ -n "$P" ]; then
    # a loop sitting in "sleep INTERVAL" ignores TERM until the sleep returns;
    # KILL is not deferred
    log "  $1 still alive, sending KILL"
    kill -9 $P 2>/dev/null
    sleep 1
  fi
}
for S in urd-edge-stats.sh urd-edge-sessions.sh \
         urd-edge-cap-lbt1-svc.sh urd-edge-cap-vpct1-uplink.sh; do
  stop_script "$S"
done

# --------------------------------------------------------------------------
# 3) release only our span sessions
# --------------------------------------------------------------------------
if [ "$ALLSESS" = 1 ]; then
  SESS="0 1 2 3 4 5 6 7"
  log "  --all-sessions: releasing ids $SESS (this also drops sessions created by others)"
else
  SESS=""
  for v in "${CAP_SESSION_VPCT1:-}" "${CAP_SESSION_LBT1:-}"; do
    [ -n "$v" ] && SESS="$SESS $v"
  done
  [ -n "$SESS" ] || SESS="0 1"
  log "  releasing our span sessions:$SESS  (others left alone)"
fi
for i in $SESS; do
  if [ "$DRY" = 1 ]; then
    echo "    would run: su admin -c \"del capture session $i\""
    continue
  fi
  # "Span session does not exist" is the NORMAL answer when the capture
  # already finished and released it. Do not print it as if it were a fault.
  o=$(su admin -c "del capture session $i" 2>&1)
  case "$o" in
    *"does not exist"*) log "    session $i : already released" ;;
    "")                 log "    session $i : released" ;;
    *)                  log "    session $i : $o" ;;
  esac
done
[ "$DRY" = 1 ] || sleep 2

# --------------------------------------------------------------------------
# 4) verify
# --------------------------------------------------------------------------
SPAN=$(ip -br link 2>/dev/null | grep -c span)
TD=$(pids_of "$CAPPAT" | grep -c .)
LOOP=0
for S in urd-edge-stats.sh urd-edge-sessions.sh; do
  LOOP=$((LOOP + $(pids_of "$S" | grep -c .)))
done

echo
echo "  span interfaces (any owner) : ${SPAN}"
echo "  our captures running        : ${TD}   $([ "$TD" -eq 0 ] && echo '(ok)' || echo '<-- still present')"
echo "  our polling loops           : ${LOOP}   $([ "$LOOP" -eq 0 ] && echo '(ok)' || echo '<-- still present')"
[ "$SPAN" -gt 0 ] && echo "  -> span interfaces remain. If they are not yours, leave them."
echo

# --------------------------------------------------------------------------
# 5) files - only our own subtrees, never a blind rm -rf on $OUT
# --------------------------------------------------------------------------
OURS=("$OUT/pcap" "$OUT/stats-${EDGE_TAG}" "$OUT/sessions-${EDGE_TAG}")
if [ "$DELETE" = 1 ]; then
  for d in "${OURS[@]}"; do
    if [ -d "$d" ]; then
      log "  deleting $d ($(du -sh "$d" 2>/dev/null | cut -f1))"
      run rm -rf "$d"
    fi
  done
  # remove $OUT only if WE emptied it - never force
  if [ -d "$OUT" ] && [ -z "$(ls -A "$OUT" 2>/dev/null)" ]; then
    run rmdir "$OUT"
  elif [ -d "$OUT" ]; then
    echo "  $OUT still has files that are not ours - left in place:"
    ls -1 "$OUT" | sed 's/^/      /'
  fi
else
  if [ -d "$OUT" ]; then
    echo "  collected files : $OUT ($(du -sh "$OUT" 2>/dev/null | cut -f1)) - kept"
    echo "                    delete ours with:  bash $(basename "$0") --all"
  fi
fi
echo

if [ "$DRY" = 1 ]; then
  log "DRY RUN finished - nothing was stopped or deleted"
  exit 0
elif [ "$TD" -eq 0 ] && [ "$LOOP" -eq 0 ]; then
  log "$(hostname) cleanup done"
else
  echo "something of ours is still running. check manually:" >&2
  echo "    pgrep -af 'tcpdump.*$OUT'" >&2
  exit 1
fi

cat <<TXT

Only this Edge was cleaned. Run the same script on every other Edge.
  check:  ssh root@<other-edge> "ip -br link | grep span"
TXT

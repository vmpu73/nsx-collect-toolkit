#!/bin/sh
# ===========================================================================
#  urd-esxi-cleanup.sh - stop OUR collection on this ESXi host and verify.
#
#  Use it in two situations:
#    a) the window is over and the files have been copied out
#    b) you want to ABORT a run and start again with a corrected config
#
#  This host only. Run it on every ESXi host you collected from.
#
#  ------------------------------------------------------------------------
#  SAFETY RULES - this runs on a production hypervisor. It must never touch
#  anything that is not ours. Every destructive action is narrowed as follows:
#
#   1. PROCESSES
#      Only pktcap-uw processes whose "-o" path is inside $OUT AND whose file
#      name starts with urd-<HOST_TAG>-dfw- are stopped.
#      A bare "pkill pktcap-uw" would also kill captures started by VMware
#      support or by another engineer. That has actually happened in the lab
#      (an unrelated "pktcap-uw --capture Drop" was running on a host).
#      Never do that. Our own script names are matched exactly as well.
#
#   2. FILES  (--all only)
#      $OUT is never handed to "rm -rf" blindly. The path is validated first,
#      and then only OUR OWN artifacts are removed:
#          $OUT/urd-<HOST_TAG>-dfw-*.pcap*
#          $OUT/stats-<HOST_TAG>      $OUT/dfw-<HOST_TAG>
#      $OUT is then removed only if it became empty.
#      Anything else in $OUT is listed and left in place.
#
#   3. Nothing is deleted unless you pass --all. Default keeps every file.
#  ------------------------------------------------------------------------
#
#  USAGE
#      sh urd-esxi-cleanup.sh              # stop ours, KEEP the files
#      sh urd-esxi-cleanup.sh --all        # also delete our own files
#      sh urd-esxi-cleanup.sh --dry-run    # show what it would do only
#
#  Note: busybox sh. No bash syntax.
# ===========================================================================
. "$(dirname "$0")/urd-esxi-lib.sh"

SELF="urd-esxi-cleanup"
DELETE=0; DRY=0
for a in "$@"; do
  case "$a" in
    --all)        DELETE=1 ;;
    --dry-run|-n) DRY=1 ;;
    *) echo "unknown option: $a" >&2
       echo "usage: $(basename "$0") [--all] [--dry-run]" >&2; exit 2 ;;
  esac
done
[ "$DRY" = 1 ] && log "DRY RUN - nothing will be stopped or deleted"

log "$(hostname) cleanup start"
rm -f "$OUT"/.urd-end-* 2>/dev/null   # stale "ends in" markers

# --------------------------------------------------------------------------
# 0) SAFETY: validate $OUT before it is used for matching or deletion
# --------------------------------------------------------------------------
case "$OUT" in
  /*)   ;;
  *)    die "OUT is not an absolute path: '$OUT'. refusing to do anything." ;;
esac
case "$OUT" in
  *..*) die "OUT contains '..': '$OUT'. refusing." ;;
esac
DEPTH=$(echo "$OUT" | awk -F/ '{n=0; for(i=1;i<=NF;i++) if($i!="") n++; print n}')
[ "$DEPTH" -ge 2 ] || die "OUT is too shallow: '$OUT'. refusing."
case "$(basename "$OUT")" in
  *urd*) ;;
  *) die "OUT does not look like a collection dir (no 'urd' in '$OUT'). refusing." ;;
esac
[ -n "$HOST_TAG" ] || die "HOST_TAG is empty. refusing - cannot tell our files apart."

# --------------------------------------------------------------------------
# World ids matching a pattern.
# Excludes this script, its parent shell and grep. Without the PID filter the
# shell that LAUNCHED the collection also matches (its command line still
# contains the script name) and shows up as a process that cannot be killed.
# --------------------------------------------------------------------------
# script_pids comes from the library - one definition, one behaviour.
# "$SELF" is dropped as well so this script never targets itself.
pids_of() { script_pids "$1" | while read _p; do
    ps -c 2>/dev/null | awk -v w="$_p" -v self="$SELF" '$1==w && $0 !~ self {print $1}'
  done; }
count_of() { pids_of "$1" | grep -c . ; }

stop_pat() {   # $1 = pattern  $2 = label
  P=$(pids_of "$1")
  if [ -z "$P" ]; then echo "  $2: none of ours running"; return 0; fi
  echo "  $2: stopping $(echo "$P" | grep -c .) process(es)"
  for p in $P; do
    echo "      wid $p : $(ps -c | awk -v w="$p" '$1==w{$1="";$2="";$3="";print}' | cut -c1-100)"
  done
  [ "$DRY" = 1 ] && return 0
  for p in $P; do kill "$p" 2>/dev/null; done
  sleep 3
  P=$(pids_of "$1")
  if [ -n "$P" ]; then
    # a loop sitting in "sleep INTERVAL" ignores TERM until that sleep
    # returns (up to INTERVAL seconds). KILL is not deferred.
    echo "  $2: still alive, sending KILL"
    for p in $P; do kill -9 "$p" 2>/dev/null; done
    sleep 2
  fi
  # an orphaned "sleep" child may linger briefly. It is harmless and exits by
  # itself - do not kill sleeps host-wide, other work on this host uses them.
}

# our pktcap-uw command line always contains  -o <OUT>/urd-<HOST_TAG>-dfw-
CAPPAT="pktcap-uw.*-o $OUT/urd-$HOST_TAG-dfw-"

stop_pat "$CAPPAT"                    "captures      "
stop_pat "urd-esxi-stats.sh"          "stats loop    "
stop_pat "urd-esxi-dfw-sessions.sh"   "sessions loop "

ALLPK=$(ps -c 2>/dev/null | grep -c "[p]ktcap-uw")
OURPK=$(count_of "$CAPPAT")
if [ "$ALLPK" -gt "$OURPK" ]; then
  echo
  echo "  note: $((ALLPK - OURPK)) other pktcap-uw process(es) are running on this"
  echo "        host and were not touched. They belong to someone else."
fi

S=$(count_of "urd-esxi-stats.sh")
D=$(count_of "urd-esxi-dfw-sessions.sh")

echo
echo "  our captures running : $OURPK   $([ "$OURPK" -eq 0 ] && echo '(ok)' || echo '<-- still present')"
echo "  stats loop           : $S   $([ "$S" -eq 0 ] && echo '(ok)' || echo '<-- still present')"
echo "  sessions loop        : $D   $([ "$D" -eq 0 ] && echo '(ok)' || echo '<-- still present')"
echo

# --------------------------------------------------------------------------
# files - only our own artifacts, never a blind rm -rf on $OUT
# --------------------------------------------------------------------------
if [ "$DELETE" = 1 ]; then
  for d in "$OUT/stats-$HOST_TAG" "$OUT/dfw-$HOST_TAG"; do
    if [ -d "$d" ]; then
      echo "  deleting $d"
      [ "$DRY" = 1 ] || rm -rf "$d"
    fi
  done
  rm -f "$OUT"/.urd-end-* 2>/dev/null
  for f in "$OUT/urd-$HOST_TAG-dfw-"*.pcap*; do
    [ -e "$f" ] || continue
    echo "  deleting $f"
    [ "$DRY" = 1 ] || rm -f "$f"
  done
  if [ -d "$OUT" ]; then
    LEFT=$(ls -A "$OUT" 2>/dev/null)
    if [ -z "$LEFT" ]; then
      [ "$DRY" = 1 ] || rmdir "$OUT" 2>/dev/null
      echo "  $OUT removed (was empty)"
    else
      echo "  $OUT still has files that are not ours - left in place:"
      echo "$LEFT" | sed 's/^/      /'
    fi
  fi
else
  if [ -d "$OUT" ]; then
    echo "  collected files : $OUT ($(du -sh "$OUT" 2>/dev/null | awk '{print $1}')) - kept"
    echo "                    delete ours with:  sh $(basename "$0") --all"
  else
    echo "  collected files : none"
  fi
fi
echo

if [ "$DRY" = 1 ]; then
  log "DRY RUN finished - nothing was stopped or deleted"
  exit 0
elif [ "$OURPK" -eq 0 ] && [ "$S" -eq 0 ] && [ "$D" -eq 0 ]; then
  log "$(hostname) cleanup done"
else
  echo "something of ours is still running. check manually:" >&2
  echo "    ps -c | grep pktcap-uw" >&2
  exit 1
fi

cat <<TXT

Only this host was cleaned. Run the same script on every ESXi host you used.
TXT

#!/bin/bash
# ===========================================================================
#  urd-edge-lib.sh - shared helper functions
#
#  DO not RUN this FILE. DO not EDIT IT.
#  It is sourced by urd-edge-cap-*.sh, urd-edge-stats.sh,
#  urd-edge-sessions.sh and urd-edge-cleanup.sh.
#  It only needs to sit in the same directory.
#
#  Provides: config loading, defaults, root/CLI check, span session
#            open/close, tcpdump capture, logging, result file writing.
# ===========================================================================
set -uo pipefail
_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${URD_EDGE_CONF:-$_D/urd-edge.conf}"
[ -r "$CONF" ] || { echo "config not found: $CONF" >&2; exit 2; }
. "$CONF"

: "${OUT:=/var/dump/urd}"; : "${EDGE_TAG:=edge}"
: "${CAP_SECS:=600}"; : "${CAP_SNAPLEN:=}"
: "${CAP_FILESIZE:=100}"; : "${CAP_FILECOUNT:=5}"
: "${INTERVAL:=30}"; : "${DURATION:=1200}"; : "${PROTO:=udp}"

# root is required: we call the NSX CLI through "su admin" and run tcpdump
[ "$(id -u)" = "0" ] || { echo "must run as root." >&2; exit 2; }
su admin -c "get version" >/dev/null 2>&1 \
  || { echo "NSX CLI (admin) call failed. Is this an NSX Edge?" >&2; exit 2; }

log(){ printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "$*" >&2; exit 2; }
need(){ local m=() v; for v in "$@"; do [ -n "${!v:-}" ] || m+=("$v"); done
        [ ${#m[@]} -eq 0 ] || { echo "empty settings in $CONF:" >&2; printf '  - %s\n' "${m[@]}" >&2; exit 2; }; }

# NSX CLI. "su admin -c" everywhere; nsxcli also exists on the root shell and
# works too, but span session control uses su admin, so keep one style.
cli(){ su admin -c "$1" 2>&1; }

# --- capture: span mirror interface + plain tcpdump -----------------------
#  Creating a span session through the admin CLI makes a Linux interface
#  span-<N>. A normal tcpdump is then attached to it.
#
#  Why this instead of "start capture":
#    - tcpdump parses the BPF itself: no CLI quoting problems, no or/() limits
#    - -C/-W give a real ring buffer
#    - writes straight to /var/dump, so no filestore limits, no .tgz packing,
#      no lost files
#    - timeout -s INT ends it by wall clock, so it does not hang when the
#      traffic stops
#
#  Danger: tcpdump drops privileges by default. With -C/-W it then cannot
#  create the next file and fails with "Permission denied". -Z root fixes it.
#
#  Note: a span session created on one Edge also appears on the other Edge
#  of the cluster. Clean up on every Edge (urd-edge-cleanup.sh).

span_open() {   # $1=session id  $2=LIF UUID
  su admin -c "set capture session $1 interface $2 direction dual" >/dev/null 2>&1
  local i=0
  while [ $i -lt 10 ]; do
    ip link show "span-$1" >/dev/null 2>&1 && return 0
    sleep 1; i=$((i+1))
  done
  # The session may well have been created even though span-<N> never showed
  # up (wrong LIF UUID, LIF on the other Edge, ...). Leaving it behind keeps
  # mirroring running on every Edge of the cluster. Always take it back.
  su admin -c "del capture session $1" >/dev/null 2>&1
  return 1
}

span_close() {  # $1=session id
  su admin -c "del capture session $1" >/dev/null 2>&1
}

cap() {  # $1=label $2=LIF UUID $3=BPF $4=seconds $5=session id
  local label="$1" lif="$2" filt="$3" secs="$4" sess="${5:-0}"
  local base="$OUT/pcap/urd-${EDGE_TAG}-${label}-$(date '+%H%M%S').pcap"
  mkdir -p "$OUT/pcap"

  log "capture $label"
  log "  interface : $lif  (span-$sess)"
  log "  filter    : $filt"
  log "  duration  : ${secs}s"
  log "  snaplen   : ${CAP_SNAPLEN:-full packet}"
  log "  files     : ${base}[0..$((CAP_FILECOUNT-1))]  max $((CAP_FILESIZE*CAP_FILECOUNT))MB"

  check_cap_budget 1
  mark_start "cap-$label" "$secs"
  span_open "$sess" "$lif" || { echo "failed to create span-$sess. check the LIF UUID." >&2; return 1; }
  trap "span_close $sess" EXIT INT TERM

  # empty CAP_SNAPLEN -> no -s flag -> tcpdump keeps the whole packet
  SNAPOPT=""
  [ -n "${CAP_SNAPLEN:-}" ] && SNAPOPT="-s $CAP_SNAPLEN"
  timeout -s INT "$secs" tcpdump -nei "span-$sess" -Z root \
      $SNAPOPT -C "$CAP_FILESIZE" -W "$CAP_FILECOUNT" \
      -w "$base" "$filt" 2>&1 | tail -4

  span_close "$sess"
  mark_done "cap-$label"
  # restore the script-wide handler instead of clearing it
  trap - EXIT
  trap 'echo; echo "interrupted"; exit 130' INT TERM
  log "done. files:"
  ls -l "${base}"* 2>/dev/null | sed 's/^/    /'
}

# --- free space -----------------------------------------------------------
#  /var/dump on an Edge is large (lab: 54 GB free) and the text output is
#  small and paced by INTERVAL, so it is not a concern. What is worth a guard
#  is a mistyped CAP_FILESIZE/CAP_FILECOUNT: the ring buffer caps its own
#  files, so whatever is configured will be written.
MIN_FREE_MB="${MIN_FREE_MB:-1024}"

free_mb(){ df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

check_cap_budget(){   # $1 = number of concurrent captures
  local n="$1" need f
  need=$(( CAP_FILESIZE * CAP_FILECOUNT * n ))
  f=$(free_mb "$OUT")
  log "  capture budget: ${CAP_FILESIZE}MB x ${CAP_FILECOUNT} files = ${need} MB"
  [ -n "$f" ] || { log "  Warning: free space unknown - continuing"; return 0; }
  log "  free space in $OUT: ${f} MB"
  [ "$need" -lt "$f" ] || die "capture budget ${need} MB does not fit in ${f} MB free at $OUT.
Lower CAP_FILESIZE or CAP_FILECOUNT in urd-edge.conf."
  return 0
}

# Called once per sample by the polling loops.
space_ok(){
  local f; f=$(free_mb "$OUT")
  [ -n "$f" ] || return 0
  [ "$f" -ge "$MIN_FREE_MB" ] && return 0
  log "  STOPPING: only ${f} MB free in $OUT (MIN_FREE_MB=$MIN_FREE_MB)."
  return 1
}

# ===========================================================================
#  SCREEN
#  Pure ASCII only. Box drawing characters and anything above 7 bit gets
#  mangled by the terminals these scripts run in - that is why the whole
#  toolkit is ASCII. Fixed 72 column width so nothing wraps.
# ===========================================================================
UIW=70                     # inner width between the frame characters

ui_rule()  { printf '+%s+\n' "$(printf '=%.0s' $(seq 1 $UIW))"; }
ui_thin()  { printf '  %s\n' "$(printf -- '-%.0s' $(seq 1 $((UIW-2))))"; }
# Never let a long value break the frame - cut anything wider than UIW.
ui_row()   { printf '|%-*.*s|\n' "$UIW" "$UIW" "$1"; }
ui_blank() { ui_row ""; }

# a titled frame:  +====+ | TITLE | +====+
ui_head() {   # $1 = title  $2..= extra lines
  ui_rule
  ui_row "  $1"
  shift
  while [ $# -gt 0 ]; do ui_row "  $1"; shift; done
  ui_rule
}

# one line band used as a section heading inside a screen
ui_band() { ui_rule; ui_row "  $1"; ui_rule; }

# progress bar:  [########------------]  40%
#   $1 = done   $2 = total   $3 = width (default 20)
ui_bar() {
  local done="$1" total="$2" w="${3:-20}" f p
  if [ -z "$total" ] || [ "$total" -le 0 ]; then
    printf '[%s]     ' "$(printf -- '-%.0s' $(seq 1 $w))"
    return
  fi
  [ "$done" -lt 0 ] && done=0
  [ "$done" -gt "$total" ] && done="$total"
  p=$(( done * 100 / total ))
  f=$(( done * w / total ))
  printf '['
  [ "$f" -gt 0 ] && printf '#%.0s' $(seq 1 $f)
  [ "$f" -lt "$w" ] && printf -- '-%.0s' $(seq 1 $((w-f)))
  printf '] %3d%%' "$p"
}

# human readable size from bytes
ui_size() {
  local b="${1:-0}"
  if   [ "$b" -ge 1073741824 ]; then awk -v b="$b" 'BEGIN{printf "%.1f GB", b/1073741824}'
  elif [ "$b" -ge 1048576 ];    then awk -v b="$b" 'BEGIN{printf "%.1f MB", b/1048576}'
  elif [ "$b" -ge 1024 ];       then awk -v b="$b" 'BEGIN{printf "%.1f KB", b/1024}'
  else echo "${b} B"; fi
}

# "2m30s"
ui_time() { local s="${1:-0}"; [ "$s" -lt 0 ] && s=0; printf '%dm%02ds' $((s/60)) $((s%60)); }

# --- finding OUR processes ------------------------------------------------
#  One matcher, used by the cleanup script AND by the status screen, so they
#  can never disagree about what is running.
#
#  It must match however the collector was started:
#      bash urd-edge-stats.sh          (from inside the directory)
#      bash ./urd-edge-stats.sh
#      bash /root/urd/urd-edge-stats.sh
#  Matching "/urd-edge-stats.sh" only catches the last form - a collector
#  started by hand then looks stopped AND survives the cleanup. That is worse
#  than a cosmetic bug, so match the bare file name and drop our own PIDs.
script_pids() {   # $1 = script file name
  pgrep -f "$1" 2>/dev/null | grep -v "^$$\$" | grep -v "^${PPID:-0}\$"
}

#  A capture is one "timeout" wrapper (which owns one tcpdump). Counting
#  "tcpdump" gives two processes per capture and reads like double.
#  $1 is the capture label (lbt1-svc, vpct1-uplink). Without it the two
#  captures cannot be told apart and starting one makes both look running.
capture_pids() {
  local lbl="${1:-}"
  pgrep -f "timeout .*tcpdump.*-w $OUT/pcap/urd-${EDGE_TAG}-${lbl}" 2>/dev/null
}

# --- "when does it finish?" -----------------------------------------------
#  A collector that runs in the background gives no clue how long it still
#  has to go. Each one drops a marker holding its end time, so the status
#  screen can just subtract. The marker is removed when the run ends, and a
#  stale one (process already gone) is reported as finished.
mark_start(){ mkdir -p "$OUT" 2>/dev/null; echo $(( $(date +%s) + $2 )) > "$OUT/.urd-end-$1" 2>/dev/null; }
# Write "done" rather than removing the marker. A removed marker is
# indistinguishable from one that never ran, so a finished capture would show
# as idle. The cleanup script removes the markers.
mark_done(){  echo done > "$OUT/.urd-end-$1" 2>/dev/null; }

# prints "3m 12s" for a number of seconds
hms(){ local s="$1"; [ "$s" -lt 0 ] && s=0; printf '%dm %02ds' $((s/60)) $((s%60)); }

mkout(){ mkdir -p "$OUT" || die "cannot create output dir: $OUT"; }
snap(){ local file="$1"; shift; { echo "########## $(date '+%F %T %z') ##########"; echo "### $*"; "$@"; echo; } >> "$file" 2>&1; }
trap 'echo; echo "interrupted"; exit 130' INT TERM

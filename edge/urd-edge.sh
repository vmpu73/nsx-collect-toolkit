#!/bin/bash
# ===========================================================================
#  urd-edge.sh - menu front end for the Edge collection scripts
#
#  This is the only file you need to remember on an Edge:
#      bash urd-edge.sh
#
#  It implements nothing itself. It calls the same scripts you would run by
#  hand and prints the command before running it, so you can always see what
#  is executed on a production Edge - and learn the commands.
#
#  Non-interactive use, same actions:
#      bash urd-edge.sh config     show the settings
#      bash urd-edge.sh check      preflight
#      bash urd-edge.sh rehearse   one sample, then show what it produced
#      bash urd-edge.sh start      start all four collectors
#      bash urd-edge.sh status     time left, progress, warnings
#      bash urd-edge.sh watch [s]  status refreshed every s seconds
#      bash urd-edge.sh stop       stop everything, keep the files
#      bash urd-edge.sh wipe       stop everything and delete our files
#      bash urd-edge.sh help       the usage text
#
#  Screen: pure ASCII, fixed 72 columns, no colour. The Edge console and the
#  ESXi console both mangle anything above 7 bit, and tput is not present on
#  ESXi, so the width is never queried.
# ===========================================================================
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$D" || exit 2
. "$D/urd-edge-lib.sh"

LOGDIR="${LOGDIR:-/tmp}"

# --- small helpers ---------------------------------------------------------

# Show the command, then run it. Everything the menu launches goes through
# here, so the screen always tells you what is happening on the box.
run() {
  echo
  echo "  \$ $*"
  ui_thin
  "$@"
  ui_thin
}

pause() { echo; printf "  Press Enter to return to the menu "; read -r _; }

# $OUT does not exist until something has been collected. Walk up to the
# nearest directory that does exist so df has something real to report on.
existing_dir() {
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ] && [ ! -d "$d" ]; do d=$(dirname "$d"); done
  echo "${d:-/}"
}

# one line summary used at the foot of the menu
foot_line() {
  local run=0 s span free
  run=$(( $(capture_pids | grep -c .) ))
  for s in urd-edge-stats.sh urd-edge-sessions.sh; do
    run=$(( run + $(script_pids "$s" | grep -c .) ))
  done
  span=$(ip -br link 2>/dev/null | grep -c span)
  free=$(df -h "$(existing_dir "$OUT")" 2>/dev/null | awk 'NR==2{print $4}')
  printf '   %s running    span %s    %s free\n' "$run" "$span" "${free:-?}"
}

# --- config ----------------------------------------------------------------
show_config() {
  ui_band "CONFIG"
  printf '   %-22s %s\n' "file"        "$CONF"
  printf '   %-22s %s\n' "Edge tag"    "$EDGE_TAG"
  printf '   %-22s %s\n' "output"      "$OUT"
  echo
  printf '   %-22s %s\n' "service"     "$PROTO  VIP $VIP:$SVC_PORT -> backend :$NODE_PORT"
  printf '   %-22s %s\n' "LB SNAT IP"  "${LB_SNAT_IP:-empty - the LB capture will refuse to run}"
  echo
  printf '   %-22s %s\n' "capture"     "${CAP_SECS}s, ring ${CAP_FILESIZE} MB x ${CAP_FILECOUNT}, snaplen ${CAP_SNAPLEN:-full packet}"
  printf '   %-22s %s\n' "polling"     "every ${INTERVAL}s for ${DURATION}s = $((DURATION/INTERVAL)) samples"
  echo
  ui_thin
  echo "   Capture interfaces. Empty means that capture is not run here."
  printf '   %-22s %s\n' "VPC T1 uplink"  "${LIF_VPCT1_UPLINK:-empty}"
  printf '   %-22s %s\n' "LB T1 service"  "${LIF_LBT1_SVC:-empty}"
  echo
  echo "   Logical routers to collect. Empty means skipped, never 'all'."
  printf '   %-22s %s\n' "T0"       "${T0_SR_UUID:-empty}"
  printf '   %-22s %s\n' "T1 VPC"   "${T1_VPC_SR_UUID:-empty}"
  printf '   %-22s %s\n' "T1 LB"    "${T1_LB_SR_UUID:-empty}"
  printf '   %-22s %s\n' "LB"       "${LB_UUID:-empty}"
  printf '   %-22s %s\n' "LB pools" "${LB_POOL_UUIDS:-empty}"
  echo
  echo "   Edit urd-edge.conf to change any of this. The menu never writes it."
}

# --- check -----------------------------------------------------------------
do_check() {
  ui_band "CHECK 1 of 3 - is this Edge active for the routers you care about?"
  echo "   The top 'state' line is this node. The 'Peer Routers' block at the"
  echo "   bottom of the CLI output describes the other node - reading that one"
  echo "   gets Active and Standby backwards."
  echo
  local any=0 tag u st
  for pair in "T0:${T0_SR_UUID:-}" "T1 VPC:${T1_VPC_SR_UUID:-}" "T1 LB:${T1_LB_SR_UUID:-}"; do
    tag="${pair%%:*}"; u="${pair#*:}"
    [ -n "$u" ] || continue
    any=1
    st=$(cli "get logical-router $u high-availability status" | awk '/^state/{print $3; f=1} END{if(!f)print "?"}')
    printf '   %-8s %-40s %s\n' "$tag" "$u" "$st"
  done
  [ "$any" = 1 ] || echo "   No T0_SR_UUID / T1_VPC_SR_UUID / T1_LB_SR_UUID set - nothing to check."
  echo
  echo "   Warning: a capture on a Standby Edge returns zero packets."

  echo
  ui_band "CHECK 2 of 3 - leftovers from an earlier run"
  echo
  echo "   \$ ip -br link | grep span"
  ui_thin
  ip -br link 2>/dev/null | grep span || echo "   none - good"
  ui_thin
  printf '   %-28s %s\n' "our captures running" "$(capture_pids | grep -c .)"
  if [ -d "$OUT" ]; then
    echo "   $OUT exists, holding:"
    ls -1 "$OUT" | sed 's/^/     /'
    echo "   Clear it with 8) stop + delete before the real run."
  else
    echo "   $OUT does not exist yet - nothing has been collected here."
  fi

  echo
  ui_band "CHECK 3 of 3 - disk"
  local dfdir; dfdir=$(existing_dir "$OUT")
  [ "$dfdir" = "$OUT" ] || echo "   $OUT is not created yet, showing its filesystem $dfdir"
  echo
  df -h "$dfdir" 2>/dev/null | sed 's/^/   /'
  echo
  printf '   %-28s %s MB\n' "capture budget" "$(( CAP_FILESIZE * CAP_FILECOUNT ))"
  printf '   %-28s %s MB\n' "stop floor (MIN_FREE_MB)" "$MIN_FREE_MB"
}

# --- rehearse --------------------------------------------------------------
do_rehearse() {
  ui_band "REHEARSAL - one sample, then stop"
  echo "   This proves the UUIDs in the config are right before you commit to"
  echo "   the real window. Nothing runs in the background."
  run bash "$D/urd-edge-stats.sh" once
  run bash "$D/urd-edge-sessions.sh" once
  echo
  ui_band "WHAT IT PRODUCED"
  find "$OUT" -type f 2>/dev/null | sed 's|^|   |' | head -40
  echo "   ... $(find "$OUT" -type f 2>/dev/null | wc -l) files in total"
  echo
  echo "   If that looks right, clear it so the rehearsal is not mixed into"
  echo "   the real data:"
  echo "       in the menu :  8) stop + delete"
  echo "       on one line :  bash urd-edge.sh wipe"
  echo "   Both call urd-edge-cleanup.sh --all."
}

# --- start -----------------------------------------------------------------
start_one() {   # $1=script  $2=logname  $3..=args
  local sc="$1" ln="$2"; shift 2
  if [ ! -f "$D/$sc" ]; then echo "   Missing file: $sc"; return 1; fi
  echo "   \$ nohup bash $sc $* > $LOGDIR/$ln.log 2>&1 </dev/null &"
  nohup bash "$D/$sc" "$@" > "$LOGDIR/$ln.log" 2>&1 </dev/null &
  sleep 1
}

do_start() {
  ui_band "START - all collectors"
  echo "   Captures stop by themselves after CAP_SECS (${CAP_SECS}s) and give"
  echo "   the span session back. Polling runs for DURATION (${DURATION}s)."
  echo
  [ -n "${LIF_LBT1_SVC:-}" ]     && start_one urd-edge-cap-lbt1-svc.sh     lbt1
  [ -n "${LIF_VPCT1_UPLINK:-}" ] && start_one urd-edge-cap-vpct1-uplink.sh vpct1
  start_one urd-edge-stats.sh    stats
  start_one urd-edge-sessions.sh sess
  sleep 6
  echo
  echo "   \$ ip -br link | grep span"
  ui_thin
  ip -br link 2>/dev/null | grep span || echo "   no span yet - give it a few seconds"
  ui_thin
  echo "   Logs: $LOGDIR/{lbt1,vpct1,stats,sess}.log"
  echo "   Watch it with 6) status or w) watch."
}

submenu_start() {
  local n=$(( DURATION / INTERVAL ))
  ui_band "START ONE - pick a single collector"
cat <<TXT
   Packet capture runs for ${CAP_SECS}s, then stops and releases the span.
     1  LB T1 service interface    span-${CAP_SESSION_LBT1:-1}
     2  VPC T1 uplink              span-${CAP_SESSION_VPCT1:-0}

   State comes in two flavours.
     repeat  one sample every ${INTERVAL}s for ${DURATION}s = ${n} samples,
             in the background. This is what the real window uses.
     once    a single sample, right now, then exit. Use it to prove the
             config before committing to the real window.

     3  counters   repeat     interface, physical port, CPU, memory,
                              throughput, flow cache
     4  sessions   repeat     connection tables, LB sessions, pools,
                              health check, SNAT
     5  counters   once
     6  sessions   once

     b  back
TXT
  printf "   choose > "; read -r x
  case "$x" in
    1) start_one urd-edge-cap-lbt1-svc.sh     lbt1 ;;
    2) start_one urd-edge-cap-vpct1-uplink.sh vpct1 ;;
    3) start_one urd-edge-stats.sh            stats ;;
    4) start_one urd-edge-sessions.sh         sess ;;
    5) run bash "$D/urd-edge-stats.sh" once ;;
    6) run bash "$D/urd-edge-sessions.sh" once ;;
    *) return ;;
  esac
  sleep 4; do_status
}

# --- status ----------------------------------------------------------------
# One line per collector: bar, percent, state, time left.
collector_line() {   # $1=label $2=script-or-capture-label $3=marker $4=kind
  local label="$1" what="$2" mark="$3" kind="$4"
  local n end now left total done_ state bar

  if [ "$kind" = cap ]; then n=$(capture_pids "$what" | grep -c .)
  else                       n=$(script_pids "$what" | grep -c .); fi

  end=$(cat "$OUT/.urd-end-$mark" 2>/dev/null)
  # "done" is written when a collector completes, so a finished run is not
  # confused with one that never started
  fin=0
  case "$end" in
    done) fin=1; end="" ;;
    ''|*[!0-9]*) end="" ;;
  esac
  now=$(date +%s)

  if [ "$kind" = cap ]; then total="$CAP_SECS"; else total="$DURATION"; fi

  if [ "$n" -gt 0 ] && [ -n "$end" ]; then
    left=$(( end - now )); [ "$left" -lt 0 ] && left=0
    done_=$(( total - left ))
    bar=$(ui_bar "$done_" "$total")
    printf '   %-16s %s   %-9s %s left\n' "$label" "$bar" "running" "$(ui_time $left)"
  elif [ "$n" -gt 0 ]; then
    printf '   %-16s %s   %-9s %s\n' "$label" "$(ui_bar 0 0)" "running" "started by hand"
  elif [ "$fin" = 1 ] || [ -n "$end" ]; then
    printf '   %-16s %s   %-9s\n' "$label" "$(ui_bar 1 1)" "finished"
  else
    printf '   %-16s %s   %-9s\n' "$label" "$(ui_bar 0 0)" "idle"
  fi
}

produced_lines() {
  local d f n b any=0
  for d in "$OUT/stats-$EDGE_TAG" "$OUT/sessions-$EDGE_TAG"; do
    [ -d "$d" ] || continue
    any=1
    n=$(find "$d" -type f 2>/dev/null | wc -l)
    b=$(du -sk "$d" 2>/dev/null | awk '{print $1*1024}')
    printf '   %-42s %3s files %11s\n' "$(basename "$d")/" "$n" "$(ui_size "${b:-0}")"
  done
  for f in "$OUT"/pcap/*.pcap*; do
    [ -e "$f" ] || continue
    any=1
    b=$(stat -c %s "$f" 2>/dev/null || echo 0)
    printf '   %-42s %15s\n' "pcap/$(basename "$f")" "$(ui_size "$b")"
  done
  [ "$any" = 1 ] || echo "   nothing yet"
}

warning_lines() {
  local w=0 f n avail
  for f in "$OUT"/pcap/*.pcap1; do
    [ -e "$f" ] || continue
    n=$(ls "${f%1}"* 2>/dev/null | wc -l)
    echo "   !  $(basename "${f%1}")* rotated into $n files. The start of the"
    echo "      window has been overwritten. Raise CAP_FILESIZE next time."
    w=1
  done
  avail=$(free_mb "$(existing_dir "$OUT")")
  if [ -n "$avail" ] && [ "$avail" -lt "$MIN_FREE_MB" ]; then
    echo "   !  Only ${avail} MB free. Collectors stop themselves at ${MIN_FREE_MB} MB."
    w=1
  fi
  if [ "$(ip -br link 2>/dev/null | grep -c span)" -gt 0 ] \
     && [ "$(capture_pids | grep -c .)" -eq 0 ]; then
    echo "   !  A span interface is up but no capture is running. It keeps"
    echo "      mirroring on every Edge of the cluster. Run 7) stop."
    w=1
  fi
  [ "$w" = 0 ] && echo "   none"
}

do_status() {
  ui_band "COLLECTORS"
  collector_line "LB T1 capture"  "lbt1-svc"             "cap-lbt1-svc"     cap
  collector_line "VPC T1 capture" "vpct1-uplink"         "cap-vpct1-uplink" cap
  collector_line "counters"       "urd-edge-stats.sh"    "stats"            proc
  collector_line "sessions"       "urd-edge-sessions.sh" "sessions"         proc
  echo
  ui_band "PRODUCED"
  if [ -d "$OUT" ]; then produced_lines; else echo "   nothing yet - $OUT does not exist"; fi
  echo
  ui_band "SPAN INTERFACES"
  ip -br link 2>/dev/null | grep span | sed 's/^/   /' || echo "   none"
  echo
  ui_band "DISK"
  df -h "$(existing_dir "$OUT")" 2>/dev/null | sed 's/^/   /'
  echo
  ui_band "WARNINGS"
  warning_lines
  echo
  echo "   Collect with:"
  echo "     scp root@$(hostname):$OUT/pcap/*.pcap*  <collector>:<path>/"
  echo "     scp -r root@$(hostname):$OUT/stats-* $OUT/sessions-*  <collector>:<path>/"
}

# Ctrl-C has to leave the watch loop, not the whole menu.
do_watch() {
  local iv="${1:-10}" i
  _watch_stop=0
  trap '_watch_stop=1' INT
  while [ "$_watch_stop" = 0 ]; do
    clear 2>/dev/null
    ui_head "URD  watch - refreshing every ${iv}s, Ctrl-C to stop" \
            "$(hostname | cut -c1-30)   $(date '+%Y-%m-%d %H:%M:%S')"
    do_status
    # sleep in 1s steps so Ctrl-C is noticed straight away instead of after
    # the full interval
    i=0
    while [ "$i" -lt "$iv" ] && [ "$_watch_stop" = 0 ]; do
      sleep 1; i=$((i+1))
    done
  done
  trap - INT
  echo
  echo "   Watch stopped."
}

# --- help ------------------------------------------------------------------
do_help() {
cat <<'TXT'

  WHAT THIS COLLECTS AND WHY
  ----------------------------------------------------------------------
  Four collectors run at the same time on one Edge.

    urd-edge-cap-lbt1-svc.sh      packet capture, LB T1 service interface
    urd-edge-cap-vpct1-uplink.sh  packet capture, VPC T1 uplink
    urd-edge-stats.sh             interface, CPU and memory counters
    urd-edge-sessions.sh          connection and LB session tables

  The captures use a span mirror. All three steps are done for you,
  including the delete on Ctrl-C.

      set capture session <N> interface <LIF> direction dual   (admin CLI)
        -> creates the Linux interface span-<N>
      tcpdump -nei span-<N> -Z root -C .. -W .. -w <file> <filter>
      del capture session <N>                                  (admin CLI)

  ORDER OF WORK
  ----------------------------------------------------------------------
    1  edit urd-edge.conf                menu 1 shows the current values
    2  menu 2  check       active, leftovers, disk
    3  menu 3  rehearse    one sample, confirm the UUIDs
    4  menu 8  wipe        throw the rehearsal away
    5  menu 4  start       the real window
    6  menu 6  status      or w) watch while it runs
    7  copy the files off the Edge       menu 6 prints the paths
    8  menu 7  stop        then, once the files are safe, menu 8

  THINGS THAT BITE
  ----------------------------------------------------------------------
  Active or Standby
      A capture on the Standby Edge returns zero packets. In
      "get logical-router <id> high-availability status" the top 'state'
      line is this node. The 'Peer Routers' block at the bottom describes
      the other node - reading that one gets it backwards.

  Span sessions are cluster wide
      A session created here also appears on the other Edge. If it is not
      removed, mirroring keeps running and keeps loading the dataplane.
      Run the stop action on every Edge, not only this one.

  Scope is the config
      Only the routers named by T0_SR_UUID, T1_VPC_SR_UUID and
      T1_LB_SR_UUID are collected. This is a troubleshooting tool, not an
      assessment - it never sweeps every logical router on the Edge. One
      router costs about 2.5 seconds of CLI time and a production Edge can
      host hundreds.

  Stopping is safe
      The stop action touches only our processes, matched by their output
      path. It releases only our span sessions and deletes only our files.
      Other people's captures and files are left alone and reported.

  WHERE THE FILES GO
  ----------------------------------------------------------------------
    <OUT>/pcap/            packet captures, .pcap0 .pcap1 ...
    <OUT>/stats-<TAG>/     A interface  B CPU  C memory  D throughput
                           E flow cache
    <OUT>/sessions-<TAG>/  A connections  B LB sessions  C pools
                           D diagnosis  E summary

  Only .pcap0 means nothing rotated and the whole window is in one file.
  Three or more files means the beginning was overwritten.

TXT
}

do_stop() {
  run bash "$D/urd-edge-cleanup.sh"
  echo
  echo "   The files were kept. Copy them off, then use 8) stop + delete."
  echo "   Run this on every Edge of the cluster - span sessions are shared."
}
do_wipe() {
  run bash "$D/urd-edge-cleanup.sh" --all
  echo
  echo "   Run this on every Edge of the cluster."
}

# --- screens ---------------------------------------------------------------
menu() {
  ui_head "URD  Collection Toolkit" \
          "<CASE_ID>   NSX Edge / $(hostname | cut -c1-24)   $(date '+%Y-%m-%d %H:%M:%S')"
  ui_row ""
  ui_row "    SETUP                        RUN"
  ui_row "      1  config                    4  start all"
  ui_row "      2  check                     5  start one"
  ui_row "      3  rehearse   (once)"
  ui_row ""
  ui_row "    MONITOR                      FINISH"
  ui_row "      6  status                    7  stop            keep files"
  ui_row "      w  watch      (auto)         8  stop + delete   remove files"
  ui_row ""
  ui_row "      9  help                      q  quit"
  ui_row ""
  ui_rule
  foot_line
}

# --- non-interactive -------------------------------------------------------
case "${1:-}" in
  config)   show_config; exit 0 ;;
  check)    do_check;    exit 0 ;;
  rehearse) do_rehearse; exit 0 ;;
  start)    do_start;    exit 0 ;;
  status)   do_status;   exit 0 ;;
  watch)    do_watch "${2:-10}"; exit 0 ;;
  stop)     do_stop;     exit 0 ;;
  wipe)     do_wipe;     exit 0 ;;
  help|-h|--help) do_help; exit 0 ;;
  "")       ;;
  *) echo "Unknown action: $1"
     echo "Try: config check rehearse start status watch stop wipe help"; exit 2 ;;
esac

# --- interactive -----------------------------------------------------------
while true; do
  echo
  menu
  echo
  printf "   choose > "; read -r a || break
  case "$a" in
    1) show_config; pause ;;
    2) do_check;    pause ;;
    3) do_rehearse; pause ;;
    4) do_start;    pause ;;
    5) submenu_start; pause ;;
    6) do_status;   pause ;;
    w|W) do_watch 10; pause ;;
    7) do_stop;     pause ;;
    8) do_wipe;     pause ;;
    9) do_help;     pause ;;
    q|Q) echo; break ;;
    *) echo "   Choose 1-9, w or q." ;;
  esac
done

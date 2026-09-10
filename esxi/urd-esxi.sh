#!/bin/sh
# ===========================================================================
#  urd-esxi.sh - menu front end for the ESXi collection scripts
#
#  This is the only file you need to remember on an ESXi host:
#      sh urd-esxi.sh
#
#  It implements nothing itself. It calls the same scripts you would run by
#  hand and prints the command before running it, so you can always see what
#  is executed on a production host - and learn the commands.
#
#  Non-interactive use, same actions:
#      sh urd-esxi.sh config     show the settings
#      sh urd-esxi.sh map        which target VMs are on this host
#      sh urd-esxi.sh check      map, free space, leftovers
#      sh urd-esxi.sh rehearse   one sample of each collector
#      sh urd-esxi.sh start      start all four collectors
#      sh urd-esxi.sh status     time left, progress, warnings
#      sh urd-esxi.sh watch [s]  status refreshed every s seconds
#      sh urd-esxi.sh stop       stop everything, keep the files
#      sh urd-esxi.sh wipe       stop everything and delete our files
#      sh urd-esxi.sh help       the usage text
#
#  Screen: pure ASCII, fixed 72 columns, no colour. tput does not exist on
#  ESXi so the terminal width is never queried.
#  NOTE: busybox sh. No bash syntax.
# ===========================================================================
D=$(dirname "$0")
case "$D" in .) D=$(pwd) ;; esac
. "$D/urd-esxi-lib.sh"

LOGDIR="${LOGDIR:-/tmp}"

run() {
  echo
  echo "  \$ $*"
  ui_thin
  "$@"
  ui_thin
}
pause() { echo; printf "  Press Enter to return to the menu "; read _; }

foot_line() {
  r=$(capture_pids | grep -c .)
  for s in urd-esxi-stats.sh urd-esxi-dfw-sessions.sh; do
    r=$(( r + $(script_pids "$s" | grep -c .) ))
  done
  printf '   %s running    %s MB free    %s\n' "$r" "$(free_mb "$OUT")" \
    "$(on_ramdisk "$OUT" && echo 'output is on the ramdisk' || echo 'output is on disk')"
}

# --- config ----------------------------------------------------------------
show_config() {
  ui_band "CONFIG"
  printf '   %-22s %s\n' "file"       "$CONF"
  printf '   %-22s %s\n' "host tag"   "$HOST_TAG"
  printf '   %-22s %s\n' "output"     "$OUT"
  echo
  printf '   %-22s %s\n' "target VMs"  "${WORKER_VMS:-empty - nothing will be collected}"
  printf '   %-22s %s\n' "vNIC filter" "${WORKER_VNIC:-empty - every vNIC of each VM}"
  echo
  printf '   %-22s %s\n' "capture"     "$PROTO port $NODE_PORT"
  printf '   %-22s %s\n' "LB SNAT IP"  "${LB_SNAT_IP:-empty - not narrowed}"
  printf '   %-22s %s\n' ""            "${CAP_SECS}s, ring ${CAP_FILESIZE} MB x ${CAP_FILECOUNT}, snaplen ${CAP_SNAPLEN:-full packet}"
  printf '   %-22s %s\n' "polling"     "every ${INTERVAL}s for ${DURATION}s = $((DURATION/INTERVAL)) samples"
  printf '   %-22s %s\n' "uplinks"     "$UPLINK_NICS"
  echo
  ui_thin
  printf '   %-22s %s MB\n' "free space"  "$(free_mb "$OUT")"
  printf '   %-22s %s MB\n' "stop floor"  "$MIN_FREE_MB"
  if on_ramdisk "$OUT"; then
    echo
    echo "   Warning: $OUT is on the ESXi ramdisk, which is host memory and"
    echo "   not disk. For a long window put OUT on a datastore instead:"
    echo "       OUT=\"/vmfs/volumes/<datastore>/urd-out\"      see: df -m"
  fi
  echo
  echo "   Edit urd-esxi.conf to change any of this. The menu never writes it."
}

# --- map and check ---------------------------------------------------------
do_map() { run sh "$D/urd-esxi-dfw-sessions.sh" map; }

do_check() {
  ui_band "CHECK 1 of 3 - are the target VMs on this host?"
  do_map
  echo "   (not on this host)               that VM lives elsewhere, run there too"
  echo "   (here, but no vNIC matches ...)  fix WORKER_VNIC, or leave it empty"

  echo
  ui_band "CHECK 2 of 3 - leftovers from an earlier run"
  a=$(ps -c 2>/dev/null | grep "[p]ktcap-uw" | grep -c .)
  o=$(capture_pids | grep -c .)
  printf '   %-30s %s\n' "pktcap-uw on this host" "$a"
  printf '   %-30s %s\n' "of those, ours"         "$o"
  [ "$a" -gt "$o" ] && echo "   The other $(( a - o )) belong to someone else and are never touched."
  if [ -d "$OUT" ]; then
    echo "   $OUT exists, holding:"
    ls -1 "$OUT" | sed 's/^/     /'
    echo "   Clear it with 9) stop + delete before the real run."
  else
    echo "   $OUT does not exist yet - nothing has been collected here."
  fi

  echo
  ui_band "CHECK 3 of 3 - free space"
  printf '   %-30s %s MB\n' "free in $OUT" "$(free_mb "$OUT")"
  printf '   %-30s %s MB\n' "stop floor (MIN_FREE_MB)" "$MIN_FREE_MB"
  nv=0
  for VM in $WORKER_VMS; do
    for F in $(dfw_filters "$VM" "$(vnic_for "$VM")"); do nv=$((nv+1)); done
  done
  printf '   %-30s %s MB  (%s x %s MB x %s captures)\n' "capture budget per stage" \
     "$(( CAP_FILESIZE * CAP_FILECOUNT * nv ))" "$CAP_FILECOUNT" "$CAP_FILESIZE" "$nv"
  if on_ramdisk "$OUT"; then
    echo
    echo "   Warning: this is the ESXi ramdisk - host memory, not disk."
    echo "   pre and post run together and share what is left above the stop"
    echo "   floor, so each stage may use about $(( ( $(free_mb "$OUT") - MIN_FREE_MB ) / 2 )) MB."
  fi
  echo
  run df -m
}

# --- rehearse --------------------------------------------------------------
do_rehearse() {
  ui_band "REHEARSAL - one sample, then stop"
  echo "   This proves the commands actually return data before you commit to"
  echo "   the real window. Nothing runs in the background."
  run sh "$D/urd-esxi-stats.sh" once
  run sh "$D/urd-esxi-dfw-sessions.sh" once
  echo
  ui_band "WHAT IT PRODUCED"
  find "$OUT" -type f 2>/dev/null | sed 's|^|   |' | head -40
  echo "   ... $(find "$OUT" -type f 2>/dev/null | grep -c .) files in total"
  echo
  echo "   If that looks right, clear it so the rehearsal is not mixed into"
  echo "   the real data:"
  echo "       in the menu :  9) stop + delete"
  echo "       on one line :  sh urd-esxi.sh wipe"
  echo "   Both call urd-esxi-cleanup.sh --all."
}

# --- start -----------------------------------------------------------------
start_one() {
  sc="$1"; ln="$2"; shift 2
  if [ ! -f "$D/$sc" ]; then echo "   Missing file: $sc"; return 1; fi
  echo "   \$ nohup sh $sc $* > $LOGDIR/$ln.log 2>&1 </dev/null &"
  nohup sh "$D/$sc" "$@" > "$LOGDIR/$ln.log" 2>&1 </dev/null &
  sleep 1
}

do_start() {
  ui_band "START - all collectors"
  echo "   Captures stop by themselves after CAP_SECS (${CAP_SECS}s)."
  echo "   Polling runs for DURATION (${DURATION}s)."
  echo
  start_one urd-esxi-cap-dfw-pre.sh   pre
  start_one urd-esxi-cap-dfw-post.sh  post
  start_one urd-esxi-stats.sh         stats
  start_one urd-esxi-dfw-sessions.sh  dfw
  sleep 5
  echo
  echo "   Logs: $LOGDIR/{pre,post,stats,dfw}.log"
  echo "   If a capture refused to start, its log says why - the usual cause"
  echo "   is the ring buffer not fitting in the ramdisk."
  echo
  do_status
}

submenu_start() {
  n=$(( DURATION / INTERVAL ))
  ui_band "START ONE - pick a single collector"
cat <<TXT
   Packet capture runs for ${CAP_SECS}s, then stops.
   Target VMs: ${WORKER_VMS:-empty - it will refuse}
     1  DFW pre     what arrives at the firewall, before the rules
     2  DFW post    what survived, after the rules
                    A packet in pre but not in post was dropped by a rule.
                    Run both - one alone tells you nothing.

   State comes in two flavours.
     repeat  one sample every ${INTERVAL}s for ${DURATION}s = ${n} samples,
             in the background. This is what the real window uses.
     once    a single sample, right now, then exit.

     3  counters   repeat     uplink NIC and switch port statistics
     4  dfw        repeat     flows, rules, pass and drop counters
     5  counters   once
     6  dfw        once

     b  back
TXT
  printf "   choose > "; read x
  case "$x" in
    1) start_one urd-esxi-cap-dfw-pre.sh  pre ;;
    2) start_one urd-esxi-cap-dfw-post.sh post ;;
    3) start_one urd-esxi-stats.sh        stats ;;
    4) start_one urd-esxi-dfw-sessions.sh dfw ;;
    5) run sh "$D/urd-esxi-stats.sh" once ;;
    6) run sh "$D/urd-esxi-dfw-sessions.sh" once ;;
    *) return ;;
  esac
  sleep 3; do_status
}

# --- status ----------------------------------------------------------------
collector_line() {   # $1=label $2=stage-or-script $3=marker $4=kind
  label="$1"; what="$2"; mark="$3"; kind="$4"
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

  if [ "${n:-0}" -gt 0 ] && [ -n "$end" ]; then
    left=$(( end - now )); [ "$left" -lt 0 ] && left=0
    printf '   %-16s %s   %-9s %s left\n' "$label" "$(ui_bar $(( total - left )) $total)" \
           "running" "$(ui_time $left)"
  elif [ "${n:-0}" -gt 0 ]; then
    printf '   %-16s %s   %-9s %s\n' "$label" "$(ui_bar 0 0)" "running" "started by hand"
  elif [ "$fin" = 1 ] || [ -n "$end" ]; then
    printf '   %-16s %s   %-9s\n' "$label" "$(ui_bar 1 1)" "finished"
  else
    printf '   %-16s %s   %-9s\n' "$label" "$(ui_bar 0 0)" "idle"
  fi
}

produced_lines() {
  any=0
  for d in "$OUT/stats-$HOST_TAG" "$OUT/dfw-$HOST_TAG"; do
    [ -d "$d" ] || continue
    any=1
    n=$(find "$d" -type f 2>/dev/null | grep -c .)
    b=$(du -sk "$d" 2>/dev/null | awk '{print $1*1024}')
    printf '   %-42s %3s files %11s\n' "$(basename "$d")/" "$n" "$(ui_size ${b:-0})"
  done
  for f in "$OUT"/urd-"$HOST_TAG"-dfw-*.pcap*; do
    [ -e "$f" ] || continue
    any=1
    b=$(ls -l "$f" | awk '{print $5}')
    printf '   %-42s %15s\n' "$(basename "$f")" "$(ui_size ${b:-0})"
  done
  [ "$any" = 1 ] || echo "   nothing yet"
}

warning_lines() {
  w=0
  for f in "$OUT"/urd-"$HOST_TAG"-dfw-*.pcap1; do
    [ -e "$f" ] || continue
    echo "   !  $(basename "${f%1}")* rotated. The start of the window has been"
    echo "      overwritten. Raise CAP_FILESIZE, or move OUT to a datastore."
    w=1
  done
  avail=$(free_mb "$OUT")
  if [ -n "$avail" ] && [ "$avail" -lt "$MIN_FREE_MB" ]; then
    echo "   !  Only ${avail} MB free. Collectors stop themselves at ${MIN_FREE_MB} MB."
    w=1
  fi
  if on_ramdisk "$OUT" && [ -n "$avail" ] && [ "$avail" -lt 120 ]; then
    echo "   !  $OUT is the ramdisk and it is filling up (${avail} MB left)."
    echo "      Copy the files off and wipe, or move OUT to a datastore."
    w=1
  fi
  o=$(capture_pids | grep -c .)
  a=$(ps -c 2>/dev/null | grep "[p]ktcap-uw" | grep -c .)
  if [ "${a:-0}" -gt "${o:-0}" ]; then
    echo "   i  $(( a - o )) pktcap-uw process(es) belong to someone else."
    echo "      They are never stopped or deleted by this tool."
  fi
  [ "$w" = 0 ] && echo "   none"
}

do_status() {
  ui_band "COLLECTORS"
  collector_line "DFW pre"        "pre"                      "cap-pre"  cap
  collector_line "DFW post"       "post"                     "cap-post" cap
  collector_line "counters"       "urd-esxi-stats.sh"        "stats"    proc
  collector_line "dfw flows"      "urd-esxi-dfw-sessions.sh" "dfw"      proc
  echo
  ui_band "PRODUCED"
  if [ -d "$OUT" ]; then produced_lines; else echo "   nothing yet - $OUT does not exist"; fi
  echo
  ui_band "FREE SPACE"
  printf '   %-30s %s MB\n' "$OUT" "$(free_mb "$OUT")"
  printf '   %-30s %s MB\n' "stop floor" "$MIN_FREE_MB"
  on_ramdisk "$OUT" && echo "   This is the ESXi ramdisk - host memory, not disk."
  echo
  ui_band "WARNINGS"
  warning_lines
  echo
  echo "   Collect with:"
  echo "     scp root@$(hostname):$OUT/urd-$HOST_TAG-dfw-*.pcap*  <collector>:<path>/"
  echo "     scp -r root@$(hostname):$OUT/stats-$HOST_TAG $OUT/dfw-$HOST_TAG  <collector>:<path>/"
}

# Ctrl-C has to leave the watch loop, not the whole menu. Without the trap
# the SIGINT reaches the script itself and drops the user back to the shell,
# which is not what "Ctrl-C to stop" leads them to expect.
do_watch() {
  iv="${1:-10}"
  _watch_stop=0
  trap '_watch_stop=1' INT
  while [ "$_watch_stop" = 0 ]; do
    clear 2>/dev/null
    ui_head "URD  watch - refreshing every ${iv}s, Ctrl-C to stop" \
            "$(hostname | cut -c1-30)   $(date '+%Y-%m-%d %H:%M:%S')"
    do_status
    # sleep in 1s steps so Ctrl-C is noticed straight away instead of after
    # the full interval
    _i=0
    while [ "$_i" -lt "$iv" ] && [ "$_watch_stop" = 0 ]; do
      sleep 1; _i=$((_i+1))
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
  Four collectors run at the same time on one ESXi host.

    urd-esxi-cap-dfw-pre.sh    packet capture before the DFW rules
    urd-esxi-cap-dfw-post.sh   packet capture after the DFW rules
    urd-esxi-stats.sh          uplink NIC and switch port counters
    urd-esxi-dfw-sessions.sh   DFW flows, rules, pass and drop counters

  pre and post are relative to the DFW filter, not to the VM. Both
  directions appear in each file. Comparing them shows what the firewall
  dropped: a packet in pre but not in post was dropped by a rule.

  ORDER OF WORK
  ----------------------------------------------------------------------
    1  edit urd-esxi.conf                 menu 1 shows the current values
    2  menu 2  map         are the target VMs on this host?
    3  menu 3  check       map, free space, leftovers
    4  menu 4  rehearse    one sample, confirm it returns data
    5  menu 9  wipe        throw the rehearsal away
    6  menu 5  start       the real window
    7  menu 7  status      or w) watch while it runs
    8  copy the files off the host        menu 7 prints the paths
    9  menu 8  stop        then, once the files are safe, menu 9

  THINGS THAT BITE
  ----------------------------------------------------------------------
  /tmp is a ramdisk
      The default OUT is /tmp/urd-out. On ESXi that is host memory, about
      250 MB on a normal host. The capture budget

          CAP_FILESIZE x CAP_FILECOUNT x (pre + post) x (vNICs)

      is checked before the capture starts and refused if it does not fit.
      For a long window put OUT on a datastore:
          OUT="/vmfs/volumes/<datastore>/urd-out"

  Scope is the config
      Only the VMs in WORKER_VMS are touched - captures, flows, port
      statistics. If WORKER_VMS is empty nothing per VM is collected and
      the scripts say so. They never fall back to every VM on the host.
      Even the two host wide listings, net-stats -l and summarize-dvfilter,
      are cut down to those VMs, so the bundle you hand over does not
      contain unrelated workloads.

  WORKER_VNIC
      Write the bare vNIC name, "eth0", not "web02.eth0". It is a list and
      can be per VM:   WORKER_VNIC="web01:eth1 web02:eth2,eth3"
      Leave it empty unless you have a reason. Empty captures every vNIC,
      and picking the wrong one loses the whole window.

  Stopping is safe
      The stop action kills only pktcap-uw processes whose output path is
      inside OUT, and deletes only our own files. Captures started by
      anyone else are left alone and reported.

  WHERE THE FILES GO
  ----------------------------------------------------------------------
    <OUT>/urd-<TAG>-dfw-pre-<VM>-<vNIC>.pcap0 ...
    <OUT>/urd-<TAG>-dfw-post-<VM>-<vNIC>.pcap0 ...
    <OUT>/stats-<TAG>/   A0 nic list  A1 nic stats  A2 ports  A3 port stats
    <OUT>/dfw-<TAG>/     A0 mapping  A1 dvfilter list  B flows  C rules
                         D pass and drop counters  F summary

  Only .pcap0 means nothing rotated and the whole window is in one file.

TXT
}

do_stop() {
  run sh "$D/urd-esxi-cleanup.sh"
  echo
  echo "   The files were kept. Copy them off, then use 9) stop + delete."
  echo "   Run this on every ESXi host you collected from."
}
do_wipe() { run sh "$D/urd-esxi-cleanup.sh" --all; }

# --- screens ---------------------------------------------------------------
menu() {
  ui_head "URD  Collection Toolkit" \
          "<CASE_ID>   ESXi / $(hostname | cut -c1-24)   $(date '+%Y-%m-%d %H:%M:%S')"
  ui_row ""
  ui_row "    SETUP                        RUN"
  ui_row "      1  config                    5  start all"
  ui_row "      2  map                       6  start one"
  ui_row "      3  check"
  ui_row "      4  rehearse   (once)"
  ui_row ""
  ui_row "    MONITOR                      FINISH"
  ui_row "      7  status                    8  stop            keep files"
  ui_row "      w  watch      (auto)         9  stop + delete   remove files"
  ui_row ""
  ui_row "      h  help                      q  quit"
  ui_row ""
  ui_rule
  foot_line
}

case "${1:-}" in
  config)   show_config; exit 0 ;;
  map)      do_map;      exit 0 ;;
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
     echo "Try: config map check rehearse start status watch stop wipe help"; exit 2 ;;
esac

while true; do
  echo
  menu
  echo
  printf "   choose > "; read a || break
  case "$a" in
    1) show_config; pause ;;
    2) do_map;      pause ;;
    3) do_check;    pause ;;
    4) do_rehearse; pause ;;
    5) do_start;    pause ;;
    6) submenu_start; pause ;;
    7) do_status;   pause ;;
    w|W) do_watch 10; pause ;;
    8) do_stop;     pause ;;
    9) do_wipe;     pause ;;
    h|H) do_help;   pause ;;
    q|Q) echo; break ;;
    *) echo "   Choose 1-9, w, h or q." ;;
  esac
done

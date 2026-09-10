#!/bin/sh
# ===========================================================================
#  urd-esxi-lib.sh - shared helper functions
#
#  DO not RUN this FILE. DO not EDIT IT.
#  It is sourced by urd-esxi-cap-dfw-*.sh, urd-esxi-stats.sh and
#  urd-esxi-dfw-sessions.sh. It only needs to sit in the same directory.
#
#  Provides: config loading, defaults, VM -> DFW filter / switch port lookup,
#            logging, result file writing.
#
#  Note: busybox sh. No bash syntax. No 'tr'. 'command -v' is unreliable here.
# ===========================================================================
_D=$(dirname "$0")
CONF="${URD_ESXI_CONF:-$_D/urd-esxi.conf}"
[ -r "$CONF" ] || { echo "config not found: $CONF" >&2; exit 2; }
. "$CONF"

[ -n "$OUT" ] || OUT=/tmp/urd-out
[ -n "$HOST_TAG" ] || HOST_TAG=esx
[ -n "$CAP_SECS" ] || CAP_SECS=600
# CAP_SNAPLEN intentionally has no default: empty means capture the whole packet
[ -n "$CAP_FILESIZE" ] || CAP_FILESIZE=100
[ -n "$CAP_FILECOUNT" ] || CAP_FILECOUNT=5
[ -n "$INTERVAL" ] || INTERVAL=30
[ -n "$DURATION" ] || DURATION=1200
[ -n "$PROTO" ] || PROTO=udp

# --- WORKER_VNIC ----------------------------------------------------------
# One setting has to cover VMs whose vNICs are named differently, so it is a
# LIST, not a single name. Tokens are separated by spaces and may be mixed:
#
#   ""                        all vNICs of every VM            <- recommended
#   "eth0"                    eth0 on every VM
#   "web01:eth1"              only that VM, only that vNIC
#   "web02:eth2,eth3"         several vNICs of one VM
#   "web01.eth1"              same as web01:eth1 - the exact ClientName that
#                             net-stats prints, so it can be pasted as is
#   "eth0 web02:eth2,eth3"    eth0 is the default; web02 overrides it
#
# A VM with its own entry uses only that. A VM with no entry falls back to the
# bare tokens, and if there are none, to all of its vNICs.
# VM names must not contain spaces (WORKER_VMS has the same limitation).
_WV=""
for _t in ${WORKER_VNIC:-}; do
  case "$_t" in
    *:*) : ;;                                   # already vm:nic
    *.*) _t=$(echo "$_t" | sed 's/\./:/') ;;     # vm.nic -> vm:nic
  esac
  _WV="$_WV $_t"
done
WORKER_VNIC="$_WV"

# vnic_for <vm> -> space separated vNIC list. Empty output means "all vNICs".
vnic_for() {
  _vm="$1"; _def=""; _hit=""; _seen=0
  for _t in $WORKER_VNIC; do
    case "$_t" in
      *:*) if [ "${_t%%:*}" = "$_vm" ]; then _hit="$_hit ${_t#*:}"; _seen=1; fi ;;
      *)   _def="$_def $_t" ;;
    esac
  done
  # unquoted echo collapses the leading/duplicate spaces built up above
  if [ "$_seen" = 1 ]; then echo $_hit | sed 's/,/ /g'; else echo $_def; fi
}

log() { echo "$(date '+%H:%M:%S') $*"; }
die() { echo "$*" >&2; exit 2; }

# busybox 'command -v' is not reliable on ESXi. Use 'which'.
which pktcap-uw >/dev/null 2>&1 || die "pktcap-uw not found. Is this an ESXi host?"

# ---------------------------------------------------------------------------
#  FREE SPACE
#
#  The default OUT is /tmp, and on ESXi /tmp is a ramdisk, not disk.
#  Measured on the lab host: 256 MB total, 243 MB free. Filling it is a host
#  problem, not a file problem - services that need /tmp start failing.
#
#  Meanwhile the capture budget from the config is
#      CAP_FILESIZE x CAP_FILECOUNT x (pre + post) x (number of vNICs)
#  which with the defaults (100 x 5 x 2) is already 1000 MB. That does not
#  fit and must be caught before the capture starts, not after.
#
#  Text output (flows, rules, stats) is small by comparison and paced by
#  INTERVAL - it is not the problem. The pcap budget is.
# ---------------------------------------------------------------------------
# Reserve kept free at all times. 64 MB is a floor for the host, not a
# comfort margin: /tmp normally uses about 12 MB. It has to stay SMALL
# relative to the ~250 MB ramdisk, otherwise nothing is left for the capture
# and the tool refuses its own default settings (that happened - 200 left
# only 21 MB usable and blocked every capture).
MIN_FREE_MB="${MIN_FREE_MB:-64}"

# free megabytes for a directory. Works for VMFS/datastore paths and for the
# visorfs ramdisks, which "df" cannot report on ESXi (it ignores the path
# argument entirely - verified). Mount points may contain spaces, e.g.
# "/vmfs/volumes/datastore1 (1)", so the mount point is rebuilt from $6..$NF.
free_mb() {   # $1 = directory. prints MB, or nothing if it cannot tell
  _d="$1"
  _m=$(df -m 2>/dev/null | awk -v d="$_d" '
      NR > 1 {
        mp = ""; for (i = 6; i <= NF; i++) mp = mp (i > 6 ? " " : "") $i
        if (mp ~ /^\// && substr(d, 1, length(mp)) == mp && length(mp) > best) {
          best = length(mp); free = $4
        }
      } END { if (best) print free }')
  if [ -n "$_m" ]; then echo "$_m"; return; fi
  case "$_d" in
    /tmp|/tmp/*) vdf -h 2>/dev/null | awk '$1=="tmp"{
        v=$4; u=v; sub(/[0-9.]+/,"",u); sub(/[A-Za-z]+$/,"",v)
        if (u=="G") v=v*1024; else if (u=="K") v=v/1024
        printf "%d\n", v; exit }' ;;
  esac
}

on_ramdisk() { case "$1" in /tmp|/tmp/*) return 0 ;; *) return 1 ;; esac; }

# Called by mkout(). Refuses to start when there is not enough room.
check_free() {
  _f=$(free_mb "$OUT")
  if [ -z "$_f" ]; then
    log "  Warning: cannot determine free space for $OUT - continuing"
    return 0
  fi
  log "  free space in $OUT: ${_f} MB"
  if [ "$_f" -lt "$MIN_FREE_MB" ]; then
    die "only ${_f} MB free in $OUT (MIN_FREE_MB=$MIN_FREE_MB). Refusing to start.
Free some space, or point OUT at a datastore:
    OUT=\"/vmfs/volumes/<datastore>/urd-out\"
  see:  df -m"
  fi
  if on_ramdisk "$OUT"; then
    log "  Note: $OUT is on the ESXi ramdisk, not on disk. Keep it small."
  fi
  return 0
}

# Called by the capture script before it starts pktcap-uw.
# $1 = number of pktcap-uw processes this script will run (one per filter).
#
# pre and post normally run at the same time, so this script's share is only
# half of what is available. And MIN_FREE_MB has to stay untouched, otherwise
# the polling loops stop themselves a minute later. So the allowance is
#     (free - MIN_FREE_MB) / 2
check_cap_budget() {
  _n="$1"
  _need=$(( CAP_FILESIZE * CAP_FILECOUNT * _n ))
  _f=$(free_mb "$OUT")
  log "  capture budget: ${CAP_FILESIZE}MB x ${CAP_FILECOUNT} files x ${_n} capture(s) = ${_need} MB"
  [ -n "$_f" ] || { log "  Warning: free space unknown - continuing"; return 0; }
  _allow=$(( (_f - MIN_FREE_MB) / 2 ))
  [ "$_allow" -lt 0 ] && _allow=0
  log "  allowed for this stage: ${_allow} MB  (free ${_f} - reserve ${MIN_FREE_MB}, halved for pre+post)"
  if [ "$_need" -gt "$_allow" ]; then
    die "capture budget ${_need} MB exceeds the ${_allow} MB this stage may use at $OUT.
free ${_f} MB, reserve MIN_FREE_MB=${MIN_FREE_MB} MB, and pre+post share what is left.

Do one of these:
  - put OUT on a datastore - the right answer for a long window:
        OUT=\"/vmfs/volumes/<datastore>/urd-out\"      (see: df -m)
  - or lower CAP_FILESIZE / CAP_FILECOUNT in urd-esxi.conf
The ring buffer caps each capture at CAP_FILESIZE x CAP_FILECOUNT, so
whatever is configured will be written. It has to fit before we start."
  fi
  return 0
}

# Called once per sample by the polling loops. Stops the run cleanly instead
# of filling the filesystem.
space_ok() {
  _f=$(free_mb "$OUT")
  [ -n "$_f" ] || return 0
  [ "$_f" -ge "$MIN_FREE_MB" ] && return 0
  log "  STOPPING: only ${_f} MB free in $OUT (MIN_FREE_MB=$MIN_FREE_MB)."
  return 1
}

# ---------------------------------------------------------------------------
#  SCOPE: this is a TROUBLESHOOTING tool, not a host assessment.
#  Everything is limited to the VMs named in WORKER_VMS.
#
#  Two commands are host-wide by nature - "net-stats -l" and
#  "summarize-dvfilter" list every VM on the hypervisor. Dumping them raw
#  would put unrelated workloads (other tenants, vCenter, log servers ...)
#  into a bundle that gets handed to the customer and attached to an SR.
#  Measured on the lab host: 14 powered-on VMs, 11 of them nothing to do
#  with this case. So both are filtered down to WORKER_VMS.
#
#  Set FULL_HOST=1 to keep the unfiltered output. Opt-in, never the default.
# ---------------------------------------------------------------------------
FULL_HOST="${FULL_HOST:-0}"

# "net-stats -l" reduced to WORKER_VMS (header kept)
portlist_ours() {
  if [ "$FULL_HOST" = "1" ]; then net-stats -l 2>/dev/null; return; fi
  net-stats -l 2>/dev/null | awk -v vms="$WORKER_VMS" '
    BEGIN { n = split(vms, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    NR == 1 { print; next }
    { c = $NF; i = index(c, "."); if (i > 0 && (substr(c, 1, i-1) in want)) print }'
}

# "summarize-dvfilter" reduced to the WORKER_VMS sections
dvfilter_ours() {
  if [ "$FULL_HOST" = "1" ]; then summarize-dvfilter 2>/dev/null; return; fi
  summarize-dvfilter 2>/dev/null | awk -v vms="$WORKER_VMS" '
    BEGIN { n = split(vms, a, " "); for (i = 1; i <= n; i++) want["vmm0:" a[i]] = 1 }
    $1 == "world" { keep = ($3 in want) }
    keep'
}

# Refuse to do per-VM work when nothing was named. Never fall back to "all".
require_targets() {
  [ -n "${WORKER_VMS:-}" ] && return 0
  log "  WORKER_VMS is empty. Skipping all per-VM collection."
  log "  This tool pinpoints the VMs you are troubleshooting - it does not"
  log "  sweep the host. Put the pool member VM names in urd-esxi.conf."
  return 1
}

# VM name -> list of DFW filter names (one per vNIC, may be several lines).
#   A VM with several vNICs has several sfw filters (lab: up to 10 seen).
#   Capturing only the first one loses traffic that uses another NIC.
#   If WORKER_VNIC is set, only that NIC is returned; empty = all.
#   Matching compares field 3 of the "world" line against "vmm0:<name>" exactly.
#   Using an exact field match (not a substring) means a VM whose name is a
#   prefix of another VM name is not matched by mistake, and it still works
#   when the world line ends right after the name (no vcUuid field).
dfw_filters() {
  # $2 is a SPACE SEPARATED vNIC list (from vnic_for). Empty = every vNIC.
  summarize-dvfilter 2>/dev/null | awk -v vm="$1" -v nics="${2:-}" '
    BEGIN { n = split(nics, want, " ") }
    $1=="world" { f = ($3 == "vmm0:" vm) }
    f && /vmware-sfw\./ {
      if (n == 0) { print $2; next }
      for (i = 1; i <= n; i++)
        if (index($2, "-" want[i] "-") > 0) { print $2; next }
    }'
}

# first filter only (used for the mapping table)
dfw_filter() { dfw_filters "$1" "${2:-}" | head -1; }

# nic-12345-eth0-vmware-sfw.2  ->  eth0
filter_nic() { echo "$1" | sed 's/^nic-[0-9]*-//; s/-vmware-sfw.*$//'; }

# VM name -> list of DVS switch port numbers (one per vNIC).
#   ClientName in net-stats is "<VM>.eth0". Compare only the part before the
#   first dot, so a substring match cannot pick the wrong VM.
vm_ports() {
  net-stats -l 2>/dev/null | awk -v vm="$1" '
    { n=$NF; i=index(n,"."); if (i>0 && substr(n,1,i-1)==vm) print $1 }'
}
vm_port() { vm_ports "$1" | head -1; }

# ===========================================================================
#  SCREEN
#  Pure ASCII only. Box drawing characters and anything above 7 bit gets
#  mangled by the ESXi console - that is why the whole toolkit is ASCII.
#  Fixed 72 column width so nothing wraps.
#  busybox: no "seq" in some builds, so the repeat helper uses awk.
# ===========================================================================
UIW=70

_rep() { awk -v n="$1" -v c="$2" 'BEGIN{s="";for(i=0;i<n;i++)s=s c;print s}'; }

ui_rule()  { printf '+%s+\n' "$(_rep $UIW '=')"; }
ui_thin()  { printf '  %s\n' "$(_rep $((UIW-2)) '-')"; }
# Never let a long value break the frame - cut anything wider than UIW.
ui_row()   { printf '|%-*.*s|\n' "$UIW" "$UIW" "$1"; }
ui_blank() { ui_row ""; }
ui_band()  { ui_rule; ui_row "  $1"; ui_rule; }

ui_head() {
  ui_rule
  ui_row "  $1"
  shift
  while [ $# -gt 0 ]; do ui_row "  $1"; shift; done
  ui_rule
}

# progress bar: [########------------]  40%
ui_bar() {   # $1=done $2=total $3=width
  d="$1"; t="$2"; w="${3:-20}"
  if [ -z "$t" ] || [ "$t" -le 0 ]; then printf '[%s]     ' "$(_rep $w '-')"; return; fi
  [ "$d" -lt 0 ] && d=0
  [ "$d" -gt "$t" ] && d="$t"
  p=$(( d * 100 / t )); f=$(( d * w / t ))
  printf '[%s%s] %3d%%' "$(_rep $f '#')" "$(_rep $((w-f)) '-')" "$p"
}

ui_size() {
  b="${1:-0}"
  awk -v b="$b" 'BEGIN{
    if (b>=1073741824) printf "%.1f GB", b/1073741824;
    else if (b>=1048576) printf "%.1f MB", b/1048576;
    else if (b>=1024) printf "%.1f KB", b/1024;
    else printf "%d B", b }'
}

ui_time() { s="${1:-0}"; [ "$s" -lt 0 ] && s=0; printf '%dm%02ds' $((s/60)) $((s%60)); }

# --- finding OUR processes ------------------------------------------------
#  One matcher, used by the cleanup script AND by the status screen, so they
#  can never disagree about what is running.
#
#  It must match however the collector was started:
#      sh urd-esxi-stats.sh            (from inside the directory)
#      sh ./urd-esxi-stats.sh
#      sh /tmp/urd/urd-esxi-stats.sh
#  Matching "/urd-esxi-stats.sh" only catches the last form - one started by
#  hand then looks stopped AND survives the cleanup.
#
#  busybox ps has no PID filter, so the caller's own world id and its parent
#  are removed explicitly. Without that the shell running the check counts
#  itself and the number comes out too high.
script_pids() {   # $1 = script file name
  ps -c 2>/dev/null | grep "$1" | grep -v grep \
    | awk -v me="$$" -v parent="${PPID:-0}" '$1 != me && $1 != parent {print $1}'
}

#  Our pktcap-uw processes, identified by where they WRITE - never by the
#  program name, so a capture started by someone else is never touched.
#  $1 is the stage (pre / post). Without it the two captures cannot be told
#  apart and starting one makes both look running.
capture_pids() {
  _st="${1:-}"
  ps -c 2>/dev/null | grep "pktcap-uw.*-o $OUT/urd-$HOST_TAG-dfw-$_st" | grep -v grep \
    | awk -v me="$$" -v parent="${PPID:-0}" '$1 != me && $1 != parent {print $1}'
}

# --- "when does it finish?" -----------------------------------------------
#  A collector that runs in the background gives no clue how long it still
#  has to go, and busybox ps has no elapsed-time column. So each collector
#  drops a marker holding its end time and the status screen subtracts.
mark_start() { mkdir -p "$OUT" 2>/dev/null; echo $(( $(date +%s) + $2 )) > "$OUT/.urd-end-$1" 2>/dev/null; }
# Write "done" rather than removing the marker. A removed marker is
# indistinguishable from one that never ran, so a finished capture would show
# as idle. The cleanup script removes the markers.
mark_done()  { echo done > "$OUT/.urd-end-$1" 2>/dev/null; }
hms() { s="$1"; [ "$s" -lt 0 ] && s=0; printf '%dm %02ds' $((s/60)) $((s%60)); }

mkout() { mkdir -p "$OUT" 2>/dev/null; [ -d "$OUT" ] || die "cannot create output dir: $OUT"; check_free; }
snap() { f="$1"; shift; { echo "########## $(date '+%Y-%m-%d %H:%M:%S') ##########"; echo "### $*"; "$@"; echo; } >> "$f" 2>&1; }

#!/bin/sh
# ===========================================================================
#  nsx-collector.sh - one-file NSX collection toolkit  (NSX Edge + ESXi host)
#
#  Two files are all you need on the box:   nsx-collector.sh   nsx-collector.conf
#
#      sh nsx-collector.sh                 the menu
#      sh nsx-collector.sh help            what it collects and why
#      sh nsx-collector.sh <action>        one action, no menu (see help)
#
#  It works out by itself whether it is on an NSX Edge or on an ESXi host and
#  offers only what makes sense there.
#
#  Written in POSIX sh so that the SAME file runs on the ESXi busybox shell
#  and on the Edge. No bash syntax, no python, nothing to install.
#  Always start it with "sh nsx-collector.sh" - a hardened ESXi refuses "./nsx-collector.sh"
#  (execInstalledOnly: only files installed from a VIB may be executed).
# ===========================================================================
NSXC_VER="3.0"

# --- 0. is this file intact? ----------------------------------------------
#  A script that travelled through a Windows editor or a messenger arrives
#  with CR line endings. The whole file then looks like ONE line and the
#  errors are useless ("line 1: syntax error", "line 1: xi.sh: not found").
#  Catch it here and say what to do. Seen in the field 2026-09-11.
_CR=$(printf '\r')
_self="$0"
case "$_self" in */*) _SD=$(dirname "$_self") ;; *) _SD=. ;; esac
if [ -f "$_self" ] && grep -q "$_CR" "$_self" 2>/dev/null; then
  echo "This copy of nsx-collector.sh has Windows/CR line endings - it cannot run."
  echo "That is what the errors look like when it does run:"
  echo "    nsx-collector.sh: line 1: syntax error / line 1: xi.sh: not found"
  echo "Fix it on the box:"
  printf '    %s\n' 'sed -i "s/\r$//" nsx-collector.sh nsx-collector.conf'
  echo "Better: transfer the .tgz in BINARY mode and unpack it here (tar xzf)."
  echo "Never paste the scripts through a messenger or a Windows editor."
  exit 2
fi

# --- 1. config -------------------------------------------------------------
CONF="${NSXC_CONF:-$_SD/nsx-collector.conf}"
[ -r "$CONF" ] || { echo "config not found: $CONF" >&2
  echo "nsx-collector.conf must sit next to nsx-collector.sh, or set NSXC_CONF=/path/nsx-collector.conf" >&2; exit 2; }
if grep -q "$_CR" "$CONF" 2>/dev/null; then
  echo "nsx-collector.conf has Windows/CR line endings - fix it with:" >&2
  printf '    %s\n' 'sed -i "s/\r$//" nsx-collector.conf' >&2; exit 2
fi
# absolute path to ourselves, so the menu can start collectors from anywhere
_self="$(cd "$_SD" 2>/dev/null && pwd)/$(basename "$0")"
. "$CONF"

# --- 2. which box is this? -------------------------------------------------
PLAT=""
if [ "$(uname -s 2>/dev/null)" = "VMkernel" ]; then PLAT=esxi
elif [ -d /opt/vmware/nsx-edge ]; then PLAT=edge
fi
[ -n "$PLAT" ] || { echo "This is neither an ESXi host (VMkernel) nor an NSX Edge." >&2
  echo "nsx-collector.sh only runs on the boxes it collects from." >&2; exit 2; }
# root check. ESXi busybox has no "id" and no "whoami" - there $USER is the
# only thing to go on, and the ESXi shell is root anyway.
nsxc_uid() { if which id >/dev/null 2>&1; then id -u; fi; }
_uid=$(nsxc_uid)
if [ -n "$_uid" ]; then
  [ "$_uid" = "0" ] || { echo "must run as root." >&2; exit 2; }
elif [ -n "$USER" ] && [ "$USER" != root ]; then
  echo "must run as root (USER=$USER)." >&2; exit 2
fi

# --- 3. defaults -----------------------------------------------------------
if [ "$PLAT" = esxi ]; then
  [ -n "$OUT" ] || OUT=/tmp/nsx-collect
  [ -n "$MIN_FREE_MB" ] || MIN_FREE_MB=64
else
  [ -n "$OUT" ] || OUT=/var/dump/nsx-collect
  [ -n "$MIN_FREE_MB" ] || MIN_FREE_MB=1024
fi
[ -n "$TAG" ] || TAG=$(hostname 2>/dev/null | sed 's/\..*//')
[ -n "$TAG" ] || TAG="$PLAT"
[ -n "$CAP_SECS" ] || CAP_SECS=600
[ -n "$CAP_FILESIZE" ] || CAP_FILESIZE=100
[ -n "$CAP_FILECOUNT" ] || CAP_FILECOUNT=5
[ -n "$INTERVAL" ] || INTERVAL=30
[ -n "$DURATION" ] || DURATION=1200
[ -n "$CAP_SESSION_VPCT1" ] || CAP_SESSION_VPCT1=0
[ -n "$CAP_SESSION_LBT1" ] || CAP_SESSION_LBT1=1
FULL_HOST="${FULL_HOST:-0}"
LOGDIR="${LOGDIR:-/tmp}"
# CAP_SNAPLEN has no default on purpose: empty = keep the whole packet.

log()  { echo "$(date '+%H:%M:%S') $*"; }
die()  { echo "$*" >&2; exit 2; }
run()  { echo "   \$ $*"; "$@"; }

# ===========================================================================
#  WHERE THINGS ARE WRITTEN
#
#  One collection = ONE directory, and every file name says what it is:
#
#    <OUT>/run-<tag>-<date>-<time>/
#        00-run-info.txt                 what was run, and this legend
#        pcap/   10-edge-lbt1svc-*.pcap      Edge, LB T1 service interface
#                11-edge-vpct1uplink-*.pcap  Edge, VPC T1 uplink
#                20-dfw-pre-<vm>-<nic>*.pcap  ESXi, BEFORE the DFW rules
#                21-dfw-post-<vm>-<nic>*.pcap ESXi, AFTER the DFW rules
#        state/  30..39 Edge counters (interfaces, routers, cpu/memory)
#                40..49 ESXi counters (switch ports, uplink NICs)
#        session/50..59 Edge firewall connections and load balancer state
#                60..69 ESXi DFW flows, rules and pass/drop counters
#
#  Collectors that are started separately join the run that is already open,
#  so pre and post captures and the pollers never end up scattered. A run
#  older than RUN_JOIN_SECS (2 h) starts a new directory.
# ===========================================================================
RUN_JOIN_SECS="${RUN_JOIN_SECS:-7200}"
run_dir() {
  local _mk _rd _rt
  if [ -n "$NSXC_RUN" ]; then
    mkdir -p "$NSXC_RUN" 2>/dev/null; echo "$NSXC_RUN"; return
  fi
  _mk="$OUT/.nsxc-run"
  if [ -f "$_mk" ]; then
    _rd=$(awk '{print $1}' "$_mk" 2>/dev/null); _rt=$(awk '{print $2}' "$_mk" 2>/dev/null)
    if [ -n "$_rd" ] && [ -d "$_rd" ] && [ $(( $(date +%s) - ${_rt:-0} )) -lt "$RUN_JOIN_SECS" ]; then
      echo "$_rd"; return
    fi
  fi
  _rd="$OUT/run-$TAG-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$_rd/pcap" "$_rd/state" "$_rd/session" 2>/dev/null
  echo "$_rd $(date +%s)" > "$_mk" 2>/dev/null
  echo "$_rd"
}
latest_run() {   # the run directory in use, without creating one
  _mk="$OUT/.nsxc-run"
  [ -f "$_mk" ] && awk '{print $1}' "$_mk" 2>/dev/null && return 0
  ls -1d "$OUT"/run-* 2>/dev/null | tail -1
}
run_info() {   # written once per run directory
  _i="$1/00-run-info.txt"
  [ -f "$_i" ] && return 0
  { echo "nsx-collector $NSXC_VER"
    echo "started : $(date '+%Y-%m-%d %H:%M:%S')  (host clock)"
    echo "platform: $PLAT        host: $(hostname 2>/dev/null)"
    echo "case    : ${CASE_ID:-(none)}        tag: $TAG"
    echo "config  : $CONF"
    echo
    echo "FILTER  : ${FILTER:-(empty - built from the single fields)}"
    if [ "$PLAT" = edge ]; then
      echo "  LB T1 service if : $(filter_for lbt1)"
      echo "  VPC T1 uplink    : $(filter_for vpct1)"
      echo "  capture LIFs     : LB=${LIF_LBT1_SVC:-none} VPC=${LIF_VPCT1_UPLINK:-none}"
    else
      echo "  DFW capture      : $(filter_for esxi)"
      echo "  target VMs       : $(x_vms)"
    fi
    echo
    echo "FILE NAMES"
    echo "  pcap/10-edge-lbt1svc-*      Edge capture, LB T1 service interface"
    echo "  pcap/11-edge-vpct1uplink-*  Edge capture, VPC T1 uplink"
    echo "  pcap/20-dfw-pre-*           ESXi capture BEFORE the DFW rules"
    echo "  pcap/21-dfw-post-*          ESXi capture AFTER the DFW rules"
    echo "    a trailing -u1812 / -t80 / -icmp / -ip<addr> is the pktcap-uw"
    echo "    filter that file was taken with (option mode only)"
    echo "  state/30..39   Edge   interface / router / cpu / memory counters"
    echo "  state/40..49   ESXi   switch port and uplink NIC counters"
    echo "  session/50..59 Edge   firewall connections, load balancer state"
    echo "  session/60..69 ESXi   DFW flows, rules, pass/drop counters"
    echo "  a name ending in -HHMMSS is one sample taken at that time"
    echo
    echo "READING THE CAPTURES LATER"
    echo "  Part of an Edge capture is 802.1Q tagged (mostly the return"
    echo "  direction). The capture filter is applied by the kernel and sees"
    echo "  through the tag, but a filter you apply when READING the file does"
    echo "  not - it would silently drop those packets. Read them like this:"
    echo "      tcpdump -nr <file> '(<expr>) or (vlan and (<expr>))'"
    echo "  Without an expression everything is shown, tagged or not."
  } > "$_i" 2>/dev/null
}

# ===========================================================================
#  CONFIG VALUES -> FILTER EXPRESSION
#
#  Two ways in, one way out: whatever the user wrote ends up as ONE pcap
#  expression which is syntax-checked before a capture starts.
#     FILTER set   -> used as it stands (bare addresses get host/net added)
#     FILTER empty -> built from HOSTS/PROTO/PORTS and the per-leg fields
# ===========================================================================
# a config value -> plain tokens. Accepts "a b", "a,b", "(a or b)", "host a".
# An unfilled "<VIP>" placeholder counts as empty.
nsxc_list() {
  local _o _s _t
  _s=$(echo "$*" | sed 's/[(),]/ /g'); _o=""
  for _t in $_s; do
    case "$_t" in or|OR|and|AND|net|NET|host|HOST) continue ;; esac
    case "$_t" in \<*) continue ;; esac
    _o="$_o $_t"
  done
  echo $_o
}
bpf_hosts() {   # "a b 10.0.0.0/28" -> "(host a or host b or net 10.0.0.0/28)"
  _o=""
  for _t in $(nsxc_list "$*"); do
    case "$_t" in */*) _o="$_o or net $_t" ;; *) _o="$_o or host $_t" ;; esac
  done
  [ -n "$_o" ] && echo "($(echo "$_o" | sed 's/^ or //'))"
}
bpf_svc() {     # $1=protocols $2=ports -> "(udp and port (1812 or 1813))"
  _pr=""; _po=""; _np=0; _nq=0
  for _t in $(nsxc_list "$1"); do
    _t=$(echo "$_t" | sed 's/[A-Z]/\l&/g')
    _pr="$_pr or $_t"; _np=$((_np+1))
  done
  for _t in $(nsxc_list "$2"); do _po="$_po or $_t"; _nq=$((_nq+1)); done
  _pr=$(echo "$_pr" | sed 's/^ or //'); _po=$(echo "$_po" | sed 's/^ or //')
  [ "$_np" -gt 1 ] && _pr="($_pr)"
  [ "$_nq" -gt 1 ] && _po="port ($_po)"
  [ "$_nq" -eq 1 ] && _po="port $_po"
  if   [ -n "$_pr" ] && [ -n "$_po" ]; then echo "($_pr and $_po)"
  elif [ -n "$_pr" ]; then echo "$_pr"
  elif [ -n "$_po" ]; then echo "$_po"
  fi
}
bpf_and() { _o=""; for _a in "$@"; do [ -n "$_a" ] && _o="$_o and $_a"; done
            _o=$(echo "$_o" | sed 's/^ and //')
            case "$_o" in *" and "*) echo "($_o)" ;; *) echo "$_o" ;; esac; }
bpf_or()  { _o=""; for _a in "$@"; do [ -n "$_a" ] && _o="$_o or $_a"; done
            echo "$_o" | sed 's/^ or //'; }

# A free FILTER may contain a bare address - "10.1.1.10 and udp port 1812".
# tcpdump calls that a syntax error, and "port 80 and 10.1.1.10" is worse: it
# parses, inherits the "port" qualifier and silently matches nothing.
# So put host/net in front of every address that has no qualifier yet.
bpf_fix() {
  local out prev
  echo "$*" | sed -e 's/(/ ( /g' -e 's/)/ ) /g' | awk '{
    out=""; prev="";
    for (i = 1; i <= NF; i++) {
      t = $i; lt = tolower(prev);
      if (t ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
          lt != "host" && lt != "net" && lt != "src" && lt != "dst" && lt != "gateway")
        t = "host " t;
      else if (t ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ && lt != "net")
        t = "net " t;
      out = out (out == "" ? "" : " ") t; prev = $i;
    }
    print out }' | sed -e 's/( /(/g' -e 's/ )/)/g'
}

# Is this expression valid? Prints the parser's own error if not.
# Edge : tcpdump can compile without capturing            (-d -i lo)
# ESXi : pktcap-uw has no BPF at all, so the expression is checked - and later
#        applied - with tcpdump-uw, against a 24 byte empty pcap file.
filt_check() {
  local _e
  [ -n "$1" ] || return 0
  if [ "$PLAT" = edge ]; then
    tcpdump -d -i lo "$1" >/dev/null 2>"$LOGDIR/.nsxc-filt.err" && return 0
    grep -qi "no such device\|not permitted" "$LOGDIR/.nsxc-filt.err" && {
      rm -f "$LOGDIR/.nsxc-filt.err"; return 0; }   # cannot check here, not a filter error
  else
    _e="$LOGDIR/.nsxc-empty.pcap"
    printf '\324\303\262\241\002\000\004\000\000\000\000\000\000\000\000\000\377\377\000\000\001\000\000\000' > "$_e" 2>/dev/null
    tcpdump-uw -r "$_e" -w /dev/null "$1" >/dev/null 2>"$LOGDIR/.nsxc-filt.err" && return 0
  fi
  echo "FILTER is not a valid pcap expression:"
  sed 's/^/    /' "$LOGDIR/.nsxc-filt.err" 2>/dev/null | grep -v "reading from file" | head -3
  echo "    expression: $1"
  echo "  Remember: and/or have the same precedence, left to right. Use ( )."
  echo "  Examples: FILTER=\"host 10.1.1.10 and (udp port 1812 or udp port 1813)\""
  echo "            FILTER=\"net 10.1.1.0/28 and not tcp port 22\""
  return 1
}

filter_set() { [ -n "$(nsxc_list "$FILTER")" ] && return 0; return 1; }

# The expression for one capture point.
#   $1 = vpct1 | lbt1 | esxi
# FILTER wins. Otherwise it is built from the fields, and ICMP is kept for the
# addresses in play (an ICMP unreachable is usually the answer you are after).
filter_for() {
  local _f _f1 _f2 _h _hi _s
  if filter_set; then bpf_fix "$FILTER"; return; fi
  _h=""; _s=""; _f=""
  case "$1" in
    vpct1)
      _h=$(bpf_hosts "$VIP $NAT_IP $CLIENT_IP $HOSTS")
      _s=$(bpf_svc "$PROTO" "$SVC_PORT $PORTS")
      if   [ -n "$_h" ] && [ -n "$_s" ]; then _f="$_h and ($_s or icmp)"
      elif [ -n "$_h" ]; then _f="$_h"
      elif [ -n "$_s" ]; then _f="$_s or icmp"
      fi ;;
    lbt1)
      _f1=""; _f2=""
      [ -n "$(nsxc_list "$VIP $SVC_PORT $HOSTS $PORTS")" ] && \
        _f1=$(bpf_and "$(bpf_hosts "$VIP $HOSTS")" "$(bpf_svc "$PROTO" "$SVC_PORT $PORTS")")
      [ -n "$(nsxc_list "$LB_SNAT_IP $NODE_PORT")" ] && \
        _f2=$(bpf_and "$(bpf_hosts "$LB_SNAT_IP")" "$(bpf_svc "$PROTO" "$NODE_PORT")")
      _f=$(bpf_or "$_f1" "$_f2")
      [ -n "$_f" ] || _f=$(bpf_svc "$PROTO" "")
      _hi=$(bpf_hosts "$VIP $LB_SNAT_IP $HOSTS")
      if [ -n "$_f" ]; then
        if [ -n "$_hi" ]; then _f="$_f or (icmp and $_hi)"; else _f="$_f or icmp"; fi
      fi ;;
    esxi)
      _h=$(bpf_hosts "$LB_SNAT_IP $HOSTS")
      _s=$(bpf_svc "$PROTO" "$NODE_PORT $PORTS")
      if   [ -n "$_h" ] && [ -n "$_s" ]; then _f="$_h and ($_s or icmp)"
      elif [ -n "$_h" ]; then _f="$_h"
      elif [ -n "$_s" ]; then _f="$_s or icmp"
      fi ;;
  esac
  echo "$_f"
}

# ===========================================================================
#  DISK / MARKERS / OUTPUT
# ===========================================================================
free_mb() {   # $1 = directory. prints MB, or nothing if it cannot tell
  _d="$1"
  _m=$(df -m 2>/dev/null | awk -v d="$_d" '
      NR > 1 { mp = ""; for (i = 6; i <= NF; i++) mp = mp (i > 6 ? " " : "") $i
        if (mp ~ /^\// && substr(d, 1, length(mp)) == mp && length(mp) > best) {
          best = length(mp); free = $4 } } END { if (best) print free }')
  if [ -n "$_m" ]; then echo "$_m"; return; fi
  _m=$(df -Pm "$_d" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "$_m" ]; then echo "$_m"; return; fi
  case "$_d" in
    /tmp|/tmp/*) vdf -h 2>/dev/null | awk '$1=="tmp"{
        v=$4; u=v; sub(/[0-9.]+/,"",u); sub(/[A-Za-z]+$/,"",v)
        if (u=="G") v=v*1024; else if (u=="K") v=v/1024
        printf "%d\n", v; exit }' ;;
  esac
}
on_ramdisk() { [ "$PLAT" = esxi ] && case "$1" in /tmp|/tmp/*) return 0 ;; esac; return 1; }
check_free() {
  local _f
  _f=$(free_mb "$OUT")
  [ -n "$_f" ] || { log "  Warning: cannot determine free space for $OUT - continuing"; return 0; }
  log "  free space in $OUT: ${_f} MB"
  if [ "$_f" -lt "$MIN_FREE_MB" ]; then
    die "only ${_f} MB free in $OUT (MIN_FREE_MB=$MIN_FREE_MB). Refusing to start.
Point OUT at somewhere bigger in nsx-collector.conf, or free space first."
  fi
  on_ramdisk "$OUT" && log "  Note: $OUT is on the ESXi ramdisk, not disk. Keep it small."
  return 0
}
# $1 = number of captures this stage will start
check_cap_budget() {
  local _allow _f _n _need
  _n="$1"; _need=$(( CAP_FILESIZE * CAP_FILECOUNT * _n )); _f=$(free_mb "$OUT")
  log "  capture budget: ${CAP_FILESIZE}MB x ${CAP_FILECOUNT} files x ${_n} = ${_need} MB"
  [ -n "$_f" ] || { log "  Warning: free space unknown - continuing"; return 0; }
  _allow=$(( (_f - MIN_FREE_MB) / 2 ))
  [ "$_allow" -lt 0 ] && _allow=0
  log "  allowed here: ${_allow} MB  (free ${_f} - reserve ${MIN_FREE_MB}, halved for two captures)"
  [ "$_need" -le "$_allow" ] && return 0
  return 1
}
space_ok() {
  local _f
  _f=$(free_mb "$OUT"); [ -n "$_f" ] || return 0
  [ "$_f" -ge "$MIN_FREE_MB" ] && return 0
  log "  STOPPING: only ${_f} MB free in $OUT (MIN_FREE_MB=$MIN_FREE_MB)."
  return 1
}
mkout() { mkdir -p "$OUT" 2>/dev/null; [ -d "$OUT" ] || die "cannot create output dir: $OUT"; check_free; }
snap()  { _f="$1"; shift; { echo "########## $(date '+%Y-%m-%d %H:%M:%S') ##########"
          echo "### $*"; "$@"; echo; } >> "$_f" 2>&1; }
mark_start() { mkdir -p "$OUT" 2>/dev/null; echo $(( $(date +%s) + $2 )) > "$OUT/.nsxc-end-$1" 2>/dev/null; }
mark_done()  { echo done > "$OUT/.nsxc-end-$1" 2>/dev/null; }
hms() { _s="$1"; [ "$_s" -lt 0 ] && _s=0; printf '%dm %02ds' $((_s/60)) $((_s%60)); }

# ===========================================================================
#  SCREEN - pure ASCII, fixed 72 columns (the ESXi console mangles the rest)
# ===========================================================================
UIW=70
_rep() { awk -v n="$1" -v c="$2" 'BEGIN{s="";for(i=0;i<n;i++)s=s c;print s}'; }
ui_rule() { printf '+%s+\n' "$(_rep $UIW '=')"; }
ui_thin() { printf '  %s\n' "$(_rep $((UIW-2)) '-')"; }
ui_row()  { printf '|%-*.*s|\n' "$UIW" "$UIW" "$1"; }
ui_band() { ui_rule; ui_row "  $1"; ui_rule; }
ui_bar()  { _d="$1"; _t="$2"; _w="${3:-20}"
  if [ -z "$_t" ] || [ "$_t" -le 0 ]; then printf '[%s]     ' "$(_rep $_w '-')"; return; fi
  [ "$_d" -lt 0 ] && _d=0; [ "$_d" -gt "$_t" ] && _d="$_t"
  printf '[%s%s] %3d%%' "$(_rep $(( _d * _w / _t )) '#')" "$(_rep $(( _w - _d * _w / _t )) '-')" "$(( _d * 100 / _t ))"; }

# --- our processes ---------------------------------------------------------
#  Everything is this one file, so a collector shows up as "nsx-collector.sh <action>".
#  Matched by action, never by program name, and our own shell is excluded.
#  Edge is Linux (pgrep -f), ESXi is busybox (ps -c, no PID filter - so our
#  own shell and its parent are dropped by hand).
pids_matching() {   # $1 = pattern found in the command line
  if [ "$PLAT" = edge ]; then
    pgrep -f "$1" 2>/dev/null | grep -v "^$$\$" | grep -v "^${PPID:-0}\$"
  else
    # ESXi "ps -c" lists one line per WORLD (thread): column 1 is the world id,
    # column 2 the cartel id = the process. Counting worlds reads like four
    # times as many captures as there are, so collapse to the cartel id.
    ps -c 2>/dev/null | grep "$1" | grep -v grep \
      | awk -v me="$$" -v parent="${PPID:-0}" '$1 != me && $1 != parent {print $2}' \
      | sort -u
  fi
}
act_pids() { pids_matching "nsx-collector.sh $1"; }
cap_pids() {   # captures: matched by the file they WRITE, never by program name
  if [ "$PLAT" = edge ]; then
    pids_matching "tcpdump.*-w $OUT/run-.*/pcap/1"
  else
    { pids_matching "pktcap-uw.*-o $OUT/run-.*/pcap/2"
      pids_matching "tcpdump-uw.*-w $OUT/run-.*/pcap/2"
      # pipe mode: pktcap-uw writes to stdout, so it is matched by the
      # dvfilter of one of OUR target VMs - never by program name alone.
      for _f in $(x_all_filters); do pids_matching "pktcap-uw.*--dvfilter $_f "; done
    } 2>/dev/null | sort -u
  fi
}

# ===========================================================================
#  ===============  NSX EDGE  ===============
# ===========================================================================
e_cli() { su admin -c "$1" 2>&1; }

e_need_lif() {   # $1 = variable name, $2 = its value
  [ -n "$2" ] && return 0
  echo "REQUIRED setting is empty in $CONF:  $1"
  echo "  It is the interface to capture on - there is no default."
  echo "  su admin -c \"get logical-routers\"                     -> SR UUID"
  echo "  su admin -c \"get logical-router <SR-UUID> interfaces\"  -> pick by Port-type"
  echo "     uplink -> LIF_VPCT1_UPLINK      service -> LIF_LBT1_SVC"
  echo "  (addresses, ports and FILTER are optional - they may stay empty.)"
  return 1
}
e_span_open() {   # $1 = session id, $2 = LIF uuid
  e_cli "set capture session $1 interface $2 direction dual" >/dev/null 2>&1
  _i=0
  while [ $_i -lt 10 ]; do
    ip link show "span-$1" >/dev/null 2>&1 && return 0
    sleep 1; _i=$((_i+1))
  done
  e_cli "del capture session $1" >/dev/null 2>&1     # never leave a mirror behind
  return 1
}
e_span_close() { e_cli "del capture session $1" >/dev/null 2>&1; }

# Is span session $1 OURS? It is ours only when it mirrors one of the LIFs in
# the config. A production Edge may have a session somebody else created for
# their own troubleshooting - deleting that would stop THEIR capture, so an
# unknown session is reported and left alone.
#   returns 0 ours, 1 empty/not created, 2 someone else's
e_span_owned() {
  local _id _ports
  _id="$1"
  _ports=$(e_cli "get capture session $_id" 2>/dev/null | awk -F: '/PORTS/{print $2}')
  case "$_ports" in
    *"[]"*|"") return 1 ;;
  esac
  for _l in $LIF_LBT1_SVC $LIF_VPCT1_UPLINK; do
    case "$_ports" in *"$_l"*) return 0 ;; esac
  done
  return 2
}

# $1=label $2=LIF $3=filter $4=seconds $5=span session id $6=file prefix
e_cap() {
  local _base _filt _lab _lif _pfx _secs _sess _snap
  _lab="$1"; _lif="$2"; _filt="$3"; _secs="$4"; _sess="${5:-0}"; _pfx="$6"
  RUN=$(run_dir); run_info "$RUN"
  _base="$RUN/pcap/$_pfx-$(date '+%H%M%S').pcap"
  mkdir -p "$RUN/pcap"
  log "capture $_lab"
  log "  interface : $_lif  (span-$_sess)"
  log "  filter    : ${_filt:-(none - EVERY packet on this interface)}"
  log "  duration  : ${_secs}s"
  log "  snaplen   : ${CAP_SNAPLEN:-full packet}"
  log "  files     : ${_base}[0..$((CAP_FILECOUNT-1))]  max $((CAP_FILESIZE*CAP_FILECOUNT))MB"
  check_cap_budget 1 || log "  Warning: the ring buffer is bigger than the free space here."
  mark_start "cap-$_lab" "$_secs"
  e_span_open "$_sess" "$_lif" || die "failed to create span-$_sess. Check the LIF UUID."
  trap "e_span_close $_sess" EXIT INT TERM
  _snap=""; [ -n "$CAP_SNAPLEN" ] && _snap="-s $CAP_SNAPLEN"
  # -Z root: tcpdump drops privileges otherwise and cannot write the next
  #  file of the ring. timeout -s INT ends it by the clock.
  if [ -n "$_filt" ]; then
    timeout -s INT "$_secs" tcpdump -nei "span-$_sess" -Z root $_snap \
        -C "$CAP_FILESIZE" -W "$CAP_FILECOUNT" -w "$_base" "$_filt" 2>&1 | tail -4
  else
    timeout -s INT "$_secs" tcpdump -nei "span-$_sess" -Z root $_snap \
        -C "$CAP_FILESIZE" -W "$CAP_FILECOUNT" -w "$_base" 2>&1 | tail -4
  fi
  e_span_close "$_sess"; mark_done "cap-$_lab"; trap - EXIT
  log "done. files:"
  ls -l "${_base}"* 2>/dev/null | sed 's/^/    /'
}

e_cap_lbt1() {
  local _f
  e_need_lif LIF_LBT1_SVC "$LIF_LBT1_SVC" || exit 2
  mkout; _f=$(filter_for lbt1); filt_check "$_f" || exit 2
  e_cap "lbt1-svc" "$LIF_LBT1_SVC" "$_f" "${1:-$CAP_SECS}" "$CAP_SESSION_LBT1" "10-edge-lbt1svc"
}
e_cap_vpct1() {
  local _f
  e_need_lif LIF_VPCT1_UPLINK "$LIF_VPCT1_UPLINK" || exit 2
  mkout; _f=$(filter_for vpct1); filt_check "$_f" || exit 2
  e_cap "vpct1-uplink" "$LIF_VPCT1_UPLINK" "$_f" "${1:-$CAP_SECS}" "$CAP_SESSION_VPCT1" "11-edge-vpct1uplink"
}

e_srs() {   # the routers to collect state for - only what the config names
  _l=""
  for _u in $(nsxc_list "$T0_SR_UUID") $(nsxc_list "$T1_VPC_SR_UUID") $(nsxc_list "$T1_LB_SR_UUID"); do
    _l="$_l $_u"
  done
  echo $_l
}
e_stats_once() {
  local _D2 _p _s8 _srs _u
  RUN=$(run_dir); run_info "$RUN"; _D2="$RUN/state"; mkdir -p "$_D2"
  snap "$_D2/30-edge-interfaces.txt"      e_cli "get interfaces"
  snap "$_D2/31-edge-interface-stats.txt" e_cli "get interfaces stats"
  snap "$_D2/32-edge-dataplane-cpu.txt"   e_cli "get dataplane cpu stats"
  for _p in $(nsxc_list "$FP_PORTS"); do
    snap "$_D2/33-edge-port-$_p-stats.txt" e_cli "get interface $_p stats"
  done
  _srs=$(e_srs)
  if [ -n "$_srs" ]; then
    for _u in $_srs; do
      _s8=$(echo "$_u" | cut -c1-8)
      snap "$_D2/34-edge-router-$_s8-interface-stats.txt" e_cli "get logical-router $_u interfaces stats"
      snap "$_D2/35-edge-router-$_s8-ha-state.txt"        e_cli "get logical-router $_u high-availability status"
    done
  else
    log "  no T0_SR_UUID / T1_VPC_SR_UUID / T1_LB_SR_UUID set - per router stats skipped."
    log "  (they cost ~2.5 s each, so only what you name is collected)"
  fi
  snap "$_D2/36-edge-system-cpu-memory.txt" e_cli "get system-stats"
  log "  state sample -> $_D2"
}
e_sessions_once() {
  local _D2 _lb _p _s8 _ts _u
  RUN=$(run_dir); run_info "$RUN"; _D2="$RUN/session"; mkdir -p "$_D2"
  _ts=$(date '+%H%M%S')
  for _u in $(nsxc_list "$T1_VPC_SR_UUID") $(nsxc_list "$T1_LB_SR_UUID") $(nsxc_list "$T0_SR_UUID"); do
    _s8=$(echo "$_u" | cut -c1-8)
    e_cli "get firewall $_u connection count" > "$_D2/50-edge-fw-conn-count-$_s8-$_ts.txt" 2>&1
    e_cli "get firewall $_u connection"       > "$_D2/51-edge-fw-conn-table-$_s8-$_ts.txt" 2>&1
  done
  if [ -n "$(nsxc_list "$LB_UUID")" ]; then
    for _lb in $(nsxc_list "$LB_UUID"); do
      snap "$_D2/52-edge-lb-status.txt" e_cli "get load-balancer $_lb status"
      snap "$_D2/53-edge-lb-stats.txt"  e_cli "get load-balancer $_lb stats"
      e_cli "get load-balancer $_lb virtual-servers" > "$_D2/54-edge-lb-virtualservers-$_ts.txt" 2>&1
      for _p in $(nsxc_list "$LB_POOL_UUIDS"); do
        snap "$_D2/55-edge-lb-pool-$(echo "$_p" | cut -c1-8)-status.txt" e_cli "get load-balancer $_lb pool $_p status"
      done
    done
  else
    log "  no LB_UUID - load balancer part skipped"
  fi
  log "  session sample -> $_D2"
}

e_check() {
  local _any _pair _st _t _u f
  ui_band "CHECK 1 of 3 - is this Edge ACTIVE for the routers you care about?"
  echo "   The top 'state' line is this node. The 'Peer Routers' block at the"
  echo "   bottom describes the OTHER node - reading that one gets it backwards."
  echo
  _any=0
  for _pair in "T0:$T0_SR_UUID" "T1 VPC:$T1_VPC_SR_UUID" "T1 LB:$T1_LB_SR_UUID"; do
    _t="${_pair%%:*}"; _u="${_pair#*:}"; [ -n "$_u" ] || continue; _any=1
    _st=$(e_cli "get logical-router $_u high-availability status" | awk '/^state/{print $3; f=1} END{if(!f)print "?"}')
    printf '   %-8s %-40s %s\n' "$_t" "$_u" "$_st"
  done
  [ "$_any" = 1 ] || echo "   No SR UUID set in nsx-collector.conf - nothing to check here."
  echo
  echo "   A capture on a STANDBY Edge returns zero packets."
  echo
  ui_band "CHECK 2 of 3 - leftovers from an earlier run"
  echo
  ip -br link 2>/dev/null | grep span || echo "   no span interface - good"
  printf '   %-28s %s\n' "our captures running" "$(cap_pids | grep -c .)"
  echo
  ui_band "CHECK 3 of 3 - disk and filter"
  df -h "$(dirname "$OUT")" 2>/dev/null | sed 's/^/   /'
  c_filter_report
}

# ===========================================================================
#  ===============  ESXi  ===============
# ===========================================================================
# WORKER_VMS with unfilled "<...>" placeholders removed
x_vms() { _o=""; for _t in $(nsxc_list "$WORKER_VMS"); do _o="$_o $_t"; done; echo $_o; }
x_vnic_for() {
  local _def _hit _seen _t _vm
  _vm="$1"; _def=""; _hit=""; _seen=0
  for _t in $WORKER_VNIC; do
    case "$_t" in *.*) _t=$(echo "$_t" | sed 's/\./:/') ;; esac
    case "$_t" in
      *:*) [ "${_t%%:*}" = "$_vm" ] && { _hit="$_hit ${_t#*:}"; _seen=1; } ;;
      *)   _def="$_def $_t" ;;
    esac
  done
  if [ "$_seen" = 1 ]; then echo $_hit | sed 's/,/ /g'; else echo $_def; fi
}
x_filters() {   # $1 = VM, $2 = vNIC list ("" = all)
  summarize-dvfilter 2>/dev/null | awk -v vm="$1" -v nics="${2:-}" '
    BEGIN { n = split(nics, want, " ") }
    $1=="world" { f = ($3 == "vmm0:" vm) }
    f && /vmware-sfw\./ {
      if (n == 0) { print $2; next }
      for (i = 1; i <= n; i++) if (index($2, "-" want[i] "-") > 0) { print $2; next } }'
}
x_all_filters() { for _v in $(x_vms); do x_filters "$_v" "$(x_vnic_for "$_v")"; done; }
x_nic() { echo "$1" | sed 's/^nic-[0-9]*-//; s/-vmware-sfw.*$//'; }
x_dvfilter_ours() {
  [ "$FULL_HOST" = "1" ] && { summarize-dvfilter 2>/dev/null; return; }
  summarize-dvfilter 2>/dev/null | awk -v vms="$(x_vms)" '
    BEGIN { n = split(vms, a, " "); for (i = 1; i <= n; i++) want["vmm0:" a[i]] = 1 }
    $1 == "world" { keep = ($3 in want) } keep'
}
x_portlist_ours() {
  [ "$FULL_HOST" = "1" ] && { net-stats -l 2>/dev/null; return; }
  net-stats -l 2>/dev/null | awk -v vms="$(x_vms)" '
    BEGIN { n = split(vms, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    NR == 1 { print; next }
    { c = $NF; i = index(c, "."); if (i > 0 && (substr(c, 1, i-1) in want)) print }'
}
x_need_vms() {
  [ -n "$(x_vms)" ] && return 0
  echo "REQUIRED setting is empty in $CONF:  WORKER_VMS"
  echo "  Nothing per VM is collected without it - no capture, no flows."
  echo "  Names as shown by:  vim-cmd vmsvc/getallvms"
  echo "     WORKER_VMS=\"k8s-w01 k8s-w02\""
  echo "  (addresses, ports and FILTER are optional - they may stay empty.)"
  return 1
}
x_map() {
  local _f _fs _has _n _p _vm _want
  printf '%-30s %-6s %-36s %s\n' "VM" "vNIC" "DFW filter" "port"
  for _vm in $(x_vms); do
    _want=$(x_vnic_for "$_vm"); _fs=$(x_filters "$_vm" "$_want")
    if [ -z "$_fs" ]; then
      _has=$(x_filters "$_vm" "" | while read _f; do x_nic "$_f"; done | xargs)
      if [ -n "$_want" ] && [ -n "$_has" ]; then
        printf '%-30s %s\n' "$_vm" "(here, but no vNIC matches '$_want'; has: $_has)"
      else
        printf '%-30s %s\n' "$_vm" "(not on this host)"
      fi
      continue
    fi
    for _f in $_fs; do
      _n=$(x_nic "$_f")
      _p=$(net-stats -l 2>/dev/null | awk -v c="$_vm.$_n" '$NF==c{print $1; exit}')
      printf '%-30s %-6s %-36s %s\n' "$_vm" "$_n" "$_f" "${_p:-?}"
    done
  done
}
# busybox timeout: old builds want "-t SECS", new ones "-s SIG SECS".
x_tmo() {
  if   timeout -t 1 -s INT true >/dev/null 2>&1; then echo "timeout -t $1 -s INT"
  elif timeout -s INT 1 true    >/dev/null 2>&1; then echo "timeout -s INT $1"
  fi
}
# The capture itself.  $1 = pre|post   $2 = seconds
#   FILTER set   -> pktcap-uw | tcpdump-uw : ONE file per vNIC, full BPF
#   FILTER empty -> pktcap-uw option filters. pktcap-uw has no "or", so every
#                   combination of protocol x port x address is its own file.
x_cap() {
  local _TMO _dead _f _fl _found _is _ispecs _n _n2 _nic _nis _nps _o _opts _p _pi _pids _pl _ports _ps _pspecs _secs _snap _stage _t _vm _x
  _stage="$1"; _secs="${2:-$CAP_SECS}"
  [ "$_stage" = pre ] || [ "$_stage" = post ] || die "stage must be pre or post"
  x_need_vms || exit 2
  mkout
  RUN=$(run_dir); run_info "$RUN"; mkdir -p "$RUN/pcap"
  if [ "$_stage" = pre ]; then _num=20; else _num=21; fi
  _TMO=$(x_tmo "$_secs")
  [ -n "$_TMO" ] || log "  WARNING: no usable 'timeout' here - end the capture with: sh nsx-collector.sh stop"
  _snap=""; [ -n "$CAP_SNAPLEN" ] && _snap="-s $CAP_SNAPLEN"

  if filter_set; then
    _f=$(filter_for esxi); filt_check "$_f" || exit 2
    _n=0; for _vm in $(x_vms); do for _fl in $(x_filters "$_vm" "$(x_vnic_for "$_vm")"); do _n=$((_n+1)); done; done
    [ "$_n" -gt 0 ] || die "no target VM on this host. Check WORKER_VMS (sh nsx-collector.sh map)."
    x_shrink "$_n"
    check_cap_budget "$_n" || die "not enough room - see the numbers above. Lower CAP_FILESIZE/CAP_FILECOUNT or set OUT to a datastore."
    mark_start "cap-$_stage" "$_secs"
    log "DFW $_stage capture ${_secs}s   filter: $_f"
    _pids=""; _found=0
    for _vm in $(x_vms); do
      for _fl in $(x_filters "$_vm" "$(x_vnic_for "$_vm")"); do
        _nic=$(x_nic "$_fl"); _o="$RUN/pcap/$_num-dfw-$_stage-$_vm-$_nic.pcap"
        _found=$((_found+1))
        log "  $_vm ($_nic) -> $_o"
        echo Y | $_TMO pktcap-uw --dvfilter "$_fl" --stage "$_stage" $_snap -o - 2>/dev/null \
          | tcpdump-uw -r - -w "$_o" -C "$CAP_FILESIZE" -W "$CAP_FILECOUNT" "$_f" >/dev/null 2>&1 &
        _pids="$_pids $!"
      done
    done
  else
    # ---- option mode: build the pktcap-uw option combinations -------------
    _pl=""; _pi=0
    for _t in $(nsxc_list "$PROTO"); do
      case "$_t" in
        udp|UDP) _pl="$_pl udp" ;; tcp|TCP) _pl="$_pl tcp" ;; icmp|ICMP) _pi=1 ;;
        *) die "PROTO: '$_t' - use udp / tcp / icmp, or leave it empty" ;;
      esac
    done
    _ports=""
    for _t in $(nsxc_list "$NODE_PORT $PORTS"); do
      case "$_t" in *[!0-9]*) die "port '$_t' is not a number" ;; esac
      [ "$_t" -ge 1 ] && [ "$_t" -le 65535 ] || die "port $_t out of range"
      _ports="$_ports $_t"
    done
    _pspecs=""
    if [ -n "$_ports" ]; then
      [ -n "$_pl" ] || _pl="udp tcp"
      for _p in $_pl; do for _n2 in $_ports; do _pspecs="$_pspecs ${_p}port:$_n2"; done; done
    elif [ -n "$_pl" ]; then
      for _p in $_pl; do case "$_p" in udp) _pspecs="$_pspecs proto:0x11" ;; tcp) _pspecs="$_pspecs proto:0x06" ;; esac; done
    elif [ "$_pi" = 0 ]; then _pspecs="none"
    fi
    [ "$_pi" = 1 ] && _pspecs="$_pspecs proto:0x01"
    _ispecs=""
    for _t in $(nsxc_list "$LB_SNAT_IP $HOSTS"); do
      case "$_t" in */*) _ispecs="$_ispecs srcip:$_t dstip:$_t" ;; *) _ispecs="$_ispecs ip:$_t" ;; esac
    done
    [ -n "$_ispecs" ] || _ispecs="none"
    _nps=0; for _x in $_pspecs; do _nps=$((_nps+1)); done
    _nis=0; for _x in $_ispecs; do _nis=$((_nis+1)); done
    _n=0; for _vm in $(x_vms); do for _fl in $(x_filters "$_vm" "$(x_vnic_for "$_vm")"); do _n=$((_n+_nps*_nis)); done; done
    [ "$_n" -gt 0 ] || die "no target VM on this host. Check WORKER_VMS (sh nsx-collector.sh map)."
    x_shrink "$_n"
    check_cap_budget "$_n" || die "not enough room - see the numbers above. Lower CAP_FILESIZE/CAP_FILECOUNT or set OUT to a datastore."
    mark_start "cap-$_stage" "$_secs"
    if [ "$_pspecs" = none ] && [ "$_ispecs" = none ]; then
      log "DFW $_stage capture ${_secs}s   filter: NONE - every packet on the vNIC"
    else
      log "DFW $_stage capture ${_secs}s   $_nps x $_nis combination(s) per vNIC"
      log "  (pktcap-uw has no 'or' - one capture per combination. Set FILTER in"
      log "   nsx-collector.conf to get ONE file per vNIC with a full expression instead.)"
    fi
    _pids=""; _found=0
    for _vm in $(x_vms); do
      for _fl in $(x_filters "$_vm" "$(x_vnic_for "$_vm")"); do
        _nic=$(x_nic "$_fl")
        for _ps in $_pspecs; do for _is in $_ispecs; do
          _found=$((_found+1))
          _opts="$(x_spec_opt "$_ps") $(x_spec_opt "$_is")"
          _o="$RUN/pcap/$_num-dfw-$_stage-$_vm-$_nic$(x_spec_tag "$_ps")$(x_spec_tag "$_is").pcap"
          log "  $_vm ($_nic) [$(echo ${_opts:-no filter})] -> $_o"
          echo Y | $_TMO pktcap-uw --dvfilter "$_fl" --stage "$_stage" $_opts $_snap \
              -C "$CAP_FILESIZE" -W "$CAP_FILECOUNT" -o "$_o" >/dev/null 2>&1 &
          _pids="$_pids $!"
        done; done
      done
    done
  fi

  [ "$_found" -gt 0 ] || die "no target VM on this host. Check WORKER_VMS (sh nsx-collector.sh map)."
  sleep 2
  _dead=0
  for _p in $_pids; do kill -0 "$_p" 2>/dev/null || _dead=$((_dead+1)); done
  if [ "$_dead" -gt 0 ]; then
    log "  WARNING: started $_found capture(s), $_dead stopped at once ($((_found-_dead)) running)."
    log "           run one by hand to see the error."
  else
    log "  $_found capture(s) running"
  fi
  log "ends by itself after ${_secs}s.  collect: scp -r root@$(hostname):$RUN ."
}
x_spec_opt() { case "$1" in none) ;; *) echo "--${1%%:*} ${1#*:}" ;; esac; }
x_spec_tag() {
  case "$1" in
    none) ;; proto:0x11) echo "-udp" ;; proto:0x06) echo "-tcp" ;; proto:0x01) echo "-icmp" ;;
    udpport:*) echo "-u${1#*:}" ;; tcpport:*) echo "-t${1#*:}" ;; ip:*) echo "-ip${1#*:}" ;;
    srcip:*) echo "-src$(echo "${1#*:}" | sed 's#/#_#')" ;;
    dstip:*) echo "-dst$(echo "${1#*:}" | sed 's#/#_#')" ;;
  esac
}
# /tmp is a ramdisk: rather than refusing, make the ring smaller for this run.
x_shrink() {
  local _allow _f _fs _need
  _f=$(free_mb "$OUT"); [ -n "$_f" ] || return 0
  _allow=$(( (_f - MIN_FREE_MB) / 2 )); [ "$_allow" -gt 0 ] || return 0
  _need=$(( CAP_FILESIZE * CAP_FILECOUNT * $1 ))
  [ "$_need" -le "$_allow" ] && return 0
  _fs=$(( _allow / (CAP_FILECOUNT * $1) ))
  [ "$_fs" -ge 1 ] || return 0
  log "  NOTE: $1 capture(s) x ${CAP_FILESIZE}MB x ${CAP_FILECOUNT} = ${_need}MB does not fit the"
  log "        ${_allow}MB allowed here -> CAP_FILESIZE lowered to ${_fs}MB for this run"
  CAP_FILESIZE=$_fs
}
x_dfw_once() {
  local _D2 _fl _nall _nic _t _ts _vm
  RUN=$(run_dir); run_info "$RUN"; _D2="$RUN/session"; mkdir -p "$_D2"; _ts=$(date '+%H%M%S')
  snap "$_D2/60-dfw-filter-list.txt" x_dvfilter_ours
  x_need_vms || return 0
  for _vm in $(x_vms); do
    for _fl in $(x_filters "$_vm" "$(x_vnic_for "$_vm")"); do
      _nic=$(x_nic "$_fl"); _t="$_vm-$_nic"
      vsipioctl getflows -f "$_fl" > "$_D2/61-dfw-flows-$_t-$_ts.txt" 2>&1
      snap "$_D2/62-dfw-rules-$_t.txt"       vsipioctl getrules -f "$_fl"
      snap "$_D2/63-dfw-passdrop-$_t.txt"    vsipioctl getfilterstat -f "$_fl"
      _nall=$(grep -c '^[0-9]' "$_D2/61-dfw-flows-$_t-$_ts.txt" 2>/dev/null)
      { echo "########## $_ts $_vm ($_nic) ##########"
        echo "  total flows : ${_nall:-0}"
        vsipioctl getfilterstat -f "$_fl" 2>/dev/null | awk '/^v4 (pass|drop)/{printf "  %s %s IN / %s OUT\n",$1" "$2,$3,$4}'
        echo; } >> "$_D2/69-dfw-summary.txt"
    done
  done
  log "  DFW sample -> $_D2"
}
x_stats_once() {
  local _D2 _n _p _vm i
  RUN=$(run_dir); run_info "$RUN"; _D2="$RUN/state"; mkdir -p "$_D2"
  snap "$_D2/40-esxi-switchport-list.txt" x_portlist_ours
  for _n in $(nsxc_list "$UPLINK_NICS"); do
    snap "$_D2/41-esxi-uplink-$_n-stats.txt" esxcli network nic stats get -n "$_n"
  done
  for _vm in $(x_vms); do
    for _p in $(net-stats -l 2>/dev/null | awk -v vm="$_vm" '{n=$NF;i=index(n,".");if(i>0&&substr(n,1,i-1)==vm)print $1}'); do
      snap "$_D2/42-esxi-vmport-$_vm-$_p-stats.txt" net-stats -A -t vW -p "$_p" -i 1 -n 1
    done
  done
  log "  state sample -> $_D2"
}
x_check() {
  local _f
  ui_band "CHECK 1 of 3 - are the target VMs on this host?"
  echo
  x_map | sed 's/^/   /'
  echo
  ui_band "CHECK 2 of 3 - leftovers from an earlier run"
  printf '   %-28s %s\n' "our captures running" "$(cap_pids | grep -c .)"
  echo
  ui_band "CHECK 3 of 3 - disk and filter"
  _f=$(free_mb "$OUT"); printf '   free in %-20s %s MB\n' "$OUT" "${_f:-?}"
  on_ramdisk "$OUT" && echo "   $OUT is the ESXi RAMDISK (about 250 MB). Keep the capture small,"
  on_ramdisk "$OUT" && echo "   or point OUT at a datastore for a long window."
  c_filter_report
}


# ===========================================================================
#  STOP / CLEAN UP   - the part that has to be safe on a production box
#
#  The rules it follows, and you can see each decision on screen:
#    1. Only OUR processes are touched. Ours = started by this script (the
#       action name is in its command line), or writing into our own run
#       directory, or capturing on the dvfilter of a VM this config names.
#       There is no "killall pktcap-uw" anywhere in this file.
#    2. A span session is released only when it mirrors a LIF from THIS
#       config. A session somebody else created is reported, never deleted.
#    3. Files are deleted only from directories holding our 00-run-info.txt.
#    4. Nothing is deleted while a collector is still running.
#    5. "stop --dry-run" / "wipe --dry-run" show every decision and change
#       nothing at all.
#    6. It ends with a verification block and exits non-zero if anything is
#       left behind, so a script can check it.
# ===========================================================================
ps_line() {   # one readable line for a pid, whatever the platform
  local _p
  _p="$1"
  if [ "$PLAT" = edge ]; then
    ps -o pid=,args= -p "$_p" 2>/dev/null | cut -c1-110
  else
    ps -c 2>/dev/null | awk -v c="$_p" '$2 == c {$1=""; print substr($0,2,110); exit}'
  fi
}
our_poll_actions() {
  if [ "$PLAT" = edge ]; then echo "stats-run sess-run"; else echo "stats-run dfw-run"; fi
}
our_cap_actions() {
  if [ "$PLAT" = edge ]; then echo "cap-lbt1 cap-vpct1"; else echo "cap-pre cap-post"; fi
}
all_our_pids() {
  local _a
  for _a in $(our_poll_actions) $(our_cap_actions); do act_pids "$_a"; done
  cap_pids
}
# wait until the pids are gone, at most $1 seconds. prints nothing.
wait_gone() {
  local _i _left _p
  _i=0
  while [ "$_i" -lt "$1" ]; do
    _left=0
    for _p in $(all_our_pids); do _left=$((_left+1)); done
    [ "$_left" = 0 ] && return 0
    sleep 1; _i=$((_i+1))
  done
  return 1
}
c_stop() {   # $1 = keep | delete    $2 = "" | --dry-run
  local _mode _dry _p _a _n _rc _s _own _left _r
  _mode="$1"; _dry="$2"; _rc=0
  if [ "$_dry" = "--dry-run" ]; then
    ui_band "DRY RUN - nothing will be stopped or deleted"
  else
    ui_band "STOP - our collectors only"
  fi

  # ---- 1. what is ours, and what would happen to it -----------------------
  _n=0
  for _a in $(our_poll_actions); do
    for _p in $(act_pids "$_a"); do
      _n=$((_n+1)); echo "   poller   $_p  $(ps_line "$_p")"
      [ "$_dry" = "--dry-run" ] || kill "$_p" 2>/dev/null
    done
  done
  for _p in $(cap_pids); do
    _n=$((_n+1)); echo "   capture  $_p  $(ps_line "$_p")"
    # INT, never KILL first: tcpdump/pktcap-uw close their file on SIGINT.
    [ "$_dry" = "--dry-run" ] || kill -INT "$_p" 2>/dev/null
  done
  [ "$_n" = 0 ] && echo "   nothing of ours is running"

  if [ "$_dry" != "--dry-run" ] && [ "$_n" -gt 0 ]; then
    echo "   waiting for them to close their files ..."
    if ! wait_gone 15; then
      echo "   still there after 15s - asking again (TERM)"
      for _p in $(all_our_pids); do kill "$_p" 2>/dev/null; done
      if ! wait_gone 10; then
        echo "   still there after 25s - last resort (KILL), our pids only"
        for _p in $(all_our_pids); do kill -9 "$_p" 2>/dev/null; done
        wait_gone 5 || _rc=1
      fi
    fi
  fi

  # ---- 2. Edge: give the span sessions back -------------------------------
  if [ "$PLAT" = edge ]; then
    echo
    for _s in "$CAP_SESSION_LBT1" "$CAP_SESSION_VPCT1"; do
      e_span_owned "$_s"; _own=$?
      case "$_own" in
        0) if [ "$_dry" = "--dry-run" ]; then echo "   span session $_s mirrors our LIF -> would be released"
           else e_span_close "$_s"; echo "   span session $_s released (it mirrored our LIF)"; fi ;;
        1) echo "   span session $_s is empty - nothing to release" ;;
        2) echo "   span session $_s mirrors an interface that is NOT in this config."
           echo "      LEFT ALONE - somebody else is capturing. Check: su admin -c \"get capture sessions\"" ;;
      esac
    done
    # A span session created here also shows up on the OTHER Edge of the
    # cluster, so say it rather than leave a mirror running over there.
    echo "   reminder: run the same stop on the other Edge of the cluster -"
    echo "   a span session created here exists on both nodes."
  fi

  # ---- 3. files -----------------------------------------------------------
  echo
  if [ "$_mode" = delete ]; then
    if [ "$_dry" = "--dry-run" ]; then
      for _r in "$OUT"/run-*; do
        [ -d "$_r" ] || continue
        if [ -f "$_r/00-run-info.txt" ]; then
          echo "   would delete $_r  ($(find "$_r" -type f | grep -c .) files, $(du -sk "$_r" 2>/dev/null | awk '{print $1}') KB)"
        else
          echo "   would SKIP   $_r  (no 00-run-info.txt - not ours)"
        fi
      done
    else
      _left=0
      for _p in $(all_our_pids); do _left=$((_left+1)); done
      if [ "$_left" != 0 ]; then
        echo "   NOT deleting anything - $_left of our processes are still running."
        _rc=1
      else
        c_wipe_files
      fi
    fi
  else
    echo "   files kept. Delete them later with:  sh nsx-collector.sh wipe"
  fi

  # ---- 4. verify ----------------------------------------------------------
  echo
  if [ "$_dry" = "--dry-run" ]; then ui_band "STATE NOW - nothing above was carried out"
  else ui_band "AFTER - what is left"; fi
  _left=0
  for _p in $(all_our_pids); do _left=$((_left+1)); echo "   STILL RUNNING: $_p  $(ps_line "$_p")"; done
  [ "$_left" = 0 ] && echo "   our processes            none"
  [ "$_left" = 0 ] || _rc=1
  if [ "$PLAT" = edge ]; then
    if ip -br link 2>/dev/null | grep -q span; then
      echo "   span interfaces still present:"
      ip -br link 2>/dev/null | grep span | sed 's/^/     /'
      echo "     (one that is not ours belongs to another session - see above)"
    else
      echo "   span interfaces          none"
    fi
  fi
  _r=$(latest_run)
  if [ -n "$_r" ] && [ -d "$_r" ]; then
    echo "   collected data           $_r  ($(find "$_r" -type f | grep -c .) files)"
  else
    echo "   collected data           none left in $OUT"
  fi
  echo
  if [ "$_dry" = "--dry-run" ]; then
    echo "   DRY RUN - nothing was stopped or deleted. Run it without --dry-run."
    return 0
  fi
  if [ "$_rc" = 0 ]; then echo "   CLEAN - nothing of ours is left running."
  else echo "   NOT CLEAN - see the lines above."; fi
  return $_rc
}

# ===========================================================================
#  COMMON ACTIONS
# ===========================================================================
c_filter_report() {
  local _f
  echo
  if filter_set; then
    echo "   FILTER (free expression) is set - it wins over the single fields."
    if [ "$PLAT" = edge ]; then
      _f=$(filter_for vpct1); printf '   %s\n' "   -> $_f"
    else
      _f=$(filter_for esxi);  printf '   %s\n' "   -> $_f"
    fi
    if filt_check "$_f"; then echo "   syntax: OK"; else return 1; fi
  else
    echo "   FILTER is empty - the filter is built from the single fields:"
    if [ "$PLAT" = edge ]; then
      printf '   %-14s %s\n' "VPC T1"  "$(filter_for vpct1)"
      printf '   %-14s %s\n' "LB T1"   "$(filter_for lbt1)"
      filt_check "$(filter_for vpct1)" || return 1
      filt_check "$(filter_for lbt1)"  || return 1
    else
      _f=$(filter_for esxi)
      printf '   %-14s %s\n' "ESXi DFW" "${_f:-(no filter - every packet on the vNIC)}"
      echo "   (on ESXi the single fields become one capture per combination;"
      echo "    set FILTER to get one file per vNIC instead)"
    fi
    echo "   empty means that condition is left out - empty everywhere = every packet"
  fi
  return 0
}
c_config() {
  ui_band "CONFIG   nsx-collector.sh $NSXC_VER   platform: $PLAT"
  printf '   %-16s %s\n' "config file" "$CONF"
  printf '   %-16s %s\n' "case" "${CASE_ID:-(none)}"
  printf '   %-16s %s\n' "tag" "$TAG"
  printf '   %-16s %s\n' "output" "$OUT"
  printf '   %-16s %s\n' "capture" "${CAP_SECS}s, ring ${CAP_FILESIZE}MB x ${CAP_FILECOUNT}, snaplen ${CAP_SNAPLEN:-full}"
  printf '   %-16s %s\n' "polling" "every ${INTERVAL}s for ${DURATION}s"
  c_filter_report
  echo
  ui_thin
  if [ "$PLAT" = edge ]; then
    echo "   Capture interfaces - REQUIRED, at least one:"
    printf '   %-16s %s\n' "VPC T1 uplink" "${LIF_VPCT1_UPLINK:-EMPTY - that capture will not run}"
    printf '   %-16s %s\n' "LB T1 service" "${LIF_LBT1_SVC:-EMPTY - that capture will not run}"
    echo "   Routers/LB to collect state for - empty means skipped, never 'all':"
    printf '   %-16s %s\n' "T0" "${T0_SR_UUID:-(none)}"
    printf '   %-16s %s\n' "T1 VPC" "${T1_VPC_SR_UUID:-(none)}"
    printf '   %-16s %s\n' "T1 LB" "${T1_LB_SR_UUID:-(none)}"
    printf '   %-16s %s\n' "LB" "${LB_UUID:-(none)}"
  else
    echo "   Target VMs - REQUIRED:"
    printf '   %-16s %s\n' "WORKER_VMS" "${WORKER_VMS:-EMPTY - nothing will be collected}"
    printf '   %-16s %s\n' "WORKER_VNIC" "${WORKER_VNIC:-(all vNICs)}"
    printf '   %-16s %s\n' "UPLINK_NICS" "${UPLINK_NICS:-(none)}"
  fi
  echo
  echo "   Edit nsx-collector.conf to change any of this. The menu never writes it."
}
c_selftest() {
  local _bad _c _f _f2 _n _t _u
  ui_band "SELF TEST"
  _bad=0
  printf '   %-34s ' "line endings of nsx-collector.sh/nsx-collector.conf"; echo "OK (checked at start)"
  printf '   %-34s ' "platform"; echo "$PLAT"
  printf '   %-34s ' "running as root"
  _u=$(nsxc_uid); if [ "${_u:-0}" = 0 ]; then echo "OK"; else echo "NO"; _bad=1; fi
  if [ "$PLAT" = esxi ]; then
    for _c in pktcap-uw vsipioctl summarize-dvfilter net-stats tcpdump-uw; do
      printf '   %-34s ' "$_c"; which "$_c" >/dev/null 2>&1 && echo "found" || { echo "MISSING"; _bad=1; }
    done
    printf '   %-34s ' "timeout syntax"; _t=$(x_tmo 1); [ -n "$_t" ] && echo "$_t" || { echo "none - captures will not self-stop"; _bad=1; }
    printf '   %-34s ' "target VMs on this host"
    _n=$(x_all_filters | grep -c .); echo "$_n vNIC(s)"
    [ "$_n" = 0 ] && _bad=1
  else
    for _c in tcpdump ip; do
      printf '   %-34s ' "$_c"; which "$_c" >/dev/null 2>&1 && echo "found" || { echo "MISSING"; _bad=1; }
    done
    printf '   %-34s ' "NSX CLI (su admin)"
    e_cli "get version" >/dev/null 2>&1 && echo "OK" || { echo "FAILED"; _bad=1; }
    printf '   %-34s ' "capture interface set"
    [ -n "$LIF_VPCT1_UPLINK$LIF_LBT1_SVC" ] && echo "yes" || { echo "NO - no capture can run"; _bad=1; }
  fi
  printf '   %-34s ' "output dir writable"
  mkdir -p "$OUT" 2>/dev/null && [ -w "$OUT" ] && echo "OK ($OUT)" || { echo "NO ($OUT)"; _bad=1; }
  printf '   %-34s ' "free space"
  _f=$(free_mb "$OUT"); echo "${_f:-?} MB (floor ${MIN_FREE_MB} MB)"
  printf '   %-34s ' "filter expression"
  if [ "$PLAT" = edge ]; then _f1=$(filter_for vpct1); _f2=$(filter_for lbt1)
    if filt_check "$_f1" >/dev/null && filt_check "$_f2" >/dev/null; then echo "OK"; else echo "INVALID"; _bad=1; fi
  else _f1=$(filter_for esxi)
    if filt_check "$_f1" >/dev/null; then echo "OK"; else echo "INVALID"; _bad=1; fi
  fi
  echo
  if [ "$_bad" = 0 ]; then echo "   ALL GOOD - ready to collect."; else
    echo "   Something above needs fixing before the real window."; fi
  return $_bad
}
c_rehearse() {
  ui_band "REHEARSAL - one sample of everything except the capture"
  echo "   Proves the config is right before you commit to the real window."
  echo
  mkout
  if [ "$PLAT" = edge ]; then e_stats_once; e_sessions_once
  else x_stats_once; x_dfw_once; fi
  echo
  ui_band "WHAT IT PRODUCED"
  find "$OUT" -type f 2>/dev/null | sed 's|^|   |' | head -30
  echo "   ... $(find "$OUT" -type f 2>/dev/null | grep -c .) files in total"
  echo
  echo "   Clear it before the real run:   sh nsx-collector.sh wipe"
}
c_start_one() {   # $1 = action, $2 = log name
  echo "   \$ nohup sh $_self $1 > $LOGDIR/nsxc-$2.log 2>&1 </dev/null &"
  NSXC_RUN="$RUN" nohup sh "$_self" "$1" > "$LOGDIR/nsxc-$2.log" 2>&1 </dev/null &
  sleep 1
}
c_start() {
  ui_band "START - all collectors"
  echo "   Captures stop by themselves after CAP_SECS (${CAP_SECS}s)."
  echo "   Polling runs for DURATION (${DURATION}s)."
  echo
  c_filter_report || die "fix FILTER in nsx-collector.conf first - nothing was started."
  echo
  # one run directory for everything started here
  mkout; RUN=$(run_dir); run_info "$RUN"
  echo "   results -> $RUN"
  echo
  if [ "$PLAT" = edge ]; then
    if [ -n "$LIF_LBT1_SVC" ]; then c_start_one cap-lbt1 lbt1
    else echo "   LB T1 capture NOT started: LIF_LBT1_SVC is empty (required for it)"; fi
    if [ -n "$LIF_VPCT1_UPLINK" ]; then c_start_one cap-vpct1 vpct1
    else echo "   VPC T1 capture NOT started: LIF_VPCT1_UPLINK is empty (required for it)"; fi
    [ -n "$LIF_LBT1_SVC$LIF_VPCT1_UPLINK" ] || {
      echo; echo "   *** NO PACKET CAPTURE WILL RUN - both LIF_* are empty. ***"; echo; }
    c_start_one stats-run stats
    c_start_one sess-run  sess
    sleep 5
    ip -br link 2>/dev/null | grep span || echo "   no span yet - give it a few seconds"
  else
    x_need_vms || { echo; echo "   *** NOTHING WILL BE COLLECTED - WORKER_VMS is empty. ***"; echo; }
    c_start_one cap-pre  pre
    c_start_one cap-post post
    c_start_one stats-run stats
    c_start_one dfw-run   dfw
    sleep 5
  fi
  echo "   Logs: $LOGDIR/nsxc-*.log"
  echo
  c_status
}
c_status() {
  local _a _m _n _name _now _r _rd _sub _sz _v
  ui_band "STATUS   $(date '+%Y-%m-%d %H:%M:%S')"
  _now=$(date +%s)
  for _m in "$OUT"/.nsxc-end-*; do
    [ -f "$_m" ] || continue
    _name=$(basename "$_m" | sed 's/^\.nsxc-end-//')
    _v=$(cat "$_m" 2>/dev/null)
    if [ "$_v" = done ]; then printf '   %-12s %s\n' "$_name" "finished"
    else printf '   %-12s %s\n' "$_name" "$(hms $(( _v - _now ))) left"; fi
  done
  printf '   %-12s %s\n' "captures" "$(cap_pids | grep -c .) process(es) running"
  _r=0
  for _a in stats-run sess-run dfw-run; do _r=$(( _r + $(act_pids "$_a" | grep -c .) )); done
  printf '   %-12s %s\n' "pollers" "$_r running"
  printf '   %-12s %s MB\n' "free" "$(free_mb "$OUT")"
  _rd=$(latest_run)
  echo
  if [ -n "$_rd" ] && [ -d "$_rd" ]; then
    echo "   run directory: $_rd"
    for _sub in pcap state session; do
      _n=$(find "$_rd/$_sub" -type f 2>/dev/null | grep -c .)
      _sz=$(du -sk "$_rd/$_sub" 2>/dev/null | awk '{print $1}')
      printf '     %-8s %3s file(s)  %s KB\n' "$_sub" "$_n" "${_sz:-0}"
    done
    ls -l "$_rd/pcap" 2>/dev/null | tail -n +2 | sed 's/^/     /' | head -8
  else
    echo "   nothing collected yet in $OUT"
  fi
}
c_watch() {
  local _iv
  _iv="${1:-10}"
  while true; do
    clear 2>/dev/null || printf '\n\n'
    c_status
    echo; echo "   refreshing every ${_iv}s - Ctrl+C to stop"
    sleep "$_iv"
  done
}
c_wipe_files() {
  local _r
  case "$OUT" in
    /|/tmp|/var|/var/dump|"") die "refusing to delete $OUT" ;;
  esac
  log "deleting our own run directories under $OUT"
  for _r in "$OUT"/run-*; do
    [ -d "$_r" ] || continue
    # only ours: a run directory always holds 00-run-info.txt
    [ -f "$_r/00-run-info.txt" ] || { log "  skipped $_r (not ours)"; continue; }
    rm -rf "$_r" && log "  removed $_r"
  done
  rm -f "$OUT"/.nsxc-end-* "$OUT"/.nsxc-run 2>/dev/null
  rmdir "$OUT" 2>/dev/null
  log "done"
}
c_help() {
  ui_band "nsx-collector.sh $NSXC_VER - what it collects and why"
  cat <<'EOF'
   One file, two boxes. Start it as:   sh nsx-collector.sh [action]

   ACTIONS
     (no action)   the menu
     config        show what the config says, and the filter it produces
     selftest      check everything that has to be right before a run
     check         platform checks (Edge: which node is Active / ESXi: VM map)
     map           ESXi only: VM <-> DFW filter <-> switch port
     rehearse      one sample of state/sessions, no capture
     start         start every collector in the background
     status        what is running, how much time is left, what was produced
     watch [secs]  status on a loop
     stop          stop our collectors, keep the files
     wipe          stop and delete our own files
     stop|wipe --dry-run    show every decision, change nothing
     help          this text

   SAFE ON A PRODUCTION BOX
     - only processes started by this script, or writing into our own run
       directory, are ever signalled. No "killall".
     - a span session is released only when it mirrors a LIF from this
       config; one that somebody else created is reported and left alone.
     - captures are ended with SIGINT first so the pcap file closes cleanly.
     - files are deleted only from directories holding our 00-run-info.txt,
       and never while a collector is still running.
     - stop/wipe print what is left afterwards and exit non-zero if anything
       of ours survived.

   ON AN NSX EDGE it collects
     - a packet capture on the LB T1 service interface and/or the VPC T1
       uplink, through a span mirror plus tcpdump (a real ring buffer, and
       it stops by the clock)
     - interface / dataplane / CPU / memory counters
     - firewall connection tables and load balancer status, pool and
       virtual server state

   ON AN ESXi HOST it collects
     - a DFW capture before (pre) and after (post) the rules, per vNIC of
       the VMs you named
     - the DFW flow table, the applied rules and the pass/drop counters
     - switch port and uplink NIC counters

   WHAT TO CAPTURE
     FILTER="..." in nsx-collector.conf takes a normal tcpdump expression with
     and / or / not / ( ). It is checked for syntax before anything starts.
     Leave FILTER empty to use the single fields instead (HOSTS, PROTO,
     PORTS and the per-leg ones). Empty everywhere = every packet.

   THE TWO RULES OF THIS TOOL
     1. It only touches what the config names. Empty is "skip", never "all".
     2. Stopping is safe: processes are matched by the file they write, so a
        capture somebody else started is never killed.
EOF
}
c_menu() {
  ui_rule
  ui_row "  NSX Collector $NSXC_VER"
  ui_row "  ${CASE_ID:-<no case>}   $PLAT / $TAG   $(date '+%Y-%m-%d %H:%M:%S')"
  ui_rule
  ui_row ""
  ui_row "    SETUP                        RUN"
  ui_row "      1  config                    5  start all"
  ui_row "      2  selftest                  6  status"
  if [ "$PLAT" = esxi ]; then
    ui_row "      3  check / VM map            w  watch"
  else
    ui_row "      3  check (Active node)       w  watch"
  fi
  ui_row "      4  rehearse                "
  ui_row ""
  ui_row "    FINISH                       "
  ui_row "      7  stop          keep files   9  help"
  ui_row "      8  stop + delete files        q  quit"
  ui_row "      d  dry run - show what 8 would stop and delete"
  ui_row ""
  ui_rule
}

# ===========================================================================
#  DISPATCH
# ===========================================================================
case "${1:-}" in
  config)    c_config; exit 0 ;;
  selftest)  c_selftest; exit $? ;;
  check)     [ "$PLAT" = edge ] && e_check || x_check; exit 0 ;;
  map)       [ "$PLAT" = esxi ] || die "map is ESXi only"; x_map; exit 0 ;;
  rehearse)  c_rehearse; exit 0 ;;
  start)     c_start; exit 0 ;;
  status)    c_status; exit 0 ;;
  watch)     c_watch "${2:-10}"; exit 0 ;;
  stop)      c_stop keep   "${2:-}"; exit $? ;;
  wipe)      c_stop delete "${2:-}"; exit $? ;;
  help|-h|--help) c_help; exit 0 ;;
  # --- the collectors themselves (the menu starts these) -------------------
  cap-lbt1)  e_cap_lbt1 "${2:-}"; exit 0 ;;
  cap-vpct1) e_cap_vpct1 "${2:-}"; exit 0 ;;
  cap-pre)   x_cap pre  "${2:-}"; exit 0 ;;
  cap-post)  x_cap post "${2:-}"; exit 0 ;;
  stats-once) mkout; [ "$PLAT" = edge ] && e_stats_once || x_stats_once; exit 0 ;;
  sess-once)  mkout; e_sessions_once; exit 0 ;;
  dfw-once)   mkout; x_dfw_once; exit 0 ;;
  stats-run|sess-run|dfw-run)
    _act="$1"; mkout
    log "start - every ${INTERVAL}s for ${DURATION}s -> $OUT"
    mark_start "${_act%-run}" "$DURATION"
    _end=$(( $(date +%s) + DURATION )); _n=0
    while [ "$(date +%s)" -lt "$_end" ]; do
      space_ok || break
      _n=$((_n+1))
      case "$_act" in
        stats-run) [ "$PLAT" = edge ] && e_stats_once || x_stats_once ;;
        sess-run)  e_sessions_once ;;
        dfw-run)   x_dfw_once ;;
      esac
      _now=$(date +%s); [ "$_now" -lt "$_end" ] || break
      _left=$(( _end - _now ))
      if [ "$INTERVAL" -lt "$_left" ]; then sleep "$INTERVAL"; else sleep "$_left"; fi
    done
    mark_done "${_act%-run}"
    log "$_n sample(s). output: $OUT"; exit 0 ;;
  "") ;;
  *) echo "Unknown action: $1"; echo "Try: sh nsx-collector.sh help"; exit 2 ;;
esac

# ===========================================================================
#  INTERACTIVE MENU
# ===========================================================================
while true; do
  echo; c_menu; echo
  printf "   choose > "
  read -r a || break
  echo
  case "$a" in
    1) c_config ;;
    2) c_selftest ;;
    3) [ "$PLAT" = edge ] && e_check || x_check ;;
    4) c_rehearse ;;
    5) c_start ;;
    6) c_status ;;
    w|W) c_watch 10 ;;
    7) c_stop keep ;;
    8) c_stop delete ;;
    d|D) c_stop delete --dry-run ;;
    9) c_help ;;
    q|Q) exit 0 ;;
    *) echo "   ?" ;;
  esac
  echo; printf "   Press Enter for the menu "; read _x
done

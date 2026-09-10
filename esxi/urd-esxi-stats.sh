#!/bin/sh
# ===========================================================================
#  ESXi state collection - run as root on the host (repeats)
#
#  Collects: physical NIC stats (incl. "Receive missed errors" = ring overrun),
#            switch port list, per-vNIC port stats of the worker node VMs.
#
#  USAGE
#      sh urd-esxi-stats.sh once     # one sample
#      sh urd-esxi-stats.sh run      # repeat every INTERVAL for DURATION
# ===========================================================================
. "$(dirname "$0")/urd-esxi-lib.sh"
mkout
D="$OUT/stats-$HOST_TAG"; mkdir -p "$D"

collect() {
  log "[$1] state collection -> $D"
  snap "$D/A0-niclist.txt" esxcli network nic list
  for N in $UPLINK_NICS; do
    snap "$D/A1-nic-$N.txt" esxcli network nic stats get -n "$N"
  done
  # WORKER_VMS only - see the SCOPE note in urd-esxi-lib.sh
  snap "$D/A2-portlist.txt" portlist_ours

  require_targets || return 0
  PORTS=$(portlist_ours)          # read the host once, not once per VM
  for VM in $WORKER_VMS; do
    # a VM with several vNICs has several switch ports
    for P in $(vm_ports "$VM"); do
      C=$(echo "$PORTS" | awk -v p="$P" '$1==p{print $NF; exit}')
      snap "$D/A3-port-$VM-${C##*.}.txt" esxcli network port stats get -p "$P"
    done
  done
}

case "${1:-run}" in
  once) collect 1 ;;
  run)
    log "start - every ${INTERVAL}s for ${DURATION}s -> $D"
    mark_start "stats" "$DURATION"
    trap 'mark_done "stats"' EXIT
    END=$(( $(date +%s) + DURATION )); N=0
    while [ "$(date +%s)" -lt "$END" ]; do
      space_ok || break
      N=$((N+1)); collect "$N"
      NOW=$(date +%s); [ "$NOW" -lt "$END" ] || break
      L=$(( END - NOW )); [ "$INTERVAL" -lt "$L" ] && sleep "$INTERVAL" || sleep "$L"
    done
    log "$N samples. output: $D" ;;
  *) echo "usage: $(basename "$0") <once|run>"; exit 1 ;;
esac

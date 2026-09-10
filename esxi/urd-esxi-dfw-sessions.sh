#!/bin/sh
# ===========================================================================
#  DFW connection table collection - run as root on the host (repeats)
#
#  Must run separately from the Edge session collection: the DFW lives in the
#  hypervisor kernel and has one filter per worker node vNIC.
#
#  Collects: DFW flow table, applied rules, filter stats (v4 pass/drop).
#
#  USAGE
#      sh urd-esxi-dfw-sessions.sh map     # show VM <-> filter <-> port only
#      sh urd-esxi-dfw-sessions.sh once
#      sh urd-esxi-dfw-sessions.sh run
#
#  Run "map" first. VMs that are not on this host show "(not on this host)";
#  that is normal - they live on another host, run the script there too.
# ===========================================================================
. "$(dirname "$0")/urd-esxi-lib.sh"
mkout
D="$OUT/dfw-$HOST_TAG"; mkdir -p "$D"

do_map() {
  printf '%-38s %-6s %-36s %s\n' "VM" "vNIC" "DFW filter" "port"
  for VM in $WORKER_VMS; do
    WANT=$(vnic_for "$VM")
    FILTERS=$(dfw_filters "$VM" "$WANT")
    if [ -z "$FILTERS" ]; then
      # Do not say "not on this host" when it is here and WORKER_VNIC hid it.
      HAS=$(dfw_filters "$VM" "" | while read F; do filter_nic "$F"; done | xargs)
      if [ -n "$WANT" ] && [ -n "$HAS" ]; then
        printf '%-38s %s\n' "$VM" "(here, but no vNIC matches '$WANT'; has: $HAS)"
      else
        printf '%-38s %s\n' "$VM" "(not on this host)"
      fi
      continue
    fi
    for F in $FILTERS; do
      NIC=$(filter_nic "$F")
      P=$(net-stats -l 2>/dev/null | awk -v c="$VM.$NIC" '$NF==c{print $1; exit}')
      printf '%-38s %-6s %-36s %s\n' "$VM" "$NIC" "$F" "${P:-?}"
    done
  done
}

collect() {
  TS=$(date '+%H%M%S')
  log "[$1] DFW collection -> $D"
  # WORKER_VMS only - see the SCOPE note in urd-esxi-lib.sh
  snap "$D/A1-dvfilter-list.txt" dvfilter_ours
  require_targets || return 0
  for VM in $WORKER_VMS; do
    for F in $(dfw_filters "$VM" "$(vnic_for "$VM")"); do
      NIC=$(filter_nic "$F"); T="$VM-$NIC"
      vsipioctl getflows -f "$F" > "$D/B1-flows-$T-$TS.txt" 2>&1
      grep -i "$PROTO" "$D/B1-flows-$T-$TS.txt" > "$D/B2-flows-$PROTO-$T-$TS.txt" 2>/dev/null
      snap "$D/C1-rules-$T.txt"      vsipioctl getrules -f "$F"
      snap "$D/D1-filterstat-$T.txt" vsipioctl getfilterstat -f "$F"
      NALL=$(grep -c '^[0-9]' "$D/B1-flows-$T-$TS.txt" 2>/dev/null)
      NPRO=$(grep -c . "$D/B2-flows-$PROTO-$T-$TS.txt" 2>/dev/null)
      {
        echo "########## $TS $VM ($NIC) ##########"
        echo "  total flows : ${NALL:-0}"
        echo "  $PROTO flows : ${NPRO:-0}"
        vsipioctl getfilterstat -f "$F" 2>/dev/null | awk '/^v4 (pass|drop)/{printf "  %s %s IN / %s OUT\n",$1" "$2,$3,$4}'
        echo
      } >> "$D/F1-summary.txt"
    done
  done
}

case "${1:-run}" in
  map)  do_map ;;
  once) collect 1 ;;
  run)
    log "start - every ${INTERVAL}s for ${DURATION}s -> $D"
    mark_start "dfw" "$DURATION"
    trap 'mark_done "dfw"' EXIT
    do_map | tee "$D/A0-mapping.txt"
    END=$(( $(date +%s) + DURATION )); N=0
    while [ "$(date +%s)" -lt "$END" ]; do
      space_ok || break
      N=$((N+1)); collect "$N"
      NOW=$(date +%s); [ "$NOW" -lt "$END" ] || break
      L=$(( END - NOW )); [ "$INTERVAL" -lt "$L" ] && sleep "$INTERVAL" || sleep "$L"
    done
    log "$N samples. output: $D" ;;
  *) echo "usage: $(basename "$0") <map|once|run>"; exit 1 ;;
esac

#!/bin/bash
# ===========================================================================
#  Edge session / connection collection - run as root on this Edge (repeats)
#
#  Collects: gateway firewall connection tables (for the LIFs in the config),
#            LB L4/L7 session tables, pool stats/status, SNAT pools,
#            health check table, persistence tables,
#            plus an automatic summary of the L4 session table.
#
#  If this Edge has no LB, the LB part is skipped automatically.
#
#  Reads from the config: INTERVAL, DURATION (not any CAP_* value).
#
#  USAGE
#      bash urd-edge-sessions.sh once
#      bash urd-edge-sessions.sh run
# ===========================================================================
. "$(dirname "${BASH_SOURCE[0]}")/urd-edge-lib.sh"
mkout
D="$OUT/sessions-$EDGE_TAG"; mkdir -p "$D"

collect() {
  local n="$1" ts; ts=$(date '+%H%M%S')
  log "[$n] session collection -> $D"

  for pair in "t0-uplink:${LIF_T0_UPLINK:-}" \
              "vpct1-uplink:${LIF_VPCT1_UPLINK:-}" \
              "vpct1-downlink:${LIF_VPCT1_DOWNLINK:-}" \
              "lbt1-svc:${LIF_LBT1_SVC:-}"; do
    local tag="${pair%%:*}" lif="${pair#*:}"
    [ -n "$lif" ] || continue
    snap "$D/A1-conncount-$tag.txt" cli "get firewall $lif connection count"
    cli "get firewall $lif connection" > "$D/A2-conn-$tag-$ts.txt" 2>&1
  done

  [ -n "${LB_UUID:-}" ] || { log "  no LB_UUID - skipping LB part"; return; }

  cli "get load-balancer $LB_UUID session-tables l4" > "$D/B1-l4-$ts.txt" 2>&1
  cli "get load-balancer $LB_UUID session-tables l7" > "$D/B2-l7-$ts.txt" 2>&1
  snap "$D/C1-pools-stats.txt"  cli "get load-balancer $LB_UUID pools stats"
  snap "$D/C2-pools-status.txt" cli "get load-balancer $LB_UUID pools status"
  snap "$D/C3-healthcheck.txt"  cli "get load-balancer $LB_UUID health-check-table"
  snap "$D/C4-persistence.txt"  cli "get load-balancer $LB_UUID persistence-tables"
  snap "$D/D1-diagnosis.txt"    cli "get load-balancer $LB_UUID diagnosis summary"
  for P in ${LB_POOL_UUIDS:-}; do
    snap "$D/C5-snat-$P.txt"     cli "get load-balancer $LB_UUID pool $P snat-pools"
    snap "$D/C6-poolstat-$P.txt" cli "get load-balancer $LB_UUID pool $P stats"
  done

  # L4 session table summary.
  # Columns verified in the lab:
  #   1=TABLE 2=ID 3=PROTO 4=CADDR 5=CPORT 6=VADDR 7=VPORT
  #   8=SADDR 9=SPORT 10=DADDR 11=DPORT 12=EXP
  local f="$D/B1-l4-$ts.txt"
  [ -s "$f" ] || return
  {
    echo "########## $ts ##########"
    echo "[$PROTO sessions]        $(awk -v p="$PROTO" '$3==p' "$f" | wc -l)"
    echo "[sessions per backend]"
    awk -v p="$PROTO" '$3==p{print "   "$10":"$11}' "$f" | sort | uniq -c | sort -rn | head -20
    echo "[unique client IPs]      $(awk -v p="$PROTO" '$3==p{print $4}' "$f" | sort -u | wc -l)"
    echo "[unique client ports]    $(awk -v p="$PROTO" '$3==p{print $5}' "$f" | sort -u | wc -l)"
    echo "[unique SNAT ports]      $(awk -v p="$PROTO" '$3==p{print $9}' "$f" | sort -u | wc -l)"
    echo "[EXP distribution]"
    awk -v p="$PROTO" '$3==p{print $12}' "$f" | sort -n | \
      awk '{a[NR]=$1} END{if(NR)printf "   min=%s median=%s max=%s n=%s\n",a[1],a[int(NR/2)+1],a[NR],NR}'
    echo
  } >> "$D/E1-l4-summary.txt"
}

case "${1:-run}" in
  once) collect 1 ;;
  run)
    log "start - every ${INTERVAL}s for ${DURATION}s -> $D"
    mark_start "sessions" "$DURATION"
    trap 'mark_done "sessions"' EXIT
    END=$(( $(date +%s) + DURATION )); N=0
    while [ "$(date +%s)" -lt "$END" ]; do
      space_ok || break
      N=$((N+1)); collect "$N"
      NOW=$(date +%s); [ "$NOW" -lt "$END" ] || break
      LEFT=$(( END - NOW )); [ "$INTERVAL" -lt "$LEFT" ] && sleep "$INTERVAL" || sleep "$LEFT"
    done
    log "$N samples. output: $D"
    [ -s "$D/E1-l4-summary.txt" ] && tail -18 "$D/E1-l4-summary.txt" ;;
  *) echo "usage: $(basename "$0") <once|run>"; exit 1 ;;
esac

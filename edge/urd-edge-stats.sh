#!/bin/bash
# ===========================================================================
#  Edge state collection - run as root on this Edge (repeats)
#
#  Only the logical routers that actually live on this Edge are collected,
#  discovered automatically. The same script therefore works unchanged on a
#  T0 Edge, a VPC T1 Edge or an LB T1 Edge.
#
#  Collects: physical interfaces, per-interface RX/TX drops, per-LIF drop
#            reason counters, DPDK core usage, memory, throughput,
#            flow cache, HA state.
#
#  Reads from the config: INTERVAL, DURATION (not any CAP_* value).
#
#  USAGE
#      bash urd-edge-stats.sh once     # one sample
#      bash urd-edge-stats.sh run      # every INTERVAL for DURATION
# ===========================================================================
. "$(dirname "${BASH_SOURCE[0]}")/urd-edge-lib.sh"
mkout
D="$OUT/stats-$EDGE_TAG"; mkdir -p "$D"

# ---------------------------------------------------------------------------
#  WHICH SERVICE ROUTERS TO COLLECT
#
#  This is a TROUBLESHOOTING tool, not an environment assessment. It collects
#  only the routers named in the config:
#      T0_SR_UUID   T1_VPC_SR_UUID   T1_LB_SR_UUID
#  Nothing is discovered and swept automatically.
#
#  Why that rule is strict - measured on a real Edge, per service router:
#      get logical-router <uuid> interfaces stats         1633 ms
#      get logical-router <uuid> high-availability status   847 ms
#  = about 2.5 s each. A production Edge can host hundreds of T1 service
#  routers; sweeping 100 of them would cost 250 s per sample, INTERVAL=30
#  could never be met, and the control plane would be hammered for hours.
#
#  If none of the three is set the script collects NO per-router data and
#  says so. It does not guess. The rest of the sample (interfaces, CPU,
#  memory, throughput, flow cache) is still collected - those are per-Edge
#  and cost the same no matter how big the environment is.
#
#  Escape hatch, opt-in only, never the default:
#      SR_AUTO=1 bash urd-edge-stats.sh once
#  collects every service router on this Edge, still refusing above SR_MAX.
# ---------------------------------------------------------------------------
SR_MAX="${SR_MAX:-10}"
SR_AUTO="${SR_AUTO:-0}"

# Note: this function's STDOUT is consumed by a pipe, so it must contain
# nothing but "<uuid> <name>" lines. Every message goes to STDERR - log()
# writes to stdout and would be parsed as if it were a router.
say() { echo "$@" >&2; }

select_srs() {          # prints "<uuid> <name>" lines on stdout, messages on stderr
  local all want="" u line n
  all=$(cli "get logical-routers" | awk '/SERVICE_ROUTER_TIER[01]/{print $1" "$4}')

  for u in "${T0_SR_UUID:-}" "${T1_VPC_SR_UUID:-}" "${T1_LB_SR_UUID:-}"; do
    [ -n "$u" ] || continue
    line=$(echo "$all" | awk -v id="$u" '$1==id{print; exit}')
    if [ -n "$line" ]; then
      want="$want$line
"
    else
      say "  Warning: $u is not a service router on this Edge - skipped"
    fi
  done

  if [ -n "$want" ]; then
    printf '%s' "$want"
    return 0
  fi

  n=$(echo "$all" | grep -c .)

  if [ "$SR_AUTO" != "1" ]; then
    say "  no T0_SR_UUID / T1_VPC_SR_UUID / T1_LB_SR_UUID set in the config."
    say "  Skipping per-router stats (A3/A5). This tool pinpoints the routers"
    say "  you are troubleshooting - it does not sweep the whole Edge."
    say "  This Edge currently hosts $n service router(s). Pick the ones you"
    say "  need with:  su admin -c \"get logical-routers\""
    say "  (SR_AUTO=1 collects all of them, only if you really mean it.)"
    return 1
  fi

  if [ "$n" -gt "$SR_MAX" ]; then
    say "  SR_AUTO=1 but this Edge hosts $n service routers (SR_MAX=$SR_MAX)."
    say "  Refusing - about 2.5s each would overload this Edge and INTERVAL"
    say "  could never be met. Name the routers in the config instead."
    return 1
  fi
  say "  SR_AUTO=1 - collecting all $n service router(s) on this Edge"
  printf '%s\n' "$all"
}

collect() {
  local n="$1"
  log "[$n] state collection -> $D"

  snap "$D/A1-interface.txt"        cli 'get interface'
  for P in ${FP_PORTS:-}; do
    snap "$D/A2-physport-$P.txt"    cli "get physical-port $P"
  done
  snap "$D/D1-throughput.txt"       cli 'get dataplane throughput 5'
  snap "$D/B1-cpu.txt"              cli 'get dataplane cpu stats'
  snap "$D/B2-cpu-verbose.txt"      cli 'get dataplane cpu stats verbose'
  snap "$D/C1-memory.txt"           cli 'get memory'
  snap "$D/C2-dp-memory.txt"        cli 'get dataplane memory stats'
  snap "$D/E1-flowcache.txt"        cli 'get dataplane flow-cache stats'

  # per service router: interface stats and HA state (config-scoped)
  select_srs | while read -r uuid name; do
    # second line of defence: ignore anything that is not a UUID, so a stray
    # message can never be turned into a bogus "router" file
    case "$uuid" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*-*-*-*) ;;
      *) continue ;;
    esac
    local tag; tag=$(echo "$name" | sed 's/[^A-Za-z0-9-]/_/g' | cut -c1-40)
    snap "$D/A3-lr-$tag-ifstats.txt" cli "get logical-router $uuid interfaces stats"
    snap "$D/A5-lr-$tag-ha.txt"      cli "get logical-router $uuid high-availability status"
  done

  # per-LIF drop reason counters - only for LIFs listed in the config
  for pair in "t0-uplink:${LIF_T0_UPLINK:-}" \
              "vpct1-uplink:${LIF_VPCT1_UPLINK:-}" \
              "vpct1-downlink:${LIF_VPCT1_DOWNLINK:-}" \
              "lbt1-svc:${LIF_LBT1_SVC:-}"; do
    local tag="${pair%%:*}" lif="${pair#*:}"
    [ -n "$lif" ] || continue
    snap "$D/A4-fwstats-$tag.txt" cli "get firewall $lif interface stats"
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
      LEFT=$(( END - NOW )); [ "$INTERVAL" -lt "$LEFT" ] && sleep "$INTERVAL" || sleep "$LEFT"
    done
    log "$N samples. output: $D" ;;
  *) echo "usage: $(basename "$0") <once|run>"; exit 1 ;;
esac

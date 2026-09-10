#!/bin/bash
# ===========================================================================
#  LB T1 service interface packet capture - run as root on the Edge that
#  hosts the LB T1
#
#  HOW
#      Same span + tcpdump method as the VPC T1 capture:
#        [admin] set capture session <N> interface <LIF> direction dual
#        [root ] tcpdump -nei span-<N> -Z root ... -w /var/dump/urd/pcap/...
#        [admin] del capture session <N>     <- automatic, also on Ctrl-C
#
#      If both captures run on the SAME Edge the span session ids must differ.
#      This one uses session 1, the VPC T1 one uses 0 (CAP_SESSION_* in config).
#
#  WHERE
#      LB T1 SR, Port-type: service  (the interface the LB is attached to)
#
#  WHY this FILTER  <- the point of this script
#      With a one-arm LB both legs cross the same interface:
#        front leg : client      <-> VIP           <PROTO>/<SVC_PORT>
#        back  leg : LB SNAT IP  <-> worker node   <PROTO>/<NODE_PORT>
#
#      Filtering on the SNAT IP alone shows only the back leg, so you cannot
#      tell whether the request ever reached the LB.
#      Filtering on the VIP alone hides whether the LB forwarded to a backend.
#      Capturing both puts all four events in one file, in order:
#        1 client request arrives     2 LB forwards to backend
#        3 backend reply arrives      4 LB replies to client
#      Where it breaks is decided by this single file.
#
#      filter: (host <VIP> and <PROTO> port <SVC_PORT>)
#           or (host <LB_SNAT_IP> and <PROTO> port <NODE_PORT>)
#           or icmp
#
#  HOW TO GET LB_SNAT_IP
#      su admin -c "get load-balancers"
#      su admin -c "get load-balancer <LB-UUID> pools status"
#      su admin -c "get load-balancer <LB-UUID> pool <POOL-UUID> snat-pools"
#        -> the "Snat IP :" value. For a one-arm LB this is usually the same
#           as the T1 service interface IP.
#        -> if SNAT uses a pool, set LB_SNAT_IP="net 192.168.13.0/28"
#
#  USAGE
#      bash urd-edge-cap-lbt1-svc.sh [seconds]
# ===========================================================================
. "$(dirname "${BASH_SOURCE[0]}")/urd-edge-lib.sh"
need VIP PROTO SVC_PORT NODE_PORT LIF_LBT1_SVC
SECS="${1:-$CAP_SECS}"
SESS="${CAP_SESSION_LBT1:-1}"
mkout

if [ -z "${LB_SNAT_IP:-}" ]; then
  cat >&2 <<'MSG'
LB_SNAT_IP is empty. Get it and put it in urd-edge.conf:
  su admin -c "get load-balancers"
  su admin -c "get load-balancer <LB-UUID> pools status"
  su admin -c "get load-balancer <LB-UUID> pool <POOL-UUID> snat-pools"
MSG
  exit 2
fi

# "net x.x.x.x/nn" is used as is; a bare IP gets "host " prefixed
case "$LB_SNAT_IP" in
  net\ *) SNAT_MATCH="$LB_SNAT_IP" ;;
  *)      SNAT_MATCH="host $LB_SNAT_IP" ;;
esac
FILT="(host $VIP and $PROTO port $SVC_PORT) or ($SNAT_MATCH and $PROTO port $NODE_PORT) or icmp"

cap "lbt1-svc" "$LIF_LBT1_SVC" "$FILT" "$SECS" "$SESS"

cat <<TXT

collect:  scp root@$(hostname):$OUT/pcap/urd-${EDGE_TAG}-lbt1-svc-*.pcap* <collector>:<path>/
clean  :  rm -f $OUT/pcap/urd-${EDGE_TAG}-lbt1-svc-*.pcap*
TXT

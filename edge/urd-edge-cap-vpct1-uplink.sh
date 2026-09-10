#!/bin/bash
# ===========================================================================
#  VPC T1 uplink packet capture - run as root on the Edge that hosts the VPC T1
#
#  HOW
#      A span mirror session is created through the admin CLI, then a plain
#      tcpdump is attached to it:
#        [admin] set capture session <N> interface <LIF> direction dual
#        [root ] tcpdump -nei span-<N> -Z root ... -w /var/dump/urd/pcap/...
#        [admin] del capture session <N>     <- the script does this for you,
#                                               also on Ctrl-C
#
#  WHERE
#      VPC T1 SR, Port-type: uplink  (the T0 <-> T1 transit, usually 100.64.x.x)
#      This is the gate where the request enters NSX and the reply leaves.
#
#  WHY this FILTER
#      The destination here is the LB virtual server IP (VIP). But depending on
#      where NAT is undone - above T0 or below this point - it may still carry
#      the external NAT IP, so both are matched.
#      CLIENT_IP is OR'ed in as a safety net: if the source is preserved we
#      still catch the flow even if the destination was translated to something
#      unexpected. It is a single IP, so it costs nothing.
#      ICMP is included because a port-unreachable coming back when there is no
#      backend is what separates "silently dropped" from "explicitly refused".
#
#      filter: (host <VIP> or host <NAT_IP> or host <CLIENT_IP>)
#              and (<PROTO> port <SVC_PORT> or icmp)
#
#  USAGE
#      bash urd-edge-cap-vpct1-uplink.sh          # uses CAP_SECS
#      bash urd-edge-cap-vpct1-uplink.sh 600      # or give seconds directly
# ===========================================================================
. "$(dirname "${BASH_SOURCE[0]}")/urd-edge-lib.sh"
need VIP PROTO SVC_PORT LIF_VPCT1_UPLINK
SECS="${1:-$CAP_SECS}"
SESS="${CAP_SESSION_VPCT1:-0}"
mkout

FILT="(host $VIP"
[ -n "${NAT_IP:-}"    ] && FILT="$FILT or host $NAT_IP"
[ -n "${CLIENT_IP:-}" ] && FILT="$FILT or host $CLIENT_IP"
FILT="$FILT) and ($PROTO port $SVC_PORT or icmp)"

cap "vpct1-uplink" "$LIF_VPCT1_UPLINK" "$FILT" "$SECS" "$SESS"

cat <<TXT

collect:  scp root@$(hostname):$OUT/pcap/urd-${EDGE_TAG}-vpct1-uplink-*.pcap* <collector>:<path>/
clean  :  rm -f $OUT/pcap/urd-${EDGE_TAG}-vpct1-uplink-*.pcap*
TXT

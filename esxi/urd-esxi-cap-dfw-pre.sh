#!/bin/sh
# ===========================================================================
#  DFW pre-stage packet capture - run as root on the ESXi host that holds
#  the worker node VM.
#
#  WHERE
#      The DFW (vmware-sfw) filter on the worker node VM vNIC, stage "pre",
#      i.e. before the DFW rules are applied.
#      Answers: "did the packet even reach the node?"
#
#  WHY this FILTER
#      Packets here look like:  src = LB SNAT IP, dst = node own IP,
#      port = NodePort. The original client IP is already gone (LB SNAT).
#      The node's own IP is on every packet of that vNIC, so it cannot
#      discriminate. The NodePort can.
#      --udpport matches src OR dst, so request (dst=NodePort) and
#      reply (src=NodePort) are both captured in one file.
#
#      default:   --udpport <NODE_PORT>
#      optional:  --ip <LB_SNAT_IP>   (narrows volume)
#          Leave LB_SNAT_IP empty unless you are sure the LB does SNAT,
#          otherwise you capture nothing.
#
#  PRE vs POST
#      Run both. Packets present in pre but missing in post were dropped
#      by the DFW. The filter must be identical for the comparison to work,
#      which it is, since both scripts share _cap-dfw.sh.
#
#  USAGE
#      sh urd-esxi-cap-dfw-pre.sh          # uses CAP_SECS from the config
#      sh urd-esxi-cap-dfw-pre.sh 600      # or give seconds directly
# ===========================================================================
. "$(dirname "$0")/urd-esxi-lib.sh"
SECS="${1:-$CAP_SECS}"
mkout
sh "$(dirname "$0")/_cap-dfw.sh" pre "$SECS"

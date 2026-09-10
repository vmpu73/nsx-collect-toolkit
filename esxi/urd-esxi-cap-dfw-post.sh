#!/bin/sh
# ===========================================================================
#  DFW post-stage packet capture - run as root on the ESXi host that holds
#  the worker node VM.
#
#  Same point as the pre capture but after the DFW rules are applied.
#  Answers: "did the DFW let the packet through?"
#
#  Packets in pre but not in post = dropped by the DFW.
#  The filter is identical to the pre capture (both use _cap-dfw.sh),
#  which is what makes the comparison valid.
#
#  See urd-esxi-cap-dfw-pre.sh for the filter rationale.
#
#  USAGE
#      sh urd-esxi-cap-dfw-post.sh [seconds]
# ===========================================================================
. "$(dirname "$0")/urd-esxi-lib.sh"
SECS="${1:-$CAP_SECS}"
mkout
sh "$(dirname "$0")/_cap-dfw.sh" post "$SECS"

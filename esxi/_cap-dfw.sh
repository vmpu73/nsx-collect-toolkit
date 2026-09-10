#!/bin/sh
# ===========================================================================
#  _cap-dfw.sh - shared body for the DFW pre/post captures
#
#  DO not RUN this FILE. DO not EDIT IT.
#  It is called by urd-esxi-cap-dfw-pre.sh and urd-esxi-cap-dfw-post.sh.
# ===========================================================================
. "$(dirname "$0")/urd-esxi-lib.sh"
STAGE="$1"; SECS="$2"
[ "$STAGE" = pre ] || [ "$STAGE" = post ] || die "stage must be pre or post"

# Build the filter. pktcap-uw is not BPF: it takes option flags and
# ANDs them together. There is no OR.
case "$PROTO" in
  udp) PORTOPT="--udpport $NODE_PORT" ;;
  tcp) PORTOPT="--tcpport $NODE_PORT" ;;
  *)   die "PROTO must be udp or tcp" ;;
esac
IPOPT=""
[ -n "$LB_SNAT_IP" ] && IPOPT="--ip $LB_SNAT_IP"
# empty CAP_SNAPLEN -> no -s flag -> pktcap-uw keeps the whole packet
SNAPOPT=""
[ -n "$CAP_SNAPLEN" ] && SNAPOPT="-s $CAP_SNAPLEN"

require_targets || die "nothing to capture."

# How many pktcap-uw processes will this launch? Count first, then check that
# the ring buffers fit. Doing it afterwards is too late - /tmp is a ramdisk.
NCAP=0
for VM in $WORKER_VMS; do
  for F in $(dfw_filters "$VM" "$(vnic_for "$VM")"); do NCAP=$((NCAP+1)); done
done
[ "$NCAP" -gt 0 ] || die "no target VM on this host. check WORKER_VMS."
check_cap_budget "$NCAP"

mark_start "cap-$STAGE" "$SECS"
log "DFW $STAGE capture ${SECS}s  filter: $PORTOPT $IPOPT  snaplen: ${CAP_SNAPLEN:-full packet}"
FOUND=0
for VM in $WORKER_VMS; do
  WANT=$(vnic_for "$VM")
  FILTERS=$(dfw_filters "$VM" "$WANT")
  if [ -z "$FILTERS" ]; then
    # Tell the two cases apart. "not on this host" is the wrong message when
    # the VM is here and WORKER_VNIC filtered it out.
    HAS=$(dfw_filters "$VM" "" | while read F; do filter_nic "$F"; done | xargs)
    if [ -n "$WANT" ] && [ -n "$HAS" ]; then
      log "  $VM - is on this host, but has no vNIC matching '$WANT'. skipped"
      log "        this VM has: $HAS"
      log "        fix WORKER_VNIC, e.g.  WORKER_VNIC=\"$VM:$(echo $HAS | cut -d' ' -f1)\""
      log "        or leave WORKER_VNIC empty to capture every vNIC."
    else
      log "  $VM - not on this host (or no DFW filter). skipped"
    fi
    continue
  fi
  # A VM with several vNICs has several filters. Capture all of them.
  for F in $FILTERS; do
    NIC=$(filter_nic "$F")
    FOUND=$((FOUND+1))
    O="$OUT/urd-$HOST_TAG-dfw-$STAGE-$VM-$NIC.pcap"
    log "  $VM ($NIC) -> $F  ->  $O"
    # 'echo Y |' answers the interactive confirmation pktcap-uw asks for.
    # Without it an unattended run just hangs.
    echo Y | pktcap-uw --dvfilter "$F" --stage "$STAGE" \
        $PORTOPT $IPOPT $SNAPOPT \
        -G "$SECS" -C "$CAP_FILESIZE" -W "$CAP_FILECOUNT" -o "$O" >/dev/null 2>&1 &
  done
done
[ "$FOUND" -gt 0 ] || die "no target VM on this host. check WORKER_VMS."
log "running in background for ${SECS}s. to wait here: wait"
log "collect:  scp root@$(hostname):$OUT/urd-$HOST_TAG-dfw-$STAGE-*.pcap* ."

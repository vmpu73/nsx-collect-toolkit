# nsx-collect-toolkit

On-box packet capture and state collection for **NSX Edge** and **ESXi**,
for troubleshooting a load-balanced service end to end.

Nothing is installed on the target. The scripts use only what is already on
an NSX Edge (bash, tcpdump, the admin CLI) and on ESXi (busybox sh,
pktcap-uw, vsipioctl), so they can be dropped onto a production box and run.

## Why

When a service behind an NSX load balancer loses traffic, the question is
always *where* it was lost. This collects the same window from four points at
once, so the answer is in the files rather than in a guess:

```
client -> [T0] -> VPC T1 uplink -> LB T1 service IF -> worker VM
                        (1)              (2)            (3) DFW pre
                                                        (4) DFW post
```

A packet present at (2) but absent at (3) was lost by the load balancer.
Present at DFW pre but absent at post means a firewall rule dropped it.

## Quick start

```bash
# on the Edge
tar xzf nsx-collect-toolkit.tgz
cd edge && vi urd-edge.conf        # fill in the placeholders
bash urd-edge.sh                   # menu

# on the ESXi host
cd esxi && vi urd-esxi.conf
sh urd-esxi.sh                     # menu
```

```
+======================================================================+
|  URD  Collection Toolkit                                             |
|  <CASE_ID>   NSX Edge / <edge01>   2026-09-10 09:00:00               |
+======================================================================+
|                                                                      |
|    SETUP                        RUN                                  |
|      1  config                    4  start all                       |
|      2  check                     5  start one                       |
|      3  rehearse   (once)                                            |
|                                                                      |
|    MONITOR                      FINISH                               |
|      6  status                    7  stop            keep files      |
|      w  watch      (auto)         8  stop + delete   remove files    |
|                                                                      |
|      9  help                      q  quit                            |
|                                                                      |
+======================================================================+
```

Every action prints the command it is about to run, so you can see what is
being executed on a production box - and learn the commands.

## Design rules

**It only touches what the config names.** This is a troubleshooting tool,
not an environment assessment. Empty settings are skipped, never expanded to
"everything". One NSX logical router costs about 2.5 s of CLI time and a
production Edge can host hundreds of them.

**Stopping is safe.** The cleanup matches processes by their *output path*,
never by program name, so a capture started by someone else is never killed.
It releases only the span sessions named in the config, validates the output
path before deleting anything, and removes only its own subtrees.

**Pure ASCII, fixed 72 columns.** No box drawing, no colour, no `tput` -
the ESXi console mangles anything above 7 bit and has no `tput`.

**It refuses to fill the box.** ESXi `/tmp` is a ramdisk of about 250 MB -
host memory, not disk. The capture ring buffer budget is checked before the
capture starts, and the polling loops stop themselves at a free-space floor.

## Layout

```
edge/   urd-edge.sh              menu - the only file you need to remember
        urd-edge.conf            edit this
        urd-edge-cap-lbt1-svc.sh      LB T1 service interface capture
        urd-edge-cap-vpct1-uplink.sh  VPC T1 uplink capture
        urd-edge-stats.sh             interface / CPU / memory counters
        urd-edge-sessions.sh          connection and LB session tables
        urd-edge-cleanup.sh           stop and clean up
        urd-edge-lib.sh               shared functions - do not run

esxi/   urd-esxi.sh              menu
        urd-esxi.conf            edit this
        urd-esxi-cap-dfw-pre.sh       capture before the DFW rules
        urd-esxi-cap-dfw-post.sh      capture after the DFW rules
        urd-esxi-stats.sh             NIC and switch port counters
        urd-esxi-dfw-sessions.sh      DFW flows, rules, pass/drop counters
        urd-esxi-cleanup.sh           stop and clean up
        urd-esxi-lib.sh               shared functions - do not run
        _cap-dfw.sh                   shared capture body - do not run
```

`RUNBOOK.md` is the field procedure. `REFERENCE.md` explains what each file
does and why.

## Capture method on the Edge

Rather than the admin CLI `start capture`, which cannot be stopped cleanly
and loses files, this uses a span mirror plus a normal tcpdump:

```
set capture session <N> interface <LIF> direction dual   # admin CLI
  -> creates the Linux interface span-<N>
tcpdump -nei span-<N> -Z root -C <MB> -W <n> -w <file> <filter>
del capture session <N>                                  # admin CLI
```

`-Z root` is required: tcpdump drops privileges and then cannot create the
next file in the ring. A span session created on one Edge also appears on the
other Edge of the cluster, so the cleanup has to run on every Edge.

## Status

Verified end to end on NSX 4.2.4 (VM Edge) and ESXi 8, against a one-arm load
balancer with SNAT and a DFW-protected backend.

## Licence

Internal tooling. No warranty.

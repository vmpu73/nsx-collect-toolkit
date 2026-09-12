# nsx-collector

On-box collection for **NSX Edge** and **ESXi**, for troubleshooting a
load-balanced service end to end.

Two files, one menu, both platforms:

```
nsx-collector.sh      the whole tool - menu and every collector
nsx-collector.conf    the only thing you edit
```

Nothing is installed on the target. It uses what is already on an NSX Edge
(sh, tcpdump, the admin CLI) and on ESXi (busybox sh, pktcap-uw, tcpdump-uw,
vsipioctl), so it can be dropped onto a production box and run.

## Quick start

```bash
tar xzf nsx-collector-<version>.tgz          # BINARY transfer, unpack on the box
vi nsx-collector.conf                        # fill in what that box needs
sh nsx-collector.sh                          # the menu
```

Always start it with `sh nsx-collector.sh`. A hardened ESXi host refuses
`./nsx-collector.sh` with *Operation not permitted* (`execInstalledOnly`:
only files installed from a VIB may be executed directly). Running it
through `sh` is unaffected.

```
+======================================================================+
|  NSX Collector 3.0                                                   |
|  ISCPSR-49099   esxi / esx01   2026-09-12 03:24:13                   |
+======================================================================+
|    SETUP                        RUN                                  |
|      1  config                    5  start all                       |
|      2  selftest                  6  status                          |
|      3  check / VM map            w  watch                           |
|      4  rehearse                                                     |
|    FINISH                                                            |
|      7  stop          keep files   9  help                           |
|      8  stop + delete files        q  quit                           |
|      d  dry run - show what 8 would stop and delete                  |
+======================================================================+
```

Every action prints the command it is about to run, so you can see what is
being executed on a production box - and learn the commands.

## What it collects

| on an NSX Edge | on an ESXi host |
|---|---|
| capture on the LB T1 service interface (span mirror + tcpdump) | DFW capture **before** the rules (pre) |
| capture on the VPC T1 uplink | DFW capture **after** the rules (post) |
| interface / dataplane / CPU / memory counters | switch port and uplink NIC counters |
| per-router interface stats and HA state | DFW flow table, applied rules, pass/drop counters |
| firewall connection tables, LB status / pools / virtual servers | |

A packet present at the Edge but absent at the ESXi pre capture was lost on
the way to the host. Present at pre but absent at post means a DFW rule
dropped it.

## What to capture - two ways

**A free expression** - anything tcpdump understands, with `and`, `or`,
`not` and brackets:

```sh
FILTER="host 10.1.1.10 and (udp port 1812 or udp port 1813)"
FILTER="(host 10.1.1.10 or host 10.1.1.11) and not tcp port 22"
FILTER="net 10.1.1.0/28 and udp"
```

* `host` / `net` may be left out in front of an address - it is put in for
  you. A bare address is a syntax error for tcpdump, and worse,
  `port 80 and 10.1.1.10` parses but matches nothing.
* `and` and `or` have the **same** precedence and are read left to right,
  so `a or b and c` means `(a or b) and c`. Use brackets.
* The expression is syntax-checked before anything starts.
* On ESXi the packets are filtered through `tcpdump-uw`, so a free
  expression gives **one file per vNIC and stage** - no file explosion.

**Or the single fields** - `HOSTS`, `PROTO`, `PORTS` and the per-leg ones.
Each may be empty or hold several values (`PORTS="1812 1813"`). Empty means
that condition is left out; empty everywhere captures every packet.

On ESXi the single fields are turned into `pktcap-uw` options, and
pktcap-uw has no `or` - so every combination of protocol x port x address
becomes its own capture and its own file. Two ports x two addresses x two
VMs x pre/post is 16 files. That is why `FILTER` exists.

## Where the results go

One collection is one directory, and every file name says what it is:

```
<OUT>/run-<tag>-<date>-<time>/
   00-run-info.txt                     what was run, the filter, this legend
   pcap/  10-edge-lbt1svc-<time>.pcap0     Edge, LB T1 service interface
          11-edge-vpct1uplink-<time>.pcap0 Edge, VPC T1 uplink
          20-dfw-pre-<vm>-<nic>.pcap0      ESXi, before the DFW rules
          21-dfw-post-<vm>-<nic>.pcap0     ESXi, after the DFW rules
   state/ 30..39 Edge counters, 40..49 ESXi counters
   session/ 50..59 Edge firewall + LB state, 60..69 ESXi DFW flows/rules
```

Collectors started separately join the run that is already open, so pre and
post captures and the pollers never end up scattered.

## Design rules

**It only touches what the config names.** This is a troubleshooting tool,
not an environment assessment. Empty settings are skipped, never expanded to
"everything". One NSX logical router costs about 2.5 s of CLI time and a
production Edge can host hundreds of them.

**Stopping is safe.** Only processes started by this script, or writing into
its own run directory, are ever signalled - there is no `killall` in the
file. A span session is released only when it mirrors a LIF from *this*
config; one somebody else created is reported and left alone. Captures get
SIGINT first so the pcap closes cleanly. Files are deleted only from
directories holding our own `00-run-info.txt`, and never while a collector is
still running. `stop --dry-run` shows every decision and changes nothing.

**Pure ASCII, fixed 72 columns.** No box drawing, no colour, no `tput` -
the ESXi console mangles anything above 7 bit and has no `tput`.

**It refuses to fill the box.** ESXi `/tmp` is a ramdisk of about 250 MB -
host memory, not disk. The ring buffer budget is checked before the capture
starts and shrunk to fit, and the polling loops stop at a free-space floor.

**POSIX sh, one file.** The same file runs on the ESXi busybox shell and on
the Edge. No bash syntax, no python, nothing to install - and one file is
one thing to transfer, which is how it broke in the field before.

## If it will not start

| message | cause |
|---|---|
| `line 1: syntax error` / `line 1: xi.sh: not found` | the file arrived with CR line endings (a messenger or a Windows editor). Transfer the .tgz in **binary** and unpack on the box. nsx-collector.sh checks itself and says so. |
| `Operation not permitted` | you ran `./nsx-collector.sh` on a hardened ESXi. Use `sh nsx-collector.sh`. |
| `can't open 'nsx-collector.sh'` | wrong directory - `cd` to where you unpacked it. |
| `REQUIRED setting is empty` | Edge: no `LIF_*`; ESXi: no `WORKER_VMS`. Everything else may stay empty. |

## Status

Verified end to end on NSX 4.2.4 (VM Edge) and ESXi 8.0.3, against a one-arm
load balancer with SNAT and a DFW-protected backend: empty config, several
values per field, and free `FILTER` expressions, plus the stop/dry-run/wipe
path with a foreign span session present.

## Licence

Internal tooling. No warranty.

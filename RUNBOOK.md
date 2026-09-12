# RUNBOOK - collecting on site

The order below is what a maintenance window looks like. Everything is
read-only apart from the capture mirror on the Edge, which is given back at
the end.

---

## 0. Before the window

**Decide where you collect.** A load-balanced service is normally three
points: the Edge that is *Active* for the T1, and the ESXi host(s) where the
backend VMs run. Run the tool on each of them - one file, same menu.

**Get the files onto the box.** Transfer the `.tgz` in **binary** mode and
unpack it there:

```
scp nsx-collector-<version>.tgz root@<box>:/tmp/
ssh root@<box>
cd /tmp && tar xzf nsx-collector-<version>.tgz
```

Never paste the script through a messenger or a Windows editor. It arrives
with CR line endings and every error then says `line 1` and nothing works.
The script checks itself for this and tells you how to fix it.

**Where to put it**

| box | directory | why |
|---|---|---|
| NSX Edge | `/root/nsxc` (results default to `/var/dump/nsx-collect`) | `/var/dump` has the space |
| ESXi | `/tmp/nsxc` (results default to `/tmp/nsx-collect`) | `/tmp` is a ~250 MB ramdisk - see step 3 |

---

## 1. Fill in the config

**The quick way:** `python3 nsx-collector.py discover` reads the box, offers
what it found (load balancers, virtual servers, T1s / VMs and uplinks), and
writes your answers into the config - comments kept, original backed up as
`nsx-collector.conf.bak`.

By hand, only one thing per box is mandatory.

```
NSX Edge   LIF_LBT1_SVC and/or LIF_VPCT1_UPLINK     the interface to capture on
ESXi       WORKER_VMS                               the VM names
```

Find them:

```
# Edge
su admin -c "get logical-routers"                      -> the SR UUID
su admin -c "get logical-router <SR-UUID> interfaces"  -> Port-type: service / uplink

# ESXi
vim-cmd vmsvc/getallvms                                -> the VM names
```

Then decide what to capture. Either a free expression:

```
FILTER="host 10.1.1.10 and (udp port 1812 or udp port 1813)"
```

or the single fields (`HOSTS`, `PROTO`, `PORTS`, `VIP`, `SVC_PORT`,
`LB_SNAT_IP`, `NODE_PORT`). Any of them may be empty or hold several values.
Empty everywhere captures every packet on the interface.

Set the window size while you are there:

```
CAP_SECS=600        how long the capture runs
DURATION=1200       how long the state/session polling runs
INTERVAL=30         seconds between state samples
```

---

## 2. Check before you commit

```
python3 nsx-collector.py discover     # fill the config in from the box itself
python3 nsx-collector.py selftest     # tools, root, filter syntax, disk, targets
python3 nsx-collector.py check        # Edge: which node is Active / ESXi: VM map
python3 nsx-collector.py rehearse     # one sample of everything except the capture
python3 nsx-collector.py wipe         # clear the rehearsal
```

**On an Edge, `check` is the one that matters.** A T1 service router is
Active on one node only, and a capture on the Standby node returns zero
packets. The top `state` line is this node; the `Peer Routers` block at the
bottom describes the *other* one - reading that gets it backwards.

---

## 3. Watch the space, especially on ESXi

`/tmp` on ESXi is a ramdisk of about 250 MB - host memory, not disk. Filling
it is a host problem, not a file problem.

* The ring buffer budget is `CAP_FILESIZE x CAP_FILECOUNT x number of
  captures`. It is checked before the capture starts and lowered to fit,
  with a note on screen.
* For a long window put the results on a datastore instead:

```
OUT="/vmfs/volumes/<datastore>/nsx-collect"
```

* A free `FILTER` gives one capture per vNIC and stage. The single fields
  give one capture per combination, which multiplies quickly.

On an Edge `/var/dump` is large (50 GB+ in the lab), so the default ring of
100 MB x 5 is fine there.

---

## 4. Collect

```
python3 nsx-collector.py start        # everything, in the background
python3 nsx-collector.py status       # what is running, how long is left
python3 nsx-collector.py watch        # the same, refreshed
```

Captures end by themselves after `CAP_SECS`, the pollers after `DURATION`.
Nothing has to be stopped by hand if you let them finish.

Reproduce the problem inside that window. If the problem is intermittent,
make `DURATION` longer than `CAP_SECS` so there is state from before and
after the capture.

---

## 5. Stop and check that nothing is left

```
python3 nsx-collector.py stop --dry-run   # shows every decision, changes nothing
python3 nsx-collector.py stop             # stop, keep the files
```

`stop` prints what it is signalling and ends with an AFTER block. It exits
non-zero if anything of ours survived, so it can be checked from a script.

What it will and will not do on a production box:

* only processes started by this script, or writing into its own run
  directory, are signalled. There is no `killall` in the file.
* a span session is released **only** when it mirrors a LIF from this
  config. One somebody else created is reported and left alone.
* captures get SIGINT first, so the pcap file is closed cleanly.
* files are deleted only from directories holding our `00-run-info.txt`,
  and never while a collector is still running.

**A span session created on one Edge also exists on the other node of the
cluster.** Run `stop` on both Edges, or a mirror keeps running over there.

---

## 6. Take the results off the box

```
scp -r root@<box>:/var/dump/nsx-collect/run-<tag>-<date>-<time> .     # Edge
scp -r root@<box>:/tmp/nsx-collect/run-<tag>-<date>-<time> .         # ESXi
```

Read `00-run-info.txt` first - it holds the filter that was used and what
every file name means.

Then remove the data from the box when you no longer need it:

```
python3 nsx-collector.py wipe
```

---

## 7. Reading the captures

```
tcpdump -nr 10-edge-lbt1svc-033306.pcap0 | head
```

**Part of an Edge capture is 802.1Q tagged** - mostly the return direction.
The capture filter runs in the kernel and sees through the tag, but a filter
you apply when *reading* the file does not, and silently drops those packets.
Measured in the lab: 930 packets, 367 of them tagged.

```
tcpdump -nr <file> '(host 10.1.1.10) or (vlan and (host 10.1.1.10))'
```

Without an expression everything is shown, tagged or not.

Files named `*.pcap0`, `*.pcap1` ... are the ring buffer. Only `.pcap0` means
nothing rotated and the whole window is there. Three or more files means the
beginning was probably overwritten - raise `CAP_FILESIZE` or shorten
`CAP_SECS` next time.

---

## Quick reference

```
python3 nsx-collector.py                 menu
python3 nsx-collector.py config          what the config says, and the filter it makes
python3 nsx-collector.py selftest        everything that has to be right
python3 nsx-collector.py check           Edge: Active node   ESXi: VM map
python3 nsx-collector.py map             ESXi: VM <-> DFW filter <-> switch port
python3 nsx-collector.py rehearse        one sample, no capture
python3 nsx-collector.py start           start everything
python3 nsx-collector.py status          progress
python3 nsx-collector.py watch [secs]    progress, refreshed
python3 nsx-collector.py stop            stop, keep files
python3 nsx-collector.py wipe            stop and delete our files
python3 nsx-collector.py stop --dry-run  show the decisions only
python3 nsx-collector.py help            what it collects and why
```

One collector on its own, if you prefer:

```
python3 nsx-collector.py cap-lbt1 [secs]     Edge, LB T1 service interface
python3 nsx-collector.py cap-vpct1 [secs]    Edge, VPC T1 uplink
python3 nsx-collector.py cap-pre [secs]      ESXi, before the DFW rules
python3 nsx-collector.py cap-post [secs]     ESXi, after the DFW rules
python3 nsx-collector.py stats-once|stats-run
python3 nsx-collector.py sess-once|sess-run  Edge
python3 nsx-collector.py dfw-once|dfw-run    ESXi
```

The captures return to the prompt in a couple of seconds and keep running in
the background; `*-run` holds the terminal for `DURATION`.

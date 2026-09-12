#!/usr/bin/env python3
# ===========================================================================
#  nsx-analyzer.py - read back what nsx-collector collected and say what
#                    it means: packets, state counters and session tables.
#
#      python3 nsx-analyzer.py                  the menu
#      python3 nsx-analyzer.py <action> [...]   one action, no menu
#      python3 nsx-analyzer.py help             what it can tell you
#
#  It analyses a RUN DIRECTORY (<OUT>/run-<tag>-<date>-<time>/) produced by
#  nsx-collector. It runs wherever python3 does - on the Edge, on the ESXi
#  host, or on your own machine after "scp -r" - and needs nothing but the
#  standard library. It never writes into the box it is reading from, apart
#  from the report file you ask for.
#
#  The collector collects. This analyses. Nothing here touches the live box.
# ===========================================================================
import os
import re
import sys
import time

VERSION = "6.0"
UIW = 70

# Where runs usually are, in the order they are looked for.
RUN_ROOTS = ["/var/dump/nsx-collect", "/tmp/nsx-collect", os.getcwd()]
IS_ESXI = os.uname().sysname == "VMkernel" if hasattr(os, "uname") else False


# --- screen ----------------------------------------------------------------
def rule():
    print("+" + "=" * UIW + "+")


def row(text=""):
    print("|" + text[:UIW].ljust(UIW) + "|")


def band(title):
    rule()
    row("  " + title)
    rule()


def thin():
    print("  " + "-" * (UIW - 2))


def ask(prompt, default=""):
    try:
        answer = input(prompt).strip()
    except EOFError:
        return default
    return answer or default


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


OUT = ""          # the run root in use - set once a run is picked
RUN = ""          # the run directory in use
ASKED_ROOT = ""   # what --run pointed at, so "runs" lists the right place


def find_runs(root=None):
    """Every run directory under the given root, or under the usual places."""
    roots = [root] if root else ([ASKED_ROOT] if ASKED_ROOT else RUN_ROOTS)
    found = []
    for base in roots:
        if not base or not os.path.isdir(base):
            continue
        # the root itself may BE a run directory
        if os.path.exists(os.path.join(base, "00-run-info.txt")):
            found.append(os.path.abspath(base))
            continue
        for name in sorted(os.listdir(base)):
            path = os.path.join(base, name)
            if name.startswith("run-") and os.path.isdir(path):
                found.append(os.path.abspath(path))
    return found


def latest_run():
    runs = find_runs()
    return runs[-1] if runs else None


def use_run(path):
    global RUN, OUT
    RUN = os.path.abspath(path)
    OUT = os.path.dirname(RUN)
    return RUN


def run_files(sub):
    d = os.path.join(RUN, sub)
    if not os.path.isdir(d):
        return []
    return [os.path.join(d, n) for n in sorted(os.listdir(d))]


# ===========================================================================
#  SAMPLED TEXT FILES
#
#  The collector appends one block per sample:
#      ########## 2026-09-12 07:18:56 ##########
#      ### get load-balancer <uuid> status
#      <output>
#  so a file is a little time series. Everything below works on that.
#  A file with no block header (a one-shot dump) counts as a single sample.
# ===========================================================================
SAMPLE_RE = re.compile(r"^#{10}\s+(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\s+#{10}\s*$")


def samples(path):
    """[(timestamp string, [lines])] - oldest first."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return []
    out, stamp, body = [], None, []
    for line in lines:
        m = SAMPLE_RE.match(line)
        if m:
            if stamp is not None or body:
                out.append((stamp, body))
            stamp, body = m.group(1), []
            continue
        if line.startswith("### "):
            continue
        body.append(line)
    if stamp is not None or body:
        out.append((stamp, body))
    return [(s or "(no timestamp)", b) for s, b in out if any(l.strip() for l in b)]


def failed_command(path):
    """The collector stores whatever the CLI said - including a refusal.
    Saying "this file is an error message" beats analysing the error text."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            head = fh.read(4000)
    except OSError:
        return ""
    m = re.search(r"^%\s*(Command not found|Invalid value.*)$", head, re.M)
    return m.group(0).strip() if m else ""


def hhmm(stamp):
    return stamp.split(" ")[-1] if " " in stamp else stamp


def num(text):
    try:
        return int(text)
    except (TypeError, ValueError):
        return None


def delta_table(rows, title, unit="", width=13):
    """rows: [(name, [(stamp, value)])] - prints value and change per sample."""
    if not rows:
        return
    print("   %s" % title)
    for name, series in rows:
        series = [(s, v) for s, v in series if v is not None]
        if not series:
            continue
        first, last = series[0][1], series[-1][1]
        change = last - first
        line = "   %-*s %12d" % (width, name[:width], last)
        if len(series) > 1:
            line += "   %+d over %d sample(s)" % (change, len(series))
        if unit:
            line += " " + unit
        print(line)


def parse_kv_counters(lines, keys):
    """Pull "  RX packets: 123" style counters out of a block."""
    found = {}
    for line in lines:
        m = re.match(r"\s*([A-Za-z][\w /()-]*?)\s*[:=]\s*(-?\d+)\s*$", line)
        if not m:
            continue
        name = m.group(1).strip()
        if keys is None or any(k.lower() in name.lower() for k in keys):
            found[name] = int(m.group(2))
    return found


# ===========================================================================
#  READING THE CAPTURES BACK - find one flow and say what happened to it
#
#  The pcap files are parsed here rather than shelled out to tcpdump, for one
#  reason that bit us in the field: part of an Edge capture is 802.1Q tagged
#  (measured: 367 of 930 packets), and a filter handed to tcpdump when READING
#  a file silently drops those - you need "(expr) or (vlan and (expr))" every
#  single time. This parser looks through the tag, so a flow cannot hide.
#
#  Supported: pcap (both byte orders, also the nanosecond variant), Ethernet,
#  802.1Q / QinQ, IPv4, TCP / UDP / ICMP. Anything else is counted as "other".
# ===========================================================================
PROTO_NAME = {1: "icmp", 6: "tcp", 17: "udp"}
TCP_FLAGS = [(0x01, "F"), (0x02, "S"), (0x04, "R"), (0x08, "P"),
             (0x10, "A"), (0x20, "U"), (0x40, "E"), (0x80, "C")]


def _u16(b, i):
    return (b[i] << 8) | b[i + 1]


def _u32(b, i):
    return (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]


def _ip(b, i):
    return "%d.%d.%d.%d" % (b[i], b[i + 1], b[i + 2], b[i + 3])


def pcap_packets(path):
    """Yield one dict per packet, from a classic pcap OR a pcapng file.

    Both are needed on the same box: tcpdump and tcpdump-uw write classic
    pcap, while pktcap-uw writes pcapng (its files start with 0a 0d 0d 0a).
    Never raises on a truncated file - a capture that was killed mid-write
    still gets read up to the last whole packet.
    """
    try:
        fh = open(path, "rb")
    except OSError:
        return
    with fh:
        head = fh.read(24)
        if len(head) < 24:
            return
        magic = head[:4]
        if magic == b"\x0a\x0d\x0d\x0a":
            fh.seek(0)
            for pkt in _pcapng_packets(fh):
                yield pkt
            return
        if magic == b"\xd4\xc3\xb2\xa1":
            endian, scale = "<", 1e-6
        elif magic == b"\xa1\xb2\xc3\xd4":
            endian, scale = ">", 1e-6
        elif magic == b"\x4d\x3c\xb2\xa1":
            endian, scale = "<", 1e-9
        elif magic == b"\xa1\xb2\x3c\x4d":
            endian, scale = ">", 1e-9
        else:
            return
        import struct
        rec = struct.Struct(endian + "IIII")
        linktype = struct.unpack(endian + "I", head[20:24])[0]
        while True:
            hdr = fh.read(16)
            if len(hdr) < 16:
                return
            sec, usec, caplen, wirelen = rec.unpack(hdr)
            if caplen > 262144:
                return
            data = fh.read(caplen)
            if len(data) < caplen:
                return
            pkt = {"t": sec + usec * scale, "len": wirelen, "vlan": None}
            if linktype != 1:          # only Ethernet is decoded
                pkt["proto"] = "other"
                yield pkt
                continue
            _decode_eth(data, pkt)
            yield pkt


def _pcapng_packets(fh):
    """pcapng: section header -> interface descriptions -> packet blocks.
    Only what pktcap-uw writes is needed: SHB, IDB, EPB and simple packets."""
    import struct
    endian = "<"
    tsresol, linktype = 1e-6, 1
    while True:
        head = fh.read(8)
        if len(head) < 8:
            return
        btype = struct.unpack(endian + "I", head[:4])[0]
        blen = struct.unpack(endian + "I", head[4:8])[0]
        if btype == 0x0A0D0D0A:                       # section header
            body = fh.read(4)
            if len(body) < 4:
                return
            if body == b"\x4d\x3c\x2b\x1a":
                endian = "<"
            elif body == b"\x1a\x2b\x3c\x4d":
                endian = ">"
            blen = struct.unpack(endian + "I", head[4:8])[0]
            rest = fh.read(max(0, blen - 16))
            if len(rest) < max(0, blen - 16):
                return
            fh.read(4)
            continue
        if blen < 12 or blen > 20 * 1024 * 1024:
            return
        body = fh.read(blen - 12)
        if len(body) < blen - 12:
            return
        fh.read(4)                                    # trailing length
        if btype == 0x00000001 and len(body) >= 8:    # interface description
            linktype = struct.unpack(endian + "H", body[0:2])[0]
            opt = 8
            while opt + 4 <= len(body):               # look for if_tsresol
                code, olen = struct.unpack(endian + "HH", body[opt:opt + 4])
                val = body[opt + 4:opt + 4 + olen]
                if code == 0 :
                    break
                if code == 9 and olen >= 1:
                    raw = val[0]
                    tsresol = (2.0 ** -(raw & 0x7f)) if raw & 0x80 else (10.0 ** -raw)
                opt += 4 + ((olen + 3) // 4) * 4
        elif btype == 0x00000006 and len(body) >= 20:  # enhanced packet
            _iface, tsh, tsl, caplen, wirelen = struct.unpack(endian + "IIIII", body[:20])
            data = body[20:20 + caplen]
            pkt = {"t": ((tsh << 32) | tsl) * tsresol, "len": wirelen, "vlan": None}
            if linktype == 1:
                _decode_eth(data, pkt)
            else:
                pkt["proto"] = "other"
            yield pkt
        elif btype == 0x00000003 and len(body) >= 4:   # simple packet
            wirelen = struct.unpack(endian + "I", body[:4])[0]
            data = body[4:]
            pkt = {"t": 0.0, "len": wirelen, "vlan": None}
            if linktype == 1:
                _decode_eth(data, pkt)
            else:
                pkt["proto"] = "other"
            yield pkt


def _decode_eth(data, pkt):
    if len(data) < 14:
        pkt["proto"] = "other"
        return
    off = 12
    etype = _u16(data, off)
    while etype in (0x8100, 0x88a8, 0x9100) and len(data) >= off + 8:
        pkt["vlan"] = _u16(data, off + 2) & 0x0fff
        off += 4
        etype = _u16(data, off)
    off += 2
    if etype != 0x0800 or len(data) < off + 20:
        pkt["proto"] = "arp" if etype == 0x0806 else "other"
        return
    ihl = (data[off] & 0x0f) * 4
    if ihl < 20 or len(data) < off + ihl:
        pkt["proto"] = "other"
        return
    pkt["src"] = _ip(data, off + 12)
    pkt["dst"] = _ip(data, off + 16)
    pkt["ttl"] = data[off + 8]
    pkt["ipid"] = _u16(data, off + 4)
    frag = _u16(data, off + 6)
    pkt["frag"] = bool(frag & 0x1fff) or bool(frag & 0x2000)
    ipproto = data[off + 9]
    pkt["proto"] = PROTO_NAME.get(ipproto, "ip%d" % ipproto)
    iplen = _u16(data, off + 2)
    l4 = off + ihl
    if pkt["proto"] == "tcp" and len(data) >= l4 + 20:
        pkt["sport"] = _u16(data, l4)
        pkt["dport"] = _u16(data, l4 + 2)
        pkt["seq"] = _u32(data, l4 + 4)
        pkt["ack"] = _u32(data, l4 + 8)
        doff = (data[l4 + 12] >> 4) * 4
        bits = data[l4 + 13]
        pkt["flags"] = "".join(ch for bit, ch in TCP_FLAGS if bits & bit) or "."
        pkt["win"] = _u16(data, l4 + 14)
        pkt["plen"] = max(0, iplen - ihl - doff)
    elif pkt["proto"] == "udp" and len(data) >= l4 + 8:
        pkt["sport"] = _u16(data, l4)
        pkt["dport"] = _u16(data, l4 + 2)
        pkt["plen"] = max(0, _u16(data, l4 + 4) - 8)
        # RADIUS: code and identifier are the first two bytes of the payload
        if len(data) >= l4 + 10:
            pkt["l7code"] = data[l4 + 8]
            pkt["l7id"] = data[l4 + 9]
    elif pkt["proto"] == "icmp" and len(data) >= l4 + 4:
        pkt["icmp_type"] = data[l4]
        pkt["icmp_code"] = data[l4 + 1]
        pkt["plen"] = max(0, iplen - ihl - 8)


ICMP_TEXT = {0: "echo reply", 3: "unreachable", 4: "source quench",
             5: "redirect", 8: "echo request", 11: "time exceeded"}
ICMP_UNREACH = {0: "net", 1: "host", 2: "protocol", 3: "port",
                4: "fragmentation needed (MTU!)", 9: "net admin prohibited",
                10: "host admin prohibited", 13: "administratively filtered"}
RADIUS_CODE = {1: "Access-Request", 2: "Access-Accept", 3: "Access-Reject",
               4: "Accounting-Request", 5: "Accounting-Response",
               11: "Access-Challenge"}


class Tuple5(object):
    """The 5-tuple to look for. Every field is optional - what you leave out
    matches anything, and the flow is matched in BOTH directions."""

    def __init__(self, src="", dst="", sport="", dport="", proto=""):
        self.src, self.dst = src.strip(), dst.strip()
        self.sport, self.dport = str(sport).strip(), str(dport).strip()
        self.proto = proto.strip().lower()

    def __str__(self):
        parts = []
        if self.src or self.sport:
            parts.append("%s:%s" % (self.src or "*", self.sport or "*"))
        if self.dst or self.dport:
            parts.append("%s:%s" % (self.dst or "*", self.dport or "*"))
        return "%s %s" % (self.proto or "any", " <-> ".join(parts) or "any address")

    def empty(self):
        return not (self.src or self.dst or self.sport or self.dport or self.proto)

    def match(self, pkt):
        """Returns 0 no match, 1 matches as given (forward), 2 matches with the
        addresses swapped (the reply direction)."""
        if self.proto and pkt.get("proto") != self.proto:
            return 0
        if "src" not in pkt:
            return 0
        fwd = ((not self.src or pkt["src"] == self.src) and
               (not self.dst or pkt["dst"] == self.dst) and
               (not self.sport or str(pkt.get("sport", "")) == self.sport) and
               (not self.dport or str(pkt.get("dport", "")) == self.dport))
        if fwd:
            return 1
        rev = ((not self.src or pkt["dst"] == self.src) and
               (not self.dst or pkt["src"] == self.dst) and
               (not self.sport or str(pkt.get("dport", "")) == self.sport) and
               (not self.dport or str(pkt.get("sport", "")) == self.dport))
        return 2 if rev else 0

    def match_loose(self, pkt):
        """Every address and port given must appear SOMEWHERE in the packet,
        on either side - this is what "host X and port 80" does in tcpdump.
        Used only when the strict 5-tuple finds nothing: a load balancer
        talks to its backend from a random source port, so "the .2 address
        and port 80" is a real question even though it is not a 5-tuple.
        """
        if self.proto and pkt.get("proto") != self.proto:
            return 0
        if "src" not in pkt:
            return 0
        ends = (pkt["src"], pkt["dst"])
        ports = (str(pkt.get("sport", "")), str(pkt.get("dport", "")))
        for addr in (self.src, self.dst):
            if addr and addr not in ends:
                return 0
        for port in (self.sport, self.dport):
            if port and port not in ports:
                return 0
        return 1 if (not self.dst or pkt["dst"] == self.dst) else 2


def pcap_points(run):
    """The capture points of a run directory, in reading order:
    [(label, [files...])] - a ring buffer (.pcap0, .pcap1) is one point."""
    pcap_dir = os.path.join(run, "pcap")
    if not os.path.isdir(pcap_dir):
        return []
    groups = {}
    for name in sorted(os.listdir(pcap_dir)):
        m = re.match(r"(.*\.pcap)\d*$", name)
        if not m:
            continue
        groups.setdefault(m.group(1), []).append(os.path.join(pcap_dir, name))
    out = []
    for base in sorted(groups):
        label = re.sub(r"\.pcap$", "", os.path.basename(base))
        out.append((label, sorted(groups[base])))
    return out


def point_meaning(label):
    if label.startswith("10-edge-lbt1svc"):
        return "Edge, LB T1 service interface (client <-> VIP and LB <-> backend)"
    if label.startswith("11-edge-vpct1uplink"):
        return "Edge, VPC T1 uplink (before NAT / before the LB)"
    if label.startswith("20-dfw-pre"):
        return "ESXi, vNIC BEFORE the DFW rules"
    if label.startswith("21-dfw-post"):
        return "ESXi, vNIC AFTER the DFW rules (this is what the guest sees)"
    return "capture point"


def analyse_flow(packets, want):
    """Everything we can say about one flow at one capture point."""
    fwd = [p for p in packets if p["_dir"] == 1]
    rev = [p for p in packets if p["_dir"] == 2]
    info = {
        "n": len(packets), "fwd": len(fwd), "rev": len(rev),
        "bytes_fwd": sum(p["len"] for p in fwd),
        "bytes_rev": sum(p["len"] for p in rev),
        "first": packets[0]["t"], "last": packets[-1]["t"],
        "vlan": sorted(set(p["vlan"] for p in packets if p.get("vlan") is not None)),
        "tuples": [], "notes": [], "proto": packets[0].get("proto", "?"),
    }
    seen = {}
    for p in packets:
        key = (p.get("proto"), p.get("src"), p.get("sport"), p.get("dst"), p.get("dport"))
        seen[key] = seen.get(key, 0) + 1
    info["tuples"] = sorted(seen.items(), key=lambda kv: -kv[1])

    proto = info["proto"]
    if proto == "tcp":
        syn = [p for p in fwd if "S" in p["flags"] and "A" not in p["flags"]]
        synack = [p for p in rev if "S" in p["flags"] and "A" in p["flags"]]
        rst = [p for p in packets if "R" in p["flags"]]
        fin = [p for p in packets if "F" in p["flags"]]
        data_fwd = sum(p.get("plen", 0) for p in fwd)
        data_rev = sum(p.get("plen", 0) for p in rev)
        seqs = {}
        retrans = 0
        for p in fwd + rev:
            key = (p["_dir"], p["seq"], p.get("plen", 0))
            if p.get("plen", 0) > 0 or "S" in p["flags"]:
                seqs[key] = seqs.get(key, 0) + 1
                if seqs[key] > 1:
                    retrans += 1
        info["notes"].append("TCP: %d SYN, %d SYN-ACK, %d RST, %d FIN, payload %d B out / %d B back"
                             % (len(syn), len(synack), len(rst), len(fin), data_fwd, data_rev))
        if syn and not synack:
            info["notes"].append("  -> the handshake was never answered HERE"
                                 " (SYN %d time(s), no SYN-ACK)" % len(syn))
        if syn and synack:
            rtt = (synack[0]["t"] - syn[0]["t"]) * 1000
            info["notes"].append("  -> handshake completed, SYN to SYN-ACK %.1f ms" % rtt)
        if retrans:
            info["notes"].append("  -> %d retransmission(s) - something was lost or slow" % retrans)
        if rst:
            who = "the client side" if rst[0]["_dir"] == 1 else "the server side"
            info["notes"].append("  -> reset by %s at %s"
                                 % (who, time.strftime("%H:%M:%S", time.localtime(rst[0]["t"]))))
        zero = [p for p in packets if p.get("win") == 0 and "R" not in p["flags"]]
        if zero:
            info["notes"].append("  -> %d zero-window packet(s) - a receiver stopped reading" % len(zero))
    elif proto == "udp":
        pairs, rtts = 0, []
        pending = []
        for p in packets:
            if p["_dir"] == 1:
                pending.append(p)
            elif pending:
                req = pending.pop(0)
                pairs += 1
                rtts.append(p["t"] - req["t"])
        info["notes"].append("UDP: %d out, %d back" % (len(fwd), len(rev)))
        if fwd and not rev:
            info["notes"].append("  -> nothing came back HERE. The request left, the answer did not.")
        if rtts:
            rtts.sort()
            mid = rtts[len(rtts) // 2]
            info["notes"].append("  -> answer time: median %.3f s, max %.3f s over %d pair(s)"
                                 % (mid, rtts[-1], len(rtts)))
            if mid > 5:
                info["notes"].append("  -> that is far too slow for a request/response service."
                                     " A stateful firewall usually drops the session after"
                                     " 30 s, so a late answer never reaches the client.")
        codes = {}
        for p in packets:
            if "l7code" in p:
                codes[p["l7code"]] = codes.get(p["l7code"], 0) + 1
        radius = [c for c in codes if c in RADIUS_CODE]
        if radius and (str(want.dport) in ("1812", "1813") or str(want.sport) in ("1812", "1813")):
            info["notes"].append("  -> looks like RADIUS: " + ", ".join(
                "%s x%d" % (RADIUS_CODE[c], codes[c]) for c in sorted(radius)))
    elif proto == "icmp":
        types = {}
        for p in packets:
            key = (p.get("icmp_type"), p.get("icmp_code"))
            types[key] = types.get(key, 0) + 1
        for (t, c), n in sorted(types.items()):
            text = ICMP_TEXT.get(t, "type %s" % t)
            if t == 3:
                text += " / " + ICMP_UNREACH.get(c, "code %s" % c)
            info["notes"].append("ICMP: %s x%d" % (text, n))
        if any(t == 3 and c == 4 for (t, c) in types):
            info["notes"].append("  -> 'fragmentation needed' means an MTU problem on the path")
    if info["vlan"]:
        info["notes"].append("802.1Q tagged packets are part of this flow (vlan %s)."
                             " A filter given to tcpdump while READING a file would drop"
                             " them - this analysis does not." %
                             ",".join(str(v) for v in info["vlan"]))
    if any(p.get("frag") for p in packets):
        info["notes"].append("  -> fragmented IP packets are present")
    return info


def action_analyse(want, run=None, files=None, limit=12):
    """Find a flow in what was captured and say what is happening to it."""
    band("FLOW ANALYSIS   %s" % want)
    if want.empty():
        print("   Give at least one of src / dst / sport / dport / proto.")
        print("   python3 nsx-collector.py analyze --dst 10.1.1.10 --dport 1812 --proto udp")
        return 1
    if files:
        points = [(os.path.basename(f), [f]) for f in files]
    else:
        run = run or latest_run()
        if not run:
            print("   no capture found in %s - run a capture first." % OUT)
            return 1
        print("   run directory: %s" % run)
        points = pcap_points(run)
    if not points:
        print("   no pcap files there yet.")
        return 1

    def scan(loose):
        out = []
        for label, paths in points:
            hits, total = [], 0
            for path in paths:
                for pkt in pcap_packets(path):
                    total += 1
                    direction = pkt and (want.match_loose(pkt) if loose else want.match(pkt))
                    if direction:
                        pkt["_dir"] = direction
                        hits.append(pkt)
            hits.sort(key=lambda p: p["t"])
            out.append((label, paths, total, hits))
        return out

    results = scan(False)
    if not any(hits for _l, _p, _t, hits in results):
        loose = scan(True)
        if any(hits for _l, _p, _t, hits in loose):
            print()
            print("   Nothing matches that exact 5-tuple, but the addresses and")
            print("   ports you gave DO appear together - just not paired that way.")
            print("   A load balancer, for example, reaches its backend from a")
            print("   random source port, so \"the .2 address AND port 80\" exists")
            print("   while \".2:80\" never does. Showing those packets instead")
            print("   (same as tcpdump \"host ... and port ...\").")
            results = loose

    for label, paths, total, hits in results:
        print()
        thin()
        print("   %s" % label)
        print("   %s" % point_meaning(label))
        print("   file(s): %s" % ", ".join(os.path.basename(p) for p in paths))
        if not hits:
            print("   NOT FOUND here  (%d packet(s) in the file)" % total)
            continue
        info = analyse_flow(hits, want)
        print("   %d packet(s) of this flow out of %d in the file" % (info["n"], total))
        print("   %s -> %s and back: %d / %d packets, %d / %d bytes"
              % (want.src or "*", want.dst or "*", info["fwd"], info["rev"],
                 info["bytes_fwd"], info["bytes_rev"]))
        print("   first %s   last %s   window %.3f s"
              % (time.strftime("%H:%M:%S", time.localtime(info["first"])),
                 time.strftime("%H:%M:%S", time.localtime(info["last"])),
                 info["last"] - info["first"]))
        if len(info["tuples"]) > 1:
            print("   addresses seen (this is where you see NAT):")
            for (proto, src, sport, dst, dport), n in info["tuples"][:6]:
                print("     %-4s %s:%s -> %s:%s   x%d"
                      % (proto, src, sport, dst, dport, n))
        for note in info["notes"]:
            print("   " + note)
        print("   first %d packet(s):" % min(limit, len(hits)))
        for pkt in hits[:limit]:
            print("     " + one_line(pkt))
        if len(hits) > limit:
            print("     ... %d more" % (len(hits) - limit))

    # ---- what the points together say -----------------------------------
    found = [(label, hits) for label, _p, _t, hits in results if hits]
    print()
    band("WHAT THE POINTS TOGETHER SAY")
    if not found:
        print("   This flow is in none of the captures.")
        print("   Either it did not happen inside the window, or the capture")
        print("   filter did not include it - check 00-run-info.txt for the")
        print("   filter that was used.")
        return 0
    print("   %-34s %8s %8s %8s" % ("point", "packets", "out", "back"))
    for label, _paths, _total, hits in results:
        if hits:
            info = analyse_flow(hits, want)
            print("   %-34s %8d %8d %8d" % (label[:34], info["n"], info["fwd"], info["rev"]))
        else:
            print("   %-34s %8s" % (label[:34], "-"))
    print()
    for label, hits in found:
        info = analyse_flow(hits, want)
        if info["fwd"] and not info["rev"]:
            print("   %s: requests only, no answer." % label)

    # pre and post are only comparable for the SAME vNIC: a flow to web01 is
    # not supposed to be in web02's capture, and calling that a DFW drop
    # would be wrong (it was, until the lab showed it).
    counts = {}
    for label, _paths, _total, hits in results:
        m = re.match(r"2[01]-dfw-(pre|post)-(.*)$", label)
        if m:
            counts.setdefault(m.group(2), {})[m.group(1)] = len(hits)
    for nic, side in sorted(counts.items()):
        pre_n, post_n = side.get("pre"), side.get("post")
        if pre_n is None or post_n is None:
            continue
        if pre_n and not post_n:
            print("   %s: seen BEFORE the DFW rules but not AFTER - the" % nic)
            print("   distributed firewall dropped this flow. Check")
            print("   session/62-dfw-rules-%s.txt and the counters in" % nic)
            print("   session/63-dfw-passdrop-%s.txt." % nic)
        elif pre_n and post_n < pre_n:
            print("   %s: %d packet(s) before the DFW, %d after - part of the flow"
                  % (nic, pre_n, post_n))
            print("   was dropped by a rule, not all of it.")
        elif pre_n and post_n >= pre_n:
            print("   %s: the DFW passed this flow (%d before, %d after)."
                  % (nic, pre_n, post_n))
    edge_seen = any(l.startswith("1") for l, _h in found)
    host_pre = [n for n, s in counts.items() if s.get("pre")]
    if edge_seen and counts and not host_pre:
        print("   Seen on the Edge but at no host vNIC here: it was lost between")
        print("   the Edge and this host - or the VM runs on another host.")
    print()
    print("   The same thing by hand, if you want to check it:")
    print("     %s -nr <file> '%s'" % ("tcpdump-uw" if IS_ESXI else "tcpdump", as_bpf(want)))
    print("   On an Edge file add the tag arm, or tagged packets are dropped:")
    print("     tcpdump -nr <file> '(%s) or (vlan and (%s))'" % (as_bpf(want), as_bpf(want)))
    return 0


def one_line(pkt):
    stamp = time.strftime("%H:%M:%S", time.localtime(pkt["t"])) + ("%.6f" % (pkt["t"] % 1))[1:]
    tag = " vlan%d" % pkt["vlan"] if pkt.get("vlan") is not None else ""
    head = "%s%s %s %s" % (stamp, tag, pkt.get("src", "?"), pkt.get("proto", "?"))
    if pkt.get("proto") == "tcp":
        return "%s %s:%s > %s:%s [%s] seq %d ack %d win %d len %d" % (
            stamp + tag, pkt["src"], pkt["sport"], pkt["dst"], pkt["dport"],
            pkt["flags"], pkt["seq"], pkt["ack"], pkt["win"], pkt.get("plen", 0))
    if pkt.get("proto") == "udp":
        extra = ""
        if "l7code" in pkt and pkt["l7code"] in RADIUS_CODE:
            extra = "  %s id=%d" % (RADIUS_CODE[pkt["l7code"]], pkt.get("l7id", 0))
        return "%s %s:%s > %s:%s udp len %d%s" % (
            stamp + tag, pkt["src"], pkt["sport"], pkt["dst"], pkt["dport"],
            pkt.get("plen", 0), extra)
    if pkt.get("proto") == "icmp":
        text = ICMP_TEXT.get(pkt.get("icmp_type"), "type %s" % pkt.get("icmp_type"))
        if pkt.get("icmp_type") == 3:
            text += "/" + ICMP_UNREACH.get(pkt.get("icmp_code"), str(pkt.get("icmp_code")))
        return "%s %s > %s icmp %s" % (stamp + tag, pkt.get("src"), pkt.get("dst"), text)
    return head


def as_bpf(want):
    parts = []
    if want.proto:
        parts.append(want.proto)
    if want.src and want.dst:
        parts.append("host %s and host %s" % (want.src, want.dst))
    elif want.src:
        parts.append("host %s" % want.src)
    elif want.dst:
        parts.append("host %s" % want.dst)
    ports = [p for p in (want.sport, want.dport) if p]
    if len(ports) == 2:
        parts.append("port %s and port %s" % tuple(ports))
    elif ports:
        parts.append("port %s" % ports[0])
    return " and ".join(parts) or "ip"


def ask_tuple():
    """The menu asks for the 5-tuple one field at a time - Enter = any."""
    print("   Enter what you know. Empty = any. The reply direction is")
    print("   matched too, so source/destination order does not matter.")
    src = ask("   source IP        (Enter = any) : ")
    sport = ask("   source port      (Enter = any) : ")
    dst = ask("   destination IP   (Enter = any) : ")
    dport = ask("   destination port (Enter = any) : ")
    proto = ask("   protocol tcp/udp/icmp (Enter = any) : ")
    return Tuple5(src, dst, sport, dport, proto)



# ===========================================================================
#  OVERVIEW - what is in this run
# ===========================================================================
def action_overview():
    band("RUN   %s" % os.path.basename(RUN))
    info = os.path.join(RUN, "00-run-info.txt")
    if os.path.exists(info):
        with open(info, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh.read().split("\n"):
                if line.startswith("FILE NAMES") or line.startswith("READING THE"):
                    break
                if line.strip():
                    print("   " + line)
    print()
    thin()
    total = 0
    for sub, what in (("pcap", "packet captures"), ("state", "counters"),
                      ("session", "session / firewall / LB tables")):
        files = run_files(sub)
        size = sum(os.path.getsize(f) for f in files)
        total += size
        print("   %-8s %3d file(s)  %8.1f KB   %s" % (sub, len(files), size / 1024.0, what))
    print("   %-8s %25.1f KB" % ("total", total / 1024.0))
    print()
    points = pcap_points(RUN)
    if points:
        print("   capture points")
        for label, paths in points:
            first = last = None
            n = 0
            for path in paths:
                for pkt in pcap_packets(path):
                    n += 1
                    if first is None:
                        first = pkt["t"]
                    last = pkt["t"]
            span = ("%s - %s" % (time.strftime("%H:%M:%S", time.localtime(first)),
                                 time.strftime("%H:%M:%S", time.localtime(last)))) if n else "-"
            print("     %-34s %7d packet(s)   %s" % (label[:34], n, span))
            print("       %s" % point_meaning(label))
    broken = []
    for sub in ("state", "session"):
        for path in run_files(sub):
            why = failed_command(path)
            if why:
                broken.append((os.path.basename(path), why))
    if broken:
        print()
        print("   These files hold an error message, not data - the command the")
        print("   collector ran does not exist on this NSX/ESXi version:")
        for name, why in broken[:10]:
            print("     %-46s %s" % (name[:46], why[:40]))
    print()
    print("   Next:  flow (5-tuple), state, session, report")


# ===========================================================================
#  STATE - the counters
# ===========================================================================
def state_edge_interfaces():
    out = []
    for path in run_files("state"):
        name = os.path.basename(path)
        if not (name.startswith("30-edge-interfaces") or name.startswith("33-edge-port")):
            continue
        if failed_command(path):
            continue
        series = {}
        for stamp, body in samples(path):
            iface = None
            for line in body:
                m = re.match(r"Interface\s*:\s*(\S+)", line) or re.match(r"^(fp-eth\d+)\s*$", line)
                if m:
                    iface = m.group(1)
                m = re.match(r"\s*(RX|TX) (packets|bytes|errors|drops|dropped|misses)\s*:\s*(\d+)", line)
                if m and iface:
                    key = "%s %s %s" % (iface, m.group(1), m.group(2))
                    series.setdefault(key, []).append((stamp, int(m.group(3))))
        for key in sorted(series):
            out.append((key, series[key]))
    return out


def state_edge_router_lifs():
    """34-edge-router-<uuid>-interface-stats.txt - per LIF rx/tx."""
    out = []
    for path in run_files("state"):
        name = os.path.basename(path)
        if not name.startswith("34-edge-router"):
            continue
        short = name.split("-")[3]
        series = {}
        for stamp, body in samples(path):
            lif = None
            for line in body:
                m = re.match(r"\s*Interface\s*:\s*(\S+)", line)
                if m:
                    lif = m.group(1)[:8]
                m = re.match(r"\s*(rx|tx)_(packets|bytes|drops|errors)\s*:\s*(\d+)", line, re.I)
                if m and lif:
                    key = "%s/%s %s_%s" % (short, lif, m.group(1).lower(), m.group(2).lower())
                    series.setdefault(key, []).append((stamp, int(m.group(3))))
        for key in sorted(series):
            out.append((key, series[key]))
    return out


def state_edge_ha():
    """HA state per sample. A flip mid-window explains a lot of "it stopped"."""
    out = []
    for path in run_files("state"):
        name = os.path.basename(path)
        if not name.startswith("35-edge-router"):
            continue
        short = name.split("-")[3]
        states = []
        for stamp, body in samples(path):
            found = ""
            for line in body:
                m = re.match(r"\s*state\s*:\s*(\S+)", line)
                if m:
                    found = m.group(1)
                    break
            states.append((stamp, found or "?"))
        out.append((short, states))
    return out


def state_esxi_uplinks():
    out = []
    for path in run_files("state"):
        name = os.path.basename(path)
        if not name.startswith("41-esxi-uplink"):
            continue
        nic = name.split("-")[3]
        series = {}
        for stamp, body in samples(path):
            got = parse_kv_counters(body, ["packets", "error", "drop", "crc", "oversize"])
            for key, val in got.items():
                series.setdefault("%s %s" % (nic, key[:24]), []).append((stamp, val))
        for key in sorted(series):
            out.append((key, series[key]))
    return out


def esxi_vmport_rates():
    """42-esxi-vmport-<vm>-<port>-stats.txt is "net-stats -A -t vW -p <port>",
    which prints JSON for EVERY port of the host and in RATES (pps, mbps,
    errors per second) - not cumulative counters. So pick out the port the
    file is named after and report its rate per sample."""
    out = []
    for path in run_files("state"):
        name = os.path.basename(path)
        if not name.startswith("42-esxi-vmport"):
            continue
        tag = name[len("42-esxi-vmport-"):].replace("-stats.txt", "")
        port = tag.split("-")[-1]
        rows = []
        for stamp, body in samples(path):
            text = "\n".join(body)
            got = None
            try:
                import json
                data = json.loads(text)
                for sample in data.get("stats", []):
                    for entry in sample.get("ports", []):
                        if str(entry.get("id")) == port:
                            got = entry
            except (ValueError, ImportError):
                got = None
            if got is None:
                # tolerate a truncated JSON block: find the port's own line
                m = re.search(r'\{"name":[^\n]*"id":\s*%s\b[^\n]*\n([^\n]*)' % port, text)
                if m:
                    got = {}
                    for key in ("txpps", "rxpps", "txmbps", "rxmbps", "txeps", "rxeps"):
                        mm = re.search(r'"%s":\s*([\d.]+)' % key, m.group(1))
                        if mm:
                            got[key] = float(mm.group(1))
                    got["name"] = "?"
            if got:
                rows.append((stamp, got))
        if rows:
            out.append((tag, rows))
    return out


def action_state():
    band("STATE - what the counters did during the window")
    ha = state_edge_ha()
    if ha:
        print("   HA state per router (a change here explains a sudden stop)")
        for short, states in ha:
            uniq = []
            for stamp, st in states:
                if not uniq or uniq[-1][1] != st:
                    uniq.append((stamp, st))
            text = " -> ".join("%s %s" % (hhmm(s), v) for s, v in uniq)
            flag = "  <-- CHANGED" if len(uniq) > 1 else ""
            print("     %-10s %s%s" % (short, text, flag))
        print()
    vmports = esxi_vmport_rates()
    if vmports:
        print("   ESXi VM switch ports - rate per sample (pps = packets/s,")
        print("   eps = errors/s. These are rates, not totals.)")
        for tag, rows in vmports:
            print("     %s" % tag)
            for stamp, got in rows:
                print("       %s  rx %6.0f pps %6.1f mbps   tx %6.0f pps %6.1f mbps"
                      "   err rx %.2f tx %.2f"
                      % (hhmm(stamp), got.get("rxpps", 0), got.get("rxmbps", 0),
                         got.get("txpps", 0), got.get("txmbps", 0),
                         got.get("rxeps", 0), got.get("txeps", 0)))
            bad = [s for s, g in rows if (g.get("rxeps", 0) or g.get("txeps", 0))]
            if bad:
                print("       errors per second were NOT zero at: %s" % ", ".join(hhmm(b) for b in bad))
        print()
    for title, rows in (("Edge interfaces / fastpath ports", state_edge_interfaces()),
                        ("Edge logical router interfaces", state_edge_router_lifs()),
                        ("ESXi uplink NICs", state_esxi_uplinks())):
        if not rows:
            continue
        interesting = [(n, s) for n, s in rows
                       if re.search(r"error|drop|miss|crc", n, re.I)]
        traffic = [(n, s) for n, s in rows if (n, s) not in interesting]
        delta_table(traffic[:24], title, width=26)
        if interesting:
            print()
            bad = [(n, s) for n, s in interesting
                   if len(s) > 1 and (s[-1][1] - s[0][1]) > 0]
            if bad:
                print("   RISING error/drop counters - look at these first:")
                for name, series in bad:
                    print("     %-30s %d -> %d   (+%d)"
                          % (name[:30], series[0][1], series[-1][1],
                             series[-1][1] - series[0][1]))
            else:
                print("   error/drop counters: no change during the window (good)")
        print()
    cpu = [p for p in run_files("state") if "dataplane-cpu" in os.path.basename(p)]
    for path in cpu:
        blocks = samples(path)
        if not blocks:
            continue
        print("   Edge dataplane CPU (last sample)")
        for line in blocks[-1][1][:8]:
            if line.strip():
                print("     " + line.strip()[:66])
        print()
    if not (ha or state_edge_interfaces() or state_esxi_uplinks() or vmports):
        print("   No counters found in this run. Was the state collection")
        print("   started? (collector: 'start' or 'stats-run')")


# ===========================================================================
#  SESSION - firewall connections, LB state, DFW flows
# ===========================================================================
CONN_RE = re.compile(
    r"^(0x[0-9a-f]+):\s+(\S+):(\d+)\s*->\s*(\S+):(\d+)\s*"
    r"(?:\((\S+):(\d+)\)\s*)?dir\s+(\S+)\s+protocol\s+(\S+)\s+state\s+(\S+)")


def parse_conn_table(lines):
    """Edge: "0x..: a:1 -> b:2 (nat:2) dir in protocol tcp state EST:EST"."""
    conns = []
    for line in lines:
        m = CONN_RE.match(line.strip())
        if not m:
            continue
        conns.append({
            "src": m.group(2), "sport": m.group(3),
            "dst": m.group(4), "dport": m.group(5),
            "nat": m.group(6) or "", "natport": m.group(7) or "",
            "dir": m.group(8), "proto": m.group(9), "state": m.group(10),
        })
    return conns


def action_session(want=None):
    band("SESSIONS - firewall connections, load balancer, DFW")
    files = run_files("session")
    if not files:
        print("   No session files in this run.")
        return
    # ---- Edge: connection count over time ------------------------------
    counts = {}
    for path in files:
        name = os.path.basename(path)
        if not name.startswith("50-edge-fw-conn-count"):
            continue
        if failed_command(path):
            print("   %s: the collector's command was refused by this NSX" % name)
            print("     (%s)" % failed_command(path))
            continue
        stamp = name.split("-")[-1].replace(".txt", "")
        for line in open(path, encoding="utf-8", errors="replace"):
            m = re.search(r"Connection count\s*:\s*(\d+)", line)
            if m:
                counts.setdefault(name.split("-")[5], []).append((stamp, int(m.group(1))))
    if counts:
        print("   Edge firewall connection count per interface")
        for lif, series in sorted(counts.items()):
            series.sort()
            text = ", ".join("%s=%d" % (s, v) for s, v in series)
            print("     %-10s %s" % (lif, text))
        print()
    # ---- Edge: the connection tables -----------------------------------
    tables = [p for p in files if os.path.basename(p).startswith("51-edge-fw-conn-table")]
    tables = [p for p in tables if not failed_command(p)]
    if tables:
        print("   Edge connection tables (%d sample file(s))" % len(tables))
        last = sorted(tables)[-1]
        with open(last, encoding="utf-8", errors="replace") as fh:
            conns = parse_conn_table(fh.read().split("\n"))
        print("     newest: %s - %d connection(s)" % (os.path.basename(last), len(conns)))
        states, protos, nats = {}, {}, {}
        for c in conns:
            states[c["state"]] = states.get(c["state"], 0) + 1
            protos[c["proto"]] = protos.get(c["proto"], 0) + 1
            if c["nat"]:
                key = "%s:%s -> %s:%s (as %s:%s)" % (c["src"], c["sport"], c["dst"],
                                                     c["dport"], c["nat"], c["natport"])
                nats[key] = nats.get(key, 0) + 1
        if protos:
            print("     protocols : " + ", ".join("%s %d" % kv for kv in sorted(protos.items())))
        if states:
            print("     states    : " + ", ".join("%s %d" % kv for kv in
                                                  sorted(states.items(), key=lambda kv: -kv[1])[:6]))
        halfopen = sum(v for k, v in states.items() if "SYN" in k.upper())
        if halfopen:
            print("     %d half-open connection(s) (SYN state) - the far side is not"
                  % halfopen)
            print("     answering, or the answer does not come back")
        if nats:
            print("     translated connections (this is the NAT / LB mapping):")
            for key in list(nats)[:5]:
                print("       " + key)
        if want and not want.empty():
            hits = [c for c in conns
                    if (not want.src or want.src in (c["src"], c["dst"], c["nat"]))
                    and (not want.dst or want.dst in (c["src"], c["dst"], c["nat"]))
                    and (not want.dport or want.dport in (c["dport"], c["sport"], c["natport"]))
                    and (not want.proto or want.proto == c["proto"])]
            print("     matching your 5-tuple: %d connection(s)" % len(hits))
            for c in hits[:8]:
                extra = " (as %s:%s)" % (c["nat"], c["natport"]) if c["nat"] else ""
                print("       %s:%s -> %s:%s%s %s %s dir %s"
                      % (c["src"], c["sport"], c["dst"], c["dport"], extra,
                         c["proto"], c["state"], c["dir"]))
        print()
    # ---- Edge: load balancer -------------------------------------------
    for path in files:
        name = os.path.basename(path)
        if name.startswith("52-edge-lb-status"):
            print("   Load balancer status per sample")
            for stamp, body in samples(path):
                got = {}
                for line in body:
                    m = re.match(r"\s*([\w -]+?)\s*:\s*(.+?)\s*$", line)
                    if m:
                        got[m.group(1).strip()] = m.group(2).strip()
                print("     %s  state=%s ha=%s  VS %s/%s up  pools %s/%s up"
                      % (hhmm(stamp), got.get("LB-State", "?"), got.get("LR-HA-State", "?"),
                         got.get("Up Virtual Servers", "?"), got.get("Virtual Servers", "?"),
                         got.get("Up Pools", "?"), got.get("Pools", "?")))
                down = num(got.get("Pools")) or 0
                up = num(got.get("Up Pools")) or 0
                if down and up < down:
                    print("       %d pool(s) not up - check 55-edge-lb-pool-*" % (down - up))
            print()
        if name.startswith("53-edge-lb-stats"):
            print("   Load balancer sessions per sample (CUR / MAX / TOTAL / RATE)")
            for stamp, body in samples(path):
                for line in body:
                    m = re.match(r"\s*(L4|L7)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", line)
                    if m:
                        print("     %s  %s  cur=%s max=%s total=%s rate=%s/s"
                              % (hhmm(stamp), m.group(1), m.group(2), m.group(3),
                                 m.group(4), m.group(5)))
            print()
        if name.startswith("55-edge-lb-pool"):
            print("   Pool members (%s)" % name.split("-")[4])
            blocks = samples(path)
            if blocks:
                # The file is a sequence of "Pool" / "Member" / "Monitor"
                # sections, each a list of "Key : value" lines. Printing the
                # fields as they come reads like noise, so group them.
                section, cur, sections = "", {}, []
                for line in blocks[-1][1]:
                    head = line.strip()
                    if head in ("Pool", "Member", "Monitor"):
                        if cur:
                            sections.append((section, cur))
                        section, cur = head, {}
                        continue
                    m = re.match(r"\s*([\w -]+?)\s*:\s*(.+?)\s*$", line)
                    if m and section:
                        cur[m.group(1).strip()] = m.group(2).strip()
                if cur:
                    sections.append((section, cur))
                for kind, data in sections:
                    state = data.get("Status", "?")
                    flag = "" if state.lower() in ("up", "ready") else "   <-- NOT UP"
                    if kind == "Pool":
                        print("     pool %-12s %-6s  members %s up / %s total%s"
                              % (data.get("Display-Name", "")[:12], state,
                                 data.get("Primary Up", "?"), data.get("Total-Members", "?"), flag))
                    elif kind == "Member":
                        print("     member %-12s %-15s port %-5s %s%s"
                              % (data.get("Display-Name", "")[:12], data.get("IP", ""),
                                 data.get("Port", "?"), state, flag))
                    elif kind == "Monitor":
                        print("     monitor %-11s %-15s %s%s"
                              % (data.get("Display-Name", "")[:11],
                                 "%s %s" % (data.get("Type", ""), data.get("Url", "")),
                                 state, flag))
                if not sections:
                    print("     (no member detail in this file)")
            print()
    # ---- ESXi: DFW ------------------------------------------------------
    passdrop = [p for p in files if os.path.basename(p).startswith("63-dfw-passdrop")]
    if passdrop:
        print("   ESXi DFW pass / drop, in PACKETS (the file also holds bytes)")
        for path in sorted(passdrop):
            nic = os.path.basename(path)[len("63-dfw-passdrop-"):].replace(".txt", "")
            series, reasons = {}, {}
            for stamp, body in samples(path):
                # the same "v4 pass:" line appears once under PACKETS and
                # once under BYTES - mixing them gives nonsense deltas
                section = ""
                for line in body:
                    head = line.strip()
                    # the sections of "vsipioctl getfilterstat", in order:
                    # PACKETS, BYTES, DROP REASON, MISCELLANEOUS, FILTER INFO
                    # the header line is "PACKETS   IN   OUT", so compare the
                    # first word, and the two-word headers as a prefix
                    first = head.split()[0] if head else ""
                    if head.startswith("DROP REASON"):
                        section = "REASON"
                        continue
                    if head.startswith("FILTER INFO") or first == "MISCELLANEOUS":
                        section = "OTHER"
                        continue
                    if first in ("PACKETS", "BYTES"):
                        section = first
                        continue
                    if head.startswith("---"):
                        continue
                    if section == "REASON":
                        m = re.match(r"\s*([\w -]+?):\s*(\d+)\s*$", line)
                        if m:
                            reasons.setdefault(m.group(1).strip(), []).append(
                                (stamp, int(m.group(2))))
                        continue
                    if section != "PACKETS":
                        continue
                    m = re.match(r"\s*v4 (pass|drop)\s*:\s*(\d+)\s+(\d+)", line)
                    if m:
                        series.setdefault(m.group(1) + " IN", []).append((stamp, int(m.group(2))))
                        series.setdefault(m.group(1) + " OUT", []).append((stamp, int(m.group(3))))
            line = "     %-18s" % nic[:18]
            for key in ("pass IN", "pass OUT", "drop IN", "drop OUT"):
                ser = series.get(key, [])
                if not ser:
                    continue
                line += "  %s %+d" % (key, ser[-1][1] - ser[0][1])
            print(line)
            for key, ser in sorted(series.items()):
                if key.startswith("drop") and len(ser) > 1 and ser[-1][1] > ser[0][1]:
                    print("       %s RISING: %d -> %d packets during the window."
                          % (key, ser[0][1], ser[-1][1]))
                    print("       The DFW is dropping on this vNIC - compare the pre/post")
                    print("       captures for your flow (action: flow).")
            rising = [(k, s) for k, s in reasons.items()
                      if len(s) > 1 and s[-1][1] > s[0][1]]
            if rising:
                print("       why it dropped (counter grew during the window):")
                for key, ser in rising:
                    print("         %-24s %d -> %d" % (key[:24], ser[0][1], ser[-1][1]))
            elif reasons:
                counted = [(k, s[-1][1]) for k, s in reasons.items() if s[-1][1] > 0]
                if counted:
                    print("       drop reasons seen (not growing - from before the window):")
                    for key, val in counted[:5]:
                        print("         %-24s %d" % (key[:24], val))
        print()
    flows = [p for p in files if os.path.basename(p).startswith("61-dfw-flows")]
    if flows:
        print("   ESXi DFW flow table (%d sample file(s))" % len(flows))
        by_nic = {}
        for path in sorted(flows):
            base = os.path.basename(path)
            m = re.match(r"61-dfw-flows-(.*)-(\d{6})\.txt$", base)
            if not m:
                continue
            n = sum(1 for line in open(path, encoding="utf-8", errors="replace")
                    if line[:1].isdigit() or line.startswith("70"))
            by_nic.setdefault(m.group(1), []).append((m.group(2), n))
        for nic, series in sorted(by_nic.items()):
            print("     %-20s %s" % (nic[:20],
                                     ", ".join("%s=%d" % (s, v) for s, v in sorted(series))))
        if want and not want.empty():
            print("     searching the newest flow table for your 5-tuple:")
            newest = sorted(flows)[-1]
            shown = 0
            for line in open(newest, encoding="utf-8", errors="replace"):
                if want.src and want.src not in line:
                    continue
                if want.dst and want.dst not in line:
                    continue
                if want.dport and want.dport not in line:
                    continue
                if want.proto and want.proto not in line.lower():
                    continue
                if line.strip() and (line[:1].isdigit() or line.startswith("70")):
                    print("       " + line.strip()[:100])
                    shown += 1
                    if shown >= 8:
                        break
            if not shown:
                print("       not in the flow table (the session may have expired)")
        print()
    rules = [p for p in files if os.path.basename(p).startswith("62-dfw-rules")]
    if rules:
        print("   ESXi DFW rules applied to the captured vNICs")
        for path in sorted(rules):
            nic = os.path.basename(path)[len("62-dfw-rules-"):].replace(".txt", "")
            text = open(path, encoding="utf-8", errors="replace").read()
            nrules = len(re.findall(r"^\s*rule \d+", text, re.M))
            drops = len(re.findall(r"\bdrop\b", text))
            rejects = len(re.findall(r"\breject\b", text))
            print("     %-20s %3d rule(s), %d with drop, %d with reject"
                  % (nic[:20], nrules, drops, rejects))
        print()


# ===========================================================================
#  REPORT - everything at once, to screen or to a file
# ===========================================================================
def action_report(path=None, want=None):
    import io
    buf = io.StringIO()
    real = sys.stdout
    sys.stdout = buf
    try:
        action_overview()
        print()
        action_state()
        print()
        action_session(want)
        if want and not want.empty():
            print()
            action_analyse(want)
    finally:
        sys.stdout = real
    text = buf.getvalue()
    if path:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("nsx-analyzer %s report - %s\nrun: %s\n\n"
                     % (VERSION, time.strftime("%Y-%m-%d %H:%M:%S"), RUN))
            fh.write(text)
        print("report written: %s  (%d lines)" % (path, text.count("\n")))
    else:
        print(text)
    return 0


# ===========================================================================
#  help and menu
# ===========================================================================
HELP = """
   nsx-analyzer reads a run directory made by nsx-collector and tells you
   what is in it. It changes nothing on the box.

   ACTIONS
     (no action)      the menu
     overview         what this run contains, per capture point and file
     flow             find one flow (5-tuple) and say what happened to it
     state            what the counters did: HA state, interfaces, drops
     session          firewall connections, LB status, DFW pass/drop, flows
     report [file]    all of the above, to screen or into a file
     runs             list the run directories it can see
     help             this text

   WHERE IT LOOKS
     --run <dir>      a run directory (or its parent) to work on
     Otherwise: /var/dump/nsx-collect, /tmp/nsx-collect, then here.

   FLOW, THE ONE YOU WILL USE MOST
     python3 nsx-analyzer.py flow --src 10.1.1.5 --dst 10.1.1.50 \\
                                  --dport 8080 --proto tcp
     Every field is optional and the reply direction is matched too. It reads
     the pcap files itself - classic pcap from tcpdump and the pcapng that
     pktcap-uw writes - so 802.1Q tagged packets cannot hide, which they do
     when a filter is handed to tcpdump while reading a file.

   WHAT IT WILL TELL YOU
     - per capture point: packets per direction, the address pairs actually
       seen (this is where NAT shows up), TCP handshake / retransmissions /
       resets, UDP answer times with a warning when an answer is slower than
       the 30 s a stateful firewall keeps a UDP session, ICMP reasons,
       RADIUS message types
     - the same vNIC before and after the DFW, so "the firewall dropped it"
       and "it never arrived on this host" are told apart
     - rising drop/error counters, and an HA state change during the window
     - the Edge connection table with its NAT mapping, half-open sessions,
       LB virtual server / pool state over the window
     - and the tcpdump command to check any of it by hand
"""


def action_help():
    band("nsx-analyzer %s - reading back what was collected" % VERSION)
    print(HELP)


def action_runs():
    band("RUN DIRECTORIES")
    runs = find_runs()
    if not runs:
        print("   none found under: %s" % ", ".join(RUN_ROOTS))
        print("   give one with:  --run /path/to/run-<tag>-<date>-<time>")
        return
    for i, path in enumerate(runs, 1):
        files = sum(len(f) for _r, _d, f in os.walk(path))
        mark = " <- in use" if os.path.abspath(path) == RUN else ""
        print("   %2d) %-58s %3d files%s" % (i, path[-58:], files, mark))


def pick_run():
    runs = find_runs()
    if not runs:
        print("   no run directory found. Use --run <dir>.")
        return False
    for i, path in enumerate(runs, 1):
        print("   %2d) %s" % (i, path))
    choice = ask("   which run? [number, Enter = newest] ")
    if not choice:
        use_run(runs[-1])
        return True
    try:
        use_run(runs[int(choice) - 1])
        return True
    except (ValueError, IndexError):
        print("   ?")
        return False


def menu():
    rule()
    row("  NSX Analyzer %s" % VERSION)
    row("  run: %s" % (os.path.basename(RUN) if RUN else "(none picked)"))
    rule()
    row("")
    row("    1  overview        what this run contains")
    row("    2  flow            find a flow (5-tuple) and explain it")
    row("    3  state           counters, HA state, rising drops")
    row("    4  session         firewall connections, LB, DFW")
    row("    5  report          all of it, saved to a file")
    row("")
    row("    r  pick another run        9  help")
    row("    l  list runs               q  quit")
    row("")
    rule()


def run_menu():
    if not RUN:
        latest = latest_run()
        if latest:
            use_run(latest)
        else:
            print("No run directory found under %s." % ", ".join(RUN_ROOTS))
            print("Start it with:  python3 nsx-analyzer.py --run <dir>")
            return
    while True:
        print()
        menu()
        print()
        try:
            choice = input("   choose > ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            return
        print()
        if choice in ("q", "quit", "exit"):
            return
        if choice == "1":
            action_overview()
        elif choice == "2":
            want = ask_tuple()
            print()
            print("   $ python3 nsx-analyzer.py flow%s%s%s%s%s --run %s" % (
                (" --src " + want.src) if want.src else "",
                (" --sport " + want.sport) if want.sport else "",
                (" --dst " + want.dst) if want.dst else "",
                (" --dport " + want.dport) if want.dport else "",
                (" --proto " + want.proto) if want.proto else "", RUN))
            print()
            action_analyse(want, run=RUN)
        elif choice == "3":
            action_state()
        elif choice == "4":
            want = Tuple5()
            if ask("   narrow it to one 5-tuple? [y/N] ").lower().startswith("y"):
                want = ask_tuple()
            action_session(want)
        elif choice == "5":
            default = os.path.join(RUN, "99-analysis-%s.txt" % time.strftime("%H%M%S"))
            path = ask("   write to [%s] : " % default, default)
            action_report(path)
        elif choice == "r":
            pick_run()
        elif choice == "l":
            action_runs()
        elif choice == "9":
            action_help()
        else:
            print("   ?")
        try:
            input("\n   Press Enter for the menu ")
        except (EOFError, KeyboardInterrupt):
            return


# ===========================================================================
#  dispatch
# ===========================================================================
def opt(args, name, default=""):
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            return args[i + 1]
        if a.startswith(name + "="):
            return a.split("=", 1)[1]
    return default


def main():
    args = sys.argv[1:]
    global ASKED_ROOT
    want_run = opt(args, "--run")
    if want_run:
        if not os.path.isdir(want_run):
            die("no such directory: %s" % want_run)
        ASKED_ROOT = os.path.abspath(want_run)
        runs = find_runs(want_run)
        use_run(runs[-1] if runs else want_run)
    action = ""
    for a in args:
        if not a.startswith("-"):
            action = a
            break
    if not action:
        if not RUN:
            latest = latest_run()
            if latest:
                use_run(latest)
        run_menu()
        return
    if action in ("help", "-h", "--help"):
        action_help()
        return
    if action == "runs":
        action_runs()
        return
    if not RUN:
        latest = latest_run()
        if not latest:
            die("no run directory found under %s\nuse --run <dir>" % ", ".join(RUN_ROOTS))
        use_run(latest)
    want = Tuple5(opt(args, "--src"), opt(args, "--dst"), opt(args, "--sport"),
                  opt(args, "--dport"), opt(args, "--proto"))
    if action == "overview":
        action_overview()
    elif action in ("flow", "analyze", "analyse"):
        if want.empty():
            want = ask_tuple()
        sys.exit(action_analyse(want, run=RUN, limit=int(opt(args, "--lines") or 12)))
    elif action == "state":
        action_state()
    elif action == "session":
        action_session(want)
    elif action == "report":
        rest = [a for a in args[1:] if not a.startswith("-")]
        target = rest[0] if rest else None
        sys.exit(action_report(target, want))
    else:
        print("Unknown action: %s" % action)
        print("Try: python3 nsx-analyzer.py help")
        sys.exit(2)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\ninterrupted")
        sys.exit(130)

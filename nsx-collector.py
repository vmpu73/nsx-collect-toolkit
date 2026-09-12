#!/usr/bin/env python3
# ===========================================================================
#  nsx-collector.py - on-box collection for NSX Edge and ESXi
#
#  Two files are all you need on the box:
#      nsx-collector.py      this file - menu AND every collector
#      nsx-collector.conf    the only thing you edit (and "discover" fills it)
#
#      python3 nsx-collector.py                 the menu for THIS box
#      python3 nsx-collector.py <action>        one action, no menu
#      python3 nsx-collector.py help            what it collects and why
#
#  It works out by itself whether it is on an NSX Edge or on an ESXi host and
#  shows only what that box can do.
#
#  Only the Python standard library is used - nothing to install.
#  ESXi 8.0.3 has Python 3.11, an NSX 4.2 Edge has 3.10.
# ===========================================================================
import os
import re
import shutil
import signal
import subprocess
import sys
import time

VERSION = "6.0"
HERE = os.path.dirname(os.path.abspath(__file__))
SELF = os.path.abspath(__file__)
CONF_PATH = os.environ.get("NSXC_CONF", os.path.join(HERE, "nsx-collector.conf"))

UIW = 70


# ===========================================================================
#  screen - pure ASCII, fixed width. The ESXi console mangles anything else.
# ===========================================================================
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


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


def ask(prompt, default=""):
    try:
        answer = input(prompt).strip()
    except EOFError:
        return default
    return answer or default


# ===========================================================================
#  running commands
# ===========================================================================
def sh(args, timeout=120, merge=True):
    """Run a command. Returns (returncode, output). Never raises."""
    if isinstance(args, str):
        args = ["sh", "-c", args]
    try:
        p = subprocess.Popen(
            args, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT if merge else subprocess.PIPE)
        out, _ = p.communicate(timeout=timeout)
        return p.returncode, out.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        p.kill()
        return 124, "(timed out after %ds)" % timeout
    except OSError as e:
        return 127, str(e)


def have(cmd):
    return shutil.which(cmd) is not None


# ===========================================================================
#  the config file
#
#  Format is KEY="value" so that the shell version of this tool can read the
#  very same file. Comments are kept when "discover" writes into it.
# ===========================================================================
KEY_RE = re.compile(r'^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$')


def conf_value(raw):
    """The value of one KEY=... line.

    A quoted value ends at its closing quote - everything after it is a
    comment, even when the comment itself contains quotes:
        PROTO=""      # "udp" / "tcp", or several: "udp tcp"
    An unquoted value ends at the first '#'.
    """
    raw = raw.strip()
    if raw[:1] in ('"', "'"):
        quote = raw[0]
        end = raw.find(quote, 1)
        return raw[1:end] if end > 0 else raw[1:]
    return raw.split("#")[0].strip()


def conf_load(path):
    values = {}
    if not os.path.exists(path):
        die("config not found: %s\n"
            "nsx-collector.conf must sit next to nsx-collector.py, or set "
            "NSXC_CONF=/path/nsx-collector.conf" % path)
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\r\n")
            if not line or line.lstrip().startswith("#"):
                continue
            m = KEY_RE.match(line)
            if not m:
                continue
            values[m.group(1)] = conf_value(m.group(2))
    return values


def conf_write(path, updates):
    """Set keys in place, keep every comment. Backs the file up once."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    todo = dict(updates)
    out = []
    for line in lines:
        m = KEY_RE.match(line.rstrip("\r"))
        if m and m.group(1) in todo:
            key = m.group(1)
            rest = line.split("=", 1)[1].strip()
            # keep the trailing comment, and only the comment: a quoted value
            # ends at its closing quote, so a '#' inside it is not a comment.
            if rest[:1] in ('"', "'"):
                end = rest.find(rest[0], 1)
                tail = rest[end + 1:] if end > 0 else ""
            else:
                tail = "#" + rest.split("#", 1)[1] if "#" in rest else ""
            tail = ("  " + tail.strip()) if tail.strip() else ""
            out.append('%s="%s"%s' % (key, todo.pop(key), tail))
        else:
            out.append(line)
    for key, val in todo.items():          # keys the file did not have
        out.append('%s="%s"' % (key, val))
    backup = path + ".bak"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out))
    return backup


CONF = conf_load(CONF_PATH)


def cget(key, default=""):
    return (CONF.get(key) or default).strip()


def cint(key, default):
    raw = cget(key)
    try:
        return int(raw)
    except ValueError:
        return default


# ===========================================================================
#  which box is this?
# ===========================================================================
def detect_platform():
    if os.uname().sysname == "VMkernel":
        return "esxi"
    if os.path.isdir("/opt/vmware/nsx-edge"):
        return "edge"
    return ""


PLAT = detect_platform()
if not PLAT:
    die("This is neither an ESXi host (VMkernel) nor an NSX Edge.\n"
        "nsx-collector only runs on the boxes it collects from.")
# ESXi has no "id"; there the shell is root anyway.
if hasattr(os, "geteuid") and os.geteuid() != 0:
    die("must run as root.")

IS_EDGE = PLAT == "edge"
IS_ESXI = PLAT == "esxi"

TAG = cget("TAG") or os.uname().nodename.split(".")[0] or PLAT
CASE_ID = cget("CASE_ID")
OUT = cget("OUT") or ("/tmp/nsx-collect" if IS_ESXI else "/var/dump/nsx-collect")
MIN_FREE_MB = cint("MIN_FREE_MB", 64 if IS_ESXI else 1024)
CAP_SECS = cint("CAP_SECS", 600)
CAP_SNAPLEN = cget("CAP_SNAPLEN")
CAP_FILESIZE = cint("CAP_FILESIZE", 100)
CAP_FILECOUNT = cint("CAP_FILECOUNT", 5)
INTERVAL = cint("INTERVAL", 30)
DURATION = cint("DURATION", 1200)
LOGDIR = os.environ.get("LOGDIR", "/tmp")
RUN_JOIN_SECS = 7200


# ===========================================================================
#  config values -> ONE pcap filter expression
# ===========================================================================
def values(raw):
    """A config value -> list of tokens. Accepts "a b", "a,b", "(a or b)",
    "host a". An unfilled "<VIP>" placeholder counts as empty."""
    if not raw:
        return []
    out = []
    for tok in re.split(r"[\s(),]+", raw):
        if not tok or tok.startswith("<"):
            continue
        if tok.lower() in ("or", "and", "host", "net"):
            continue
        out.append(tok)
    return out


def names(raw):
    """Like values(), but for NAMES - VM names, NIC names. Only whitespace
    separates them and brackets are kept, because a VM may be called
    "SupervisorControlPlaneVM_(2)". A name with a space in it cannot be
    written into a space separated list at all - it is reported, not guessed.
    """
    out = []
    for tok in (raw or "").split():
        if tok.startswith("<"):
            continue
        out.append(tok)
    return out


def bpf_hosts(*raws):
    parts = []
    for raw in raws:
        for tok in values(raw):
            parts.append(("net " if "/" in tok else "host ") + tok)
    return "(" + " or ".join(parts) + ")" if parts else ""


def bpf_svc(proto_raw, *port_raws):
    protos = [p.lower() for p in values(proto_raw)]
    ports = []
    for raw in port_raws:
        ports += values(raw)
    pr = protos[0] if len(protos) == 1 else ("(" + " or ".join(protos) + ")" if protos else "")
    if len(ports) == 1:
        po = "port " + ports[0]
    elif ports:
        po = "port (" + " or ".join(ports) + ")"
    else:
        po = ""
    if pr and po:
        return "(%s and %s)" % (pr, po)
    return pr or po


def bpf_and(*parts):
    parts = [p for p in parts if p]
    if len(parts) > 1:
        return "(" + " and ".join(parts) + ")"
    return parts[0] if parts else ""


def bpf_or(*parts):
    parts = [p for p in parts if p]
    return " or ".join(parts)


IPV4 = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
CIDR = re.compile(r"^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$")
QUALIFIERS = ("host", "net", "src", "dst", "gateway")


def bpf_fix(expr):
    """A free FILTER may hold a bare address: "10.1.1.10 and udp port 1812".
    tcpdump calls that a syntax error - and "port 80 and 10.1.1.10" is worse:
    it parses, inherits the "port" qualifier and matches nothing at all.
    So put host/net in front of every address that has no qualifier yet."""
    if not expr:
        return ""
    spaced = expr.replace("(", " ( ").replace(")", " ) ")
    out, prev = [], ""
    for tok in spaced.split():
        low = prev.lower()
        if IPV4.match(tok) and low not in QUALIFIERS:
            out.append("host")
        elif CIDR.match(tok) and low != "net":
            out.append("net")
        out.append(tok)
        prev = tok
    text = " ".join(out)
    return text.replace("( ", "(").replace(" )", ")")


def filter_check(expr):
    """Is this a valid pcap expression? Returns (ok, message)."""
    if not expr:
        return True, ""
    if IS_EDGE:
        rc, out = sh(["tcpdump", "-d", "-i", "lo", expr])
        if rc == 0:
            return True, ""
        if re.search(r"no such device|not permitted", out, re.I):
            return True, ""          # cannot check here; not a filter problem
    else:
        # pktcap-uw has no BPF at all, so the expression is checked - and
        # later applied - with tcpdump-uw, against a 24 byte empty pcap file.
        empty = os.path.join(LOGDIR, ".nsxc-empty.pcap")
        with open(empty, "wb") as fh:
            fh.write(bytes([0xd4, 0xc3, 0xb2, 0xa1, 2, 0, 4, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0xff, 0xff, 0, 0, 1, 0, 0, 0]))
        rc, out = sh(["tcpdump-uw", "-r", empty, "-w", "/dev/null", expr])
        if rc == 0:
            return True, ""
    msg = [l for l in out.splitlines() if "reading from file" not in l]
    return False, "\n".join(msg[:3])


def filter_set():
    return bool(values(cget("FILTER")))


def filter_for(point):
    """point: lbt1 | vpct1 (Edge) | dfw (ESXi)."""
    if filter_set():
        return bpf_fix(cget("FILTER"))
    hosts, ports, proto = cget("HOSTS"), cget("PORTS"), cget("PROTO")
    if point == "vpct1":
        h = bpf_hosts(cget("VIP"), cget("NAT_IP"), cget("CLIENT_IP"), hosts)
        s = bpf_svc(proto, cget("SVC_PORT"), ports)
        if h and s:
            return "%s and (%s or icmp)" % (h, s)
        return h or (("%s or icmp" % s) if s else "")
    if point == "lbt1":
        front = back = ""
        if values(cget("VIP")) or values(cget("SVC_PORT")) or values(hosts) or values(ports):
            front = bpf_and(bpf_hosts(cget("VIP"), hosts), bpf_svc(proto, cget("SVC_PORT"), ports))
        if values(cget("LB_SNAT_IP")) or values(cget("NODE_PORT")):
            back = bpf_and(bpf_hosts(cget("LB_SNAT_IP")), bpf_svc(proto, cget("NODE_PORT")))
        expr = bpf_or(front, back) or bpf_svc(proto)
        if expr:
            icmp_hosts = bpf_hosts(cget("VIP"), cget("LB_SNAT_IP"), hosts)
            expr += " or (icmp and %s)" % icmp_hosts if icmp_hosts else " or icmp"
        return expr
    # ESXi
    h = bpf_hosts(cget("LB_SNAT_IP"), hosts)
    s = bpf_svc(proto, cget("NODE_PORT"), ports)
    if h and s:
        return "%s and (%s or icmp)" % (h, s)
    return h or (("%s or icmp" % s) if s else "")


# ===========================================================================
#  where results go
#
#  One collection = ONE directory, and every file name says what it is:
#    <OUT>/run-<tag>-<date>-<time>/
#        00-run-info.txt
#        pcap/    10-edge-lbt1svc-*      11-edge-vpct1uplink-*
#                 20-dfw-pre-<vm>-<nic>  21-dfw-post-<vm>-<nic>
#        state/   30..39 Edge counters   40..49 ESXi counters
#        session/ 50..59 Edge fw+LB      60..69 ESXi DFW
#  Collectors started on their own join the run that is already open.
# ===========================================================================
def free_mb(path):
    """ESXi df ignores its path argument, so work it out from the mount list."""
    rc, out = sh(["df", "-m"])
    best, free = 0, None
    if rc == 0:
        for line in out.splitlines()[1:]:
            f = line.split()
            if len(f) < 6:
                continue
            mount = " ".join(f[5:])
            if mount.startswith("/") and path.startswith(mount) and len(mount) > best:
                best, free = len(mount), f[3]
    if free is not None:
        try:
            return int(free)
        except ValueError:
            pass
    if IS_ESXI and path.startswith("/tmp"):
        rc, out = sh(["vdf", "-h"])
        for line in out.splitlines():
            f = line.split()
            if len(f) >= 4 and f[0] == "tmp":
                m = re.match(r"([\d.]+)([KMG])?", f[3])
                if m:
                    val = float(m.group(1))
                    unit = m.group(2) or "M"
                    return int(val * {"K": 1 / 1024, "M": 1, "G": 1024}[unit])
    try:
        st = os.statvfs(path if os.path.isdir(path) else os.path.dirname(path) or "/")
        return int(st.f_bavail * st.f_frsize / 1048576)
    except OSError:
        return None


def on_ramdisk(path):
    return IS_ESXI and path.startswith("/tmp")


def mkout():
    os.makedirs(OUT, exist_ok=True)
    fm = free_mb(OUT)
    if fm is None:
        log("  Warning: cannot determine free space for", OUT)
        return
    log("  free space in %s: %d MB" % (OUT, fm))
    if fm < MIN_FREE_MB:
        die("only %d MB free in %s (MIN_FREE_MB=%d). Refusing to start.\n"
            "Point OUT somewhere bigger in nsx-collector.conf, or free space first."
            % (fm, OUT, MIN_FREE_MB))
    if on_ramdisk(OUT):
        log("  Note: %s is on the ESXi ramdisk, not disk. Keep it small." % OUT)


def run_marker():
    return os.path.join(OUT, ".nsxc-run")


def run_dir():
    """The run directory in use - created if there is none open."""
    env = os.environ.get("NSXC_RUN")
    if env:
        for sub in ("pcap", "state", "session"):
            os.makedirs(os.path.join(env, sub), exist_ok=True)
        return env
    mk = run_marker()
    if os.path.exists(mk):
        try:
            with open(mk) as fh:
                path, stamp = fh.read().split()
            if os.path.isdir(path) and time.time() - float(stamp) < RUN_JOIN_SECS:
                return path
        except (ValueError, OSError):
            pass
    path = os.path.join(OUT, "run-%s-%s" % (TAG, time.strftime("%Y%m%d-%H%M%S")))
    for sub in ("pcap", "state", "session"):
        os.makedirs(os.path.join(path, sub), exist_ok=True)
    with open(mk, "w") as fh:
        fh.write("%s %d" % (path, int(time.time())))
    return path


def latest_run():
    mk = run_marker()
    if os.path.exists(mk):
        try:
            with open(mk) as fh:
                path = fh.read().split()[0]
            if os.path.isdir(path):
                return path
        except (ValueError, OSError, IndexError):
            pass
    runs = sorted(p for p in glob_runs())
    return runs[-1] if runs else None


def glob_runs():
    if not os.path.isdir(OUT):
        return []
    return [os.path.join(OUT, d) for d in sorted(os.listdir(OUT))
            if d.startswith("run-") and os.path.isdir(os.path.join(OUT, d))]


RUN_INFO_NAME = "00-run-info.txt"


def run_info(path):
    info = os.path.join(path, RUN_INFO_NAME)
    if os.path.exists(info):
        return
    lines = [
        "nsx-collector %s (python)" % VERSION,
        "started : %s  (host clock)" % time.strftime("%Y-%m-%d %H:%M:%S"),
        "platform: %-12s host: %s" % (PLAT, os.uname().nodename),
        "case    : %-12s tag : %s" % (CASE_ID or "(none)", TAG),
        "config  : %s" % CONF_PATH,
        "",
        "FILTER  : %s" % (cget("FILTER") or "(empty - built from the single fields)"),
    ]
    if IS_EDGE:
        lines += [
            "  LB T1 service if : %s" % (filter_for("lbt1") or "(every packet)"),
            "  VPC T1 uplink    : %s" % (filter_for("vpct1") or "(every packet)"),
            "  capture LIFs     : LB=%s VPC=%s" % (cget("LIF_LBT1_SVC") or "none",
                                                   cget("LIF_VPCT1_UPLINK") or "none"),
        ]
    else:
        lines += [
            "  DFW capture      : %s" % (filter_for("dfw") or "(every packet on the vNIC)"),
            "  target VMs       : %s" % (" ".join(names(cget("WORKER_VMS"))) or "none"),
        ]
    lines += [
        "",
        "FILE NAMES",
        "  pcap/10-edge-lbt1svc-*      Edge capture, LB T1 service interface",
        "  pcap/11-edge-vpct1uplink-*  Edge capture, VPC T1 uplink",
        "  pcap/20-dfw-pre-*           ESXi capture BEFORE the DFW rules",
        "  pcap/21-dfw-post-*          ESXi capture AFTER the DFW rules",
        "    a trailing -u1812 / -t80 / -icmp / -ip<addr> is the pktcap-uw",
        "    filter that file was taken with (option mode only)",
        "  state/30..39   Edge   interface / router / cpu / memory counters",
        "  state/40..49   ESXi   switch port and uplink NIC counters",
        "  session/50..59 Edge   firewall connections, load balancer state",
        "  session/60..69 ESXi   DFW flows, rules, pass/drop counters",
        "  a name ending in -HHMMSS is one sample taken at that time",
        "",
        "READING THE CAPTURES LATER",
        "  Part of an Edge capture is 802.1Q tagged (mostly the return",
        "  direction). The capture filter is applied by the kernel and sees",
        "  through the tag, but a filter you apply when READING the file does",
        "  not - it would silently drop those packets:",
        "      tcpdump -nr <file> '(<expr>) or (vlan and (<expr>))'",
        "  Without an expression everything is shown, tagged or not.",
    ]
    with open(info, "w") as fh:
        fh.write("\n".join(lines) + "\n")


def mark_start(name, secs):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, ".nsxc-end-" + name), "w") as fh:
        fh.write(str(int(time.time()) + secs))


def mark_done(name):
    with open(os.path.join(OUT, ".nsxc-end-" + name), "w") as fh:
        fh.write("done")


def snap(path, label, args):
    rc, out = sh(args)
    with open(path, "a") as fh:
        fh.write("########## %s ##########\n### %s\n%s\n"
                 % (time.strftime("%Y-%m-%d %H:%M:%S"), label, out))


def space_ok():
    fm = free_mb(OUT)
    if fm is None or fm >= MIN_FREE_MB:
        return True
    log("  STOPPING: only %d MB free in %s (MIN_FREE_MB=%d)." % (fm, OUT, MIN_FREE_MB))
    return False


def budget_ok(n_captures, shrink=False):
    """CAP_FILESIZE x CAP_FILECOUNT x captures must fit in half of what is
    free above the floor (pre and post run together). On ESXi the file size is
    lowered instead of refusing - /tmp is a ramdisk."""
    global CAP_FILESIZE
    fm = free_mb(OUT)
    need = CAP_FILESIZE * CAP_FILECOUNT * n_captures
    log("  capture budget: %dMB x %d files x %d = %d MB"
        % (CAP_FILESIZE, CAP_FILECOUNT, n_captures, need))
    if fm is None:
        log("  Warning: free space unknown - continuing")
        return True
    allow = max(0, (fm - MIN_FREE_MB) // 2)
    log("  allowed here: %d MB  (free %d - reserve %d, halved for two captures)"
        % (allow, fm, MIN_FREE_MB))
    if need <= allow:
        return True
    if shrink and allow > 0:
        newsize = allow // (CAP_FILECOUNT * n_captures)
        if newsize >= 1:
            log("  NOTE: does not fit -> CAP_FILESIZE lowered to %d MB for this run" % newsize)
            CAP_FILESIZE = newsize
            return True
    return False


# ===========================================================================
#  finding OUR processes
#
#  Never by program name: a capture somebody else started must not be
#  touched. Ours = started from this file (the action is in the command line)
#  or writing into our own run directory.
#    Edge  = Linux    -> pgrep -f
#    ESXi  = busybox  -> ps -c, and column 2 (cartel id) is the process;
#                        column 1 is a world (thread), which reads like four
#                        times as many captures as there are.
# ===========================================================================
def pids_matching(pattern):
    mine = {os.getpid(), os.getppid()}
    found = []
    if IS_EDGE:
        rc, out = sh(["pgrep", "-f", pattern])
        for line in out.split():
            if line.isdigit() and int(line) not in mine:
                found.append(int(line))
    else:
        rc, out = sh(["ps", "-c"])
        for line in out.splitlines():
            if not re.search(pattern, line):
                continue
            f = line.split()
            if len(f) < 2 or not f[1].isdigit():
                continue
            if int(f[1]) in mine:
                continue
            found.append(int(f[1]))
    return sorted(set(found))


def ps_line(pid):
    if IS_EDGE:
        rc, out = sh(["ps", "-o", "pid=,args=", "-p", str(pid)])
        return out.strip()[:110]
    rc, out = sh(["ps", "-c"])
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 2 and f[1] == str(pid):
            return line.strip()[:110]
    return "(gone)"


COLLECTOR_ACTIONS = {
    "edge": ["cap-lbt1", "cap-vpct1", "stats-run", "sess-run"],
    "esxi": ["cap-pre", "cap-post", "stats-run", "dfw-run"],
}


def poller_pids():
    out = []
    for act in ("stats-run", "sess-run", "dfw-run"):
        out += pids_matching(r"nsx-collector\.py %s" % act)
    return sorted(set(out))


def capture_pids():
    pats = []
    if IS_EDGE:
        pats.append(r"tcpdump.*-w %s/run-.*/pcap/1" % re.escape(OUT))
    else:
        pats.append(r"pktcap-uw.*-o %s/run-.*/pcap/2" % re.escape(OUT))
        pats.append(r"tcpdump-uw.*-w %s/run-.*/pcap/2" % re.escape(OUT))
        for flt in esxi_all_filters():
            pats.append(r"pktcap-uw.*--dvfilter %s " % re.escape(flt))
    out = []
    for pat in pats:
        out += pids_matching(pat)
    return sorted(set(out))


def our_pids():
    out = list(poller_pids()) + list(capture_pids())
    for act in COLLECTOR_ACTIONS[PLAT]:
        out += pids_matching(r"nsx-collector\.py %s" % act)
    return sorted(set(out))


# ===========================================================================
#  ===========================  NSX EDGE  ===========================
# ===========================================================================
def cli(query, timeout=60):
    rc, out = sh(["su", "admin", "-c", query], timeout=timeout)
    return out


def edge_routers():
    """[(uuid, name, type)] from "get logical-routers"."""
    out = cli("get logical-routers")
    rows = []
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 6 and re.match(r"^[0-9a-f-]{36}$", f[0]):
            uuid, name, rtype = f[0], f[3], f[4]
            if not re.search(r"ROUTER|TUNNEL", rtype):
                name, rtype = "", f[3]
            rows.append((uuid, name, rtype))
    return rows


def edge_interfaces(sr_uuid):
    """[{uuid,name,type,ip}] from "get logical-router <uuid> interfaces"."""
    out = cli("get logical-router %s interfaces" % sr_uuid)
    ifaces, cur = [], None
    for line in out.splitlines():
        m = re.match(r"\s*Interface\s*:\s*(\S+)", line)
        if m:
            if cur:
                ifaces.append(cur)
            cur = {"uuid": m.group(1), "name": "", "type": "", "ip": ""}
            continue
        if cur is None:
            continue
        for key, field in (("Name", "name"), ("Port-type", "type"), ("IP/Mask", "ip")):
            m = re.match(r"\s*%s\s*:\s*(.*\S)" % key, line)
            if m:
                cur[field] = m.group(1).strip()
    if cur:
        ifaces.append(cur)
    return ifaces


def edge_ha_state(sr_uuid):
    out = cli("get logical-router %s high-availability status" % sr_uuid)
    for line in out.splitlines():
        m = re.match(r"\s*state\s*:\s*(\S+)", line)
        if m:
            return m.group(1)
    return "?"


def edge_load_balancers():
    """[{uuid,name,sr,vs:[ids]}] from "get load-balancers"."""
    out = cli("get load-balancers")
    lbs, cur = [], None
    for line in out.splitlines():
        if line.startswith("Load Balancer"):
            if cur:
                lbs.append(cur)
            cur = {"uuid": "", "name": "", "sr": "", "vs": []}
            continue
        if cur is None:
            continue
        m = re.match(r"\s*Service Router Id\s*:\s*(\S+)", line)
        if m:
            cur["sr"] = m.group(1)
        m = re.match(r"\s*Display Name\s*:\s*(.*\S)", line)
        if m:
            cur["name"] = m.group(1)
        m = re.match(r"^UUID\s*:\s*(\S+)", line)
        if m:
            cur["uuid"] = m.group(1)
    if cur:
        lbs.append(cur)
    return [lb for lb in lbs if lb["uuid"]]


def edge_virtual_servers(lb_uuid):
    """[{name,ip,proto,port,pool}]"""
    out = cli("get load-balancer %s virtual-servers" % lb_uuid)
    rows, cur = [], None
    for line in out.splitlines():
        m = re.match(r"\s*Display Name\s*:\s*(.*\S)", line)
        if m:
            if cur:
                rows.append(cur)
            cur = {"name": m.group(1), "ip": "", "proto": "", "port": "", "pool": ""}
            continue
        if cur is None:
            continue
        for pat, field in ((r"Ipv4\s*:\s*(\S+)", "ip"), (r"Ip Protocol\s*:\s*(\S+)", "proto"),
                           (r"Port\s*:\s*(\S+)", "port"), (r"Pool Id\s*:\s*(\S+)", "pool")):
            m = re.match(r"\s*" + pat, line)
            if m and not cur[field]:
                cur[field] = m.group(1)
    if cur:
        rows.append(cur)
    return rows


def edge_pool(lb_uuid, pool_uuid):
    """{'members': [(ip, port)], 'snat': ip}"""
    out = cli("get load-balancer %s pool %s" % (lb_uuid, pool_uuid))
    members, ip = [], ""
    for line in out.splitlines():
        m = re.match(r"\s*Ipv4\s*:\s*(\S+)", line)
        if m:
            ip = m.group(1)
            continue
        m = re.match(r"\s*Port\s*:\s*(\S+)", line)
        if m and ip:
            members.append((ip, m.group(1)))
            ip = ""
    snat = ""
    out = cli("get load-balancer %s pool %s snat-pools" % (lb_uuid, pool_uuid))
    m = re.search(r"Snat IP\s*:\s*(\S+)", out)
    if m:
        snat = m.group(1)
    return {"members": members, "snat": snat}


def edge_span_open(session_id, lif):
    cli("set capture session %s interface %s direction dual" % (session_id, lif))
    for _ in range(10):
        rc, _out = sh(["ip", "link", "show", "span-%s" % session_id])
        if rc == 0:
            return True
        time.sleep(1)
    cli("del capture session %s" % session_id)     # never leave a mirror behind
    return False


def edge_span_close(session_id):
    cli("del capture session %s" % session_id)


def edge_span_owner(session_id):
    """'ours' / 'empty' / 'other' - a session mirroring an interface that is
    not in this config belongs to somebody else and is never deleted."""
    out = cli("get capture session %s" % session_id)
    m = re.search(r"PORTS\s*:\s*(.*)", out)
    ports = m.group(1) if m else ""
    if not ports or "[]" in ports:
        return "empty"
    for lif in (cget("LIF_LBT1_SVC"), cget("LIF_VPCT1_UPLINK")):
        if lif and lif in ports:
            return "ours"
    return "other"


def edge_capture(label, prefix, lif, expr, secs, session_id):
    run = run_dir()
    run_info(run)
    base = os.path.join(run, "pcap", "%s-%s.pcap" % (prefix, time.strftime("%H%M%S")))
    log("capture %s" % label)
    log("  interface : %s  (span-%s)" % (lif, session_id))
    log("  filter    : %s" % (expr or "(none - EVERY packet on this interface)"))
    log("  duration  : %ds" % secs)
    log("  snaplen   : %s" % (CAP_SNAPLEN or "full packet"))
    log("  files     : %s[0..%d]  max %d MB" % (base, CAP_FILECOUNT - 1,
                                                CAP_FILESIZE * CAP_FILECOUNT))
    if not budget_ok(1):
        log("  Warning: the ring buffer is bigger than the free space here.")
    mark_start("cap-" + label, secs)
    if not edge_span_open(session_id, lif):
        die("failed to create span-%s. Check the LIF UUID." % session_id)
    # -Z root: tcpdump drops privileges otherwise and cannot write the next
    # file of the ring. timeout -s INT ends it by the clock.
    cmd = ["timeout", "-s", "INT", str(secs), "tcpdump", "-nei", "span-%s" % session_id,
           "-Z", "root", "-C", str(CAP_FILESIZE), "-W", str(CAP_FILECOUNT), "-w", base]
    if CAP_SNAPLEN:
        cmd += ["-s", CAP_SNAPLEN]
    if expr:
        cmd.append(expr)
    try:
        rc, out = sh(cmd, timeout=secs + 60)
        print("\n".join(out.strip().splitlines()[-4:]))
    finally:
        edge_span_close(session_id)
        mark_done("cap-" + label)
    log("done. files:")
    for name in sorted(os.listdir(os.path.dirname(base))):
        if name.startswith(os.path.basename(base)):
            full = os.path.join(os.path.dirname(base), name)
            print("    %9d  %s" % (os.path.getsize(full), full))


def edge_need_lif(key):
    if cget(key):
        return True
    print("REQUIRED setting is empty in %s:  %s" % (CONF_PATH, key))
    print("  It is the interface to capture on - there is no default.")
    print("  Let the tool find it:   python3 nsx-collector.py discover")
    print("  or by hand:  su admin -c \"get logical-router <SR-UUID> interfaces\"")
    print("  (addresses, ports and FILTER are optional - they may stay empty.)")
    return False


def edge_srs():
    out = []
    for key in ("T0_SR_UUID", "T1_VPC_SR_UUID", "T1_LB_SR_UUID"):
        out += values(cget(key))
    return out


def edge_stats_once():
    run = run_dir()
    run_info(run)
    d = os.path.join(run, "state")
    snap(os.path.join(d, "30-edge-interfaces.txt"), "get interfaces",
         ["su", "admin", "-c", "get interfaces"])
    snap(os.path.join(d, "32-edge-dataplane-cpu.txt"), "get dataplane cpu stats",
         ["su", "admin", "-c", "get dataplane cpu stats"])
    # "get interface <name>" - NOT "... stats", and there is no
    # "get interfaces stats" at all on NSX 4.2.4 ("% Command not found").
    # "get interface <name>" already holds RX/TX packets, bytes, errors and
    # drops per fastpath port, which is what was wanted.
    for port in names(cget("FP_PORTS")):
        snap(os.path.join(d, "33-edge-port-%s-stats.txt" % port),
             "get interface %s" % port,
             ["su", "admin", "-c", "get interface %s" % port])
    srs = edge_srs()
    if srs:
        for uuid in srs:
            short = uuid[:8]
            snap(os.path.join(d, "34-edge-router-%s-interface-stats.txt" % short),
                 "get logical-router %s interfaces stats" % uuid,
                 ["su", "admin", "-c", "get logical-router %s interfaces stats" % uuid])
            snap(os.path.join(d, "35-edge-router-%s-ha-state.txt" % short),
                 "get logical-router %s high-availability status" % uuid,
                 ["su", "admin", "-c", "get logical-router %s high-availability status" % uuid])
    else:
        log("  no T0/T1 SR UUID in the config - per router stats skipped")
        log("  (each router costs about 2.5 s per sample, so only what you name)")
    # "get system-stats" does not exist on NSX 4.2.4 either - these two do.
    snap(os.path.join(d, "36-edge-cpu.txt"), "get cpu-stats",
         ["su", "admin", "-c", "get cpu-stats"])
    snap(os.path.join(d, "37-edge-memory.txt"), "get memory",
         ["su", "admin", "-c", "get memory"])
    log("  state sample -> %s" % d)


def edge_sessions_once():
    run = run_dir()
    run_info(run)
    d = os.path.join(run, "session")
    ts = time.strftime("%H%M%S")
    # "get firewall <uuid> connection" wants the LOGICAL INTERFACE uuid, not
    # the service router uuid - with an SR uuid the CLI answers "% Invalid
    # value for argument <uuid>" and the file holds an error, not data.
    # Measured on NSX 4.2.4, and it is why v5 collected nothing useful here.
    for uuid in names(cget("LIF_LBT1_SVC")) + names(cget("LIF_VPCT1_UPLINK")) + names(cget("LIF_T0_UPLINK")) + names(cget("LIF_VPCT1_DOWNLINK")):
        short = uuid[:8]
        with open(os.path.join(d, "50-edge-fw-conn-count-%s-%s.txt" % (short, ts)), "w") as fh:
            fh.write(cli("get firewall %s connection count" % uuid))
        # The table shows the NAT mapping in brackets, which is exactly what
        # you want when a load balancer is in the path:
        #   0x..: 172.16.204.2:54982 -> 172.16.201.12:80 (172.16.204.10:80)
        with open(os.path.join(d, "51-edge-fw-conn-table-%s-%s.txt" % (short, ts)), "w") as fh:
            fh.write(cli("get firewall %s connection" % uuid))
    lbs = values(cget("LB_UUID"))
    if not lbs:
        log("  no LB_UUID - load balancer part skipped")
    for lb in lbs:
        snap(os.path.join(d, "52-edge-lb-status.txt"), "get load-balancer %s status" % lb,
             ["su", "admin", "-c", "get load-balancer %s status" % lb])
        snap(os.path.join(d, "53-edge-lb-stats.txt"), "get load-balancer %s stats" % lb,
             ["su", "admin", "-c", "get load-balancer %s stats" % lb])
        with open(os.path.join(d, "54-edge-lb-virtualservers-%s.txt" % ts), "w") as fh:
            fh.write(cli("get load-balancer %s virtual-servers" % lb))
        for pool in values(cget("LB_POOL_UUIDS")):
            snap(os.path.join(d, "55-edge-lb-pool-%s-status.txt" % pool[:8]),
                 "get load-balancer %s pool %s status" % (lb, pool),
                 ["su", "admin", "-c", "get load-balancer %s pool %s status" % (lb, pool)])
    log("  session sample -> %s" % d)


def edge_check():
    band("CHECK 1 of 3 - is this Edge ACTIVE for the routers you care about?")
    print("   The top 'state' line is this node. The 'Peer Routers' block at the")
    print("   bottom describes the OTHER node - reading that one gets it backwards.")
    print()
    any_set = False
    for label, key in (("T0", "T0_SR_UUID"), ("T1 VPC", "T1_VPC_SR_UUID"), ("T1 LB", "T1_LB_SR_UUID")):
        uuid = cget(key)
        if not uuid:
            continue
        any_set = True
        print("   %-8s %-40s %s" % (label, uuid, edge_ha_state(uuid)))
    if not any_set:
        print("   No SR UUID in the config - nothing to check.")
        print("   Fill it in with:  python3 nsx-collector.py discover")
    print()
    print("   A capture on a STANDBY Edge returns zero packets.")
    print()
    band("CHECK 2 of 3 - leftovers from an earlier run")
    rc, out = sh(["ip", "-br", "link"])
    spans = [l for l in out.splitlines() if "span" in l]
    print("\n".join("   " + l for l in spans) if spans else "   no span interface - good")
    print("   %-28s %d" % ("our captures running", len(capture_pids())))
    print()
    band("CHECK 3 of 3 - disk and filter")
    rc, out = sh(["df", "-h", os.path.dirname(OUT) or "/"])
    print("\n".join("   " + l for l in out.strip().splitlines()))
    filter_report()


# ===========================================================================
#  ===========================  ESXi  ===========================
# ===========================================================================
def esxi_vms():
    return names(cget("WORKER_VMS"))


def esxi_vnic_for(vm):
    """WORKER_VNIC is a list and may be mixed: "eth0 web02:eth2,eth3"."""
    default, hit = [], []
    for tok in names(cget("WORKER_VNIC")):
        tok = tok.replace(".", ":", 1) if ("." in tok and ":" not in tok) else tok
        if ":" in tok:
            name, nics = tok.split(":", 1)
            if name == vm:
                hit += nics.split(",")
        else:
            default.append(tok)
    return hit or default


def esxi_filters(vm, want=None):
    """The DFW filter name(s) of a VM - one per vNIC."""
    rc, out = sh(["summarize-dvfilter"])
    found, in_vm = [], False
    for line in out.splitlines():
        f = line.split()
        if f and f[0] == "world":
            in_vm = len(f) > 2 and f[2] == "vmm0:" + vm
        if in_vm and "vmware-sfw." in line and len(f) > 1:
            name = f[1]
            if not want:
                found.append(name)
            else:
                for nic in want:
                    if "-%s-" % nic in name:
                        found.append(name)
                        break
    return found


def esxi_all_filters():
    if not IS_ESXI:
        return []
    out = []
    for vm in esxi_vms():
        out += esxi_filters(vm, esxi_vnic_for(vm))
    return out


def esxi_nic_of(filter_name):
    return re.sub(r"-vmware-sfw.*$", "", re.sub(r"^nic-\d+-", "", filter_name))


def esxi_host_vms():
    """Every VM that has a DFW filter on this host - for discovery."""
    rc, out = sh(["summarize-dvfilter"])
    vms = []
    cur = None
    for line in out.splitlines():
        f = line.split()
        if f and f[0] == "world":
            cur = f[2][5:] if len(f) > 2 and f[2].startswith("vmm0:") else None
        if cur and "vmware-sfw." in line:
            vms.append(cur)
            cur = None
    return sorted(set(vms))


def esxi_port_of(vm, nic):
    rc, out = sh(["net-stats", "-l"])
    for line in out.splitlines():
        f = line.split()
        if f and f[-1] == "%s.%s" % (vm, nic):
            return f[0]
    return "?"


def esxi_need_vms():
    if esxi_vms():
        return True
    print("REQUIRED setting is empty in %s:  WORKER_VMS" % CONF_PATH)
    print("  Nothing per VM is collected without it - no capture, no flows.")
    print("  Let the tool find the VMs:   python3 nsx-collector.py discover")
    print("  (addresses, ports and FILTER are optional - they may stay empty.)")
    return False


def esxi_map():
    print("%-30s %-6s %-36s %s" % ("VM", "vNIC", "DFW filter", "port"))
    for vm in esxi_vms():
        want = esxi_vnic_for(vm)
        flts = esxi_filters(vm, want)
        if not flts:
            has = [esxi_nic_of(f) for f in esxi_filters(vm)]
            if want and has:
                print("%-30s (here, but no vNIC matches %s; has: %s)" % (vm, want, " ".join(has)))
            else:
                print("%-30s (not on this host)" % vm)
            continue
        for flt in flts:
            nic = esxi_nic_of(flt)
            print("%-30s %-6s %-36s %s" % (vm, nic, flt, esxi_port_of(vm, nic)))


def esxi_timeout_prefix(secs):
    """busybox: old builds want "-t SECS", new ones "-s SIG SECS"."""
    if sh(["timeout", "-t", "1", "-s", "INT", "true"])[0] == 0:
        return ["timeout", "-t", str(secs), "-s", "INT"]
    if sh(["timeout", "-s", "INT", "1", "true"])[0] == 0:
        return ["timeout", "-s", "INT", str(secs)]
    return []


def esxi_spec_opt(spec):
    if spec == "none":
        return []
    key, val = spec.split(":", 1)
    return ["--" + key, val]


def esxi_spec_tag(spec):
    if spec == "none":
        return ""
    key, val = spec.split(":", 1)
    return {"proto:0x11": "-udp", "proto:0x06": "-tcp", "proto:0x01": "-icmp"}.get(
        spec, {"udpport": "-u" + val, "tcpport": "-t" + val, "ip": "-ip" + val,
               "srcip": "-src" + val.replace("/", "_"),
               "dstip": "-dst" + val.replace("/", "_")}.get(key, ""))


def esxi_option_specs():
    """The pktcap-uw option combinations, used when FILTER is empty.
    pktcap-uw ANDs its options and has no "or", so every combination is its
    own capture and its own file."""
    protos, icmp = [], False
    for tok in values(cget("PROTO")):
        low = tok.lower()
        if low == "udp":
            protos.append("udp")
        elif low == "tcp":
            protos.append("tcp")
        elif low == "icmp":
            icmp = True
        else:
            die("PROTO: '%s' - use udp / tcp / icmp, or leave it empty" % tok)
    ports = []
    for tok in values(cget("NODE_PORT")) + values(cget("PORTS")):
        if not tok.isdigit() or not 1 <= int(tok) <= 65535:
            die("port '%s' is not a port number" % tok)
        ports.append(tok)
    pspecs = []
    if ports:
        for proto in (protos or ["udp", "tcp"]):
            for port in ports:
                pspecs.append("%sport:%s" % (proto, port))
    elif protos:
        for proto in protos:
            pspecs.append("proto:" + {"udp": "0x11", "tcp": "0x06"}[proto])
    elif not icmp:
        pspecs.append("none")
    if icmp:
        pspecs.append("proto:0x01")
    ispecs = []
    for tok in values(cget("LB_SNAT_IP")) + values(cget("HOSTS")):
        if "/" in tok:
            ispecs += ["srcip:" + tok, "dstip:" + tok]    # --ip takes no range
        else:
            ispecs.append("ip:" + tok)
    return pspecs, ispecs or ["none"]


def esxi_capture(stage, secs):
    if stage not in ("pre", "post"):
        die("stage must be pre or post")
    if not esxi_need_vms():
        sys.exit(2)
    mkout()
    run = run_dir()
    run_info(run)
    num = "20" if stage == "pre" else "21"
    tmo = esxi_timeout_prefix(secs)
    if not tmo:
        log("  WARNING: no usable 'timeout' here - stop the capture with: "
            "python3 nsx-collector.py stop")
    snap_opt = ["-s", CAP_SNAPLEN] if CAP_SNAPLEN else []
    targets = []
    for vm in esxi_vms():
        for flt in esxi_filters(vm, esxi_vnic_for(vm)):
            targets.append((vm, flt))
    if not targets:
        die("no target VM on this host. Check WORKER_VMS (python3 nsx-collector.py map).")

    procs = []
    if filter_set():
        expr = filter_for("dfw")
        ok, msg = filter_check(expr)
        if not ok:
            filter_problem(expr, msg)
            sys.exit(2)
        if not budget_ok(len(targets), shrink=True):
            die("not enough room - see the numbers above. Lower CAP_FILESIZE/"
                "CAP_FILECOUNT, or put OUT on a datastore.")
        mark_start("cap-" + stage, secs)
        log("DFW %s capture %ds   filter: %s" % (stage, secs, expr))
        for vm, flt in targets:
            nic = esxi_nic_of(flt)
            out_file = os.path.join(run, "pcap", "%s-dfw-%s-%s-%s.pcap" % (num, stage, vm, nic))
            log("  %s (%s) -> %s" % (vm, nic, out_file))
            # pktcap-uw has no BPF, so the expression is applied by tcpdump-uw.
            # One file per vNIC and stage - no file explosion.
            inner = (" ".join(tmo) + " pktcap-uw --dvfilter %s --stage %s %s -o - 2>/dev/null"
                     % (flt, stage, " ".join(snap_opt)))
            cmd = ("echo Y | %s | tcpdump-uw -r - -w %s -C %d -W %d '%s' >/dev/null 2>&1"
                   % (inner, out_file, CAP_FILESIZE, CAP_FILECOUNT, expr))
            procs.append(subprocess.Popen(["sh", "-c", cmd]))
    else:
        pspecs, ispecs = esxi_option_specs()
        ncap = len(targets) * len(pspecs) * len(ispecs)
        if not budget_ok(ncap, shrink=True):
            die("not enough room - see the numbers above. Lower CAP_FILESIZE/"
                "CAP_FILECOUNT, or put OUT on a datastore.")
        mark_start("cap-" + stage, secs)
        if pspecs == ["none"] and ispecs == ["none"]:
            log("DFW %s capture %ds   filter: NONE - every packet on the vNIC" % (stage, secs))
        else:
            log("DFW %s capture %ds   %d x %d combination(s) per vNIC"
                % (stage, secs, len(pspecs), len(ispecs)))
            log("  (pktcap-uw has no 'or' - one capture per combination. Set FILTER")
            log("   in the config for ONE file per vNIC with a full expression.)")
        for vm, flt in targets:
            nic = esxi_nic_of(flt)
            for ps in pspecs:
                for isp in ispecs:
                    opts = esxi_spec_opt(ps) + esxi_spec_opt(isp)
                    out_file = os.path.join(run, "pcap", "%s-dfw-%s-%s-%s%s%s.pcap"
                                            % (num, stage, vm, nic,
                                               esxi_spec_tag(ps), esxi_spec_tag(isp)))
                    log("  %s (%s) [%s] -> %s" % (vm, nic, " ".join(opts) or "no filter", out_file))
                    cmd = ("echo Y | %s pktcap-uw --dvfilter %s --stage %s %s %s -C %d -W %d -o %s "
                           ">/dev/null 2>&1" % (" ".join(tmo), flt, stage, " ".join(opts),
                                                " ".join(snap_opt), CAP_FILESIZE,
                                                CAP_FILECOUNT, out_file))
                    procs.append(subprocess.Popen(["sh", "-c", cmd]))

    # pktcap-uw output goes to /dev/null, so a bad option would fail silently.
    time.sleep(2)
    dead = sum(1 for p in procs if p.poll() is not None)
    if dead:
        log("  WARNING: started %d capture(s), %d stopped at once (%d running)."
            % (len(procs), dead, len(procs) - dead))
        log("           run one by hand to see the error.")
    else:
        log("  %d capture(s) running" % len(procs))
    log("ends by itself after %ds.  collect: scp -r root@%s:%s ."
        % (secs, os.uname().nodename, run))


def esxi_dfw_once():
    run = run_dir()
    run_info(run)
    d = os.path.join(run, "session")
    ts = time.strftime("%H%M%S")
    full = os.environ.get("FULL_HOST") == "1"
    rc, out = sh(["summarize-dvfilter"])
    if not full:
        keep, lines = False, []
        wanted = set("vmm0:" + vm for vm in esxi_vms())
        for line in out.splitlines():
            f = line.split()
            if f and f[0] == "world":
                keep = len(f) > 2 and f[2] in wanted
            if keep:
                lines.append(line)
        out = "\n".join(lines)
    with open(os.path.join(d, "60-dfw-filter-list.txt"), "a") as fh:
        fh.write("########## %s ##########\n%s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), out))
    if not esxi_need_vms():
        return
    for vm in esxi_vms():
        for flt in esxi_filters(vm, esxi_vnic_for(vm)):
            nic = esxi_nic_of(flt)
            tag = "%s-%s" % (vm, nic)
            rc, flows = sh(["vsipioctl", "getflows", "-f", flt])
            with open(os.path.join(d, "61-dfw-flows-%s-%s.txt" % (tag, ts)), "w") as fh:
                fh.write(flows)
            snap(os.path.join(d, "62-dfw-rules-%s.txt" % tag), "vsipioctl getrules",
                 ["vsipioctl", "getrules", "-f", flt])
            snap(os.path.join(d, "63-dfw-passdrop-%s.txt" % tag), "vsipioctl getfilterstat",
                 ["vsipioctl", "getfilterstat", "-f", flt])
            rc, stat = sh(["vsipioctl", "getfilterstat", "-f", flt])
            counters = [l.strip() for l in stat.splitlines() if re.match(r"v4 (pass|drop)", l.strip())]
            nflows = sum(1 for l in flows.splitlines() if l[:1].isdigit())
            with open(os.path.join(d, "69-dfw-summary.txt"), "a") as fh:
                fh.write("########## %s %s (%s) ##########\n  total flows : %d\n%s\n\n"
                         % (ts, vm, nic, nflows, "\n".join("  " + c for c in counters)))
    log("  DFW sample -> %s" % d)


def esxi_stats_once():
    run = run_dir()
    run_info(run)
    d = os.path.join(run, "state")
    rc, out = sh(["net-stats", "-l"])
    if os.environ.get("FULL_HOST") != "1":
        wanted = set(esxi_vms())
        lines = out.splitlines()
        head = lines[:1]
        body = [l for l in lines[1:] if l.split() and l.split()[-1].split(".")[0] in wanted]
        out = "\n".join(head + body)
    with open(os.path.join(d, "40-esxi-switchport-list.txt"), "a") as fh:
        fh.write("########## %s ##########\n%s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), out))
    for nic in names(cget("UPLINK_NICS")):
        snap(os.path.join(d, "41-esxi-uplink-%s-stats.txt" % nic),
             "esxcli network nic stats get -n %s" % nic,
             ["esxcli", "network", "nic", "stats", "get", "-n", nic])
    for vm in esxi_vms():
        for flt in esxi_filters(vm, esxi_vnic_for(vm)):
            port = esxi_port_of(vm, esxi_nic_of(flt))
            if port == "?":
                continue
            snap(os.path.join(d, "42-esxi-vmport-%s-%s-stats.txt" % (vm, port)),
                 "net-stats -A -t vW -p %s" % port,
                 ["net-stats", "-A", "-t", "vW", "-p", port, "-i", "1", "-n", "1"])
    log("  state sample -> %s" % d)


def esxi_check():
    band("CHECK 1 of 3 - are the target VMs on this host?")
    print()
    if esxi_vms():
        esxi_map()
    else:
        print("   WORKER_VMS is empty. VMs with a DFW filter on this host:")
        for vm in esxi_host_vms():
            print("     " + vm)
        print("   Fill them in with:  python3 nsx-collector.py discover")
    print()
    band("CHECK 2 of 3 - leftovers from an earlier run")
    print("   %-28s %d" % ("our captures running", len(capture_pids())))
    print()
    band("CHECK 3 of 3 - disk and filter")
    print("   free in %-22s %s MB" % (OUT, free_mb(OUT)))
    if on_ramdisk(OUT):
        print("   %s is the ESXi RAMDISK (about 250 MB). Keep the capture small," % OUT)
        print("   or point OUT at a datastore for a long window.")
    filter_report()


# ===========================================================================
#  DISCOVER - fill the config in from the box itself
# ===========================================================================
def pick(prompt, rows, allow_multi=False, allow_skip=True):
    """rows: [(value, label)] - returns a list of chosen values."""
    if not rows:
        print("   nothing found")
        return []
    for i, (_val, label) in enumerate(rows, 1):
        print("   %2d) %s" % (i, label))
    if allow_skip:
        print("    s) skip")
    while True:
        raw = ask("   %s " % prompt).strip().lower()
        if raw in ("s", "") and allow_skip:
            return []
        nums = [n for n in re.split(r"[\s,]+", raw) if n]
        try:
            idx = [int(n) for n in nums]
        except ValueError:
            print("   number please")
            continue
        if any(n < 1 or n > len(rows) for n in idx):
            print("   out of range")
            continue
        if not allow_multi and len(idx) > 1:
            print("   one only")
            continue
        return [rows[n - 1][0] for n in idx]


def discover_edge():
    band("DISCOVER - reading this Edge")
    print("   Nothing is changed until you say yes at the end.")
    print()
    updates = {}

    routers = edge_routers()
    t0 = [r for r in routers if r[2] == "SERVICE_ROUTER_TIER0"]
    t1 = [r for r in routers if r[2] == "SERVICE_ROUTER_TIER1"]
    print("   %d service router(s) on this Edge" % (len(t0) + len(t1)))
    print()

    lbs = edge_load_balancers()
    if lbs:
        print("   Load balancers:")
        rows = []
        for lb in lbs:
            vss = edge_virtual_servers(lb["uuid"])
            vips = ", ".join("%s:%s/%s" % (v["ip"], v["port"], v["proto"]) for v in vss[:3] if v["ip"])
            rows.append((lb, "%-34s %s" % (lb["name"][:34], vips or "(no virtual server)")))
        chosen = pick("which load balancer? [number/s]", rows)
        if chosen:
            lb = chosen[0]
            updates["LB_UUID"] = lb["uuid"]
            if lb["sr"]:
                updates["T1_LB_SR_UUID"] = lb["sr"]
                for iface in edge_interfaces(lb["sr"]):
                    if iface["type"] == "service":
                        updates["LIF_LBT1_SVC"] = iface["uuid"]
                        print("   -> LB T1 service interface %s (%s)" % (iface["uuid"], iface["ip"]))
                        break
                print("   -> LB T1 service router %s  HA state: %s"
                      % (lb["sr"], edge_ha_state(lb["sr"])))
            vss = edge_virtual_servers(lb["uuid"])
            rows = [(v, "%-22s %-16s %s/%s" % (v["name"][:22], v["ip"], v["proto"], v["port"]))
                    for v in vss if v["ip"]]
            print()
            print("   Virtual servers of that load balancer:")
            picked = pick("which virtual server(s)? [number/s]", rows, allow_multi=True)
            if picked:
                updates["VIP"] = " ".join(v["ip"] for v in picked)
                updates["SVC_PORT"] = " ".join(sorted(set(v["port"] for v in picked)))
                protos = sorted(set(v["proto"].lower() for v in picked))
                updates["PROTO"] = " ".join(protos)
                pools = [v["pool"] for v in picked if v["pool"]]
                updates["LB_POOL_UUIDS"] = " ".join(sorted(set(pools)))
                snats, nodeports = [], []
                for pool in sorted(set(pools)):
                    info = edge_pool(lb["uuid"], pool)
                    if info["snat"]:
                        snats.append(info["snat"])
                    for _ip, port in info["members"]:
                        nodeports.append(port)
                if snats:
                    updates["LB_SNAT_IP"] = " ".join(sorted(set(snats)))
                    print("   -> LB SNAT %s" % updates["LB_SNAT_IP"])
                if nodeports:
                    updates["NODE_PORT"] = " ".join(sorted(set(nodeports)))
                    print("   -> backend port(s) %s" % updates["NODE_PORT"])
    print()
    if t1:
        print("   Other T1 service routers - pick the one in front of the LB")
        print("   (its uplink is where traffic arrives before NAT):")
        rows = []
        for uuid, name, _t in t1:
            if uuid == updates.get("T1_LB_SR_UUID"):
                continue
            rows.append(((uuid, name), "%-34s %s" % (name[:34], uuid)))
        chosen = pick("which T1? [number]", rows)
        if chosen:
            uuid, _name = chosen[0]
            updates["T1_VPC_SR_UUID"] = uuid
            for iface in edge_interfaces(uuid):
                if iface["type"] == "uplink":
                    updates["LIF_VPCT1_UPLINK"] = iface["uuid"]
                    print("   -> VPC T1 uplink interface %s (%s)" % (iface["uuid"], iface["ip"]))
                    break
    if t0:
        updates["T0_SR_UUID"] = t0[0][0]
        print("   -> T0 service router %s" % t0[0][0])
    return updates


def discover_esxi():
    band("DISCOVER - reading this host")
    print("   Nothing is changed until you say yes at the end.")
    print()
    updates = {}
    vms = esxi_host_vms()
    unusable = [v for v in vms if " " in v]
    vms = [v for v in vms if " " not in v]
    if unusable:
        print("   NOT offered - the name has a space in it, which a space")
        print("   separated list cannot hold. Rename the VM or capture it by")
        print("   hand (python3 nsx-collector.py map shows the filter names):")
        for v in unusable:
            print("     %s" % v)
        print()
    print("   VMs with a DFW filter on this host:")
    rows = [(vm, vm) for vm in vms]
    picked = pick("which VMs are the backend? [numbers, or 'a' for all]", rows, allow_multi=True) \
        if vms else []
    if not picked and vms:
        answer = ask("   all of them? [y/N] ").lower()
        if answer.startswith("y"):
            picked = vms
    if picked:
        updates["WORKER_VMS"] = " ".join(picked)
        print()
        for vm in picked:
            for flt in esxi_filters(vm):
                nic = esxi_nic_of(flt)
                print("   %-20s %-6s %-36s port %s" % (vm, nic, flt, esxi_port_of(vm, nic)))
    print()
    rc, out = sh(["esxcli", "network", "nic", "list"])
    ups = []
    for line in out.splitlines()[2:]:
        f = line.split()
        if len(f) >= 5 and f[0].startswith("vmnic") and "Up" in line:
            ups.append(f[0])
    if ups:
        updates["UPLINK_NICS"] = " ".join(ups)
        print("   -> uplink NICs that are Up: %s" % updates["UPLINK_NICS"])
    return updates


def action_discover():
    updates = discover_edge() if IS_EDGE else discover_esxi()
    updates = {k: v for k, v in updates.items() if v}
    print()
    if not updates:
        print("   nothing to write.")
        return
    band("PROPOSED CONFIG")
    for key in sorted(updates):
        old = cget(key)
        mark = " " if old == updates[key] else "*"
        print("  %s %-18s %s%s" % (mark, key, updates[key],
                                   ("      (was: %s)" % old) if old and old != updates[key] else ""))
    print()
    print("   * = changed. Nothing else in the file is touched, comments stay.")
    if not ask("   write this into %s? [y/N] " % os.path.basename(CONF_PATH)).lower().startswith("y"):
        print("   nothing written.")
        return
    backup = conf_write(CONF_PATH, updates)
    print("   written. Backup of the original: %s" % backup)
    print("   Check it with:  python3 nsx-collector.py config")


# ===========================================================================
#  common actions
# ===========================================================================
def filter_problem(expr, msg):
    print("FILTER is not a valid pcap expression:")
    for line in msg.splitlines():
        print("    " + line)
    print("    expression: %s" % expr)
    print("  Remember: and/or have the same precedence, left to right. Use ( ).")
    print('  Examples: FILTER="host 10.1.1.10 and (udp port 1812 or udp port 1813)"')
    print('            FILTER="net 10.1.1.0/28 and not tcp port 22"')


def filter_report():
    print()
    points = [("LB T1", "lbt1"), ("VPC T1", "vpct1")] if IS_EDGE else [("ESXi DFW", "dfw")]
    if filter_set():
        print("   FILTER (free expression) is set - it wins over the single fields.")
    else:
        print("   FILTER is empty - the filter is built from the single fields:")
    ok_all = True
    for label, point in points:
        expr = filter_for(point)
        print("   %-10s %s" % (label, expr or "(no filter - every packet)"))
        ok, msg = filter_check(expr)
        if not ok:
            filter_problem(expr, msg)
            ok_all = False
    if ok_all:
        print("   syntax: OK")
    if not filter_set() and IS_ESXI:
        pspecs, ispecs = esxi_option_specs()
        targets = sum(len(esxi_filters(vm, esxi_vnic_for(vm))) for vm in esxi_vms())
        print("   ESXi option mode: %d x %d combination(s) x %d vNIC(s) = %d file(s) per stage"
              % (len(pspecs), len(ispecs), targets, len(pspecs) * len(ispecs) * targets))
        print("   (set FILTER for one file per vNIC instead)")
    return ok_all


def action_config():
    band("CONFIG   nsx-collector %s   platform: %s" % (VERSION, PLAT))
    print("   %-16s %s" % ("config file", CONF_PATH))
    print("   %-16s %s" % ("case", CASE_ID or "(none)"))
    print("   %-16s %s" % ("tag", TAG))
    print("   %-16s %s" % ("output", OUT))
    print("   %-16s %ds, ring %dMB x %d, snaplen %s"
          % ("capture", CAP_SECS, CAP_FILESIZE, CAP_FILECOUNT, CAP_SNAPLEN or "full"))
    print("   %-16s every %ds for %ds" % ("polling", INTERVAL, DURATION))
    filter_report()
    print()
    thin()
    if IS_EDGE:
        print("   Capture interfaces - REQUIRED, at least one:")
        print("   %-16s %s" % ("LB T1 service", cget("LIF_LBT1_SVC") or "EMPTY - that capture will not run"))
        print("   %-16s %s" % ("VPC T1 uplink", cget("LIF_VPCT1_UPLINK") or "EMPTY - that capture will not run"))
        print("   Routers / LB to collect state for - empty means skipped:")
        for label, key in (("T0", "T0_SR_UUID"), ("T1 VPC", "T1_VPC_SR_UUID"),
                           ("T1 LB", "T1_LB_SR_UUID"), ("LB", "LB_UUID")):
            print("   %-16s %s" % (label, cget(key) or "(none)"))
    else:
        print("   Target VMs - REQUIRED:")
        print("   %-16s %s" % ("WORKER_VMS", cget("WORKER_VMS") or "EMPTY - nothing will be collected"))
        print("   %-16s %s" % ("WORKER_VNIC", cget("WORKER_VNIC") or "(all vNICs)"))
        print("   %-16s %s" % ("UPLINK_NICS", cget("UPLINK_NICS") or "(none)"))
    print()
    print("   Edit the file, or let the tool fill it in:  python3 nsx-collector.py discover")


def action_selftest():
    band("SELF TEST")
    bad = 0
    print("   %-34s %s" % ("platform", PLAT))
    print("   %-34s %s" % ("python", sys.version.split()[0]))
    print("   %-34s %s" % ("running as root", "OK" if os.geteuid() == 0 else "NO"))
    tools = ["pktcap-uw", "vsipioctl", "summarize-dvfilter", "net-stats", "tcpdump-uw"] \
        if IS_ESXI else ["tcpdump", "ip", "pgrep"]
    for tool in tools:
        found = have(tool)
        print("   %-34s %s" % (tool, "found" if found else "MISSING"))
        bad += 0 if found else 1
    if IS_ESXI:
        tmo = esxi_timeout_prefix(1)
        print("   %-34s %s" % ("timeout syntax", " ".join(tmo) if tmo else "none - captures will not self-stop"))
        bad += 0 if tmo else 1
        n = len(esxi_all_filters())
        print("   %-34s %d vNIC(s)" % ("target VMs on this host", n))
        bad += 0 if n else 1
    else:
        ok = "get version" in cli("get version") or "Version" in cli("get version")
        rc, out = sh(["su", "admin", "-c", "get version"])
        ok = rc == 0 and bool(out.strip())
        print("   %-34s %s" % ("NSX CLI (su admin)", "OK" if ok else "FAILED"))
        bad += 0 if ok else 1
        has_lif = bool(cget("LIF_LBT1_SVC") or cget("LIF_VPCT1_UPLINK"))
        print("   %-34s %s" % ("capture interface set", "yes" if has_lif else "NO - no capture can run"))
        bad += 0 if has_lif else 1
    try:
        os.makedirs(OUT, exist_ok=True)
        writable = os.access(OUT, os.W_OK)
    except OSError:
        writable = False
    print("   %-34s %s (%s)" % ("output dir writable", "OK" if writable else "NO", OUT))
    bad += 0 if writable else 1
    print("   %-34s %s MB (floor %d MB)" % ("free space", free_mb(OUT), MIN_FREE_MB))
    points = ("lbt1", "vpct1") if IS_EDGE else ("dfw",)
    ok = all(filter_check(filter_for(p))[0] for p in points)
    print("   %-34s %s" % ("filter expression", "OK" if ok else "INVALID"))
    bad += 0 if ok else 1
    print()
    print("   ALL GOOD - ready to collect." if bad == 0
          else "   Something above needs fixing before the real window.")
    return 0 if bad == 0 else 1


def action_rehearse():
    band("REHEARSAL - one sample of everything except the capture")
    print("   Proves the config is right before you commit to the real window.")
    print()
    mkout()
    if IS_EDGE:
        edge_stats_once()
        edge_sessions_once()
    else:
        esxi_stats_once()
        esxi_dfw_once()
    print()
    band("WHAT IT PRODUCED")
    run = latest_run()
    files = []
    for base, _dirs, names in os.walk(run or OUT):
        for name in names:
            files.append(os.path.join(base, name))
    for path in sorted(files)[:30]:
        print("   " + path)
    print("   ... %d file(s) in total" % len(files))
    print()
    print("   Clear it before the real run:   python3 nsx-collector.py wipe")


def start_one(action, logname, run):
    logfile = os.path.join(LOGDIR, "nsxc-%s.log" % logname)
    print("   $ nohup python3 %s %s > %s 2>&1 &" % (SELF, action, logfile))
    env = dict(os.environ, NSXC_RUN=run)
    with open(logfile, "w") as fh:
        subprocess.Popen([sys.executable, SELF, action], stdout=fh, stderr=fh,
                         stdin=subprocess.DEVNULL, env=env, start_new_session=True)
    time.sleep(1)


def action_start():
    band("START - all collectors")
    print("   Captures stop by themselves after CAP_SECS (%ds)." % CAP_SECS)
    print("   Polling runs for DURATION (%ds)." % DURATION)
    print()
    if not filter_report():
        die("fix FILTER in the config first - nothing was started.")
    print()
    mkout()
    run = run_dir()
    run_info(run)
    print("   results -> %s" % run)
    print()
    if IS_EDGE:
        if cget("LIF_LBT1_SVC"):
            start_one("cap-lbt1", "lbt1", run)
        else:
            print("   LB T1 capture NOT started: LIF_LBT1_SVC is empty (required for it)")
        if cget("LIF_VPCT1_UPLINK"):
            start_one("cap-vpct1", "vpct1", run)
        else:
            print("   VPC T1 capture NOT started: LIF_VPCT1_UPLINK is empty (required for it)")
        if not (cget("LIF_LBT1_SVC") or cget("LIF_VPCT1_UPLINK")):
            print()
            print("   *** NO PACKET CAPTURE WILL RUN - both LIF_* are empty. ***")
            print("   Fill them in:  python3 nsx-collector.py discover")
            print()
        start_one("stats-run", "stats", run)
        start_one("sess-run", "sess", run)
        time.sleep(5)
        rc, out = sh(["ip", "-br", "link"])
        spans = [l for l in out.splitlines() if "span" in l]
        print("\n".join("   " + l for l in spans) if spans
              else "   no span yet - give it a few seconds")
    else:
        if not esxi_need_vms():
            print()
            print("   *** NOTHING WILL BE COLLECTED - WORKER_VMS is empty. ***")
            print()
        start_one("cap-pre", "pre", run)
        start_one("cap-post", "post", run)
        start_one("stats-run", "stats", run)
        start_one("dfw-run", "dfw", run)
        time.sleep(5)
    print("   Logs: %s/nsxc-*.log" % LOGDIR)
    print()
    action_status()


def action_status():
    band("STATUS   %s" % time.strftime("%Y-%m-%d %H:%M:%S"))
    now = int(time.time())
    if os.path.isdir(OUT):
        for name in sorted(os.listdir(OUT)):
            if not name.startswith(".nsxc-end-"):
                continue
            with open(os.path.join(OUT, name)) as fh:
                val = fh.read().strip()
            label = name[len(".nsxc-end-"):]
            if val == "done":
                print("   %-12s finished" % label)
            else:
                try:
                    left = int(val) - now
                except ValueError:
                    continue
                print("   %-12s %dm %02ds left" % (label, max(0, left) // 60, max(0, left) % 60))
    print("   %-12s %d process(es) running" % ("captures", len(capture_pids())))
    print("   %-12s %d running" % ("pollers", len(poller_pids())))
    print("   %-12s %s MB" % ("free", free_mb(OUT)))
    run = latest_run()
    print()
    if run and os.path.isdir(run):
        print("   run directory: %s" % run)
        for sub in ("pcap", "state", "session"):
            path = os.path.join(run, sub)
            files = os.listdir(path) if os.path.isdir(path) else []
            size = sum(os.path.getsize(os.path.join(path, f)) for f in files) // 1024
            print("     %-8s %3d file(s)  %d KB" % (sub, len(files), size))
        pcap = os.path.join(run, "pcap")
        for name in sorted(os.listdir(pcap))[:8] if os.path.isdir(pcap) else []:
            print("     %9d  %s" % (os.path.getsize(os.path.join(pcap, name)), name))
    else:
        print("   nothing collected yet in %s" % OUT)


def action_watch(interval=10):
    while True:
        os.system("clear 2>/dev/null || printf '\\n\\n'")
        action_status()
        print()
        print("   refreshing every %ds - Ctrl+C to stop" % interval)
        time.sleep(interval)


def wipe_files():
    if OUT in ("/", "/tmp", "/var", "/var/dump", ""):
        die("refusing to delete %s" % OUT)
    log("deleting our own run directories under %s" % OUT)
    for run in glob_runs():
        if not os.path.exists(os.path.join(run, RUN_INFO_NAME)):
            log("  skipped %s (no %s - not ours)" % (run, RUN_INFO_NAME))
            continue
        shutil.rmtree(run, ignore_errors=True)
        log("  removed %s" % run)
    for name in os.listdir(OUT) if os.path.isdir(OUT) else []:
        if name.startswith(".nsxc-"):
            os.remove(os.path.join(OUT, name))
    try:
        os.rmdir(OUT)
    except OSError:
        pass
    log("done")


def action_stop(mode="keep", dry=False):
    """mode: keep | delete.  Safe on a production box:
    - only OUR processes are signalled, matched by what they write
    - captures get SIGINT first so the pcap closes cleanly
    - a span session is released only if it mirrors a LIF from this config
    - files are deleted only from directories holding our own run info,
      and never while a collector is still running
    - --dry-run shows every decision and changes nothing"""
    band("DRY RUN - nothing will be stopped or deleted" if dry else "STOP - our collectors only")
    rc = 0
    pollers, captures = poller_pids(), capture_pids()
    for pid in pollers:
        print("   poller   %s  %s" % (pid, ps_line(pid)))
        if not dry:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
    for pid in captures:
        print("   capture  %s  %s" % (pid, ps_line(pid)))
        if not dry:
            try:
                os.kill(pid, signal.SIGINT)      # closes the pcap file
            except OSError:
                pass
    if not pollers and not captures:
        print("   nothing of ours is running")

    if not dry and (pollers or captures):
        print("   waiting for them to close their files ...")
        for escalation, sig in ((15, signal.SIGTERM), (10, signal.SIGKILL)):
            waited = 0
            while waited < escalation:
                if not our_pids():
                    break
                time.sleep(1)
                waited += 1
            left = our_pids()
            if not left:
                break
            print("   still there - %s, our pids only"
                  % ("asking again (TERM)" if sig == signal.SIGTERM else "last resort (KILL)"))
            for pid in left:
                try:
                    os.kill(pid, sig)
                except OSError:
                    pass
        if our_pids():
            rc = 1

    if IS_EDGE:
        print()
        for session_id in (cget("CAP_SESSION_LBT1") or "1", cget("CAP_SESSION_VPCT1") or "0"):
            owner = edge_span_owner(session_id)
            if owner == "ours":
                if dry:
                    print("   span session %s mirrors our LIF -> would be released" % session_id)
                else:
                    edge_span_close(session_id)
                    print("   span session %s released (it mirrored our LIF)" % session_id)
            elif owner == "empty":
                print("   span session %s is empty - nothing to release" % session_id)
            else:
                print("   span session %s mirrors an interface that is NOT in this config." % session_id)
                print("      LEFT ALONE - somebody else is capturing there.")
        print("   reminder: run the same stop on the other Edge of the cluster -")
        print("   a span session created here exists on both nodes.")

    print()
    if mode == "delete":
        if dry:
            for run in glob_runs():
                nfiles = sum(len(f) for _r, _d, f in os.walk(run))
                if os.path.exists(os.path.join(run, RUN_INFO_NAME)):
                    print("   would delete %s  (%d files)" % (run, nfiles))
                else:
                    print("   would SKIP   %s  (not ours)" % run)
        elif our_pids():
            print("   NOT deleting anything - %d of our processes are still running." % len(our_pids()))
            rc = 1
        else:
            wipe_files()
    else:
        print("   files kept. Delete them later with:  python3 nsx-collector.py wipe")

    print()
    band("STATE NOW - nothing above was carried out" if dry else "AFTER - what is left")
    left = our_pids()
    for pid in left:
        print("   STILL RUNNING: %s  %s" % (pid, ps_line(pid)))
    if not left:
        print("   our processes            none")
    else:
        rc = 1
    if IS_EDGE:
        rc2, out = sh(["ip", "-br", "link"])
        spans = [l for l in out.splitlines() if "span" in l]
        if spans:
            print("   span interfaces still present:")
            for line in spans:
                print("     " + line)
            print("     (one that is not ours belongs to another session - see above)")
        else:
            print("   span interfaces          none")
    run = latest_run()
    if run and os.path.isdir(run):
        nfiles = sum(len(f) for _r, _d, f in os.walk(run))
        print("   collected data           %s  (%d files)" % (run, nfiles))
    else:
        print("   collected data           none left in %s" % OUT)
    print()
    if dry:
        print("   DRY RUN - nothing was stopped or deleted. Run it without --dry-run.")
        return 0
    print("   CLEAN - nothing of ours is left running." if rc == 0
          else "   NOT CLEAN - see the lines above.")
    return rc


def poll_loop(action):
    mkout()
    label = {"stats-run": "stats", "sess-run": "sess", "dfw-run": "dfw"}[action]
    log("start - every %ds for %ds -> %s" % (INTERVAL, DURATION, OUT))
    mark_start(label, DURATION)
    end = time.time() + DURATION
    n = 0
    while time.time() < end:
        if not space_ok():
            break
        n += 1
        if action == "stats-run":
            edge_stats_once() if IS_EDGE else esxi_stats_once()
        elif action == "sess-run":
            edge_sessions_once()
        else:
            esxi_dfw_once()
        left = end - time.time()
        if left <= 0:
            break
        time.sleep(min(INTERVAL, left))
    mark_done(label)
    log("%d sample(s). output: %s" % (n, OUT))


# ===========================================================================
#  help and menu - per platform, so only what this box can do is shown
# ===========================================================================
EDGE_HELP = """
   ON THIS NSX EDGE it collects
     - a packet capture on the LB T1 service interface and/or the VPC T1
       uplink, through a span mirror plus tcpdump (a real ring buffer, and
       it stops by the clock)
     - interface / dataplane / CPU / memory counters
     - per router interface stats and HA state (only the routers you name)
     - firewall connection tables, load balancer status, pools and
       virtual servers

   ACTIONS
     (no action)   the menu
     config        what the config says, and the filter it produces
     discover      read this Edge and fill the config in for you
     selftest      everything that has to be right before a run
     check         which node is Active, leftovers, disk, filter
     rehearse      one sample of state and sessions, no capture
     start         start every collector in the background
     status        what is running, what is left, what was produced
     watch [secs]  status on a loop
     stop          stop our collectors, keep the files
     wipe          stop and delete our own files
     stop|wipe --dry-run    show every decision, change nothing
     help          this text

   READING IT BACK  ->  nsx-analyzer.py (the other script)
     python3 nsx-analyzer.py overview
     python3 nsx-analyzer.py flow --src 10.1.1.5 --dport 1812 --proto udp
     python3 nsx-analyzer.py state | session | report
     It analyses a run directory, so it also runs on your own machine after
     you copy the results off the box. The collector only collects.

   ONE COLLECTOR ON ITS OWN (same as the menu, no menu)
     python3 nsx-collector.py cap-lbt1 [secs]     LB T1 service interface
     python3 nsx-collector.py cap-vpct1 [secs]    VPC T1 uplink
     python3 nsx-collector.py stats-once | stats-run
     python3 nsx-collector.py sess-once  | sess-run
"""

ESXI_HELP = """
   ON THIS ESXi HOST it collects
     - a DFW capture BEFORE (pre) and AFTER (post) the rules, per vNIC of
       the VMs you named
     - the DFW flow table, the applied rules and the pass/drop counters
     - switch port and uplink NIC counters

   ACTIONS
     (no action)   the menu
     config        what the config says, and the filter it produces
     discover      read this host and fill the config in for you
     selftest      everything that has to be right before a run
     check         VM map, leftovers, disk, filter
     map           VM <-> DFW filter <-> switch port
     rehearse      one sample of DFW state and counters, no capture
     start         start every collector in the background
     status        what is running, what is left, what was produced
     watch [secs]  status on a loop
     stop          stop our collectors, keep the files
     wipe          stop and delete our own files
     stop|wipe --dry-run    show every decision, change nothing
     help          this text

   READING IT BACK  ->  nsx-analyzer.py (the other script)
     python3 nsx-analyzer.py overview
     python3 nsx-analyzer.py flow --dst 10.1.1.50 --dport 8080 --proto tcp
     python3 nsx-analyzer.py state | session | report
     It compares the pre and post captures for you, and also runs on your own
     machine after you copy the results off the host. The collector collects.

   ONE COLLECTOR ON ITS OWN (same as the menu, no menu)
     python3 nsx-collector.py cap-pre [secs]      before the DFW rules
     python3 nsx-collector.py cap-post [secs]     after the DFW rules
     python3 nsx-collector.py stats-once | stats-run
     python3 nsx-collector.py dfw-once   | dfw-run
"""

COMMON_HELP = """
   WHAT TO CAPTURE
     FILTER="..." in the config takes a normal tcpdump expression with
     and / or / not / ( ). It is syntax-checked before anything starts, and
     host/net is put in front of a bare address for you.
     Leave FILTER empty to use the single fields instead (HOSTS, PROTO,
     PORTS and the per-leg ones). Empty everywhere = every packet.

   SAFE ON A PRODUCTION BOX
     - only processes started by this file, or writing into our own run
       directory, are ever signalled. No "killall" anywhere.
     - captures are ended with SIGINT first so the pcap closes cleanly.
     - on an Edge a span session is released only when it mirrors a LIF from
       this config; one somebody else created is reported and left alone.
     - files are deleted only from directories holding our own
       00-run-info.txt, and never while a collector is still running.
     - stop/wipe print what is left and exit non-zero if anything survived.
"""


def action_help():
    band("nsx-collector %s on %s - what it collects and why" % (VERSION, PLAT))
    print(EDGE_HELP if IS_EDGE else ESXI_HELP)
    print(COMMON_HELP)


def menu():
    rule()
    row("  NSX Collector %s   (python)" % VERSION)
    row("  %s   %s / %s   %s" % (CASE_ID or "<no case>", PLAT, TAG,
                                 time.strftime("%Y-%m-%d %H:%M:%S")))
    rule()
    row("")
    if IS_EDGE:
        row("    SETUP                          COLLECT")
        row("      1  config                       5  start all")
        row("      2  discover (fill config)       6  status")
        row("      3  check - Active node?         w  watch")
        row("      4  rehearse (no capture)      ")
        row("")
        row("    ONE AT A TIME                  FINISH")
        row("      c  capture LB T1 service       7  stop        keep files")
        row("      u  capture VPC T1 uplink       8  stop + delete files")
        row("      t  state sample once           d  dry run (show only)")
        row("      e  session sample once         9  help    q  quit")

    else:
        row("    SETUP                          COLLECT")
        row("      1  config                       5  start all")
        row("      2  discover (fill config)       6  status")
        row("      3  check / VM map               w  watch")
        row("      4  rehearse (no capture)      ")
        row("")
        row("    ONE AT A TIME                  FINISH")
        row("      c  capture DFW pre             7  stop        keep files")
        row("      u  capture DFW post            8  stop + delete files")
        row("      t  state sample once           d  dry run (show only)")
        row("      e  DFW sample once             9  help    q  quit")

    row("")
    rule()


def run_menu():
    single = {
        "c": ("cap-lbt1", "cap-pre"),
        "u": ("cap-vpct1", "cap-post"),
        "t": ("stats-once", "stats-once"),
        "e": ("sess-once", "dfw-once"),
    }
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
            action_config()
        elif choice == "2":
            action_discover()
        elif choice == "3":
            edge_check() if IS_EDGE else esxi_check()
        elif choice == "4":
            action_rehearse()
        elif choice == "5":
            action_start()
        elif choice == "6":
            action_status()
        elif choice == "w":
            try:
                action_watch(10)
            except KeyboardInterrupt:
                pass
        elif choice == "7":
            action_stop("keep")
        elif choice == "8":
            action_stop("delete")
        elif choice == "d":
            action_stop("delete", dry=True)
        elif choice == "9":
            action_help()
        elif choice in single:
            act = single[choice][0 if IS_EDGE else 1]
            print("   $ python3 nsx-collector.py %s" % act)
            print()
            dispatch(act, [])
        elif choice == "m" and IS_ESXI:
            esxi_map()
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
    """--name value  or  --name=value"""
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            return args[i + 1]
        if a.startswith(name + "="):
            return a.split("=", 1)[1]
    return default


def dispatch(action, args):
    dry = "--dry-run" in args
    rest, skip = [], False
    for i, a in enumerate(args):
        if skip:
            skip = False
            continue
        if a.startswith("--"):
            skip = ("=" not in a) and a != "--dry-run"
            continue
        rest.append(a)
    secs = int(rest[0]) if rest and rest[0].isdigit() else CAP_SECS

    if action == "config":
        action_config()
    elif action == "discover":
        action_discover()
    elif action == "selftest":
        sys.exit(action_selftest())
    elif action == "check":
        edge_check() if IS_EDGE else esxi_check()
    elif action == "map":
        if not IS_ESXI:
            die("map is ESXi only")
        esxi_map()
    elif action == "rehearse":
        action_rehearse()
    elif action == "start":
        action_start()
    elif action == "status":
        action_status()
    elif action == "watch":
        try:
            action_watch(int(rest[0]) if rest else 10)
        except KeyboardInterrupt:
            pass
    elif action == "stop":
        sys.exit(action_stop("keep", dry))
    elif action == "wipe":
        sys.exit(action_stop("delete", dry))
    elif action in ("analyze", "analyse", "flow"):
        print("Analysis moved to its own script - the collector only collects now:")
        print("    python3 nsx-analyzer.py flow --src .. --dst .. --dport .. --proto ..")
        print("    python3 nsx-analyzer.py overview | state | session | report")
        print("It reads the run directory, so it also runs on your own machine")
        print("after   scp -r root@<box>:%s/run-... ." % OUT)
        sys.exit(2)
    elif action in ("help", "-h", "--help"):
        action_help()
    # ---- the collectors -------------------------------------------------
    elif action == "cap-lbt1":
        if not IS_EDGE:
            die("cap-lbt1 is Edge only")
        if not edge_need_lif("LIF_LBT1_SVC"):
            sys.exit(2)
        mkout()
        expr = filter_for("lbt1")
        ok, msg = filter_check(expr)
        if not ok:
            filter_problem(expr, msg)
            sys.exit(2)
        edge_capture("lbt1-svc", "10-edge-lbt1svc", cget("LIF_LBT1_SVC"), expr, secs,
                     cget("CAP_SESSION_LBT1") or "1")
    elif action == "cap-vpct1":
        if not IS_EDGE:
            die("cap-vpct1 is Edge only")
        if not edge_need_lif("LIF_VPCT1_UPLINK"):
            sys.exit(2)
        mkout()
        expr = filter_for("vpct1")
        ok, msg = filter_check(expr)
        if not ok:
            filter_problem(expr, msg)
            sys.exit(2)
        edge_capture("vpct1-uplink", "11-edge-vpct1uplink", cget("LIF_VPCT1_UPLINK"), expr,
                     secs, cget("CAP_SESSION_VPCT1") or "0")
    elif action in ("cap-pre", "cap-post"):
        if not IS_ESXI:
            die("%s is ESXi only" % action)
        esxi_capture("pre" if action == "cap-pre" else "post", secs)
    elif action == "stats-once":
        mkout()
        edge_stats_once() if IS_EDGE else esxi_stats_once()
    elif action == "sess-once":
        if not IS_EDGE:
            die("sess-once is Edge only - on ESXi use dfw-once")
        mkout()
        edge_sessions_once()
    elif action == "dfw-once":
        if not IS_ESXI:
            die("dfw-once is ESXi only - on an Edge use sess-once")
        mkout()
        esxi_dfw_once()
    elif action in ("stats-run", "sess-run", "dfw-run"):
        if action == "sess-run" and not IS_EDGE:
            die("sess-run is Edge only")
        if action == "dfw-run" and not IS_ESXI:
            die("dfw-run is ESXi only")
        poll_loop(action)
    else:
        print("Unknown action: %s" % action)
        print("Try: python3 nsx-collector.py help")
        sys.exit(2)


def main():
    args = sys.argv[1:]
    if not args:
        run_menu()
        return
    dispatch(args[0], args[1:])


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\ninterrupted")
        sys.exit(130)

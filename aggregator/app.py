#!/usr/bin/env python3
"""
IT Health Scan Aggregator (single-file service)
- Run: python app.py
- Endpoints:
  GET  /            -> Dashboard page (templates/dashboard.html)
  GET  /data        -> latest report JSON
  POST /start-scan  -> start a scan (json body: {"mode":"full"|"partial"})
  GET  /status      -> simple status (idle/running, start time)
  GET  /stream      -> Server-Sent Events (logs) for live terminal-like feed
  GET  /reports     -> list saved report filenames
  GET  /download/<name> -> download saved JSON report
"""
import os, json, time, threading, queue, glob
from datetime import datetime
from flask import Flask, render_template, request, jsonify, Response, send_from_directory
from flask_cors import CORS
import psutil
import platform
import socket
import subprocess

BASE_DIR = os.path.dirname(__file__)
UPLOAD_DIR = os.path.join(BASE_DIR, "uploads")
os.makedirs(UPLOAD_DIR, exist_ok=True)

app = Flask(__name__, static_folder="static", template_folder="templates")
CORS(app)

# In-memory state
_state = {
    "running": False,
    "mode": None,
    "start_time": None,
    "latest_report": None
}
# Thread-safe queue for log lines to be streamed via SSE
_log_q = queue.Queue()

def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"{ts} | {msg}"
    print(line, flush=True)
    _log_q.put(line)

def safe_json(obj):
    try:
        return json.dumps(obj, default=str, indent=2)
    except Exception:
        return json.dumps(str(obj))

# --- Scan logic ---
def analyze_and_score(report):
    """Simple heuristics to generate a score and remediations"""
    score = 100
    remediations = []

    # CPU
    cpu = report.get("cpu_percent")
    if cpu is not None:
        if cpu >= 90:
            score -= 40; remediations.append({"title":"High CPU", "action":"Check top processes and restart or throttle heavy services."})
        elif cpu >= 75:
            score -= 15; remediations.append({"title":"Elevated CPU", "action":"Investigate recent processes, consider scheduling heavy jobs off-peak."})

    # Memory
    mem_p = report.get("memory_percent")
    if mem_p is not None:
        if mem_p >= 95:
            score -= 35; remediations.append({"title":"Low free memory", "action":"Restart memory-hungry services or add RAM."})
        elif mem_p >= 85:
            score -= 12; remediations.append({"title":"High memory usage", "action":"Investigate processes consuming memory."})

    # Disks
    for d in report.get("disks", []):
        try:
            pct = d.get("percent", 0)
            if pct >= 95:
                score -= 35; remediations.append({"title":f"Disk {d.get('mount')} almost full", "action":"Clean temp files, rotate logs, extend disk or move data."})
            elif pct >= 90:
                score -= 12; remediations.append({"title":f"Disk {d.get('mount')} high usage", "action":"Investigate large files and cleanup."})
        except Exception:
            continue

    # Network
    if not report.get("network_online", True):
        score -= 40; remediations.append({"title":"No network connectivity","action":"Verify cable/Wi-Fi and gateway, restart adapter."})

    if score < 0: score = 0
    report["score"] = score
    report["remediations"] = remediations
    return report

def gather_basic_info():
    info = {}
    info["host"] = socket.gethostname()
    info["platform"] = platform.platform()
    try:
        info["uptime_seconds"] = time.time() - psutil.boot_time()
    except Exception:
        info["uptime_seconds"] = None
    # Add primary IPv4
    try:
        addrs = psutil.net_if_addrs()
        for iface, addrlist in addrs.items():
            for a in addrlist:
                if getattr(a, "family", None) == socket.AF_INET and not a.address.startswith("127."):
                    info["ip"] = a.address
                    info["iface"] = iface
                    raise StopIteration
    except StopIteration:
        pass
    except Exception:
        info["ip"] = "N/A"
    return info

def scan_partial(log_fn=log):
    log_fn("Starting PARTIAL scan: CPU, Memory, Disks, Network (quick).")
    report = {}
    report.update(gather_basic_info())

    # CPU instant sample (non-blocking)
    try:
        cpu = psutil.cpu_percent(interval=1)
        report["cpu_percent"] = cpu
        log_fn(f"CPU: {cpu}%")
    except Exception as e:
        report["cpu_percent"] = None
        log_fn(f"CPU sample failed: {e}")

    # Memory
    try:
        vm = psutil.virtual_memory()
        report["memory_total_mb"] = round(vm.total/1024/1024,2)
        report["memory_used_mb"] = round((vm.total - vm.available)/1024/1024,2)
        report["memory_percent"] = vm.percent
        log_fn(f"Memory: {report['memory_percent']}% used")
    except Exception as e:
        log_fn(f"Memory read failed: {e}")

    # Disks
    ds = []
    try:
        for part in psutil.disk_partitions(all=False):
            if "snap" in part.mountpoint.lower() or part.fstype == "":
                continue
            try:
                du = psutil.disk_usage(part.mountpoint)
                ds.append({"mount":part.mountpoint, "device": part.device, "total_gb": round(du.total/1e9,2), "used_gb": round(du.used/1e9,2), "free_gb": round(du.free/1e9,2), "percent": du.percent})
            except Exception:
                continue
        report["disks"] = ds
        log_fn(f"Disks: {len(ds)} mounted partitions scanned")
    except Exception as e:
        log_fn(f"Disk scan failed: {e}")

    # Network: interfaces & test connectivity (to 1.1.1.1)
    net = []
    network_online = False
    try:
        for name, addrs in psutil.net_if_addrs().items():
            for a in addrs:
                if getattr(a, "family", None) == socket.AF_INET:
                    net.append({"iface": name, "address": a.address, "netmask": a.netmask})
        try:
            # quick connectivity test
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(2)
            sock.connect(("1.1.1.1", 53))
            sock.close()
            network_online = True
        except Exception:
            network_online = False
        report["network_interfaces"] = net
        report["network_online"] = network_online
        log_fn(f"Network: interfaces found {len(net)} ; online={network_online}")
    except Exception as e:
        log_fn(f"Network scan failed: {e}")

    # Top processes (partial)
    try:
        procs = []
        for p in psutil.process_iter(['pid','name','cpu_percent','memory_info']):
            try:
                procs.append({"pid": p.info['pid'], "name": p.info['name'], "cpu": p.info.get('cpu_percent',0), "mem_mb": round(getattr(p.info.get('memory_info',None),'rss',0)/1024/1024,2)})
            except Exception:
                continue
        procs_sorted = sorted(procs, key=lambda x: x.get('cpu',0), reverse=True)[:8]
        report["top_cpu_processes"] = procs_sorted
        log_fn("Top processes collected")
    except Exception as e:
        log_fn(f"Process listing failed: {e}")

    return analyze_and_score(report)

def scan_full(log_fn=log):
    log_fn("Starting FULL scan: deep checks, services, connections, basic vuln heuristics.")
    report = scan_partial(log_fn=log_fn)  # include partial results first

    # Add more: listening ports, established connections (may require privileges)
    try:
        conns = psutil.net_connections(kind='inet')
        listening = []
        established = []
        for c in conns:
            try:
                laddr = f"{c.laddr.ip}:{c.laddr.port}" if c.laddr else ""
                raddr = f"{c.raddr.ip}:{c.raddr.port}" if c.raddr else ""
                if c.status == psutil.CONN_LISTEN:
                    listening.append({"pid": c.pid, "local": laddr})
                else:
                    established.append({"pid": c.pid, "laddr": laddr, "raddr": raddr, "status": c.status})
            except Exception:
                continue
        report["listening_ports"] = listening
        report["connections"] = established
        log_fn(f"Network sockets: listening={len(listening)} established={len(established)}")
    except Exception as e:
        log_fn(f"Socket enumeration failed: {e}")

    # Services (Windows) or systemd units (Linux)
    try:
        services = []
        if platform.system().lower().startswith("windows"):
            for s in psutil.win_service_iter():
                try:
                    services.append({"name": s.name(), "status": s.status()})
                except Exception:
                    continue
        else:
            # On Linux use systemctl list-units? psutil cannot list systemd units; limited approach:
            for s in psutil.process_iter(['pid','name']):
                if s.info['name'] and 'systemd' in s.info['name'].lower():
                    services.append({"pid": s.info['pid'], "name": s.info['name']})
        report["services_snapshot"] = services
        log_fn(f"Services snapshot: {len(services)} items")
    except Exception as e:
        log_fn(f"Service snapshot failed: {e}")

    # Vulnerability heuristics
    vulns = []
    try:
        # Java
        if shutil_which("java"):
            vulns.append({"name":"java present", "severity":"warn", "note":"Confirm Java version is up-to-date"})
        # docker presence
        if shutil_which("docker"):
            vulns.append({"name":"docker present", "severity":"info", "note":"Check container runtime versions"})
        report["vulnerabilities"] = vulns
        log_fn(f"Vulnerability heuristics: {len(vulns)} items")
    except Exception as e:
        log_fn(f"Vuln checks failed: {e}")

    # Event logs (Windows) or syslog snippet (Linux) - lightweight
    try:
        if platform.system().lower().startswith("windows"):
            import win32evtlog  # optional - won't be present in many environments
            # skip due to third-party requirement; instead note that detailed event fetch needs admin and pywin32
            report["logs_snippet"] = "Event log collection not enabled in this build (pywin32 required)"
        else:
            # tail /var/log/syslog or /var/log/messages
            candidates = ["/var/log/syslog", "/var/log/messages", "/var/log/system.log"]
            found = False
            for c in candidates:
                if os.path.exists(c):
                    try:
                        with open(c, 'r', encoding='utf-8', errors='ignore') as fh:
                            lines = fh.readlines()[-200:]
                            report["logs_snippet"] = "".join(lines[-200:])
                            found = True
                            break
                    except Exception:
                        continue
            if not found:
                report["logs_snippet"] = "No system log file readable or file not present."
        log_fn("Collected logs snippet (best-effort)")
    except Exception as e:
        report["logs_snippet"] = f"Log collection failed: {e}"
        log_fn(f"Log snippet read failed: {e}")

    return analyze_and_score(report)

# small helper
def shutil_which(cmd):
    try:
        import shutil
        return shutil.which(cmd)
    except Exception:
        return None

# Background worker
_scan_thread = None
_stop_event = threading.Event()

def scan_worker(mode):
    try:
        _state["running"] = True
        _state["mode"] = mode
        _state["start_time"] = datetime.now().isoformat()
        log(f"Scan worker started in {mode} mode.")
        if mode == "partial":
            rep = scan_partial(log_fn=log)
        else:
            rep = scan_full(log_fn=log)
        # add timestamp
        rep["collected_at"] = datetime.now().isoformat()
        # save
        filename = f"{rep.get('host','host')}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        path = os.path.join(UPLOAD_DIR, filename)
        with open(path, 'w', encoding='utf-8') as fh:
            json.dump(rep, fh, indent=2)
        _state["latest_report"] = path
        log(f"Scan complete. Report saved: {path}")
    except Exception as e:
        log(f"Scan worker failed: {e}")
    finally:
        _state["running"] = False
        _state["mode"] = None
        _state["start_time"] = None

@app.route("/")
def ui():
    return render_template("dashboard.html")

@app.route("/start-scan", methods=["POST"])
def start_scan():
    data = request.get_json(silent=True) or {}
    mode = data.get("mode", "full")
    if _state["running"]:
        return jsonify({"status":"busy","message":"Scan already running"}), 409
    # start
    t = threading.Thread(target=scan_worker, args=(mode,), daemon=True)
    t.start()
    return jsonify({"status":"started","mode":mode})

@app.route("/status", methods=["GET"])
def status():
    return jsonify(_state)

@app.route("/data", methods=["GET"])
def data():
    # load latest report (if exist)
    latest = _state.get("latest_report")
    if latest and os.path.exists(latest):
        try:
            with open(latest, 'r', encoding='utf-8') as fh:
                return jsonify(json.load(fh))
        except Exception as e:
            return jsonify({"error":"failed to read latest report","detail":str(e)}), 500
    # fallback: combine all
    items = []
    for p in sorted(glob.glob(os.path.join(UPLOAD_DIR, "*.json"))):
        try:
            with open(p, 'r', encoding='utf-8') as fh:
                items.append(json.load(fh))
        except Exception:
            continue
    return jsonify({"reports": items})

@app.route("/reports", methods=["GET"])
def list_reports():
    files = sorted(os.listdir(UPLOAD_DIR))
    return jsonify(files)

@app.route("/download/<path:name>", methods=["GET"])
def download(name):
    return send_from_directory(UPLOAD_DIR, name, as_attachment=True)

# SSE stream for logs
@app.route("/stream")
def stream():
    def event_stream():
        # open forever
        while True:
            try:
                line = _log_q.get(block=True, timeout=0.5)
                yield f"data: {json.dumps(line)}\n\n"
            except queue.Empty:
                # send keepalive comment to keep connection open
                yield ":keep-alive\n\n"
    return Response(event_stream(), mimetype="text/event-stream")

if __name__ == "__main__":
    log("Starting aggregator service on 0.0.0.0:5000")
    app.run(host="0.0.0.0", port=5000, debug=True)


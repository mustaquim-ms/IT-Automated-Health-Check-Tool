#!/usr/bin/env python3
"""
IT Health — Dark Neon Dashboard backend (Flask)
- Run a full or partial scan
- Stream logs via Server-Sent Events
- Provide actions: kill/suspend process, clear temp, performance boost
- Persist last 4 scans to scan_history.json
"""

import os
import json
import time
import threading
import queue
import glob
import platform
import socket
import psutil
import shutil
from datetime import datetime
from flask import Flask, render_template, request, jsonify, Response, send_from_directory
from flask_cors import CORS

BASE_DIR = os.path.dirname(__file__)
UPLOADS_DIR = os.path.join(BASE_DIR, "uploads")
os.makedirs(UPLOADS_DIR, exist_ok=True)
HISTORY_FILE = os.path.join(BASE_DIR, "scan_history.json")

app = Flask(__name__, static_folder="static", template_folder="templates")
CORS(app)

# In-memory state
_state = {
    "running": False,
    "mode": None,
    "start_time": None,
    "latest": None
}

# Log queue for SSE
_log_q = queue.Queue()


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"{ts} | {msg}"
    print(line, flush=True)
    try:
        _log_q.put(line)
    except Exception:
        pass

# ---------- persistence helpers ----------


def load_history():
    if not os.path.exists(HISTORY_FILE):
        return []
    try:
        with open(HISTORY_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return []


def save_history(history):
    try:
        with open(HISTORY_FILE, "w", encoding="utf-8") as fh:
            json.dump(history, fh, indent=2)
    except Exception as e:
        log(f"Failed saving history: {e}")


def append_history(entry, max_items=8):
    h = load_history()
    h.append(entry)
    # keep last 8 (we'll display last 4 in UI)
    if len(h) > max_items:
        h = h[-max_items:]
    save_history(h)

# ---------- scan logic ----------


def gather_basic():
    info = {}
    info['host'] = socket.gethostname()
    info['platform'] = platform.platform()
    info['timestamp'] = datetime.now().isoformat()
    # ip
    ip = "N/A"
    try:
        addrs = psutil.net_if_addrs()
        for iface, addrs_list in addrs.items():
            for a in addrs_list:
                if getattr(a, "family", None) == socket.AF_INET and not a.address.startswith("127."):
                    ip = a.address
                    raise StopIteration
    except StopIteration:
        pass
    except Exception:
        pass
    info['ip'] = ip
    return info


def quick_cpu_sample():
    try:
        return psutil.cpu_percent(interval=1)
    except Exception as e:
        log(f"CPU sample failed: {e}")
        return None


def scan_partial():
    log("Starting PARTIAL scan (quick).")
    rep = gather_basic()
    cpu = quick_cpu_sample()
    rep['cpu_percent'] = cpu
    vm = psutil.virtual_memory()
    rep['memory_percent'] = vm.percent
    # disks
    disks = []
    try:
        for p in psutil.disk_partitions(all=False):
            if p.fstype == "":
                continue
            try:
                du = psutil.disk_usage(p.mountpoint)
                disks.append({
                    "mount": p.mountpoint,
                    "device": p.device,
                    "total_gb": round(du.total/1e9, 2),
                    "used_gb": round(du.used/1e9, 2),
                    "free_gb": round(du.free/1e9, 2),
                    "percent": du.percent
                })
            except Exception:
                continue
    except Exception as e:
        log(f"Disk scan failed: {e}")
    rep['disks'] = disks

    # processes top CPU (non-blocking)
    pros = []
    try:
        for p in psutil.process_iter(['pid', 'name', 'cpu_percent', 'memory_info']):
            try:
                pros.append({
                    "pid": p.info['pid'],
                    "name": p.info['name'],
                    "cpu": p.info.get('cpu_percent', 0),
                    "mem_mb": round(getattr(p.info.get('memory_info', None), 'rss', 0)/1024/1024, 2)
                })
            except Exception:
                continue
        pros = sorted(pros, key=lambda x: x.get('cpu', 0), reverse=True)[:8]
    except Exception as e:
        log(f"Process sampling failed: {e}")
    rep['top_processes'] = pros

    # network quick test
    try:
        # test connectivity to 1.1.1.1:53
        sock_ok = False
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(2)
            sock.connect(("1.1.1.1", 53))
            sock.close()
            sock_ok = True
        except Exception:
            sock_ok = False
        rep['network_online'] = sock_ok
    except Exception:
        rep['network_online'] = False

    # heuristics + score
    rep = analyze(rep)
    return rep


def scan_full():
    log("Starting FULL scan (deep).")
    rep = scan_partial()
    # connections / listening
    try:
        conns = psutil.net_connections(kind='inet')
        listening = []
        established = []
        for c in conns:
            try:
                laddr = f"{getattr(c.laddr, 'ip', '')}:{getattr(c.laddr, 'port', '')}" if c.laddr else ""
                raddr = f"{getattr(c.raddr, 'ip', '')}:{getattr(c.raddr, 'port', '')}" if c.raddr else ""
                if c.status == psutil.CONN_LISTEN:
                    listening.append({"pid": c.pid, "local": laddr})
                else:
                    established.append(
                        {"pid": c.pid, "laddr": laddr, "raddr": raddr, "status": c.status})
            except Exception:
                continue
        rep['listening'] = listening
        rep['connections'] = established
        log(
            f"Network sockets scanned: listening={len(listening)} established={len(established)}")
    except Exception as e:
        log(f"Socket scan failed: {e}")

    # services snapshot (Windows) / limited process-based for Linux
    try:
        svcs = []
        if platform.system().lower().startswith("windows"):
            for s in psutil.win_service_iter():
                try:
                    svcs.append({"name": s.name(), "status": s.status()})
                except Exception:
                    continue
        else:
            # snapshot top system processes
            for p in psutil.process_iter(['pid', 'name']):
                try:
                    if 'systemd' in (p.info.get('name') or '').lower():
                        svcs.append(
                            {"pid": p.info['pid'], "name": p.info['name']})
                except Exception:
                    continue
        rep['services_snapshot'] = svcs
        log(f"Services snapshot collected: {len(svcs)} entries")
    except Exception as e:
        log(f"Service snapshot failed: {e}")

    # logs snippet - best-effort
    try:
        if platform.system().lower().startswith("windows"):
            rep['logs_snippet'] = "Event log extraction not enabled (pywin32 required for deep event logs)."
        else:
            candidates = ["/var/log/syslog",
                          "/var/log/messages", "/var/log/system.log"]
            snippet = ""
            for p in candidates:
                if os.path.exists(p):
                    try:
                        with open(p, 'r', encoding='utf-8', errors='ignore') as fh:
                            lines = fh.readlines()[-300:]
                            snippet = "".join(lines[-300:])
                            break
                    except Exception:
                        continue
            rep['logs_snippet'] = snippet if snippet else "No readable system log available."
        log("Logs snippet collected (best-effort)")
    except Exception as e:
        log(f"Log snippet failed: {e}")

    rep = analyze(rep)
    return rep


def analyze(rep):
    # compute a simple score and remediation hints
    score = 100
    rem = []
    try:
        cpu = rep.get('cpu_percent') or 0
        mem = rep.get('memory_percent') or 0
        disks = rep.get('disks', [])
        if cpu >= 90:
            score -= 40
            rem.append(
                {"title": "High CPU", "action": "Check top processes, consider stopping or reconfiguring heavy services."})
        elif cpu >= 75:
            score -= 15
            rem.append({"title": "Elevated CPU",
                       "action": "Investigate processes with high CPU."})
        if mem >= 95:
            score -= 35
            rem.append({"title": "Low available memory",
                       "action": "Restart high memory processes or add memory."})
        elif mem >= 85:
            score -= 12
            rem.append({"title": "High memory usage",
                       "action": "Investigate memory-hungry processes."})
        for d in disks:
            try:
                if d.get('percent', 0) >= 95:
                    score -= 35
                    rem.append({"title": f"Disk {d.get('mount')} nearly full",
                               "action": "Clean temp files, rotate logs, or extend volume."})
                elif d.get('percent', 0) >= 90:
                    score -= 12
                    rem.append({"title": f"Disk {d.get('mount')} high usage",
                               "action": "Investigate large files."})
            except Exception:
                continue
        if not rep.get('network_online', True):
            score -= 25
            rem.append({"title": "Network offline",
                       "action": "Check cable/router/Wi-Fi settings."})
    except Exception as e:
        log(f"Analyze routine exceptions: {e}")
    rep['score'] = max(0, score)
    rep['remediations'] = rem
    return rep


# ---------- background worker ----------
_scan_thread = None
_lock = threading.Lock()


def scan_worker(mode):
    with _lock:
        _state['running'] = True
        _state['mode'] = mode
        _state['start_time'] = datetime.now().isoformat()
    try:
        if mode == 'partial':
            rep = scan_partial()
        else:
            rep = scan_full()
        # save to disk
        filename = f"{rep.get('host', 'host')}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        path = os.path.join(UPLOADS_DIR, filename)
        with open(path, 'w', encoding='utf-8') as fh:
            json.dump(rep, fh, indent=2)
        _state['latest'] = path
        append_history({
            "time": rep.get('timestamp', datetime.now().isoformat()),
            "host": rep.get('host'),
            "score": rep.get('score'),
            "cpu": rep.get('cpu_percent'),
            "memory": rep.get('memory_percent'),
            "disks": [{"mount": d.get('mount'), "percent": d.get('percent')} for d in rep.get('disks', [])]
        })
        log(f"Scan finished and saved: {path}")
    except Exception as e:
        log(f"Scan worker error: {e}")
    finally:
        with _lock:
            _state['running'] = False
            _state['mode'] = None
            _state['start_time'] = None

# ---------- actions ----------


@app.route("/action/kill", methods=["POST"])
def action_kill():
    data = request.get_json(silent=True) or {}
    pid = data.get('pid')
    try:
        p = psutil.Process(int(pid))
        p.terminate()
        log(f"Terminated process PID={pid} ({p.name()})")
        return jsonify({"status": "ok"})
    except Exception as e:
        log(f"Failed to terminate PID={pid}: {e}")
        return jsonify({"status": "error", "detail": str(e)}), 500


@app.route("/action/suspend", methods=["POST"])
def action_suspend():
    data = request.get_json(silent=True) or {}
    pid = data.get('pid')
    try:
        p = psutil.Process(int(pid))
        p.suspend()
        log(f"Suspended process PID={pid} ({p.name()})")
        return jsonify({"status": "ok"})
    except Exception as e:
        log(f"Failed to suspend PID={pid}: {e}")
        return jsonify({"status": "error", "detail": str(e)}), 500


@app.route("/action/resume", methods=["POST"])
def action_resume():
    data = request.get_json(silent=True) or {}
    pid = data.get('pid')
    try:
        p = psutil.Process(int(pid))
        p.resume()
        log(f"Resumed process PID={pid} ({p.name()})")
        return jsonify({"status": "ok"})
    except Exception as e:
        log(f"Failed to resume PID={pid}: {e}")
        return jsonify({"status": "error", "detail": str(e)}), 500


@app.route("/action/clear_temp", methods=["POST"])
def action_clear_temp():
    try:
        if platform.system().lower().startswith("windows"):
            temp = os.environ.get("TEMP", r"C:\Windows\Temp")
        else:
            temp = "/tmp"
        # be careful: remove files only in temp
        removed = 0
        for root, dirs, files in os.walk(temp):
            for f in files:
                try:
                    os.remove(os.path.join(root, f))
                    removed += 1
                except Exception:
                    continue
        log(f"Cleared temp files from {temp}. Removed approx {removed} files.")
        return jsonify({"status": "ok", "removed": removed})
    except Exception as e:
        log(f"Clear temp failed: {e}")
        return jsonify({"status": "error", "detail": str(e)}), 500


@app.route("/action/boost", methods=["POST"])
def action_boost():
    data = request.get_json(silent=True) or {}
    mode = data.get('mode', 'soft')  # soft vs hard
    killed = []
    lowered = []
    try:
        # get CPU usage per process
        procs = []
        for p in psutil.process_iter(['pid', 'name']):
            try:
                cpu = p.cpu_percent(interval=0.1)
                procs.append((p.pid, p.name(), cpu))
            except Exception:
                continue
        procs = sorted(procs, key=lambda x: x[2], reverse=True)
        # soft: lower nice on expensive processes; hard: terminate top ones
        for pid, name, cpu in procs[:6]:
            try:
                p = psutil.Process(pid)
                if mode == 'hard' and cpu > 30:
                    p.terminate()
                    killed.append({"pid": pid, "name": name, "cpu": cpu})
                    log(f"Boost hard: terminated {name} (PID {pid}) cpu={cpu}")
                else:
                    # lower priority (increase nice)
                    try:
                        if platform.system().lower().startswith("windows"):
                            p.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)
                        else:
                            p.nice(10)
                        lowered.append({"pid": pid, "name": name, "cpu": cpu})
                        log(
                            f"Boost soft: lowered priority of {name} (PID {pid}) cpu={cpu}")
                    except Exception as e:
                        log(f"Failed lowering priority for PID {pid}: {e}")
            except Exception:
                continue
        return jsonify({"status": "ok", "killed": killed, "lowered": lowered})
    except Exception as e:
        log(f"Boost failed: {e}")
        return jsonify({"status": "error", "detail": str(e)}), 500

# ---------- web endpoints ----------


@app.route("/")
def index():
    return render_template("dashboard.html")


@app.route("/start-scan", methods=["POST"])
def start_scan():
    if _state['running']:
        return jsonify({"status": "busy", "message": "Scan already running"}), 409
    data = request.get_json(silent=True) or {}
    mode = data.get('mode', 'full')
    t = threading.Thread(target=scan_worker, args=(mode,), daemon=True)
    t.start()
    log(f"Requested scan mode={mode}")
    return jsonify({"status": "started", "mode": mode})


@app.route("/status")
def status():
    return jsonify(_state)


@app.route("/data")
def data():
    # return latest saved report if present
    latest = _state.get('latest')
    if latest and os.path.exists(latest):
        try:
            with open(latest, 'r', encoding='utf-8') as fh:
                return jsonify(json.load(fh))
        except Exception as e:
            log(f"Failed reading latest report: {e}")
    # fallback: return last entry from history
    history = load_history()
    if history:
        # return most recent entry augmented
        last = history[-1]
        # create a small object compatible for UI
        return jsonify({
            "host": last.get('host'),
            "timestamp": last.get('time'),
            "score": last.get('score'),
            "cpu_percent": last.get('cpu'),
            "memory_percent": last.get('memory'),
            "disks": last.get('disks'),
            "network_online": True,
            "remediations": []
        })
    return jsonify({})


@app.route("/history")
def history():
    return jsonify(load_history())


@app.route("/uploads/<path:name>")
def serve_report(name):
    safe = os.path.join(UPLOADS_DIR, os.path.basename(name))
    if os.path.exists(safe):
        return send_from_directory(UPLOADS_DIR, os.path.basename(name), as_attachment=True)
    return jsonify({"error": "not found"}), 404


@app.route("/stream")
def stream():
    def event_stream():
        # send keepalive and then lines from queue
        # this loop runs forever while client connected; yield SSE format text
        while True:
            try:
                line = _log_q.get(block=True, timeout=0.5)
                yield f"data: {json.dumps(line)}\n\n"
            except queue.Empty:
                # keepalive
                yield ":keep-alive\n\n"
    return Response(event_stream(), mimetype="text/event-stream")

# ---------- utility routes for testing ----------


@app.route("/debug/clear-history", methods=["POST"])
def debug_clear_history():
    try:
        if os.path.exists(HISTORY_FILE):
            os.remove(HISTORY_FILE)
        return jsonify({"status": "ok"})
    except Exception as e:
        return jsonify({"status": "error", "detail": str(e)}), 500


if __name__ == "__main__":
    log("Starting IT Health Flask server (dark neon) on 127.0.0.1:5000")
    app.run(host="127.0.0.1", port=5000, debug=False, threaded=True)

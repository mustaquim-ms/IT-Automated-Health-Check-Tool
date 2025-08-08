from flask import Flask, request, jsonify, render_template
import os, json, glob
from datetime import datetime

app = Flask(__name__)
REPORTS_DIR = "reports"
AGGREGATED_FILE = "aggregated_report.json"

os.makedirs(REPORTS_DIR, exist_ok=True)

def aggregate_reports():
    data = []
    for file in glob.glob(os.path.join(REPORTS_DIR, "*.json")):
        with open(file, "r") as f:
            try:
                data.extend(json.load(f))
            except json.JSONDecodeError:
                continue

    total_hosts = len(data)
    critical = sum(1 for r in data if r["Status"] == "Critical")
    warning = sum(1 for r in data if r["Status"] == "Warning")
    healthy = sum(1 for r in data if r["Status"] == "Healthy")

    category_counts = {
        "CPU": sum(1 for r in data if r["CPU"] > 80),
        "Memory": sum(1 for r in data if r["MemoryGB"] < 2),
        "Disk": sum(1 for r in data if r["DiskGB"] < 10),
        "Network": 0
    }

    trend = [
        {"date": datetime.now().strftime("%Y-%m-%d"), "count": total_hosts}
    ]

    logs = [f"[{r['Hostname']}] CPU {r['CPU']}% / Mem {r['MemoryGB']}GB / Disk {r['DiskGB']}GB"
            for r in data]

    aggregated = {
        "totalHosts": total_hosts,
        "critical": critical,
        "warning": warning,
        "healthy": healthy,
        "categoryCounts": category_counts,
        "trend": trend,
        "logs": logs,
        "hosts": [r["Hostname"] for r in data]
    }

    with open(AGGREGATED_FILE, "w") as f:
        json.dump(aggregated, f, indent=4)
    return aggregated

@app.route("/upload", methods=["POST"])
def upload():
    file_path = os.path.join(REPORTS_DIR, f"report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json")
    with open(file_path, "wb") as f:
        f.write(request.data)
    return jsonify({"status": "ok", "message": "Report received"})

@app.route("/")
def dashboard():
    aggregated = aggregate_reports()
    return render_template("dashboard.html", data=aggregated)

if __name__ == "__main__":
    app.run(debug=True)



# This code is a Flask application that serves as an aggregator for reports.
# It allows uploading JSON reports or files, saves them in a specified directory,
# and provides an endpoint to retrieve all aggregated reports in JSON format.
# The application is designed to be run in a development environment with debug mode enabled.
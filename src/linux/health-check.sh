# Health Check Script for Linux Systems
# This script performs a health check on a Linux system, gathering information about CPU, memory,
# disk usage, running processes, services, and pending updates. It generates a JSON report and
# an HTML report based on a template.
# src/linux/health-check.sh
set -euo pipefail
OUTDIR="$(dirname "$0")/../../reports"
TEMPLATEDIR="$(dirname "$0")/../../templates"
TIMESTAMP=$(date -Iseconds)
mkdir -p "$OUTDIR"

LOGFILE="$OUTDIR/healthcheck.log"
echo "$TIMESTAMP [INFO] Starting health check" >> "$LOGFILE"

HOSTNAME="$(hostname --fqdn)"
IP="$(hostname -I | awk '{print $1}' || echo 'N/A')"
OS="$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d \")"

# CPU
CPU_LOAD="$(awk '{print $1}' /proc/loadavg || echo 'N/A')"
# percent approximation using top is noisy; skip exact percent unless tools exist
CPU_USED_PERCENT=""
echo "$TIMESTAMP [INFO] CPU load: $CPU_LOAD" >> "$LOGFILE"

# Memory
read -r mem_total mem_free mem_available <<< $(free -m | awk 'NR==2{printf "%s %s %s",$2,$3,$7}')
mem_used=$mem_free
mem_json=$(cat <<EOF
{
  "total_mb": $mem_total,
  "used_mb": $mem_used,
  "free_mb": $((mem_total - mem_used)),
  "total_human": "${mem_total} MB",
  "free_human": "${mem_free} MB",
  "free_gb": $(awk "BEGIN {printf \"%.2f\", $mem_free/1024}")
}
EOF
)

# Disks
disks_json="[]"
disks_arr=()
while read -r fs size used avail percent mount; do
  percent_num=$(echo $percent | tr -d '%')
  free_human="${avail}K"
  used_human="${used}K"
  disks_arr+=("{\"mount\":\"$mount\",\"free_human\":\"$avail\",\"used_human\":\"$used\",\"percent\":$percent_num}")
done < <(df -h --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs | tail -n +2)
disks_json="[${disks_arr[*]}]"

# Processes & services
proc_count=$(ps aux --no-heading | wc -l)
service_count=0
if command -v systemctl >/dev/null 2>&1; then
  service_count=$(systemctl list-units --type=service --state=running | grep .service | wc -l)
fi
echo "$TIMESTAMP [INFO] Procs: $proc_count Services: $service_count" >> "$LOGFILE"

# Pending updates
updates_arr=()
if command -v apt >/dev/null 2>&1; then
  upg=$(apt list --upgradable 2>/dev/null | tail -n +2)
  if [ -n "$upg" ]; then
    while read -r line; do
      pkg=$(echo "$line" | cut -d/ -f1)
      updates_arr+=("{\"name\":\"$pkg\",\"severity\":\"warn\",\"note\":\"apt upgrade available\"}")
    done <<< "$upg"
  fi
elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
  updates_arr+=("{\"name\":\"YUM/DNF updates\",\"severity\":\"warn\",\"note\":\"Run yum/dnf check-update\"}")
fi

# logs (last 200 lines from syslog/journal)
if command -v journalctl >/dev/null 2>&1; then
  logs=$(journalctl -n 200 --no-pager 2>/dev/null | sed -n '1,200p' | sed 's/"/'\''/g')
else
  logs=$(tail -n 200 /var/log/syslog 2>/dev/null || tail -n 200 /var/log/messages 2>/dev/null || echo "No logs available")
fi

# Assemble JSON (simple)
report_json="$OUTDIR/report_$(date +%Y%m%d_%H%M%S).json"
cat > "$report_json" <<EOF
{
  "host":"$HOSTNAME",
  "ip":"$IP",
  "os":"$OS",
  "timestamp":"$TIMESTAMP",
  "cpu": {"load":"$CPU_LOAD"},
  "memory": $mem_json,
  "disks": $disks_json,
  "processes": {"total": $proc_count},
  "services": {"running": $service_count},
  "updates": [$(IFS=,; echo "${updates_arr[*]}")],
  "vulnerabilities": [],
  "log": "$(echo "$logs" | sed 's/"/\\"/g')",
  "remediations": [],
  "score": 85
}
EOF
echo "$TIMESTAMP [INFO] JSON report written: $report_json" >> "$LOGFILE"

# Inject JSON into HTML template
template="$TEMPLATEDIR/report-template.html"
if [ -f "$template" ]; then
  html_out="$OUTDIR/report_$(date +%Y%m%d_%H%M%S).html"
  # We need to inject: var REPORT_DATA = <json>;
  json_compact=$(sed -e ':a;N;$!ba;s/\n/ /g' "$report_json" | sed 's/"/\\"/g')
  # simpler: use placeholder replacement
  awk -v j="$(cat "$report_json")" '{
    if(index($0,"/* INSERT_DATA_HERE */")) { print "var REPORT_DATA = " j ";" }
    else print
  }' "$template" > "$html_out"
  echo "$TIMESTAMP [INFO] HTML report created: $html_out" >> "$LOGFILE"
  echo "Report: $html_out"
else
  echo "$TIMESTAMP [WARN] Template not found, HTML skipped" >> "$LOGFILE"
fi

exit 0

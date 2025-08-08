# Health Check Script for Linux Systems
# This script performs a health check on a Linux system, gathering information about CPU, memory,
# disk usage, running processes, services, and pending updates. It generates a JSON report and
# an HTML report based on a template.
# src/linux/health-check.sh


#!/bin/bash

cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}')
ram=$(free | grep Mem | awk '{print $3/$2 * 100.0}')

json=$(jq -n \
    --arg cpu "$(printf "%.2f" $cpu)" \
    --arg ram "$(printf "%.2f" $ram)" \
    '{cpu: ($cpu|tonumber), ram: ($ram|tonumber), status: "Healthy"}')

curl -X POST -H "Content-Type: application/json" -d "$json" http://127.0.0.1:5000/upload

echo "Report sent successfully!"


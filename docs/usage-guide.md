# Usage Guide

## Windows
1. Open an elevated PowerShell (Run as Administrator).
2. `cd src/windows`
3. `.\health-check.ps1`
4. Output: `reports/report_YYYYMMDD_HHMMSS.json` + `.html` and `healthcheck.log`

### Schedule
- Use Task Scheduler to run weekly:
  - Action: `powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\health-check.ps1"`
  - Trigger: Weekly, choose day/time.

## Linux
1. `chmod +x src/linux/health-check.sh`
2. `src/linux/health-check.sh`
3. Output located in `reports/`

### Schedule
- Add to cron (root recommended for updates check):
  - `0 3 * * 1 /path/to/src/linux/health-check.sh >> /var/log/it-health-check.log 2>&1`
- This runs every Monday at 3 AM, appending output to the log file. 
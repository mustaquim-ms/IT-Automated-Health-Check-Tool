# Remediation Guide (short)

## High CPU
- Run: `Get-Process | Sort-Object CPU -Descending | Select -First 10` (Windows)
- Action: Identify memory/CPU heavy process, restart service gracefully, schedule maintenance window.

## Disk nearly full
- Windows: `Get-ChildItem -Path C:\ -Recurse | Sort Length -Descending | Select -First 50`
- Linux: `sudo du -ahx / | sort -rh | head -n 50`
- Action: Archive logs, remove old backups, move large files to separate volume.

## Pending Updates
- Windows: Install-Module PSWindowsUpdate; `Install-WindowsUpdate -AcceptAll -AutoReboot`
- Ubuntu: `sudo apt update && sudo apt upgrade -y` (test in staging first)

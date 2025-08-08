# 🖥️ IT-Health-Check-Script

Automated **system health check** for Windows & Linux servers.  
Generates detailed reports covering CPU, memory, disk usage, running services, and pending updates.

## 🚀 Features
- Works on **Windows (PowerShell)** & **Linux (Bash)**.
- Generates both **console output** & **saved report files**.
- Easy to run — no complex dependencies.
- Ideal for **SysAdmins, DevOps, and IT Support teams**.

## 📂 Project Structure
```
src/windows/health-check.ps1  → Windows PowerShell script  
src/linux/health-check.sh     → Linux Bash script  
reports/sample-report.md      → Example generated report
docs/usage-guide.md           → Detailed instructions
```



## Security & Operational Safety Notes
- **Run scripts with caution**: Always review scripts before executing.
- **Test in staging**: Validate scripts in a non-production environment first.
- **Backup critical data**: Ensure you have backups before making changes.
 
 - Do not run scripts blindly on production without staging/testing.
 - Some checks require elevated privileges — the script will warn.
 - Scripts are meant to be read and modified for environment specifics (e.g., domain-joined update servers, custom package repos).
 - Keep templates/report-template.html offline if exposing sensitive logs. HTML can contain logs and should not be publicly accessible in some environments.

## ⚡ Quick Start

### Windows
```powershell
cd src/windows
.\health-check.ps1
```

### Linux
```bash
cd src/linux
chmod +x health-check.sh
./health-check.sh
```

## 📝 Example Output
See `reports/sample-report.md`

# IT-Health-Check-Script

Automated, production-grade system health check for Windows & Linux. Generates JSON + interactive HTML reports (charts + logs + remediation steps), suitable for scheduled runs and quick diagnostics.

## Quick links
- Windows script: `src/windows/health-check.ps1`
- Linux script: `src/linux/health-check.sh`
- Report template (Chart.js): `templates/report-template.html`
- Sample report: `reports/sample-report-2025-08-08.html`
- Usage guide: `docs/usage-guide.md`

## 📄 License
MIT License — free to use, modify, and distribute.

## 🤝 Contributing
See `CONTRIBUTING.md` for details.

---
*Built with ❤️ for IT professionals by Ahmad.*

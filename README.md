# 🖥 System Monitor

A production-ready, **free-tier** system health monitoring stack.  
Bash metrics → Flask REST API → Live web dashboard + Alerting via Email & Slack.

```
system-monitor/
├── backend/
│   ├── app.py              # Flask REST API
│   └── requirements.txt
├── frontend/
│   └── index.html          # Self-contained dashboard
├── scripts/
│   └── health_check.sh     # Core metrics collector (Bash)
├── alerts/
│   └── alert.sh            # Threshold alerting with cooldown
├── cron/
│   ├── setup_cron.sh       # Install cron jobs
│   └── remove_cron.sh      # Remove cron jobs
├── data/
│   └── metrics.json        # Latest metrics snapshot (auto-created)
├── logs/                   # Rotating log files (auto-created)
├── .env.example            # Config template
└── README.md
```

---

## Architecture

```
  ┌─────────────────────────────────────────┐
  │  cron (every 1 min)                     │
  │    ├── health_check.sh ──► metrics.json │
  │    └── alert.sh        ──► email/Slack  │
  └─────────────────────────────────────────┘
                    │
                    ▼
  ┌─────────────────────────────────────────┐
  │  Flask Backend  :5000                   │
  │    GET /metrics ──► runs script + cache │
  │    GET /health  ──► liveness probe      │
  └─────────────────────────────────────────┘
                    │ JSON
                    ▼
  ┌─────────────────────────────────────────┐
  │  Dashboard  (browser → index.html)      │
  │    Auto-refreshes every 4 seconds       │
  │    CPU / Memory / Disk gauges           │
  │    Services table + Process list        │
  └─────────────────────────────────────────┘
```

**How components talk:**

| Component | What it does |
|-----------|-------------|
| `health_check.sh` | Reads `/proc/stat`, `/proc/meminfo`, `df`, `ps`, `systemctl`, `ping` — outputs JSON |
| `Flask /metrics` | Invokes the script on every request; falls back to cached `metrics.json` on error |
| `alert.sh` | Reads `metrics.json`, compares against thresholds, fires email/Slack with cooldown |
| `cron` | Keeps `metrics.json` fresh every minute independently of the API |
| `index.html` | Pure HTML/CSS/JS — polls `/metrics` every 4 s, renders live gauges |

This mirrors real-world monitoring (e.g. Prometheus + Grafana) at zero cost:
- **Scrape layer** → `health_check.sh`
- **Storage/API layer** → Flask + `metrics.json`
- **Visualization layer** → Dashboard
- **Alertmanager layer** → `alert.sh`

---

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04 (or any Debian-based Linux)
- Python 3.8+
- Bash 5+
- Standard tools: `ps`, `df`, `ping`, `ip`, `systemctl`

Optional:
- `mailutils` for email alerts (`sudo apt install mailutils`)
- `curl` for Slack alerts (usually pre-installed)

---

## Setup

### 1. Clone / Download

```bash
git clone https://github.com/youruser/system-monitor.git
cd system-monitor
```

### 2. Configure

```bash
cp .env.example .env
nano .env          # set thresholds, email, Slack webhook
```

### 3. Install Python dependencies

```bash
cd backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cd ..
```

### 4. Make scripts executable

```bash
chmod +x scripts/health_check.sh alerts/alert.sh cron/setup_cron.sh cron/remove_cron.sh
```

### 5. Test the health-check script

```bash
# Human-readable output:
bash scripts/health_check.sh

# JSON output:
bash scripts/health_check.sh --json
```

### 6. Start the Flask backend

```bash
cd backend
source venv/bin/activate
python app.py
# → Listening on http://0.0.0.0:5000
```

Test API endpoints:
```bash
curl http://localhost:5000/health
curl http://localhost:5000/metrics | python3 -m json.tool
```

### 7. Open the Dashboard

```bash
# Option A — open directly in browser:
xdg-open frontend/index.html

# Option B — serve with Python:
python3 -m http.server 8080 --directory frontend
# Then visit: http://localhost:8080
```

### 8. Install Cron Jobs

```bash
bash cron/setup_cron.sh
```

Installs:
- `health_check.sh --json` → every 1 minute
- `alert.sh` → every 1 minute

Remove with: `bash cron/remove_cron.sh`

---

## Running in Production (optional)

Use `gunicorn` instead of Flask's dev server:

```bash
cd backend
source venv/bin/activate
gunicorn -w 2 -b 0.0.0.0:5000 app:app --access-logfile ../logs/gunicorn.log
```

To run as a systemd service, create `/etc/systemd/system/sysmonitor.service`:

```ini
[Unit]
Description=System Monitor Backend
After=network.target

[Service]
WorkingDirectory=/path/to/system-monitor/backend
ExecStart=/path/to/system-monitor/backend/venv/bin/gunicorn -w 2 -b 0.0.0.0:5000 app:app
Restart=always
User=youruser

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now sysmonitor
```

---

## Alert Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `ALERT_CPU_THRESHOLD` | `85` | CPU % to trigger alert |
| `ALERT_MEM_THRESHOLD` | `85` | Memory % to trigger alert |
| `ALERT_DISK_THRESHOLD` | `90` | Disk % to trigger alert |
| `ALERT_COOLDOWN_SECONDS` | `300` | Seconds between repeat alerts (per category) |
| `ALERT_EMAIL` | — | Recipient email (requires `mailutils`) |
| `SLACK_WEBHOOK` | — | Slack Incoming Webhook URL |
| `MONITORED_SERVICES` | `ssh,cron,networking` | Comma-separated systemd units |

---

## Logs

| File | Contents |
|------|----------|
| `logs/health_check.log` | Timestamped metric collection events |
| `logs/alerts.log` | Alert firings and cooldown suppression |
| `logs/backend.log` | Flask request and error log (rotates at 1 MB) |
| `logs/cron.log` | stdout/stderr from cron executions |

---

## Dashboard Screenshot

```
╔══════════════════════════════════════════════════════════════════╗
║  ⬡ SysMonitor                               ● Live  ↺ Refresh   ║
║  Last updated: 14:23:07  |  Next refresh in: 3s  |  Host: vm01  ║
╠══════════════╦══════════════╦══════════════════════════════════╣
║  CPU Usage   ║  Memory      ║  Disk ( / )                      ║
║   ◯ 42%      ║   ◯ 71%      ║   ◯ 55%                          ║
║   (green)    ║   (yellow)   ║   (green)                        ║
╠══════════════╩══════════════╩══════════════════════════════════╣
║  Network           ║  Services        ║  Top Processes          ║
║  Status: UP ●      ║  ssh   [active]  ║  PID  User  CMD CPU%    ║
║  Latency: 18.2 ms  ║  cron  [active]  ║  1234 root  nginx 12.3% ║
║  Interface: eth0   ║  net   [active]  ║  ...                    ║
╚══════════════════════════════════════════════════════════════════╝
```

---

## Dependencies

| Tool | Purpose | Install |
|------|---------|---------|
| Python 3.8+ | Flask backend | `sudo apt install python3 python3-pip python3-venv` |
| Flask 3 | REST API framework | `pip install flask` |
| flask-cors | Cross-origin requests | `pip install flask-cors` |
| python-dotenv | `.env` loading | `pip install python-dotenv` |
| gunicorn | Production WSGI server | `pip install gunicorn` |
| mailutils | Email alerts | `sudo apt install mailutils` |
| curl | Slack webhook | `sudo apt install curl` |

---

## License

MIT — Free to use, modify, and deploy.

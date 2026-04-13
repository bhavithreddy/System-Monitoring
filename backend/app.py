"""
system-monitor/backend/app.py
Flask REST API backend — serves metrics from the bash health-check script.
"""

import json
import os
import subprocess
import logging
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler
from pathlib import Path

from flask import Flask, jsonify, abort
from flask_cors import CORS
from dotenv import load_dotenv

# ── Bootstrap ─────────────────────────────────────────────────────────────────
BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

app = Flask(__name__)
CORS(app)  # Allow frontend on any port to reach the API

# ── Config ────────────────────────────────────────────────────────────────────
DATA_FILE   = Path(os.getenv("DATA_FILE",  BASE_DIR / "data" / "metrics.json"))
LOG_FILE    = Path(os.getenv("LOG_FILE",   BASE_DIR / "logs" / "backend.log"))
SCRIPT_PATH = BASE_DIR / "scripts" / "health_check.sh"
PORT        = int(os.getenv("FLASK_PORT", 5000))
DEBUG       = os.getenv("FLASK_DEBUG", "false").lower() == "true"

DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

# ── Logging ───────────────────────────────────────────────────────────────────
handler = RotatingFileHandler(LOG_FILE, maxBytes=1_000_000, backupCount=3)
handler.setFormatter(logging.Formatter("[%(asctime)s] %(levelname)s %(message)s"))
app.logger.addHandler(handler)
app.logger.setLevel(logging.INFO)


# ── Helpers ───────────────────────────────────────────────────────────────────

def run_health_check() -> dict:
    """Execute the bash script and return parsed JSON metrics."""
    if not SCRIPT_PATH.exists():
        raise FileNotFoundError(f"Health-check script not found: {SCRIPT_PATH}")

    result = subprocess.run(
        ["bash", str(SCRIPT_PATH), "--json"],
        capture_output=True,
        text=True,
        timeout=30,
    )

    if result.returncode != 0:
        app.logger.error("health_check.sh stderr: %s", result.stderr)
        raise RuntimeError(f"Script exited with code {result.returncode}: {result.stderr.strip()}")

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        app.logger.error("JSON parse error: %s | stdout: %s", exc, result.stdout[:500])
        raise ValueError(f"Invalid JSON from script: {exc}") from exc


def read_cached_metrics() -> dict | None:
    """Return cached metrics from data file, or None if missing/corrupt."""
    try:
        with open(DATA_FILE, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


# ── Routes ────────────────────────────────────────────────────────────────────

@app.route("/health", methods=["GET"])
def health():
    """Simple liveness probe."""
    return jsonify({
        "status": "ok",
        "service": "system-monitor",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })


@app.route("/metrics", methods=["GET"])
def metrics():
    """
    Runs the health-check script, caches result, and returns JSON metrics.
    Falls back to the last-known cached data if the script fails.
    """
    try:
        data = run_health_check()
        app.logger.info("Metrics collected successfully")
        return jsonify(data)

    except FileNotFoundError as exc:
        app.logger.error("Script not found: %s", exc)
        cached = read_cached_metrics()
        if cached:
            cached["_warning"] = "Using cached data — script not found"
            return jsonify(cached), 206
        abort(503, description=str(exc))

    except subprocess.TimeoutExpired:
        app.logger.warning("health_check.sh timed out; returning cached data")
        cached = read_cached_metrics()
        if cached:
            cached["_warning"] = "Using cached data — collection timed out"
            return jsonify(cached), 206
        abort(504, description="Health-check script timed out and no cache available")

    except (RuntimeError, ValueError) as exc:
        app.logger.error("Metric collection error: %s", exc)
        cached = read_cached_metrics()
        if cached:
            cached["_warning"] = f"Using cached data — {exc}"
            return jsonify(cached), 206
        abort(500, description=str(exc))


@app.errorhandler(404)
def not_found(e):
    return jsonify({"error": "Not found", "message": str(e)}), 404


@app.errorhandler(500)
def server_error(e):
    return jsonify({"error": "Internal server error", "message": str(e)}), 500


@app.errorhandler(503)
def service_unavailable(e):
    return jsonify({"error": "Service unavailable", "message": str(e)}), 503


@app.errorhandler(504)
def gateway_timeout(e):
    return jsonify({"error": "Gateway timeout", "message": str(e)}), 504


# ── Entry Point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    app.logger.info("Starting system-monitor backend on port %d", PORT)
    app.run(host="0.0.0.0", port=PORT, debug=DEBUG)

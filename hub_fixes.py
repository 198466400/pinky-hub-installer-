"""hub_fixes.py — drop-in replacements for hub.py.

Apply in order. Line numbers refer to the uploaded one-shot-install.sh.

  1. Replace class ModelManager (lines 122-169) with the version below.
  2. Add the db() helper and require_token decorator.
  3. Decorate every /api/ route with @require_token.
  4. Replace the final app.run line (464).
  5. Replace bare `request.json` with `request.get_json(silent=True) or {}`.

What was wrong, in order of severity:

  app.run(host="0.0.0.0")   Published an unauthenticated remote-process-spawner
                            to every device on the Wi-Fi. The whole design is
                            SSH tunnels to loopback; the bind contradicted it.

  MODELS_DIR / model_file   model_file comes straight from the HTTP body. A
                            path with ../ escapes the models directory and
                            hands an arbitrary file to llama-server.

  stdout=PIPE, stderr=PIPE  Nothing ever reads those pipes. llama-server
  with no reader             blocks forever once the 64KB pipe buffer fills,
                            usually a minute or two into the first real load.

  time.sleep(3)             A 600MB model on a phone VM is not ready in 3s.
                            The first query after load reliably failed.

  os.kill(pid, 15)          No wait, no SIGKILL fallback, Popen object
                            discarded, so every unload left a zombie.
"""

import os
import sqlite3
import subprocess
import time
from contextlib import contextmanager
from functools import wraps
from pathlib import Path

from flask import jsonify, request

# These come from hub.py; re-declared here only so this file reads standalone.
HUB_DIR = Path("/opt/pinky-hub")
DATA_DIR = HUB_DIR / "data"
MODELS_DIR = HUB_DIR / "models"
DB_PATH = DATA_DIR / "hub.db"

TOKEN_PATH = DATA_DIR / "token"
API_TOKEN = TOKEN_PATH.read_text().strip() if TOKEN_PATH.exists() else ""


# ------------------------------------------------------------------ db
@contextmanager
def db():
    """The original opened a connection per call and leaked it on any raise."""
    conn = sqlite3.connect(str(DB_PATH), timeout=10)
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------- auth
def require_token(fn):
    """Loopback is not authentication. Any app on the phone can reach the
    tunnel; anything that reaches it can spawn a process."""

    @wraps(fn)
    def wrapper(*args, **kwargs):
        if not API_TOKEN:
            return jsonify({"error": "no API token provisioned"}), 500
        sent = request.headers.get("X-Pinky-Token", "")
        # constant-time compare; hmac is stdlib
        import hmac

        if not hmac.compare_digest(sent, API_TOKEN):
            return jsonify({"error": "unauthorized"}), 401
        return fn(*args, **kwargs)

    return wrapper


# -------------------------------------------------------- ModelManager
class ModelManager:
    STARTUP_TIMEOUT_S = 180

    def __init__(self):
        self.proc: subprocess.Popen | None = None
        self.current_model: str | None = None
        self.model_port = 8080
        self.log_path = HUB_DIR / "model.log"

    # -- discovery -----------------------------------------------------
    def list_models(self):
        return [
            {
                "file": f.name,
                "size_mb": round(f.stat().st_size / (1024 * 1024), 1),
                "path": str(f),
            }
            for f in MODELS_DIR.glob("*.gguf")
        ]

    def _resolve(self, model_file: str) -> Path | None:
        """Whitelist by exact filename. No joining of caller-supplied paths."""
        if not model_file or "/" in model_file or "\\" in model_file:
            return None
        for f in MODELS_DIR.glob("*.gguf"):
            if f.name == model_file:
                return f
        return None

    # -- lifecycle -----------------------------------------------------
    def load_model(self, model_file: str):
        path = self._resolve(model_file)
        if path is None:
            return {"error": f"unknown model: {model_file}"}

        self.unload_model()
        log = open(self.log_path, "ab", buffering=0)
        try:
            self.proc = subprocess.Popen(
                [
                    "llama-server",
                    "-m", str(path),
                    "--port", str(self.model_port),
                    "--host", "127.0.0.1",
                ],
                stdout=log,          # a file, not a pipe nobody drains
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        except FileNotFoundError:
            return {"error": "llama-server not on PATH"}

        if not self._wait_ready():
            tail = self._log_tail()
            self.unload_model()
            return {"error": "model did not become ready", "log": tail}

        self.current_model = model_file
        return {
            "status": "loaded",
            "model": model_file,
            "port": self.model_port,
            "pid": self.proc.pid,
        }

    def _wait_ready(self) -> bool:
        """Poll /health instead of guessing with sleep(3)."""
        import requests

        deadline = time.time() + self.STARTUP_TIMEOUT_S
        url = f"http://127.0.0.1:{self.model_port}/health"
        while time.time() < deadline:
            if self.proc is None or self.proc.poll() is not None:
                return False  # exited during startup
            try:
                if requests.get(url, timeout=2).status_code == 200:
                    return True
            except Exception:
                pass
            time.sleep(1)
        return False

    def _log_tail(self, n: int = 20) -> str:
        try:
            return "\n".join(self.log_path.read_text(errors="replace").splitlines()[-n:])
        except OSError:
            return ""

    def unload_model(self):
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
            self.proc = None
        self.current_model = None
        return {"status": "unloaded"}

    def get_status(self):
        alive = self.proc is not None and self.proc.poll() is None
        if not alive:
            self.current_model = None
        return {
            "loaded": alive,
            "model": self.current_model,
            "port": self.model_port if alive else None,
        }

    # -- inference -----------------------------------------------------
    def query(self, prompt: str, system: str = ""):
        if not self.get_status()["loaded"]:
            return {"error": "no model loaded"}
        import requests

        messages = ([{"role": "system", "content": system}] if system else []) + [
            {"role": "user", "content": prompt}
        ]
        try:
            res = requests.post(
                f"http://127.0.0.1:{self.model_port}/v1/chat/completions",
                json={"messages": messages, "temperature": 0.7, "max_tokens": 1024},
                timeout=180,
            )
            res.raise_for_status()
            return res.json()
        except Exception as exc:
            return {"error": str(exc), "log": self._log_tail(5)}


# ------------------------------------------------------------ __main__
# Replace line 464 with this. 0.0.0.0 published an unauthenticated
# process-spawner to the local network.
#
#   app.run(host="127.0.0.1", port=7777, debug=False)
#
# And guard against the reloader double-spawning llama-server if debug is
# ever turned on:
#
#   if __name__ == "__main__" and os.environ.get("WERKZEUG_RUN_MAIN") != "true":
#       init_db()

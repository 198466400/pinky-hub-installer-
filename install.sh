#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
# PINKY HUB — INSTALLER (rewrite)
#
#   Termux:  sh install.sh          # stages files, drives the VM install
#   Alpine:  sh install.sh          # installs in place
#
# Requires hub.py in the same directory as this script. The original
# embedded hub.py in a heredoc and re-extracted it with sed on the VM
# side; that path is removed. One copy of the file, no self-extraction.
#
# This script has no `|| true` on anything load-bearing. If a stage
# fails, it stops and says which one.
# ═══════════════════════════════════════════════════════════════════

set -eu

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
say()  { printf "${CYN}[*]${NC} %s\n" "$*"; }
ok()   { printf "${GRN}[✓]${NC} %s\n" "$*"; }
warn() { printf "${YEL}[!]${NC} %s\n" "$*" >&2; }
die()  { printf "${RED}[✗] %s${NC}\n" "$*" >&2; exit 1; }

# Absolute path to this script and its directory. $0 is unreliable after
# any cd, and is literally "sh" when piped from curl.
case "$0" in
    /*) SELF="$0" ;;
    *)  SELF="$(pwd)/$0" ;;
esac
[ -f "$SELF" ] || die "cannot resolve own path — do not pipe this script into sh; save it to a file first"
SELF_DIR="$(dirname "$SELF")"

VM_SSH_PORT="${VM_SSH_PORT:-2222}"
VM_USER="${VM_USER:-root}"
VM_HOST="${VM_HOST:-localhost}"
HUB_PORT="${HUB_PORT:-7777}"
MODEL_PORT="${MODEL_PORT:-8080}"
HUB_ROOT="/opt/pinky-hub"
JOBS="${JOBS:-2}"          # llama.cpp build parallelism; -j$(nproc) OOMs on phones

MODEL_URL="${MODEL_URL:-https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf}"
MODEL_NAME="tinyllama-1.1b-chat.Q4_K_M.gguf"
MODEL_MIN_BYTES=400000000   # sanity floor; a 4KB HTML error page must not pass

# ─── environment detection (alpine checked first: an Alpine guest can see
#     Termux paths through a proot/bind mount and misdetect) ───
if [ -f /etc/alpine-release ]; then
    ENVIRON=alpine
elif [ -d /data/data/com.termux ]; then
    ENVIRON=termux
else
    die "unknown environment — expected Termux or Alpine"
fi

printf "\n${CYN}◈ PINKY HUB INSTALLER${NC}  —  detected: %s\n\n" "$ENVIRON"

# ═══════════════════════════════════════════════════════════════════
# TERMUX SIDE
# ═══════════════════════════════════════════════════════════════════
if [ "$ENVIRON" = termux ]; then
    VM_DIR="${VM_DIR:-$HOME/pinky-vm}"
    SHARED="$VM_DIR/shared"
    HUB_SHARED="$SHARED/pinky-hub"

    [ -f "$SELF_DIR/hub.py" ] || die "hub.py not found next to the installer ($SELF_DIR)"
    [ -d "$SHARED" ] || die "VM shared folder missing: $SHARED (set VM_DIR=... if it lives elsewhere)"
    command -v ssh >/dev/null 2>&1 || die "ssh missing — pkg install openssh"
    command -v scp >/dev/null 2>&1 || die "scp missing — pkg install openssh"

    say "Checking the VM is up on port $VM_SSH_PORT..."
    if ! ssh -p "$VM_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=8 \
             -o StrictHostKeyChecking=accept-new \
             "$VM_USER@$VM_HOST" true 2>/dev/null; then
        warn "key auth failed or VM unreachable; retrying interactively"
        ssh -p "$VM_SSH_PORT" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
            "$VM_USER@$VM_HOST" true \
            || die "cannot reach the VM at $VM_HOST:$VM_SSH_PORT — start it and retry"
    fi
    ok "VM reachable"

    say "Staging files into $HUB_SHARED"
    mkdir -p "$HUB_SHARED/src" "$HUB_SHARED/scripts"
    cp "$SELF_DIR/hub.py" "$HUB_SHARED/src/hub.py"

    cat > "$HUB_SHARED/scripts/termux-bridge.sh" << BRIDGE
#!/data/data/com.termux/files/usr/bin/sh
# SSH tunnels: phone browser -> VM services (which bind loopback only).
set -eu
VM_SSH_PORT=$VM_SSH_PORT; VM_USER=$VM_USER; VM_HOST=$VM_HOST
HUB_PORT=$HUB_PORT; MODEL_PORT=$MODEL_PORT

up() {
    ssh -f -N -o ExitOnForwardFailure=yes -L "\$1:localhost:\$1" \\
        -p "\$VM_SSH_PORT" "\$VM_USER@\$VM_HOST" \\
        || { printf '[!] tunnel for port %s failed (already open?)\\n' "\$1" >&2; return 1; }
}

case "\${1:-start}" in
    start)
        up "\$HUB_PORT"   || true
        up "\$MODEL_PORT" || true
        printf '[✓] Hub: http://localhost:%s\\n' "\$HUB_PORT"
        ;;
    stop)
        pkill -f "ssh.*-L \$HUB_PORT:localhost:\$HUB_PORT"     2>/dev/null || true
        pkill -f "ssh.*-L \$MODEL_PORT:localhost:\$MODEL_PORT" 2>/dev/null || true
        printf '[✓] tunnels down\\n'
        ;;
    ssh) exec ssh -p "\$VM_SSH_PORT" "\$VM_USER@\$VM_HOST" ;;
    *) printf 'usage: termux-bridge.sh [start|stop|ssh]\\n' >&2; exit 1 ;;
esac
BRIDGE
    chmod +x "$HUB_SHARED/scripts/termux-bridge.sh"
    ok "files staged"

    say "Copying installer + hub.py to the VM"
    ssh -p "$VM_SSH_PORT" -o StrictHostKeyChecking=accept-new "$VM_USER@$VM_HOST" \
        "mkdir -p /tmp/pinky-install" || die "mkdir on VM failed"
    scp -P "$VM_SSH_PORT" -o StrictHostKeyChecking=accept-new \
        "$SELF" "$SELF_DIR/hub.py" "$VM_USER@$VM_HOST:/tmp/pinky-install/" \
        || die "scp to VM failed"

    say "Running the installer inside the VM"
    # Exit status propagates. The original swallowed it with || true and
    # printed success unconditionally.
    ssh -p "$VM_SSH_PORT" -o StrictHostKeyChecking=accept-new "$VM_USER@$VM_HOST" \
        "sh /tmp/pinky-install/install.sh" \
        || die "VM-side install failed — see output above"

    printf "\n"; ok "Termux side complete"
    printf "  start tunnels: %s/scripts/termux-bridge.sh\n\n" "$HUB_SHARED"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════
# ALPINE VM SIDE
# ═══════════════════════════════════════════════════════════════════
[ "$(id -u)" = 0 ] || die "run as root inside the VM"

# ─── 1. system packages ───
say "[1/6] system packages"
apk update >/dev/null || die "apk update failed"
apk add --no-cache python3 py3-pip py3-flask sqlite git build-base cmake wget curl \
    || die "apk add failed"
ok "system packages"

# ─── 2. python packages ───
say "[2/6] python packages"
PIP_FLAGS=""
pip3 install --help 2>&1 | grep -q -- --break-system-packages && PIP_FLAGS="--break-system-packages"
# shellcheck disable=SC2086
pip3 install $PIP_FLAGS flask-cors requests beautifulsoup4 lxml \
    || die "pip install failed"
python3 -c "import flask, flask_cors, requests" \
    || die "python imports still broken after install"
ok "python packages"

# ─── 3. llama.cpp ───
say "[3/6] llama.cpp"
if command -v llama-server >/dev/null 2>&1; then
    ok "llama-server already present"
else
    [ -d /opt/llama.cpp/.git ] || git clone --depth 1 \
        https://github.com/ggml-org/llama.cpp.git /opt/llama.cpp \
        || die "git clone failed"
    # LLAMA_BUILD_SERVER was removed upstream; the server is built by default.
    # CMAKE_BUILD_TYPE must be set at configure time for Makefile generators.
    cmake -S /opt/llama.cpp -B /opt/llama.cpp/build \
        -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF \
        || die "cmake configure failed"
    cmake --build /opt/llama.cpp/build -j"$JOBS" \
        || die "llama.cpp build failed (try JOBS=1 if the VM ran out of memory)"
    for b in llama-server llama-cli; do
        [ -x "/opt/llama.cpp/build/bin/$b" ] || die "$b not produced by the build"
        ln -sf "/opt/llama.cpp/build/bin/$b" "/usr/local/bin/$b"
    done
fi
command -v llama-server >/dev/null 2>&1 || die "llama-server not on PATH"
ok "llama.cpp"

# ─── 4. hub files ───
say "[4/6] hub layout"
# Note: no brace expansion. Under ash, mkdir -p /opt/pinky-hub/{src,models,data}
# creates one directory literally named "{src,models,data}".
for d in src models data; do mkdir -p "$HUB_ROOT/$d"; done

if   [ -f /tmp/pinky-install/hub.py ];      then SRC=/tmp/pinky-install/hub.py
elif [ -f /shared/pinky-hub/src/hub.py ];   then SRC=/shared/pinky-hub/src/hub.py
elif [ -f "$SELF_DIR/hub.py" ];             then SRC="$SELF_DIR/hub.py"
else die "hub.py not found in /tmp/pinky-install, /shared/pinky-hub/src, or $SELF_DIR"
fi
cp "$SRC" "$HUB_ROOT/src/hub.py"
python3 -m py_compile "$HUB_ROOT/src/hub.py" || die "hub.py does not compile"
ok "hub.py installed from $SRC"

# API token. The hub binds loopback, but the tunnel makes it reachable from
# anything running on the phone. Anything that can load a model and run a
# subprocess gets a credential.
if [ ! -f "$HUB_ROOT/data/token" ]; then
    head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$HUB_ROOT/data/token"
    chmod 600 "$HUB_ROOT/data/token"
fi
ok "api token at $HUB_ROOT/data/token"

# ─── 5. model ───
say "[5/6] model"
MODEL_FILE="$HUB_ROOT/models/$MODEL_NAME"
if [ -f "$MODEL_FILE" ] && [ "$(wc -c < "$MODEL_FILE")" -ge "$MODEL_MIN_BYTES" ]; then
    ok "model already present"
else
    # -C - resumes a partial download; --retry survives a phone dropping data.
    curl -fL --retry 3 --retry-delay 2 -C - -o "$MODEL_FILE" "$MODEL_URL" \
        || die "model download failed — rerun to resume, or set MODEL_URL"
    SZ="$(wc -c < "$MODEL_FILE")"
    [ "$SZ" -ge "$MODEL_MIN_BYTES" ] \
        || die "downloaded file is only $SZ bytes — probably an error page, not a model"
    ok "model downloaded"
fi

# ─── 6. commands ───
say "[6/6] shortcuts"
cat > /usr/local/bin/pinky-start << 'CMD'
#!/bin/sh
set -eu
ROOT=/opt/pinky-hub
PIDFILE="$ROOT/hub.pid"
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    printf 'hub already running (pid %s)\n' "$(cat "$PIDFILE")"; exit 0
fi
rm -f "$PIDFILE"
cd "$ROOT/src"
python3 hub.py >> "$ROOT/hub.log" 2>&1 &
echo $! > "$PIDFILE"
sleep 2
kill -0 "$(cat "$PIDFILE")" 2>/dev/null || {
    rm -f "$PIDFILE"; printf 'hub died on startup — tail %s/hub.log\n' "$ROOT" >&2; exit 1; }
printf 'hub up on http://127.0.0.1:7777  (token: %s)\n' "$(cat "$ROOT/data/token")"
CMD

cat > /usr/local/bin/pinky-stop << 'CMD'
#!/bin/sh
set -eu
PIDFILE=/opt/pinky-hub/hub.pid
[ -f "$PIDFILE" ] || { printf 'hub not running\n'; exit 0; }
PID="$(cat "$PIDFILE")"
kill "$PID" 2>/dev/null || true
i=0; while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 1; i=$((i+1)); done
kill -9 "$PID" 2>/dev/null || true
rm -f "$PIDFILE"
printf 'hub stopped\n'
CMD

cat > /usr/local/bin/pinky-model-start << 'CMD'
#!/bin/sh
set -eu
ROOT=/opt/pinky-hub
MODEL="${1:-}"; PORT="${2:-8080}"
if [ -z "$MODEL" ]; then
    printf 'usage: pinky-model-start <model.gguf> [port]\n' >&2
    ls -1 "$ROOT/models"/*.gguf 2>/dev/null || printf '  (no models)\n' >&2
    exit 1
fi
case "$MODEL" in */*) printf 'pass a filename, not a path\n' >&2; exit 1 ;; esac
[ -f "$ROOT/models/$MODEL" ] || { printf 'no such model: %s\n' "$MODEL" >&2; exit 1; }
llama-server -m "$ROOT/models/$MODEL" --port "$PORT" --host 127.0.0.1 \
    >> "$ROOT/model.log" 2>&1 &
echo $! > "$ROOT/model.pid"
i=0
while [ "$i" -lt 120 ]; do
    if wget -qO- "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
        printf 'model ready on %s\n' "$PORT"; exit 0
    fi
    kill -0 "$(cat "$ROOT/model.pid")" 2>/dev/null || {
        printf 'llama-server exited — tail %s/model.log\n' "$ROOT" >&2; exit 1; }
    sleep 1; i=$((i+1))
done
printf 'model did not become ready in 120s\n' >&2; exit 1
CMD

cat > /usr/local/bin/pinky-model-stop << 'CMD'
#!/bin/sh
set -eu
PIDFILE=/opt/pinky-hub/model.pid
[ -f "$PIDFILE" ] || { printf 'no model running\n'; exit 0; }
PID="$(cat "$PIDFILE")"
kill "$PID" 2>/dev/null || true
i=0; while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 1; i=$((i+1)); done
kill -9 "$PID" 2>/dev/null || true
rm -f "$PIDFILE"
printf 'model stopped\n'
CMD

chmod +x /usr/local/bin/pinky-start /usr/local/bin/pinky-stop \
         /usr/local/bin/pinky-model-start /usr/local/bin/pinky-model-stop
ok "shortcuts"

printf "\n${GRN}✅ PINKY HUB INSTALLED${NC}\n\n"
printf "  pinky-model-start %s\n" "$MODEL_NAME"
printf "  pinky-start\n\n"
printf "  token: %s\n\n" "$(cat "$HUB_ROOT/data/token")"

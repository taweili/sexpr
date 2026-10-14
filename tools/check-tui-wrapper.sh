#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regression check: ./sexpr-tui.sh must bring the sexpr image up before the
# TUI client, and only when the swank port is not already listening.
#
# The check launches no sbcl. Assertions go through --dry-run (which writes
# the boot file and prints the client command, and touches no port) and
# through argument validation (which fails before anything is spawned). The
# attach path needs a listening swank port, so it is probed against a throwaway
# python socket with a fake sbcl standing in for the client — no image is ever
# booted by this check.
#
# A stale server.lisp can never point the image at last week's checkout, so
# the boot file is asserted to carry the project root with a trailing slash
# (ASDF refuses a registry entry that is not an absolute directory) and the
# ports baked into it are asserted to match the command line.
#
# Run from anywhere: tools/check-tui-wrapper.sh
# Exit 0 on success, 1 on any assertion failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAP="$ROOT/sexpr-tui.sh"
# Scratch dir outside the repo: the check regenerates it for every case.
STATE="$(mktemp -d /tmp/tui-wrapper-check.XXXXXX)"
trap 'rm -rf "$STATE"' EXIT

fails=0
pass() { printf '  ok: %s\n' "$*"; }
bad()  { printf '  FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

need() {
    local needle="$1" hay="$2"
    if [[ "$hay" == *"$needle"* ]]; then
        pass "contains: $needle"
    else
        bad "missing: $needle"
    fi
}

absent() {
    local needle="$1" hay="$2"
    if [[ "$hay" == *"$needle"* ]]; then
        bad "unexpectedly contains: $needle"
    else
        pass "absent: $needle"
    fi
}

status_ok() {
    local desc="$1" rc="$2"
    if [[ "$rc" -eq 0 ]]; then
        pass "$desc: exit 0"
    else
        bad "$desc: expected exit 0, got $rc"
    fi
}

status_fail() {
    local desc="$1" rc="$2"
    if [[ "$rc" -ne 0 ]]; then
        pass "$desc: non-zero exit"
    else
        bad "$desc: expected a failure, got exit 0"
    fi
}

# Dry run with the env defaults pinned, so the assertions never depend on
# whatever the caller exported.
dry() {
    rm -rf "$STATE"
    mkdir -p "$STATE"
    env SEXPR_TUI_STATE_DIR="$STATE" SEXPR_TUI_HOST=127.0.0.1 \
        SEXPR_TUI_SWANK_PORT="${T_SWANK:-4004}" SEXPR_TUI_PUSH_PORT="${T_PUSH:-4005}" \
        "$WRAP" --dry-run "$@" 2>&1
}

boot_file() { cat "$STATE/server.lisp"; }

# The client's Lisp arg list, as it goes into sexpr-tui:main.
args_line() {
    printf '%s\n' "$1" | sed -n 's/^  client args: //p'
}

echo "sexpr-tui.sh — launcher regression check"
echo "========================================="
echo

if [[ -x "$WRAP" ]]; then
    pass "sexpr-tui.sh exists and is executable"
else
    bad "sexpr-tui.sh missing or not executable"
    echo
    echo "$fails assertion(s) failed."
    exit 1
fi

echo "[1] --help exits 0 and documents every flag and env var"
out="$( "$WRAP" --help 2>&1 )"; rc=$?
status_ok "--help" "$rc"
for s in "usage: sexpr-tui.sh" "--no-server" "--server-only" "--dry-run" \
         "--swank-port" "--push-port" "--agent" \
         "SEXPR_TUI_HOST" "SEXPR_TUI_SWANK_PORT" "SEXPR_TUI_PUSH_PORT" \
         "SEXPR_TUI_STATE_DIR" "SEXPR_TUI_READY_TIMEOUT" \
         "SEXPR_TUI_SBCL" "SEXPR_TUI_SBCLINIT"; do
    need "$s" "$out"
done

echo
echo "[2] defaults: both channels named, client and boot file agree"
out="$(dry)"
status_ok "dry run" "$?"
a="$(args_line "$out")"
need 'swank, 4005 push' "$out"
need '"--host" "127.0.0.1"' "$a"
need '"--swank-port" "4004"' "$a"
b="$(boot_file)"
need '(swank:create-server :port 4004 :dont-close t)' "$b"
need '(sexpr.tui:start-server :port 4005)' "$b"
need '(ql:quickload :sexpr :silent t)' "$b"
need '(ql:quickload :swank :silent t)' "$b"
# The client resolves :sexpr-tui from the wrapper's own location, so the
# wrapper runs from any cwd. The argv is shell-quoted, so match the unescaped
# fragment; the literal form is asserted against the boot file below.
need 'central-registry' "$out"
# The image must stay client-free: cl-tuition belongs to the TUI process only.
absent 'tuition' "$b"
# The image honors the SEXPR_* provider env like the CLI, so the greeter's
# model call can succeed in the documented local-dev flow.
need '(sexpr.provider:configure-provider)' "$b"
# A fresh image is an empty society; the boot file seeds the default agent
# the TUI picks on first connect (goal "hello world"), with the same
# "hello world" user line the kernel's user-speaks-first convention needs.
need 'sexpr.tui:spawn' "$b"
need '"hello world"' "$b"
need ':lisp-eval' "$b"
need '(sexpr.tui:inject-note greeter "hello world")' "$b"

echo
echo "[3] the boot file points at THIS checkout, as an absolute directory"
b="$(boot_file)"
need "asdf:*central-registry*)" "$b"
need "push \"${ROOT}/\"" "$b"
absent "push \"${ROOT}\"" "$b"

echo
echo "[4] ports on the command line reach both the boot file and the client"
T_SWANK=4123 T_PUSH=4124 out="$(dry)"
a="$(args_line "$out")"
need '"--swank-port" "4123"' "$a"
b="$(boot_file)"
need ':port 4123 :dont-close t' "$b"
need '(sexpr.tui:start-server :port 4124)' "$b"
need 'for 127.0.0.1:4123' "$b"

echo
echo "[5] a flag beats the environment"
out="$(env SEXPR_TUI_STATE_DIR="$STATE" SEXPR_TUI_SWANK_PORT=4123 \
        "$WRAP" --swank-port 4200 --dry-run 2>&1)"
a="$(args_line "$out")"
need '"--swank-port" "4200"' "$a"
b="$(boot_file)"
need ':port 4200 :dont-close t' "$b"
absent ':port 4123' "$b"

echo
echo "[6] unknown args are forwarded to sexpr-tui:main, spaces included"
out="$(dry --agent Alpha)"
need '"--agent" "Alpha"' "$(args_line "$out")"
out="$(dry --agent "Alpha Beta" --foo bar)"
need '"--agent" "Alpha Beta"' "$(args_line "$out")"
need '"--foo" "bar"' "$(args_line "$out")"
# The wrapper's own flags must not be duplicated into the client argv.
out="$(dry --swank-port 4300)"
absent '"--swank-port" "4300" "--swank-port"' "$(args_line "$out")"

echo
echo "[7] the swank feature-negotiation hook is suppressed"
echo "    (it names packages the client image does not have, and the client"
echo "     treats the unparseable :new-features packet as a fatal reader error)"
b="$(boot_file)"
need 'SYNC-FEATURES-TO-EMACS' "$b"
need '"*PRE-REPLY-HOOK*"' "$b"

echo
echo "[8] a missing push port is not fatal at the image"
b="$(boot_file)"
need 'SEXPR-TUI PUSH CHANNEL OFF' "$b"
need 'handler-case' "$b"

echo
echo "[9] argument validation fails before anything is spawned"
# check_fail DESC EXPECTED [VAR=VALUE...] -- WRAPPER-ARGS...
check_fail() {
    local desc="$1" want="$2"; shift 2
    local env=() out rc
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        env+=("$1")
        shift
    done
    shift
    out="$(env SEXPR_TUI_STATE_DIR="$STATE" "${env[@]}" "$WRAP" --dry-run "$@" 2>&1)"; rc=$?
    status_fail "$desc" "$rc"
    need "$want" "$out"
}
check_fail "swank and push on one port" "different ports" -- --swank-port 4004 --push-port 4004
check_fail "non-numeric swank port"     "must be a number" -- --swank-port abc
check_fail "zero port"                  "greater than 0"   -- --swank-port 0
check_fail "--host with no value"       "requires a value" -- --host
check_fail "missing sbclinit"           "sbcl init not found" \
    SEXPR_TUI_SBCLINIT=/tmp/no-such-sbclinit --
check_fail "missing sbcl binary"        "sbcl not found on PATH" \
    SEXPR_TUI_SBCL=no-such-sbcl-xyz --

echo
echo "[10] a dry run writes the boot file and launches nothing"
rm -rf "$STATE"; mkdir -p "$STATE"
dry >/dev/null
if [[ -s "$STATE/server.lisp" ]]; then
    pass "boot file written"
else
    bad "boot file missing or empty"
fi
for f in server.pid server.stdin.fifo server.log; do
    if [[ -e "$STATE/$f" ]]; then
        bad "dry run left behind $f"
    else
        pass "no $f after a dry run"
    fi
done

echo
echo "[11] an already-listening swank port is adopted, never duplicated"

# A fake sbcl so the client half is a no-op echo of its own argv: this check
# must never boot a real image or a real TUI.
mkdir -p "$STATE"
cat > "$STATE/fake-sbcl" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done
FAKE
chmod +x "$STATE/fake-sbcl"

# A long-lived stand-in for the TUI client, so the interrupt test has
# something to interrupt.
cat > "$STATE/slow-sbcl" <<'FAKE'
#!/usr/bin/env bash
echo $$ > "${SLOW_PID_FILE:-/tmp/slow-sbcl.pid}"
sleep 300
FAKE
chmod +x "$STATE/slow-sbcl"

# stand up a fake swank listener on PORT for SEC seconds and wait until it
# accepts connections. The wrapper must see this as an image it does not own.
start_listener() {
    local port="$1" sec="${2:-30}"
    cat > "$STATE/listener-${port}.py" <<PY
import socket, time
# Drain every probe: a backlog of 1 refuses the second connect, which would
# look like the image going away between the wait loop and the wrapper.
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $port))
s.listen(32)
s.settimeout(1)
deadline = time.time() + $sec
while time.time() < deadline:
    try:
        c, _ = s.accept()
    except socket.timeout:
        continue
    except OSError:
        break
    c.close()
PY
    python3 "$STATE/listener-${port}.py" &
    listener_pid=$!
    for _ in $(seq 1 40); do
        if timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}
stop_listener() {
    [[ -n "${listener_pid:-}" ]] && kill "$listener_pid" 2>/dev/null
    wait "$listener_pid" 2>/dev/null
    listener_pid=""
}

# --no-server must fail fast with a usable message instead of hanging or
# silently starting something.
out="$(env SEXPR_TUI_STATE_DIR="$STATE" SEXPR_TUI_SBCL="$STATE/fake-sbcl" \
        SEXPR_TUI_SWANK_PORT=4823 SEXPR_TUI_PUSH_PORT=4824 \
        "$WRAP" --no-server 2>&1)"; rc=$?
status_fail "--no-server with no image listening" "$rc"
need 'no image at 127.0.0.1:4823' "$out"
absent 'starting image at' "$out"

if command -v python3 >/dev/null 2>&1 && start_listener 4821; then
    out="$(env SEXPR_TUI_STATE_DIR="$STATE" SEXPR_TUI_SBCL="$STATE/fake-sbcl" \
              SEXPR_TUI_SWANK_PORT=4821 SEXPR_TUI_PUSH_PORT=4822 \
              "$WRAP" --agent Alpha 2>&1)"; rc=$?
    status_ok "attach to an existing image" "$rc"
    need 'image already up at 127.0.0.1:4821' "$out"
    need 'attaching' "$out"
    absent 'starting image at' "$out"
    absent 'stopping image' "$out"
    # The fake client echoes its argv; push is only requested when listening.
    need '--swank-port' "$out"
    absent '--push-port' "$out"
    stop_listener

    echo
echo "[12] an interrupted wrapper takes the client down too"
    start_listener 4831 || true
    rm -f "$STATE/slow.pid"
    env SEXPR_TUI_STATE_DIR="$STATE" SEXPR_TUI_SBCL="$STATE/slow-sbcl" \
        SEXPR_TUI_SWANK_PORT=4831 SEXPR_TUI_PUSH_PORT=4832 \
        SLOW_PID_FILE="$STATE/slow.pid" \
        "$WRAP" --no-server >/dev/null 2>&1 &
    wrapper_pid=$!
    for _ in $(seq 1 40); do
        [[ -s "$STATE/slow.pid" ]] && break
        sleep 0.25
    done
    client_pid="$(cat "$STATE/slow.pid" 2>/dev/null || true)"
    status_ok "the client came up" "$( [[ -n "$client_pid" ]] && echo 0 || echo 1 )"
    # SIGTERM, not SIGINT: a non-interactive bash ignores SIGINT, and the TUI
    # reads ^C as input while in raw mode, so SIGINT is not the real path.
    kill -TERM "$wrapper_pid" 2>/dev/null
    for _ in $(seq 1 20); do
        kill -0 "$client_pid" 2>/dev/null || break
        sleep 0.25
    done
    if kill -0 "$client_pid" 2>/dev/null; then
        bad "client survived the interrupted wrapper"
    else
        pass "client torn down with the wrapper"
    fi
    stop_listener
else
    echo "  skip: python3 unavailable or no listener"
fi

stop_listener
echo
echo "[13] SPDX header on the wrapper and on the generated boot file"
head -3 "$WRAP" | grep -q 'SPDX-License-Identifier: GPL-3.0-or-later' \
    && pass "wrapper carries the SPDX header" || bad "wrapper missing the SPDX header"
dry >/dev/null
head -3 "$STATE/server.lisp" | grep -q 'SPDX-License-Identifier: GPL-3.0-or-later' \
    && pass "boot file carries the SPDX header" || bad "boot file missing the SPDX header"

echo
if [[ $fails -eq 0 ]]; then
    echo "OK — all assertions passed."
    exit 0
else
    echo "$fails assertion(s) FAILED."
    exit 1
fi

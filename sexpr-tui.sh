#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# sexpr-tui.sh — start the remote TUI, bringing up the sexpr image first.
#
# The TUI (:sexpr-tui, cl-tuition) is a SEPARATE SBCL process that renders a
# projection of a running sexpr image (notes/tui.md §7). Two channels carry
# that projection, and both servers live in the IMAGE:
#   swank   request/response   eval + typed sexpr.tui RPCs   default 4004
#   push    one-way, live      transcript/status deltas       default 4005
# So the image has to be up before the client can render a single row. This
# wrapper is the launcher for both halves:
#     ./sexpr-tui.sh                 start the image if needed, run the TUI
#     ./sexpr-tui.sh --agent Alpha   same, pick Alpha on connect
#     ./sexpr-tui.sh --no-server     attach to an image started by hand
#     ./sexpr-tui.sh --server-only   start/reuse the image and wait
#     ./sexpr-tui.sh --dry-run       print what would be generated, launch nothing
#
# Environment (all optional, all default the local-dev way):
#   SEXPR_TUI_HOST           image host            (default 127.0.0.1)
#   SEXPR_TUI_SWANK_PORT     swank port            (default 4004)
#   SEXPR_TUI_PUSH_PORT      push port             (default 4005)
#   SEXPR_TUI_STATE_DIR      boot file + logs      (default /tmp/sexpr-tui)
#   SEXPR_TUI_READY_TIMEOUT  seconds to wait       (default 120)
#   SEXPR_TUI_SBCL           sbcl binary           (default sbcl)
#   SEXPR_TUI_SBCLINIT       sbcl init file        (default ~/.sbclinit)
#
# OWNERSHIP: "server running" means the SWANK port accepts a TCP connection.
# The wrapper starts an image only when that fails, and tears down only an
# image it started itself — one the caller brought up by hand is left exactly
# as found. A push channel is picked up only when it is actually listening,
# so an image that came up without one still renders (no live deltas).
#
# Everything after the flags above is forwarded to sexpr-tui:main verbatim
# (--agent NAME, --help, ...).
#
# If the image will not come up, read $SEXPR_TUI_STATE_DIR/server.log — the
# boot file it runs is $SEXPR_TUI_STATE_DIR/server.lisp, regenerated on
# every run, so edits to it do not survive.

set -uo pipefail

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------

ROOT="$(cd "$(dirname "$0")" && pwd)"

HOST="${SEXPR_TUI_HOST:-127.0.0.1}"
SWANK_PORT="${SEXPR_TUI_SWANK_PORT:-4004}"
PUSH_PORT="${SEXPR_TUI_PUSH_PORT:-4005}"
STATE_DIR="${SEXPR_TUI_STATE_DIR:-/tmp/sexpr-tui}"
READY_TIMEOUT="${SEXPR_TUI_READY_TIMEOUT:-120}"
SBCL="${SEXPR_TUI_SBCL:-sbcl}"
SBCLINIT="${SEXPR_TUI_SBCLINIT:-$HOME/.sbclinit}"

SERVER_PID=""
CLIENT_PID=""
SERVER_FIFO=""

log() { printf 'sexpr-tui: %s\n' "$*" >&2; }
fail() { printf 'sexpr-tui: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
usage: sexpr-tui.sh [OPTIONS] [sexpr-tui args...]

Start the remote TUI, bringing up the sexpr image it needs first. "The image
is running" means the swank port accepts a TCP connection; only an image this
wrapper started is torn down when the client exits.

options:
  --host HOST            image host                 (default 127.0.0.1)
  --swank-port PORT      swank port                 (default 4004)
  --push-port PORT       push channel port          (default 4005)
  --no-server            attach only; fail if the image is not up
  --server-only          start/reuse the image and wait for it
  --dry-run              print the boot file and the client command, launch nothing
  --help, -h             this message

environment (override with `VAR=value ./sexpr-tui.sh ...`):
  SEXPR_TUI_HOST            image host            (default 127.0.0.1)
  SEXPR_TUI_SWANK_PORT      swank port            (default 4004)
  SEXPR_TUI_PUSH_PORT       push port             (default 4005)
  SEXPR_TUI_STATE_DIR       boot file + logs      (default /tmp/sexpr-tui)
  SEXPR_TUI_READY_TIMEOUT   seconds to wait       (default 120)
  SEXPR_TUI_SBCL            sbcl binary           (default sbcl)
  SEXPR_TUI_SBCLINIT        sbcl init file        (default ~/.sbclinit)

sexpr-tui args (forwarded verbatim):
  --agent NAME             agent name to pick on connect

images that will not come up leave their reason in
$SEXPR_TUI_STATE_DIR/server.log; the boot file is server.lisp.

examples:
  ./sexpr-tui.sh                        # start image if needed, run the TUI
  ./sexpr-tui.sh --agent Alpha          # same, pick Alpha
  ./sexpr-tui.sh --no-server            # attach to an image started by hand
  SEXPR_TUI_SWANK_PORT=4100 ./sexpr-tui.sh --swank-port 4100
USAGE
}

# ---------------------------------------------------------------------------
# probes
# ---------------------------------------------------------------------------

# A TCP connect is enough: localhost dev needs no auth (notes/tui.md §7,
# "Swank has no auth by default"). nc is used when present; the /dev/tcp path
# is the portable fallback and needs nothing beyond bash.
port_open() {
    local host="$1" port="$2"
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 1 "$host" "$port" 2>/dev/null
        return $?
    fi
    timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
    return $?
}

# kill -0 reports a zombie as alive, and the image is never reaped until this
# shell exits — so a boot failure would otherwise look like a live process for
# the whole grace period. Ask ps for the state instead.
image_alive() {
    local state
    state="$(ps -o state= -p "$1" 2>/dev/null)"
    [[ -n "$state" && "$state" != Z* ]]
}

# Wait for HOST:PORT to accept connections. Returns 0 on open, 1 on timeout,
# 2 when the watched PID died first — the "the image crashed on boot" case,
# which deserves its own message rather than a 120 s silence.
wait_port() {
    local host="$1" port="$2" timeout_s="$3" pid="${4:-}"
    local deadline=$((SECONDS + timeout_s))
    while (( SECONDS < deadline )); do
        if port_open "$host" "$port"; then
            return 0
        fi
        if [[ -n "$pid" ]] && ! image_alive "$pid"; then
            return 2
        fi
        sleep 0.5
    done
    return 1
}

# Escape one value for use inside a Lisp string literal. The client argv is
# built as a Lisp list in an --eval form, so backslash and double quote are
# the only two that need escaping.
lisp_quote() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# ARGS... -> a run of quoted Lisp strings, for embedding in `main '(...)`.
lisp_arg_list() {
    local out="" a
    for a in "$@"; do
        out+="\"$(lisp_quote "$a")\" "
    done
    printf '%s' "$out"
}

# Both processes need the project root in the ASDF registry. ASDF refuses a
# registry entry that is not an absolute DIRECTORY, so the trailing separator
# is mandatory, not cosmetic. Derived from the wrapper's own location rather
# than from the caller's cwd, so the wrapper works from any directory.
ROOT_DIR="${ROOT%/}/"
ROOT_ESC="$(lisp_quote "$ROOT_DIR")"

# ---------------------------------------------------------------------------
# the image
# ---------------------------------------------------------------------------

# Write the boot file the image runs. Generated on every run: the ports and
# the project root are baked in, so a stale server.lisp can never point the
# image at last week's image.
write_server_boot() {
    mkdir -p "$STATE_DIR" || fail "cannot create state dir: $STATE_DIR"
    local boot="$STATE_DIR/server.lisp"
    cat > "$boot" <<EOF
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; server.lisp — GENERATED by sexpr-tui.sh for ${HOST}:${SWANK_PORT}. Do not
;;;; edit by hand: the wrapper rewrites it on every run.
;;;;
;;;; Boots the image the remote TUI attaches to. Swank carries
;;;; request/response (typed sexpr.tui RPCs); sexpr.tui:start-server carries
;;;; the one-way delta channel. notes/tui.md §7 is the design for both.

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(push "${ROOT_ESC}" asdf:*central-registry*)
;;;; The trailing slash above is required: ASDF treats a registry entry without
;;;; one as a file name and refuses to search it.
(ql:quickload :sexpr :silent t)
(ql:quickload :swank :silent t)

;;;; The client image loads :sexpr-tui ONLY — depending on :sexpr would pull
;;;; the kernel into the client process and create a second society (R023).
;;;; Swank's *pre-reply-hook* sends an unsolicited :new-features packet that
;;;; names every package the IMAGE loaded — cffi-sys, alexandria,
;;;; chipz-system — and none of those exist in the client image. The client's
;;;; parse-packet then fails to read that packet, classifies the failure as a
;;;; fatal :reader-error instead of skipping an unsolicited packet, and the
;;;; first RPC of every session dies. Swank ships both names private, so they
;;;; are reached by symbol name rather than a qualified reader.
(let ((hook (symbol-value (intern "*PRE-REPLY-HOOK*" (find-package "SWANK")))))
  (setf (symbol-value (intern "*PRE-REPLY-HOOK*" (find-package "SWANK")))
        (remove (intern "SYNC-FEATURES-TO-EMACS" (find-package "SWANK")) hook)))

(swank:create-server :port ${SWANK_PORT} :dont-close t)

;;;; A busy push port is not fatal: swank alone still renders a TUI, just
;;;; without live deltas. The wrapper learns the outcome from the port probe,
;;;; so it omits --push-port rather than handing the client a dead channel.
(let ((push (handler-case
                (sexpr.tui:start-server :port ${PUSH_PORT})
              (error (e)
                (format *error-output* "SEXPR-TUI PUSH CHANNEL OFF: ~A~%" e)
                nil))))
  (format *error-output* "SEXPR-TUI IMAGE UP: swank=${SWANK_PORT} push=~A~%"
          (or (and push (sexpr.tui:push-server-port push)) "off")))
EOF
    printf '%s' "$boot"
}

# The image is a long-lived server, so it must not exit when its --eval forms
# finish. `sbcl --non-interactive` appends (:QUIT) to its option list and
# sb-ext:exit kills every thread, which takes the swank server down with the
# process. Instead the image runs interactively with its stdin bound to a FIFO
# the wrapper holds open: the reader loop blocks on that empty FIFO forever,
# which is a real syscall block and keeps the image alive with no busy loop.
#
# --disable-debugger: a boot-time error (a missing dep, a port already bound)
# must kill the image, not park it in the debugger reading an empty FIFO. An
# unhandled error that parks in the debugger looks like a hang — wait_port would
# burn the whole READY_TIMEOUT before reporting anything.
start_image() {
    local boot log_file
    boot="$(write_server_boot)"
    log_file="$STATE_DIR/server.log"
    SERVER_FIFO="$STATE_DIR/server.stdin.fifo"
    rm -f "$SERVER_FIFO"
    mkfifo "$SERVER_FIFO" || fail "cannot create fifo: $SERVER_FIFO"

    "$SBCL" --noinform --disable-debugger --load "$boot" \
        < "$SERVER_FIFO" > "$log_file" 2>&1 &
    SERVER_PID=$!
    printf '%s' "$SERVER_PID" > "$STATE_DIR/server.pid"
    exec 3>"$SERVER_FIFO"

    log "starting image at ${HOST}:${SWANK_PORT} (pid ${SERVER_PID}) — log: ${log_file}"
    wait_port "$HOST" "$SWANK_PORT" "$READY_TIMEOUT" "$SERVER_PID"
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
        return 0
    fi
    local reason
    if [[ "$rc" -eq 2 ]]; then
        reason="image exited before binding ${SWANK_PORT}"
    else
        reason="timed out after ${READY_TIMEOUT}s waiting for ${HOST}:${SWANK_PORT}"
    fi
    log "${reason} — ${log_file}"
    log "--- last lines of ${log_file} ---"
    tail -25 "$log_file" >&2 2>/dev/null
    fail "see ${log_file} — boot file is ${boot}"
}

# An image the caller started by hand: nothing to tear down, and a FIFO was
# never opened for it.
cleanup() {
    local rc=$?
    if [[ -n "$SERVER_PID" ]] && image_alive "$SERVER_PID"; then
        log "stopping image (pid ${SERVER_PID})"
        kill "$SERVER_PID" 2>/dev/null
        local i=0
        while (( i < 10 )) && image_alive "$SERVER_PID"; do
            sleep 0.5
            i=$((i + 1))
        done
        image_alive "$SERVER_PID" && kill -KILL "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
    fi
    # Closing the FIFO write end is the polite half: the image's reader sees
    # EOF and unwinds. The kill above is the belt.
    exec 3>&- 2>/dev/null
    [[ -n "$SERVER_FIFO" && -p "$SERVER_FIFO" ]] && rm -f "$SERVER_FIFO"
    rm -f "$STATE_DIR/server.pid" 2>/dev/null
    if [[ -n "$CLIENT_PID" ]] && image_alive "$CLIENT_PID"; then
        # An interrupt reaching this shell does not reach the client unless the
        # two share a process group, so an interrupted run would otherwise
        # leave the TUI running against a dead image. The client is normally
        # gone already — the wrapper only exits when it exits.
        kill "$CLIENT_PID" 2>/dev/null
        wait "$CLIENT_PID" 2>/dev/null
    fi
    exit "$rc"
}
trap cleanup EXIT
# No SIGINT trap: a non-interactive bash ignores SIGINT anyway, and the TUI
# reads ^C as input while in raw mode (ISIG off), so it never reaches us. If a
# trap were set, bash would defer it until `wait` returned, which would defeat
# the cleanup. SIGTERM, SIGHUP and SIGKILL reach the EXIT trap immediately.

# ---------------------------------------------------------------------------
# the client
# ---------------------------------------------------------------------------

build_client_cmd() {
    CLIENT_CMD=("$SBCL" --non-interactive --load "$SBCLINIT"
                --eval "(push \"${ROOT_ESC}\" asdf:*central-registry*)"
                --eval '(ql:quickload :sexpr-tui :print t)'
                --eval "(sb-ext:exit :code (sexpr-tui:main '($(lisp_arg_list "${CLIENT_ARGS[@]}"))))")
}

# ARGS... -> a shell-quoted argv line, for the dry-run display.
print_argv() {
    local a
    for a in "$@"; do
        printf '%q ' "$a"
    done
}

validate() {
    command -v "$SBCL" >/dev/null 2>&1 || fail "sbcl not found on PATH (set SEXPR_TUI_SBCL)"
    [[ -f "$SBCLINIT" ]] || fail "sbcl init not found: $SBCLINIT (set SEXPR_TUI_SBCLINIT)"
    [[ "$SWANK_PORT" =~ ^[0-9]+$ ]] || fail "--swank-port must be a number: $SWANK_PORT"
    [[ "$PUSH_PORT" =~ ^[0-9]+$ ]] || fail "--push-port must be a number: $PUSH_PORT"
    (( SWANK_PORT > 0 && PUSH_PORT > 0 )) || fail "ports must be greater than 0"
    (( SWANK_PORT != PUSH_PORT )) || fail "swank and push must use different ports"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

DRY_RUN=0
SERVER_ONLY=0
NO_SERVER=0
CLIENT_ARGS=()

while (( $# > 0 )); do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --server-only)
            SERVER_ONLY=1
            shift
            ;;
        --no-server)
            NO_SERVER=1
            shift
            ;;
        --host)
            (( $# >= 2 )) || fail "--host requires a value"
            HOST="$2"
            shift 2
            ;;
        --swank-port)
            (( $# >= 2 )) || fail "--swank-port requires a value"
            SWANK_PORT="$2"
            shift 2
            ;;
        --push-port)
            (( $# >= 2 )) || fail "--push-port requires a value"
            PUSH_PORT="$2"
            shift 2
            ;;
        *)
            CLIENT_ARGS+=("$1")
            shift
            ;;
    esac
done

validate

# The two flags the client must see, in front of anything the caller passed,
# so an explicit --agent still wins over the defaults.
CLIENT_ARGS=(--host "$HOST" --swank-port "$SWANK_PORT" "${CLIENT_ARGS[@]}")

build_client_cmd

if (( DRY_RUN )); then
    log "dry run — nothing was launched"
    printf '  image:      %s:%s swank, %s push\n' "$HOST" "$SWANK_PORT" "$PUSH_PORT"
    printf '  state dir:  %s\n' "$STATE_DIR"
    printf '  boot:       %s/server.lisp\n' "$STATE_DIR"
    printf '  log:        %s/server.log\n' "$STATE_DIR"
    printf '  client:     %s\n' "$(print_argv "${CLIENT_CMD[@]}")"
    printf '  client args: %s\n' "$(lisp_arg_list "${CLIENT_ARGS[@]}")"
    printf '\n----- %s/server.lisp -----\n' "$STATE_DIR"
    write_server_boot >/dev/null
    cat "$STATE_DIR/server.lisp"
    exit 0
fi

if (( NO_SERVER )); then
    port_open "$HOST" "$SWANK_PORT" ||
        fail "no image at ${HOST}:${SWANK_PORT} — start one, or drop --no-server and let this wrapper start it"
    log "attaching to an existing image at ${HOST}:${SWANK_PORT}"
elif port_open "$HOST" "$SWANK_PORT"; then
    log "image already up at ${HOST}:${SWANK_PORT} — attaching (ownership stays with its owner)"
else
    start_image
fi

# The push channel is optional at the client. Ask for it only when it is
# actually listening, so an image without one still renders. 3 s is enough
# in the case that matters — the push server is bound in the same boot file,
# milliseconds after swank — and short enough that an image without one does
# not feel slow to start.
PUSH_UP=0
if wait_port "$HOST" "$PUSH_PORT" 3 ""; then
    PUSH_UP=1
    CLIENT_ARGS=(--push-port "$PUSH_PORT" "${CLIENT_ARGS[@]}")
    build_client_cmd
fi

if (( SERVER_ONLY )); then
    log "image up — swank=${HOST}:${SWANK_PORT}${PUSH_UP:+ push=$PUSH_PORT}"
    if [[ -n "$SERVER_PID" ]]; then
        log "waiting on pid ${SERVER_PID} (Ctrl-C to stop)"
        wait "$SERVER_PID" 2>/dev/null
    else
        log "image is externally owned — waiting for the swank port to close"
        while port_open "$HOST" "$SWANK_PORT"; do
            sleep 2
        done
    fi
    exit 0
fi

log "running the TUI client"
# Backgrounded so cleanup can name it: an interrupt on this shell must take the
# client down too, and `wait` keeps the foreground/tty behaviour the same.
"${CLIENT_CMD[@]}" &
CLIENT_PID=$!
wait "$CLIENT_PID"
rc=$?
CLIENT_PID=""
exit "$rc"

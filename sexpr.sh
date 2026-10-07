#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Local dev wrapper: run ./sexpr against the on-host OpenAI-compatible
# endpoint with Qwythos-9B-v2, wrapped in rlwrap for line editing in
# the chat loop. Override any setting by exporting it before invoking,
# e.g. `SEXPR_MODEL=Other ./sexpr.sh`.
#
# Environment variables (all optional, all default the local-dev way):
#   SEXPR_PROVIDER       provider name         (default: openai-compatible)
#   SEXPR_BASE_URL       provider base URL     (default: http://localhost:6969/v1)
#   SEXPR_MODEL          model name            (default: Qwythos-9B-v2)
#   SEXPR_CAPABILITIES   comma-separated list  (default: all four grants)
#                        Known names: fs-read, fs-write, process, lisp-eval
#                        Set to `fs-read` for a read-only session.
#
# A default --goal is injected only when the caller did not supply one,
# and the SEXPR_CAPABILITIES list is forwarded as --capability flags
# BEFORE the caller's arguments so caller --capability grants add to the
# set without replacing it:
#     ./sexpr.sh                                  # default goal + all caps
#     ./sexpr.sh --goal "Do X" --load foo.lisp     # explicit goal
#     ./sexpr.sh --capability process             # (already granted by default)
#     SEXPR_CAPABILITIES=fs-read ./sexpr.sh       # read-only override
#     ./sexpr.sh --help                            # this message
#
# Example runner:
#     ./sexpr.sh example                           # run all examples
#     ./sexpr.sh example 01                        # run example 01
#     ./sexpr.sh example 01-transcript             # run by name
#     ./sexpr.sh example --list                    # list available examples
#
# The binary's own flag list is `./sexpr --help`.

set -euo pipefail

# ---------------------------------------------------------------------------
# example subcommand
# ---------------------------------------------------------------------------

EXAMPLES_DIR="$(cd "$(dirname "$0")" && pwd)/examples"

run_example() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "error: example file not found: $file" >&2
        return 1
    fi
    local base
    base="$(basename "$file")"
    echo "" >&2
    echo "--- Running example: $base ---" >&2
    sbcl --non-interactive \
        --load "${HOME}/.sbclinit" \
        --load "$file"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "--- $base: PASSED ---" >&2
    else
        echo "--- $base: FAILED (exit $rc) ---" >&2
    fi
    return $rc
}

cmd_example() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        cat <<'USAGE_EXAMPLE'
usage: sexpr.sh example [OPTIONS] [NAME]

Run sexpr examples. Each example is a standalone .lisp file that loads
sexpr via Quicklisp, exercises one concept, and prints visible output.
No model endpoint or API key is needed.

options:
  --list          list available examples and exit
  --help, -h      show this help and exit

examples:
  ./sexpr.sh example                # run all examples
  ./sexpr.sh example 01             # run example 01
  ./sexpr.sh example 01-transcript  # run by full name
  ./sexpr.sh example 05 06 07       # run multiple examples
USAGE_EXAMPLE
        exit 0
    fi

    if [[ "${1:-}" == "--list" ]]; then
        echo "Available examples:" >&2
        for f in "$EXAMPLES_DIR"/*.lisp; do
            if [[ -f "$f" ]]; then
                echo "  $(basename "$f" .lisp)" >&2
            fi
        done
        exit 0
    fi

    local names=("$@")
    local run=()

    if [[ ${#names[@]} -eq 0 ]]; then
        # run all examples
        for f in "$EXAMPLES_DIR"/*.lisp; do
            if [[ -f "$f" ]]; then
                run+=("$f")
            fi
        done
    else
        # resolve each name to a file
        for name in "${names[@]}"; do
            # try exact match first (e.g. 01-transcript.lisp)
            if [[ -f "$EXAMPLES_DIR/$name" ]]; then
                run+=("$EXAMPLES_DIR/$name")
            elif [[ -f "$EXAMPLES_DIR/$name.lisp" ]]; then
                # name without .lisp extension (e.g. 01-transcript)
                run+=("$EXAMPLES_DIR/$name.lisp")
            else
                # try matching by number prefix (e.g. 01 matches 01-*)
                local match
                match="$(ls "$EXAMPLES_DIR"/$name*.lisp 2>/dev/null | head -1 || true)"
                if [[ -n "$match" ]]; then
                    run+=("$match")
                else
                    echo "error: unknown example: $name" >&2
                    echo "Try './sexpr.sh example --list' to see available examples." >&2
                    exit 1
                fi
            fi
        done
    fi

    if [[ ${#run[@]} -eq 0 ]]; then
        echo "error: no example files found in $EXAMPLES_DIR" >&2
        exit 1
    fi

    local failed=0
    for f in "${run[@]}"; do
        if ! run_example "$f"; then
            failed=$((failed + 1))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        echo "" >&2
        echo "$failed example(s) failed." >&2
        exit 1
    fi

    echo "" >&2
    echo "All examples passed." >&2
}

# ---------------------------------------------------------------------------
# repl subcommand
# ---------------------------------------------------------------------------

cmd_repl() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        cat <<'USAGE_REPL'
usage: sexpr.sh repl

Enter an unrestricted Common Lisp REPL with sexpr loaded. The REPL starts
in the :sexpr.repl package (aggregating — make-agent, agent-transcript,
render-events, eval-in-sandbox, define-tool are unqualified). ,exit leaves.

No model endpoint or API key is needed — the REPL never calls the model
(it's a dev surface). Reach the model by evaluating a provider-call form
yourself, e.g. (sexpr.provider:provider-call nil '((:role "user"
:content "hi"))).

environment (read by sexpr via ~/.sbclinit / configure-provider):
  SEXPR_PROVIDER / SEXPR_MODEL / SEXPR_BASE_URL  see `sexpr.sh --help`
USAGE_REPL
        exit 0
    fi

    # --non-interactive: sbcl runs the --eval forms then exits; the repl
    # --eval reads stdin (the terminal via rlwrap) until ,exit/EOF, then
    # returns and sbcl exits. No SEXPR_PROVIDER/MODEL/CAPABILITIES injected —
    # the REPL never calls the model, so provider config is irrelevant here.
    exec rlwrap sbcl --noinform --non-interactive \
        --load "${HOME}/.sbclinit" \
        --eval "(ql:quickload :sexpr :silent t)" \
        --eval "(sexpr.repl:repl)"
}

# ---------------------------------------------------------------------------
# dispatch: example subcommand vs repl vs chat
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "example" ]]; then
    shift
    cmd_example "$@"
    exit $?
fi

if [[ "${1:-}" == "repl" ]]; then
    shift
    cmd_repl "$@"
    exit $?
fi

if [[ " $* " == *" --help "* || " $* " == *" -h "* ]]; then
    cat <<'USAGE'
usage: sexpr.sh [sexpr flags...]
       sexpr.sh example [OPTIONS] [NAME]
       sexpr.sh repl

Local dev wrapper: sets provider/model/capability defaults and runs
./sexpr under rlwrap. Forwarded arguments are passed through verbatim,
so the full flag list is:
  ./sexpr --help

Run examples with:
  ./sexpr.sh example [OPTIONS] [NAME]

environment (override with `VAR=value ./sexpr.sh ...`):
  SEXPR_PROVIDER       provider name         (default: openai-compatible)
  SEXPR_BASE_URL       provider base URL     (default: http://localhost:6969/v1)
  SEXPR_MODEL          model name            (default: Qwythos-9B-v2)
  SEXPR_CAPABILITIES   comma-separated list  (default: all four grants)
                       Known: fs-read, fs-write, process, lisp-eval

sexpr flags (a subset; see `./sexpr --help` for the full list):
  --goal TEXT          agent goal (a default is injected when absent)
  --load FILE          start from a saved transcript
  --provider NAME      override SEXPR_PROVIDER
  --model NAME         override SEXPR_MODEL
  --capability NAME    grant a capability (repeatable; additive with
                       SEXPR_CAPABILITIES and the built-in fs-read)

examples:
  ./sexpr.sh                                  # chat with all caps
  SEXPR_CAPABILITIES=fs-read ./sexpr.sh      # read-only, no write
  ./sexpr.sh example                          # run all examples
  ./sexpr.sh example 01                       # run example 01
  ./sexpr.sh repl                             # standalone dev REPL
USAGE
    exit 0
fi

export SEXPR_PROVIDER="${SEXPR_PROVIDER:-openai-compatible}"
export SEXPR_BASE_URL="${SEXPR_BASE_URL:-http://localhost:6969/v1}"
export SEXPR_MODEL="${SEXPR_MODEL:-Qwythos-9B-v2}"

# SEXPR_CAPABILITIES (comma-separated) is forwarded as repeated --capability
# flags BEFORE user args so user --capability grants add to the default set.
caps_arg=()
IFS=',' read -r -a caps <<< "${SEXPR_CAPABILITIES:-fs-read,fs-write,process,lisp-eval}"
for cap in "${caps[@]}"; do
    # trim whitespace (a common env-var paste artifact)
    cap="$(printf '%s' "$cap" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ -n "$cap" ]]; then
        caps_arg+=(--capability "$cap")
    fi
done

if [[ ! " $* " == *" --goal "* ]]; then
    args=(--goal "You are an expert in LISP" "${caps_arg[@]}" "$@")
else
    args=("${caps_arg[@]}" "$@")
fi

exec rlwrap ./sexpr "${args[@]}"

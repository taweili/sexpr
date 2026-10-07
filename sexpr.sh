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
#   SEXPR_CAPABILITIES   comma-separated list  (default: fs-read,fs-write)
#                        Known names: fs-read, fs-write, process, lisp-eval
#                        Set to `fs-read` for a read-only session.
#
# A default --goal is injected only when the caller did not supply one,
# and the SEXPR_CAPABILITIES list is forwarded as --capability flags
# BEFORE the caller's arguments so caller --capability grants add to the
# set without replacing it:
#     ./sexpr.sh                                     # default goal + read+write
#     ./sexpr.sh --goal "Do X" --load foo.lisp      # explicit goal
#     ./sexpr.sh --capability process              # also allow shell
#     SEXPR_CAPABILITIES=fs-read ./sexpr.sh        # read-only override
#     ./sexpr.sh --help                            # this message
#
# The binary's own flag list is `./sexpr --help`.

set -euo pipefail

if [[ " $* " == *" --help "* || " $* " == *" -h "* ]]; then
    cat <<'USAGE'
usage: sexpr.sh [sexpr flags...]

Local dev wrapper: sets provider/model/capability defaults and runs
./sexpr under rlwrap. Forwarded arguments are passed through verbatim,
so the full flag list is:
  ./sexpr --help

environment (override with `VAR=value ./sexpr.sh ...`):
  SEXPR_PROVIDER       provider name         (default: openai-compatible)
  SEXPR_BASE_URL       provider base URL     (default: http://localhost:6969/v1)
  SEXPR_MODEL          model name            (default: Qwythos-9B-v2)
  SEXPR_CAPABILITIES   comma-separated list  (default: fs-read,fs-write)
                       Known: fs-read, fs-write, process, lisp-eval

sexpr flags (a subset; see `./sexpr --help` for the full list):
  --goal TEXT          agent goal (a default is injected when absent)
  --load FILE          start from a saved transcript
  --provider NAME      override SEXPR_PROVIDER
  --model NAME         override SEXPR_MODEL
  --capability NAME    grant a capability (repeatable; additive with
                       SEXPR_CAPABILITIES and the built-in fs-read)

examples:
  ./sexpr.sh                                  # chat with the default caps
  ./sexpr.sh --capability process            # also allow the shell tool
  SEXPR_CAPABILITIES=fs-read ./sexpr.sh      # read-only, no write
USAGE
    exit 0
fi

export SEXPR_PROVIDER="${SEXPR_PROVIDER:-openai-compatible}"
export SEXPR_BASE_URL="${SEXPR_BASE_URL:-http://localhost:6969/v1}"
export SEXPR_MODEL="${SEXPR_MODEL:-Qwythos-9B-v2}"

# SEXPR_CAPABILITIES (comma-separated) is forwarded as repeated --capability
# flags BEFORE user args so user --capability grants add to the default set.
caps_arg=()
IFS=',' read -r -a caps <<< "${SEXPR_CAPABILITIES:-fs-read,fs-write}"
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

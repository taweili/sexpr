#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regression check: ./sexpr.sh must forward all four built-in capabilities
# to ./sexpr when SEXPR_CAPABILITIES is unset or empty.
#
# The test does not build or run ./sexpr. It makes a test-only copy of
# sexpr.sh with the final `exec rlwrap ...` line replaced by a printf of
# the built argv, so we can assert on the wrapper's own argument-building
# in isolation. Any narrowing of the default in sexpr.sh will show up as
# a missing --capability here.
#
# Run from anywhere: tools/check-default-capabilities.sh
# Exit 0 on success, 1 on any assertion failure.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WRAP="$ROOT/sexpr.sh"

if [[ ! -x "$WRAP" ]]; then
    echo "error: $WRAP not found or not executable" >&2
    exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Build a probe copy: replace the final `exec rlwrap ...` with a JSON-like
# argv dump so the test can compare tokens exactly. We use printf '%s\n'
# per arg so a single arg with whitespace is not split on read.
sed 's|^exec rlwrap .*|for a in "${args[@]}"; do printf "%s\\n" "$a"; done; exit 0|' \
    "$WRAP" > "$TMPDIR/probe.sh"
chmod +x "$TMPDIR/probe.sh"

fails=0
pass() { printf '  PASS: %s\n' "$*"; }
fail() { printf '  FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

contains() {
    local needle="$1" haystack
    haystack="$(cat)"
    grep -Fxq -- "$needle" <<< "$haystack"
}

run_case() {
    local label="$1" envspec="$2" args="$3"
    local out
    out="$(env $envspec bash -c "cd '$ROOT' && '$TMPDIR/probe.sh' $args" 2>&1)"
    printf '  %s\n' "$label"
    printf '%s\n' "$out" | sed 's/^/    argv: /'
}

echo "default caps on ./sexpr.sh — regression check"
echo "============================================="
echo

# 1. No env override: wrapper must forward all four caps.
echo "[case 1] no SEXPR_CAPABILITIES in env"
out="$(env -u SEXPR_CAPABILITIES bash -c "cd '$ROOT' && '$TMPDIR/probe.sh'")"
echo "$out" | sed 's/^/  argv: /'
for cap in fs-read fs-write process lisp-eval; do
    if contains "$cap" <<< "$out"; then
        pass "--capability $cap present"
    else
        fail "--capability $cap MISSING"
    fi
done

# 2. Empty env var: `${VAR:-default}` treats empty the same as unset.
echo
echo "[case 2] SEXPR_CAPABILITIES='' (empty)"
out="$(SEXPR_CAPABILITIES='' bash -c "cd '$ROOT' && '$TMPDIR/probe.sh'")"
echo "$out" | sed 's/^/  argv: /'
for cap in fs-read fs-write process lisp-eval; do
    if contains "$cap" <<< "$out"; then
        pass "--capability $cap present"
    else
        fail "--capability $cap MISSING"
    fi
done

# 3. Explicit override: user's narrower set wins (no auto-expansion).
echo
echo "[case 3] SEXPR_CAPABILITIES=fs-read (read-only override)"
out="$(SEXPR_CAPABILITIES=fs-read bash -c "cd '$ROOT' && '$TMPDIR/probe.sh'")"
echo "$out" | sed 's/^/  argv: /'
if contains fs-read <<< "$out"; then
    pass "fs-read present"
else
    fail "fs-read MISSING"
fi
for cap in fs-write process lisp-eval; do
    if ! contains "$cap" <<< "$out"; then
        pass "$cap correctly absent"
    else
        fail "$cap should be absent under fs-read override"
    fi
done

# 4. Whitespace-tolerant parsing.
echo
echo "[case 4] SEXPR_CAPABILITIES='fs-read, process' (with space)"
out="$(SEXPR_CAPABILITIES='fs-read, process' bash -c "cd '$ROOT' && '$TMPDIR/probe.sh'")"
echo "$out" | sed 's/^/  argv: /'
for cap in fs-read process; do
    if contains "$cap" <<< "$out"; then
        pass "--capability $cap present"
    else
        fail "--capability $cap MISSING (whitespace trim failed)"
    fi
done

# 5. Additive with an explicit --capability flag on the command line.
echo
echo "[case 5] ./sexpr.sh --capability custom-tool (additive)"
out="$(bash -c "cd '$ROOT' && '$TMPDIR/probe.sh' --capability custom-tool")"
echo "$out" | sed 's/^/  argv: /'
for cap in fs-read fs-write process lisp-eval custom-tool; do
    if contains "$cap" <<< "$out"; then
        pass "--capability $cap present"
    else
        fail "--capability $cap MISSING (additive contract broken)"
    fi
done

# 6. Default goal injection still works when no --goal is supplied.
echo
echo "[case 6] default goal injection (no --goal on cmdline)"
out="$(bash -c "cd '$ROOT' && '$TMPDIR/probe.sh'")"
echo "$out" | sed 's/^/  argv: /'
if contains "You are an expert in LISP" <<< "$out"; then
    pass "default goal injected"
else
    fail "default goal NOT injected"
fi

echo
if [[ $fails -eq 0 ]]; then
    echo "OK — all assertions passed."
    exit 0
else
    echo "$fails assertion(s) FAILED." >&2
    exit 1
fi

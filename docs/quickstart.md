<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# sexpr — Quickstart

Get your first chat session running. This guide covers running the
program with `./sexpr` and the convenience wrapper `./sexpr.sh`. If
you need to build the binary from source, see
[`../README.md`](../README.md).

## Prerequisites

- **SBCL** — the reference implementation is Common Lisp on SBCL.
- **GNU make** — only needed for the one-time build (below).
- **rlwrap** (optional) — line editing in the chat loop; the wrapper
  uses it if present.
- A **model API key** or a local OpenAI-compatible server.

## 1. Get the binary

If you have a pre-built release, drop the `sexpr` binary into your
PATH. Otherwise, build it once from the source tree:

```sh
git clone https://github.com/quasi/sexpr && cd sexpr
make build
```

`make build` runs the test suite first, so a broken build never ships.
The binary is self-contained — it needs no SBCL and no Quicklisp at
runtime.

Verify:

```sh
./sexpr --help
```

You should see the usage text and exit 0.

## 2. Configure a model

sexpr talks to a model through an environment-variable-configured
transport. The simplest case is a local OpenAI-compatible server
(Ollama, llama-server, vLLM, LM Studio, an internal gateway):

```sh
export SEXPR_BASE_URL="http://localhost:6969/v1"
export SEXPR_MODEL="Qwythos-9B-v2"
```

For a hosted provider, set the API key and provider name:

```sh
export SEXPR_PROVIDER="openai"        # :anthropic | :openai | :gemini
                                       # :openrouter | :ollama | :openai-compatible
export SEXPR_MODEL="gpt-4o-mini"      # optional; provider default otherwise
export OPENAI_API_KEY="sk-..."        # ANTHROPIC_API_KEY, GEMINI_API_KEY, ...
```

The wrapper `./sexpr.sh` sets local-dev defaults (OpenAI-compatible
server on `localhost:6969`, model `Qwythos-9B-v2`) so you don't need
to export anything if that matches your setup.

## 3. Your first chat

```sh
./sexpr.sh
```

You'll land at the Listener prompt with the default goal and all four
capabilities (`fs-read`, `fs-write`, `process`, `lisp-eval`). Type a
line and press Enter; sexpr folds one bounded turn over the transcript
and prints the new events.

### Directly with `./sexpr`

```sh
./sexpr --goal "You are a terse pair programmer."
./sexpr --provider anthropic --model claude-3-5-sonnet-latest --goal "..."
./sexpr --capability fs-read --capability fs-write --goal "read-only session"
```

The full flag list is `./sexpr --help`. Highlights:

| Flag              | Meaning                                            |
|-------------------|----------------------------------------------------|
| `--goal TEXT`     | the agent's goal (required to enter the loop)       |
| `--load FILE`     | start from a saved transcript                      |
| `--provider NAME` | configure the provider transport                   |
| `--model NAME`    | configure the model name                           |
| `--capability NAME` | grant a capability (repeatable; comma-separated   |
|                   | values accepted). Known: `fs-read`, `fs-write`,    |
|                   | `process`, `lisp-eval`. Grants are additive with   |
|                   | the built-in default `:fs-read`.                   |
| `--help`, `-h`    | print usage and exit                               |

### Using the wrapper

`./sexpr.sh` is the local-dev convenience wrapper. It sets
`SEXPR_PROVIDER`, `SEXPR_BASE_URL`, `SEXPR_MODEL`, and
`SEXPR_CAPABILITIES` to sensible defaults, then execs `./sexpr` under
`rlwrap`. Any env var can be overridden inline:

```sh
./sexpr.sh                                          # default goal + all caps
./sexpr.sh --goal "summarize this repo"             # explicit goal
SEXPR_CAPABILITIES=fs-read ./sexpr.sh               # read-only session
SEXPR_MODEL=OtherModel ./sexpr.sh                   # different model
./sexpr.sh --help                                   # wrapper help
```

The wrapper's `--help` (`./sexpr.sh --help`) shows all env vars and
examples.

## 4. Slash commands

Inside the chat loop:

| Command        | Effect                                              |
|----------------|-----------------------------------------------------|
| `/help`        | list the slash commands                             |
| `/transcript`  | print the whole transcript                          |
| `/system TEXT` | set the system prompt (persona)                     |
| `/save FILE`   | write the transcript to FILE                        |
| `/load FILE`   | replace the transcript with FILE                    |
| `/retry`       | drop the last model reply and re-run one turn       |
| `/exit`, `/quit` | quit the session                                 |

`/save` and `/load` round-trip through the transcript's own
`print`/`read` (`*read-eval*` nil). The `.sexp` file is plain Common
Lisp data — it opens in any text editor.

## 5. Save and resume

```sh
./sexpr.sh
; inside the loop:
; /save my-session.sexp
; /exit

./sexpr --goal "pair programmer" --load my-session.sexp
```

## 6. Scripted runs

The Listener reads stdin, so piping works:

```sh
printf '/help\n/exit\n' | ./sexpr --goal "verify"

printf 'Summarize the design.\n/save out.sexp\n/exit\n' \
  | ./sexpr --goal "pair programmer" > out.log
```

Useful for CI, cron, or a batch run against a corpus.

## 7. Granting capabilities

By default the wrapper grants all four capabilities. To restrict:

```sh
SEXPR_CAPABILITIES=fs-read ./sexpr.sh                    # read-only
SEXPR_CAPABILITIES=fs-read,fs-write ./sexpr.sh           # read + write
./sexpr --capability fs-read --goal "no shell, no lisp"  # direct binary
```

If a capability is missing, the tool call is refused with a
`CAPABILITY-DENIED` error and the agent is told what's missing — it
can adapt or ask the user to grant the capability.

## Where to go next

- [`../README.md`](../README.md) — the design thesis and layer-by-layer
  mapping.
- [`../notes/sexpr.md`](../notes/sexpr.md) — the deepest source: the
  thesis, module-by-module plan, and open questions.
- [`../src/`](../src/) — the code.
- [`./sexpr --help`](#) and [`./sexpr.sh --help`](#) — the full flag
  lists.

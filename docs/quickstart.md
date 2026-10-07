<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# sexpr — Quickstart

Get from a fresh checkout to a running `./sexpr` binary and your first chat
in a few minutes. This is the "how" doc; [`../README.md`](../README.md) is
the "why" doc (the design thesis and layer-by-layer mapping), and
[`../notes/sexpr.md`](../notes/sexpr.md) is the deepest source. Read the
README first if you have questions about *what* sexpr is trying to be.

## Prerequisites

- **SBCL** — the reference implementation of sexpr is Common Lisp on
  SBCL; other implementations are untested.
- **Quicklisp** for the dependency bootstrap.
- **GNU make** for the targets below.
- A **model API key** for step 5 — Anthropic, OpenAI, OpenRouter, Gemini,
  or a local OpenAI-compatible endpoint (Ollama, llama-server, vLLM).

## 1. Bootstrap Quicklisp (one-time)

```sh
curl -O https://beta.quicklisp.org/quicklisp.lisp
sbcl --load quicklisp.lisp --eval '(quicklisp-quickstart:install)' \
     --eval '(ql:add-to-init-file)'
```

After this, `~/.sbclinit` loads Quicklisp automatically. Verify with
`sbcl --non-interactive --eval '(ql:quickload :alexandria)'`.

## 2. Register sexpr and its dependency

sexpr depends on **cl-llm-provider**, which is not in the Quicklisp dist
yet. Vendor it next to sexpr under `local-projects/`:

```sh
# from your sexpr checkout:
ln -s "$PWD" ~/quicklisp/local-projects/sexpr

git clone https://github.com/quasi/cl-llm-provider \
  ~/quicklisp/local-projects/cl-llm-provider
```

If you clone sexpr elsewhere, redo the `ln -s` to point at the new path.

## 3. Smoke test the load

Confirm Quicklisp can resolve the system and the entry point runs:

```sh
make hello
```

Expected output:

```
sexpr 0.0.0
  An Agent OS in Common Lisp.
  Hello from sexpr.
```

Run the test suite:

```sh
make test
```

The suite is a rove run through `asdf:test-op`. Anything failing here
means something is broken before you build; fix that first.

## 4. Build the binary

```sh
make build
```

`make build` runs `make test` first, so a broken suite never ships a
binary. On success you get `./sexpr` at the repo root — a
self-contained ~64 MB executable produced by `sb-ext:save-lisp-and-die`.
It needs no SBCL and no Quicklisp at runtime.

## 5. Configure a model provider

sexpr reaches the model through a single generic function,
`sexpr.provider:provider-call`, implemented over **cl-llm-provider**.
Configure the transport with environment variables (keys are read
directly by cl-llm-provider; sexpr never touches them):

```sh
export SEXPR_PROVIDER="openai"         # :anthropic | :openai | :gemini
                                       # :openrouter | :ollama | :openai-compatible
export SEXPR_MODEL="gpt-4o-mini"       # optional; provider default otherwise
export OPENAI_API_KEY="sk-..."         # ANTHROPIC_API_KEY, GEMINI_API_KEY, ...
```

Then start:

```sh
make chat                              # default goal: "pair programmer"
# or explicitly:
./sexpr --goal "summarize this repo"
./sexpr --provider anthropic --model claude-3-5-sonnet-latest --goal "..."
```

### Talking to a local OpenAI-compatible server

Point `SEXPR_BASE_URL` at any OpenAI-compatible HTTP endpoint
(llama-server, vLLM, LM Studio, an internal gateway). When
`SEXPR_PROVIDER` is unset but `SEXPR_BASE_URL` is set, sexpr
auto-infers `:openai-compatible`:

```sh
export SEXPR_BASE_URL="http://localhost:6969/v1"
export SEXPR_MODEL="Qwythos-9B-v2"
export SEXPR_PROVIDER="openai-compatible"   # explicit, or omit for auto-infer
```

The `make diagnostic-*` and `make test-live` targets in the Makefile
exercise this path against a local server — see `make help`.

## 6. First chat

```sh
./sexpr --goal "You are a terse pair programmer."
```

You'll land at the Listener prompt. Type a line and press Enter; sexpr
folds one bounded turn over the transcript and prints the new events.
Each line you type becomes a user event; the model's reply is rendered
as events. Ctrl-C aborts the current turn and returns to the prompt —
the partial transcript stays readable, no rollback. A second Ctrl-C at
an idle prompt exits.

### Slash commands

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
`print`/`read` (`with-standard-io-syntax`, `*read-eval*` nil). There is
no separate serializer.

## 7. Save and resume sessions

```sh
./sexpr --goal "pair programmer"
; inside the loop:
; /save my-session.sexp
; /exit

./sexpr --goal "pair programmer" --load my-session.sexp
```

The `.sexp` file is plain Common Lisp data — it opens in any text
editor and reloads with `read`. This is deliberate (R012).

## 8. Scripted, non-interactive runs

The Listener reads stdin, so piping works:

```sh
printf '/help\n/exit\n' | ./sexpr --goal "verify"

printf 'Summarize the design.\n/save out.sexp\n/exit\n' \
  | ./sexpr --goal "pair programmer" > out.log
```

Useful for CI, cron, or a batch run against a corpus.

## 9. Verify your install

`make verify` runs four binary-level probes: `--help` prints usage and
exits 0; a scripted `/help` + `/exit` session succeeds; a cross-process
`/save` + `--load` round-trips a real `.sexp` file; and the R015 seam
holds (no `cl-llm-provider` reference leaks into `src/cli/`). Run it
after `make build` if you want a quick health gate:

```sh
make verify
```

## 10. Work from the source tree

For development, load the system into an interactive SBCL instead of
running the binary:

```sh
make load
# type: (sexpr:hello)
#       (ql:quickload :sexpr)
#       (sexpr.provider:configure-provider :provider :openai)
```

The full target list is `make help`. Highlights:

| Target                | What it does                                           |
|-----------------------|--------------------------------------------------------|
| `make hello`          | Run `sexpr:hello` in a one-shot SBCL                   |
| `make test`           | Run the rove test suite                                |
| `make load`           | Interactive SBCL with the system loaded                |
| `make build`          | Rebuild `./sexpr` (runs `make test` first)             |
| `make chat`           | Sugar for `./sexpr --goal "pair programmer"`           |
| `make verify`         | Four binary-level probes                               |
| `make test-live`      | Round-trip against a running local model server        |
| `make clean`          | Remove `./sexpr`, `.ql`, `.output`, `*.fasl`, `*.fbas`, `*.lib` |

`make chat` accepts `CHAT_ARGS` to override the default goal:

```sh
make chat CHAT_ARGS='--goal "summarize the design" --provider ollama --model llama3'
```

For line editing and history in the Listener, wrap with `rlwrap`:

```sh
rlwrap ./sexpr --goal "pair programmer"
```

## Where to go next

- [`../README.md`](../README.md) — the design thesis, the "in five
  sentences" summary, and the layer-by-layer mapping of 2025 harness
  concepts to Lisp-machine primitives.
- [`../notes/sexpr.md`](../notes/sexpr.md) — the deepest source: the
  thesis, the module-by-module plan, and open questions.
- [`../notes/agent.md`](../notes/agent.md) — the 2025 harness research
  (context engineering, skills, MCP) that the design answers.
- [`../src/`](../src/) — the code. `src/kernel/kernel.lisp` is the
  agent loop; `src/transcript/transcript.lisp` is the transcript
  substrate; `src/cli/cli.lisp` is the Listener; `src/provider/` is
  the model transport; `src/builtins/builtins.lisp` is the five
  registered tools (`read-file`, `write-file`, `edit-file`, `shell`,
  `lisp`).
- [`../tests/`](../tests/) — the rove suite. `tests/smoke.lisp` is the
  smallest place to see how a turn is asserted.

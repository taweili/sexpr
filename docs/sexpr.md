# sexpr — Operation Manual

> Operation manual for the `sexpr` agent binary and the `./sexpr.sh` local-dev
> wrapper. For the design thesis, see [`notes/sexpr.md`](../notes/sexpr.md);
> for the remote TUI, see [`docs/sexpr-tui.md`](./sexpr-tui.md).

`sexpr` is the Listener — the terminal front end of a live Lisp image. The
image is the state; the transcript is its conversation slice; the model is a
socket reached only through the kernel, never imported into the Listener
(R015). Each line you type becomes a transcript event; one bounded fold runs a
single model turn; new events render back to the screen.

There are three ways to reach the agent:

| Surface | What it is | How |
|---------|------------|-----|
| Chat | the agent loop, one goal, slash commands | `./sexpr --goal "..."` (or `./sexpr.sh`) |
| REPL | an unrestricted CL dev REPL sharing the live image | `./sexpr.sh repl`, or `/repl` from chat |
| Examples | standalone `.lisp` files, no model needed | `./sexpr.sh example` |

---

## 1. Get a binary

Pre-built release? Drop `sexpr` on your `PATH`. Otherwise build once:

```sh
git clone https://github.com/quasi/sexpr && cd sexpr
make build          # runs the test suite first; ~64 MB, self-contained
./sexpr --help       # verify
```

`make build` always runs `make test` first, so a broken suite never ships a
binary. `make clean` removes `./sexpr` alongside the fasl/Quicklisp artifacts.

---

## 2. Configure a model

Local OpenAI-compatible server (Ollama, llama-server, vLLM, LM Studio, an
internal gateway):

```sh
export SEXPR_BASE_URL="http://localhost:6969/v1"
export SEXPR_MODEL="Qwythos-9B-v2"
```

Hosted provider:

```sh
export SEXPR_PROVIDER="openai"   # :anthropic | :openai | :gemini | :openrouter
                                  # :ollama | :openai-compatible
export SEXPR_MODEL="gpt-4o-mini" # optional; provider default otherwise
export OPENAI_API_KEY="sk-..."   # or ANTHROPIC_API_KEY, GEMINI_API_KEY, ...
```

| Env var | Meaning |
|---------|---------|
| `SEXPR_PROVIDER` | provider name (`openai`, `anthropic`, `gemini`, `openrouter`, `ollama`, `openai-compatible`) |
| `SEXPR_BASE_URL` | base URL for an OpenAI-compatible endpoint |
| `SEXPR_MODEL` | model name |
| `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` / `GEMINI_API_KEY` | provider API key |

---

## 3. The `./sexpr.sh` wrapper

`./sexpr.sh` is the local-dev wrapper. It exports provider/model defaults,
wraps the binary under `rlwrap` for line editing and history, and forwards
every argument to `./sexpr` verbatim. The default capability set is the full
eight grants; narrow it for a restricted session.

```sh
./sexpr.sh                                        # default goal + all caps
./sexpr.sh --goal "summarize this repo"           # explicit goal
SEXPR_CAPABILITIES=fs-read ./sexpr.sh             # read-only session
SEXPR_MODEL=OtherModel ./sexpr.sh                 # different model
./sexpr.sh --help                                 # wrapper help + env vars
```

### Wrapper environment

| Env var | Default | Meaning |
|---------|---------|---------|
| `SEXPR_PROVIDER` | `openai-compatible` | provider name |
| `SEXPR_BASE_URL` | `http://localhost:6969/v1` | provider base URL |
| `SEXPR_MODEL` | `Qwythos-9B-v2` | model name |
| `SEXPR_CAPABILITIES` | all eight grants (comma-separated) | capabilities forwarded as `--capability` flags |

The known capability set:

- **Built-in tools:** `fs-read`, `fs-write`, `process`, `lisp-eval`
- **Multi-agent coordination:** `spawn`, `collect`, `manage`, `inspect`

The `SEXPR_CAPABILITIES` list is forwarded as repeated `--capability` flags
**before** the caller's arguments, so a caller-supplied `--capability` is
additive with the default set rather than replacing it. Set
`SEXPR_CAPABILITIES=fs-read` for a read-only session.

A default `--goal "You are an expert in LISP"` is injected only when the caller
did not supply one.

### Wrapper subcommands

| Subcommand | Effect |
|------------|--------|
| `./sexpr.sh example` | run all examples |
| `./sexpr.sh example 01` | run example 01 (by number, name, or prefix) |
| `./sexpr.sh example --list` | list available examples |
| `./sexpr.sh repl` | standalone dev REPL (no model call) |

`./sexpr.sh example --help` and `./sexpr.sh repl --help` print their own usage.

---

## 4. Chat — flags and slash commands

```sh
./sexpr --goal "TEXT" [--load FILE] [--provider NAME] [--model NAME]
        [--capability NAME] [--help | -h]
```

| Flag | Meaning |
|------|---------|
| `--goal TEXT` | the agent's goal (required to enter the loop) |
| `--load FILE` | start from a saved transcript |
| `--provider NAME` | configure the provider transport |
| `--model NAME` | configure the model name |
| `--capability NAME` | grant a capability (repeatable; a comma-separated list is also accepted). Additive with the built-in default `:fs-read`. Known set: `fs-read`, `fs-write`, `process`, `lisp-eval`, `spawn`, `collect`, `manage`, `inspect` |
| `--help`, `-h` | print usage and exit (never enters chat) |

`--provider`/`--model` reach the transport by the single qualified
`sexpr.provider:configure-provider` reference; the Listener never imports the
transport package (R015).

### Slash commands

| Command | Effect |
|---------|--------|
| `/exit` | quit the session |
| `/quit` | quit the session |
| `/help` | list the commands |
| `/transcript` | print the whole transcript |
| `/system TEXT` | set the system prompt (persona) |
| `/save FILE` | write the session transcript to FILE |
| `/load FILE` | load a transcript from FILE, replacing the session |
| `/retry` | pop the last model reply and re-run one turn |
| `/repl` | escape into a CL dev REPL (`,exit` to return) |

`/save` and `/load` round-trip through the transcript's own `print`/`read`
(`with-standard-io-syntax`, `*read-eval*` nil) — no separate serializer (R012).

### Interrupts

- **Ctrl-C** aborts a running turn and returns to the prompt — the partial
  transcript stays readable, no rollback (R013).
- A second **Ctrl-C** at an idle prompt exits.

### Line editing and history

History, streaming, multiline input, and tool dispatch are deliberately **not**
in the Listener (R016). Line history and editing come from an external tool
like `rlwrap` — `./sexpr.sh` does this automatically, or wrap the binary
manually:

```sh
./sexpr.sh --goal "..."         # wrapper: rlwrap + local-dev defaults
rlwrap ./sexpr --goal "..."     # manual wrap
```

### Piping / scripted sessions

The Listener reads stdin, so piping works for CI or batch runs:

```sh
printf '/help\n/exit\n' | ./sexpr --goal "verify"
```

### Saving and resuming sessions

```sh
./sexpr --goal "pair programmer"
# inside the loop:
# /save my-session.sexp
# /exit

./sexpr --goal "pair programmer" --load my-session.sexp
```

---

## 5. The REPL

`sexpr.repl` is an unrestricted Common Lisp REPL that shares the live image —
the same agent, transcript, tools, and provider state the chat loop is
mid-conversation with. It is a developer surface, not a sandboxed one:
everything in `:sexpr` is in scope.

### Escape from chat: `/repl`

From inside a chat session, `/repl` drops into the REPL with `*agent*` bound
to the live agent. `,exit` returns to the chat loop; the conversation resumes
with any redefinitions you made now in effect:

```text
you: make me a todo app
model: <calls edit-file, error in the result>
you: /repl
> (agent-transcript *agent*)           ; inspect the live state
> (trace sexpr.tools:perform-tool)
> (defun my-edit-file ...)             ; hot-redefine the buggy tool
> ,exit
you: /retry                            ; re-run the last turn with the new def
model: <now succeeds>
```

`*agent*` is bound by the REPL around its loop body — reach the transcript via
`(agent-transcript *agent*)`, the persona via `(agent-system *agent*)`. The
REPL shares the chat loop's input/output streams, so `,exit` (not EOF) is the
escape — EOF would also end the chat.

### Standalone: `./sexpr.sh repl`

Outside a chat session, `./sexpr.sh repl` enters the REPL with no agent
(`*agent*` is `NIL`). Useful for loading examples, defining tools from
scratch, or driving the provider directly:

```sh
./sexpr.sh repl
> (load "examples/02-tools.lisp")
> (sexpr.provider:provider-call nil '((:role "user" :content "hi")))
> ,exit
```

The REPL never calls the model on its own — no provider endpoint or API key is
needed. Reach it by evaluating a `provider-call` form yourself.

### REPL conventions

- **One form per prompt.** `,exit` collides with the CL unquote reader macro,
  so the line is read whole and string-checked for a leading comma before
  `read-from-string`. Multiple forms on one line all eval and print; for
  multi-line forms use `(progn ...)` or `(load "file")`.
- **`,` meta-commands.** Only `,exit` is defined; an unknown `,foo` prints a
  notice and continues (never reaches the reader).
- **Errors never crash the loop** — reader errors, eval errors, and a Ctrl-C
  mid-form are caught, printed, and re-prompted. Ctrl-C aborts the current
  form only (no two-press idle-exit dance — `,exit` is the explicit escape).
- **Package.** The REPL starts in `:sexpr.repl`, an aggregating package that
  `:use`s `:sexpr.transcript`, `:sexpr.kernel`, `:sexpr.tools`, and
  `:sexpr.sandbox` — so `make-agent`, `agent-transcript`, `render-events`,
  `eval-in-sandbox`, `define-tool` are unqualified. Switch with
  `(in-package :sexpr.kernel)`.
- **Nil is suppressed.** A form returning a single `NIL` prints nothing (SBCL
  convention), so side-effecting `(format t ...)` calls don't echo a trailing
  `NIL`.

---

## 6. Examples

`./sexpr.sh example` runs the standalone `.lisp` files in `examples/`. Each
loads sexpr via Quicklisp, exercises one concept, and prints visible output —
no model endpoint or API key needed.

```sh
./sexpr.sh example                # run all examples
./sexpr.sh example 01             # run example 01
./sexpr.sh example 01-transcript  # run by full name
./sexpr.sh example 05 06 07       # run multiple examples
./sexpr.sh example --list         # list available examples
```

Names resolve by exact match, by `.lisp`-suffixed match, or by number prefix
(e.g. `01` matches `01-transcript.lisp`).

---

## 7. Make targets

| Target | Effect |
|--------|--------|
| `make build` | produce `./sexpr` via `sb-ext:save-lisp-and-die`; runs `make test` first |
| `make chat` | sugar for `./sexpr --goal "pair programmer"`; accepts `CHAT_ARGS` |
| `make verify` | binary-level health gate: `--help`, scripted session, cross-process `--load` round-trip, R015 seam |
| `make test` | run the test suite |
| `make hello` | the trivial smoke entry point |
| `make clean` | remove `./sexpr` and fasl/Quicklisp artifacts |

```sh
make chat CHAT_ARGS='--goal "summarize the design" --provider ollama --model llama3'
```

---

## 8. Troubleshooting

- **`sbcl not found` / build fails** — install SBCL and Quicklisp; see
  [`notes/sbcl.md`](../notes/sbcl.md).
- **Model calls fail** — check `SEXPR_PROVIDER`, `SEXPR_BASE_URL`,
  `SEXPR_MODEL`, and the relevant `*_API_KEY`. A goal-only call carries no
  user message; providers whose chat template requires one (llama-server's
  `--jinja`) refuse it, so seed a user note.
- **No chat prompt marker** — the Listener never prints its own `> `; run it
  under `rlwrap` (the wrapper does this with `-S "sexpr> "`).
- **`--capability` not taking effect** — grants are additive with the built-in
  `:fs-read`; an unknown capability name is ignored. List the known set with
  `./sexpr --help`.

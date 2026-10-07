# sexpr — an Agent OS in Common Lisp

![sexpr](sexpr.png)

> The agent runtime *is* a living Lisp image. The harness is not scaffolding around
> intelligence — it is the operating environment in which intelligence is a
> first-class, inspectable, hot-patchable process.

## Contents

- [Quickstart](#quickstart)
- [The big idea](#the-big-idea)
- [The design in five sentences](#the-design-in-five-sentences)
- [Architecture sketch](#architecture-sketch)
- [Repository](#repository)
- [Design documents](#design-documents)
- [Development setup](#development-setup)
- [Model provider](#model-provider)
- [Chat interface](#chat-interface)
- [Building the binary](#building-the-binary)
- [Status](#status)
- [Open questions](#open-questions)
- [License](#license)

## Quickstart

Get a session running in three steps. For the design thesis, skip to
[§ The design in five sentences](#the-design-in-five-sentences); for building
from source, see [§ Development setup](#development-setup).

### 1. Get the binary

Pre-built release? Drop `sexpr` on your `PATH`. Otherwise build once:

```sh
git clone https://github.com/quasi/sexpr && cd sexpr
make build          # runs the test suite first; ~64 MB, self-contained
./sexpr --help      # verify
```

### 2. Configure a model

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

The wrapper `./sexpr.sh` sets local-dev defaults (OpenAI-compatible server on
`localhost:6969`, model `Qwythos-9B-v2`, all four capabilities) and execs
`./sexpr` under `rlwrap`:

```sh
./sexpr.sh                                        # default goal + all caps
./sexpr.sh --goal "summarize this repo"           # explicit goal
SEXPR_CAPABILITIES=fs-read ./sexpr.sh             # read-only session
SEXPR_MODEL=OtherModel ./sexpr.sh                 # different model
./sexpr.sh --help                                 # wrapper help + env vars
```

### 3. Chat

```sh
./sexpr --goal "You are a terse pair programmer."
./sexpr --provider anthropic --model claude-3-5-sonnet-latest --goal "..."
./sexpr --capability fs-read --goal "read-only session"
```

Slash commands and the full flag list are in
[§ Chat interface](#chat-interface). To resume a session:

```sh
./sexpr --goal "pair programmer" --load my-session.sexp
```

The Listener reads stdin, so piping works for CI or batch runs:

```sh
printf '/help\n/exit\n' | ./sexpr --goal "verify"
```

## The big idea

In 1985, Symbolics shipped the Genera operating system on Lisp Machines —
single-user computers whose entire operating environment (OS kernel, GUI,
development tools, application runtime) was written in a dialect of Common Lisp.
The user interacted with the system through a *listener* (an interactive REPL),
tools were *functions*, the runtime state was the *image* (the heap), and code
could be redefined live without restarting. By 2025, the AI industry has
reinvented most of these ideas under new names: agent harnesses (the *listener*
loop), tool calling (the *functions*), context engineering (the *image* as sole
state), subagents (lightweight *processes* in one heap), and MCP servers (the
*services* of Chaosnet).

But the AI industry built all of this in Python and TypeScript, bolted around a
stateless model called over HTTP. **sexpr inverts this.** Instead of wrapping a
model in Python, the agent runtime *is* a living Lisp image on SBCL — the modern
descendant of the Symbolics Lisp Machine's runtime. The Lisp machine already
solved most of what agent engineering is rediscovering.

| Agent-harness concept (2025)     | Lisp machine concept (1985)                          |
|----------------------------------|------------------------------------------------------|
| "The transcript is the only state" | The image is the only state                       |
| Context engineering / compaction | GC + ephemeral memory + presentations with history   |
| Tool use / function calling      | Calling functions. Literally.                        |
| Skills with progressive disclosure | Systems, packages, autoloading, Document Examiner |
| MCP servers                      | Processes / services in the same address space       |
| Approvals & permissions          | Condition system + restarts                          |
| Subagents                        | Lightweight processes sharing one heap               |
| Agent OS                         | Genera                                               |

sexpr's job is to close the loop: rebuild these ideas around an LLM as a
*resident process* of the image, not its master.

## The design in five sentences

1. **The agent loop is `eval`, made explicit.** `model-step` returns an s-expression,
   not JSON; tools are Lisp functions wearing metadata; a tool call is a form.
2. **The transcript is a first-class object**, not a list of strings. It holds live
   object references (presentations) and round-trips through `print`/`read`.
3. **Compaction is garbage collection.** Old transcript ranges reify into summary
   nodes; the recent window is the nursery.
4. **Approvals are conditions, permissions are restarts.** Non-unwinding semantics
   mean a denied effect leaves the agent's stack intact — the human inspects the
   exact state and resumes precisely there.
5. **Skills are systems.** A skill is an ASDF-loadable directory with a SKILL.md,
   a SKILL.sexp, and optional scripts. Progressive disclosure becomes `load`.

## Architecture sketch

```
+-------------------------------------------------------------+
|  sexpr image (one address space, SBCL)                      |
|                                                             |
|  kernel process: scheduler, GC, capability table           |
|  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         |
|  │ agent proc  │  │ agent proc  │  │ human proc  |         |
|  │ (goal loop) │  │ (subagent)  │  │ (listener)  |         |
|  │ transcript  │  │ transcript  │  │             |         |
|  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘         |
|         └────────────────┴────────────────┘                |
|              shared heap: tools, skills, world state        |
|  model endpoint processes: sockets to LLM providers        |
|  MCP bridge process (for legacy / foreign tools)           |
+-------------------------------------------------------------+
```

Agents are threads with an owner, a goal, a transcript, a capability set, and a
budget. The model is a socket. Budgets are dynamic variables. Interrupts come
for free because everything is a thread in one image — a human can drop into
any agent's debugger, patch a function, and let it continue.

## Repository

```
sexpr.asd              ASDF system definition
src/
  package.lisp         :sexpr package
  sexpr.lisp           identity + `hello' entry point; test-op method
  provider/            the "Ivory" layer — LLM providers as sockets
    package.lisp       :sexpr.provider package
    provider.lisp      provider-call GF + configuration (cl-llm-provider transport)
  transcript/          events, print/read round-trip, the GC substrate
  kernel/              the agent: budget, transcript, model-step, run-until-finished
  cli/                 the Listener: chat loop, slash commands, SIGINT, argv/main/build
  tools/               the tool registry (register-tool!, derive-schema, dispatch)
  builtins/            the five registered tools (read-file, write-file, edit-file, shell, lisp)
  sandbox/             the restricted-read eval sandbox (eclector, locked package, eval timeout)
qlfile                 Qlot deps (cl-llm-provider, eclector, rove)
Makefile               `make hello`, `make test`, `make build`, `make chat`, `make verify`, `make clean`
notes/
  sexpr.md             — thesis, layer-by-layer mapping, open questions
  agent.md             — 2025 harness research (context engineering, skills, MCP)
  symbolics-lisp.md    — Symbolics / Genera / Dynamic Windows lineage
  sbcl.md              — SBCL, Quicklisp, hot-patching, condition system, save-lisp-and-die
  sbcl-libs.md         — CL library survey mapped to the sexpr design
```

## Design documents

`notes/` holds the research and design documents that motivated the project.
[`notes/sexpr.md`](notes/sexpr.md) is the entry point; the others are the
research base it's synthesized from.

| File | What it covers |
|------|---------------|
| [`notes/sexpr.md`](notes/sexpr.md) | The main design doc. Thesis, layer-by-layer mapping of 2025 agent-harness concepts to 1985 Lisp-machine primitives, module-by-module plan, open questions. **Start here.** |
| [`notes/symbolics-lisp.md`](notes/symbolics-lisp.md) | History and architecture of Symbolics Lisp Machines (LM-2, 3600 family, XL, MacIvory, Open Genera), the Genera OS, CLIM, Dynamic Windows, Document Examiner, and the patch system. The "what we're modernizing" reference. |
| [`notes/agent.md`](notes/agent.md) | Survey of 2025–2026 AI agent harness architecture: the agent loop, context engineering (write/select/compress/isolate), tool dispatch, MCP, subagents, skills with progressive disclosure, and sandboxing. The "what we're translating" reference. |
| [`notes/sbcl.md`](notes/sbcl.md) | SBCL and Quicklisp deep-dive: the live image, hot redefinition, the condition/restart system, `save-lisp-and-die` for whole-image snapshots, and Quicklisp as a dependency/skill distribution mechanism. The "our runtime substrate" reference. |
| [`notes/sbcl-libs.md`](notes/sbcl-libs.md) | Library survey: maps the sexpr design onto existing Common Lisp libraries (ASDF, UIOP, cl-llm-provider, etc.), noting availability and fit. The "what already exists" reference. |

### How to read them

1. **`sexpr.md`** first — it synthesizes the others and states the thesis. Read
   its §0 ("Thesis") for the core argument and §11 ("Sources / lineage") for how
   it draws on the other three docs.
2. **`symbolics-lisp.md`** if you want the historical/architectural background
   on what we're modernizing.
3. **`agent.md`** if you want the 2025 state of the art that we're translating
   into Lisp.
4. **`sbcl.md`** and **`sbcl-libs.md`** if you want the implementation substrate
   and what's already available in the CL ecosystem.

## Development setup

Prerequisites: **SBCL** and **Quicklisp**. One-time bootstrap:

```sh
curl -O https://beta.quicklisp.org/quicklisp.lisp
sbcl --load quicklisp.lisp --eval '(quicklisp-quickstart:install)' \
     --eval '(ql:add-to-init-file)'
```

Then register this project with Quicklisp (one-time, from a checkout):

```sh
ln -s "$PWD" ~/quicklisp/local-projects/sexpr
```

sexpr depends on **cl-llm-provider** (the unified LLM transport — Anthropic,
OpenAI, Gemini, Ollama, OpenRouter). It is not (yet) in the Quicklisp dist, so
vendor it into local-projects too:

```sh
git clone https://github.com/quasi/cl-llm-provider \
  ~/quicklisp/local-projects/cl-llm-provider
```

Run the smoke test:

```sh
make hello
# or, directly:
sbcl --load ~/.sbclinit \
     --eval '(ql:quickload "sexpr")' \
     --eval '(sexpr:hello)'
```

Load into an interactive session for development:

```sh
make load
# type: (sexpr:hello)
```

## Model provider

The model is a socket (`notes/sexpr.md` §2). `src/provider/` is the "Ivory"
layer: a single generic function, `sexpr.provider:provider-call`, that returns
s-expression transcript nodes (`:content`, `:tool-calls`, `:model`, `:usage`,
`:finish`) — never raw provider objects. cl-llm-provider is the concrete
transport; tool *execution* stays in the sexpr kernel (transport only, by
design).

**Configure** via environment variables (API keys are read directly by
cl-llm-provider):

```sh
export OPENAI_API_KEY="sk-..."        # or ANTHROPIC_API_KEY, OPENROUTER_API_KEY, ...
export SEXPR_PROVIDER="openai"        # :anthropic | :openai | :gemini | :ollama
                                       # :openrouter | :openai-compatible
export SEXPR_MODEL="gpt-4o-mini"      # optional; defaults to the provider's default
export SEXPR_BASE_URL="http://..."    # OpenAI-compatible endpoint (default:
                                       # https://api.openai.com/v1)
export SEXPR_CAPABILITIES="fs-read"   # comma-separated; grants additive with
                                       # the built-in default :fs-read
```

Then from Lisp:

```lisp
(ql:quickload :sexpr)
(in-package :sexpr.provider)
(configure-provider)                    ; picks up the env vars above
;; or, explicitly:
(configure-provider :provider :anthropic :model "claude-3-5-sonnet-latest")
```

`*model-endpoint*` is realized lazily on the first `provider-call` (so
configuration never fails just because a key isn't set yet). Swap providers by
rebinding — `(let ((*model-endpoint* (make-provider :ollama))) ...)` — the
central design invariant.

## Chat interface

`sexpr.cli` is the Listener — the terminal front end. The image is the
state; the transcript is its conversation slice; the model is a socket
reached only through the kernel, never imported into the Listener (R015).
Each line you type becomes a transcript event; `run-until-finished` folds
one bounded model turn; new events render back to the screen.

```sh
./sexpr --goal "summarize the design"
```

Ctrl-C aborts a running turn and returns to the prompt — the partial
transcript stays readable, no rollback (R013). A second Ctrl-C at an idle
prompt exits.

### Slash commands

| Command        | Effect                                              |
|----------------|-----------------------------------------------------|
| `/exit`        | quit the session                                    |
| `/quit`        | quit the session                                    |
| `/help`        | list the commands                                   |
| `/transcript`  | print the whole transcript                          |
| `/system TEXT` | set the system prompt (persona)                     |
| `/save FILE`   | write the session transcript to FILE                |
| `/load FILE`   | load a transcript from FILE, replacing the session  |
| `/retry`       | pop the last model reply and re-run one turn        |

`/save` and `/load` round-trip through the transcript's own `print`/`read`
(`with-standard-io-syntax`, `*read-eval*` nil) — no separate serializer
(R012).

### Flags

```sh
./sexpr --goal "TEXT" [--load FILE] [--provider NAME] [--model NAME]
        [--capability NAME] [--help | -h]
```

| Flag              | Meaning                                            |
|-------------------|----------------------------------------------------|
| `--goal TEXT`     | the agent's goal (required to enter the loop)       |
| `--load FILE`     | start from a saved transcript                      |
| `--provider NAME` | configure the provider transport (qualified call)  |
| `--model NAME`    | configure the model name                           |
| `--capability NAME` | grant a capability to the agent (repeatable; a    |
|                   | comma-separated list is also accepted). Grants are |
|                   | additive with the built-in default `:fs-read`. The |
|                   | known set is `fs-read`, `fs-write`, `process`,     |
|                   | `lisp-eval`.                                        |
| `--help`, `-h`    | print usage and exit (never enters chat)           |

`--provider`/`--model` reach the transport by the single qualified
`sexpr.provider:configure-provider` reference; the Listener never imports
the transport package (R015).

### Deliberately out (R016)

History, streaming, multiline input, and tool dispatch are **not** in the
Listener. Line history and editing come from an external tool like
`rlwrap` — the wrapper `./sexpr.sh` does this automatically, or wrap the
binary manually:

```sh
./sexpr.sh --goal "..."         # wrapper: rlwrap + local-dev defaults
rlwrap ./sexpr --goal "..."     # manual wrap
```

No readline, no threading, no streaming — the transcript is the state,
and each turn is one bounded fold over it.

## Building the binary

`make build` produces a self-contained `./sexpr` executable via
`sb-ext:save-lisp-and-die` — no Quicklisp or SBCL needed at runtime.
`make build` always runs `make test` first, so a broken suite never
ships a binary:

```sh
make build       # ./sexpr at the repo root, ~64 MB
make chat        # sugar for: ./sexpr --goal "pair programmer"
make verify      # binary-level health gate: --help, scripted session,
                 # cross-process --load round-trip, R015 seam
make clean       # removes ./sexpr alongside the fasl/ql artifacts
```

`make chat` accepts `CHAT_ARGS` to override the default goal:

```sh
make chat CHAT_ARGS='--goal "summarize the design" --provider ollama --model llama3'
```

Sessions persist through the transcript's own print/read path — save from
inside the loop, load at startup:

```sh
./sexpr --goal "pair programmer"
; inside the loop:
; /save my-session.sexp
; /exit

./sexpr --goal "pair programmer" --load my-session.sexp
```

A scripted session runs from a clean shell with no terminal:

```sh
printf '/help\n/exit\n' | ./sexpr --goal "verify"
```

## Status

Design phase, with the model/transport layer wired. The cl-llm-provider
dependency is installed and `src/provider/` exposes the `provider-call` boundary
(verified end-to-end: configuration → provider realization → HTTP → the
provider's condition/restart error recovery). The design has been
cross-checked against a concrete library survey (see `notes/sbcl-libs.md`) —
most of the substrate exists in Quicklisp; the novel pieces still ahead are the
transcript compactor, the token-budgeted presentation renderer, and a
capability-restricted eval sandbox.

## Open questions

- Sandbox granularity: one heap = one fault domain. Genera accepted this; can
  sexpr afford it when the code-writer is an LLM?
- Token cost of sexpr I/O: presentations need a `:view :model` rendering path.
- Determinism & replay: model calls are nondeterministic; transcript + canned
  responses is the likely answer.
- Multi-agent coherence: shared heap invites races; the world model needs
  transactional accessors, not naked globals.
- How much LLM, how much symbolics? Keep proposal generation in the model;
  keep control flow symbolic.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE) for the full text.

New files should carry the SPDX header:

```
;;; SPDX-License-Identifier: GPL-3.0-or-later
```

(`;;;` for Lisp source; use `<!--` or `#` as appropriate for other file types.)

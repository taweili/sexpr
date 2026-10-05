# SBCL/Quicklisp Ecosystem Survey for Building sexpr OS

*Maps the sexpr OS design (`notes/sexpr.md`) onto existing Common Lisp libraries. Availability: most are in Quicklisp; GitHub-only projects noted.*

## 0. Build & deployment substrate

| Library | Role in sexpr |
|---|---|
| **ASDF / UIOP** (bundled with SBCL) | System definitions for kernel/agents/skills; `uiop:run-program` for shell-out tools; portable pathname/OS layer |
| **Quicklisp** | Dependency + skill distribution (dists as "skill dists"); `local-projects` for dev |
| **Qlot** / **CLPM** | Lockfile-based reproducible builds for deployment |
| **`save-lisp-and-die` (sb-ext)** | Whole-OS image snapshots; hibernating agent societies |
| **deploy** | Ship standalone binaries (handles foreign lib bundling) |
| **sb-sprof, sb-cltl2, sb-introspect** | Profiling agent loops; introspection for self-inspecting tools (`arglist`, callers/callees for tool-schema generation) |

## 1. Model endpoints (the "Ivory" layer)

| Library | Notes |
|---|---|
| **cl-llm-provider** (quasi) | Unified multi-provider interface (Anthropic, OpenAI, Gemini, Ollama, OpenRouter, OpenAI-compatible) **with tool calling**, streaming, and — notably — *condition-based error recovery*. Closest fit for sexpr's provider-dispatch + restart philosophy. GitHub: quasi/cl-llm-provider |
| **cl-completions** (atgreen) | Completions for Ollama/OpenAI/Anthropic/Gemini; token counting built in (useful for budgets); via ocicl |
| **mark-watson/openai**, **mark-watson/anthropic** | Minimal single-provider clients; useful as reference |
| **com.inuoe.jzon** / **yason** / **jsown** | JSON codecs for provider wire formats (jzon is the modern, safe, fast choice) |
| **dexador** | HTTP client (streaming support needed for SSE provider streams); **drakma** as fallback |
| **cl-plus-ssl** | TLS for dexador/usocket |

Design note: wrap provider clients behind one generic function (`model-call endpoint context → sexpr`) so providers are swappable by rebinding — sexpr §2.

## 2. Concurrency & the process model

| Library | Role |
|---|---|
| **bordeaux-threads** | Portable threads/locks/condition-vars; the substrate of agent processes |
| **SBCL native**: `sb-thread`, `sb-concurrency` (lock-free queues), timers | Kernel internals where portability doesn't matter |
| **lparallel** | Task queues, futures/promises, `pmap`, **task killing**, **async condition handling across threads** — maps almost 1:1 onto sexpr subagent spawning, parallel tool batches, and budget enforcement |
| **chanl** | CSP channels — alternative message-passing discipline for agent↔agent and agent↔supervisor communication |
| **cl-async** / **woo (libev)** | Event loop + fast non-blocking HTTP server for the MCP bridge and model streaming |
| **blackbird** | Promises on cl-async, if an async style is chosen |
| **sb-safepoint / interrupt-thread** | Steering: injecting notes into a running agent's dynamic environment |

Recommendation: threads + lparallel promises for agents; chanl-style channels for inter-agent messages; avoid a global event loop except at I/O edges (model streaming, MCP).

## 3. Conditions, debugging, observability

| Library | Role |
|---|---|
| ANSI **condition system** + `dissect` | `dissect` gives programmatic backtraces/restarts **across threads** — the base of sexpr's supervisor and `effect-requested` policy handlers |
| **trivial-backtrace** | Backtrace strings for transcript events/logging |
| **log4cl** | Hierarchical logging per-agent (`log:info` inside agent loops routes by agent name); pairs with **log4cl-extras** (JSON appenders → observability pipeline) |
| **tracer/metering via sb-cltl2, `trace`** | Tracing `model-step`, tool calls — the image is its own observability stack |
| **slynk** / **swank** | The human operator's console: attach to the live OS, inspect any agent's transcript, patch tools mid-run. Sly's stickers/backtrace are excellent for agent debugging |

## 4. Persistence & memory

| Library | Role |
|---|---|
| Plain `print`/`read` + `with-standard-io-syntax` | Transcript/session serialization (code-is-data payoff); guard with `*read-eval*` nil for untrusted reads |
| **cl-prevalence** / **bknr.datastore** | Transaction-log + snapshot object persistence — a natural fit for the world-model store ("the image, but durable") |
| **manardb** | Memory-mapped persistent CLOS objects; low-latency semantic memory |
| **postmodern** (Postgres) / **sqlite** / **cl-dbi** | Durable stores when leaving the image is required |
| **cl-redis** | Optional shared/cache layer between multiple images |
| **ubiquitous** / **cl-config** | Simple config storage for endpoints/keys |
| Vector search: brute-force over arrays, or FFI to hnswlib/**usearch** via **CFFI** | Embeddings for episodic-memory retrieval (no mature native CL ANN lib — CFFI is the way) |

## 5. Language tools for the s-expression protocol

| Library | Role |
|---|---|
| **trivia** / **optima** | Pattern matching on model-emitted forms — the "tool-call parser" is a pattern match, not JSON validation |
| **esrap** (PEG) / **maxpc** | Lenient parsing of malformed model output with error recovery (signal a condition, offer `retry-with-repaired-form`) |
| **cl-ppcre** / **ppcre-unicode** | Regex inside tools |
| **eclector** | A *safe, customizable* `read` — critical for reading model output without `*read-eval*` hazards; also gives precise source locations for repair loops |
| **cl-syntax / named-readtables** | Reader discipline per context (model channel vs. source files) |

## 6. MCP & external connectivity (the FFI layer)

| Library | Notes |
|---|---|
| **mcp-lisp** (jsulmont) | Full MCP SDK: server, client, agent; targets MCP 2025-11-25 spec — best candidate for sexpr's bridge both directions |
| **40ants-mcp** | Framework for MCP servers **and** clients (clack/lack, SSE, JSON-RPC); actively maintained, batteries included |
| **cl-mcp** (cl-ai-project) | MCP server exposing a CL REPL/eval/introspection to agents — directly relevant as the "sexpr as MCP server" component (structure-aware editing included) |
| **jsonrpc** (cxxxr) | JSON-RPC 2.0 base used by 40ants-mcp |
| **clack + lack** / **hunchentoot** / **woo** | HTTP server choices for the bridge and any web UI; **clack-sse** for streamable HTTP transport |
| **websocket-driver** | WS transport if needed |
| **CFFI** | Native libs: embeddings ANN, sqlite-vec, tree-sitter for code tools |

## 7. Code manipulation tools (self-editing agent)

| Library | Role |
|---|---|
| **eclector / cl-concrete-syntax-tree (CST)** | Read/edit source *without losing formatting/comments* — the difference between a careful surgeon and sed-awk; basis for structure-aware `edit-file` tool |
| **sb-cover** | Coverage of agent-run test suites |
| **quickproject** | Scaffolding new skills/systems |
| **fiveam** / **parachute** / **rove** | Test frameworks — the agent's `run-tests` tool; rove has nice interactive/debug integration |
| **trivial-indent** | Correct re-indentation of generated code |

## 8. Interface layer (presentations & Listener)

| Library | Role |
|---|---|
| **McCLIM** | The real prize: presentation types, output records, command tables, incremental redisplay — Genera's Dynamic Windows ideas, portable. Steep curve, but it *is* sexpr §4. Listener and inspector already exist in McCLIM |
| **cl-charms** / **croatoan** (ncurses) | Terminal UI v1: budget meters, agent list, approval prompts |
| **sb-aclrepl** / **linedit** | Decent native REPL quickly (line editing, history) |
| **Sly/SLIME + slynk** | Day-one interface — presentations degrade to inspectable objects in the inspector; do not underestimate this as "v1 UI" |
| **Spinneret / cl-who + hunchentoot** | Optional web dashboard (agent transcripts rendered as hypertext — Document Examiner-lite) |
| **3md / common-doc / pandoc** | Markdown rendering of model text for the UI |

## 9. Knowledge, planning, symbolic cognition

| Library | Role |
|---|---|
| **PAIP-style code / norvig ports** | GPS planner, unification, Prolog-in-Lisp — plan DSL substrate |
| **cl-prolog2 / Screamer** | Logic/constraint programming: nondeterministic search with backtracking for planners — Screamer is the classic "nondeterministic Lisp" extension |
| **cl-hash-util / fset / cl-containers** | Functional/persistent data structures for world-model snapshots (cheap history, safe sharing between agents) |
| **local-time**, **local-time-duration** | Schedules, deadlines, budget accounting |
| **trivial-timers / sb-ext timers** | Heartbeats, cron-ish triggers, watchdog for hung model calls |
| **cl-cron** | Scheduled agent wakeups ("initializer agent" pattern) |

## 10. Utilities & quality of life

**alexandria**, **serapeum** (kitchen-sink++, includes excellent data structures and `op`), **arrow-macros**, **split-sequence**, **iterate**, **trivial-features**, **trivial-garbage** (finalizers/weak tables — for the presentation registry's object-id → object map), **bordeaux-threads**, **uuid**, **ironclad** (crypto for API keys), **cl-base64**, **flexi-streams**, **trivial-mimes**, **cl-fad**, **zpng/salza2** (misc).

Notable mention: **serapeum** deserves emphasis — its `dict`, `queue`, `synchronized` and control utilities remove a lot of kernel boilerplate.

## 11. Gaps (things we'd need to build)

1. **Token accounting / context-window budgeting** — no CL tokenizer for frontier models (tiktoken bindings via CFFI or a pure-CL BPE would be needed for accurate budgets).
2. **Native embedding/ANN stack** — CFFI to usearch/hnswlib, or shell out.
3. **A structured, safe `eval` sandbox package** — capability-restricted reader+evaluator for model code (eclector gets us 80%; the package/capability discipline is ours).
4. **Presentation substrate v1** — McCLIM exists but the token-budgeted `:view :model` rendering protocol is novel work.
5. **Transcript GC/compaction engine** — nobody has written the generational context compactor; it's the core differentiator.
6. **Mature multi-agent supervision trees** — lparallel/dissect provide primitives; Erlang-style supervision policy is ours to write (and conditions make it pleasant).

## 12. Suggested core dependency list (v0)

```
;; kernel
alexandria serapeum bordeaux-threads lparallel chanl dissect log4cl log4cl-extras
;; protocol
eclector trivia esrap com.inuoe.jzon
;; model layer
cl-llm-provider dexador cl-plus-ssl
;; connectivity
40ants-mcp jsonrpc clack websocket-driver cffi
;; persistence
cl-prevalence postmodern trivial-garbage fset
;; code tools
cl-concrete-syntax-tree rove sb-cover
;; interface (v1)
slynk cl-charms  ; McCLIM when ready for v2
```

## 13. Sources

- cl-llm-provider: https://github.com/quasi/cl-llm-provider
- cl-completions: https://github.com/atgreen/cl-completions
- mark-watson/anthropic, /openai: https://github.com/mark-watson/anthropic
- mcp-lisp: https://github.com/jsulmont/mcp-lisp
- 40ants-mcp: https://github.com/40ants/mcp , https://40ants.com/mcp/
- cl-mcp: https://github.com/cl-ai-project/cl-mcp
- mcp-srv-lisp: https://github.com/belyak/mcp-srv-lisp
- lparallel: https://github.com/sharplispers/lparallel/
- chanl: https://github.com/zkat/chanl
- woo: https://github.com/fukamachi/woo
- Common Lisp libraries overview: https://common-lisp.net/libraries
- Awesome CL (companion catalog): https://github.com/CodyReichert/awesome-cl

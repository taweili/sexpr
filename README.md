# sexpr — an Agent OS in Common Lisp

> The agent runtime *is* a living Lisp image. The harness is not scaffolding around
> intelligence — it is the operating environment in which intelligence is a
> first-class, inspectable, hot-patchable process.

Modern agent harnesses bolt agency onto the model from the outside: a Python or
TypeScript process owns the loop, the transcript, the tools, the memory, and the
model is a stateless oracle called over HTTP. **sexpr inverts this.**

The Lisp machine already solved most of what agent engineering is rediscovering.

| Agent-harness concept (2025)     | Lisp machine concept (1985)                          |
|----------------------------------|------------------------------------------------------|
| "The transcript is the only state" | The image is the only state                       |
| Context engineering / compaction | GC + ephemeral memory + presentations with history   |
| Tool use / function calling      | Calling functions. Literally.                        |
| Skills with progressive disclosure | Systems, packages, autoloading, Document Examiner |
| MCP servers                      | Processes / services in the same address space       |
| Approvals & permissions          | Condition system + restarts                          |
| Subagents                        | Lightweight processes sharing one heap               |
| Agent OS                         | …Genera                                              |

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
notes/
  sexpr.md            — thesis, layer-by-layer mapping, open questions
  agent.md            — 2025 harness research (context engineering, skills, MCP)
  symbolics-lisp.md   — Symbolics / Genera / Dynamic Windows lineage
  sbcl.md             — SBCL, Quicklisp, hot-patching, condition system, save-lisp-and-die
  sbcl-libs.md        — CL library survey mapped to the sexpr design
```

`notes/sexpr.md` is the entry point. The others are the research base it's
synthesized from.

## Status

Brainstorm / design phase. No code yet. The design has been cross-checked against
a concrete library survey (see `notes/sbcl-libs.md`) — most of the substrate
exists in Quicklisp; the novel pieces are the transcript compactor, the
token-budgeted presentation renderer, and a capability-restricted eval sandbox.

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

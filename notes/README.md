<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# notes/ — Research & Design Documents

This directory holds the research, design, and background documents that
motivated the sexpr project. The project's guiding thesis: **modernize
the Symbolics Lisp Machine for the age of AI agents**.

## The big idea

In 1985, Symbolics shipped the Genera operating system on Lisp Machines
— single-user computers whose entire operating environment (OS kernel,
GUI, development tools, application runtime) was written in a dialect
of Common Lisp. The user interacted with the system through a *listener*
(an interactive REPL), tools were *functions*, the runtime state was
the *image* (the heap), and code could be redefined live without
restarting.

By 2025, the AI industry has reinvented most of these ideas under new
names: agent harnesses (the *listener* loop), tool calling (the
*functions*), context engineering (the *image* as sole state), subagents
(lightweight *processes* in one heap), and MCP servers (the *services*
of Chaosnet). But the AI industry built all of this in Python and
TypeScript, bolted around a stateless model called over HTTP.

**sexpr inverts this.** Instead of wrapping a model in Python, the
agent runtime *is* a living Lisp image on SBCL — the modern descendant
 of the Symbolics Lisp Machine's runtime. The harness is not scaffolding
around intelligence; it is the operating environment in which
intelligence is a first-class, inspectable, hot-patchable process.

## Document map

| File | What it covers |
|------|---------------|
| [`sexpr.md`](sexpr.md) | The main design doc. Thesis, layer-by-layer mapping of 2025 agent-harness concepts to 1985 Lisp-machine primitives, module-by-module plan, open questions. **Start here.** |
| [`symbolics-lisp.md`](symbolics-lisp.md) | History and architecture of Symbolics Lisp Machines (LM-2, 3600 family, XL, MacIvory, Open Genera), the Genera OS, CLIM, Dynamic Windows, Document Examiner, and the patch system. The "what we're modernizing" reference. |
| [`agent.md`](agent.md) | Survey of 2025–2026 AI agent harness architecture: the agent loop, context engineering (write/select/compress/isolate), tool dispatch, MCP, subagents, skills with progressive disclosure, and sandboxing. The "what we're translating" reference. |
| [`sbcl.md`](sbcl.md) | SBCL and Quicklisp deep-dive: the live image, hot redefinition, the condition/restart system, `save-lisp-and-die` for whole-image snapshots, and Quicklisp as a dependency/skill distribution mechanism. The "our runtime substrate" reference. |
| [`sbcl-libs.md`](sbcl-libs.md) | Library survey: maps the sexpr design onto existing Common Lisp libraries (ASDF, UIOP, cl-llm-provider, etc.), noting availability and fit. The "what already exists" reference. |

## How to read them

1. **`sexpr.md`** first — it synthesizes the others and states the
   thesis. Read its §0 ("Thesis") for the core argument and §11
   ("Sources / lineage") for how it draws on the other three docs.
2. **`symbolics-lisp.md`** if you want the historical/architectural
   background on what we're modernizing.
3. **`agent.md`** if you want the 2025 state of the art that we're
   translating into Lisp.
4. **`sbcl.md`** and **`sbcl-libs.md`** if you want the implementation
   substrate and what's already available in the CL ecosystem.

## The mapping

`sexpr.md` §0 contains the central table that maps agent-harness
concepts to their Lisp-machine ancestors:

| Agent harness (2025) | Lisp machine (1985) |
|---------------------|---------------------|
| The transcript is the only state | The image is the only state |
| Context engineering / compaction | GC + ephemeral memory + presentations |
| Tool use / function calling | Calling functions. Literally. |
| Skills with progressive disclosure | Systems, packages, autoloading, Document Examiner |
| MCP servers | Processes/services in one address space (Chaosnet) |
| Approvals & permissions | Condition system + restarts |
| Subagents | Lightweight processes sharing one heap |
| Agent OS | Genera |

The project is an attempt to build the left column *in the language
of the right column*.

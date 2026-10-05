# AGENT.md — working notes for AI agents on this repo

You are editing **sexpr**, an Agent OS written in Common Lisp. The
runtime *is* a living SBCL image: the model is a socket, not a master.
Read the top of `README.md` and `notes/sexpr.md` §0–§2 for the thesis
before doing anything non-trivial. The design is opinionated — matching
it beats being clever.

## Stack

- **SBCL** + **Quicklisp** + **ASDF**. No other implementation is
  supported; do not add portability guards or `#+sbcl` noise preemptively.
- External deps live in `qlfile` (Qlot) and in
  `~/quicklisp/local-projects/` for anything not in the dist. The only
  current dep is **cl-llm-provider** — see the boundary rules below.
- License is **GPL-3.0-or-later**. Every new source file must carry the
  SPDX header (see *Conventions*); `.gitignore`d agent cruft is
  `Unlicense`d.

## Commands

```sh
make hello    # non-interactive smoke test: quickload + (sexpr:hello)
make load     # interactive SBCL with the system loaded
make clean    # strip fasls / qlot workdirs
asdf:test-op  # runs (sexpr:hello); defined as a method in src/sexpr.lisp
```

There is no test suite yet. When you add one, wire it through the same
`asdf:perform` method (the ASDF bundled with Quicklisp miscompiles inline
`:perform` bodies once a system has real deps — that is why `sexpr.lisp`
defines the method rather than inlining it; do not "fix" this).

`hello-llm` talks to a local OpenAI-compatible endpoint
(`http://localhost:6969/v1`, model `Gemma-4-E2B-it`, api key `sk-12345`)
to exercise the transport end-to-end. Do not change those defaults
casually — they are load-bearing for smoke tests.

## Source layout

```
sexpr.asd               system definition (single system, submodules)
src/package.lisp        :sexpr package (nickname :$)
src/sexpr.lisp          identity, hello, hello-llm, asdf test-op method
src/provider/package.lisp    :sexpr.provider (nickname :$.provider)
src/provider/provider.lisp   the "Ivory" layer — provider-call boundary
notes/                  design notes + research base (see below)
```

`notes/` is the reference literature for the project, not commentary.
`notes/sexpr.md` is the design thesis and the layer-by-layer mapping
from agent-harness concepts to Lisp constructs; §2 is the process model.
`notes/agent.md`, `notes/sbcl.md`, `notes/sbcl-libs.md`, and
`notes/symbolics-lisp.md` are the research it synthesizes. When you
invent a design decision, cite the note that motivates it (as
`provider.lisp` does: `;;;; DESIGN (notes/sexpr.md §2): …`).

## Design invariants (do not violate)

These are not suggestions; they are the load-bearing structure of the
project. If a change would break one, stop and think.

1. **`provider-call` is the only function sexpr uses to reach the
   model.** Everything downstream of `src/provider/provider.lisp` is
   provider-agnostic by construction. Never import `cl-llm-provider`
   outside `sexpr.provider`.
2. **`provider-call` returns an sexpr transcript node, never a raw
   provider object.** The shape is a plist:
   `(:content …) (:tool-calls ((:id .. :name .. :arguments ..)))`
   `(:model …) (:usage …) (:finish …)`. This is the one place that
   knows the transport's response shape.
3. **cl-llm-provider is transport only.** Do not adopt its tool
   registry, approval, or hooks — tool *execution* stays in the sexpr
   kernel. Two sources of truth for "what a tool is" corrupts the
   design (this is written at the top of `provider.lisp`; keep it
   written).
4. **Swapping providers = rebinding `*model-endpoint*`.** `provider-call`
   resolves lazily on first call; `configure-provider` does not realize
   the endpoint, so configuration never fails just because an API key is
   missing. Do not eagerly realize in `configure-provider`.
5. **The transcript is a first-class object with live references**
   (presentations), not a list of strings. It round-trips through
   `print`/`read`. Compaction is GC over events, not prompt surgery.
6. **Approvals are conditions; permissions are restarts.** Non-unwinding
   semantics mean a denied effect leaves the agent's stack intact. When
   you build the approval layer, use `handler-case` / `invoke-restart`,
   not try/except-flavoured flags.
7. **Tools are Lisp functions wearing metadata**, not JSON schemas. The
   lambda list + declared types *are* the schema; do not duplicate it.
8. **Skills are ASDF-loadable systems** with `SKILL.md`, `SKILL.sexp`,
   and optional scripts. Progressive disclosure is `load`.

## Conventions

- **SPDX header on every new file.** Lisp:
  `;;; SPDX-License-Identifier: GPL-3.0-or-later`. Makefiles, shell, and
  other comments: `# SPDX-License-Identifier: GPL-3.0-or-later`.
  Agent-cruft (`.gitignore`, `.mcp.json`) is `Unlicense`.
- **Comment style**: file-level headers use `;;;;`, section headers use
  `;;;`, inline uses `;;`. Headers often open with a `DESIGN (…)` or
  `BOUNDARY:` line citing the note that motivates the file. Preserve this
  voice when editing — it is the project's way of keeping invariants
  auditable.
- **Naming**: lowercase, dash-separated function and variable names
  (`provider-call`, `*model-endpoint*`); packages lowercase (`sexpr`,
  `sexpr.provider`); keywords for config and plist keys (`:anthropic`,
  `:content`, `:tool-calls`).
- **Export discipline**: define-and-export in the same file where
  practical — `provider.lisp` uses an explicit `(export 'foo)` right
  after each `defun` because the package clause can't see them. Match
  this. When you add public symbols, also add them to the
  `:export` clause in the package file so the two agree.
- **Docstrings**: real docstrings on every public function, in the
  prose style of `configure-provider` (a short imperative summary,
  then the contract, then non-obvious gotchas). Do not write
  `;; foo does foo` stubs.
- **Generic functions for boundaries**, plain functions inside.
  `provider-call` is a `defgeneric`; the kernel will dispatch on
  endpoint type. Follow the pattern.
- **Keep `alexandria` out of `:use`.** It is available transitively via
  cl-llm-provider; use fully-qualified `alexandria:foo` calls when you
  need it (as `configure-provider` does) rather than importing it into
  the package.

## Prose voice

`README.md` and `notes/` are written in a distinctive, opinionated
voice: declarative, comparative ("Lisp already solved X"), and
unapologetic. When you extend the README or add a note, match the
register — dense tables, short paragraphs, concrete mappings over
adjectives. Do not soften it. Do not add marketing filler.

## What not to do

- Don't inline `:perform` bodies in `sexpr.asd` (see *Commands*).
- Don't pass API keys through `configure-provider`; cl-llm-provider
  reads them from the environment directly.
- Don't add a new dep without a note in `notes/sbcl-libs.md` explaining
  why Quicklisp's existing libraries are insufficient.
- Don't introduce Python/TS orchestration around the image. The whole
  point is that there is no harness outside Lisp.
- Don't commit `.bg-shell/`, `.claude/`, `.gsd/`, or `.mcp.json` — they
  are machine-specific and gitignored.
- Don't rename files or packages to match "modern" conventions. The
  package nicknames `:$` and `:$.provider` are deliberate (sexpr
  aesthetic); keep them.

## When in doubt

- Read `notes/sexpr.md` first; then `notes/sbcl.md` for the Lisp
  substrate. The design is cross-checked against `notes/sbcl-libs.md`
  — most of what you might be tempted to build already exists in
  Quicklisp; check there before writing it.
- The open questions in `README.md` (§Open questions) are still open.
  Sandbox granularity, token cost of sexpr I/O, determinism/replay,
  multi-agent coherence, and "how much LLM vs. symbols" are all
  unresolved. Don't silently pick an answer; call the choice out in a
  comment and leave the note updated.

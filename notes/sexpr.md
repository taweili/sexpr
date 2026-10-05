# sexpr — An Agent OS in Pure Lisp

*Brainstorm document. Synthesizes ideas from: SBCL/Quicklisp research (`notes/sbcl.md`), agent harness architecture (`notes/agent.md`), and Symbolics Genera (`notes/symbolics-lisp.md`).*

## 0. Thesis

Modern agent harnesses bolt agency onto the model from the outside: a Python/TS process owns the loop, the transcript, the tools, the memory, and the model is a stateless oracle called over HTTP. **sexpr inverts this**: the agent runtime *is* a living Lisp image. The harness is not scaffolding around intelligence — it is an operating environment in which intelligence is a first-class, inspectable, hot-patchable process.

The Lisp machine already solved most of what agent engineering is rediscovering:

| Agent-harness concept (2025) | Lisp machine concept (1985) |
|---|---|
| "The transcript is the only state" | The image is the only state |
| Context engineering / compaction | GC + ephemeral memory + presentations with output history |
| Tool use / function calling | Calling functions. Literally. |
| Skills with progressive disclosure | Systems, packages, autoloading, Document Examiner |
| MCP servers | Processes/services in the same address space, Chaosnet |
| Approvals & permissions | Condition system + restarts |
| Subagents | Lightweight processes sharing one heap |
| Agent OS | …Genera |

sexpr's job is to close the loop: rebuild these ideas around an LLM as a *resident process* of the image, not its master.

---

## 1. Core mapping: agent architecture → native Lisp constructs

### 1.1 The agent loop → `eval`, made explicit

The agent loop is a REPL where one of the "users" is a model. In sexpr the loop is not hidden in a framework — it's a documented, redefinable function:

```lisp
(defun agent-loop (agent goal)
  (loop with ctx = (initial-context agent goal)
        for step = (model-step agent ctx)          ; LLM call: sexpr in → sexpr out
        do (setf ctx (integrate ctx step))          ; eval tool forms, fold results in
        until (finished-p step)
        finally (return (result-of step))))
```

- **`model-step` returns code, not JSON.** The protocol between model and harness is the *s-expression*. A tool call is a form; a response is a form; a plan is a form. JSON tool schemas are a foreign serialization — in sexpr, schemas are Lisp type declarations and `deftype`s.
- The loop itself is just a function: redefinable at runtime (hot-patching the agent's own cognition while it runs), traceable (`(trace model-step)`), and replaceable per-agent.
- Safety comes from **evaluation discipline**: model-emitted forms are `eval`'d in a restricted package with a capability-limited symbol environment (§5), not in the ambient image.

### 1.2 The transcript → a first-class persistent object

Harness lesson: "the transcript is the only state." sexpr makes it a real data structure:

```lisp
(defclass transcript ()
  ((events    :initform (make-array 0 :adjustable t :fill-pointer 0)) ; vector of EVENTs
   (anchors   :initform '())          ; compaction anchors
   (objects   :initform (make-hash-table)))) ; presentation registry: object-id → live object
```

- Events are not strings: `(user "fix the bug in parser.lisp")`, `(model (:thought …) (:call (edit-file …)))`, `(result #<file-buffer …>)`. Because output carries *object references* (presentations, §4), the transcript is a graph of live objects, not dead text.
- **Compaction = GC.** When context pressure rises, `compact` reifies older event ranges into summary nodes and drops the raw events — literally a generational garbage collector over conversation history. Summaries are the "old generation"; the recent window is nursery.
- **Serialization = `print`/`read`.** The whole transcript round-trips through s-expressions — sessions persist to disk and resume exactly, for free. (Where objects aren't printable, presentations store a rehydration form.)

### 1.3 Tools → functions with presentation types & capabilities

A tool in sexpr is an ordinary Lisp function wearing metadata:

```lisp
(define-tool edit-file ((path file-pathname) (edits list))
  (:documentation "Apply exact text replacements to a file")
  (:capability :fs-write)
  (:cost :low)
  (apply-edits path edits))
```

- The model-visible "schema" is derived from the lambda list + declared types. No JSON schema duplication — **one source of truth**.
- Tool results are *presented*, not stringified: a file read yields a presentation wrapping the actual buffer object, with a printed rendering chosen for the model's token budget. The model sees text; the system keeps the object.
- Discovery is `apropos`: the agent can search its own tool space at runtime (`(apropos-tool "postgres")`), which *is* progressive disclosure for tools — load schemas just-in-time instead of pinning 40 MCP schemas in the system prompt.

### 1.4 Context management → memory management

The central insight from context engineering ("curate the smallest set of high-signal tokens") maps onto memory management vocabulary:

| Context strategy | sexpr mechanism |
|---|---|
| Write | `remember`/`note` — agent writes to files & its own doc store (cheap, native) |
| Select | `apropos`-style retrieval over tools, skills, docs, prior transcript summaries |
| Compress | `compact` — generational summarization with anchors |
| Isolate | **Processes** — subagents are `sb-thread` threads (or `lparallel` tasks) with their *own* transcript object, sharing the heap; they return `(values summary presentations)` |

Because subagents share the address space, isolation is about *context*, not data: a subagent can return live objects (parsed ASTs, open handles) to its parent without serialization — something JSON-transcript harnesses fundamentally cannot do.

### 1.5 Memory → the image, plus stores

- **Working memory** = the current transcript.
- **Episodic memory** = past transcripts, saved as `.lisp` files; `grep`/`read` over them is just file I/O.
- **Semantic memory** = ordinary Lisp global state: `defvar`ed world models, hash tables, an embedded triple store or graph — all hot-inspectable.
- **Procedural memory** = *skills* (§3) and, at the limit, learned **compiled functions** — the agent can write, compile, and intern new functions into its own packages. An agent that improves itself by editing its own source is not a metaphor here; it's `defun` + `compile` + `fdefinition`.

### 1.6 Planning → macros and code-as-data

Plans are programs. A plan is a quoted s-expression the agent constructs, inspects, rewrites, and then executes stepwise:

```lisp
(defparameter *plan*
  '(progn
     (step :explore  (find-callers 'parse-entry))
     (step :patch    (edit-file "parser.lisp" …))
     (step :verify   (run-tests :parser))
     (on-failure :patch (invoke-restart 'revert-and-rethink))))
```

- Macros let sexpr define a *plan DSL* whose semantics the agent can rely on (checkpointing, retries, parallelism) without burning tokens on boilerplate each time.
- The model can emit plan *transformations* (`(splice-retry-around step-3)`) — code manipulating code — which is the natural notation for a system whose thoughts are already code.

---

## 2. The process model

```
+-------------------------------------------------------------+
|  sexpr image (one address space, SBCL or similar)           |
|                                                             |
|  kernel process: scheduler, GC, capability table            |
|  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          |
|  │ agent proc  │  │ agent proc  │  │ human proc  │          |
|  │ (goal loop) │  │ (subagent)  │  │ (listener)  │          |
|  │ transcript  │  │ transcript  │  │             │          |
|  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘          |
|         └────────────────┴────────────────┘                 |
|              shared heap: tools, skills, world state        |
|  model endpoint processes: sockets to LLM providers         |
|  MCP bridge process (for legacy/foreign tools)              |
+-------------------------------------------------------------+
```

- **Agents are processes** (threads) with an owner, a goal, a transcript, a capability set, and a budget (tokens/time). Spawn = `make-agent` + `make-thread`. Kill = thread kill + budget cleanup. Parent can `inspect` a child's transcript live.
- **The model is a socket.** LLM providers are I/O endpoints (`model-call provider messages → sexpr`). Swapping providers = rebinding one function. Local model vs frontier model routing is just dispatch.
- **Budgets as dynamic variables**: `(with-budget (:tokens 50000 :seconds 600) …)` — dynamically scoped, so subagent budgets nest inside parent budgets naturally. Special variables were made for this.
- **Interrupts**: because everything is a thread in one image, a human (or a supervisor agent) can interrupt any agent, drop into its debugger, evaluate forms in its dynamic environment, and let it continue. Steering = `(interrupt-thread agent (lambda () (inject-note "focus on the parser")))`.

---

## 3. Skills → systems, packages, documents

Agent Skills (SKILL.md + progressive disclosure) already mirror 1980s Lisp practice; sexpr makes it literal:

- A **skill** is a directory: `SKILL.sexp` (metadata: name, trigger description, capabilities needed), an `SKILL.md` instruction body, plus optional `scripts/*.lisp`, `reference/*.md`, `examples/`.
- Registry holds **only (name . description) in context** — a few tokens each. On trigger, the agent `load`s the skill: instructions enter context, scripts are compiled into a skill package (`skill:pdf-tools`), references stay on disk until `read`.
- Because skills are also **ASDF systems**, a skill can `quickload` real dependencies. Because they live in one image, a loaded skill's functions are *immediately callable tools*.
- Skills are versioned dists (Quicklisp model): `(update-skills)`, pinning, private skill dists for an org's proprietary know-how.
- Authoring loop is self-hosted: the agent writes its own skills (it has `edit-file`…), turning repeated task solutions into crystallized procedural memory. Skill writing *is* learning.

## 4. Interface: the presentation system reborn

sexpr's human-facing UI takes Genera's core idea — **present output as typed objects, never as dead text** — and points it at agent work:

```lisp
(present buffer 'file-buffer :stream *listener*)
```

- Everything an agent emits in the Listener is a presentation wrapping the live object: files, diffs, test results, transcripts, subagent processes. Click a test failure → its backtrace; click a file mention → Zmacs-like buffer; click a subagent → attach to its transcript.
- **Commands are typed and clickable**: `Fix`, `Retry`, `Approve`, `Redefine`, `Compact context`. Arguments are filled by clicking presentations. The human operates the agent OS with the same command processor the agents use — humans and agents are peers in the command loop.
- Model-facing rendering is the same substrate with a different view: presentations render to token-budgeted text for the LLM (`present` with `:view :model`), and to rich hypertext for the human (`:view :human`). One object, two projections.
- Documentation is a Document-Examiner-style hypertext system; since skills, tools, and source are all in-image, every mention of a function in any document is a live link to its definition, its callers, its test history.
- Practical v1: the Listener lives in a terminal (or Emacs via Swank); presentations degrade to numbered object references the human can `describe`. Rich UI later — the *architecture* (object-preserving output) matters from day one, the pixels don't.

## 5. Safety: conditions, restarts, and capabilities

The condition system is the best approval/permission architecture ever designed; sexpr builds security on it instead of bolt-on config files.

- **Effects signal conditions.** Any tool attempting a privileged effect signals:
  `(signal 'effect-requested :capability :fs-write :target path :description "…")`
- **Capability grants are restarts.** The dynamic environment (set by the human, a policy agent, or config) establishes restarts: `grant-once`, `grant-session`, `grant-always`, `deny`. A handler chooses the restart — interactively (human in the loop) or programmatically (policy).
- Non-unwinding semantics mean the agent's work **is not destroyed** when approval is needed: the stack waits at the point of effect; the human inspects the exact state; approval resumes precisely there. Compare: Python harness re-prompting the model after a tool denial, losing stack context entirely.
- **Sandboxing layers**: (1) restricted eval packages for model-emitted code, (2) capability conditions for effects, (3) OS-level sandbox for `run-program` escapes. Package locks (`sb-ext:lock-package`) protect the kernel from agent meddling — unless deliberately unlocked.
- Kill switches: budget exhaustion signals `budget-exceeded` with restarts `extend-budget` / `return-partial-result` — graceful degradation is built into the arithmetic of the loop.

## 6. Hot-patching the mind

SBCL research pay-off: sexpr agents are **online-modifiable systems**.

- Redefine any tool, skill procedure, planner macro, or even `agent-loop` while agents run; symbol indirection picks up the new definition next call (with the standard caveats: avoid inlining across the seam, beware captured function objects).
- The system patches **itself**: an agent notices a broken tool, edits the tool's source, recompiles, `retry`s via the condition system — self-repair using the same machinery a human operator would.
- Class redefinition with `update-instance-for-redefined-class` lets the world-model schema evolve under live data: add a slot to `agent` or `transcript`, migrate all live instances lazily, no restart.
- `save-lisp-and-die` snapshots an entire *society of agents mid-thought*: hibernate the OS, ship the image, resume elsewhere. The image is the deployment artifact (with the §7 caveats from sbcl.md about sockets/threads/FDs — sexpr agents must implement `reinitialize-after-restore` methods).

## 7. MCP and the outside world

- MCP is the **foreign function interface** of the agent world, and sexpr treats it exactly like a C FFI: a bridge process speaks MCP (stdio/HTTP JSON-RPC), and each foreign tool is *imported* as a native `define-tool` wrapper with inferred types. Foreign results arrive as text but are re-presented as objects where possible.
- This keeps the kernel culturally pure (sexprs, presentations, conditions) while remaining pragmatically connected — the same posture Genera took toward NFS/TCP: full participation, on Lisp terms.
- sexpr should also *be* an MCP server: expose agent processes as tools (`ask-agent`, `spawn-agent`) so other harnesses can call in — an agent OS that other agents can inhabit.

## 8. Open questions / design tensions

1. **Sandbox granularity**: one heap means one fault domain. Genera accepted this for productivity; can sexpr afford it when the code-writer is an LLM? Options: per-agent packages + capability conditions (soft), separate images with message-passing for untrusted work (hard).
2. **Token cost of sexpr I/O**: s-expression protocol is compact, but presentations must render economically for models. Need a `token-budget` aware printer (`write :budget 2000`).
3. **Determinism & replay**: transcripts + saved images give strong replay, but model calls are nondeterministic. Record model responses as events; replay = re-eval with canned responses.
4. **Multi-agent coherence**: shared heap invites races. Lisp answer: the world model lives behind transactional accessors (STM-lite or a rules engine), not naked globals.
5. **How much LLM, how much symbolics?** The interesting frontier: hybrid cognition — the model proposes, symbolic machinery (type system, planner, conditions) disposes. Keep the model's role *proposal generation under uncertainty*; keep control flow symbolic.

## 9. Sketch: the smallest honest kernel

```lisp
;; --- kernel ---
(defclass agent ()
  ((name :initarg :name) (goal :initarg :goal)
   (transcript :initform (make-instance 'transcript) :accessor transcript)
   (capabilities :initarg :capabilities :initform '(:fs-read))
   (budget :initarg :budget :initform (make-budget :tokens 100000))
   (thread :accessor agent-thread)))

(defun spawn (goal &key (capabilities '(:fs-read)) (parent *agent*))
  (let ((a (make-instance 'agent :goal goal :capabilities capabilities)))
    (setf (agent-thread a)
          (make-thread (lambda () (with-capabilities capabilities
                                    (with-budget (budget-of a)
                                      (agent-loop a goal))))
                       :name (format nil "agent:~a" goal)))
    a))

(defun model-step (agent ctx)
  (read-model-response                      ; s-expr protocol
    (provider-call *model-endpoint*
      (render-for-model ctx :budget (context-budget agent)))))

;; effect gating via conditions
(defun perform-effect (capability thunk description)
  (restart-case
      (handler-bind ((effect-requested
                       (lambda (e) (invoke-restart
                                     (policy-decide e *agent*)))))
        (signal 'effect-requested :capability capability :description description)
        (funcall thunk))
    (grant-once () :test (lambda (c) (typep c 'effect-requested)) (funcall thunk))
    (deny () :test (lambda (c) (typep c 'effect-requested))
      (values nil "denied by policy"))))
```

Everything else — skills, presentations, MCP bridge, compaction — hangs off these few types.

## 10. Naming the layers

A tongue-in-cheek but honest layering, bottom-up:

- **CADR** — hardware/VM substrate (SBCL runtime, threads, GC)
- **Zetalisp** — kernel: agents, transcripts, capabilities, budgets, conditions
- **Flavors** — object model: presentations, tools, skills, world-model classes
- **Genera** — environment: Listener UI, command processor, document examiner, skill registry
- ** Ivory** — the model endpoints: interchangeable oracles, external cognition
- **sexpr** — the whole thing, because code is data is thought.

## 11. Sources / lineage

- `notes/sbcl.md` — live image, hot redefinition, conditions/restarts, `save-lisp-and-die`, Quicklisp dists
- `notes/agent.md` — harness anatomy, context engineering (write/select/compress/isolate), skills & progressive disclosure, MCP architecture
- `notes/symbolics-lisp.md` — Genera, Dynamic Windows & presentations, Document Examiner, Flavors, patch systems
- Direct inspirations: Moon, "Symbolics Architecture" (1987); Anthropic, "Effective context engineering for AI agents" & "Agent Skills" (2025); LangChain, "Anatomy of an Agent Harness" (2025).

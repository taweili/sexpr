# sexpr — the Remote TUI

*Brainstorm document. Synthesizes the runtime surfaces already in `src/` (kernel, agents, transcript, cli, repl) with the interface substrate named in `notes/sbcl-libs.md` §8 and the process model in `notes/sexpr.md` §2. Cites line numbers from `sbcl-libs.md` where the substrate was already decided.*

## 0. Thesis

The agent runtime *is* a living Lisp image (§0 of `sexpr.md`). A TUI is therefore a **window into the image**, not a harness around it. It owns no loop, no transcript, no tools, no model state; it renders projections of live objects and operates on them by evaluating forms in the image. The moment the TUI becomes scaffolding *around* intelligence, it violates the one rule the whole project is built on (`AGENT.md`: *"Don't introduce Python/TS orchestration around the image. The whole point is that there is no harness outside Lisp."*). So the TUI is Common Lisp, it connects over the Lisp-native console protocol, and it holds projections — never live objects.

This is the Genera posture, modernized: a remote listener attached over the network to a society of agents that never stops running. Attach, work, detach; the society keeps thinking.

## 1. The substrate (already decided in `notes/sbcl-libs.md`)

| Concern | Choice | Where decided |
|---|---|---|
| **Wire** | **swank / slynk** — "the human operator's console: attach to the live OS, inspect any agent's transcript, patch tools mid-run" | `sbcl-libs.md` L51 |
| **TUI v1** | **cl-tuition** — pure-CL, TEA + CLOS, Bubble-Tea-class components; supersedes the ncurses pair | §1.1 below; amends `sbcl-libs.md` L104 |
| **TUI v2** | **McCLIM** — the real presentation substrate (`:view :human`) | `sbcl-libs.md` L103 |
| **Day-one fallback** | Sly/SLIME + slynk — "do not underestimate this as v1 UI" | `sbcl-libs.md` L106 |

The one amendment this note makes to `sbcl-libs.md`: **cl-tuition supersedes `cl-charms` / `croatoan` for Terminal UI v1.** cl-tuition is pure Common Lisp (MIT, actively maintained), CLOS-message TEA, and ships `chat`, `tree`, `table`, `viewport`, `textarea`, `list`, mouse `zones`, and spring animation — the polished, Lisp-native surface the ncurses pair was reaching for. McCLIM remains the v2 prize for `:view :human`.

### 1.1 Why cl-tuition, not cl-charms/croatoan and not a foreign viewer

- **Pure CL → no foreign harness.** A Go (bubbletea) or Rust (ratatui) client is a non-Lisp process owning rendering — borderline against the *"no harness outside Lisp"* rule, defensible only as a pure viewer. cl-tuition removes the need for that defense: the viewer is Lisp too.
- **TEA + CLOS** is the CLOS-idiomatic shape the whole project already speaks (conditions, restarts, generic functions at boundaries). Model-View-Update over typed message classes maps cleanly onto "poll the society, render deltas."
- **Async commands** (functions that return messages, non-blocking) are exactly the non-blocking I/O story a Swank-polling client needs — `tui:tick 0.1` re-arms a `transcript-delta` poll without freezing the keyboard.
- **Every pane we want is already a component** (see §4). cl-tuition is the Charm-ecosystem aesthetic (Lip Gloss / Bubbles / Glamour / Harmonica), in Lisp.
- Deps are `bordeaux-threads` + `trivial-channels`, confined to the client process — no clash with the image's direct `sb-thread` use.

## 2. The three panes are Genera subsystems, reborn simultaneous

The CLI already has all three as *sequential* surfaces (`chat-loop`, the escaped `/repl`, the `/agents` tree). The TUI makes them **simultaneous, live, and remote** — and each maps onto a Genera subsystem that `notes/symbolics-lisp.md` names:

| sexpr pane | Genera ancestor | Existing sexpr surface | TUI upgrade |
|---|---|---|---|
| **Chat** | **Converse** (chat) | `chat-loop` + the render cursor in `chat-session` | scrollback that streams; binds to the focused agent's transcript |
| **Agent console** | **Peek** (system status) | `/agents` static tree (`cmd-agents`, status icons `✓ ↻ ✗ ⏎`) | live process manager over `*agent-table*` + `*subagent-registry*` |
| **REPL** | **Listener** / Zmacs | escaped `/repl` with `*agent*` bound | Swank listener with `*agent*` = focused agent |

The unifying interaction is the Genera "select an object, operate on it" model: **a focused agent**. Select a row in the agent console → the chat pane rebinds to that agent's transcript, and the REPL binds `*agent*` to it. One society, one cursor across all three panes.

## 3. cl-tuition's TEA maps onto the sexpr push loop

```
Model     a CLOS object: focused-agent, transcript-cursor,
          agent-tree-snapshot, repl-history, swank-conn, push-conn
Messages  tui:key-msg            chat send / repl eval / tree nav / focus
          custom delta-msg         <- decoded from the push channel
          custom finalize-msg      <- decoded from the push channel
          custom agent-event-msg   <- status / agent-added / compact
          custom resync-msg        <- refetch via transcript-delta
          custom approval-msg      <- the approval queue
          tui:window-size-msg      reflow panes on resize
Commands  a reader thread per subscription, blocking on a socket read,
          decodes each sexpr line into the message above
          (tui:tick 0.1) for cursor blink and fallback poll
View      join-horizontal / join-vertical of three bordered panels
```

The reader thread is the push side of cl-tuition's async model: it blocks on a socket read, decodes each line with `read` (sexprs — print/read for free), and returns the matching message. `tui:tick 0.1` remains for cursor blink and as the fallback poll. The render-cursor concept from `chat-session` still crosses the process boundary, but it only runs on `resync` — the normal path is deltas.

## 4. Layout & Panes → cl-tuition components

**Master-detail layout:**

```
+-----------------------------------+------------------+
|                                   |  AGENT PANE      |
|   VIEWPORT (chat)                 |  ● agent A  idle  |
|   shows transcript of picked      |  ● agent B  busy  |
|   agent; textarea for input       |  ● agent C  wait  |
|                                   |                  |
|                                   |  picked: agent B |
+-----------------------------------+------------------+
|                                   |                  |
|   REPL (dev console)              |                  |
|   forms eval'd over Swank         |                  |
+-----------------------------------+------------------+```

| Pane | Position | cl-tuition building blocks | Notes |
|---|---|---|---|
| Viewport (chat) | Left, top | `textarea` (input) + `viewport` (scrollback) | Shows transcript of **picked** agent; viewport content set by `transcript-delta` |
| Agent pane (Peek) | Right | `table` + mouse `zones` + `make-style` | Lists all agents with **three status lights**: green (idle), red (busy), yellow (waiting for approval). Picked agent gets highlight border. Row click = focus |
| REPL | Left, bottom | `textarea` (form input) + `viewport` (values) | forms eval'd over Swank; `*agent*` bound to picked agent; `,exit`-style meta |
| Chrome | All | `render-border` (`*border-rounded*`), `join-horizontal`/`join-vertical`, `make-style` | exactly `examples/layout.lisp` composition |

## 5. The image side: a new `sexpr.tui` package

The client never speaks raw kernel internals. It calls a small typed RPC package, `sexpr.tui`, that lives **in the image** and wraps the kernel/agents surfaces the TUI needs. Like `sexpr.cli`, it **never imports `:sexpr.provider`** (R015): the model is reached only transitively, and the TUI is a viewer, not a model caller.

Every function returns **s-expressions** — which print/read for free (invariant #5). This is `:view :model`'s sibling: a `:view :tui` projection of the society, designed for a management console rather than a token budget.

| `sexpr.tui` function | Returns | Wraps |
|---|---|---|
| `agent-snapshot` | sexpr tree: name, status, `thread-alive-p`, `transcript-length`, capabilities, endpoint, `handle-error`, budget | walks `*agent-table*` / `agent-child-list` |
| `transcript-delta agent cursor` | `(new-events . new-cursor)` | the render-cursor concept, cross-process |
| `inject-note agent note` | confirmation | `subagent-note` / `append-event` |
| `kill agent` | confirmation | `subagent-kill` / `sb-thread:terminate-thread` |
| `spawn goal &key ...` | handle id | `spawn-subagent` |
| `inspect-id id` | printed object | the presentation registry (§4 of `sexpr.md`, when it lands) |
| `pending-approvals` | effect-request queue + restarts | the §5 condition/restart layer, when it lands |
| `start-server port` | bind confirmation | the stage-3 subscription server — Swank stays for eval, this carries deltas |

The client holds **projections + object IDs, never live objects** (R023 — live objects are process-local). "Click a presentation `[N]`" = "eval `(sexpr.tui:inspect-id N)` in the image." The object-preserving architecture is intact; only the projection crosses the wire.

## 6. The push pipeline: LLM → agent → TUI

Decided: **push, not poll.** R016 deferred streaming from the terminal Listener; the TUI pane is where it lands, and the LLM already streams. Three stages, each with its own seam.

```
  model endpoint (LLM)
        │ token deltas
        ▼
  provider-stream            stage 1 — the Ivory layer
        │ advisory fragments
        ▼
  pending buffer (agent slot)
        │ finalize
        ▼
  transcript                 stage 2 — atomic events only
        │ push projection
        ▼
  push channel               stage 3 — one socket per subscription
        │ typed sexprs, newline-delimited
        ▼
  sexpr-tui client
```

### Stage 1 — LLM → image: the streaming loop lives in the kernel

**Decision: option 3.** The streaming loop does **not** sit at the provider seam. `provider-call` stays the only sexpr function that makes the HTTP call. A new kernel function, `model-step-streaming`, calls cl-llm-provider's `complete-stream` (which returns a pull iterator), pulls chunks with `read-stream-chunk`, pushes each fragment to the event bus, and returns the final event — exactly the same event `model-step` would have produced.

```
model-step          (existing, non-streaming)  ──▶ provider-call  ──▶ node
model-step-streaming (new, streaming)          ──▶ complete-stream ──▶ pull chunks
                                                      │
                                                      ▼
                                               event bus (emit fragments)
                                                      │
                                                      ▼
                                               returns final event (same shape as model-step)
```

The kernel is the only package that calls `complete-stream`. `sexpr.provider` stays untouched. The event shape is identical — streaming is a transport concern, not a semantic one. Invariant #1 holds: `provider-call` is still the only non-streaming entry point; `model-step-streaming` is a kernel-level function that uses cl-llm-provider directly (which is acceptable because the kernel is where the loop lives, not the provider seam).

**cl-llm-provider streaming confirmed.** The library exports `complete-stream`, `read-stream-chunk`, `stream-accumulated-content`, `stream-tool-calls`, and `abort-stream`. The earlier research item is resolved: streaming is buildable now, not a future assumption.

### The event bus: the architectural keystone

The event bus is an in-image observable that decouples the kernel from the socket. The kernel emits events on it; `sexpr.tui` subscribes and forwards to the push channel. Neither knows about the other directly.

```
model-step-streaming          sexpr.tui:start-server
       │                               │
       │  emit-event(agent, fragment)   │
       └───────────┬───────────────────┘
                   ▼
            *event-bus* (hash table)
            agent-id → list of listeners
                   │
                   ▼
            (emit-event agent-id event)
            iterates listeners, calls each
```

**Design:** `*event-bus*` is a dynamic variable — a hash table mapping agent-id strings to a list of listener functions. The kernel calls `(emit-event agent-id event)` which iterates the listeners and calls each with the event. `sexpr.tui:start-server` subscribes by adding a listener that writes sexprs to the socket.

**Why a hash table, not conditions:** Conditions are for control flow, not high-rate event delivery. Streaming tokens is high-rate; a condition per token would be too slow. A listener list is the pragmatic choice for v1.

**Why this matters:** The kernel stays pure — it emits events on the bus, not to sockets. `sexpr.tui` stays thin — it subscribes to the bus, not to the model. The bus is the seam that keeps the invariants clean: the kernel never imports `sexpr.tui`, and `sexpr.tui` never imports the provider.

### Stage 2 — image → transcript: stream fragments, commit atoms

**The transcript stays atomic.** Partial events never enter it. An in-flight model event accumulates in a `pending` slot on the agent; on completion it is `append-event`'d once, as a complete `:model` event.

That keeps invariant #5 clean: print/read round-trips only ever see complete events, and a crash mid-stream loses the partial event — which is correct, because it was never committed. The pending buffer is the nursery; the transcript is the heap. The same generational idea as compaction-as-GC, one level lower.

Three ordering rules worth pinning down:

- **One model event = one stream.** `finalize` commits the event *before* tool dispatch, so tool results are their own streams (`tool-start` → `tool-result`) and never interleave with the model's prose.
- **One stream per agent.** A client subscribed to agent A gets A's deltas; B is a separate subscription. `focus` switches resubscribe.
- **Compaction is pushed too.** When it lands, `(compact :agent A :from I :to J :summary S)` lets the TUI collapse a range in the scrollback visually — the GC becomes visible instead of invisible.

### Stage 3 — image → TUI: a subscription channel, not a poll

Swank is request/response. Push needs a second surface: `sexpr.tui:start-server` opens a port, a client connects and subscribes to agents, and the image pushes typed sexprs on a newline-delimited stream:

```
(delta       :agent A :kind :model :text "...")
(finalize    :agent A :event-index N)
(tool-start  :agent A :call-id C :name "shell")
(tool-result :agent A :call-id C :value <projection>)
(status      :agent A :status :running :error nil)
(agent-added :agent A :parent P)   (agent-removed :agent A)
(compact     :agent A :from I :to J :summary S)
(approval-needed :agent A :capability C :target T :restarts R)
(resync      :agent A :cursor N)
```

This is the same push-service substrate `sexpr.md` §7 wants for "sexpr as an MCP server": one channel mechanism, two transports, one message vocabulary. The TUI speaks sexpr-over-newline (compact, ours); an MCP bridge speaks HTTP over the same server. Building the TUI push channel builds half of §7.

**Push is the view; the transcript is the truth.** Push is fire-and-forget: a client that falls behind, or disconnects, loses deltas. That is fine, because the recovery path *is* the old poll — the server coalesces or drops fragments when a client lags and sends `(resync :agent A :cursor N)`, and the client refetches structure via `transcript-delta`. Polling is not deleted; it is the backpressure-recovery path. That is why §5 keeps `transcript-delta` and `agent-snapshot`.

### What push unlocks that polling could not

- **Tool progress.** `dispatch-tool-call` is today synchronous and silent: a long tool (a `shell` call running a build) produces nothing until it returns. Push gives tools a progress stream — `tool-start`, fragments, `tool-result` — so the chat pane stays alive during long calls. It hints at tools signaling progress *conditions*, which fits §5's vocabulary exactly.
- **A society view.** The focused-agent model can relax. With push, one client can subscribe to *several* agents and show N transcripts streaming at once — closer to Genera's Peek with live traces than to a single chat window.
- **A live REPL pane.** Eval a form that calls the model and it streams back; `(trace ...)` output can push. The REPL becomes a window into cognition, not just a command line.

The honest cost: two servers in the image, and push has no transactions — an `inject-note` eval'd over Swank is asynchronous with respect to the deltas arriving on the push socket (§10.2).

## 7. The wire & lifecycle

- **Swank as transport, `sexpr.tui` as API.** Swank already gives remote eval, a REPL, an inspector, backtraces, and `compile-string` (hot-patch) for free. The chat and console panes call typed `sexpr.tui` functions over the same connection. Best of both: the REPL pane *is* a Swank listener; the other two panes are typed RPC over it.
- **Two servers, one vocabulary.** Swank carries eval and commands (request/response, low rate); the push channel carries deltas (one-way, high rate). Separate sockets because the rates differ by three orders of magnitude — but both speak the `sexpr.tui` message vocabulary (§6, stage 3).
- **Remote = separate process.** The TUI is a small `sexpr-tui` SBCL executable (cl-tuition + a swank-client), not a thread in the image. A thread-in-image would be the pure Genera posture (one address space) but is not network-remote. The separate process buys crash-isolation — a TUI bug never takes down the agent society — and true attach/detach.
- **Attach/detach without killing the society** is the complement to `save-lisp-and-die` (`sexpr.md` §6): you do not snapshot the image, you just leave the society running and reattach. Disconnect; the agents keep thinking; reconnect to the same live state.
- **Security.** Swank has no auth by default. Over localhost that is fine; for a society on a remote server, tunnel over SSH (`notes/sbcl.md` already assumes this for live patching). A shared-secret token on the `sexpr.tui` calls is worth it the moment you go past localhost.

## 8. Presentations degrade to numbered refs

`sexpr.md` §4: *"the Listener lives in a terminal (or Emacs via Swank); presentations degrade to numbered object references the human can `describe`. Rich UI later — the architecture (object-preserving output) matters from day one, the pixels don't."* The TUI honors this: every event renders with `[N]` object refs; a ref is resolved by eval'ing `(sexpr.tui:inspect-id N)`, whose result renders in the REPL pane (or a pop-over). The pixels are cl-tuition's job; the object-preserving seam is `sexpr.tui`'s job, from day one. McCLIM (v2) is where `[N]` becomes a real clickable presentation type.

## 9. The approval queue (the killer feature, when §5 lands)

The agent pane's real differentiator is not the process tree — any `htop` has that. It is the **approval queue**. When approvals are conditions and permissions are restarts (`sexpr.md` §5, `AGENT.md` invariant #6), a pending `effect-requested` shows as a row: capability, target, description, and the available restarts (`grant-once`, `grant-session`, `grant-always`, `deny`). Because the semantics are **non-unwinding**, approving resumes the agent at the *exact stack point* of the effect — the human inspects the precise state and resumes precisely there. No JSON-transcript harness can do this; it is the whole reason approvals were built on the condition system. The TUI is the natural home for that queue.

**Push makes it reactive instead of polled.** `(approval-needed ...)` arrives on the stage-3 channel the instant the condition is signaled — no poll interval, no lag while the agent sits blocked. That matters precisely because the restart is non-unwinding: the agent is *waiting at the stack*, so the prompt must appear now, not at the next 100 ms tick. Push plus non-unwinding restarts is the combination that makes a synchronous human-in-the-loop approval real at zero latency. Of everything in this note, this is the one feature that genuinely requires push — the rest would work on polling.

**The approval flow:**

1. Agent B signals `effect-requested` → the event bus emits `(approval-needed ...)` → the agent pane updates agent B's status light from green (idle) to **yellow** (waiting).
2. The user sees the yellow light in the agent pane (right side), notices the pending request.
3. The user clicks agent B in the agent pane → the viewport (left side) switches to agent B's transcript.
4. The transcript shows the `effect-requested` event with clickable restart buttons (`grant-once`, `grant-session`, `deny`).
5. The user clicks a restart → the agent resumes at the exact stack point.
6. The viewport stays on agent B (the user just resolved its approval; switching back would lose context). Agent B's status light returns to green (idle) or red (busy) depending on what it does next.

**Multiple simultaneous effect-requested:** If agent B and agent C both signal effect-requested, **both get yellow lights**. The user resolves them one by one. There is no queue — they are independent blocks at independent stack points. The order of resolution is user-chosen, not priority-based.

## 10. Open tensions (and one parked for later)

1. **Token cost of the delta wire.** Fragments are already strings, so model deltas are cheap; result-event projections (R023) must stay economic. The `:view :tui` printer shares the budget discipline of the deferred `:view :model` printer (`sexpr.md` §8.2). `resync` is the lever: when a client lags, the server stops sending fragments and sends `resync` so the client refetches structure rather than every token.
2. **Push has no transactions.** An `inject-note` eval'd over Swank is asynchronous with respect to the deltas arriving on the push socket, so a single client can observe its own write out of order with its own stream. For one human operator this is cosmetic. The real fix is the same transactional world-model accessors `sexpr.md` Q4 asks for.
3. **How much lives in the image vs the client.** Every rendering decision (status icons, row layout, focus highlight) is client-side and disposable; every state decision (what counts as a snapshot, what an approval carries, which fragments get coalesced) is `sexpr.tui`-side and load-bearing. Keep the line bright: the client is a projection renderer, `sexpr.tui` is the truth.

**Parked for a future note — multi-client coherence.** Two TUIs attached at once both see the same society, and `kill`/`inject-note` writes race. That is the same open question #4 in `sexpr.md` (shared heap → transactional world-model accessors, not naked globals). The TUI does not create it, and it is deliberately out of scope for v1: **assume one operator.** Record it; do not solve it here.

## 11. Where this leaves the existing notes

- **`sbcl-libs.md` L104** — `cl-charms` / `croatoan` for "Terminal UI v1" is superseded by **cl-tuition** for the sexpr TUI. The ncurses pair remains a valid fallback if cl-tuition's deps are unwanted, but cl-tuition is the default.
- **`sbcl-libs.md` L152** ql line `slynk cl-charms ; McCLIM when ready for v2` becomes `slynk cl-tuition ; McCLIM when ready for v2`.
- **`sexpr.md` §4** "practical v1: the Listener lives in a terminal (or Emacs via Swank)" — this note adds the third practical v1: a remote cl-tuition client over Swank, with presentations degrading to numbered refs exactly as §4 prescribes.
- **McCLIM is unchanged** as the v2 presentation substrate for `:view :human`; cl-tuition is the v1 that proves the object-preserving seam first.
- **`sexpr.md` §7** — the stage-3 push channel is the same substrate §7 wants for "sexpr as an MCP server": one push-service mechanism, two transports, one message vocabulary. Building the TUI push channel builds half of §7.
- **`sexpr.md` §8** — question #1 (sandbox granularity) is unaffected. Question #3 (determinism & replay) gains a wrinkle: streamed fragments are ephemeral and must not be replayed as events, or replay would double-apply text. The `pending` buffer is the seam that keeps them out.

## 12. Sources / lineage

- `notes/sexpr.md` §0 (thesis), §2 (process model — agents as threads, the human proc / listener), §4 (presentation system, `:view :model` / `:view :human`), §5 (approvals as conditions), §6 (hot-patching, `save-lisp-and-die`), §8 (open questions #2 #4).
- `notes/sbcl-libs.md` §8 (interface layer — swank L51, cl-charms/croatoan L104, Sly/SLIME L106, McCLIM L103) and the ql line L152.
- `notes/symbolics-lisp.md` §3 (Genera subsystems: Peek, Converse, Zmacs, Inspector) and the "single address space + total introspection" thesis.
- `notes/sbcl.md` — Swank server over SSH for long-running images; the condition/restart fix-and-resume loop.
- `src/` surfaces already in place: `agent` class + `*agent-table*` + `*subagent-registry*` (`src/agents/`), `chat-session` render cursor (`src/cli/`), escaped `sexpr.repl:repl` with `*agent*` (`src/repl/`), `cmd-agents` status icons, transcript `print`/`read` round-trip (`src/transcript/`).
- cl-tuition: `atgreen/cl-tuition` (MIT) — TEA + CLOS TUI; `examples/chat.lisp`, `src/components/{tree,table,list,viewport,textarea}`, `src/zone.lisp`, `src/style.lisp`, `src/layout.lisp`.
- `notes/agent.md` L136–144 (MCP client–host–server, JSON-RPC 2.0, stdio and HTTP/SSE transports, OAuth for remote) — the transport vocabulary the stage-3 push channel shares with an MCP bridge.

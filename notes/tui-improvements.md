;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; notes/tui-improvements.md — TUI review, prioritized plan, and work log.
;;;
;;;; Lineage: a review of `src/tui/` (image side), `src/tui-client/` (remote
;;;; client), `sexpr-tui.sh`, `docs/sexpr-tui.md` and the TUI test files,
;;;; cross-checked against `notes/tui.md`. The findings below are the ones
;;;; that survived reading the code and running the headless harness; each
;;;; cites where it lives. Nothing here is a redesign — the Genera posture
;;;; of the original note is unchanged.

## STATUS (read this first)

- **P0: implemented and verified.** Client harness 163/163 green; full rove
  suite green (499 assertions) at the P0 checkpoint.
- **P1: implemented and verified.** Membership events end to end; scrolling
  and follow mode; agent detail + `/help /spawn /kill /approvals /clear`;
  throttled reconnect for push and swank; async REPL eval with `Ctrl+X`
  abandon. `ql:quickload :sexpr-tui` is clean; client harness **181/181**;
  full rove suite green (**499 assertions, exit 0**).
- **Residual from P1-C:** only the REPL eval is asynchronous. Snapshot polls,
  resyncs, agent switches, notes and approvals still block the TEA thread for
  up to the 30 s reply timeout. They are serialized under `*swank-rpc-lock*`
  so the worker and those paths cannot interleave packets, but a slow image
  can still pause them. Moving them to the same queue is the next step.
- Everything is uncommitted working-tree state; no commit was requested.

Testing note for agents: this sandbox blocks writes under `~/.cache`, so run
SBCL with `XDG_CACHE_HOME=$PWD/.xdg-cache` (see *Commands* in AGENT.md for the
normal `make test`). Remove `.xdg-cache/` before committing.

## What was already right

- `:sexpr`/`:sexpr-tui` boundary enforced by tests, not prose; the client is
  projections-only (R023) and never names a transport package.
- Failure visibility on both channels: counters, `:last-error`, diagnostics.
- Total exact-fit layout from the terminal size, degrading safely.
- Headless testability (`init`/`update`/`view`), which is why these fixes were
  cheap to prove.

## P0 — correctness (done)

| # | Fix | Where |
|---|---|---|
| P0-1 | Agent-scoped `finalize`/`tool-*`/`budget-exceeded`/`resync`; one predicate `agent-is-picked-p` | `model.lisp` |
| P0-2 | Display-width-aware `wrap-text`/`truncate-text`; chat, REPL and agent rows fitted at render time; CJK-safe; ANSI-safe | `view.lisp`, `model.lisp` |
| P0-3 | Chat note sends synchronously; local echo **is** the transcript's `USER:` event and advances the cursor (no more duplicate/desync) | `model.lisp` |
| P0-4 | `--agent` validated against the snapshot with a visible fallback; agent rows sorted by name | `model.lisp` |
| P0-5 | Documented polling fallback implemented: throttled `agent-snapshot` + `transcript-delta` when push is absent/closed | `model.lisp` |
| P0-6 | Approvals: clicks outside the strip switch agents; every offered restart renders as a zoned button; switching restores the new picked row's pending request | `view.lisp`, `model.lisp` |
| P0-7 | Stats plist keyed per connection instead of duplicate anonymous keys | `model.lisp` |

Regression tests: scoping (foreign finalize/tool/budget/resync), wrapping and
frame fit, note echo and failure path, validation/sorting, click-through and
multi-agent approvals, poll on/off, stats shape. All in
`tests/test-tui-client.lisp` under the `P0:` names.

## P1 — capability (in progress)

- [x] **Membership events.** `register-agent!`/`deregister-agent!` emit
  `:agent-added`/`:agent-removed`; the push server enriches the added event
  with the data-only row (`%agent-to-sexpr`); the client decodes both, merges
  or drops rows, reconciles subscriptions, unsubscribes on removal, and
  re-picks when the picked agent vanishes.
- [x] **Scrolling and follow mode.** Wheel routed by layout geometry to
  `:chat`/`:repl`/`:agents`; page keys/Home/End/Ctrl+B/F scroll the focused
  pane; chat holds position when scrolled away instead of being yanked down by
  a streaming turn.
- [x] **Agent detail and actions.** The picked row renders a two-line detail
  from the snapshot it already carries; `/spawn`, `/kill`, `/approvals`,
  `/clear` and `/help` are client-side slash verbs over ordinary RPCs.
- [x] **Async REPL with cancel.** REPL evals run on a background thread
  (`*tui-async-repl*`), show `repl: busy`, and `Ctrl+X` abandons the stale
  result via a generation counter; `*swank-rpc-lock*` serializes the wire.
- [x] **Reconnect/reattach.** A configured-but-closed push or swank channel is
  retried on a throttle, then re-subscribed/re-read; a never-configured channel
  stays on the poll path.

## P2 — polish (not started)

- [ ] Multi-line chat input + history; help overlay (`?`); slash/command
  palette; search; timestamps/role styling; `[truncated — inspect]` markers.
- [ ] Image-side `inspect-id` presentations (notes §8) and a `:compact`
      layout/theme knobs via `SEXPR_TUI_*`.
- [ ] Render throttling / incremental scrollback (the per-fragment full-frame
      rebuild is correct but wasteful; P0 fitting made each rebuild O(lines)).
- [ ] Escape blurs/clears before quitting; port validation; client log env;
      connect timeouts.

## Open tensions carried forward

- Async RPC (P1) is the largest remaining architectural change; it interacts
  with the approval path (`resolve-approval`) and the poller.
- Multi-client coherence is still parked (one operator), per `notes/tui.md` §10.
- Security: both channels remain unauthenticated localhost; the docs already
  say to tunnel or add a token before going remote.

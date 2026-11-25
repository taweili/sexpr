<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# TUI client — landed-work archive

> **Archived.** This was the remote TUI client's review / plan / work log while
> the work was in flight. The P0, P1, and P2 batches below are landed; the only
> items left open are listed under *Open items carried forward*. Kept as the
> record of what shipped, where it lives, and how it was verified. For current
> project state see `README.md` §Status; for the design see `notes/tui.md`.

*Lineage: a review of `src/tui/` (image side), `src/tui-client/` (remote
client), `sexpr-tui.sh`, `docs/sexpr-tui.md` and the TUI test files,
cross-checked against `notes/tui.md`. The findings below are the ones that
survived reading the code and running the headless harness; each cites where
it lives. Nothing here is a redesign — the Genera posture of the original
note is unchanged.*

## STATUS (read this first)

- **P0: landed and verified** (`19b1619`). Client harness 163/163 green at the
  P0 checkpoint; full rove suite green (499 assertions).
- **P1: landed and verified** (same commit). Membership events end to end;
  scrolling and follow mode; agent detail + `/help /spawn /kill /approvals
  /clear`; throttled reconnect for push and swank; async REPL eval with `Ctrl+X`
  abandon. Client harness **181/181**; full rove suite green (**499 assertions,
  exit 0**). A later review found one defect P0-2 had missed — see the caveat
  under the P0 table; the load is now warning-free.
- **Review fix: landed** (`a4d8fbc`). `:sexpr-tui` shadows `WRAP-TEXT` /
  `TRUNCATE-TEXT` instead of redefining cl-tuition's, and passes the truncation
  marker positionally.
- **P2 batch: landed** (`a4d8fbc`) — input history and overlays, `:compact`
  layout and theme knobs, batched rendering, and startup hardening. Every P2
  line below is checked off except the image-side `inspect-id` resolver.
- **Residual:** only the REPL eval is asynchronous. Snapshot polls, resyncs,
  agent switches, notes and approvals still block the TEA thread for up to the
  30 s reply timeout. They are serialized under `*swank-rpc-lock*` so the
  worker and those paths cannot interleave packets, but a slow image can still
  pause them. Moving them to the same queue is the next step.

Run the suite with `make test` (*Commands* in AGENT.md).

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

**Caveat found in review (fixed).** `WRAP-TEXT`/`TRUNCATE-TEXT` were first
defined on the symbols `:use`d from `:tuition`, so loading `:sexpr-tui`
redefined cl-tuition's own functions (`WARNING: redefining TUITION:WRAP-TEXT`)
rather than adding client-local ones. It was latent — this client never renders
styled text at a width — but tuition's `RENDER-STYLED` calls its `WRAP-TEXT`
with keyword arguments, so any width-styled render or markdown view would have
been a program error. `:sexpr-tui` now shadows both names
(`src/tui-client/package.lisp`); the harness resolves them with
`:shadowing-import-from`.

## P1 — capability (done)

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

## P2 — polish (landed in `a4d8fbc`, except the image-side resolver)

- [x] Multi-line chat input + history; help overlay (`?`); slash/command
  palette; search; timestamps/role styling; `[truncated — inspect]` markers.
  Landed as Up/Down history with draft preservation, optional three-row input
  (`SEXPR_TUI_MULTILINE`), the `?` / `Ctrl+P` / `Ctrl+F` overlays,
  `SEXPR_TUI_TIMESTAMPS` and `SEXPR_TUI_ROLE_STYLES`, and distinct
  content-vs-chrome truncation markers.
- [x] `:compact` layout and theme knobs via `SEXPR_TUI_*`:
  `SEXPR_TUI_COMPACT` drops the pane borders and gives the columns to the
  transcript; `SEXPR_TUI_FOCUS_COLOR` retints the border/cursor accent.
- [ ] Image-side `inspect-id` presentations (`notes/tui.md` §8). The client
      renders `[N]` object refs; the resolver that evals
      `(sexpr.tui:inspect-id N)` in the image is still unbuilt. The one P2
      item left.
- [x] Render throttling / incremental scrollback: fragments are batched through
      `*tui-render-batch*` and per-(line,width) fits are memoized, so a turn
      re-fits only its growing in-flight line instead of rebuilding every
      frame.
- [x] Escape clears the focused draft before quitting (an empty input quits);
      `--swank-port` / `--push-port` validated before connecting;
      `SEXPR_TUI_LOG` bound once per process; TCP connects bounded by
      `SEXPR_TUI_CONNECT_TIMEOUT`.

## Open items carried forward

- Finishing the async move (the P1-C residual) is the largest remaining
  architectural change: snapshot polls, resyncs, agent switches, notes and
  approvals still run on the TEA thread under the wire lock, and moving them
  onto the REPL's queue interacts with the approval path (`resolve-approval`)
  and the poller.
- The image-side `inspect-id` resolver is unbuilt (see P2).
- Multi-client coherence is still parked (one operator), per `notes/tui.md` §10.
- Security: both channels remain unauthenticated localhost; the docs already
  say to tunnel or add a token before going remote.

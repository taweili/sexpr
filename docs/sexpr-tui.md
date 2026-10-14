# sexpr-tui — Operation Manual

> Operation manual for the `./sexpr-tui.sh` launcher and the remote TUI client.
> For the design, see [`notes/tui.md`](../notes/tui.md); for the binary/chat
> surface, see [`docs/sexpr.md`](./sexpr.md).

The TUI is a separate process (`:sexpr-tui`, cl-tuition) that renders a
projection of a running sexpr image. It does not carry the kernel — the two
sides stay apart so the client never becomes a second agent society. The
client holds projections and object IDs, never live objects (R023).

`./sexpr-tui.sh` brings up both halves: it starts the image if needed, waits
for it, then runs the client.

---

## 1. Quick start

```sh
./sexpr-tui.sh                 # start the image if needed, then run the TUI
./sexpr-tui.sh --agent Alpha   # same, starting on Alpha
./sexpr-tui.sh --no-server     # attach only; fail if nothing is listening
./sexpr-tui.sh --server-only   # bring the image up and leave it running
./sexpr-tui.sh --dry-run       # show the boot file and the client command
```

Prerequisites: `sbcl` on `PATH`, a `~/.sbclinit` that loads Quicklisp, and the
project checked out (the wrapper adds its own directory to the ASDF registry).
No model endpoint is required to bring the image up — the default greeter
agent simply finishes as `:failed` without one.

---

## 2. The two channels

The TUI needs two channels, both owned by the image:

| Channel | Port | Purpose |
|---------|------|---------|
| **swank** | `4004` | request/response — eval + typed `sexpr.tui` RPCs |
| **push** | `4005` | one-way delta stream — transcript/status deltas |

"An image is running" means "the swank port accepts a connection." The
wrapper adopts what is already there and starts nothing if the image is up;
it tears down only an image it started itself — an image you started by hand
is left exactly as you left it. The push channel is optional at the client;
the wrapper asks for it only when it is actually listening.

---

## 3. The default agent

A fresh image is not an empty society. The boot file seeds one default agent
whose goal is `hello world` — it exists to greet whoever opens the TUI. The
client picks its default agent from the first snapshot row, so the greeter is
what you land on. It runs like any subagent (worker thread, handle,
transcript), streams its welcome over the push channel when the provider is
configured, and finishes as `:failed` without one — the image comes up either
way. The worker announces its status on the push channel as it starts and
finishes, so the agent pane's row tracks it live (RUNNING while a turn is in
flight, IDLE once the turn is done).

A chat note typed into a finished agent starts a fresh worker, so the note
gets a turn of its own instead of sitting unanswered in the transcript. The
greeter's transcript is seeded with the same `hello world` user line, because
the kernel sends the whole transcript to the model as messages and a
goal-only call carries no user message — providers whose chat template
requires one (llama-server's `--jinja`) refuse such a request. The image
also honors `SEXPR_PROVIDER` / `SEXPR_MODEL` / `SEXPR_BASE_URL`, exactly
like the CLI does, so the local-dev flow greets out of the box.

---

## 4. Flags

| Flag | Meaning |
|------|---------|
| `--host HOST` | image host (default `127.0.0.1`) |
| `--swank-port PORT` | swank port (default `4004`) |
| `--push-port PORT` | push channel port (default `4005`) |
| `--no-server` | attach only; fail if the image is not up |
| `--server-only` | start/reuse the image and wait for it |
| `--dry-run` | print what would be generated, launch nothing |
| `--help`, `-h` | this message |

Flags (`--host`, `--swank-port`, `--push-port`) win over the environment;
every other flag is forwarded to `sexpr-tui:main` verbatim (e.g. `--agent
NAME`).

### `--dry-run`

`--dry-run` prints the generated boot file at
`$SEXPR_TUI_STATE_DIR/server.lisp` and the client command, and launches
nothing. Use it to inspect what the image will load, or to debug a boot
failure without starting a process.

### `--no-server`

Attach to an image started by hand. The wrapper fails immediately if the
swank port is not accepting connections — it will not start an image for you.

### `--server-only`

Start (or reuse) the image and wait. With an externally-owned image, it waits
for the swank port to close; with one it started itself, it waits on the
process. `Ctrl-C` stops it; an image the wrapper started is torn down, an
externally-owned one is left as found.

---

## 5. Environment

Every knob is overridable, with no build step and no binary:

| Env var | Default | Purpose |
|---------|---------|---------|
| `SEXPR_TUI_HOST` | `127.0.0.1` | where the image listens |
| `SEXPR_TUI_SWANK_PORT` | `4004` | request/response channel |
| `SEXPR_TUI_PUSH_PORT` | `4005` | one-way delta channel |
| `SEXPR_TUI_STATE_DIR` | `/tmp/sexpr-tui` | boot file, log, pipe |
| `SEXPR_TUI_READY_TIMEOUT` | `120` | seconds to wait for the image |
| `SEXPR_TUI_SBCL` | `sbcl` | the SBCL binary |
| `SEXPR_TUI_SBCLINIT` | `~/.sbclinit` | loaded first, image and client |
| `SEXPR_PROVIDER` | `openai-compatible` | provider name |
| `SEXPR_BASE_URL` | `http://localhost:6969/v1` | provider base URL |
| `SEXPR_MODEL` | `Qwythos-9B-v2` | model name |

Examples:

```sh
SEXPR_TUI_SWANK_PORT=4100 ./sexpr-tui.sh --swank-port 4100
SEXPR_TUI_STATE_DIR=/tmp/my-session ./sexpr-tui.sh --server-only
SEXPR_PROVIDER=anthropic SEXPR_MODEL=claude-3-5-sonnet-latest \
  ANTHROPIC_API_KEY=sk-... ./sexpr-tui.sh
```

---

## 6. Layout

The frame is laid out from the terminal size, not from fixed pane dimensions.
`layout-dimensions` (in `src/tui-client/view.lisp`) derives every pane's
width and height from the window, so the frame comes out exactly as wide and
as tall as the screen at any size.

```
+-----------------------------------+------------------+
|                                   |  AGENT PANE      |
|   VIEWPORT (chat)                 |  ● agent A  idle  |
|   transcript of picked agent;     |  ● agent B  busy  |
|   textarea for input              |  ● agent C  wait  |
|                                   |  picked: agent B |
+-----------------------------------+------------------+
|   REPL (dev console)             |                  |
|   forms eval'd over Swank        |                  |
+-----------------------------------+------------------+
```

| Size | Chat viewport | REPL viewport | Agent pane |
|------|---------------|--------------|------------|
| 80x24 | 54 x 11 | 54 x 3 | 24 x 22 |
| 120x32 | 82 x 17 | 82 x 5 | 36 x 30 |
| 200x45 | 150 x 27 | 150 x 8 | 48 x 43 |
| 60x16 | 38 x 5 | 38 x 1 | 20 x 14 |

A resize event reflows every pane. The layout is total: a 0x0 or negative
window degrades to the smallest usable panes rather than signalling.

---

## 7. Input focus and keybindings

`Tab` moves key input between the chat and REPL inputs, and exactly one of
them owns the keys at a time — the other is explicitly blurred. A textarea
holding no text renders its placeholder without a cursor, so the focused
input's border is drawn in cyan (`*focus-color*`) as the visible cue.

| Key | Effect |
|-----|--------|
| `Tab` | move key focus between chat and REPL inputs |
| `Enter` | submit the focused input |
| `Ctrl+C` | quit |
| `Escape` | quit |
| `Ctrl+G` | grant an approval once (only while an approval is pending) |
| `Ctrl+D` | deny an approval (only while an approval is pending) |

The agent pane (right) lists every agent with status lights: green (idle),
red (busy), yellow (waiting for approval). Row click = focus — the chat pane
rebinds to that agent's transcript and the REPL binds `*agent*` to it.

---

## 8. Ownership and lifecycle

- **"Server running" means the swank port accepts a TCP connection.** The
  wrapper starts an image only when that fails, and tears down only an image
  it started itself — one the caller brought up by hand is left exactly as
  found.
- A push channel is picked up only when it is actually listening, so an image
  that came up without one still renders (no live deltas).
- The image comes up in its own SBCL, fed by a named pipe it holds open, and
  exits on EOF — so a crash never looks like a hang. `--disable-debugger`
  means a boot-time error kills the image rather than parking it in the
  debugger reading an empty FIFO.
- `cleanup` (the `EXIT` trap) tears down an image the wrapper started, closes
  the FIFO, and kills the client if it is still running (an interrupt on the
  wrapper shell does not reach the client unless they share a process group).
- No `SIGINT` trap: a non-interactive bash ignores `SIGINT` anyway, and the
  TUI reads `^C` as input while in raw mode (`ISIG` off). `SIGTERM`, `SIGHUP`,
  and `SIGKILL` reach the `EXIT` trap immediately.

---

## 9. Files written by the wrapper

All under `$SEXPR_TUI_STATE_DIR` (default `/tmp/sexpr-tui`):

| File | What it is |
|------|-----------|
| `server.lisp` | the generated boot file — **regenerated on every run**, so it can never point at a stale checkout |
| `server.log` | the image's stdout/stderr — that is where a failed boot explains itself |
| `server.pid` | the image's PID, while it is running |
| `server.stdin.fifo` | the named pipe the wrapper holds open to keep the image alive |

---

## 10. Make targets

| Target | Effect |
|--------|--------|
| `make sexpr-tui` | the same wrapper |
| `make verify-wrapper` | run the launcher checks without starting a single process |

---

## 11. Troubleshooting

- **Image will not come up** — read `$SEXPR_TUI_STATE_DIR/server.log`. The
  boot file it runs is `$SEXPR_TUI_STATE_DIR/server.lisp`, regenerated on
  every run, so edits to it do not survive. The last 25 lines are printed to
  stderr on failure.
- **Timed out waiting for the swank port** — the wrapper waited
  `SEXPR_TUI_READY_TIMEOUT` seconds (default 120). If the image crashed on
  boot the wrapper reports that case distinctly (`image exited before binding
  the port`) rather than burning the full timeout.
- **`sbcl not found`** — set `SEXPR_TUI_SBCL` to the SBCL binary.
- **`sbcl init not found`** — set `SEXPR_TUI_SBCLINIT` to a Quicklisp-loading
  init file.
- **`swank and push must use different ports`** — the two channels cannot
  share a port. Override with `--swank-port` / `--push-port` (or the env
  vars).
- **No live deltas / agent pane static** — the push channel is optional; the
  wrapper omits `--push-port` when the port is not listening, so the TUI
  falls back to polling `sexpr.tui:agent-snapshot` over swank. An image that
  came up without a push server still renders.
- **`--no-server` fails with "no image at..."** — drop `--no-server` and let
  the wrapper start one, or start an image by hand first.
- **First RPC of every session dies** — this was a known issue with Swank's
  `*pre-reply-hook*` sending an unsolicited `:new-features` packet the client
  could not parse; the generated boot file already strips it. If it recurs,
  confirm you are running a freshly-generated `server.lisp`.
- **Remote operation** — Swank has no auth by default; over localhost that is
  fine. For a society on a remote server, tunnel over SSH, and consider a
  shared-secret token on `sexpr.tui` calls the moment you go past localhost
  (see [`notes/tui.md`](../notes/tui.md) §7).

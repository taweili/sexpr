# sexpr examples

Small, self-contained Common Lisp examples that demonstrate sexpr's
core features. Each example loads sexpr via Quicklisp, exercises one
concept, and prints visible output.

## Prerequisites

- SBCL with Quicklisp (`~/.sbclinit` present)
- sexpr built and available in `local-projects` (see `docs/quickstart.md`)

## Run all examples

```sh
for f in examples/*.lisp; do sbcl --non-interactive --load "$f"; done
```

Or run one at a time:

```sh
sbcl --non-interactive --load examples/01-transcript.lisp
```

## Examples

| File | Demonstrates | Model needed? |
|------|-------------|---------------|
| `01-transcript.lisp` | Events, append, render, serialize/deserialize | No |
| `02-tools.lisp` | Tool registry, schema derivation, custom tools | No |
| `03-sandbox.lisp` | Restricted read eval, refusal taxonomy | No |
| `04-builtins.lisp` | Five built-in tools in action | No |
| `05-agent-loop.lisp` | Agent loop with a mock provider | No (mock) |
| `06-capabilities.lisp` | Capability gate: grants and denials | No |
| `07-hot-redefinition.lisp` | Live image: code persists across turns | No |
| `08-subagent-sbcl.lisp` | Multi-agent: spawn, collect, tree from SBCL | No (mock) |
| `09-subagent-chat.lisp` | Multi-agent: tool dispatch through the chat loop | No (mock) |

## Using a real model

Examples 05, 08, and 09 use mock providers by default. To use a real model,
set the environment variables and remove the mock:

```sh
export SEXPR_PROVIDER="openai-compatible"
export SEXPR_BASE_URL="http://localhost:6969/v1"
export SEXPR_MODEL="Qwythos-9B-v2"
```

Then modify the example to use the real provider instead of the mock.

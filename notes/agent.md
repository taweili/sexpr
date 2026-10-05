# AI Agent Harness Architecture — Research Notes

Research date: 2026 (sources from 2025–2026).

## 1. What is an "agent harness"?

**Agent = Model + Harness.** The harness is everything around the model that turns it into a work engine: all code, configuration, and execution logic that isn't the model itself.

A harness provides:

- **The agent loop** — drives repeated model + tool calls until the task completes.
- **Tool dispatch** — schemas exposed to the model; the harness executes `tool_use` → `tool_result`.
- **Context/conversation state management** — the transcript is the only real state.
- **Permissions / approval policies** — gating dangerous tool calls.
- **Sandboxing** — isolated execution (VMs, containers, permission rules).
- **Prompt/system-prompt assembly** — instructions, environment info, tool descriptions.
- **Subagent orchestration**, **hooks**, **memory**, **session persistence/resume**.

References:
- LangChain, "The Anatomy of an Agent Harness" — https://www.langchain.com/blog/the-anatomy-of-an-agent-harness
- Anthropic, "Effective harnesses for long-running agents" — https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- Martin Fowler, "Harness engineering for coding agent users" — https://martinfowler.com/articles/harness-engineering.html
- Microsoft Agent Framework harness concept — https://learn.microsoft.com/en-us/agent-framework/concepts/harness

## 2. The agent loop

The core of every harness is a simple while-loop:

```
state = [system_prompt, user_task]
loop:
    response = model(state, tools)
    if response has tool calls:
        results = execute each tool call (with permission checks, sandboxing)
        append response + tool_results to state
    else:
        return response   # model signaled completion
```

Key design points from practice:

- **The transcript is the only state.** Everything the model knows is in the message list. Durability = persisting the transcript; resume = reloading it.
- **Termination conditions**: max steps, max tokens/cost, wall-clock, explicit "done" tool, or the model stopping without tool calls.
- **Parallel tool calls**: modern harnesses batch independent `tool_use` blocks in one turn.
- **Streaming**: responses and tool results are streamed for UX; hooks fire on lifecycle events (pre/post tool use, user prompt submit, compaction).
- **Interruption & steering**: users can interject mid-loop; harnesses support queues of user messages and aborts.
- **Error handling**: tool errors are fed back as `tool_result` content so the model can self-correct — this is the primary recovery mechanism.
- Long-running work is split into **sessions**: e.g. Anthropic's Claude Agent SDK pattern — an *initializer agent* sets up the environment on first run; a *coding agent* makes incremental progress each session and leaves structured artifacts (progress files, git commits, feature lists) for the next session, mimicking "engineers working in shifts".

Reference: "The Agent Harness", AI Engineering Playbook — https://karthikreddy-7.github.io/ai-engineering-playbook/docs/05-agents/agent-harness/

## 3. Prompting: system prompt assembly

The system prompt is assembled from layered sources:

1. **Base harness prompt** — role, behavioral rules, tool usage conventions, output style.
2. **Environment context** — cwd, OS, date, git status, available tools, runtime versions (often injected as "system reminders" or a context block).
3. **Project instructions** — repo-level memory files (`CLAUDE.md`, `AGENTS.md`, `.cursor/rules/`) auto-loaded at startup; can be hierarchical (root → subdirectory overrides).
4. **Tool & skill descriptions** — schemas + descriptions; skills load metadata only (see §6).
5. **User/session-specific memory** — preferences, learned facts, previous-session summaries.

Prompt-engineering guidance has largely converged into **context engineering** (§4): prompts are just one input alongside retrieved knowledge, memory, and tool outputs.

## 4. Context management ("context engineering")

Context is a **critical but finite resource**; performance degrades ("context rot") as the window fills. Context engineering = curating the *smallest set of high-signal tokens* that maximize the chance of the desired outcome. LangChain groups strategies into four: **write, select, compress, isolate**.

### 4.1 Write (persist outside the window)
- Scratchpads / note files (agent writes plans, progress, decisions to disk and reads them back later).
- Long-term memory systems (user prefs, project facts) stored outside the transcript and injected selectively.
- Artifacts over recall: commit messages, PROGRESS.md, feature lists — Anthropic's long-running agent harness leans on this for cross-session memory.

### 4.2 Select (retrieve only what's needed)
- RAG over code/docs (embedding search, grep-like tools) instead of reading whole files.
- **Just-in-time context**: tools return data at call time rather than preloading everything.
- Progressive disclosure for skills/tools metadata (see §6).

### 4.3 Compress (keep the window small)
- **Compaction / summarization**: when the transcript nears the limit, older turns are summarized (Claude Code does this automatically); recent turns stay verbatim.
- Tool-result truncation/pruning: old file reads and command outputs are the first to be elided; clearing tool outputs is often higher-value than summarizing messages.
- Deterministic trimming rules + LLM summarization for semantic content.

### 4.4 Isolate (split context across agents)
- **Subagents**: side tasks (log analysis, broad searches, exploration) run in their own context window and return only a summary — protects the main thread's window from noise.
- Multi-agent architectures: orchestrator + specialized workers; Google ADK's "context stack" separates durable state from per-agent presentation.
- Quirks: subagents add coordination cost; use when the work is parallelizable or context-heavy.

References:
- Anthropic, "Effective context engineering for AI agents" — https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- LangChain, "Context Engineering for Agents" — https://www.langchain.com/blog/context-engineering-for-agents
- Claude Code best practices — https://code.claude.com/docs/en/best-practices.md
- Google ADK context architecture — https://developers.googleblog.com/architecting-efficient-context-aware-multi-agent-framework-for-production/

## 5. Tools, permissions, sandboxing

- Tools are defined by **name + description + JSON schema**; the model emits `tool_use`, the harness validates, checks permissions, executes, and returns `tool_result`.
- **Permission modes**: allowlist/denylist rules, per-tool approval prompts, sandbox profiles (e.g. network-less, read-only fs, restricted bash).
- **Hooks**: user-defined shell callbacks on lifecycle events — policy enforcement, logging, auto-formatting after edits, injecting extra context on prompt submit.
- Coding-agent tool sets are deliberately small and composable (read/write/edit/bash/glob/grep) — general primitives beat many narrow tools.

## 6. Skills

**Agent Skills** (Anthropic's open format, adopted across tools) are *organized folders of expertise* an agent discovers and loads dynamically:

```
my-skill/
  SKILL.md          # frontmatter: name, description, (allowed-tools, model...) + instructions
  scripts/          # executable helpers the agent can run
  references/       # docs loaded on demand
  assets/           # templates, examples
```

Key architectural idea — **progressive disclosure**:

1. At startup, only **metadata (name + description)** of all skills is in context (~tens of tokens each).
2. When a task matches a skill's description, the agent loads `SKILL.md` (a few hundred tokens).
3. SKILL.md points to additional files, loaded only as needed — effectively unbounded knowledge with near-zero upfront cost.

Design implications:

- The **description field is the trigger surface** — writing good trigger descriptions (what it does + when to use it) determines reliability.
- Skills can include **scripts** the agent executes rather than re-deriving logic (deterministic, token-free).
- `allowed-tools` metadata can pre-approve/limit tools a skill uses.
- In Claude Code, custom slash commands merged into skills (`.claude/commands/x.md` ≡ `.claude/skills/x/SKILL.md`).
- Skills complement MCP: **MCP connects the agent to external systems (tools/data); skills teach the agent procedures and domain expertise (know-how).**

References:
- Anthropic, "Equipping agents for the real world with Agent Skills" — https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills
- Agent Skills docs & best practices — https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview
- Claude Code skills docs — https://code.claude.com/docs/en/skills.md

## 7. MCP (Model Context Protocol)

Open standard (Anthropic, Nov 2024, now broadly adopted incl. OpenAI/Google ecosystems) for connecting agents to external data sources and tools — "USB-C for AI integrations".

### Architecture (client–host–server, JSON-RPC 2.0)

- **Host** — the AI app (Claude Code, IDEs, chat apps); container and coordinator, manages multiple clients, enforces security boundaries.
- **Client** — one per server connection; maintains the stateful session, handles capability negotiation.
- **Server** — exposes primitives:
  - **Tools** — model-controlled functions (query DB, call API). Unique name + schema; discovered and invoked by the model.
  - **Resources** — application-controlled data (files, records) exposed by URI.
  - **Prompts** — user-controlled reusable prompt templates.
- Transports: **stdio** (local servers as subprocesses) and **HTTP/SSE (streamable HTTP)** for remote servers; auth via OAuth for remote.

### In the harness

- On startup the harness connects to configured MCP servers, negotiates capabilities, and merges their tool schemas into the model's tool list (names often prefixed per-server).
- Tool calls are routed by the harness to the right server; results flow back as `tool_result`.
- **Context cost caveat**: every connected server's tool schemas occupy system-prompt tokens; large MCP setups hurt performance — curate servers, prefer progressive-disclosure patterns (e.g. "code mode": expose few meta-tools, let the agent write code against MCP APIs, or CLI wrappers discovered on demand).

References:
- MCP spec architecture (2025-06-18) — https://modelcontextprotocol.io/specification/2025-06-18/architecture
- MCP tools spec — https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- Anthropic announcement — https://www.anthropic.com/news/model-context-protocol

## 8. Putting it together: a modern harness checklist

| Layer | Modern practice |
|---|---|
| Loop | Simple tool-use while-loop; transcript as only state; streaming; abort/steer support |
| System prompt | Layered: base + environment + project memory files (AGENTS.md/CLAUDE.md) + tool/skill metadata |
| Context | JIT retrieval, tool-result pruning, auto-compaction, notes-to-disk, subagent isolation |
| Tools | Small primitive set + MCP servers for external systems; schema-validated, permission-gated |
| Extensibility | Skills (SKILL.md + files, progressive disclosure) for domain know-how; hooks for policy |
| Long-running | Session-based with artifacts (progress files, commits); initializer + incremental-worker pattern |
| Safety | Sandboxing, approval policies, least-privilege tools, allowlists |

## 9. Source list

1. Anthropic — Effective harnesses for long-running agents: https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
2. Anthropic — Effective context engineering for AI agents: https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
3. Anthropic — Equipping agents for the real world with Agent Skills: https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills
4. LangChain — The Anatomy of an Agent Harness: https://www.langchain.com/blog/the-anatomy-of-an-agent-harness
5. LangChain — Context Engineering for Agents: https://www.langchain.com/blog/context-engineering-for-agents
6. Martin Fowler — Harness engineering for coding agent users: https://martinfowler.com/articles/harness-engineering.html
7. Microsoft Agent Framework — Harness concepts: https://learn.microsoft.com/en-us/agent-framework/concepts/harness
8. Claude Code — Best practices: https://code.claude.com/docs/en/best-practices.md ; Glossary: https://code.claude.com/docs/en/glossary ; Subagents & Skills docs
9. MCP specification — architecture & tools: https://modelcontextprotocol.io/specification/2025-06-18/architecture
10. Anthropic — Introducing the Model Context Protocol: https://www.anthropic.com/news/model-context-protocol
11. Google — ADK context-aware multi-agent architecture: https://developers.googleblog.com/architecting-efficient-context-aware-multi-agent-framework-for-production/
12. AI Engineering Playbook — The Agent Harness: https://karthikreddy-7.github.io/ai-engineering-playbook/docs/05-agents/agent-harness/
13. Redis — Context engineering best practices: https://redis.io/blog/context-engineering-best-practices-for-an-emerging-discipline/

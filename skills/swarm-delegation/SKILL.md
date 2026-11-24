---
name: swarm-delegation
description: Native Antigravity 4-subagent delegation playbook (scout, builder, bulk, checker) with MECE thresholds, 3-round fresh Argon QA, workspace hygiene, and token-saving defaults.
---

# Antigravity Native Swarm Delegation Playbook

This skill defines the operational playbook for delegating work across Antigravity's 4 native roles (`scout`, `builder`, `bulk`, `checker`) using built-in Antigravity models only rather than external proxy routers.

> **Hooks Note:** Antigravity `hooks.json` is intentionally **not** used for delegation enforcement because `stdin` hook payloads lack reliable caller-role attribution (`Manager` vs `scout`/`builder`/`checker`). Enforcement relies on the MECE thresholds below and `EnableWriteTools: false` isolation on `scout`.

---

## 1. MECE Fast-Path vs. Swarm-Path Decision Table

| Criterion | **Fast-Path** (Execute Directly — **ALL** must hold) | **Swarm-Path** (Delegate — **ANY** triggers) |
|---|---|---|
| **Files** | `1–2` tightly coupled files | `>= 3` files, or `2` decoupled modules |
| **Change Size** | `<= 50` LOC changed | `> 50` LOC changed |
| **Tool Steps** | `<= 4` expected tool steps | `>= 5` expected tool steps |
| **Manager Context** | `< 95K` input tokens | `>= 95K` input tokens (Context Breaker) |
| **Action** | Execute directly; skip `swarm` and `checker`; run deterministic test directly | Delegate to `builder`/`bulk`, run deterministic checks, then up to 3 rounds of `checker-rN` |

---

## 2. Triage Announcement Protocol (`DELEGATION:` Header & F15 Honesty)

In Antigravity sessions, this 6-role header supersedes legacy `AGENTS.md` `DELEGATION: gemini | inline` syntax.

**Canonical Format** (line 1 of actionable tool-using turns and phase-transition turns; **no model names**):
```text
DELEGATION: manager|scout|builder|bulk|checker|browser — <1-line justification>
```

| Role | Matching Same-Turn Tool Call (F15 Invariant) | Justification Requirement |
|---|---|---|
| `manager` | Inline Fast-Path tools (no subagent dispatch) | **MUST** cite Fast-Path metrics (`<=2 files, <=50 LOC, <=4 steps`) |
| `scout` | `invoke_subagent(TypeName="research"\|"scout", ...)` | Read-only discovery / log analysis / reads `> 150` lines |
| `builder` | `swarm(action="add", name="builder", ...)` | Single-writer implementation (`workspace="inherit"`) |
| `bulk` | `swarm(action="add", name="bulk", ...)` | Repetitive / parallel mechanical work |
| `checker` | `swarm(action="add", name="checker-rN", ...)` | Independent Argon QA audit (`[QA_ROUND: N/3]`) |
| `browser` | `invoke_subagent(TypeName="browser", ...)` | Live web UI / browser interaction |

**Valid Examples:**
- `DELEGATION: manager — Fast-Path (0 files, 1 read-only step): probe localhost:9222.`
- `DELEGATION: manager — Fast-Path (1 file, ~15 LOC, 2 steps): update config flag.`
- `DELEGATION: scout — read delegation policy files (>150 lines) and extract role table.`
- `DELEGATION: builder — implement 4-file refactor (>50 LOC) and run unit tests.`
- `DELEGATION: checker — [QA_ROUND: 1/3] independent blind audit of git diff HEAD.`
- `DELEGATION: browser — inspect live dashboard UI on localhost:3000.`

**Anti-Patterns (Forbidden):**
- Model names in the header (e.g., `DELEGATION: builder (hydrogen) — ...`).
- Missing Fast-Path metrics on `manager` (e.g., `DELEGATION: manager — quick fix`).
- Phantom triage (F15 violation): announcing `scout`/`builder`/`bulk`/`checker`/`browser` without dispatching the matching tool in that exact same turn.
- Double waiting lines: emitting `DELEGATION: scout — ...` AND a second waiting sentence before stopping.

**Exemptions & Wakeup Rule:**
- **Exempt:** Pure text Q&A / greetings / clarification turns (0 tool calls), swarm worker internal turns (workers NEVER emit `DELEGATION:`), and post-worker final synthesis turns with no new dispatch.
- **Post-Wakeup:** When an async worker/browser returns via `<SYSTEM_MESSAGE>`, do NOT re-announce `DELEGATION: manager` just to read results and reply; only emit a new `DELEGATION: <role>` if immediately dispatching the next delegated worker.

---

## 3. Exact Tool Invocation Patterns

### `scout` (Read-Only Discovery / Log Analysis)
Prefer MCP code-graph/symbol tools when installed, else use `scout` for discovery. For unknown files or reads `> 150` lines, invoke `scout` (async subagent):
```text
invoke_subagent(TypeName="research", Model="flash", Prompt="...")
```
Or if defining a custom read-only scout:
```text
define_subagent(Name="scout", EnableWriteTools=false, EnableMCPTools=true, EnableSubagentTools=false)
invoke_subagent(TypeName="scout", Model="flash", Prompt="...")
```

### `builder` (Single-Writer Implementation)
```text
swarm(action="add", name="builder", model="gemini-4-hydrogen-medium", workspace="inherit", brief="...")
```

### `bulk` (Repetitive / Parallel Mechanical Tasks)
```text
swarm(action="add", name="bulk", model="gemini-3.8-flash-medium", workspace="inherit", brief="...")
```
*(For disjoint parallel writers using `tasks=[...]` or `n>1`, pass `workspace="share"`.)*

### `checker-rN` (Independent Read-Only QA on Argon Pool)
```text
swarm(action="add", name="checker-r1", model="gemini-4-argon-medium", workspace="inherit", brief="...")
```

---

## 4. Workspace Safety & Lifecycle Hygiene

1. **Workspace Mode**:
   - Single writer (`builder` or `bulk`): ALWAYS use `workspace="inherit"` so `kill` never discards edits.
   - Disjoint parallel writers: Use `workspace="share"`, and **merge/verify all changes into the main workspace BEFORE calling `swarm(action="kill")`**, because `kill` permanently deletes `share` and `branch` workspaces.
2. **Async Wait Discipline**:
   - `swarm(action="add")` and `invoke_subagent` are asynchronous. After dispatching, emit ONLY the single `DELEGATION: <role> — <short waiting status>` line (plus the mandatory `open_board` link on its own line when `swarm(action="add")` requires it) and stop calling tools to wait for the reactive wakeup. Never poll `read_board` in a loop.
3. **Mandatory Cleanup**:
   - Always `swarm(action="kill", name="...")` finished workers immediately after integrating their result or receiving their QA verdict.
   - Before delivering your final reply to the user, run `swarm(action="status")` and verify **zero** active/unclosed workers (`working`, `waiting`, or `stopped`).
4. **No Recursive Spawning**:
   - Every `swarm` brief MUST end with: `CRITICAL: Do NOT call swarm(action='add') or spawn subagents.`

---

## 5. Deterministic-Tests-First Gate & 3-Round Fresh Checker Protocol

1. **Deterministic Gate First**: Run `lint`, `tsc`, and unit tests *before* spawning `checker-r1`. Failing deterministic checks return straight to `builder` without burning Argon QA quota.
2. **Blind Audit Contract**:
   - If new untracked files were created, run `git add -N <paths>` first (or list exact file paths for `checker` to read directly).
   - Pass ONLY: user requirements, exact changed file paths, `git diff HEAD` scope, and deterministic test output. Zero Manager rationalizations.
   - **NO nested `checker -> scout`**: `checker` inspects diffs and targeted line ranges directly on its separate `Gemini 4 Argon` pool.
3. **Round Loop (`[QA_ROUND: 1/3..3/3]`)**:
   - Spawn fresh `checker-r1` (`gemini-4-argon-medium`).
   - `kill` `checker-r1` immediately upon receiving `QA VERDICT: PASS | FAIL`.
   - On `FAIL` with `Round < 3`: pass `[FILE:LINE]` defects to `builder` -> fix & `kill` `builder` -> re-run deterministic checks -> spawn **fresh** `checker-r(N+1)`.
   - On **Round 3 `FAIL`**: **HARD STOP**. `kill` all active workers and output the Escalation Report below. Round 4 requires explicit user authorization.

### Escalation Report Format (Round 3 `FAIL`)
```markdown
## QA Hard Stop — Escalation Required ([QA_ROUND: 3/3] FAIL)
- **Blocker Summary:** <1-2 sentence root cause>
- **Open Defects (`[FILE:LINE]`):**
  - `path/to/file:123` — <exact defect>
- **Deterministic Checks:** <pass/fail command + exit code>
- **Next Step:** Awaiting user authorization for Round 4 or manual override.
```

---

## 6. Compact Brief Templates

### `builder` Brief Template
```text
Own: <exact target files/symbols>. Do NOT touch: <excluded files>.
Task: <concise requirements + acceptance criteria>.
Verification: Run <exact test/lint command> and report exit code + pass/fail counts.
Output: <= 15 lines summary, zero pasted code blocks. Post `@coordinator [done]` when finished.
CRITICAL: Do NOT call swarm(action='add') or spawn subagents.
```

### `checker-rN` Brief Template
```text
[QA_ROUND: N/3] Blind QA Audit (read-only; do NOT modify files).
Requirements: <user acceptance criteria>.
Scope: Changed files [<paths>]. Inspect `git diff HEAD` (and listed paths directly).
Deterministic Test Output: <command + exact result>.
Verdict Format: Start with `QA VERDICT: PASS` or `QA VERDICT: FAIL`. List any defects as `[FILE:LINE] <issue>`. <= 15 lines. Post `@coordinator [done]` when finished.
CRITICAL: Do NOT call swarm(action='add') or spawn subagents.
```

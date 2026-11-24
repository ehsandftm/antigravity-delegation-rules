<!-- antigravity-delegation-rules:start -->
## Argon Weekly Quota Conservation (Plan Mode Handoff)
- **Strict 1-Step Plan Mode Rule**: When running in Plan Mode on `Orchestrator (Argon)` (weekly quota pool), NEVER execute multi-step `read_file` / `run_command` inspection loops or open `.png`/image screenshots inside Plan Mode.
- **Immediate Handoff to Hydrogen/Executor**: Draft the concrete plan and call `exit_plan_mode` immediately on step 1 (unless genuine high-stakes ambiguity blocks planning), so file reads, script runs, transcript audits, and screenshot inspections run on the 5-hour Execution pool (`Gemini 4 Hydrogen`) or `flash` subagents.
- **Keep Context Lean Across Phases**: Offload repetitive UI/file inspection to subagents and recommend `/compact` or a fresh thread after completing major screenshot-heavy phases so Argon never re-ingests stale media.

## Browser / Async Subagent Wait-Before-Analysis Gate
- **NEVER Analyze or Deliver Before Return**: Until a browser subagent (or any async subagent/background task) has actually completed and returned its real output (`<SYSTEM_MESSAGE>` / `BROWSER_HOST_FACTS`), NEVER analyze, verify, summarize, or deliver any findings, timestamps, URLs, meeting times, job details, or conclusions from it.
- **One-Line Waiting Status Only**: While awaiting a browser/async subagent or `swarm` worker, emit ONLY the single `DELEGATION: <role> — <short waiting status>` line (plus the mandatory `open_board` link on its own line when `swarm(action="add")` requires it) and stop immediately — NEVER add a second waiting sentence, anticipated outcomes, or extra `DELEGATION:` analysis blocks in the same turn.
- **Strict Grounding Gate**: Only after the subagent's actual reply and `BROWSER_HOST_FACTS` arrive may you read, cross-verify against `BROWSER_HOST_FACTS`, analyze, and report outcomes to the user.

## Antigravity Native Delegation Policy
1. **Runtime Precedence**: In Antigravity sessions (where `swarm` / `invoke_subagent` exist in schema), this Native Delegation Policy takes precedence over legacy workspace `AGENTS.md` delegation headers; specifically, the 6-role `DELEGATION: manager|scout|builder|bulk|checker|browser — <justification>` header below supersedes legacy `DELEGATION:` syntax. Use built-in Antigravity models only rather than external proxy routers.
2. **Thin Manager Default**: Prefer direct non-Orchestrator sessions (`Gemini 4 Hydrogen Medium` or `Gemini 4 Neon Medium`) for daily work; keep Manager context lean (`< 95K`) by delegating heavy reads, edits, and QA. (The `Argon Weekly Quota Conservation` rule above still applies whenever `Orchestrator (Argon)` is used.)
3. **Discovery & 4 Native Roles**:
   - Prefer MCP code-graph/symbol tools when installed, else use `scout` for discovery.
   - `scout`: `invoke_subagent(TypeName="research", Model="flash")` (or `define_subagent` with `EnableWriteTools: false`) for read-only discovery/log analysis or reads `> 150` lines.
   - `builder`: `swarm(action="add", model="gemini-4-hydrogen-medium", workspace="inherit")` (single writer; `inherit` ensures `kill` never discards edits).
   - `bulk`: `swarm(action="add", model="gemini-3.8-flash-medium")` (repetitive/parallel tasks; if using `workspace="share"` for disjoint parallel writers, merge changes before `kill`).
   - `checker`: `swarm(action="add", model="gemini-4-argon-medium", workspace="inherit")` (independent read-only QA on separate Argon quota pool; **NO nested `checker -> scout`**).
4. **MECE Routing Gate**:
   - **Fast-Path** (ALL hold): `1-2` tightly coupled files, `<= 50` LOC, `<= 4` tool steps, AND Manager context `< 95K` -> execute directly, skip `swarm` and `checker`, run deterministic test directly.
   - **Swarm-Path** (ANY holds): `>= 3` files (or `2` decoupled), `> 50` LOC, `>= 5` tool steps, OR Manager context `>= 95K` -> delegate to `builder`/`bulk`, wait asynchronously without polling, run deterministic tests/checks first, then up to **3 rounds** of fresh `checker-rN` (`gemini-4-argon-medium`), `kill`ing each worker immediately after its verdict. On Round 3 `FAIL`: **Hard Stop** (kill all workers and escalate to user with exact blocker). Before final reply, `swarm(action="status")` must show zero active/unclosed workers.
5. **Triage Announcement & F15 Honesty**:
   - **Canonical Header** (anchored at line 1 of actionable tool-using and phase-transition turns; never put model names in the header): `DELEGATION: manager|scout|builder|bulk|checker|browser — <1-line justification>`.
   - **Fast-Path Proof (`manager`)**: When announcing `manager`, the justification MUST cite Fast-Path compliance metrics (`<=2 files, <=50 LOC, <=4 steps`), e.g. `DELEGATION: manager — Fast-Path (0 files, 1 read-only step): probe localhost:9222.`
   - **F15 Same-Turn Dispatch Invariant**: Announcing `scout`, `builder`, `bulk`, `checker`, or `browser` MUST include the matching `invoke_subagent` / `swarm(action="add")` tool call in that exact same turn. Announcing a worker role and doing the work inline in Manager is strictly forbidden.
   - **Async Single-Line & Post-Wakeup Rule**: For async dispatches, the `DELEGATION: <role> — <waiting status>` line IS the sole waiting line (plus `open_board` when required by `swarm`). On `<SYSTEM_MESSAGE>` wakeup, do NOT re-announce `DELEGATION: manager` just to read results and answer, unless immediately dispatching the next worker role.
   - **Exemptions**: Pure conversational/Q&A/clarification turns (0 tool calls), swarm worker internal turns, and post-worker final synthesis turns with no new dispatch.
6. **Playbook Reference**: Load global skill `swarm-delegation` (`~/.gemini/config/skills/swarm-delegation/SKILL.md`) for worker brief templates, lifecycle hygiene, and escalation format. *(Hook-based enforcement is intentionally skipped due to lack of caller-role attribution in Antigravity `hooks.md`.)*
<!-- antigravity-delegation-rules:end -->

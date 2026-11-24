---
name: swarm-delegation
description: Native Antigravity 4-subagent delegation playbook (scout, builder, bulk, checker) with MECE thresholds, unified-quota risk/round tiering, structured scout output, and lifecycle hygiene.
---

# Antigravity Native Swarm Delegation Playbook

Operational playbook for delegating work across Antigravity's native roles (`scout`, `builder`, `bulk`, `checker`) using built-in Antigravity models under a **unified shared weighted quota pool**.

> **Audit Skill:** For Swarm-Path QA audits, non-mutating `diff_sha256`, MVD Comment Sheets, and `HUMAN_REQUIRED` escalation, load `swarm-audit` (`~/.gemini/config/skills/swarm-audit/SKILL.md`).

---

## 1. MECE Fast-Path vs. Swarm-Path Decision Table

| Criterion | **Fast-Path** (Execute Directly — **ALL** hold) | **Swarm-Path** (Delegate — **ANY** triggers) |
|---|---|---|
| **Files** | `1–2` tightly coupled files | `>= 3` files, or `2` decoupled modules |
| **Change Size** | `<= 50` LOC changed (max 2 consecutive turns on same files per `F2`) | `> 50` LOC changed |
| **Tool Steps** | `<= 4` expected tool steps | `>= 5` expected tool steps |
| **Manager Context** | `< 95K` input tokens | `>= 95K` input tokens (Context Breaker) |
| **Action** | Execute directly; skip `swarm`/`checker`; run deterministic test | Delegate to `builder`/`bulk`, run deterministic checks, then `swarm-audit` (`R1..R3`) |

---

## 2. Unified Quota Model Routing, Risk Tiers & F17 Plan Audit

All Antigravity models share one weighted quota pool. Route by risk tier and asymmetric round tiering:

- **Risk Tiers:**
  - **T0** (Docs/comments only, tests green): No checker; Manager self-attests.
  - **T1** (Fast-Path, no risk paths): Optional 1x `R1` on cheap/mid tier; `R2–R3` only if `R1` fails.
  - **T2** (Swarm-Path OR risk paths: auth, deletion, migrations, install scripts, hooks, CI, secrets): Full 3-round `swarm-audit` protocol.
- **Asymmetric Round Tiering:**
  - `scout` / `bulk`: Flash-class (`gemini-3.8-flash-medium` / `flash`).
  - `builder`: Mid-tier (`gemini-4-hydrogen-medium`).
  - `checker-r1`: Strongest available (ideally different model family from `builder`, e.g., `gemini-4-argon-medium`).
  - `checker-r2`: Mid-tier (delta only).
  - `checker-r3`: Cheapest verifier (binary closure).
- **F17 Plan Audit (Optional):** For architectural plans/migrations touching `>= 5` files or destructive schema/config changes, run 1-round `checker-plan` (`[[AGY-ROLE:checker-plan round=1]]`) on the plan artifact before dispatching `builder`.

---

## 3. Triage Announcement Protocol (`DELEGATION:` Header & F15 Honesty)

Line 1 of actionable tool-using and phase-transition turns (**no model names**):
```text
DELEGATION: manager|scout|builder|bulk|checker|browser — <1-line justification>
```
- `manager`: Inline Fast-Path tools; **MUST** cite metrics (`<=2 files, <=50 LOC, <=4 steps`).
- `scout`: Same-turn `invoke_subagent(TypeName="research", Model="flash", ...)` for discovery / reads `> 150` lines.
- `builder`: Same-turn `swarm(action="add", name="builder", workspace="inherit", ...)`.
- `bulk`: Same-turn `swarm(action="add", name="bulk", ...)`.
- `checker`: Same-turn `swarm(action="add", name="checker-rN", workspace="inherit", ...)`.
- `browser`: Same-turn `invoke_subagent(TypeName="browser", ...)`.

**Exemptions & Wakeup:** Pure 0-tool Q&A/clarification turns, worker internal turns, and final synthesis with no new dispatch are exempt. On `<SYSTEM_MESSAGE>` wakeup, do NOT re-announce `DELEGATION: manager` just to read results and reply.

---

## 4. Workspace Safety, Concurrency & Quota Hygiene

1. **Workspace Mode:** Single writer (`builder` or `bulk`) ALWAYS uses `workspace="inherit"`. Disjoint parallel writers (`tasks=[...]` or `n>1`) use `workspace="share"`, and must be merged/verified before `swarm(action="kill")`.
2. **Concurrency & Quota Hard Stop:** Keep `<= 3` active workers. On **Quota/Rate-Limit**, trigger **Hard Stop**: `kill` workers, write a compact resume note, never retry-storm.
3. **Async Wait & Cleanup:** After dispatch, emit ONLY the single `DELEGATION:` waiting line (plus `open_board` when `swarm` requires it) and stop calling tools. Never poll `read_board`. `kill` finished workers immediately; verify `swarm(action="status")` shows 0 active workers before final reply.
4. **No Recursive Spawning & NO `checker -> scout`:** Every `swarm` brief MUST end with `CRITICAL: Do NOT call swarm(action='add') or spawn subagents.`

---

## 5. Epistemic Answer Discipline

- Quantify rejected alternatives alongside recommended ones.
- Explicitly label `CALCULATED` vs `MEASURED` values.
- Distinguish disk reads from live process state.
- Never embed the premise under test into `checker` or `scout` briefs.

---

## 6. Worker Sentinel & Brief Templates

Prefix every swarm worker brief with `[[AGY-ROLE:<role> round=<N>]]` (`round=0` initial `scout`/`bulk`/`builder`; `round=1..3` audit/fix cycles; `round=1` `checker-plan`).

### `scout` Brief Template
```text
[[AGY-ROLE:scout round=0]]
Search/Read: <exact files, symbols, or logs>. Read-only; do NOT modify files.
Return ONLY:
STATUS: OK | NOT_FOUND | TRUNCATED
ANSWER: <concise factual answer>
EVIDENCE: "<= 120-char verbatim quote>"
LOCATION: <path:StartLine-EndLine>
```

### `builder` Brief Template
```text
[[AGY-ROLE:builder round=0]]
Own: <exact target files/symbols>. Do NOT touch: <excluded files>.
Task: <concise requirements + acceptance criteria>. Mask any secrets as [REDACTED_LITERAL].
Verification: Run <exact test/lint command> and report exit code + exact pass/fail counts.
Output: <= 15 lines summary, zero pasted code blocks. Post `@coordinator [done]` when finished.
CRITICAL: Do NOT call swarm(action='add') or spawn subagents.
```

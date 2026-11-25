---
name: swarm-delegation
description: Native Antigravity 4-subagent delegation playbook (scout, builder, bulk, checker) with MECE thresholds, family-quota risk/dual-slot round tiering, structured scout output, and lifecycle hygiene.
---

# Antigravity Native Swarm Delegation Playbook

Operational playbook for delegating work across Antigravity's native roles (`scout`, `builder`, `bulk`, `checker`) using built-in Antigravity models under **weighted family quota pools (Gemini pool vs Claude pool)**.

> **Audit Skill:** For Swarm-Path QA audits, checker isolation, consensus, `diff_sha256`, MVD Comment Sheets, `checker-rN-{a|b}` brief template, and `HUMAN_REQUIRED` escalation, load `swarm-audit` (`~/.gemini/config/skills/swarm-audit/SKILL.md`).

---

## 1. MECE Fast-Path vs. Swarm-Path Decision Table

| Criterion | **Fast-Path** (Execute Directly — **ALL** hold) | **Swarm-Path** (Delegate — **ANY** triggers) |
|---|---|---|
| **Files** | `1–2` tightly coupled files | `>= 3` files, or `2` decoupled modules |
| **Change Size** | `<= 50` LOC changed (max 2 consecutive turns on same files per `F2`) | `> 50` LOC changed |
| **Tool Steps** | `<= 4` expected tool steps | `>= 5` expected tool steps |
| **Manager Context** | `< 95K` input tokens | `>= 95K` input tokens (Context Breaker) |
| **Risk Path** | No `T2` risk paths (`T0` docs-only skips checker) | OR `T2` risk path (`auth`/`deletion`/`migrations`/`install`/`hooks`/`CI`/`secrets`) |
| **Action** | Execute directly; skip `swarm`/`checker`; run deterministic test | Delegate to `builder`/`bulk`, run deterministic checks, then `swarm-audit` (`R1..R3`) |

---

## 2. Family Quota Routing, Risk Tiers & Checker Round Tiering

Models use **weighted family quota pools (Gemini pool vs Claude pool)**.
- **Core Roles:** `scout`/`bulk` = Flash (`gemini-3.8-flash-medium`/`flash`); `builder` = `gemini-4-hydrogen-medium`.
{{AGY_SLOT_MAPPING_LINE}}
- **Risk Tiers:**
  - **T0** (Docs/comments only, tests green): No checker; Manager self-attests.
{{AGY_TIER_R1_R3_LINES}}

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
- `checker`: Same-turn `swarm(action="add", ...)` dispatching all active slot(s) (`checker-rN-a`, `checker-rN-b`) with `workspace="inherit"`.
- `browser`: Same-turn `invoke_subagent(TypeName="browser", ...)`.

**Exemptions & Wakeup:** Pure 0-tool Q&A/clarification turns, worker internal turns, and final synthesis with no new dispatch are exempt. On `<SYSTEM_MESSAGE>` wakeup, do NOT re-announce `DELEGATION: manager` just to read results and reply.

---

## 4. Workspace Safety, Concurrency & Quota Hygiene

1. **Workspace Mode:** Single writer (`builder` or `bulk`) ALWAYS uses `workspace="inherit"`. Disjoint parallel writers (`tasks=[...]` or `n>1`) use `workspace="share"`, and must be merged/verified before `swarm(action="kill")`.
2. **Concurrency & Quota Policy:** Keep `<= 3` active workers. {{AGY_QUOTA_POLICY_CLAUSE}}. Pre-dispatch: if `swarm(action="models")` explicitly reports `0%`/exhausted quota for a slot, skip spawning it (in Dual, run surviving slot `-medium`); if quota metadata is absent, dispatch normally (never guess). Anti-flapping: once `SINGLE_CHECKER_DEGRADED` in a round, stay degraded for that round (no re-spawn); degraded rounds still count toward the `<= 3`-round R3 Hard Stop cap.
3. **Async Wait & Barrier:** After dispatch, emit ONLY the single `DELEGATION:` waiting line (plus `open_board` when `swarm` requires it) and stop calling tools.{{AGY_PARTIAL_WAKEUP_CLAUSE}} Never poll `read_board`. `kill` finished workers immediately; verify `swarm(action="status")` shows 0 active workers before final reply.
4. **No Recursive Spawning & NO `checker -> scout`:** Every `swarm` brief MUST end with `CRITICAL: Do NOT call swarm(action='add') or spawn subagents.`

---

## 5. Epistemic Answer Discipline

- Quantify rejected alternatives alongside recommended ones.
- Explicitly label `CALCULATED` vs `MEASURED` values.
- Distinguish disk reads from live process state.
- Never embed the premise under test into `checker` or `scout` briefs.

---

## 6. Worker Sentinel & Brief Templates

Prefix every swarm worker brief with `[[AGY-ROLE:<role> round=<N>]]` (`round=0` initial `scout`/`bulk`/`builder`; `round=1..3` audit/fix cycles; `round=1` `checker-plan`). See `swarm-audit` for the `checker-rN-{a|b}` brief template.

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

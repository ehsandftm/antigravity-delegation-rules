---
name: swarm-audit
description: Swarm-Path dual-checker QA audit, non-mutating LF diff_sha256, MVD 7-col Comment Sheet, and 3-round escalation. Manager and Checker only.
---

# Swarm-Path QA Audit & MVD Comment Sheet

Loaded **only** by Manager and `checker-rN-{a|b}` (never `builder`/`bulk`/`scout`). **NO nested `checker -> scout`**, **NO `read_board`**, strictly non-mutating (zero file writes / untracked artifacts).

## 1. Pre-Gate, Non-Mutating Baseline & `diff_sha256`

- **Pre-Gate:** Build/typecheck/lint/tests must pass (`exit 0`) *before* `checker-r1-{a|b}`.
- **Baseline:** Capture `<baseline>` **before** `builder`/`bulk` edits (`git stash create` if dirty; if output is empty, `git rev-parse HEAD`). **`git add -N` is forbidden.**
- **Non-Git Fallback (e.g., `~/.gemini/*`):** Canonical LF SHA-256 of each target file sorted by path, then SHA-256 of those hex hashes joined by `\n`.
- **Canonical LF `diff_sha256`:**
```powershell
node -e "const c=require('crypto'),f=require('fs'),cp=require('child_process'),o={maxBuffer:1<<25},b=process.argv[1]||'HEAD',h=c.createHash('sha256');h.update(cp.execFileSync('git',['-c','core.quotepath=false','diff','-W','--no-color',b],o).toString('utf8').replace(/\r\n/g,'\n'));for(const p of cp.execFileSync('git',['-c','core.quotepath=false','ls-files','-z','--others','--exclude-standard'],o).toString('utf8').split('\0').filter(Boolean).sort((x,y)=>x<y?-1:x>y?1:0)){if(!f.statSync(p).isFile())continue;const fh=c.createHash('sha256').update(f.readFileSync(p).toString('utf8').replace(/\r\n/g,'\n')).digest('hex');h.update('UNTRACKED:'+p.split(String.fromCharCode(92)).join('/')+'\n'+fh+'\n');}console.log(h.digest('hex'));" <baseline>
```
- **Per-Slot Bounded Reads:** `<= 12 KB` / `<= 120` lines per window; caps per slot: **`R1 <= 8`**, **`R2 <= 3`**, **`R3 <= 2`**.

## 2. Checker Isolation & Partial-Wakeup Barrier

- Dispatch active slots (`checker-rN-a`, `checker-rN-b` in Dual; `checker-rN-a` in Single) in the same turn; briefs forbid `read_board` and peer references.
- **Partial-Wakeup Barrier (Dual):** Wait for both active slots before analyzing, folding, or dispatching `builder` (or surviving slot in `SINGLE_CHECKER_DEGRADED`).
- **SHA Lock:** Manager asserts `slotA.diff_sha256 == slotB.diff_sha256 == pregate_diff_sha256` (mismatch invalidates round).
- **R2/R3 Context:** Pass only that slot's own open rows + baseline/delta SHAs (never peer's rows or social-proof anchoring).

## 3. MVD 7-Column Comment Sheet & Row-Owner Ownership

```markdown
| ID | Sev | Anchor | Finding | Required Evidence | Builder Response | Status |
|---|---|---|---|---|---|---|
| CS.R1.A.01 | B | src/auth.ts:42 | Missing expiry | Test expired rejects | FIXED test_exp | O |
```

- **Slot-Neutral IDs & Caps:** `CS.R<n>.A.<nn>` (Slot A) and `CS.R<n>.B.<nn>` (Slot B). `<= 15` rows **per slot** (`.A.15`/`.B.15` reserved for `OVERFLOW_REAUDIT_REQUIRED`; up to 30 pre-dedup).
- **Row-Owner Invariant:** Only a fresh worker of the minting slot may close (`O -> C`) its own row (regressions get new ID; see Section 6 for quota-only fallback).
- **Deduplication:** Manager folds into one canonical board table preserving both source IDs (`A.03≡B.05`), higher severity wins, closes only when all source slots close it (never deletes rows).
- **Sev & Status:** `B` (Blocker), `M` (Major), `m` (minor — batch nits into 1 `m` row/slot/round). `O` (Open), `C` (Closed — immutable), `PAM` (`m` only; `M` needing PAM triggers `HUMAN_REQUIRED`).

## 4. Consensus, Rounds & Zero Self-Override

- **Consensus Lattice:** `FAIL > PASS_AS_MARKED > APPROVED` (`0 B/M/m -> APPROVED`; `0 B/M, >=1 m (PAM) -> PASS_AS_MARKED`; `>=1 B/M -> FAIL`).
- **Zero Self-Override:** Manager MUST NEVER unilaterally dismiss/close a checker's `B/M` row. False positives use `CS.R<n>.<A|B>.<nn>: CONTEST <deterministic proof>` routed to the minting slot in `R(n+1)` (or `HUMAN_REQUIRED` at R3).
- **R1:** Full pack; `0 B/M` -> `APPROVED`/`PASS_AS_MARKED` (no R2). `>=1 B/M` -> `FAIL`; Builder fixes + tests -> **R2**.
- **R2:** Row-owner selective (open `B/M` + delta; full pack if overflow); new rows only on R2-delta lines.
- **R3:** Open rows only; **no new rows** except new `B` regression in R3 delta. Open `B/M` -> **`HUMAN_REQUIRED`** Hard Stop (kill workers, list open rows grouped by slot `A`/`B`, baseline SHA, `diff_sha256`).

**Verdict Line (Checker emits ONLY `APPROVED`/`PASS_AS_MARKED`/`FAIL`):**
```text
VERDICT: APPROVED|PASS_AS_MARKED|FAIL  slot=A|B  round=N  diff_sha256=<sha256>  open=B0/M0/m2  tests=green  independent=yes
```

## 5. Compact `checker-rN-{a|b}` Brief Template

```text
[[AGY-ROLE:checker round=N]]
Slot: A|B | Scope: <baseline_sha, pregate_diff_sha256, open_rows_for_this_slot_only>.
Rules: NEVER call read_board; NO subagents/scout; strictly non-mutating (zero file writes/untracked artifacts).
Read caps: <=12KB/<=120 lines per window (R1<=8, R2<=3, R3<=2); <=15 CS.RN.<A|B>.<nn> rows.
Run non-mutating LF diff_sha256 and assert match with pregate_diff_sha256.
Output: MVD 7-col rows + final line:
VERDICT: APPROVED|PASS_AS_MARKED|FAIL  slot=<A|B>  round=N  diff_sha256=<sha256>  open=B<n>/M<n>/m<n>  tests=green|red  independent=yes
Post `@coordinator [done]` with verdict. CRITICAL: Do NOT call swarm(action='add') or spawn subagents.
```

## 6. Quota-Only `SINGLE_CHECKER_DEGRADED` Fallback (Dual Mode)

- **Trigger (Quota-Only):** Only explicit `429` / `RESOURCE_EXHAUSTED` / `[quota]` (or `0%` in `swarm(action="models")`) triggers `SINGLE_CHECKER_DEGRADED` (never crashes, timeouts, `diff_sha256` mismatch, or `FAIL`). Stay degraded for the rest of the round; degraded rounds count toward the `<= 3`-round cap.
- **R2/R3 Row-Owner Exception:** If the minting slot is quota-exhausted, Manager kills it and dispatches a fresh surviving-slot `-medium` worker for those open rows on the same `diff_sha256`, citing the original row ID (`CS.R<n>.<A|B>.<nn>`) and marking Column 7 `C (CLOSED_BY_SURVIVING_SLOT_QUOTA_FALLBACK)`.
- **Mandatory Disclosure:** Both the board `CONSENSUS:` line and the final user reply MUST state: `CONSENSUS: APPROVED|PASS_AS_MARKED|FAIL (SINGLE_CHECKER_DEGRADED: slot=<A|B> quota_exhausted, audited_by=slot=<B|A>)`.

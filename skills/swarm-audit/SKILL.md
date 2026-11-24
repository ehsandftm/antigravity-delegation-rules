---
name: swarm-audit
description: Swarm-Path QA audit, non-mutating LF diff_sha256, MVD 7-col Comment Sheet, and 3-round escalation. Manager and Checker only.
---

# Swarm-Path QA Audit & MVD Comment Sheet

Loaded **only** by Manager and `checker-rN` (never `builder`/`bulk`/`scout`). **NO nested `checker -> scout`**.

## 1. Pre-Gate, Non-Mutating Baseline & `diff_sha256`

- **Pre-Gate:** Build/typecheck/lint/tests must pass (`exit 0`) *before* `checker-r1`.
- **Baseline:** `git stash create` (or `HEAD` if clean). **`git add -N` is forbidden.**
- **Canonical LF `diff_sha256`:**
```bash
node -e 'const c=require("crypto"),f=require("fs"),cp=require("child_process"),o={maxBuffer:1<<25},b=process.argv[1]||"HEAD",h=c.createHash("sha256");h.update(cp.execFileSync("git",["-c","core.quotepath=false","diff","-W","--no-color",b],o).toString("utf8").replace(/\r\n/g,"\n"));for(const p of cp.execFileSync("git",["-c","core.quotepath=false","ls-files","-z","--others","--exclude-standard"],o).toString("utf8").split("\0").filter(Boolean).sort((x,y)=>x<y?-1:x>y?1:0)){const fh=c.createHash("sha256").update(f.readFileSync(p).toString("utf8").replace(/\r\n/g,"\n")).digest("hex");h.update("UNTRACKED:"+p.replace(/\\/g,"/")+"\n"+fh+"\n");}console.log(h.digest("hex"));' <baseline>
```
- **Bounded Reads:** `<= 12 KB` / `<= 120` lines per window; caps: **`R1 <= 8`**, **`R2 <= 3`**, **`R3 <= 2`**.

## 2. MVD 7-Column Comment Sheet (Single-Writer)

```markdown
| ID | Sev | Anchor | Finding | Required Evidence | Builder Response | Status |
|---|---|---|---|---|---|---|
| CS.R1.01 | B | src/auth.ts:42 | Missing expiry | Test expired rejects | FIXED test_exp | O |
```

- **Ownership:** **Checker** alone mints `CS.R<n>.<nn>` rows and sets `Status`. **Builder** posts `CS.R<n>.<nn>: FIXED <evidence>` or `CS.R<n>.<nn>: CONTEST <1-line proof>`. **Manager** folds replies into the board table before `checker-r(n+1)`.
- **Sev:** `B` (Blocker), `M` (Major), `m` (minor — batch nits into 1 `m` row/round).
- **Status:** `O` (Open), `C` (Closed — **immutable**; regressions get new ID), `PAM` (Pass-As-Marked — `m` only; `M` needing PAM triggers Manager `HUMAN_REQUIRED`).

## 3. Rounds & Verdict

- **R1:** Full pack; `<= 15` rows by severity (group same-cause defects). If >15, reserve `CS.R1.15` (`Sev=B`) as `OVERFLOW_REAUDIT_REQUIRED` (unlocks full pack in R2). 0 `B`/`M` -> `VERDICT: PASS_AS_MARKED` (**no R2**). `>=1` `B`/`M` -> `FAIL`; Builder fixes + tests -> **R2**.
- **R2:** R1->R2 delta + open rows (or full pack if overflow open); new rows only on R2-delta lines.
- **R3:** Open rows only; **no new rows** except new `B` regression in R3 delta. Open `B`/`M` -> `VERDICT: FAIL` -> **Manager** triggers **`HUMAN_REQUIRED`** Hard Stop (kill workers, print open rows, baseline SHA, `diff_sha256`).

**Verdict (Checker emits ONLY `APPROVED`/`PASS_AS_MARKED`/`FAIL`; recompute `diff_sha256` for `F2`):**
```text
VERDICT: APPROVED|PASS_AS_MARKED|FAIL  round=N  diff_sha256=<sha256>  open=B0/M0/m2  tests=green
```

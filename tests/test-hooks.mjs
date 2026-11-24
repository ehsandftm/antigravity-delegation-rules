import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { execFileSync, spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const fixturesDir = path.join(__dirname, "fixtures");

const { classifyRole } = require(path.join(repoRoot, "extras/hooks/agy-role-classifier.js"));
const { evaluate } = require(path.join(repoRoot, "extras/hooks/agy-delegation-gate.js"));
const { evaluateStop } = require(path.join(repoRoot, "extras/hooks/agy-stop-gate.js"));

function makeTempDir(prefix = "agy-test-") {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

function runGateCli(scriptRel, payloadObj, stateDir) {
  const scriptPath = path.join(repoRoot, scriptRel);
  const res = spawnSync(process.execPath, [scriptPath], {
    input: typeof payloadObj === "string" ? payloadObj : JSON.stringify(payloadObj),
    encoding: "utf8",
    env: { ...process.env, AGY_GATE_STATE_DIR: stateDir },
    timeout: 5000,
  });
  assert.equal(res.status, 0, `Hook exited with ${res.status}: ${res.stderr}`);
  return JSON.parse(res.stdout.trim());
}

test("Role classifier handles all fixtures and sticky tighten-only cache", () => {
  const stateDir = makeTempDir();
  try {
    assert.equal(classifyRole({ conversationId: "m1", transcriptPath: path.join(fixturesDir, "manager.jsonl") }, stateDir), "manager");
    assert.equal(classifyRole({ conversationId: "m2", transcriptPath: path.join(fixturesDir, "compacted.jsonl") }, stateDir), "manager");
    assert.equal(classifyRole({ conversationId: "c1", transcriptPath: path.join(fixturesDir, "checker.jsonl") }, stateDir), "checker");
    assert.equal(classifyRole({ conversationId: "b1", transcriptPath: path.join(fixturesDir, "builder.jsonl") }, stateDir), "builder");
    assert.equal(classifyRole({ conversationId: "s1", transcriptPath: path.join(fixturesDir, "scout.jsonl") }, stateDir), "scout");
    assert.equal(classifyRole({ conversationId: "sp1", transcriptPath: path.join(fixturesDir, "spoofed.jsonl") }, stateDir), "checker");
    assert.equal(classifyRole({ conversationId: "cb1", transcriptPath: path.join(fixturesDir, "crlf_bom.jsonl") }, stateDir), "manager");
    assert.equal(classifyRole({ conversationId: "ov1", transcriptPath: path.join(fixturesDir, "oversized_line1.jsonl") }, stateDir), "unknown");

    // Unknown is never cached
    assert.equal(fs.existsSync(path.join(stateDir, "roles", "ov1.json")), false);

    // Sticky cache + tighten-only: builder -> unknown stays builder; builder -> checker tightens to checker; checker -> manager stays checker
    assert.equal(classifyRole({ conversationId: "b1", transcriptPath: "/nonexistent.jsonl" }, stateDir), "builder");
    assert.equal(classifyRole({ conversationId: "b1", transcriptPath: path.join(fixturesDir, "checker.jsonl") }, stateDir), "checker");
    assert.equal(classifyRole({ conversationId: "b1", transcriptPath: path.join(fixturesDir, "manager.jsonl") }, stateDir), "checker");
  } finally {
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
});

test("PreToolUse CLI fail-open emits explicit {decision:allow} on malformed JSON, never {}", () => {
  const stateDir = makeTempDir();
  try {
    const out = runGateCli("extras/hooks/agy-delegation-gate.js", "{not-valid-json", stateDir);
    assert.deepEqual(out, { decision: "allow" });
  } finally {
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
});

test("Layer 1: H0 Anti-Tamper denies protected paths and allows repo development", () => {
  const stateDir = makeTempDir();
  try {
    const mgr = path.join(fixturesDir, "manager.jsonl");
    const blockedTargets = [
      "/home/user/.gemini/GEMINI.md",
      "C:\\Users\\test\\.gemini\\hooks.json",
      ".agents/hooks.json",
      "/home/user/.gemini/hooks/agy-delegation-gate.js",
      "~/.gemini/config/skills/swarm-audit/SKILL.md",
      ".git/hooks/pre-commit",
      "/tmp/.system_generated/logs/transcript.jsonl",
    ];
    for (const p of blockedTargets) {
      const r = evaluate({ conversationId: "h0-w", transcriptPath: mgr, toolCall: { name: "write_file", args: { Path: p, Content: "x" } } }, stateDir);
      assert.equal(r.out.decision, "deny", `Expected deny for write_file ${p}`);
      const c = evaluate({ conversationId: "h0-c", transcriptPath: mgr, toolCall: { name: "run_command", args: { CommandLine: `echo x > "${p}"` } } }, stateDir);
      assert.equal(c.out.decision, "deny", `Expected deny for run_command ${p}`);
    }

    // Repo development of extras/hooks/agy-delegation-gate.js must NOT be blocked
    const repoEdit = evaluate({
      conversationId: "h0-ok",
      transcriptPath: mgr,
      workspacePaths: [repoRoot],
      cwd: repoRoot,
      toolCall: { name: "edit_file", args: { Path: path.join(repoRoot, "extras/hooks/agy-delegation-gate.js"), Target: "a", Replacement: "b" } },
    }, stateDir);
    assert.equal(repoEdit.out.decision, "allow");
  } finally {
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
});

test("Layer 1: Destructive Command Guard returns force_ask for manager and deny for workers/unknown", () => {
  const stateDir = makeTempDir();
  try {
    const mgr = path.join(fixturesDir, "manager.jsonl");
    const bld = path.join(fixturesDir, "builder.jsonl");
    const unk = path.join(fixturesDir, "oversized_line1.jsonl");

    for (const cmd of ["rm -rf ./dist", "Remove-Item -Recurse ./dist", "git reset --hard HEAD~1", "git push --force", "DROP TABLE users;"]) {
      assert.equal(evaluate({ conversationId: "dm", transcriptPath: mgr, toolCall: { name: "run_command", args: { CommandLine: cmd } } }, stateDir).out.decision, "force_ask");
      assert.equal(evaluate({ conversationId: "db", transcriptPath: bld, toolCall: { name: "run_command", args: { CommandLine: cmd } } }, stateDir).out.decision, "deny");
      assert.equal(evaluate({ conversationId: "du", transcriptPath: unk, toolCall: { name: "run_command", args: { CommandLine: cmd } } }, stateDir).out.decision, "deny");
    }

    // MCP destructive tool name
    assert.equal(evaluate({ conversationId: "dm2", transcriptPath: mgr, toolCall: { name: "mcp_github_delete_repo", args: {} } }, stateDir).out.decision, "force_ask");
    assert.equal(evaluate({ conversationId: "db2", transcriptPath: bld, toolCall: { name: "mcp_github_delete_repo", args: {} } }, stateDir).out.decision, "deny");

    // Outside workspace write
    const outside = path.join(os.tmpdir(), "outside-file.txt");
    assert.equal(evaluate({ conversationId: "dm3", transcriptPath: mgr, workspacePaths: [repoRoot], toolCall: { name: "write_file", args: { Path: outside, Content: "x" } } }, stateDir).out.decision, "force_ask");
    assert.equal(evaluate({ conversationId: "db3", transcriptPath: bld, workspacePaths: [repoRoot], toolCall: { name: "write_file", args: { Path: outside, Content: "x" } } }, stateDir).out.decision, "deny");
  } finally {
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
});

test("Layer 1: Lazy-Placeholder Guard denies placeholders unless already in target", () => {
  const stateDir = makeTempDir();
  try {
    const mgr = path.join(fixturesDir, "manager.jsonl");
    assert.equal(evaluate({ conversationId: "lp1", transcriptPath: mgr, toolCall: { name: "write_file", args: { Path: "a.js", Content: "// ... existing code ..." } } }, stateDir).out.decision, "deny");
    assert.equal(evaluate({ conversationId: "lp2", transcriptPath: mgr, toolCall: { name: "edit_file", args: { Path: "a.js", Target: "const x = 1;", Replacement: "\u2026 rest of file" } } }, stateDir).out.decision, "deny");
    assert.equal(evaluate({ conversationId: "lp3", transcriptPath: mgr, toolCall: { name: "edit_file", args: { Path: "a.js", ReplacementChunks: [{ TargetContent: "foo", ReplacementContent: "... unchanged" }] } } }, stateDir).out.decision, "deny");
    // Allowed if already present in target
    assert.equal(evaluate({ conversationId: "lp4", transcriptPath: mgr, toolCall: { name: "edit_file", args: { Path: "a.js", Target: "// ... existing code ...", Replacement: "// ... existing code ...\nconst y = 2;" } } }, stateDir).out.decision, "allow");
  } finally {
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
});

test("Layer 1: F6 Secrets Guard blocks workers/unknown, force_asks manager, exempts .env.example", () => {
  const stateDir = makeTempDir();
  try {
    const mgr = path.join(fixturesDir, "manager.jsonl");
    const chk = path.join(fixturesDir, "checker.jsonl");
    const unk = path.join(fixturesDir, "oversized_line1.jsonl");

    assert.equal(evaluate({ conversationId: "f6m", transcriptPath: mgr, toolCall: { name: "read_file", args: { Path: ".env.production", StartLine: 1, EndLine: 10 } } }, stateDir).out.decision, "force_ask");
    assert.equal(evaluate({ conversationId: "f6c", transcriptPath: chk, toolCall: { name: "read_file", args: { Path: ".env", StartLine: 1, EndLine: 10 } } }, stateDir).out.decision, "deny");
    assert.equal(evaluate({ conversationId: "f6u", transcriptPath: unk, toolCall: { name: "run_command", args: { CommandLine: "cat id_rsa" } } }, stateDir).out.decision, "deny");
    assert.equal(evaluate({ conversationId: "f6ex", transcriptPath: chk, toolCall: { name: "read_file", args: { Path: ".env.example", StartLine: 1, EndLine: 10 } } }, stateDir).out.decision, "allow");
  } finally {
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
});

test("Layer 2: Spawn-Name Gate, checker/scout read-only, builder/bulk no-spawn, manager bounded read", () => {
  const stateDir = makeTempDir();
  try {
    const mgr = path.join(fixturesDir, "manager.jsonl");
    const chk = path.join(fixturesDir, "checker.jsonl");
    const sct = path.join(fixturesDir, "scout.jsonl");
    const bld = path.join(fixturesDir, "builder.jsonl");

    // Spawn-Name Gate
    assert.equal(evaluate({ conversationId: "sn1", transcriptPath: mgr, toolCall: { name: "swarm", args: { action: "add", name: "agent-1" } } }, stateDir).out.decision, "deny");
    assert.equal(evaluate({ conversationId: "sn2", transcriptPath: mgr, toolCall: { name: "swarm", args: { action: "add", name: "checker-r1" } } }, stateDir).out.decision, "allow");
    assert.equal(evaluate({ conversationId: "sn3", transcriptPath: mgr, toolCall: { name: "swarm", args: { action: "add", name: "builder-v12" } } }, stateDir).out.decision, "allow");

    // Checker & Scout restrictions
    for (const [cid, tp] of [["ck", chk], ["sc", sct]]) {
      assert.equal(evaluate({ conversationId: cid, transcriptPath: tp, toolCall: { name: "write_file", args: { Path: "a.js", Content: "x" } } }, stateDir).out.decision, "deny");
      assert.equal(evaluate({ conversationId: cid, transcriptPath: tp, toolCall: { name: "run_command", args: { CommandLine: "git diff --stat" } } }, stateDir).out.decision, "allow");
      assert.equal(evaluate({ conversationId: cid, transcriptPath: tp, toolCall: { name: "run_command", args: { CommandLine: "git diff; rm -rf /" } } }, stateDir).out.decision, "deny");
      assert.equal(evaluate({ conversationId: cid, transcriptPath: tp, toolCall: { name: "run_command", args: { CommandLine: "node -e '1'" } } }, stateDir).out.decision, "deny");
      const unbounded = evaluate({ conversationId: cid, transcriptPath: tp, toolCall: { name: "read_file", args: { Path: "a.js" } } }, stateDir);
      assert.equal(unbounded.out.decision, "deny");
      assert.match(unbounded.out.reason, /Specify integer StartLine and EndLine \(<=150 lines\)/);
    }

    // Builder cannot spawn
    assert.equal(evaluate({ conversationId: "bl1", transcriptPath: bld, toolCall: { name: "swarm", args: { action: "add", name: "bulk-1" } } }, stateDir).out.decision, "deny");
    assert.equal(evaluate({ conversationId: "bl2", transcriptPath: bld, toolCall: { name: "invoke_subagent", args: { TypeName: "research" } } }, stateDir).out.decision, "deny");

    // Manager bounded read (catches NaN bypass on omitted StartLine/EndLine and >150 range)
    assert.equal(evaluate({ conversationId: "mr1", transcriptPath: mgr, toolCall: { name: "read_file", args: { Path: "a.js" } } }, stateDir).out.decision, "deny");
    assert.equal(evaluate({ conversationId: "mr2", transcriptPath: mgr, toolCall: { name: "read_file", args: { Path: "a.js", StartLine: 1, EndLine: 200 } } }, stateDir).out.decision, "deny");
    assert.equal(evaluate({ conversationId: "mr3", transcriptPath: mgr, toolCall: { name: "read_file", args: { Path: "a.js", StartLine: 1, EndLine: 151 } } }, stateDir).out.decision, "allow");
  } finally {
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
});

test("Stop Gate: Turn-Wide F15 honesty, circuit breaker (max 2), and continuationActive", () => {
  const stateDir = makeTempDir();
  try {
    // Honest swarm dispatch -> {}
    assert.deepEqual(evaluateStop({
      conversationId: "st-h",
      transcriptPath: path.join(fixturesDir, "f15_honest_swarm.jsonl"),
      terminationReason: "NO_TOOL_CALL",
      fullyIdle: true,
    }, stateDir), {});

    // Dishonest dispatch -> continue up to 2 times, then {}
    const payload = {
      conversationId: "st-d",
      transcriptPath: path.join(fixturesDir, "f15_dishonest.jsonl"),
      terminationReason: "NO_TOOL_CALL",
      fullyIdle: true,
    };
    const r1 = evaluateStop(payload, stateDir);
    assert.equal(r1.decision, "continue");
    const r2 = evaluateStop(payload, stateDir);
    assert.equal(r2.decision, "continue");
    const r3 = evaluateStop(payload, stateDir);
    assert.deepEqual(r3, {});

    // continuationActive: true -> {}
    assert.deepEqual(evaluateStop({
      conversationId: "st-ca",
      transcriptPath: path.join(fixturesDir, "f15_dishonest.jsonl"),
      terminationReason: "NO_TOOL_CALL",
      fullyIdle: true,
      continuationActive: true,
    }, stateDir), {});

    // Non-manager -> {}
    assert.deepEqual(evaluateStop({
      conversationId: "st-chk",
      transcriptPath: path.join(fixturesDir, "checker.jsonl"),
      terminationReason: "NO_TOOL_CALL",
      fullyIdle: true,
    }, stateDir), {});
  } finally {
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
});

test("Stop Gate: Scoped Fast-Path numstat detects >50 changed lines in untracked/tracked files", () => {
  const stateDir = makeTempDir();
  const gitDir = makeTempDir("agy-git-");
  try {
    execFileSync("git", ["init"], { cwd: gitDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@example.com"], { cwd: gitDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: gitDir, stdio: "ignore" });
    fs.writeFileSync(path.join(gitDir, "app.js"), "init\n", "utf8");
    execFileSync("git", ["add", "app.js"], { cwd: gitDir, stdio: "ignore" });
    execFileSync("git", ["commit", "-m", "init"], { cwd: gitDir, stdio: "ignore" });

    // Modify app.js with 60 lines
    fs.writeFileSync(path.join(gitDir, "app.js"), Array.from({ length: 60 }, (_, i) => `line${i}`).join("\n") + "\n", "utf8");

    const res = evaluateStop({
      conversationId: "fp-1",
      transcriptPath: path.join(fixturesDir, "fastpath_exceeded.jsonl"),
      cwd: gitDir,
      terminationReason: "NO_TOOL_CALL",
      fullyIdle: true,
    }, stateDir);
    assert.equal(res.decision, "continue");
    assert.match(res.reason, /Fast-Path threshold exceeded/);
  } finally {
    fs.rmSync(stateDir, { recursive: true, force: true });
    fs.rmSync(gitDir, { recursive: true, force: true });
  }
});

test("Stop Gate & PreToolUse regressions: leading-newline F15, checker mismatch, write_to_file, ./foo.js untracked, missing transcriptPath", () => {
  const stateDir = makeTempDir();
  const gitDir = makeTempDir("agy-git-reg-");
  const tpDir = makeTempDir("agy-tp-reg-");
  try {
    // 1. Missing transcriptPath fails open without throwing ENOENT
    assert.deepEqual(evaluateStop({
      conversationId: "reg-missing",
      transcriptPath: path.join(tpDir, "does-not-exist.jsonl"),
      terminationReason: "NO_TOOL_CALL",
      fullyIdle: true,
    }, stateDir), {});

    // 2. Leading-newline F15 + empty trailing model step does not bypass
    const leadingNlTp = path.join(tpDir, "leading-nl.jsonl");
    fs.writeFileSync(leadingNlTp, [
      JSON.stringify({ step_index: 1, source: "USER_EXPLICIT", content: "build it" }),
      JSON.stringify({ step_index: 2, type: "PLANNER_RESPONSE", source: "MODEL", content: "\n\nDELEGATION: builder — spawning builder" }),
      JSON.stringify({ step_index: 3, type: "PLANNER_RESPONSE", source: "MODEL", content: "   " }),
    ].join("\n") + "\n", "utf8");
    const nlRes = evaluateStop({
      conversationId: "reg-nl",
      transcriptPath: leadingNlTp,
      terminationReason: "NO_TOOL_CALL",
      fullyIdle: true,
    }, stateDir);
    assert.equal(nlRes.decision, "continue");
    assert.match(nlRes.reason, /F15 Dispatch Honesty/);

    // 3. checker vs builder role mismatch on F15 (spawning builder-1 does not satisfy DELEGATION: checker)
    const mismatchTp = path.join(tpDir, "checker-mismatch.jsonl");
    fs.writeFileSync(mismatchTp, [
      JSON.stringify({ step_index: 1, source: "USER_EXPLICIT", content: "verify it" }),
      JSON.stringify({
        step_index: 2,
        type: "PLANNER_RESPONSE",
        source: "MODEL",
        content: "DELEGATION: checker — running QA",
        toolCalls: [{ name: "swarm", args: { action: "add", name: "builder-1", brief: "do work" } }],
      }),
    ].join("\n") + "\n", "utf8");
    const mmRes = evaluateStop({
      conversationId: "reg-mm",
      transcriptPath: mismatchTp,
      terminationReason: "NO_TOOL_CALL",
      fullyIdle: true,
    }, stateDir);
    assert.equal(mmRes.decision, "continue");
    assert.match(mmRes.reason, /DELEGATION: checker/);

    // 4. write_to_file Fast-Path detection + ./foo.js untracked normalization + trailing newline accuracy
    execFileSync("git", ["init"], { cwd: gitDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@example.com"], { cwd: gitDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: gitDir, stdio: "ignore" });
    fs.writeFileSync(path.join(gitDir, "README.md"), "hi\n", "utf8");
    execFileSync("git", ["add", "README.md"], { cwd: gitDir, stdio: "ignore" });
    execFileSync("git", ["commit", "-m", "init"], { cwd: gitDir, stdio: "ignore" });

    // Exactly 50 lines with trailing newline -> should NOT exceed 50 lines
    fs.writeFileSync(path.join(gitDir, "foo.js"), Array.from({ length: 50 }, (_, i) => `const a${i} = ${i};`).join("\n") + "\n", "utf8");
    const ok50Tp = path.join(tpDir, "ok50.jsonl");
    fs.writeFileSync(ok50Tp, [
      JSON.stringify({ step_index: 1, source: "USER_EXPLICIT", content: "edit foo" }),
      JSON.stringify({
        step_index: 2,
        type: "PLANNER_RESPONSE",
        source: "MODEL",
        content: "DELEGATION: manager — Fast-Path (1 file, 50 LOC): edit foo.js",
        tool_calls: [{ name: "write_to_file", args: { TargetFile: "./foo.js" } }],
      }),
    ].join("\n") + "\n", "utf8");
    assert.deepEqual(evaluateStop({
      conversationId: "reg-ok50",
      transcriptPath: ok50Tp,
      cwd: gitDir,
      terminationReason: "NO_TOOL_CALL",
      fullyIdle: true,
    }, stateDir), {});

    // 55 lines in ./foo.js via write_to_file -> triggers Fast-Path threshold exceeded
    fs.writeFileSync(path.join(gitDir, "foo.js"), Array.from({ length: 55 }, (_, i) => `const a${i} = ${i};`).join("\n") + "\n", "utf8");
    const over55Tp = path.join(tpDir, "over55.jsonl");
    fs.writeFileSync(over55Tp, [
      JSON.stringify({ step_index: 1, source: "USER_EXPLICIT", content: "edit foo" }),
      JSON.stringify({
        step_index: 2,
        type: "PLANNER_RESPONSE",
        source: "MODEL",
        content: "DELEGATION: manager — Fast-Path (1 file, 55 LOC): edit foo.js",
        tool_calls: [{ name: "write_to_file", args: { TargetFile: "./foo.js" } }],
      }),
    ].join("\n") + "\n", "utf8");
    const fpOverRes = evaluateStop({
      conversationId: "reg-over55",
      transcriptPath: over55Tp,
      cwd: gitDir,
      terminationReason: "NO_TOOL_CALL",
      fullyIdle: true,
    }, stateDir);
    assert.equal(fpOverRes.decision, "continue");
    assert.match(fpOverRes.reason, /Fast-Path threshold exceeded/);

    // 5. Tool alias parity in agy-delegation-gate.js (write_to_file, replace_file_content)
    const mgr = path.join(fixturesDir, "manager.jsonl");
    const chk = path.join(fixturesDir, "checker.jsonl");
    assert.equal(evaluate({ conversationId: "al-1", transcriptPath: mgr, toolCall: { name: "write_to_file", args: { TargetFile: "/home/u/.gemini/GEMINI.md", CodeContent: "x" } } }, stateDir).out.decision, "deny");
    assert.equal(evaluate({ conversationId: "al-2", transcriptPath: mgr, toolCall: { name: "replace_file_content", args: { TargetFile: "a.js", TargetContent: "x", ReplacementContent: "... existing" } } }, stateDir).out.decision, "deny");
    assert.equal(evaluate({ conversationId: "al-3", transcriptPath: chk, toolCall: { name: "write_to_file", args: { TargetFile: "a.js", CodeContent: "x" } } }, stateDir).out.decision, "deny");
  } finally {
    fs.rmSync(stateDir, { recursive: true, force: true });
    fs.rmSync(gitDir, { recursive: true, force: true });
    fs.rmSync(tpDir, { recursive: true, force: true });
  }
});

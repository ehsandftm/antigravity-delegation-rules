#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const __dirname = path.dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  let geminiDir = path.join(os.homedir(), ".gemini");
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--gemini-dir" && argv[i + 1]) {
      geminiDir = argv[++i];
    } else if (argv[i].startsWith("--gemini-dir=")) {
      geminiDir = argv[i].slice("--gemini-dir=".length);
    }
  }
  return { geminiDir };
}

function checkNodeVersion() {
  const major = parseInt(process.versions.node.split(".")[0], 10);
  if (Number.isNaN(major) || major < 18) {
    throw new Error(`Node >= 18 required, found ${process.version}`);
  }
  console.log(`PASS    : Node ${process.version}`);
}

function checkHooksJson(geminiDir) {
  const hooksJsonPath = path.join(geminiDir, "hooks.json");
  if (!fs.existsSync(hooksJsonPath)) {
    console.log(`INFO    : ${hooksJsonPath} not present (optional hooks not installed there)`);
    return;
  }
  const parsed = JSON.parse(fs.readFileSync(hooksJsonPath, "utf8"));
  assert.ok(parsed && typeof parsed === "object" && !Array.isArray(parsed), "hooks.json must be a JSON object");
  for (const key of ["agy-delegation-gate", "agy-stop-gate"]) {
    if (parsed[key]) {
      if (key === "agy-delegation-gate") {
        assert.ok(Array.isArray(parsed[key].PreToolUse), "agy-delegation-gate.PreToolUse must be an array");
        assert.ok(parsed[key].PreToolUse[0]?.hooks?.[0]?.command, "agy-delegation-gate command missing");
      } else {
        assert.ok(Array.isArray(parsed[key].Stop), "agy-stop-gate.Stop must be an array");
        assert.ok(parsed[key].Stop[0]?.command, "agy-stop-gate command missing");
      }
      console.log(`PASS    : hooks.json entry '${key}' valid`);
    } else {
      console.log(`INFO    : hooks.json entry '${key}' not registered`);
    }
  }
}

function checkScriptsAndSmoke(geminiDir) {
  const installedHooksDir = path.join(geminiDir, "hooks");
  const useInstalled = fs.existsSync(path.join(installedHooksDir, "agy-delegation-gate.js"));
  const baseDir = useInstalled ? installedHooksDir : __dirname;

  for (const f of ["agy-role-classifier.js", "agy-delegation-gate.js", "agy-stop-gate.js"]) {
    const full = path.join(baseDir, f);
    assert.ok(fs.existsSync(full), `Missing hook script: ${full}`);
  }
  console.log(`PASS    : Hook scripts found in ${baseDir}`);

  const { classifyRole } = require(path.join(baseDir, "agy-role-classifier.js"));
  const { evaluate } = require(path.join(baseDir, "agy-delegation-gate.js"));
  const { evaluateStop } = require(path.join(baseDir, "agy-stop-gate.js"));

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "agy-doctor-"));
  try {
    const mgrTranscript = path.join(tmpDir, "mgr.jsonl");
    fs.writeFileSync(mgrTranscript, JSON.stringify({ source: "USER_EXPLICIT", content: "hi" }) + "\n", "utf8");

    const role = classifyRole({ conversationId: "doc-1", transcriptPath: mgrTranscript }, tmpDir);
    assert.equal(role, "manager");

    const h0 = evaluate({
      conversationId: "doc-1",
      transcriptPath: mgrTranscript,
      toolCall: { name: "write_file", args: { Path: "/home/u/.gemini/GEMINI.md", Content: "x" } },
    }, tmpDir);
    assert.equal(h0.out.decision, "deny");

    const allow = evaluate({
      conversationId: "doc-1",
      transcriptPath: mgrTranscript,
      toolCall: { name: "read_file", args: { Path: "README.md", StartLine: 1, EndLine: 20 } },
    }, tmpDir);
    assert.equal(allow.out.decision, "allow");

    const stopOk = evaluateStop({
      conversationId: "doc-1",
      transcriptPath: mgrTranscript,
      terminationReason: "NO_TOOL_CALL",
      fullyIdle: true,
    }, tmpDir);
    assert.deepEqual(stopOk, {});

    console.log("PASS    : Smoke assertions (classifier, PreToolUse, Stop)");
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

try {
  const { geminiDir } = parseArgs(process.argv);
  checkNodeVersion();
  checkHooksJson(geminiDir);
  checkScriptsAndSmoke(geminiDir);
  console.log("DOCTOR  : ALL CHECKS PASSED");
  process.exit(0);
} catch (err) {
  console.error("DOCTOR  : FAILED -", err && err.message ? err.message : err);
  process.exit(1);
}

"use strict";
const fs = require("fs");
const path = require("path");
const os = require("os");
const crypto = require("crypto");
const { execFileSync } = require("child_process");
const { classifyRole } = require("./agy-role-classifier.js");

const TAIL_BYTES = 262144;
const DELEGATION_WORKER_RE = /^DELEGATION:\s*(scout|builder|bulk|checker|browser)\b/i;
const FAST_PATH_RE = /^DELEGATION:\s*manager\b.*fast[\u2013\u2014-]?path/i;
const EDIT_TOOL_NAMES = new Set([
  "write_file",
  "edit_file",
  "write_to_file",
  "replace_file_content",
  "multi_replace_file_content",
]);

function readTailSteps(transcriptPath) {
  if (!transcriptPath || typeof transcriptPath !== "string") return [];
  let fd;
  try {
    fd = fs.openSync(transcriptPath, "r");
    const stat = fs.fstatSync(fd);
    const size = stat.size;
    if (size <= 0) return [];
    const offset = Math.max(0, size - TAIL_BYTES);
    const toRead = size - offset;
    const buf = Buffer.allocUnsafe(toRead);
    const bytesRead = fs.readSync(fd, buf, 0, toRead, offset);
    let text = buf.toString("utf8", 0, bytesRead);
    if (offset === 0 && text.charCodeAt(0) === 0xfeff) text = text.slice(1);
    const lines = text.split(/\r?\n/);
    if (offset > 0 && lines.length > 0) lines.shift();
    const steps = [];
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        steps.push(JSON.parse(line));
      } catch (_) {}
    }
    return steps;
  } catch (_) {
    return [];
  } finally {
    if (fd !== undefined) {
      try { fs.closeSync(fd); } catch (_) {}
    }
  }
}

function parseToolArgs(tc) {
  const raw = (tc && (tc.args !== undefined ? tc.args : tc.arguments)) || {};
  if (typeof raw === "string") {
    try { return JSON.parse(raw); } catch (_) { return {}; }
  }
  return raw && typeof raw === "object" ? raw : {};
}

function isTurnBoundary(step) {
  if (!step || typeof step !== "object") return false;
  if (step.source === "USER_EXPLICIT") return true;
  if (step.source === "SYSTEM" && typeof step.content === "string" && step.content.includes("[swarm]")) return true;
  return false;
}

function readBreaker(stateFile, convId, turnSeq) {
  try {
    const data = JSON.parse(fs.readFileSync(stateFile, "utf8"));
    if (data && data.conversationId === convId && data.lastUserTurnSeq === turnSeq) {
      return Number.isInteger(data.count) ? data.count : 0;
    }
  } catch (_) {}
  return 0;
}

function writeBreaker(stateDir, stateFile, convId, turnSeq, count) {
  try {
    fs.mkdirSync(stateDir, { recursive: true });
    const tmp = stateFile + ".tmp." + process.pid;
    fs.writeFileSync(tmp, JSON.stringify({ conversationId: convId, lastUserTurnSeq: turnSeq, count }), "utf8");
    fs.renameSync(tmp, stateFile);
  } catch (_) {}
}

function countFastPathChanges(paths, cwd) {
  let filesChanged = 0;
  let linesChanged = 0;
  const normPaths = Array.from(
    new Set(
      paths
        .map((p) => path.relative(cwd, path.resolve(cwd, p)).replace(/\\/g, "/"))
        .filter(Boolean)
    )
  );
  if (normPaths.length === 0) return { filesChanged: 0, linesChanged: 0 };

  try {
    const out = execFileSync("git", ["diff", "--numstat", "--relative", "--", ...normPaths], {
      cwd,
      timeout: 600,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    for (const line of out.split(/\r?\n/)) {
      if (!line.trim()) continue;
      const parts = line.split("\t");
      if (parts.length < 3) continue;
      filesChanged++;
      const a = parseInt(parts[0], 10);
      const d = parseInt(parts[1], 10);
      if (!Number.isNaN(a)) linesChanged += a;
      if (!Number.isNaN(d)) linesChanged += d;
    }
  } catch (_) {
    return null;
  }

  const untrackedSet = new Set();
  try {
    const uOut = execFileSync("git", ["ls-files", "--others", "--exclude-standard", "--", ...normPaths], {
      cwd,
      timeout: 600,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    for (const u of uOut.split(/\r?\n/)) {
      if (u.trim()) untrackedSet.add(u.trim());
    }
  } catch (_) {}

  for (const rel of normPaths) {
    if (untrackedSet.has(rel)) {
      const full = path.resolve(cwd, rel);
      if (fs.existsSync(full)) {
        try {
          const fd = fs.openSync(full, "r");
          let isBinary = false;
          try {
            const probe = Buffer.alloc(8192);
            const bytesRead = fs.readSync(fd, probe, 0, 8192, 0);
            if (probe.subarray(0, bytesRead).includes(0)) {
              isBinary = true;
            }
          } finally {
            fs.closeSync(fd);
          }
          if (isBinary) continue;
          const content = fs.readFileSync(full, "utf8");
          filesChanged++;
          linesChanged += content.length === 0 ? 0 : content.replace(/\r?\n$/, "").split(/\r?\n/).length;
        } catch (_) {}
      }
    }
  }

  return { filesChanged, linesChanged };
}

function logStop(stateDir, ruleId, role, decision) {
  try {
    fs.mkdirSync(stateDir, { recursive: true });
    const entry = JSON.stringify({ ts: new Date().toISOString(), hook: "stop", ruleId, role, decision });
    fs.appendFileSync(path.join(stateDir, "gate.log"), entry + "\n", "utf8");
  } catch (_) {}
}

function evaluateStop(payload, stateDir) {
  try {
    if (!payload || payload.terminationReason !== "NO_TOOL_CALL" || payload.fullyIdle !== true) {
      return {};
    }
    if (/quota|rate.?limit|cancel/i.test(String(payload.error || ""))) {
      return {};
    }
    if (payload.continuationActive === true) {
      return {};
    }

    const role = classifyRole(payload, stateDir);
    if (role !== "manager") return {};

    const steps = readTailSteps(payload.transcriptPath);
    if (steps.length === 0) return {};

    let boundaryIdx = -1;
    for (let i = steps.length - 1; i >= 0; i--) {
      if (isTurnBoundary(steps[i])) {
        boundaryIdx = i;
        break;
      }
    }
    if (boundaryIdx < 0) return {};

    const boundaryStep = steps[boundaryIdx];
    let turnSeq = boundaryStep.step_index ?? boundaryStep.stepIndex;
    if (turnSeq === undefined || turnSeq === null) {
      turnSeq = crypto
        .createHash("sha256")
        .update((boundaryStep.created_at || "") + ":" + String(boundaryStep.content || "").slice(0, 200))
        .digest("hex");
    }
    const convId = payload.conversationId ? String(payload.conversationId) : "default";
    const safeId = convId.replace(/[^a-zA-Z0-9_-]/g, "_") || "default";
    const stateFile = path.join(stateDir, `stop-${safeId}.json`);

    const count = readBreaker(stateFile, convId, turnSeq);
    if (count >= 2) return {};

    const turnSteps = steps.slice(boundaryIdx + 1);
    let finalPlanner = null;
    const touchedPaths = new Set();
    let hasSubagent = false;
    let hasSwarmAdd = false;
    let hasBrowserTool = false;
    let hasCheckerAdd = false;

    for (const st of turnSteps) {
      if (
        st &&
        (st.type === "PLANNER_RESPONSE" || st.source === "MODEL") &&
        typeof st.content === "string" &&
        st.content.trim().length > 0
      ) {
        finalPlanner = st;
      }
      const rawCalls = st && (st.tool_calls || st.toolCalls || (st.tool_call ? [st.tool_call] : null));
      const calls = Array.isArray(rawCalls) ? rawCalls : [];
      for (const tc of calls) {
        const name = String((tc && (tc.name || tc.tool_name)) || "");
        const args = parseToolArgs(tc);
        if (name === "invoke_subagent") hasSubagent = true;
        if (/browser/i.test(name)) hasBrowserTool = true;
        if (name === "swarm" && args.action === "add") {
          hasSwarmAdd = true;
          if (typeof args.name === "string" && args.name.startsWith("checker")) {
            hasCheckerAdd = true;
          }
        }
        if (EDIT_TOOL_NAMES.has(name)) {
          const p = args.Path || args.TargetFile || args.path;
          if (typeof p === "string" && p.trim()) touchedPaths.add(p.trim());
        }
      }
    }

    if (!finalPlanner || typeof finalPlanner.content !== "string") return {};
    const firstLine = finalPlanner.content.trimStart().split(/\r?\n/)[0].trim();

    // Check 1: Turn-Wide F15 Dispatch Honesty
    const delegMatch = firstLine.match(DELEGATION_WORKER_RE);
    if (delegMatch) {
      const targetRole = delegMatch[1].toLowerCase();
      let dispatched = false;
      if (targetRole === "scout") dispatched = hasSubagent;
      else if (targetRole === "browser") dispatched = hasSubagent || hasBrowserTool;
      else if (targetRole === "checker") dispatched = hasCheckerAdd;
      else dispatched = hasSwarmAdd;

      if (!dispatched) {
        writeBreaker(stateDir, stateFile, convId, turnSeq, count + 1);
        logStop(stateDir, "F15-dishonest", role, "continue");
        return {
          decision: "continue",
          reason: `F15 Dispatch Honesty: response declared DELEGATION: ${targetRole} without dispatching the corresponding worker/subagent in this turn.`,
        };
      }
    }

    // Check 2: Scoped Fast-Path numstat Check
    if (FAST_PATH_RE.test(firstLine) && touchedPaths.size > 0 && !hasCheckerAdd) {
      const cwd = payload.cwd || process.cwd();
      const stats = countFastPathChanges(Array.from(touchedPaths), cwd);
      if (stats && (stats.filesChanged > 2 || stats.linesChanged > 50)) {
        writeBreaker(stateDir, stateFile, convId, turnSeq, count + 1);
        logStop(stateDir, "fastpath-exceeded", role, "continue");
        return {
          decision: "continue",
          reason: `Fast-Path threshold exceeded (${stats.filesChanged} files, ${stats.linesChanged} lines; max 2 files / 50 lines): dispatch checker-r1 or escalate to Swarm-Path.`,
        };
      }
    }

    return {};
  } catch (_) {
    return {};
  }
}

function main() {
  let responded = false;
  const stateDir = process.env.AGY_GATE_STATE_DIR || path.join(os.homedir(), ".gemini", "agy-gate");
  const respond = (obj) => {
    if (responded) return;
    responded = true;
    clearTimeout(timer);
    process.stdout.write(JSON.stringify(obj) + "\n", () => process.exit(0));
  };
  const timer = setTimeout(() => respond({}), 1800);
  timer.unref();

  let input = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => { input += chunk; });
  process.stdin.on("end", () => {
    try {
      const payload = input ? JSON.parse(input) : {};
      const out = evaluateStop(payload, stateDir);
      respond(out);
    } catch (_) {
      respond({});
    }
  });
  process.stdin.on("error", () => respond({}));
}

if (require.main === module) main();
module.exports = { evaluateStop, readTailSteps, countFastPathChanges };

"use strict";
const fs = require("fs");
const path = require("path");
const os = require("os");
const { classifyRole } = require("./agy-role-classifier.js");

const PLACEHOLDER_RE_1 = /(\.\.\.|\u2026)\s*(rest|existing|remaining|unchanged|same as before)/i;
const PLACEHOLDER_RE_2 = /\/\/\s*\.\.\.\s*existing code\s*\.\.\./i;
const SPAWN_NAME_RE = /^(builder|bulk|checker-r[123]|checker-[a-z0-9-]+)(-[a-z0-9-]+)?$/;
const READONLY_CMD_RE = /^(?:git\s+(?:diff|log|show|status|ls-files)|rg|grep|ls)(?:\s|$)/;
const SHELL_META_RE = /[;&|><`\r\n]|\$\(/;
const WRITE_TOOLS = new Set(["write_file", "write_to_file"]);
const EDIT_TOOLS = new Set(["edit_file", "replace_file_content", "multi_replace_file_content"]);
const ALL_WRITE_EDIT_TOOLS = new Set([...WRITE_TOOLS, ...EDIT_TOOLS]);

const H0_PATTERNS = [
  /\.gemini\/gemini\.md(?=$|[\s"'/\\])/i,
  /\.gemini\/(?:[^/]+\/)*hooks[^/]*\.json(?=$|[\s"'])/i,
  /(?:^|[\s"'/])\.agents\/hooks\.json(?=$|[\s"'])/i,
  /\.gemini\/(?:[^/]+\/)*agy-[^/\s"']*-gate\.js(?=$|[\s"'])/i,
  /\.gemini\/config\/skills(?:\/|$)/i,
  /(?:^|[\s"'/])\.git\/hooks(?:\/|$)/i,
  /\.system_generated\/logs(?:\/|$)/i,
];

const DESTRUCTIVE_PATTERNS = [
  /\brm\s+(?:-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r|--recursive\b.*\b--force|--force\b.*\b--recursive)\b/,
  /\bRemove-Item\b.*\s-Recurse\b/i,
  /\bdel\b.*\s\/s\b/i,
  /\brd\b.*\s\/s\b/i,
  /\bClear-Content\b/i,
  /\bgit\s+reset\s+--hard\b/i,
  /\bgit\s+clean\b.*\s-[a-zA-Z]*f/i,
  /\bgit\s+push\b.*\s(?:--force(?:-with-lease)?|-f)\b/i,
  /\bgit\s+checkout\s+--\s+\./i,
  /\bgit\s+stash\s+(?:drop|clear)\b/i,
  /\bfind\b.*\s-delete\b/,
  /\b(?:DROP|TRUNCATE)\s+TABLE\b/i,
];

function isProtectedPath(str) {
  if (typeof str !== "string" || !str) return false;
  const norm = str.replace(/\\/g, "/");
  return H0_PATTERNS.some((re) => re.test(norm));
}

function hasSecretRef(str) {
  if (typeof str !== "string" || !str) return false;
  const norm = str.replace(/\\/g, "/");
  const envMatches = norm.match(/(?:^|[\s"'/])\.env(?:\.([a-zA-Z0-9_-]+))?(?=$|[\s"'/])/gi) || [];
  for (const m of envMatches) {
    if (!/\.env\.(?:example|sample|template)$/i.test(m.trim())) return true;
  }
  if (/\.(?:pem|key)(?=$|[\s"'])/i.test(norm)) return true;
  if (/(?:^|[\s"'/])id_(?:rsa|dsa|ecdsa|ed25519)(?=$|[\s"'])/i.test(norm)) return true;
  if (/(?:^|[\s"'/])credentials[^/\s"']*(?=$|[\s"'])/i.test(norm)) return true;
  return false;
}

function hasPlaceholder(str) {
  return typeof str === "string" && (PLACEHOLDER_RE_1.test(str) || PLACEHOLDER_RE_2.test(str));
}

function isOutsideWorkspace(targetPath, payload) {
  if (!targetPath || typeof targetPath !== "string") return false;
  const workspaces = payload && payload.workspacePaths;
  if (!Array.isArray(workspaces) || workspaces.length === 0) return false;
  const cwd = (payload && payload.cwd) || process.cwd();
  const resolved = path.resolve(cwd, targetPath);
  const normTarget = process.platform === "win32" ? resolved.toLowerCase() : resolved;
  for (const ws of workspaces) {
    if (typeof ws !== "string" || !ws) continue;
    const wsRes = path.resolve(ws);
    const normWs = process.platform === "win32" ? wsRes.toLowerCase() : wsRes;
    const rel = path.relative(normWs, normTarget);
    if (rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel))) return false;
  }
  return true;
}

function isValidReadRange(args) {
  const s = args && args.StartLine;
  const e = args && args.EndLine;
  return Number.isInteger(s) && Number.isInteger(e) && s >= 1 && e >= s && (e - s) <= 150;
}

function logDecision(stateDir, toolName, ruleId, role, decision) {
  try {
    fs.mkdirSync(stateDir, { recursive: true });
    const entry = JSON.stringify({ ts: new Date().toISOString(), toolName, ruleId, role, decision });
    fs.appendFileSync(path.join(stateDir, "gate.log"), entry + "\n", "utf8");
  } catch (_) {}
}

function evaluate(payload, stateDir) {
  const role = classifyRole(payload, stateDir);
  const tc = (payload && payload.toolCall) || {};
  const toolName = String(tc.name || "");
  const args = tc.args || {};

  // Layer 1: H0 Anti-Tamper
  if (ALL_WRITE_EDIT_TOOLS.has(toolName)) {
    const p = args.Path || args.TargetFile || args.path || "";
    if (isProtectedPath(p)) {
      return { role, ruleId: "H0-anti-tamper", out: { decision: "deny", reason: "H0 Anti-Tamper: protected configuration or hook path cannot be modified." } };
    }
  }
  if (toolName === "run_command" && isProtectedPath(args.CommandLine || "")) {
    return { role, ruleId: "H0-anti-tamper", out: { decision: "deny", reason: "H0 Anti-Tamper: command references a protected configuration or hook path." } };
  }

  // Layer 1: Destructive Command / Outside-Workspace Guard
  const workerOrUnknown = role !== "manager";
  const destructiveDecision = workerOrUnknown ? "deny" : "force_ask";
  const destructiveReason = workerOrUnknown
    ? "Destructive operation requires manager confirmation; report back to board."
    : "Destructive or out-of-workspace operation requires explicit confirmation.";

  if (toolName === "run_command") {
    const cmd = String(args.CommandLine || "");
    if (DESTRUCTIVE_PATTERNS.some((re) => re.test(cmd))) {
      return { role, ruleId: "destructive-cmd", out: { decision: destructiveDecision, reason: destructiveReason } };
    }
  }
  if (/(delete|remove|drop|purge)/i.test(toolName)) {
    return { role, ruleId: "destructive-mcp", out: { decision: destructiveDecision, reason: destructiveReason } };
  }
  if (ALL_WRITE_EDIT_TOOLS.has(toolName)) {
    const p = args.Path || args.TargetFile || args.path || "";
    if (isOutsideWorkspace(p, payload)) {
      return { role, ruleId: "outside-workspace", out: { decision: destructiveDecision, reason: destructiveReason } };
    }
  }

  // Layer 1: Lazy-Placeholder Guard
  if (WRITE_TOOLS.has(toolName) && hasPlaceholder(args.Content ?? args.CodeContent)) {
    return { role, ruleId: "lazy-placeholder", out: { decision: "deny", reason: `Lazy placeholder detected in ${toolName} Content; write complete code.` } };
  }
  if (EDIT_TOOLS.has(toolName)) {
    if (hasPlaceholder(args.Replacement) && !hasPlaceholder(args.Target)) {
      return { role, ruleId: "lazy-placeholder", out: { decision: "deny", reason: `Lazy placeholder detected in ${toolName} Replacement; write complete code.` } };
    }
    if (hasPlaceholder(args.ReplacementContent) && !hasPlaceholder(args.TargetContent)) {
      return { role, ruleId: "lazy-placeholder", out: { decision: "deny", reason: `Lazy placeholder detected in ${toolName} ReplacementContent; write complete code.` } };
    }
    if (Array.isArray(args.ReplacementChunks)) {
      for (const ch of args.ReplacementChunks) {
        if (ch && hasPlaceholder(ch.ReplacementContent) && !hasPlaceholder(ch.TargetContent)) {
          return { role, ruleId: "lazy-placeholder", out: { decision: "deny", reason: `Lazy placeholder detected in ${toolName} ReplacementChunks; write complete code.` } };
        }
      }
    }
  }

  // Layer 1: F6 Secrets Read Guard
  if (toolName === "read_file" && hasSecretRef(args.Path || args.path || "")) {
    return {
      role,
      ruleId: "F6-secrets-read",
      out: {
        decision: workerOrUnknown ? "deny" : "force_ask",
        reason: workerOrUnknown ? "F6 Secrets Guard: workers cannot read secret files." : "F6 Secrets Guard: reading secret file requires confirmation.",
      },
    };
  }
  if (toolName === "run_command" && hasSecretRef(args.CommandLine || "")) {
    return {
      role,
      ruleId: "F6-secrets-cmd",
      out: {
        decision: workerOrUnknown ? "deny" : "force_ask",
        reason: workerOrUnknown ? "F6 Secrets Guard: workers cannot access secret files via command." : "F6 Secrets Guard: command references secret file; requires confirmation.",
      },
    };
  }

  // Layer 2: Spawn-Name Gate (all roles)
  if (toolName === "swarm" && args.action === "add") {
    if (typeof args.name !== "string" || !SPAWN_NAME_RE.test(args.name)) {
      return { role, ruleId: "spawn-name-gate", out: { decision: "deny", reason: "Spawn-Name Gate: worker name must match ^(builder|bulk|checker-r[123]|checker-[a-z0-9-]+)(-[a-z0-9-]+)?$." } };
    }
  }

  if (role === "unknown") {
    return { role, ruleId: "unknown-allow", out: { decision: "allow" } };
  }

  // Layer 2: checker & scout
  if (role === "checker" || role === "scout") {
    if (ALL_WRITE_EDIT_TOOLS.has(toolName)) {
      return { role, ruleId: "readonly-no-write", out: { decision: "deny", reason: `${role} is read-only and cannot modify files.` } };
    }
    if ((toolName === "swarm" && args.action === "add") || toolName === "invoke_subagent") {
      return { role, ruleId: "readonly-no-spawn", out: { decision: "deny", reason: `${role} cannot spawn nested workers or subagents.` } };
    }
    if (toolName === "run_command") {
      const cmd = String(args.CommandLine || "").trim();
      if (!READONLY_CMD_RE.test(cmd) || SHELL_META_RE.test(cmd)) {
        return { role, ruleId: "readonly-cmd-allowlist", out: { decision: "deny", reason: `${role} run_command is restricted to anchored read-only commands without shell metacharacters.` } };
      }
    }
    if (toolName === "read_file" && !isValidReadRange(args)) {
      return { role, ruleId: "bounded-read", out: { decision: "deny", reason: "Bounded read required: Specify integer StartLine and EndLine (<=150 lines)." } };
    }
  }

  // Layer 2: builder & bulk
  if (role === "builder" || role === "bulk") {
    if ((toolName === "swarm" && args.action === "add") || toolName === "invoke_subagent") {
      return { role, ruleId: "worker-no-spawn", out: { decision: "deny", reason: `${role} cannot recursively spawn workers or subagents.` } };
    }
  }

  // Layer 2: manager
  if (role === "manager") {
    if (toolName === "read_file" && !isValidReadRange(args)) {
      return { role, ruleId: "bounded-read", out: { decision: "deny", reason: "Bounded read required: Specify integer StartLine and EndLine (<=150 lines)." } };
    }
  }

  return { role, ruleId: "default-allow", out: { decision: "allow" } };
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
  const timer = setTimeout(() => respond({ decision: "allow" }), 150);
  timer.unref();

  let input = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => { input += chunk; });
  process.stdin.on("end", () => {
    try {
      const payload = input ? JSON.parse(input) : {};
      const res = evaluate(payload, stateDir);
      const toolName = (payload && payload.toolCall && payload.toolCall.name) || "";
      logDecision(stateDir, toolName, res.ruleId, res.role, res.out.decision);
      respond(res.out);
    } catch (_) {
      respond({ decision: "allow" });
    }
  });
  process.stdin.on("error", () => respond({ decision: "allow" }));
}

if (require.main === module) main();
module.exports = { evaluate, isProtectedPath, hasSecretRef, hasPlaceholder, isOutsideWorkspace, isValidReadRange };

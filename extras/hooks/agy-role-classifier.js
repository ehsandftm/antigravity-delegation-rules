"use strict";
const fs = require("fs");
const path = require("path");
const os = require("os");

const RANK = { checker: 1, scout: 2, bulk: 3, builder: 3, manager: 4, unknown: 99 };
const HEAD_BYTES = 65536;
const TTL_MS = 7 * 24 * 60 * 60 * 1000;

function moreRestrictive(a, b) {
  const ra = RANK[a] || 99;
  const rb = RANK[b] || 99;
  return ra <= rb ? a : b;
}

function roleFromName(name) {
  if (!name) return null;
  if (name.startsWith("checker")) return "checker";
  if (name.startsWith("scout")) return "scout";
  if (name.startsWith("bulk")) return "bulk";
  if (name.startsWith("builder")) return "builder";
  return null;
}

function readHeadLines(transcriptPath) {
  const fd = fs.openSync(transcriptPath, "r");
  try {
    const buf = Buffer.allocUnsafe(HEAD_BYTES);
    const bytesRead = fs.readSync(fd, buf, 0, HEAD_BYTES, 0);
    if (bytesRead <= 0) return [];
    let text = buf.toString("utf8", 0, bytesRead);
    if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
    return text.split(/\r?\n/).filter((l) => l.length > 0).slice(0, 2);
  } finally {
    fs.closeSync(fd);
  }
}

function parseFromTranscript(transcriptPath) {
  if (!transcriptPath || typeof transcriptPath !== "string") return "unknown";
  const lines = readHeadLines(transcriptPath);
  if (lines.length === 0) return "unknown";
  const l1 = JSON.parse(lines[0]);
  if (l1 && l1.source === "USER_EXPLICIT") return "manager";
  if (lines.length < 2) return "unknown";
  const l2 = JSON.parse(lines[1]);
  const l1Content = typeof l1.content === "string" ? l1.content : "";
  const l2Content = typeof l2.content === "string" ? l2.content : "";

  if (l2 && l2.source === "SYSTEM") {
    const assignMatch = l2Content.match(/recorded on the board as #\d+ for @([a-z0-9_-]+)\)?:/);
    if (assignMatch) {
      const byName = roleFromName(assignMatch[1]);
      const sentinelMatch = l2Content.match(/^\[\[AGY-ROLE:(checker|builder|bulk|scout)\s+round=\d+\]\]/m);
      const bySentinel = sentinelMatch ? sentinelMatch[1] : null;
      if (byName && bySentinel) return moreRestrictive(byName, bySentinel);
      if (bySentinel) return bySentinel;
      if (byName) return byName;
      return "unknown";
    }
  }

  if (l1 && l1.source === "SYSTEM" && !/\[swarm\]/i.test(l1Content) && l2 && l2.source === "MODEL") {
    return "scout";
  }
  return "unknown";
}

function cleanupOldCaches(rolesDir) {
  try {
    const cutoff = Date.now() - TTL_MS;
    const entries = fs.readdirSync(rolesDir);
    for (let i = 0; i < entries.length && i < 64; i++) {
      const name = entries[i];
      if (!name.endsWith(".json")) continue;
      const full = path.join(rolesDir, name);
      try {
        const st = fs.statSync(full);
        if (st.mtimeMs < cutoff) fs.unlinkSync(full);
      } catch (_) {}
    }
  } catch (_) {}
}

function classifyRole(payload, stateDir) {
  try {
    const baseDir = stateDir || process.env.AGY_GATE_STATE_DIR || path.join(os.homedir(), ".gemini", "agy-gate");
    const rolesDir = path.join(baseDir, "roles");
    const rawId = payload && payload.conversationId ? String(payload.conversationId) : "";
    const safeId = rawId.replace(/[^a-zA-Z0-9_-]/g, "_") || "default";
    const cacheFile = path.join(rolesDir, safeId + ".json");

    let cachedRole = null;
    try {
      const raw = fs.readFileSync(cacheFile, "utf8");
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed.role === "string" && parsed.role !== "unknown" && RANK[parsed.role]) {
        cachedRole = parsed.role;
      }
    } catch (_) {}

    let detected = "unknown";
    try {
      detected = parseFromTranscript(payload && payload.transcriptPath);
    } catch (_) {
      detected = "unknown";
    }

    const finalRole = cachedRole
      ? (detected !== "unknown" ? moreRestrictive(cachedRole, detected) : cachedRole)
      : detected;

    if (finalRole !== "unknown" && finalRole !== cachedRole) {
      fs.mkdirSync(rolesDir, { recursive: true });
      const tmp = cacheFile + ".tmp." + process.pid;
      fs.writeFileSync(tmp, JSON.stringify({ role: finalRole, ts: Date.now() }), "utf8");
      fs.renameSync(tmp, cacheFile);
      cleanupOldCaches(rolesDir);
    }
    return finalRole;
  } catch (_) {
    return "unknown";
  }
}

module.exports = { classifyRole, RANK };

#!/usr/bin/env bash
set -euo pipefail

TMP_DIR=""
START_MARKER="<!-- antigravity-delegation-rules:start -->"
END_MARKER="<!-- antigravity-delegation-rules:end -->"
REPO_SLUG="ehsandftm/antigravity-delegation-rules"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

usage() {
  cat <<'EOF'
Usage: install.sh [OPTIONS]

Options:
  --with-hooks         Opt-in: install pure-Node PreToolUse & Stop hooks into <gemini-dir>/hooks/ and merge hooks.json
  --verify             Verify installed GEMINI.md block and SKILL.md files (and hooks if --with-hooks) against canonical SHA-256
  --uninstall          Remove delegation block from GEMINI.md, installed skills, and any installed agy hooks/cache
  --gemini-dir <path>  Target Antigravity directory (default: $HOME/.gemini)
  --ref <git-ref>      Git ref for remote raw downloads (default: main)
  -h, --help           Show this help message
EOF
}

sha256_stdin_lf() {
  if command -v sha256sum >/dev/null 2>&1; then
    tr -d '\r' | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    tr -d '\r' | shasum -a 256 | awk '{print $1}'
  else
    echo "Error: neither sha256sum nor shasum is available." >&2
    exit 1
  fi
}

inspect_markers() {
  local file="$1"
  awk -v start_m="$START_MARKER" -v end_m="$END_MARKER" '
    BEGIN { content = "" }
    {
      gsub(/\r/, "", $0)
      content = content (NR > 1 ? "\n" : "") $0
    }
    END {
      sc = 0; sp = 0; rest = content; offset = 0
      while ((idx = index(rest, start_m)) > 0) {
        sc++
        if (sc == 1) sp = offset + idx
        adv = idx + length(start_m) - 1
        offset += adv
        rest = substr(rest, adv + 1)
      }
      ec = 0; ep = 0; rest = content; offset = 0
      while ((idx = index(rest, end_m)) > 0) {
        ec++
        if (ec == 1) ep = offset + idx
        adv = idx + length(end_m) - 1
        offset += adv
        rest = substr(rest, adv + 1)
      }
      print sc, ec, sp, ep
    }
  ' "$file"
}

validate_markers_strict() {
  local file="$1"
  local sc ec sp ep
  read -r sc ec sp ep < <(inspect_markers "$file")
  if [[ "$sc" -eq 0 && "$ec" -eq 0 ]]; then
    echo "none"
    return 0
  elif [[ "$sc" -eq 1 && "$ec" -eq 1 && "$sp" -lt "$ep" ]]; then
    echo "present"
    return 0
  else
    echo "Error: Malformed delegation markers in $file (start_count=$sc, end_count=$ec, start_pos=$sp, end_pos=$ep). Aborting without modifying GEMINI.md." >&2
    exit 1
  fi
}

extract_block_lf() {
  local file="$1"
  awk -v start_m="$START_MARKER" -v end_m="$END_MARKER" '
    BEGIN { content = "" }
    {
      gsub(/\r/, "", $0)
      content = content (NR > 1 ? "\n" : "") $0
    }
    END {
      sp = index(content, start_m)
      ep = index(content, end_m)
      if (sp > 0 && ep > sp) {
        printf "%s", substr(content, sp, (ep + length(end_m)) - sp)
      }
    }
  ' "$file"
}

atomic_write_from_stdin() {
  local target="$1"
  local target_dir tmp_file
  target_dir="$(dirname "$target")"
  mkdir -p "$target_dir"
  tmp_file="$(mktemp "${target}.tmp.XXXXXX")"
  cat > "$tmp_file"
  mv -f "$tmp_file" "$target"
}

backup_gemini_md() {
  local gemini_md="$1"
  local backup_dir="$2"
  local stamp backup_path
  mkdir -p "$backup_dir"
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_path="${backup_dir}/GEMINI.md.bak-${stamp}"
  cp -p "$gemini_md" "$backup_path"
  echo "BACKUP  : $backup_path"
}

validate_payloads() {
  local block_file="$1"
  local skill_file="$2"
  local audit_file="$3"

  if [[ ! -s "$block_file" ]]; then
    echo "Error: Downloaded/local delegation-block.md is empty." >&2
    exit 1
  fi
  if [[ ! -s "$skill_file" ]]; then
    echo "Error: Downloaded/local swarm-delegation/SKILL.md is empty." >&2
    exit 1
  fi
  if [[ ! -s "$audit_file" ]]; then
    echo "Error: Downloaded/local swarm-audit/SKILL.md is empty." >&2
    exit 1
  fi

  local sc ec sp ep
  read -r sc ec sp ep < <(inspect_markers "$block_file")
  if [[ "$sc" -ne 1 || "$ec" -ne 1 || "$sp" -ge "$ep" ]]; then
    echo "Error: Invalid delegation-block.md payload (markers missing or malformed)." >&2
    exit 1
  fi

  if ! grep -q "name: swarm-delegation" "$skill_file"; then
    echo "Error: Invalid swarm-delegation/SKILL.md payload (missing 'name: swarm-delegation')." >&2
    exit 1
  fi
  if ! grep -q "name: swarm-audit" "$audit_file"; then
    echo "Error: Invalid swarm-audit/SKILL.md payload (missing 'name: swarm-audit')." >&2
    exit 1
  fi
}

resolve_sources() {
  local ref="$1"
  local with_hooks="${2:-0}"
  local script_dir=""
  if [[ -z "${AGY_RAW_BASE:-}" && -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  if [[ -n "$script_dir" && -f "${script_dir}/rules/delegation-block.md" && -f "${script_dir}/skills/swarm-delegation/SKILL.md" && -f "${script_dir}/skills/swarm-audit/SKILL.md" ]]; then
    BLOCK_SRC="${script_dir}/rules/delegation-block.md"
    SKILL_SRC="${script_dir}/skills/swarm-delegation/SKILL.md"
    AUDIT_SRC="${script_dir}/skills/swarm-audit/SKILL.md"
    if [[ "$with_hooks" -eq 1 ]]; then
      HOOK_CLASSIFIER_SRC="${script_dir}/extras/hooks/agy-role-classifier.js"
      HOOK_DELEG_SRC="${script_dir}/extras/hooks/agy-delegation-gate.js"
      HOOK_STOP_SRC="${script_dir}/extras/hooks/agy-stop-gate.js"
      HOOK_DOCTOR_SRC="${script_dir}/extras/hooks/agy-gate-doctor.mjs"
    fi
  else
    TMP_DIR="$(mktemp -d)"
    local base_url="${AGY_RAW_BASE:-https://raw.githubusercontent.com/${REPO_SLUG}/${ref}}"
    base_url="${base_url%/}"
    BLOCK_SRC="${TMP_DIR}/delegation-block.md"
    SKILL_SRC="${TMP_DIR}/swarm-delegation-SKILL.md"
    AUDIT_SRC="${TMP_DIR}/swarm-audit-SKILL.md"
    curl -fsSL "${base_url}/rules/delegation-block.md" -o "$BLOCK_SRC"
    curl -fsSL "${base_url}/skills/swarm-delegation/SKILL.md" -o "$SKILL_SRC"
    curl -fsSL "${base_url}/skills/swarm-audit/SKILL.md" -o "$AUDIT_SRC"
    if [[ "$with_hooks" -eq 1 ]]; then
      HOOK_CLASSIFIER_SRC="${TMP_DIR}/agy-role-classifier.js"
      HOOK_DELEG_SRC="${TMP_DIR}/agy-delegation-gate.js"
      HOOK_STOP_SRC="${TMP_DIR}/agy-stop-gate.js"
      HOOK_DOCTOR_SRC="${TMP_DIR}/agy-gate-doctor.mjs"
      curl -fsSL "${base_url}/extras/hooks/agy-role-classifier.js" -o "$HOOK_CLASSIFIER_SRC"
      curl -fsSL "${base_url}/extras/hooks/agy-delegation-gate.js" -o "$HOOK_DELEG_SRC"
      curl -fsSL "${base_url}/extras/hooks/agy-stop-gate.js" -o "$HOOK_STOP_SRC"
      curl -fsSL "${base_url}/extras/hooks/agy-gate-doctor.mjs" -o "$HOOK_DOCTOR_SRC"
    fi
  fi

  validate_payloads "$BLOCK_SRC" "$SKILL_SRC" "$AUDIT_SRC"
}

verify_skill_file() {
  local label="$1"
  local src="$2"
  local dst="$3"
  local expected_hash actual_hash
  expected_hash="$(sha256_stdin_lf < "$src")"
  if [[ ! -f "$dst" ]]; then
    echo "MISSING : $dst"
    return 1
  fi
  actual_hash="$(sha256_stdin_lf < "$dst")"
  if [[ "$expected_hash" == "$actual_hash" ]]; then
    echo "MATCH   : $label ($actual_hash)"
    return 0
  else
    echo "MISMATCH: $label (expected=$expected_hash live=$actual_hash)"
    return 1
  fi
}

do_verify() {
  local gemini_md="$1"
  local skill_dst="$2"
  local audit_dst="$3"
  local with_hooks="${4:-0}"
  local gemini_dir
  gemini_dir="$(dirname "$gemini_md")"
  local ok=0

  local expected_block_hash actual_block_hash
  expected_block_hash="$(extract_block_lf "$BLOCK_SRC" | sha256_stdin_lf)"

  if [[ ! -f "$gemini_md" ]]; then
    echo "MISSING : $gemini_md"
    ok=1
  else
    local state
    state="$(validate_markers_strict "$gemini_md")"
    if [[ "$state" == "none" ]]; then
      echo "MISSING : delegation block in $gemini_md"
      ok=1
    else
      actual_block_hash="$(extract_block_lf "$gemini_md" | sha256_stdin_lf)"
      if [[ "$expected_block_hash" == "$actual_block_hash" ]]; then
        echo "MATCH   : GEMINI.md delegation block ($actual_block_hash)"
      else
        echo "MISMATCH: GEMINI.md delegation block (expected=$expected_block_hash live=$actual_block_hash)"
        ok=1
      fi
    fi
  fi

  verify_skill_file "skills/swarm-delegation/SKILL.md" "$SKILL_SRC" "$skill_dst" || ok=1
  verify_skill_file "skills/swarm-audit/SKILL.md" "$AUDIT_SRC" "$audit_dst" || ok=1

  if [[ "$with_hooks" -eq 1 ]]; then
    local hooks_dir="${gemini_dir}/hooks"
    verify_skill_file "hooks/agy-role-classifier.js" "$HOOK_CLASSIFIER_SRC" "${hooks_dir}/agy-role-classifier.js" || ok=1
    verify_skill_file "hooks/agy-delegation-gate.js" "$HOOK_DELEG_SRC" "${hooks_dir}/agy-delegation-gate.js" || ok=1
    verify_skill_file "hooks/agy-stop-gate.js" "$HOOK_STOP_SRC" "${hooks_dir}/agy-stop-gate.js" || ok=1
    verify_skill_file "hooks/agy-gate-doctor.mjs" "$HOOK_DOCTOR_SRC" "${hooks_dir}/agy-gate-doctor.mjs" || ok=1
    local hooks_json="${gemini_dir}/hooks.json"
    if [[ ! -f "$hooks_json" ]]; then
      echo "MISSING : $hooks_json"
      ok=1
    elif command -v node >/dev/null 2>&1; then
      if node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(!j["agy-delegation-gate"]||!j["agy-stop-gate"])process.exit(1);' "$hooks_json"; then
        echo "MATCH   : hooks.json (agy-delegation-gate, agy-stop-gate)"
      else
        echo "MISMATCH: hooks.json missing agy-delegation-gate or agy-stop-gate"
        ok=1
      fi
    fi
  fi

  return "$ok"
}

install_skill_file() {
  local src="$1"
  local dst="$2"
  local needs_write=1
  mkdir -p "$(dirname "$dst")"
  if [[ -f "$dst" ]]; then
    local exp_h live_h
    exp_h="$(sha256_stdin_lf < "$src")"
    live_h="$(sha256_stdin_lf < "$dst")"
    if [[ "$exp_h" == "$live_h" ]]; then
      needs_write=0
    fi
  fi
  if [[ "$needs_write" -eq 1 ]]; then
    tr -d '\r' < "$src" | atomic_write_from_stdin "$dst"
  fi
}

install_hooks() {
  local gemini_dir="$1"
  local backup_dir="${gemini_dir}/backups"
  local hooks_dir="${gemini_dir}/hooks"
  local hooks_json="${gemini_dir}/hooks.json"

  if ! command -v node >/dev/null 2>&1; then
    echo "WARNING : node not found in PATH; skipping hooks installation." >&2
    return 1
  fi

  local node_bin
  node_bin="$(node -e 'console.log(process.execPath)')"

  install_skill_file "$HOOK_CLASSIFIER_SRC" "${hooks_dir}/agy-role-classifier.js"
  install_skill_file "$HOOK_DELEG_SRC" "${hooks_dir}/agy-delegation-gate.js"
  install_skill_file "$HOOK_STOP_SRC" "${hooks_dir}/agy-stop-gate.js"
  install_skill_file "$HOOK_DOCTOR_SRC" "${hooks_dir}/agy-gate-doctor.mjs"

  if [[ -f "$hooks_json" ]]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    cp -p "$hooks_json" "${backup_dir}/hooks.json.bak-${stamp}"
    echo "BACKUP  : ${backup_dir}/hooks.json.bak-${stamp}"
  fi

  local tmp_hooks
  tmp_hooks="$(mktemp "${hooks_json}.tmp.XXXXXX")"
  node -e '
    const fs = require("fs");
    const path = require("path");
    const [hooksJsonPath, tmpPath, nodeBin, hooksDir] = process.argv.slice(1);
    const nativeHooksDir = path.resolve(hooksDir);
    let data = {};
    if (fs.existsSync(hooksJsonPath)) {
      const raw = fs.readFileSync(hooksJsonPath, "utf8").trim();
      if (raw) data = JSON.parse(raw);
    }
    data["agy-delegation-gate"] = {
      PreToolUse: [{
        matcher: "*",
        hooks: [{
          type: "command",
          command: `"${nodeBin}" "${path.join(nativeHooksDir, "agy-delegation-gate.js")}"`,
          timeout: 5
        }]
      }]
    };
    data["agy-stop-gate"] = {
      Stop: [{
        type: "command",
        command: `"${nodeBin}" "${path.join(nativeHooksDir, "agy-stop-gate.js")}"`,
        timeout: 10
      }]
    };
    fs.writeFileSync(tmpPath, JSON.stringify(data, null, 2) + "\n", "utf8");
  ' "$hooks_json" "$tmp_hooks" "$node_bin" "$hooks_dir"
  mv -f "$tmp_hooks" "$hooks_json"
  echo "UPDATED : $hooks_json (merged agy-delegation-gate, agy-stop-gate)"
  return 0
}

do_install() {
  local gemini_dir="$1"
  local with_hooks="${2:-0}"
  local gemini_md="${gemini_dir}/GEMINI.md"
  local backup_dir="${gemini_dir}/backups"
  local skill_dst="${gemini_dir}/config/skills/swarm-delegation/SKILL.md"
  local audit_dst="${gemini_dir}/config/skills/swarm-audit/SKILL.md"

  mkdir -p "$gemini_dir"

  local canonical_block
  canonical_block="$(extract_block_lf "$BLOCK_SRC")"

  if [[ ! -f "$gemini_md" ]]; then
    printf '%s\n' "$canonical_block" | atomic_write_from_stdin "$gemini_md"
  else
    local state
    state="$(validate_markers_strict "$gemini_md")"
    if [[ "$state" == "none" ]]; then
      backup_gemini_md "$gemini_md" "$backup_dir"
      {
        tr -d '\r' < "$gemini_md" | awk '
          { lines[NR] = $0 }
          END {
            last = NR
            while (last > 0 && lines[last] == "") last--
            for (i = 1; i <= last; i++) print lines[i]
            if (last > 0) print ""
          }
        '
        printf '%s\n' "$canonical_block"
      } | atomic_write_from_stdin "$gemini_md"
    else
      local expected_hash live_hash
      expected_hash="$(printf '%s' "$canonical_block" | sha256_stdin_lf)"
      live_hash="$(extract_block_lf "$gemini_md" | sha256_stdin_lf)"
      if [[ "$expected_hash" != "$live_hash" ]]; then
        backup_gemini_md "$gemini_md" "$backup_dir"
        REPL_BLOCK="$canonical_block" awk -v start_m="$START_MARKER" -v end_m="$END_MARKER" '
          BEGIN { content = ""; repl = ENVIRON["REPL_BLOCK"] }
          {
            gsub(/\r/, "", $0)
            content = content (NR > 1 ? "\n" : "") $0
          }
          END {
            sp = index(content, start_m)
            ep = index(content, end_m)
            before = substr(content, 1, sp - 1)
            after  = substr(content, ep + length(end_m))
            printf "%s%s%s\n", before, repl, after
          }
        ' "$gemini_md" | atomic_write_from_stdin "$gemini_md"
      fi
    fi
  fi

  install_skill_file "$SKILL_SRC" "$skill_dst"
  install_skill_file "$AUDIT_SRC" "$audit_dst"

  local verify_hooks=0
  if [[ "$with_hooks" -eq 1 ]]; then
    if install_hooks "$gemini_dir"; then
      verify_hooks=1
    fi
  fi

  do_verify "$gemini_md" "$skill_dst" "$audit_dst" "$verify_hooks"
}

remove_skill_file() {
  local dst="$1"
  if [[ -f "$dst" ]]; then
    rm -f "$dst"
    rmdir "$(dirname "$dst")" 2>/dev/null || true
    echo "REMOVED : $dst"
  fi
}

do_uninstall() {
  local gemini_dir="$1"
  local gemini_md="${gemini_dir}/GEMINI.md"
  local backup_dir="${gemini_dir}/backups"
  local skill_dst="${gemini_dir}/config/skills/swarm-delegation/SKILL.md"
  local audit_dst="${gemini_dir}/config/skills/swarm-audit/SKILL.md"

  if [[ -f "$gemini_md" ]]; then
    local state
    state="$(validate_markers_strict "$gemini_md")"
    if [[ "$state" == "present" ]]; then
      backup_gemini_md "$gemini_md" "$backup_dir"
      local remaining
      remaining="$(awk -v start_m="$START_MARKER" -v end_m="$END_MARKER" '
        BEGIN { content = "" }
        {
          gsub(/\r/, "", $0)
          content = content (NR > 1 ? "\n" : "") $0
        }
        END {
          sp = index(content, start_m)
          ep = index(content, end_m)
          before = substr(content, 1, sp - 1)
          after  = substr(content, ep + length(end_m))
          sub(/\n+$/, "", before)
          sub(/^\n+/, "", after)
          if (before != "" && after != "") {
            printf "%s\n\n%s\n", before, after
          } else if (before != "") {
            printf "%s\n", before
          } else if (after != "") {
            printf "%s\n", after
          }
        }
      ' "$gemini_md")"
      if [[ -z "${remaining//[[:space:]]/}" ]]; then
        rm -f "$gemini_md"
        echo "REMOVED : $gemini_md (empty after removing delegation block)"
      else
        printf '%s\n' "$remaining" | atomic_write_from_stdin "$gemini_md"
        echo "UPDATED : $gemini_md (delegation block removed)"
      fi
    fi
  fi

  remove_skill_file "$skill_dst"
  remove_skill_file "$audit_dst"

  local hooks_dir="${gemini_dir}/hooks"
  local hooks_json="${gemini_dir}/hooks.json"
  local gate_cache="${gemini_dir}/agy-gate"

  if [[ -f "$hooks_json" ]]; then
    if command -v node >/dev/null 2>&1; then
      local has_keys
      has_keys="$(node -e 'const fs=require("fs");try{const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));console.log((j["agy-delegation-gate"]||j["agy-stop-gate"])?"1":"0");}catch(_){console.log("0");}' "$hooks_json")"
      if [[ "$has_keys" == "1" ]]; then
        local stamp
        stamp="$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$backup_dir"
        cp -p "$hooks_json" "${backup_dir}/hooks.json.bak-${stamp}"
        echo "BACKUP  : ${backup_dir}/hooks.json.bak-${stamp}"
        local tmp_hooks
        tmp_hooks="$(mktemp "${hooks_json}.tmp.XXXXXX")"
        local remaining_keys
        remaining_keys="$(node -e '
          const fs = require("fs");
          const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
          delete j["agy-delegation-gate"];
          delete j["agy-stop-gate"];
          const keys = Object.keys(j);
          if (keys.length > 0) fs.writeFileSync(process.argv[2], JSON.stringify(j, null, 2) + "\n", "utf8");
          console.log(keys.length);
        ' "$hooks_json" "$tmp_hooks")"
        if [[ "$remaining_keys" -eq 0 ]]; then
          rm -f "$tmp_hooks" "$hooks_json"
          echo "REMOVED : $hooks_json (empty after removing agy hooks)"
        else
          mv -f "$tmp_hooks" "$hooks_json"
          echo "UPDATED : $hooks_json (removed agy-delegation-gate, agy-stop-gate)"
        fi
      fi
    else
      echo "WARNING : node not found in PATH; cannot remove agy-delegation-gate/agy-stop-gate from $hooks_json (dangling entries may remain)." >&2
    fi
  fi

  for hf in agy-role-classifier.js agy-delegation-gate.js agy-stop-gate.js agy-gate-doctor.mjs; do
    remove_skill_file "${hooks_dir}/${hf}"
  done
  if [[ -d "$gate_cache" ]]; then
    rm -rf "$gate_cache"
    echo "REMOVED : $gate_cache"
  fi
}

main() {
  local mode="install"
  local gemini_dir="${HOME}/.gemini"
  local ref="main"
  local with_hooks=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-hooks)
        with_hooks=1
        shift
        ;;
      --verify)
        if [[ "$mode" == "uninstall" ]]; then
          echo "Error: --verify and --uninstall are mutually exclusive." >&2
          exit 1
        fi
        mode="verify"
        shift
        ;;
      --uninstall)
        if [[ "$mode" == "verify" ]]; then
          echo "Error: --verify and --uninstall are mutually exclusive." >&2
          exit 1
        fi
        mode="uninstall"
        shift
        ;;
      --gemini-dir)
        [[ $# -ge 2 ]] || { echo "Error: --gemini-dir requires a value." >&2; exit 1; }
        gemini_dir="$2"
        shift 2
        ;;
      --gemini-dir=*)
        gemini_dir="${1#*=}"
        shift
        ;;
      --ref)
        [[ $# -ge 2 ]] || { echo "Error: --ref requires a value." >&2; exit 1; }
        ref="$2"
        shift 2
        ;;
      --ref=*)
        ref="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Error: Unknown option '$1'" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if [[ "$mode" == "uninstall" ]]; then
    do_uninstall "$gemini_dir"
    exit 0
  fi

  resolve_sources "$ref" "$with_hooks"
  if [[ "$mode" == "verify" ]]; then
    do_verify \
      "${gemini_dir}/GEMINI.md" \
      "${gemini_dir}/config/skills/swarm-delegation/SKILL.md" \
      "${gemini_dir}/config/skills/swarm-audit/SKILL.md" \
      "$with_hooks"
  else
    do_install "$gemini_dir" "$with_hooks"
  fi
}

main "$@"

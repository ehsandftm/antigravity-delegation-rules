#!/usr/bin/env bash
set -euo pipefail

TMP_DIR=""
START_MARKER="<!-- antigravity-delegation-rules:start -->"
END_MARKER="<!-- antigravity-delegation-rules:end -->"
REPO_SLUG="ehsandftm/antigravity-delegation-rules"
DEFAULT_SLOT_A="claude-opus-5-5-medium"
DEFAULT_SLOT_B="gemini-4-carbon-medium"
MODEL_ID_REGEX='^[a-zA-Z0-9][a-zA-Z0-9._-]*$'

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
  --checker-mode <single|dual>  Checker mode (default: dual, or interactive prompt)
  --slot-a-model <id>           Model ID for Slot A (checker-rN-a)
  --slot-b-model <id>           Model ID for Slot B (checker-rN-b, dual mode only)
  --non-interactive             Skip interactive prompts and use defaults/flags
  --dry-run                     Validate, render, and print LF SHA-256 hashes without writing files
  --with-hooks                  Opt-in: install pure-Node PreToolUse & Stop hooks into <gemini-dir>/hooks/ and merge hooks.json
  --verify                      Verify installed GEMINI.md block and SKILL.md files (and hooks if --with-hooks) against canonical SHA-256
  --uninstall                   Remove delegation block from GEMINI.md, installed skills, state file, and any installed agy hooks/cache
  --gemini-dir <path>           Target Antigravity directory (default: $HOME/.gemini)
  --ref <git-ref>               Git ref for remote raw downloads (default: main)
  -h, --help                    Show this help message
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

validate_model_id() {
  local model_id="$1"
  local label="$2"
  if [[ -z "$model_id" || ! "$model_id" =~ $MODEL_ID_REGEX ]]; then
    echo "Error: Invalid model ID for ${label}: '${model_id}'. Must match ${MODEL_ID_REGEX}." >&2
    exit 1
  fi
}

derive_low_model() {
  local model_id="$1"
  if [[ "$model_id" == *-medium ]]; then
    printf '%s-low' "${model_id%-medium}"
  else
    printf '%s' "$model_id"
  fi
}

prompt_read() {
  local prompt_text="$1"
  local var_name="$2"
  local val=""
  printf '%s' "$prompt_text" >&2
  if [[ -t 0 ]]; then
    read -r val || val=""
  else
    read -r val </dev/tty || val=""
  fi
  printf -v "$var_name" '%s' "$val"
}

read_model_choice() {
  local slot_label="$1"
  local default_num="$2"
  local out_var="$3"
  local choice="" custom=""
  local models=("claude-opus-5-5-medium" "gemini-4-carbon-medium" "gemini-4-argon-medium" "claude-sonnet-5-5-medium")

  while true; do
    echo "" >&2
    echo "Select model for ${slot_label} (default [${default_num}]):" >&2
    echo "  1) claude-opus-5-5-medium (smaller quota; best cross-family contrast)" >&2
    echo "  2) gemini-4-carbon-medium (larger Gemini quota pool)" >&2
    echo "  3) gemini-4-argon-medium (Gemini quota pool)" >&2
    echo "  4) claude-sonnet-5-5-medium (Claude quota pool)" >&2
    echo "  5) Custom model ID" >&2
    prompt_read "Enter choice [1-5] (default ${default_num}): " choice
    choice="${choice//[[:space:]]/}"
    if [[ -z "$choice" ]]; then
      printf -v "$out_var" '%s' "${models[$((default_num - 1))]}"
      return 0
    fi
    case "$choice" in
      1|2|3|4)
        printf -v "$out_var" '%s' "${models[$((choice - 1))]}"
        return 0
        ;;
      5)
        prompt_read "Enter custom model ID: " custom
        custom="${custom#"${custom%%[![:space:]]*}"}"
        custom="${custom%"${custom##*[![:space:]]}"}"
        if [[ -n "$custom" && "$custom" =~ $MODEL_ID_REGEX ]]; then
          printf -v "$out_var" '%s' "$custom"
          return 0
        fi
        echo "Invalid model ID. Must match ${MODEL_ID_REGEX}." >&2
        ;;
      *)
        echo "Invalid selection '${choice}'. Please enter 1-5." >&2
        ;;
    esac
  done
}

resolve_checker_config_interactive() {
  local raw_mode="" confirm=""
  echo "" >&2
  echo "=== Antigravity Delegation Rules v1.3 Setup ===" >&2
  echo "Step 1 — Checker Mode:" >&2
  echo "  [1] Dual-Checker (Recommended)" >&2
  echo "  [2] Single-Checker" >&2
  while true; do
    prompt_read "Select mode [1-2] (default 1): " raw_mode
    raw_mode="${raw_mode//[[:space:]]/}"
    if [[ -z "$raw_mode" || "$raw_mode" == "1" ]]; then
      CFG_MODE="dual"
      break
    elif [[ "$raw_mode" == "2" ]]; then
      CFG_MODE="single"
      break
    else
      echo "Invalid selection '${raw_mode}'. Please enter 1 or 2." >&2
    fi
  done

  echo "" >&2
  echo "Step 2 — Checker Model Selection:" >&2
  echo "Note: Claude Opus 5.5 has a smaller quota pool and hits rate limits faster than Gemini Carbon. In Dual-Checker mode, if one model hits quota/rate-limit, QA automatically continues with the surviving model." >&2

  read_model_choice "Slot A (checker-rN-a)" 1 CFG_SLOT_A
  CFG_SLOT_B=""
  if [[ "$CFG_MODE" == "dual" ]]; then
    while true; do
      read_model_choice "Slot B (checker-rN-b)" 2 CFG_SLOT_B
      if [[ "$CFG_SLOT_A" == "$CFG_SLOT_B" ]]; then
        echo "WARNING : Slot A and Slot B are both set to '${CFG_SLOT_A}'. Using the same model reduces cross-family independence." >&2
        prompt_read "Proceed with identical Slot A and Slot B models? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]]; then
          break
        fi
        continue
      fi
      break
    done
  fi
}

load_persisted_checker_config() {
  local gemini_dir="$1"
  local state_file="${gemini_dir}/config/agy-installer.json"
  if [[ ! -f "$state_file" ]]; then
    echo "WARNING : Legacy install detected (missing ${state_file}); using dual-checker defaults for verification." >&2
    CFG_MODE="dual"
    CFG_SLOT_A="$DEFAULT_SLOT_A"
    CFG_SLOT_B="$DEFAULT_SLOT_B"
    return 0
  fi

  local parsed
  parsed="$(awk '
    function skip_ws(str, pos,    c) {
      while (pos <= length(str)) {
        c = substr(str, pos, 1)
        if (c == " " || c == "\t" || c == "\n" || c == "\r") pos++
        else break
      }
      return pos
    }
    function parse_str(str, pos, out,    c, res, esc) {
      if (substr(str, pos, 1) != "\"") { out[2] = 0; return }
      pos++
      res = ""
      while (pos <= length(str)) {
        c = substr(str, pos, 1)
        if (c == "\"") {
          out[1] = res
          out[2] = pos + 1
          return
        }
        if (c == "\\") {
          pos++
          if (pos > length(str)) { out[2] = 0; return }
          esc = substr(str, pos, 1)
          if (esc == "\"" || esc == "\\" || esc == "/") res = res esc
          else if (esc == "b") res = res "\b"
          else if (esc == "f") res = res "\f"
          else if (esc == "n") res = res "\n"
          else if (esc == "r") res = res "\r"
          else if (esc == "t") res = res "\t"
          else if (esc == "u") {
            if (pos + 4 > length(str)) { out[2] = 0; return }
            if (substr(str, pos + 1, 4) !~ /^[0-9a-fA-F]{4}$/) { out[2] = 0; return }
            res = res "\\u" substr(str, pos + 1, 4)
            pos += 4
          } else { out[2] = 0; return }
        } else if (c == "\n" || c == "\r") {
          out[2] = 0; return
        } else {
          res = res c
        }
        pos++
      }
      out[2] = 0
    }
    BEGIN { content = "" }
    {
      gsub(/\r/, "", $0)
      content = content (NR > 1 ? "\n" : "") $0
    }
    END {
      if (NR == 0) { print "ERR|Empty state file."; exit }
      pos = skip_ws(content, 1)
      if (substr(content, pos, 1) != "{") { print "ERR|Expected JSON object."; exit }
      pos = skip_ws(content, pos + 1)
      if (substr(content, pos, 1) == "}") {
        pos = skip_ws(content, pos + 1)
        if (pos <= length(content)) { print "ERR|Trailing data after JSON object."; exit }
        print "ERR|Missing required key(s)."
        exit
      }
      while (1) {
        parse_str(content, pos, kout)
        if (kout[2] == 0) { print "ERR|Invalid JSON key."; exit }
        key = kout[1]
        pos = skip_ws(content, kout[2])
        if (substr(content, pos, 1) != ":") { print "ERR|Expected colon after key."; exit }
        pos = skip_ws(content, pos + 1)
        parse_str(content, pos, vout)
        if (vout[2] == 0) { print "ERR|Expected string value for key " key "."; exit }
        val = vout[1]
        if (index(val, "|") > 0 || index(val, "\n") > 0) { print "ERR|Invalid character in value for key " key "."; exit }
        if (key != "checkerMode" && key != "slotAModel" && key != "slotBModel") {
          print "ERR|Unknown key " key "."
          exit
        }
        if (seen[key]) { print "ERR|Duplicate key " key "."; exit }
        seen[key] = 1
        vals[key] = val
        pos = skip_ws(content, vout[2])
        c = substr(content, pos, 1)
        if (c == ",") {
          pos = skip_ws(content, pos + 1)
        } else if (c == "}") {
          pos = skip_ws(content, pos + 1)
          break
        } else {
          print "ERR|Expected comma or closing brace."
          exit
        }
      }
      if (pos <= length(content)) { print "ERR|Trailing data after JSON object."; exit }
      if (!seen["checkerMode"] || !seen["slotAModel"]) { print "ERR|Missing required key(s)."; exit }
      printf "OK|%s|%s|%s\n", vals["checkerMode"], vals["slotAModel"], (seen["slotBModel"] ? vals["slotBModel"] : "")
    }
  ' "$state_file")"

  local parse_status
  IFS='|' read -r parse_status CFG_MODE CFG_SLOT_A CFG_SLOT_B <<< "$parsed"
  if [[ "$parse_status" != "OK" ]]; then
    echo "Error: Invalid state in ${state_file}: ${CFG_MODE:-Failed to parse JSON.}" >&2
    exit 1
  fi
  if [[ "$CFG_MODE" != "single" && "$CFG_MODE" != "dual" ]]; then
    echo "Error: Invalid checkerMode '${CFG_MODE}' in ${state_file}." >&2
    exit 1
  fi
  validate_model_id "$CFG_SLOT_A" "${state_file}:slotAModel"
  if [[ "$CFG_MODE" == "dual" ]]; then
    validate_model_id "$CFG_SLOT_B" "${state_file}:slotBModel"
  elif [[ -n "$CFG_SLOT_B" ]]; then
    echo "Error: Invalid state in ${state_file}: slotBModel must be empty when checkerMode is single." >&2
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

render_template_file() {
  local src="$1"
  local dst="$2"
  awk '
    function replace_all(str, tok, val,    pos, out) {
      out = ""
      while ((pos = index(str, tok)) > 0) {
        out = out substr(str, 1, pos - 1) val
        str = substr(str, pos + length(tok))
      }
      return out str
    }
    BEGIN { content = "" }
    {
      gsub(/\r/, "", $0)
      content = content (NR > 1 ? "\n" : "") $0
    }
    END {
      content = replace_all(content, "{{AGY_QUOTA_POLICY_CLAUSE}}", ENVIRON["T_QUOTA"])
      content = replace_all(content, "{{AGY_PARTIAL_WAKEUP_CLAUSE}}", ENVIRON["T_PARTIAL"])
      content = replace_all(content, "{{AGY_CHECKER_ROLE_LINE}}", ENVIRON["T_ROLE"])
      content = replace_all(content, "{{AGY_CHECKER_MECE_CLAUSE}}", ENVIRON["T_MECE"])
      content = replace_all(content, "{{AGY_SLOT_MAPPING_LINE}}", ENVIRON["T_SLOTMAP"])
      content = replace_all(content, "{{AGY_TIER_R1_R3_LINES}}", ENVIRON["T_TIER"])
      printf "%s\n", content
    }
  ' "$src" > "$dst"
}

render_payloads() {
  if [[ -z "${TMP_DIR:-}" ]]; then
    TMP_DIR="$(mktemp -d)"
  fi

  local slot_a="$CFG_SLOT_A"
  local slot_a_low
  slot_a_low="$(derive_low_model "$slot_a")"
  local slot_b="$CFG_SLOT_B"
  local slot_b_low=""
  if [[ -n "$slot_b" ]]; then
    slot_b_low="$(derive_low_model "$slot_b")"
  fi

  local t_quota t_partial t_role t_mece t_slotmap t_tier
  if [[ "$CFG_MODE" == "dual" ]]; then
    t_quota='1-of-2 checker quota/rate-limit -> SINGLE_CHECKER_DEGRADED (kill rate-limited slot, stay degraded for round, cite verbatim 429/quota); 2-of-2 checkers or builder/bulk/Manager quota -> Hard Stop'
    t_partial=' On partial wakeup (1/2 checkers done), do NOT analyze or dispatch `builder`; wait until both finish (or surviving slot in SINGLE_CHECKER_DEGRADED).'
    t_role="- \`checker\`: Dual-Slot read-only QA (\`workspace=\"inherit\"\`, **NO nested \`checker -> scout\`**, **NO \`read_board\`**): Slot A \`checker-rN-a\` (\`${slot_a}\`, \`${slot_a_low}\` on eligible R2/R3) + Slot B \`checker-rN-b\` (\`${slot_b}\`, \`${slot_b_low}\` on eligible R2/R3)."
    t_mece='fresh dual-slot `checker-rN-{a|b}` (R1 dual, R2/R3 selective row-owner; kill after verdicts; Manager never self-overrides `B/M`)'
    t_slotmap="- **Dual-Checker Slot Mapping (SSOT):** Slot A = \`checker-rN-a\` (\`${slot_a}\` / \`${slot_a_low}\`), Slot B = \`checker-rN-b\` (\`${slot_b}\` / \`${slot_b_low}\`)."
    t_tier="  - **T1** (Fast-Path, no risk paths): Skip checker (optional 1x R1 Slot A \`${slot_a}\` for cross-family contrast with \`builder=hydrogen\`).
  - **T2** (Swarm-Path OR risk paths: \`auth\`, \`deletion\`, \`migrations\`, \`install scripts\`, \`hooks\`, \`CI\`, \`secrets\`):
    - **R1:** Always dual \`-medium\` (\`checker-r1-a\` + \`checker-r1-b\`) in parallel on full pack.
    - **R2 (Row-Owner Selective + Effort-Stepped):** Re-run each slot holding open \`B/M\` (\`-medium\` if \`Sev=B\`/\`CONTEST\`/\`OVERFLOW\`, \`-low\` if \`M\`-only without \`CONTEST\`); also re-run peer slot on delta if fix touches hunks outside failing anchors or T2 risk paths. If minting slot hits quota, dispatch surviving-slot \`-medium\` for those open rows on the same \`diff_sha256\`.
    - **R3 (Binary Closure):** Only slot(s) with open \`B/M\` (\`-low\`, or \`-medium\` for \`Sev=B/CONTEST\`; surviving-slot \`-medium\` if minting slot hit quota).
- **F17 Plan Audit (Optional):** For \`>= 5\` files, policy changes, or destructive schema/config changes, run 1-round dual \`checker-plan-a\` + \`checker-plan-b\` (\`[[AGY-ROLE:checker-plan round=1]]\`) before \`builder\`."
  else
    t_quota='Quota/Rate-Limit = Hard Stop (kill workers, save resume note, no auto-downgrade or retry-storms)'
    t_partial=''
    t_role="- \`checker\`: Read-only QA (\`workspace=\"inherit\"\`, **NO nested \`checker -> scout\`**, **NO \`read_board\`**): Slot A \`checker-rN-a\` (\`${slot_a}\`, \`${slot_a_low}\` on eligible R2/R3)."
    t_mece='fresh `checker-rN-a` (kill after verdict; Manager never self-overrides `B/M`)'
    t_slotmap="- **Checker Slot Mapping (SSOT):** Slot A = \`checker-rN-a\` (\`${slot_a}\` / \`${slot_a_low}\`)."
    t_tier="  - **T1** (Fast-Path, no risk paths): Skip checker (optional 1x R1 Slot A \`${slot_a}\`).
  - **T2** (Swarm-Path OR risk paths: \`auth\`, \`deletion\`, \`migrations\`, \`install scripts\`, \`hooks\`, \`CI\`, \`secrets\`):
    - **R1:** Single \`-medium\` (\`checker-r1-a\`) on full pack.
    - **R2 (Effort-Stepped):** Re-run \`checker-r2-a\` on open \`B/M\` + delta (\`-medium\` if \`Sev=B\`/\`CONTEST\`/\`OVERFLOW\`, \`-low\` if \`M\`-only without \`CONTEST\`).
    - **R3 (Binary Closure):** Re-run \`checker-r3-a\` on open \`B/M\` (\`-low\`, or \`-medium\` for \`Sev=B/CONTEST\`).
- **F17 Plan Audit (Optional):** For \`>= 5\` files, policy changes, or destructive schema/config changes, run 1-round \`checker-plan-a\` (\`[[AGY-ROLE:checker-plan round=1]]\`) before \`builder\`."
  fi

  local r_block="${TMP_DIR}/rendered-delegation-block.md"
  local r_skill="${TMP_DIR}/rendered-swarm-delegation.md"
  local r_audit="${TMP_DIR}/rendered-swarm-audit.md"

  T_QUOTA="$t_quota" T_PARTIAL="$t_partial" T_ROLE="$t_role" T_MECE="$t_mece" T_SLOTMAP="$t_slotmap" T_TIER="$t_tier" \
    render_template_file "$BLOCK_SRC" "$r_block"
  T_QUOTA="$t_quota" T_PARTIAL="$t_partial" T_ROLE="$t_role" T_MECE="$t_mece" T_SLOTMAP="$t_slotmap" T_TIER="$t_tier" \
    render_template_file "$SKILL_SRC" "$r_skill"
  awk '{sub(/\r$/,""); print}' "$AUDIT_SRC" > "$r_audit"

  BLOCK_SRC="$r_block"
  SKILL_SRC="$r_skill"
  AUDIT_SRC="$r_audit"

  local f max_l lc
  for pair in "${BLOCK_SRC}:36:rules/delegation-block.md" "${SKILL_SRC}:115:skills/swarm-delegation/SKILL.md" "${AUDIT_SRC}:85:skills/swarm-audit/SKILL.md"; do
    IFS=':' read -r f max_l label <<< "$pair"
    if grep -Eq '\{\{[^}]+\}\}' "$f"; then
      echo "Error: Unreplaced template token detected in rendered ${label}." >&2
      exit 1
    fi
    lc="$(wc -l < "$f" | tr -d '[:space:]')"
    if [[ "$lc" -gt "$max_l" ]]; then
      echo "Error: Rendered ${label} exceeds line cap (${lc} > ${max_l})." >&2
      exit 1
    fi
  done
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
  render_payloads
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
  local state_file="${gemini_dir}/config/agy-installer.json"

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

  printf '{\n  "checkerMode": "%s",\n  "slotAModel": "%s",\n  "slotBModel": "%s"\n}\n' \
    "$CFG_MODE" "$CFG_SLOT_A" "$CFG_SLOT_B" | atomic_write_from_stdin "$state_file"

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
  local state_file="${gemini_dir}/config/agy-installer.json"

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
  remove_skill_file "$state_file"

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
  local arg_mode=""
  local arg_slot_a=""
  local arg_slot_b=""
  local non_interactive=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-hooks)
        with_hooks=1
        shift
        ;;
      --verify)
        if [[ "$mode" != "install" && "$mode" != "verify" ]]; then
          echo "Error: --verify, --uninstall, and --dry-run are mutually exclusive." >&2
          exit 1
        fi
        mode="verify"
        shift
        ;;
      --uninstall)
        if [[ "$mode" != "install" && "$mode" != "uninstall" ]]; then
          echo "Error: --verify, --uninstall, and --dry-run are mutually exclusive." >&2
          exit 1
        fi
        mode="uninstall"
        shift
        ;;
      --dry-run)
        if [[ "$mode" != "install" && "$mode" != "dry-run" ]]; then
          echo "Error: --verify, --uninstall, and --dry-run are mutually exclusive." >&2
          exit 1
        fi
        mode="dry-run"
        shift
        ;;
      --non-interactive)
        non_interactive=1
        shift
        ;;
      --checker-mode)
        [[ $# -ge 2 ]] || { echo "Error: --checker-mode requires a value." >&2; exit 1; }
        arg_mode="$2"
        shift 2
        ;;
      --checker-mode=*)
        arg_mode="${1#*=}"
        shift
        ;;
      --slot-a-model)
        [[ $# -ge 2 ]] || { echo "Error: --slot-a-model requires a value." >&2; exit 1; }
        arg_slot_a="$2"
        shift 2
        ;;
      --slot-a-model=*)
        arg_slot_a="${1#*=}"
        shift
        ;;
      --slot-b-model)
        [[ $# -ge 2 ]] || { echo "Error: --slot-b-model requires a value." >&2; exit 1; }
        arg_slot_b="$2"
        shift 2
        ;;
      --slot-b-model=*)
        arg_slot_b="${1#*=}"
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

  if [[ -n "$arg_mode" && "$arg_mode" != "single" && "$arg_mode" != "dual" ]]; then
    echo "Error: --checker-mode must be 'single' or 'dual' (got '${arg_mode}')." >&2
    exit 1
  fi
  if [[ "$arg_mode" == "single" && -n "$arg_slot_b" ]]; then
    echo "Error: --slot-b-model cannot be used with --checker-mode single." >&2
    exit 1
  fi
  if [[ -n "$arg_slot_a" ]]; then
    validate_model_id "$arg_slot_a" "--slot-a-model"
  fi
  if [[ -n "$arg_slot_b" ]]; then
    validate_model_id "$arg_slot_b" "--slot-b-model"
  fi

  if [[ "$mode" == "uninstall" ]]; then
    do_uninstall "$gemini_dir"
    exit 0
  fi

  local has_checker_flags=0
  if [[ -n "$arg_mode" || -n "$arg_slot_a" || -n "$arg_slot_b" ]]; then
    has_checker_flags=1
  fi

  if [[ "$mode" == "verify" ]]; then
    if [[ "$has_checker_flags" -eq 1 ]]; then
      CFG_MODE="${arg_mode:-dual}"
      CFG_SLOT_A="${arg_slot_a:-$DEFAULT_SLOT_A}"
      if [[ "$CFG_MODE" == "dual" ]]; then
        CFG_SLOT_B="${arg_slot_b:-$DEFAULT_SLOT_B}"
      else
        CFG_SLOT_B=""
      fi
    else
      load_persisted_checker_config "$gemini_dir"
    fi
  else
    local has_tty=0
    if [[ -t 0 ]] || { [[ -t 1 ]] && ( : </dev/tty ) 2>/dev/null; }; then
      has_tty=1
    fi
    if [[ "$non_interactive" -eq 0 && -z "${CI:-}" && "$has_checker_flags" -eq 0 && "$has_tty" -eq 1 ]]; then
      resolve_checker_config_interactive
    else
      CFG_MODE="${arg_mode:-dual}"
      CFG_SLOT_A="${arg_slot_a:-$DEFAULT_SLOT_A}"
      if [[ "$CFG_MODE" == "dual" ]]; then
        CFG_SLOT_B="${arg_slot_b:-$DEFAULT_SLOT_B}"
        if [[ "$CFG_SLOT_A" == "$CFG_SLOT_B" ]]; then
          echo "WARNING : Slot A and Slot B are both set to '${CFG_SLOT_A}'. Proceeding in non-interactive mode." >&2
        fi
      else
        CFG_SLOT_B=""
      fi
    fi
  fi

  resolve_sources "$ref" "$with_hooks"

  if [[ "$mode" == "dry-run" ]]; then
    local block_hash skill_hash audit_hash
    block_hash="$(extract_block_lf "$BLOCK_SRC" | sha256_stdin_lf)"
    skill_hash="$(sha256_stdin_lf < "$SKILL_SRC")"
    audit_hash="$(sha256_stdin_lf < "$AUDIT_SRC")"
    echo "DRY-RUN : Target=${gemini_dir}"
    echo "MODE    : ${CFG_MODE} (SlotA=${CFG_SLOT_A}, SlotB=${CFG_SLOT_B})"
    echo "SHA256  : GEMINI.md block = ${block_hash} ($(wc -l < "$BLOCK_SRC" | tr -d '[:space:]')L)"
    echo "SHA256  : swarm-delegation/SKILL.md = ${skill_hash} ($(wc -l < "$SKILL_SRC" | tr -d '[:space:]')L)"
    echo "SHA256  : swarm-audit/SKILL.md = ${audit_hash} ($(wc -l < "$AUDIT_SRC" | tr -d '[:space:]')L)"
    exit 0
  fi

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

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
  --verify             Verify installed GEMINI.md block and SKILL.md against canonical SHA-256
  --uninstall          Remove delegation block from GEMINI.md and remove SKILL.md
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

  if [[ ! -s "$block_file" ]]; then
    echo "Error: Downloaded/local delegation-block.md is empty." >&2
    exit 1
  fi
  if [[ ! -s "$skill_file" ]]; then
    echo "Error: Downloaded/local SKILL.md is empty." >&2
    exit 1
  fi

  local sc ec sp ep
  read -r sc ec sp ep < <(inspect_markers "$block_file")
  if [[ "$sc" -ne 1 || "$ec" -ne 1 || "$sp" -ge "$ep" ]]; then
    echo "Error: Invalid delegation-block.md payload (markers missing or malformed)." >&2
    exit 1
  fi

  if ! grep -q "name: swarm-delegation" "$skill_file"; then
    echo "Error: Invalid SKILL.md payload (missing 'name: swarm-delegation')." >&2
    exit 1
  fi
}

resolve_sources() {
  local ref="$1"
  local script_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  if [[ -n "$script_dir" && -f "${script_dir}/rules/delegation-block.md" && -f "${script_dir}/skills/swarm-delegation/SKILL.md" ]]; then
    BLOCK_SRC="${script_dir}/rules/delegation-block.md"
    SKILL_SRC="${script_dir}/skills/swarm-delegation/SKILL.md"
  else
    TMP_DIR="$(mktemp -d)"
    local base_url="https://raw.githubusercontent.com/${REPO_SLUG}/${ref}"
    BLOCK_SRC="${TMP_DIR}/delegation-block.md"
    SKILL_SRC="${TMP_DIR}/SKILL.md"
    curl -fsSL "${base_url}/rules/delegation-block.md" -o "$BLOCK_SRC"
    curl -fsSL "${base_url}/skills/swarm-delegation/SKILL.md" -o "$SKILL_SRC"
  fi

  validate_payloads "$BLOCK_SRC" "$SKILL_SRC"
}

do_verify() {
  local gemini_md="$1"
  local skill_dst="$2"
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

  local expected_skill_hash actual_skill_hash
  expected_skill_hash="$(sha256_stdin_lf < "$SKILL_SRC")"
  if [[ ! -f "$skill_dst" ]]; then
    echo "MISSING : $skill_dst"
    ok=1
  else
    actual_skill_hash="$(sha256_stdin_lf < "$skill_dst")"
    if [[ "$expected_skill_hash" == "$actual_skill_hash" ]]; then
      echo "MATCH   : skills/swarm-delegation/SKILL.md ($actual_skill_hash)"
    else
      echo "MISMATCH: skills/swarm-delegation/SKILL.md (expected=$expected_skill_hash live=$actual_skill_hash)"
      ok=1
    fi
  fi

  return "$ok"
}

do_install() {
  local gemini_dir="$1"
  local gemini_md="${gemini_dir}/GEMINI.md"
  local backup_dir="${gemini_dir}/backups"
  local skill_dst="${gemini_dir}/config/skills/swarm-delegation/SKILL.md"

  mkdir -p "$gemini_dir" "$(dirname "$skill_dst")"

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

  local skill_needs_write=1
  if [[ -f "$skill_dst" ]]; then
    local exp_s live_s
    exp_s="$(sha256_stdin_lf < "$SKILL_SRC")"
    live_s="$(sha256_stdin_lf < "$skill_dst")"
    if [[ "$exp_s" == "$live_s" ]]; then
      skill_needs_write=0
    fi
  fi
  if [[ "$skill_needs_write" -eq 1 ]]; then
    tr -d '\r' < "$SKILL_SRC" | atomic_write_from_stdin "$skill_dst"
  fi

  do_verify "$gemini_md" "$skill_dst"
}

do_uninstall() {
  local gemini_dir="$1"
  local gemini_md="${gemini_dir}/GEMINI.md"
  local backup_dir="${gemini_dir}/backups"
  local skill_dst="${gemini_dir}/config/skills/swarm-delegation/SKILL.md"

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

  if [[ -f "$skill_dst" ]]; then
    rm -f "$skill_dst"
    rmdir "$(dirname "$skill_dst")" 2>/dev/null || true
    echo "REMOVED : $skill_dst"
  fi
}

main() {
  local mode="install"
  local gemini_dir="${HOME}/.gemini"
  local ref="main"

  while [[ $# -gt 0 ]]; do
    case "$1" in
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

  resolve_sources "$ref"
  if [[ "$mode" == "verify" ]]; then
    do_verify "${gemini_dir}/GEMINI.md" "${gemini_dir}/config/skills/swarm-delegation/SKILL.md"
  else
    do_install "$gemini_dir"
  fi
}

main "$@"

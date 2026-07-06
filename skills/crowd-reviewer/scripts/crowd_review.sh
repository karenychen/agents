#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: crowd_review.sh [options]

Run four Copilot CLI code reviewers in the current worktree and write one report
per model. This script does not create worktrees.

Options:
  --base REF        Base ref. Defaults to origin/HEAD, origin/main,
                    origin/master, main, or master.
  --run-dir DIR     Report directory. Defaults to
                    ./tmp/crowd-reviewer/<timestamp>.
  --timeout-seconds N
                    Per-reviewer timeout. Defaults to
                    CROWD_REVIEWER_TIMEOUT_SECONDS or 300.
  --dry-run         Write prompts without invoking Copilot.
  -h, --help        Show this help.

Model overrides:
  CROWD_REVIEWER_MODEL_CLAUDE_OPUS
  CROWD_REVIEWER_MODEL_CLAUDE_SONNET
  CROWD_REVIEWER_MODEL_GEMINI
  CROWD_REVIEWER_MODEL_GPT
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_positive_integer() {
  local name="$1"
  local value="$2"
  case "$value" in
    ''|*[!0-9]*)
      die "$name must be a positive integer (got: $value)"
      ;;
  esac
  if [ "$value" -le 0 ]; then
    die "$name must be a positive integer (got: $value)"
  fi
}

detect_base_ref() {
  local origin_head
  origin_head=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$origin_head" ] && git rev-parse --verify "${origin_head}^{commit}" >/dev/null 2>&1; then
    printf '%s\n' "$origin_head"
    return
  fi

  local candidate
  for candidate in origin/main origin/master main master; do
    if git rev-parse --verify "${candidate}^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  die "Could not detect a base ref. Pass --base <ref>."
}

model_catalog() {
  copilot help config 2>/dev/null |
    sed -n 's/^[[:space:]]*- "\([^"]*\)".*/\1/p'
}

first_catalog_match() {
  local pattern="$1"
  model_catalog | awk -v pattern="$pattern" '$0 ~ pattern { print; exit }'
}

select_model() {
  local env_name="$1"
  local pattern="$2"
  local fallback="$3"
  local override="${!env_name:-}"

  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return
  fi

  local selected
  selected=$(first_catalog_match "$pattern")
  if [ -n "$selected" ]; then
    printf '%s\n' "$selected"
    return
  fi

  printf '%s\n' "$fallback"
}

main() {
  local base_ref=""
  local run_dir=""
  local dry_run=0
  local timeout_seconds="${CROWD_REVIEWER_TIMEOUT_SECONDS:-300}"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base)
        [ "$#" -ge 2 ] || die "--base requires a value"
        base_ref="$2"
        shift 2
        ;;
      --run-dir)
        [ "$#" -ge 2 ] || die "--run-dir requires a value"
        run_dir="$2"
        shift 2
        ;;
      --timeout-seconds)
        [ "$#" -ge 2 ] || die "--timeout-seconds requires a value"
        timeout_seconds="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  require_command git
  require_command copilot
  validate_positive_integer "timeout_seconds" "$timeout_seconds"

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die "Run this script inside a git repository."
  cd "$repo_root"

  if [ -z "$base_ref" ]; then
    base_ref=$(detect_base_ref)
  fi
  git rev-parse --verify "${base_ref}^{commit}" >/dev/null 2>&1 || die "Base ref not found: $base_ref"

  if [ -z "$run_dir" ]; then
    run_dir="./tmp/crowd-reviewer/$(date +%Y%m%d-%H%M%S)"
  fi
  mkdir -p "$run_dir"

  local script_dir single_script
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  single_script=$(cd "$script_dir/../../copilot-reviewer/scripts" && pwd)/copilot_review.sh
  [ -x "$single_script" ] || die "Single-model reviewer script not executable: $single_script"

  local claude_opus claude_sonnet gemini gpt
  claude_opus=$(select_model CROWD_REVIEWER_MODEL_CLAUDE_OPUS '^claude-opus-' 'claude-opus-4.8')
  claude_sonnet=$(select_model CROWD_REVIEWER_MODEL_CLAUDE_SONNET '^claude-sonnet-' 'claude-sonnet-4.6')
  gemini=$(select_model CROWD_REVIEWER_MODEL_GEMINI '^gemini-' 'gemini-3.1-pro-preview')
  gpt=$(select_model CROWD_REVIEWER_MODEL_GPT '^gpt-' 'gpt-5.5')

  cat >"$run_dir/metadata.md" <<METADATA
# Crowd Review Run

Repository: \`$repo_root\`
Base ref: \`$base_ref\`
Generated: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`
Worktree creation: none; all reviewers ran in this checkout.

Reports:
- Claude Opus: \`review_report_claude-opus.md\` (\`$claude_opus\`)
- Claude Sonnet: \`review_report_claude-sonnet.md\` (\`$claude_sonnet\`)
- Gemini: \`review_report_gemini.md\` (\`$gemini\`)
- GPT: \`review_report_gpt.md\` (\`$gpt\`)

Manager instructions:
- Read every report.
- Verify each finding against the code.
- Ignore unverified or low-signal feedback.
- Synthesize final findings inline, then ask whether to post them.
METADATA

  local reviewers=(
    "Claude Opus|$claude_opus|review_report_claude-opus.md"
    "Claude Sonnet|$claude_sonnet|review_report_claude-sonnet.md"
    "Gemini|$gemini|review_report_gemini.md"
    "GPT|$gpt|review_report_gpt.md"
  )

  local entry name model model_and_report report_name report_path
  local pids=()
  local status=0
  for entry in "${reviewers[@]}"; do
    name=${entry%%|*}
    model_and_report=${entry#*|}
    model=${model_and_report%%|*}
    report_name=${entry##*|}
    report_path="$run_dir/$report_name"

    local args=(
      "$single_script"
      --name "$name"
      --model "$model"
      --base "$base_ref"
      --report "$report_path"
      --timeout-seconds "$timeout_seconds"
    )
    if [ "$dry_run" = "1" ]; then
      args+=(--dry-run)
    fi
    "${args[@]}" >/dev/null &
    pids+=("$!")
  done

  local pid
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      status=1
    fi
  done

  printf '%s\n' "$run_dir"
  return "$status"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: copilot_review.sh --model MODEL [options]

Run one read-only owner-style code review with GitHub Copilot CLI.

Options:
  --model MODEL       Copilot model id to use.
  --report FILE      Markdown report path to write. Defaults to
                     ./tmp/copilot-reviewer/<timestamp>/review_report_<model>.md.
  --name NAME        Reviewer display name. Defaults to MODEL.
  --base REF         Base ref. Defaults to origin/HEAD, origin/main,
                     origin/master, main, or master.
  --timeout-seconds N
                     Per-review timeout. Defaults to
                     COPILOT_REVIEWER_TIMEOUT_SECONDS or 300.
  --dry-run          Write the prompt without invoking Copilot.
  -h, --help         Show this help.
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

slugify() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//'
}

run_with_timeout() {
  local timeout_seconds="$1"
  local timed_out_file="$2"
  rm -f "$timed_out_file"
  shift 2

  "$@" &
  local child_pid=$!
  (
    sleep "$timeout_seconds"
    if kill -0 "$child_pid" 2>/dev/null; then
      printf '1\n' >"$timed_out_file"
      kill "$child_pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$child_pid" 2>/dev/null || true
    fi
  ) &
  local watchdog_pid=$!

  local status=0
  wait "$child_pid" || status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  if [ -s "$timed_out_file" ]; then
    rm -f "$timed_out_file"
    return 124
  fi
  rm -f "$timed_out_file"
  return "$status"
}

review_prompt() {
  local reviewer_name="$1"
  local model="$2"
  local base_ref="$3"
  local repo_root="$4"

  cat <<PROMPT
You are ${reviewer_name}, reviewing code like an owner.

Repository: ${repo_root}
Base ref: ${base_ref}
Model: ${model}

Rules:
- Do not edit files, create commits, change branches, push, or mutate the repo.
- Do not create plans, scratch files, session files, or reports.
- Run read-only shell commands one at a time. Avoid command chains and pipes.
- Focus on the diff against ${base_ref}; inspect call sites when needed.
- Prioritize correctness, security, behavior regressions, data loss,
  concurrency, compatibility, and missing tests.
- Ignore style-only feedback unless it hides a real risk.
- If you make a finding, include file:line, concrete scenario, and suggested fix.

Return exactly:
## Findings
- [severity] path:line - title
  Why this is a bug or risk:
  Reproduction or validation:
  Suggested fix:

## Test Coverage Gaps

## Notes
PROMPT
}

main() {
  local model=""
  local report=""
  local reviewer_name=""
  local base_ref=""
  local timeout_seconds="${COPILOT_REVIEWER_TIMEOUT_SECONDS:-300}"
  local dry_run=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --model)
        [ "$#" -ge 2 ] || die "--model requires a value"
        model="$2"
        shift 2
        ;;
      --report)
        [ "$#" -ge 2 ] || die "--report requires a value"
        report="$2"
        shift 2
        ;;
      --name)
        [ "$#" -ge 2 ] || die "--name requires a value"
        reviewer_name="$2"
        shift 2
        ;;
      --base)
        [ "$#" -ge 2 ] || die "--base requires a value"
        base_ref="$2"
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
  [ -n "$model" ] || die "--model is required"
  validate_positive_integer "timeout_seconds" "$timeout_seconds"

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die "Run this script inside a git repository."
  cd "$repo_root"

  if [ -z "$base_ref" ]; then
    base_ref=$(detect_base_ref)
  fi
  git rev-parse --verify "${base_ref}^{commit}" >/dev/null 2>&1 || die "Base ref not found: $base_ref"

  if [ -z "$reviewer_name" ]; then
    reviewer_name="$model"
  fi
  if [ -z "$report" ]; then
    report="./tmp/copilot-reviewer/$(date +%Y%m%d-%H%M%S)/review_report_$(slugify "$model").md"
  fi

  mkdir -p "$(dirname "$report")"

  local prompt
  prompt=$(review_prompt "$reviewer_name" "$model" "$base_ref" "$repo_root")
  local timed_out_file
  timed_out_file="$(dirname "$report")/.copilot-review-timeout.$$"

  {
    printf '# %s\n\n' "$reviewer_name"
    printf "Model: \`%s\`\n" "$model"
    printf "Base ref: \`%s\`\n" "$base_ref"
    printf "Generated: \`%s\`\n\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$report"

  if [ "$dry_run" = "1" ]; then
    {
      printf 'Dry run only. Prompt follows.\n\n'
      printf "\`\`\`text\n%s\n\`\`\`\n" "$prompt"
    } >>"$report"
    printf '%s\n' "$report"
    return 0
  fi

  local status=0
  run_with_timeout "$timeout_seconds" "$timed_out_file" \
    copilot \
    -C "$repo_root" \
    --model "$model" \
    --context long_context \
    --effort high \
    --no-ask-user \
    --no-auto-update \
    --disallow-temp-dir \
    --silent \
    --output-format text \
    --deny-tool=write \
    --allow-tool='shell(git status)' \
    --allow-tool='shell(git diff)' \
    --allow-tool='shell(git show)' \
    --allow-tool='shell(git log)' \
    --allow-tool='shell(git ls-files)' \
    --allow-tool='shell(git rev-parse)' \
    --allow-tool='shell(git merge-base)' \
    --allow-tool='shell(git grep)' \
    --allow-tool='shell(rg)' \
    --allow-tool='shell(sed)' \
    --allow-tool='shell(nl)' \
    --allow-tool='shell(head)' \
    --allow-tool='shell(tail)' \
    --allow-tool='shell(awk)' \
    --allow-tool='shell(cat)' \
    --allow-tool='shell(ls)' \
    --allow-tool='shell(find)' \
    -p "$prompt" >>"$report" || status=$?

  if [ "$status" -eq 124 ]; then
    printf '\nReviewer timed out after %s seconds.\n' "$timeout_seconds" >>"$report"
  elif [ "$status" -ne 0 ]; then
    printf '\nReviewer exited with status %s.\n' "$status" >>"$report"
  fi

  printf '%s\n' "$report"
  return "$status"
}

main "$@"

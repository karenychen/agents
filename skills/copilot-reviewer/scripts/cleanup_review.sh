#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: cleanup_review.sh [--run-dir DIR] [--worktree DIR] --yes

Clean up generated reviewer reports and/or a disposable PR review worktree.
Without --yes, the script only prints the planned cleanup.

Options:
  --run-dir DIR      Remove a generated report directory under
                     ./tmp/copilot-reviewer or ./tmp/crowd-reviewer.
                     Can be passed multiple times.
  --worktree DIR     Remove a disposable PR review worktree. Can be passed
                     multiple times.
  --yes              Actually remove the requested paths.
  -h, --help         Show this help.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

absolute_path() {
  local path="$1"
  local parent
  local name

  case "$path" in
    /*)
      printf '%s\n' "$path"
      ;;
    *)
      parent=$(dirname "$path")
      name=$(basename "$path")
      [ -d "$parent" ] || die "Parent directory not found: $parent"
      parent=$(cd "$parent" && pwd)
      printf '%s/%s\n' "$parent" "$name"
      ;;
  esac
}

has_review_artifacts() {
  local dir="$1"
  local reports

  if [ -f "$dir/metadata.md" ]; then
    return 0
  fi

  shopt -s nullglob
  reports=("$dir"/review_report_*.md)
  shopt -u nullglob
  [ "${#reports[@]}" -gt 0 ]
}

validate_run_dir() {
  local dir="$1"

  [ -d "$dir" ] || die "Report directory not found: $dir"
  case "$dir" in
    */tmp/copilot-reviewer/*|*/tmp/crowd-reviewer/*)
      ;;
    *)
      die "Refusing to remove non-review report directory: $dir"
      ;;
  esac
  has_review_artifacts "$dir" ||
    die "Refusing to remove directory without review artifacts: $dir"
}

main() {
  local confirmed=0
  local run_dirs=()
  local worktrees=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-dir)
        [ "$#" -ge 2 ] || die "--run-dir requires a value"
        run_dirs+=("$(absolute_path "$2")")
        shift 2
        ;;
      --worktree)
        [ "$#" -ge 2 ] || die "--worktree requires a value"
        worktrees+=("$(absolute_path "$2")")
        shift 2
        ;;
      --yes)
        confirmed=1
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

  [ "${#run_dirs[@]}" -gt 0 ] || [ "${#worktrees[@]}" -gt 0 ] ||
    die "Pass at least one --run-dir or --worktree."

  local run_dir
  for run_dir in "${run_dirs[@]}"; do
    validate_run_dir "$run_dir"
  done

  local worktree
  for worktree in "${worktrees[@]}"; do
    [ -d "$worktree" ] || die "Worktree directory not found: $worktree"
    git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
      die "Not a git worktree: $worktree"
  done

  printf 'Cleanup plan:\n'
  for run_dir in "${run_dirs[@]}"; do
    printf '  report directory: %s\n' "$run_dir"
  done
  for worktree in "${worktrees[@]}"; do
    printf '  worktree: %s\n' "$worktree"
  done

  if [ "$confirmed" != "1" ]; then
    printf '\nNo changes made. Re-run with --yes after confirmation.\n'
    return 0
  fi

  local script_dir
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

  for worktree in "${worktrees[@]}"; do
    "$script_dir/github_pr_target.sh" cleanup "$worktree"
  done

  for run_dir in "${run_dirs[@]}"; do
    if [ -e "$run_dir" ]; then
      rm -rf "$run_dir"
    fi
  done
}

main "$@"

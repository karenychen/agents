#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  github_pr_target.sh prepare PR_URL_OR_NUMBER [options]
  github_pr_target.sh cleanup WORKTREE_DIR

Prepare or remove a disposable GitHub PR review worktree.

Options for prepare:
  --repo OWNER/REPO       Required when PR is a number and the current
                          directory is not a GitHub checkout.
  --worktree-root DIR     Parent directory for the generated worktree.
                          Defaults to the parent of the current repo.
  --worktree-dir DIR      Exact worktree directory to create.
  --force                 Replace an existing generated worktree.
  -h, --help              Show this help.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

slugify() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//'
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
      mkdir -p "$parent"
      parent=$(cd "$parent" && pwd)
      printf '%s/%s\n' "$parent" "$name"
      ;;
  esac
}

parse_pr_ref() {
  local pr_ref="$1"
  local repo_arg="$2"

  if printf '%s\n' "$pr_ref" | grep -Eq '^https?://github\.com/[^/]+/[^/]+/pull/[0-9]+'; then
    printf '%s\n' "$pr_ref" |
      sed -E 's#^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+).*$#\1 \2 \3#'
    return
  fi

  if printf '%s\n' "$pr_ref" | grep -Eq '^[0-9]+$'; then
    if [ -z "$repo_arg" ]; then
      repo_arg=$(gh repo view --json nameWithOwner --jq '.nameWithOwner') ||
        die "Pass --repo OWNER/REPO when the current repo cannot be inferred."
    fi
    case "$repo_arg" in
      */*)
        printf '%s %s %s\n' "${repo_arg%%/*}" "${repo_arg#*/}" "$pr_ref"
        return
        ;;
    esac
  fi

  die "Expected a GitHub PR URL or number: $pr_ref"
}

fetch_pr_json() {
  local owner="$1"
  local repo="$2"
  local pr_number="$3"

  gh api "repos/$owner/$repo/pulls/$pr_number" ||
    die "Failed to fetch GitHub PR $owner/$repo#$pr_number"
}

json_field() {
  local jq_filter="$1"
  jq -r "$jq_filter"
}

current_github_repo() {
  gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true
}

remote_matches_repo() {
  local expected="$1"
  local expected_slug
  expected_slug=$(printf '%s\n' "$expected" | sed 's#/#[/:-]#')

  git remote -v |
    grep -E "github.com[:/]$expected_slug(\\.git)?([[:space:]]|$)" >/dev/null 2>&1
}

ensure_review_checkout() {
  local base_repo="$1"
  local head_repo="$2"
  local current_repo

  current_repo=$(current_github_repo)
  if [ "$current_repo" = "$base_repo" ] || [ "$current_repo" = "$head_repo" ]; then
    return
  fi
  if remote_matches_repo "$base_repo" || remote_matches_repo "$head_repo"; then
    return
  fi

  die "Run from a checkout of $base_repo or $head_repo before preparing this PR."
}

remove_existing_worktree() {
  local repo_root="$1"
  local worktree_dir="$2"

  if [ ! -e "$worktree_dir" ]; then
    return
  fi
  if ! git -C "$worktree_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "Refusing to replace non-worktree path: $worktree_dir"
  fi
  git -C "$repo_root" worktree remove --force "$worktree_dir" ||
    die "Failed to remove existing worktree: $worktree_dir"
}

write_metadata() {
  local metadata_path="$1"
  local pr_number="$2"
  local title="$3"
  local url="$4"
  local author="$5"
  local base_repo="$6"
  local base_ref="$7"
  local base_sha="$8"
  local head_repo="$9"
  local head_ref="${10}"
  local head_sha="${11}"
  local worktree_dir="${12}"
  local base_local_ref="${13}"
  local head_local_ref="${14}"
  local body="${15}"

  {
    printf '# GitHub PR %s\n\n' "$pr_number"
    printf '**Title:** %s\n' "$title"
    printf '**URL:** %s\n' "$url"
    printf '**Author:** %s\n' "$author"
    printf "**Base:** \`%s:%s\` (\`%s\`)\n" "$base_repo" "$base_ref" "$base_sha"
    printf "**Head:** \`%s:%s\` (\`%s\`)\n" "$head_repo" "$head_ref" "$head_sha"
    printf "**Worktree:** \`%s\`\n" "$worktree_dir"
    printf "**Base ref for review:** \`%s\`\n" "$base_local_ref"
    printf "**Head ref:** \`%s\`\n\n" "$head_local_ref"
    printf '## Description\n\n'
    printf '%s\n' "$body"
  } >"$metadata_path"
}

prepare_pr() {
  local pr_ref=""
  local repo_arg=""
  local worktree_root=""
  local worktree_dir=""
  local force=0

  [ "$#" -gt 0 ] || die "prepare requires a PR URL or number"
  pr_ref="$1"
  shift

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        [ "$#" -ge 2 ] || die "--repo requires a value"
        repo_arg="$2"
        shift 2
        ;;
      --worktree-root)
        [ "$#" -ge 2 ] || die "--worktree-root requires a value"
        worktree_root="$2"
        shift 2
        ;;
      --worktree-dir)
        [ "$#" -ge 2 ] || die "--worktree-dir requires a value"
        worktree_dir="$2"
        shift 2
        ;;
      --force)
        force=1
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
  require_command gh
  require_command jq

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) ||
    die "Run prepare from a local checkout of the repository being reviewed."
  repo_root=$(cd "$repo_root" && pwd)

  local parsed owner repo pr_number
  parsed=$(parse_pr_ref "$pr_ref" "$repo_arg")
  owner=$(printf '%s\n' "$parsed" | awk '{print $1}')
  repo=$(printf '%s\n' "$parsed" | awk '{print $2}')
  pr_number=$(printf '%s\n' "$parsed" | awk '{print $3}')

  local pr_json
  pr_json=$(fetch_pr_json "$owner" "$repo" "$pr_number")

  local title url author body
  local base_repo base_ref base_sha base_clone_url
  local head_repo head_ref head_sha head_clone_url
  title=$(printf '%s\n' "$pr_json" | json_field '.title // ""')
  url=$(printf '%s\n' "$pr_json" | json_field '.html_url // ""')
  author=$(printf '%s\n' "$pr_json" | json_field '.user.login // ""')
  body=$(printf '%s\n' "$pr_json" | json_field '.body // ""')
  base_repo=$(printf '%s\n' "$pr_json" | json_field '.base.repo.full_name')
  base_ref=$(printf '%s\n' "$pr_json" | json_field '.base.ref')
  base_sha=$(printf '%s\n' "$pr_json" | json_field '.base.sha')
  base_clone_url=$(printf '%s\n' "$pr_json" | json_field '.base.repo.clone_url')
  head_repo=$(printf '%s\n' "$pr_json" | json_field '.head.repo.full_name')
  head_ref=$(printf '%s\n' "$pr_json" | json_field '.head.ref')
  head_sha=$(printf '%s\n' "$pr_json" | json_field '.head.sha')
  head_clone_url=$(printf '%s\n' "$pr_json" | json_field '.head.repo.clone_url')

  ensure_review_checkout "$base_repo" "$head_repo"

  if [ -z "$worktree_dir" ]; then
    if [ -z "$worktree_root" ]; then
      worktree_root=$(dirname "$repo_root")
    fi
    worktree_root=$(absolute_path "$worktree_root")
    worktree_dir="$worktree_root/$(basename "$repo_root")-copilot-review-pr-$pr_number"
  else
    worktree_dir=$(absolute_path "$worktree_dir")
  fi

  if [ -e "$worktree_dir" ] && [ "$force" != "1" ]; then
    die "Worktree already exists: $worktree_dir. Pass --force or choose --worktree-dir."
  fi
  remove_existing_worktree "$repo_root" "$worktree_dir"

  local ref_slug base_local_ref head_local_ref
  ref_slug=$(slugify "$owner-$repo-pr-$pr_number")
  base_local_ref="refs/copilot-reviewer/$ref_slug/base"
  head_local_ref="refs/copilot-reviewer/$ref_slug/head"

  git -C "$repo_root" fetch --no-tags "$base_clone_url" "+refs/heads/$base_ref:$base_local_ref"
  git -C "$repo_root" fetch --no-tags "$head_clone_url" "+refs/heads/$head_ref:$head_local_ref"

  local fetched_base_sha fetched_head_sha
  fetched_base_sha=$(git -C "$repo_root" rev-parse "$base_local_ref^{commit}")
  fetched_head_sha=$(git -C "$repo_root" rev-parse "$head_local_ref^{commit}")
  [ "$fetched_base_sha" = "$base_sha" ] ||
    die "Fetched base SHA changed from $base_sha to $fetched_base_sha"
  [ "$fetched_head_sha" = "$head_sha" ] ||
    die "Fetched head SHA changed from $head_sha to $fetched_head_sha"

  git -C "$repo_root" worktree add --detach "$worktree_dir" "$head_local_ref"

  local target_dir metadata_path diff_path files_path
  target_dir="$worktree_dir/tmp/copilot-reviewer/github-pr-$pr_number"
  metadata_path="$target_dir/metadata.md"
  diff_path="$target_dir/diff.patch"
  files_path="$target_dir/files.txt"
  mkdir -p "$target_dir"

  git -C "$worktree_dir" diff "$base_local_ref...HEAD" >"$diff_path"
  git -C "$worktree_dir" diff --name-status "$base_local_ref...HEAD" >"$files_path"
  write_metadata \
    "$metadata_path" \
    "$pr_number" \
    "$title" \
    "$url" \
    "$author" \
    "$base_repo" \
    "$base_ref" \
    "$base_sha" \
    "$head_repo" \
    "$head_ref" \
    "$head_sha" \
    "$worktree_dir" \
    "$base_local_ref" \
    "$head_local_ref" \
    "$body"

  local script_dir single_script cleanup_script crowd_dir crowd_script
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  single_script="$script_dir/copilot_review.sh"
  cleanup_script="$script_dir/cleanup_review.sh"
  crowd_script=""
  if crowd_dir=$(cd "$script_dir/../../crowd-reviewer/scripts" 2>/dev/null && pwd); then
    crowd_script="$crowd_dir/crowd_review.sh"
  fi

  cat <<SUMMARY
Worktree: $worktree_dir
Base ref: $base_local_ref
Metadata: $metadata_path
Diff: $diff_path
Files: $files_path

Run single-model review:
  cd "$worktree_dir"
  "$single_script" --model gpt-5.5 --base "$base_local_ref"
SUMMARY

  if [ -x "$crowd_script" ]; then
    cat <<SUMMARY

Run crowd review:
  cd "$worktree_dir"
  # Run once; the dispatcher sends all models through this same worktree.
  "$crowd_script" --base "$base_local_ref"
SUMMARY
  fi

  cat <<SUMMARY
Cleanup:
  "$cleanup_script" --worktree "$worktree_dir" --yes
SUMMARY
}

cleanup_worktree() {
  [ "$#" -eq 1 ] || die "cleanup requires WORKTREE_DIR"
  require_command git

  local worktree_dir
  worktree_dir=$(absolute_path "$1")
  [ -d "$worktree_dir" ] || die "Worktree directory not found: $worktree_dir"
  git -C "$worktree_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "Not a git worktree: $worktree_dir"

  local cleanup_refs common_dir
  cleanup_refs=$(
    find "$worktree_dir/tmp/copilot-reviewer" -name metadata.md -type f -exec \
      awk -F'`' '/Base ref for review:/ { print $2 } /Head ref:/ { print $2 }' {} + \
      2>/dev/null || true
  )
  common_dir=$(git -C "$worktree_dir" rev-parse --path-format=absolute --git-common-dir)
  git --git-dir="$common_dir" worktree remove --force "$worktree_dir" ||
    die "Failed to remove worktree: $worktree_dir"
  printf '%s\n' "$cleanup_refs" |
    while IFS= read -r ref; do
      case "$ref" in
        refs/copilot-reviewer/*)
          git --git-dir="$common_dir" update-ref -d "$ref" 2>/dev/null || true
          ;;
      esac
    done
}

main() {
  local command="${1:-}"
  case "$command" in
    prepare)
      shift
      prepare_pr "$@"
      ;;
    cleanup)
      shift
      cleanup_worktree "$@"
      ;;
    -h|--help|"")
      usage
      ;;
    *)
      die "Unknown command: $command"
      ;;
  esac
}

main "$@"

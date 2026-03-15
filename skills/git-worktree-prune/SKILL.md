---
name: git-worktree-prune
description: >
  Scan and remove stale git worktrees whose PRs have already been merged.
  Run this automatically before creating any new worktree to keep the
  workspace clean. Works with both GitHub and Azure DevOps repositories.
allowed-tools:
  - bash
---

# Git Worktree Prune Skill

Automatically detect and remove git worktrees whose associated pull requests have been merged. Keeps the local workspace free of stale checkouts. Supports both **GitHub** and **Azure DevOps** repositories.

## When to Use

- **Before every `git worktree add`** — run this first to clean up merged worktrees.
- When the user asks to "clean up worktrees", "prune stale branches", or similar.
- During periodic workspace maintenance.

## Prerequisites

- Working directory inside a git repository (or provide the repo root path).
- **GitHub repos**: `gh` CLI authenticated with access to the repository.
- **ADO repos**: `az` CLI with the `azure-devops` extension, authenticated and with org/project configured (or detectable from git remote).

## Workflow

### Step 1 — Detect the remote type and repository identity

Inspect the `origin` remote URL to determine whether this is a GitHub or ADO repository:

```bash
REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)

if echo "$REMOTE_URL" | grep -qiE '(dev\.azure\.com|vs-ssh\.visualstudio\.com|\.visualstudio\.com)'; then
  REMOTE_TYPE="ado"
elif echo "$REMOTE_URL" | grep -qiE '(github\.com)'; then
  REMOTE_TYPE="github"
else
  echo "ERROR: Could not determine remote type from origin URL: $REMOTE_URL"
  exit 1
fi
```

For **GitHub**, resolve the owner/repo:

```bash
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
```

For **ADO**, the `az repos` commands auto-detect org/project/repo from git config when `--detect true` is used. No extra parsing needed.

### Step 2 — Scan and remove stale worktrees

Run this from the **main worktree** (repo root):

```bash
#!/usr/bin/env bash
set -euo pipefail

REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)

if echo "$REMOTE_URL" | grep -qiE '(dev\.azure\.com|vs-ssh\.visualstudio\.com|\.visualstudio\.com)'; then
  REMOTE_TYPE="ado"
elif echo "$REMOTE_URL" | grep -qiE '(github\.com)'; then
  REMOTE_TYPE="github"
  REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
else
  echo "ERROR: Could not determine remote type from origin URL: $REMOTE_URL"
  exit 1
fi

MAIN_WT="$(git rev-parse --show-toplevel)"

echo "=== Scanning for stale worktrees (type: ${REMOTE_TYPE}) ==="

# --- helper: check if a branch's PR has been merged ---
pr_is_merged() {
  local branch="$1"

  if [ "$REMOTE_TYPE" = "github" ]; then
    local state
    state=$(gh pr view "$branch" --repo "$REPO" --json state -q '.state' 2>/dev/null || true)
    [ "$state" = "MERGED" ]

  elif [ "$REMOTE_TYPE" = "ado" ]; then
    # az repos pr list returns completed PRs for the given source branch.
    # ADO "completed" status is the equivalent of GitHub "MERGED".
    local count
    count=$(az repos pr list \
      --source-branch "$branch" \
      --status completed \
      --detect true \
      --query 'length(@)' \
      --output tsv 2>/dev/null || echo "0")
    [ "$count" -gt 0 ]
  fi
}

git worktree list --porcelain | grep '^worktree ' | sed 's/^worktree //' | while read -r wt; do
  # Skip the main worktree
  [ "$wt" = "$MAIN_WT" ] && continue

  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  [ -z "$branch" ] && continue

  if pr_is_merged "$branch"; then
    echo "Removing: $wt (branch: $branch — PR merged)"
    git worktree remove "$wt" --force
    git branch -d "$branch" 2>/dev/null || true
  else
    echo "Keeping:  $wt (branch: $branch — no merged PR found)"
  fi
done

git worktree prune
echo "=== Cleanup complete ==="
```

### Step 3 — Confirm

After cleanup, list remaining worktrees to confirm:

```bash
git worktree list
```

## Notes

- **GitHub**: The script only removes worktrees whose PRs are in `MERGED` state. Open, closed-without-merge, and draft PRs are left intact.
- **ADO**: The script checks for PRs in `completed` status (ADO's equivalent of merged). Abandoned and active PRs are left intact.
- `git worktree prune` at the end cleans up any broken worktree references (e.g., manually deleted directories).
- Always run from the main worktree, not from inside a secondary worktree.
- The `--detect true` flag lets `az repos` auto-detect the ADO org, project, and repository from the local git remote — no manual configuration required.

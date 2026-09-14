---
name: copilot-reviewer
description: Run a single-model owner-style code review with GitHub Copilot CLI and write the raw report to a predictable local file. Use when asked to review local changes with one Copilot model, generate a single model's review report, or support a higher-level crowd review workflow.
---

# Copilot Reviewer

Run one Copilot CLI reviewer against a local git diff. Requires the `copilot`
CLI to be installed and authenticated.

# Step 1: Prepare Review Target

For a GitHub PR, prepare a disposable worktree from a local checkout of the PR's
base or head repository.

```bash
<skill-path>/scripts/github_pr_target.sh prepare https://github.com/OWNER/REPO/pull/123
cd <worktree-from-output>
```

For an already-prepared branch or worktree, run from that checkout. Confirm the
diff before dispatching the model.

```bash
command -v copilot
git status --short --branch
git diff --stat <base-ref>...HEAD
```

# Step 2: Single-Model Review

Write the raw report under repo-local `./tmp/` unless the caller provides a
specific path.

```bash
<skill-path>/scripts/copilot_review.sh \
  --model gpt-5.5 \
  --name "GPT" \
  --base <base-ref>
```

# Step 3: Manager Verification

Read the report. Treat it as evidence, not truth. Verify every finding against
the code before presenting it inline or posting it to a PR.

If the report timed out or exited non-zero, keep any partial output but call out
the incomplete coverage.

# Step 4: Clean Up

Ask before removing generated reports or disposable worktrees. For GitHub PR
worktrees or generated report directories created by this skill:

```bash
# Preview first.
<skill-path>/scripts/cleanup_review.sh --worktree <worktree>

# Run only after the user confirms.
<skill-path>/scripts/cleanup_review.sh --worktree <worktree> --yes
<skill-path>/scripts/cleanup_review.sh --run-dir ./tmp/copilot-reviewer/<run> --yes
```

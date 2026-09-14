---
name: crowd-reviewer
description: Run a multi-model owner-style code review by dispatching several GitHub Copilot CLI reviewers, then synthesize verified findings. Use when asked for a crowd review, multi-model review, owner review, adversarial review, or extra review pass on local code changes, a branch, or a pull request.
---

# Crowd Reviewer

Run several independent Copilot CLI reviewers, then act as the manager review
pass. Depends on `copilot-reviewer` and requires the `copilot` CLI.

# Step 1: Prepare Review Target

Use `copilot-reviewer` to prepare an isolated review target. For a GitHub PR,
prepare exactly one worktree for the PR, then run all model reviewers inside
that same worktree. Do not create one worktree per model.

```bash
<copilot-reviewer-path>/scripts/github_pr_target.sh prepare https://github.com/OWNER/REPO/pull/123
cd <worktree-from-output>
```

For an already-prepared branch or worktree, reuse it. Confirm the diff.

```bash
git status --short --branch
git diff --stat <base-ref>...HEAD
```

# Step 2: Subagent Reviews

Run the dispatcher once from the prepared checkout. It dispatches all four
models against the same `HEAD`, base ref, and working tree.

```bash
<skill-path>/scripts/crowd_review.sh --base <base-ref>
```

The default report directory is:

```text
./tmp/crowd-reviewer/<timestamp>/
```

The dispatcher writes:

- `metadata.md`
- `review_report_claude-opus.md`
- `review_report_claude-sonnet.md`
- `review_report_gemini.md`
- `review_report_gpt.md`

# Step 3: Manager Review

Read every report. Verify each issue against the actual code, call chain, and
tests. Ignore findings that are speculative, duplicated, style-only, or
unsupported.

Final response shape:

- Findings first, ordered by severity, with file:line and reproduction or
  validation steps when possible.
- Test coverage gaps.
- Brief model coverage summary, including timeouts or failed reviewers.

# Step 4: Conversation With User

Ask whether the user wants verified findings posted to GitHub or Azure DevOps.
Do not post raw model output. Do not post without explicit confirmation.

# Step 5: Clean Up

Ask whether to keep or remove the `./tmp/crowd-reviewer/...` run directory and
the single disposable PR worktree. Do not clean up until the user confirms.
Use `copilot-reviewer`'s cleanup script. Omit `--yes` to preview. After
confirmation, pass only the paths that exist:

```bash
<copilot-reviewer-path>/scripts/cleanup_review.sh \
  --run-dir ./tmp/crowd-reviewer/<run> \
  --yes

<copilot-reviewer-path>/scripts/cleanup_review.sh \
  --run-dir ./tmp/crowd-reviewer/<run> \
  --worktree <worktree> \
  --yes
```

---
name: github-address-pr-comments
description: >
  Address review comments on a GitHub pull request by summarizing active
  comments, letting the user choose which to fix, making code changes,
  and pushing. Use when user wants to "address PR comments", "fix review
  feedback", "handle PR suggestions", or "resolve GitHub PR threads".
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Question
---

# GitHub PR — Address Review Comments

Fetch active review comments on a GitHub PR, summarize and assess each one, let the user pick which to address, make the fixes, and push.

## When to Use

- User says "address comments", "fix review feedback", "handle PR suggestions"
- User pastes a GitHub PR URL and wants to resolve reviewer threads
- User asks to "go through PR comments and fix them"

## Required Inputs

| Input | Format | Example |
|-------|--------|---------|
| PR URL or number | GitHub PR link or `owner/repo#N` or `#N` (if inside repo) | `https://github.com/org/repo/pull/42` or `#42` |

## Prerequisites

- `gh` CLI authenticated with access to the repository
- Local checkout of the repository (or ability to clone it)
- On the PR's source branch (skill will checkout if needed)

---

## Step 1: Parse PR Identifier

Extract owner, repo, and PR number from the input. Supported formats:
- `https://github.com/{owner}/{repo}/pull/{number}`
- `{owner}/{repo}#{number}`
- `#{number}` — resolve owner/repo from current git remote

```bash
# If inside a repo, resolve owner/repo automatically:
gh repo view --json nameWithOwner -q '.nameWithOwner'
```

## Step 2: Fetch PR Metadata

```bash
gh pr view <NUMBER> --json number,title,headRefName,baseRefName,state,author,url
```

Confirm the PR is open. If merged or closed, inform the user and stop.

## Step 3: Checkout the PR Branch

```bash
gh pr checkout <NUMBER>
git pull
```

## Step 4: Fetch Review Comments

Fetch all review comments (inline code comments from reviews):

```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments --paginate
```

Also fetch top-level PR review bodies (non-inline review summaries):

```bash
gh api repos/{owner}/{repo}/pulls/{number}/reviews --paginate
```

Also fetch issue-level comments (general discussion on the PR):

```bash
gh api repos/{owner}/{repo}/issues/{number}/comments --paginate
```

## Step 5: Filter Active Comments

From the fetched data, keep only comments that are **unresolved and actionable**:

1. **Inline review comments**: Keep those that are NOT outdated and NOT part of a resolved conversation. Use the `gh api` graphql endpoint if needed to check thread resolution status:
   ```bash
   gh api graphql -f query='
   {
     repository(owner: "{owner}", name: "{repo}") {
       pullRequest(number: {number}) {
         reviewThreads(first: 100) {
           nodes {
             isResolved
             comments(first: 20) {
               nodes {
                 body
                 author { login }
                 path
                 line
                 originalLine
               }
             }
           }
         }
       }
     }
   }'
   ```
2. **General comments**: Include only if they contain actionable code-change requests (skip "LGTM", thank-you messages, status bot comments).

Discard:
- Bot comments (author login contains `[bot]` or is a known CI bot)
- Already-resolved threads
- Pure questions with no code-change implication

## Step 6: Summarize and Assess Each Comment

For each active comment/thread, produce a summary:

| Field | Description |
|-------|-------------|
| **Thread ID / Comment ID** | Identifier for reference |
| **File & Line** | `path/to/file.go:42` |
| **Reviewer** | Who left the comment |
| **Summary** | One-line plain-English summary of what the reviewer wants |
| **Legitimate?** | `Yes` / `Likely` / `Questionable` — your honest assessment |
| **Suggested Fix** | Brief description of the code change needed |
| **Complexity** | `Trivial` / `Small` / `Medium` / `Large` |

**Assessment criteria for legitimacy:**
- **Yes**: Catches a real bug, enforces a documented standard, improves correctness
- **Likely**: Style/readability improvement that aligns with codebase conventions
- **Questionable**: Subjective preference, contradicts existing patterns, or may introduce new issues

## Step 7: Present to User and Get Selection

Use the `question` tool to present the summarized comments and let the user choose which to address.

Display format:
```
## Active Review Comments on PR #<number>

1. [Yes | Trivial] `src/auth.go:42` — @reviewer: "Use constants instead of magic strings"
   → Replace string literals with existing constants from `pkg/constants`

2. [Likely | Small] `src/handler.go:88` — @reviewer: "Add error wrapping here"
   → Wrap error with `fmt.Errorf("operation failed: %w", err)`

3. [Questionable | Medium] `src/utils.go:12` — @reviewer: "Refactor to use generics"
   → Rewrite helper using type parameters — but current approach is consistent with rest of codebase
```

Ask the user which comments they want to address (allow multi-select or "all").

## Step 8: Address Selected Comments

For each selected comment:
1. Read the referenced file and surrounding context
2. Understand the reviewer's intent from the full thread (not just the first comment)
3. Make the code change using Edit
4. Track what was changed for the commit message

**Rules:**
- Group changes by file — if multiple comments affect the same file, batch edits
- When a comment is ambiguous, ask the user for clarification rather than guessing
- Match existing code style — read nearby code for conventions
- If the repo has `.github/copilot-instructions.md`, `CLAUDE.md`, or `AGENTS.md`, read it for coding standards

## Step 9: Validate

If the project has quick validation commands, run them:
- Go: `go build ./...` and `go vet ./...`
- TypeScript/JS: `npm run build` or `npx tsc --noEmit`
- Python: `python -m py_compile <file>` or `ruff check`
- Rust: `cargo check`

Check for lint/type errors in changed files. Fix any issues introduced by the changes.

## Step 10: Commit and Push

Stage only modified files — never use `git add -A`:

```bash
git add <file1> <file2> ...
git commit -m "address PR #<NUMBER> review comments

Changes:
- <summary of change 1>
- <summary of change 2>"

git push
```

## Step 11: Summary

Present the final report:

```
## PR #<NUMBER> — Comments Addressed

### Changes Made
| # | File:Line | Reviewer | Comment | Change |
|---|-----------|----------|---------|--------|
| 1 | `src/auth.go:42` | @alice | Use constants | Replaced magic strings with `pkg/constants` values |

### Comments Skipped
- Thread <id> — <reason> (e.g., "user chose not to address", "ambiguous request")

### Commit
- Hash: <short-hash>
- Pushed to: `origin/<branch>`

### Remaining
- <N> unresolved comments still open on this PR
```

---

## Safety Rules

- **Do NOT resolve/dismiss threads on GitHub** — let the reviewer do that
- **Do NOT use `git add -A`** — stage only files you modified
- **Do NOT force-push** — use regular `git push` only
- If a comment is ambiguous, **ask the user** rather than guessing
- Validate changes compile/lint before pushing
- If the user asks to skip pushing, commit locally and show the push command instead

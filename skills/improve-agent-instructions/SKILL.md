---
name: improve-agent-instructions
description: >
  Audit and improve an AGENTS.md, CLAUDE.md, copilot-instructions.md, or
  .cursorrules file using research-backed criteria. Removes discoverable
  bloat, surfaces missing landmines, and produces a lean, high-signal
  context file. Use when asked to "improve my AGENTS.md", "review my
  copilot-instructions", "optimize my context file", or "audit my CLAUDE.md".
allowed-tools:
  - bash
  - read
  - write
  - edit
  - grep
  - glob
  - question
---

# Improve Agent Instructions

Audit and rewrite agent context files (AGENTS.md, CLAUDE.md, copilot-instructions.md, .cursorrules) so they contain only what actually helps coding agents produce correct output.

## Research Background

This skill is grounded in two key studies:

- **Gloaguen et al. (ETH Zurich, 2026)** — LLM-generated context files *decreased* task correctness in 5/8 settings and increased inference cost by 20–23%. Human-written files averaged only ~4% improvement, inconsistently. Agents with and without context files discovered the same files at the same speed.
- **Lulla et al. (2026)** — Human-authored context files reduced median agent runtime by ~29% and output tokens by ~17%, but measured *efficiency*, not *correctness*.

**The core finding:** context files help agents navigate faster but don't reliably help them arrive at the right answer. The useful content is *non-discoverable information* — things code can't tell you.

### The Three Failure Modes

1. **Redundancy** — Describing things the agent can discover by reading code (directory structure, language, framework, test commands). This wastes tokens and adds no signal.
2. **Attention tax** — Long files trigger U-shaped attention (Liu et al., 2023): LLMs attend strongly to the beginning and end, poorly to the middle. Important rules buried in paragraph 6 of 12 get ignored.
3. **Anchoring trap** — Agents follow instructions too faithfully. Mentioning a tool or pattern makes agents use it ~50x more often, even when outdated or wrong.

### The Filter

> *"Can the agent discover this on its own by reading your code? If yes, delete it."*
> — Addy Osmani, synthesizing the ETH Zurich findings

## When to Use

- User asks to "improve", "audit", "review", or "optimize" their AGENTS.md, CLAUDE.md, copilot-instructions.md, or .cursorrules
- User ran `/init` and wants to clean up the generated output
- User suspects their context file is too long or not helping
- User is setting up a context file for the first time and wants guidance

## Prerequisites

- A git repository with source code (so we can assess what's discoverable)
- An existing context file to audit, OR the user wants to create one from scratch

---

## Step 1: Locate the Context File

Search for existing context files in the repo root and `.github/` directory:

```bash
# Check common locations
for f in AGENTS.md CLAUDE.md .github/copilot-instructions.md .cursorrules COPILOT.md; do
  [ -f "$f" ] && echo "FOUND: $f"
done
```

If multiple files exist, ask the user which one to audit. If none exist, proceed to Step 6 (create from scratch).

Read the file fully before proceeding.

## Step 2: Inventory the Codebase

Gather what the agent can discover on its own — this is the baseline for identifying redundancy.

```bash
# Directory structure (top 2 levels)
find . -maxdepth 2 -type f -not -path './.git/*' | head -60

# Package/project metadata
for f in package.json pyproject.toml Cargo.toml go.mod Gemfile pom.xml build.gradle Makefile CMakeLists.txt; do
  [ -f "$f" ] && echo "=== $f ===" && head -30 "$f"
done

# CI/CD configuration
ls -la .github/workflows/ 2>/dev/null
ls -la .gitlab-ci.yml 2>/dev/null
ls -la Jenkinsfile 2>/dev/null

# Existing documentation
for f in README.md CONTRIBUTING.md docs/; do
  [ -e "$f" ] && echo "FOUND: $f"
done
```

This inventory tells you what information is *already available* to the agent through normal code reading.

## Step 3: Classify Every Line

Go through the context file and classify each instruction or section into one of four categories:

### Category A: Redundant (DELETE)

Information the agent will discover by reading code, config, or docs that already exist in the repo. Common offenders:

- **Codebase overviews** — "This is a React app using TypeScript..." (agent reads package.json)
- **Directory structure descriptions** — "The `src/` folder contains..." (agent reads the filesystem)
- **Language/framework identification** — "We use Python 3.12 with FastAPI" (agent reads pyproject.toml)
- **Test commands** — "Run tests with `npm test`" (agent reads package.json scripts or Makefile)
- **Build commands** — "Build with `cargo build`" (agent reads Cargo.toml)
- **Dependency lists** — "We use lodash, express, ..." (agent reads the manifest)
- **File-by-file descriptions** — "auth.ts handles authentication" (agent reads the file)
- **Architecture diagrams in prose** — Describing what the code already shows

### Category B: Landmines (KEEP — high value)

Non-obvious hazards that look normal but will cause failures. These are the *most valuable* lines:

- **Counterintuitive tool requirements** — "Use `uv` instead of `pip`", "Use `pnpm`, not `npm`"
- **Hidden dependencies** — "The auth module requires Redis running on port 6380 (non-standard)"
- **Trap patterns** — "Don't refactor `legacy/auth.go` — 3 production services import it directly"
- **Non-obvious test requirements** — "Integration tests need `docker compose up` first", "Run tests with `--no-cache` or results are stale"
- **Environment gotchas** — "CI uses Node 18 but local dev must use Node 20", "The `.env.test` file must exist even for unit tests"
- **Deprecated-but-live code** — "The `v1/` API is deprecated but still serves 40% of production traffic — don't remove it"

### Category C: Behavioral Guardrails (KEEP — if not obvious from code)

Rules the agent can't infer from code patterns alone:

- **Error handling policy** — Only if it contradicts what the code patterns suggest
- **Commit/PR conventions** — Only if non-standard (e.g., "squash commits must reference Jira ticket")
- **Things NOT to do** — Prohibitions that prevent common agent mistakes in *this specific* codebase

### Category D: Style Preferences (TRIM)

Style rules are valuable only when they *contradict* what the agent would infer from existing code. If you have a linter config (ESLint, Prettier, Ruff, etc.), the agent will read it.

- If `.prettierrc` says `singleQuote: true`, delete "Use single quotes" from the context file
- If there's no linter, keep 2–3 essential style rules max
- If a style rule has 20+ examples in the codebase, the agent will pattern-match — delete the rule

## Step 4: Present the Audit

Show the user a classification table:

```
## Audit Results for <filename>

### 🗑️ Redundant (recommend DELETE) — <N> lines
These are discoverable from code/config and add ~X% token overhead:

| Line/Section | Why it's redundant | Source the agent reads instead |
|---|---|---|
| "This is a TypeScript monorepo" | package.json + directory structure | `package.json`, `tsconfig.json` |
| "Run tests with npm test" | scripts section | `package.json:scripts.test` |

### 💣 Landmines (recommend KEEP) — <N> lines
These prevent real failures:

| Line/Section | Why it matters |
|---|---|
| "Use pnpm, not npm" | No lockfile hint; agent would default to npm |
| "Don't modify legacy/auth" | Looks refactorable but has hidden dependents |

### 🛡️ Guardrails (recommend KEEP, review for staleness) — <N> lines

| Line/Section | Still accurate? |
|---|---|
| "Never use `as any`" | ✓ Verified — no `as any` in codebase |

### ✂️ Style (recommend TRIM unless no linter) — <N> lines

| Line/Section | Covered by linter? |
|---|---|
| "Use single quotes" | ✓ .prettierrc exists — delete |

### 📊 Summary
- Current file: ~<N> tokens
- Estimated after cleanup: ~<N> tokens
- Projected token savings: ~<X>%
```

Use the question tool to ask the user which recommendations to accept.

## Step 5: Rewrite the File

Apply the accepted changes. The rewritten file should follow these structural rules:

### Structure Rules

1. **Maximum length: aim for under 50 lines of actual content.** Shorter is better. Every line should fail the "can the agent figure this out?" test.

2. **Lead with the highest-value information.** Due to U-shaped attention, put the most critical landmines and guardrails first (and last if the file is longer).

3. **Use imperative, unambiguous statements.** Not "We prefer to use..." but "Use X." Not "It's generally a good idea to..." but "Always X." Agents anchor on instructions — make them precise.

4. **Group by action, not by topic.** Instead of a "Testing" section with 8 bullet points, put only the non-obvious testing landmines under a "Landmines" heading.

### Recommended Template

```markdown
# <Project Name> — Agent Instructions

## Landmines

- <Most critical non-obvious hazard>
- <Second most critical>
- ...

## Guardrails

- <Rule the agent can't infer from code>
- ...

## Verification

- <Non-obvious verification commands or sequences>
- ...
```

That's it. No codebase overview. No architecture description. No dependency list. No directory tree.

### Writing Rules

- Never add back information that was classified as redundant
- Keep the total under 50 content lines (excluding blank lines and headings)
- If a guardrail has a *reason*, include it inline: "Use `pnpm` — the repo has no `package-lock.json` and `npm` will create one, breaking CI"
- End with verification steps only if they're non-obvious

## Step 6: Create from Scratch (if no file exists)

If the user has no context file yet, DO NOT generate a codebase overview. Instead:

1. Run the codebase inventory from Step 2
2. Look for landmines by checking for:
   - Non-standard tooling (custom scripts, unusual package managers, wrapper commands)
   - Multiple config files that could conflict
   - `legacy/`, `deprecated/`, or `compat/` directories that are still imported
   - Environment variable requirements not documented elsewhere
   - Docker/compose requirements for testing
   - Monorepo structures with non-obvious build ordering
   - Custom linter rules or pre-commit hooks
3. Ask the user: "What trips up new engineers on this project? What are the 'you just have to know' things?"
4. Write a minimal file using the template from Step 5

**Start with 5–10 lines.** The user should add lines only when an agent trips on something in practice. A context file is a living list of active hazards, not a static encyclopedia.

## Step 7: Validate the Result

After writing the file:

1. Count the lines and tokens — flag if over 50 content lines
2. Re-run the redundancy check: for each remaining line, state what code/config file would tell the agent the same thing. If any match, flag them.
3. Show the final file to the user with a summary:

```
## Result

- Lines: <N> (target: <50)
- Estimated tokens: <N>
- Landmines: <N>
- Guardrails: <N>
- Redundant lines: 0 ✓
```

---

## Anti-Patterns to Flag

If you encounter these in a context file, always recommend removal:

| Anti-Pattern | Why |
|---|---|
| Codebase overview / "This project is..." | 100% of LLM-generated files include this (Gloaguen et al.). Pure redundancy. |
| Directory tree reproduction | Agent reads the filesystem in milliseconds. |
| Dependency enumeration | Agent reads the manifest file. |
| Generic best practices ("write clean code", "follow SOLID") | Vague instructions that don't change agent behavior. |
| Restating linter/formatter config | Agent reads `.eslintrc`, `.prettierrc`, `ruff.toml` directly. |
| History / changelog / "why we chose X" | Interesting to humans, useless to agents. |
| Long examples of desired output | Use a few lines max; long examples waste the attention window. |

## Key Principles

1. **Agents aren't new hires.** They can grep the entire codebase before you finish typing. They need to know where the landmines are, not how the building is laid out.
2. **Shorter is better.** Every unnecessary line dilutes the attention the agent gives to important lines (U-shaped attention).
3. **Context files should be living documents.** Add a line when an agent trips. Delete a line when the root cause is fixed. Never "set and forget."
4. **What helps humans ≠ what helps LLMs.** Prose explanations and architectural narratives help humans onboard. Agents need terse, actionable directives about non-obvious hazards.

---
name: github-project-sync
description: >
  Sync tasks from any planning markdown file(s) into a GitHub Project. Reads
  task definitions from one or more markdown files (or a folder), compares
  against existing project items, and creates only the missing issues.
  Enforces dependencies and parent-child hierarchies when specified. Never
  creates duplicates. Works with any markdown-based planning format.
allowed-tools:
  - bash
  - read
  - glob
  - grep
---

# GitHub Project Sync Skill

Sync tasks from markdown planning files into a GitHub Project (v2). Reads task definitions, diffs against existing issues, and creates only what's missing. Enforces dependency ordering and parent-child hierarchies when the planning files specify them.

**Format-agnostic** — works with any markdown planning file that contains numbered tasks, whether in tables, headings, or lists.

## When to Use

- "sync tasks to project", "add missing tasks", "populate the project board"
- "create issues from plan", "import tasks into GitHub"
- New tasks added to a plan file and need syncing without duplicating existing items

## Prerequisites

- `gh` CLI authenticated with `project` scope:
  ```bash
  gh auth refresh -s project
  ```
- The GitHub repository must exist and be accessible.
- For sub-issue support (optional):
  ```bash
  gh extension install yahsan2/gh-sub-issue 2>/dev/null || true
  ```

## Inputs

The skill needs two things:

1. **Task source** — one of:
   - A single markdown file containing tasks (table, headings, or list format)
   - A folder of markdown files (one task per file, or multiple tasks per file)
   - Multiple specific files

2. **GitHub Project identifier** — the project number and owner.

**If the user doesn't provide the task source**, check whether the current repository has an obvious planning file (e.g., a `PLAN.md`, `TASKS.md`, `TODO.md`, or a `plans/` directory at the root). If nothing is obvious, **ask the user** to point you to the file or directory.

**If the user doesn't provide the project number/owner**, list their projects:
```bash
gh project list --owner "$(gh api user -q .login)" --format json --jq '.projects[] | "\(.number)\t\(.title)"'
```
Then ask them to pick one.

## Supported Planning Formats

The skill handles these common patterns. When parsing, try them in order and use whichever matches.

### Format A — Markdown table with numbered rows

Any table where the first column is a task number and the second is a title:

```markdown
| # | Task | Status |
|---|------|--------|
| 1 | Set up project scaffolding | Done |
| 2 | Configure networking | In Progress |
```

Variations: first column may be labeled `#`, `No`, `ID`, `Task`, `Number`, or just contain digits. The title column is typically the next text column.

### Format B — Headings with task numbers

```markdown
## Task 1: Set up project scaffolding
## Task 2: Configure networking
```

Or:
```markdown
# 1. Set up project scaffolding
# 2. Configure networking
```

### Format C — Ordered list items

```markdown
1. Set up project scaffolding
2. Configure networking
3. Create database schema
```

Or with checkboxes:
```markdown
- [ ] 1. Set up project scaffolding
- [x] 2. Configure networking
```

### Format D — Individual task files in a folder

Each file represents one task. The task number and title are extracted from the filename and/or the first heading:
- Filename: `task-01-scaffolding.md`, `01-scaffolding.md`, `T1.md`
- First heading: `# Task 1: Scaffolding` or `# Set up project scaffolding`

### Dependency Formats

Dependencies can appear in several forms. Look for all of these:

**In a dedicated table:**
```markdown
| Task | Depends On | Blocks |
|------|-----------|--------|
| 3    | 1, 2      | 5, 6   |
```

**Inline in task description:**
```markdown
**Depends on**: Task 1, Task 2
**Blocks**: Task 5, Task 6
**Blocked by**: #3, #4
**After**: T1, T2
**Prerequisites**: 1, 2
```

**As list items:**
```markdown
- Depends on: Task 1
- Blocks: Task 5
```

## Workflow

### Step 1 — Locate the task source and repository

Determine the planning file(s) and target repo/project.

```bash
# Detect current repo
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
echo "Repository: $REPO"
```

If the user provided a file or directory path, use it directly. Otherwise, look for common planning file locations:

```bash
detect_plan_files() {
  local candidates=(
    "PLAN.md" "TASKS.md" "TODO.md" "ROADMAP.md"
    "plans/" "tasks/" ".plans/"
    "docs/plan.md" "docs/tasks.md"
  )
  for candidate in "${candidates[@]}"; do
    if [ -e "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  # Check for any top-level markdown with "task" or "plan" in the name
  find . -maxdepth 2 -name '*task*' -o -name '*plan*' -o -name '*todo*' | head -5
}
```

If nothing is found, **ask the user**: "I couldn't find a planning file in the repo. Could you point me to the file or directory containing your task definitions?"

Ask for **project number** and **owner** if not provided.

### Step 2 — Detect the planning format and parse tasks

Read the source file(s) and determine the format. Output a normalized task list as TSV: `TASK_NUM \t TITLE \t SOURCE_FILE \t EXTRA_METADATA`

```bash
parse_tasks_from_file() {
  local file="$1"
  local content
  content=$(cat "$file")

  # --- Try Format A: Markdown table ---
  # Look for a table where the first data column is a number
  local table_tasks
  table_tasks=$(awk '
    BEGIN { in_table=0; num_col=-1; title_col=-1 }

    # Detect table header row (contains | separated cells)
    /^\|.*\|/ && !in_table {
      gsub(/^ *\| *| *\| *$/, "")
      n = split($0, hdrs, / *\| */)
      for (i=1; i<=n; i++) {
        h = tolower(hdrs[i])
        if (h ~ /^(#|no|id|num|number|task *#?)$/) num_col = i
        if (h ~ /^(task|title|name|description|summary)$/ && title_col < 0) title_col = i
      }
      # If first col looks like a number header and second is text, use those
      if (num_col < 0 && n >= 2) { num_col = 1; title_col = 2 }
      if (title_col < 0 && num_col > 0) {
        title_col = (num_col == 1) ? 2 : 1
      }
      if (num_col > 0 && title_col > 0) in_table = 1
      next
    }

    # Skip separator row
    /^\|[-: ]+\|/ && in_table { next }

    # Data rows
    /^\|/ && in_table {
      gsub(/^ *\| *| *\| *$/, "")
      n = split($0, cols, / *\| */)
      if (n >= 2) {
        tnum = cols[num_col]
        ttitle = cols[title_col]
        # Only emit if first col is numeric
        if (tnum ~ /^[0-9]+$/) {
          printf "%s\t%s\t\t\n", tnum, ttitle
        }
      }
    }

    # End of table
    /^[^|]/ && in_table { in_table=0; num_col=-1; title_col=-1 }
  ' "$file")

  if [ -n "$table_tasks" ]; then
    echo "$table_tasks"
    return 0
  fi

  # --- Try Format B: Headings with task numbers ---
  local heading_tasks
  heading_tasks=$(sed -nE '
    s/^#{1,6} *[Tt]ask *([0-9]+)[.:) -]+ *(.+)$/\1\t\2\t\t/p
    s/^#{1,6} *([0-9]+)[.:) ] *(.+)$/\1\t\2\t\t/p
  ' "$file")

  if [ -n "$heading_tasks" ]; then
    echo "$heading_tasks"
    return 0
  fi

  # --- Try Format C: Ordered list items ---
  local list_tasks
  list_tasks=$(sed -nE '
    s/^- \[.\] *([0-9]+)[.:) ] *(.+)$/\1\t\2\t\t/p
    s/^([0-9]+)[.:) ] +(.+)$/\1\t\2\t\t/p
  ' "$file")

  if [ -n "$list_tasks" ]; then
    echo "$list_tasks"
    return 0
  fi

  echo ""
  return 1
}
```

For **Format D** (directory of task files):

```bash
parse_tasks_from_directory() {
  local dir="$1"
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    local basename
    basename=$(basename "$f" .md)

    # Try to extract task number from filename
    local task_num
    task_num=$(echo "$basename" | sed -nE '
      s/^[Tt]?ask-?0*([0-9]+).*/\1/p
      s/^0*([0-9]+)[-_.].*/\1/p
      s/^[Tt]0*([0-9]+)$/\1/p
    ' | head -1)

    # Try to extract title from first heading
    local task_title
    task_title=$(head -10 "$f" | sed -nE '
      s/^#{1,6} *[Tt]ask *[0-9]+[.:) -]+ *(.+)$/\1/p
      s/^#{1,6} *[0-9]+[.:) -]+ *(.+)$/\1/p
      s/^#{1,6} +(.+)$/\1/p
    ' | head -1)

    # Fallback: use filename as title
    if [ -z "$task_title" ]; then
      task_title=$(echo "$basename" | sed -E 's/^[Tt]?ask-?[0-9]*-?//; s/[-_]/ /g')
    fi

    # If no task number found, assign sequential number
    if [ -z "$task_num" ]; then
      echo "Warning: Could not extract task number from ${f}. Skipping." >&2
      continue
    fi

    printf "%s\t%s\t%s\t\n" "$task_num" "$task_title" "$(basename "$f")"
  done
}
```

### Step 3 — Parse dependencies

Scan all source files for dependency information. Produce TSV: `TASK_NUM \t DEPENDS_ON \t BLOCKS`

```bash
parse_dependencies_from_file() {
  local file="$1"

  # --- Check for a dependency table ---
  awk '
    /^\|.*[Dd]epend/ || /^\|.*[Bb]lock/ {
      # Identify column positions
      gsub(/^ *\| *| *\| *$/, "")
      n = split($0, hdrs, / *\| */)
      task_col = -1; dep_col = -1; blk_col = -1
      for (i=1; i<=n; i++) {
        h = tolower(hdrs[i])
        if (h ~ /task|#|id/) task_col = i
        if (h ~ /depend|blocked by|prerequisite|after/) dep_col = i
        if (h ~ /block/) blk_col = i
      }
      if (task_col < 0) task_col = 1
      if (dep_col > 0 || blk_col > 0) in_table = 1
      next
    }
    /^\|[-: ]+\|/ && in_table { next }
    /^\|/ && in_table {
      gsub(/^ *\| *| *\| *$/, "")
      n = split($0, cols, / *\| */)
      task = cols[task_col]
      dep = (dep_col > 0) ? cols[dep_col] : ""
      blk = (blk_col > 0) ? cols[blk_col] : ""
      # Normalize: strip "T", "Task", "#", commas stay
      gsub(/[Tt]ask */, "", dep); gsub(/[Tt]/, "", dep); gsub(/#/, "", dep); gsub(/ /, "", dep)
      gsub(/[Tt]ask */, "", blk); gsub(/[Tt]/, "", blk); gsub(/#/, "", blk); gsub(/ /, "", blk)
      gsub(/[Tt]ask */, "", task); gsub(/[Tt]/, "", task); gsub(/#/, "", task); gsub(/ /, "", task)
      if (task ~ /^[0-9]+$/) printf "%s\t%s\t%s\n", task, dep, blk
    }
    /^[^|]/ && in_table { in_table = 0 }
  ' "$file"

  # --- Check for inline dependency metadata ---
  # Look for lines like: **Depends on**: T1, T2  or  **Blocked by**: 3, 4
  # We need to associate these with a task number — use the nearest heading
  awk '
    /^#{1,6}/ {
      # Extract task number from heading
      line = $0
      gsub(/^#{1,6} */, "", line)
      if (match(line, /[Tt]ask *([0-9]+)/, m)) current_task = m[1]
      else if (match(line, /^([0-9]+)/, m)) current_task = m[1]
      else current_task = ""
    }
    current_task && tolower($0) ~ /(depend|blocked by|prerequisite|after) *:/ {
      line = $0
      gsub(/.*: */, "", line)
      gsub(/[Tt]ask */, "", line); gsub(/[Tt]/, "", line); gsub(/#/, "", line); gsub(/ /, "", line)
      if (line != "") printf "%s\t%s\t\n", current_task, line
    }
    current_task && tolower($0) ~ /blocks? *:/ {
      line = $0
      gsub(/.*: */, "", line)
      gsub(/[Tt]ask */, "", line); gsub(/[Tt]/, "", line); gsub(/#/, "", line); gsub(/ /, "", line)
      if (line != "") printf "%s\t\t%s\n", current_task, line
    }
  ' "$file"
}
```

### Step 4 — Fetch existing issues

Query the repository for all issues to avoid duplicates:

```bash
fetch_existing_issues() {
  local repo="$1"
  gh issue list --repo "$repo" --state all --limit 500 \
    --json number,title \
    --jq '.[] | "\(.number)\t\(.title)"'
}
```

### Step 5 — Determine what's missing

Compare parsed tasks against existing issues. Match by:
1. Task-ID prefix in title (e.g., `t4:`, `T4:`, `Task 4:`, `4:`)
2. Fuzzy: case-insensitive exact title substring match

```bash
is_task_duplicate() {
  local task_num="$1"
  local task_title="$2"
  local existing_file="$3"  # file of existing issue titles (num\ttitle per line)

  # Escape special regex characters in title for safe matching
  local escaped_title
  escaped_title=$(printf '%s' "$task_title" | sed 's/[.[\*^$()+?{|\\]/\\&/g')

  while IFS=$'\t' read -r existing_num existing_title; do
    # Match by task ID prefix
    if echo "$existing_title" | grep -qiE "^[Tt](ask)?[ -]*${task_num}[.:) ]"; then
      echo "$existing_num"
      return 0
    fi
    if echo "$existing_title" | grep -qiE "^${task_num}[.:) ]"; then
      echo "$existing_num"
      return 0
    fi
    # Match by exact title (case-insensitive)
    if echo "$existing_title" | grep -qiF "$task_title"; then
      echo "$existing_num"
      return 0
    fi
  done < "$existing_file"

  return 1
}
```

### Step 6 — Create missing issues and add to project

For each task that doesn't already exist:

```bash
create_task_issue() {
  local task_num="$1"
  local task_title="$2"
  local source_file="$3"    # original file for this task (for body content)
  local dep_info="$4"       # dependency text to append
  local repo="$5"
  local project_num="$6"
  local owner="$7"
  local tasks_dir="$8"      # base directory for source files

  local title="t${task_num}: ${task_title}"
  local body="Task ${task_num}: ${task_title}"

  # Use source file content as body if available
  if [ -n "$source_file" ]; then
    local full_path=""
    if [ -f "$source_file" ]; then
      full_path="$source_file"
    elif [ -n "$tasks_dir" ] && [ -f "${tasks_dir}/${source_file}" ]; then
      full_path="${tasks_dir}/${source_file}"
    fi
    if [ -n "$full_path" ]; then
      body=$(cat "$full_path")
    fi
  fi

  # Append dependency info
  if [ -n "$dep_info" ]; then
    body+="$dep_info"
  fi

  local issue_url
  issue_url=$(gh issue create \
    --repo "$repo" \
    --title "$title" \
    --body "$body" \
    --json url -q '.url')

  local issue_number
  issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')

  # Add to project
  gh project item-add "$project_num" --owner "$owner" --url "$issue_url" >/dev/null 2>&1 || \
    echo "  Warning: Failed to add to project (check project scope)" >&2

  echo "$issue_number"
}
```

### Step 7 — Build dependency text for issue bodies

Since GitHub Projects V2 lacks native dependency fields, encode dependencies as `#N` cross-references:

```bash
build_dependency_text() {
  local task_num="$1"
  local dep_file="$2"     # TSV: task_num \t depends_on \t blocks
  local issue_map="$3"    # TSV: task_num \t issue_number

  local dep_line
  dep_line=$(grep "^${task_num}	" "$dep_file" 2>/dev/null | head -1) || true
  [ -z "$dep_line" ] && return

  local depends_on blocks
  depends_on=$(echo "$dep_line" | cut -f2)
  blocks=$(echo "$dep_line" | cut -f3)

  local text=""

  if [ -n "$depends_on" ] && [ "$depends_on" != "-" ] && [ "$depends_on" != "None" ] && [ "$depends_on" != "none" ]; then
    text+=$'\n\n## Dependencies\n\n**Blocked by**: '
    IFS=',' read -ra deps <<< "$depends_on"
    for d in "${deps[@]}"; do
      d=$(echo "$d" | tr -d ' ')
      [ -z "$d" ] && continue
      local dep_issue
      dep_issue=$(grep "^${d}	" "$issue_map" 2>/dev/null | cut -f2 | head -1) || true
      if [ -n "$dep_issue" ]; then
        text+="#${dep_issue} "
      else
        text+="Task ${d} "
      fi
    done
  fi

  if [ -n "$blocks" ] && [ "$blocks" != "-" ] && [ "$blocks" != "None" ] && [ "$blocks" != "none" ]; then
    text+=$'\n\n**Blocks**: '
    IFS=',' read -ra blks <<< "$blocks"
    for b in "${blks[@]}"; do
      b=$(echo "$b" | tr -d ' ')
      [ -z "$b" ] && continue
      text+="Task ${b} "
    done
  fi

  echo "$text"
}
```

### Step 8 — Link sub-issues (optional)

If planning files specify parent-child relationships, link them:

```bash
link_sub_issues() {
  local parent_issue="$1"
  shift
  local children=("$@")

  if ! gh sub-issue --help &>/dev/null; then
    echo "Note: gh-sub-issue extension not installed. Skipping sub-issue linking." >&2
    echo "Install with: gh extension install yahsan2/gh-sub-issue" >&2
    return 0
  fi

  for child in "${children[@]}"; do
    gh sub-issue add "$parent_issue" "$child" 2>/dev/null || \
      echo "  Warning: Could not link #${child} to #${parent_issue}" >&2
  done
}
```

### Step 9 — Full orchestration

Tie everything together. The agent runs this logic, adapting to whatever format was detected:

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- Configuration (provided by the agent based on user input) ---
PROJECT_NUM="${PROJECT_NUM:?Set PROJECT_NUM}"
OWNER="${OWNER:?Set OWNER}"
SOURCE="${SOURCE:?Set SOURCE to a file or directory path}"
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

echo "=== GitHub Project Sync ==="
echo "Repository: $REPO"
echo "Project:    #${PROJECT_NUM} (owner: ${OWNER})"
echo "Source:     ${SOURCE}"
echo ""

# Temp files
TASK_LIST=$(mktemp)
DEP_LIST=$(mktemp)
EXISTING_ISSUES=$(mktemp)
ISSUE_MAP=$(mktemp)
trap 'rm -f "$TASK_LIST" "$DEP_LIST" "$EXISTING_ISSUES" "$ISSUE_MAP"' EXIT

TASKS_DIR=""

# --- Parse tasks ---
if [ -d "$SOURCE" ]; then
  echo "Detected directory source. Parsing individual task files..."
  TASKS_DIR="$SOURCE"
  # Use parse_tasks_from_directory logic (see Step 2)
  for f in "$SOURCE"/*.md; do
    [ -f "$f" ] || continue
    basename_noext=$(basename "$f" .md)
    task_num=$(echo "$basename_noext" | sed -nE '
      s/^[Tt]?ask-?0*([0-9]+).*/\1/p
      s/^0*([0-9]+)[-_.].*/\1/p
      s/^[Tt]0*([0-9]+)$/\1/p
    ' | head -1)
    [ -z "$task_num" ] && continue
    task_title=$(head -10 "$f" | sed -nE '
      s/^#{1,6} *[Tt]ask *[0-9]+[.:) -]+ *(.+)$/\1/p
      s/^#{1,6} *[0-9]+[.:) -]+ *(.+)$/\1/p
      s/^#{1,6} +(.+)$/\1/p
    ' | head -1)
    [ -z "$task_title" ] && task_title=$(echo "$basename_noext" | sed -E 's/^[Tt]?ask-?[0-9]*-?//; s/[-_]/ /g')
    printf "%s\t%s\t%s\t\n" "$task_num" "$task_title" "$(basename "$f")" >> "$TASK_LIST"
  done

  # Parse dependencies from each file
  for f in "$SOURCE"/*.md; do
    [ -f "$f" ] || continue
    # Use parse_dependencies_from_file logic (see Step 3)
    # (Agent should inline the awk scripts from Step 3 here)
  done >> "$DEP_LIST"

elif [ -f "$SOURCE" ]; then
  echo "Detected single file source. Parsing tasks..."
  # Use parse_tasks_from_file logic (see Step 2)
  # (Agent should inline the awk/sed scripts from Step 2 here)
  # Results go to $TASK_LIST

  # Parse dependencies
  # Use parse_dependencies_from_file logic (see Step 3)
  # Results go to $DEP_LIST
else
  echo "ERROR: Source '${SOURCE}' does not exist."
  exit 1
fi

TASK_COUNT=$(wc -l < "$TASK_LIST" | tr -d ' ')
echo "Found ${TASK_COUNT} tasks."

if [ "$TASK_COUNT" -eq 0 ]; then
  echo "No tasks found. Check the file format — the skill expects numbered tasks in tables, headings, or lists."
  exit 1
fi

# --- Fetch existing issues ---
echo "Fetching existing issues from ${REPO}..."
gh issue list --repo "$REPO" --state all --limit 500 \
  --json number,title \
  --jq '.[] | "\(.number)\t\(.title)"' > "$EXISTING_ISSUES"

EXISTING_COUNT=$(wc -l < "$EXISTING_ISSUES" | tr -d ' ')
echo "Found ${EXISTING_COUNT} existing issues."

# --- Create missing issues ---
CREATED=0
SKIPPED=0

while IFS=$'\t' read -r task_num task_title source_file extra; do
  # Check for duplicates (see Step 5 logic)
  existing_match=""
  while IFS=$'\t' read -r ex_num ex_title; do
    if echo "$ex_title" | grep -qiE "^[Tt](ask)?[ -]*${task_num}[.:) ]"; then
      existing_match="$ex_num"; break
    fi
    if echo "$ex_title" | grep -qiE "^${task_num}[.:) ]"; then
      existing_match="$ex_num"; break
    fi
    if echo "$ex_title" | grep -qiF "$task_title"; then
      existing_match="$ex_num"; break
    fi
  done < "$EXISTING_ISSUES"

  if [ -n "$existing_match" ]; then
    echo "SKIP (exists as #${existing_match}): t${task_num}: ${task_title}"
    echo "${task_num}	${existing_match}" >> "$ISSUE_MAP"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Build dependency text (see Step 7 logic)
  dep_text=""
  if [ -s "$DEP_LIST" ]; then
    dep_line=$(grep "^${task_num}	" "$DEP_LIST" 2>/dev/null | head -1) || true
    if [ -n "$dep_line" ]; then
      depends_on=$(echo "$dep_line" | cut -f2)
      blocks=$(echo "$dep_line" | cut -f3)
      if [ -n "$depends_on" ] && [ "$depends_on" != "-" ] && [ "$depends_on" != "None" ]; then
        dep_text+=$'\n\n## Dependencies\n\n**Blocked by**: '
        IFS=',' read -ra deps <<< "$depends_on"
        for d in "${deps[@]}"; do
          d=$(echo "$d" | tr -d ' ')
          [ -z "$d" ] && continue
          dep_issue=$(grep "^${d}	" "$ISSUE_MAP" 2>/dev/null | cut -f2 | head -1) || true
          [ -n "$dep_issue" ] && dep_text+="#${dep_issue} " || dep_text+="Task ${d} "
        done
      fi
      if [ -n "$blocks" ] && [ "$blocks" != "-" ] && [ "$blocks" != "None" ]; then
        dep_text+=$'\n\n**Blocks**: '
        IFS=',' read -ra blks <<< "$blocks"
        for b in "${blks[@]}"; do
          b=$(echo "$b" | tr -d ' ')
          [ -z "$b" ] && continue
          dep_text+="Task ${b} "
        done
      fi
    fi
  fi

  # Build body
  body="Task ${task_num}: ${task_title}"
  if [ -n "$source_file" ]; then
    if [ -f "$source_file" ]; then
      body=$(cat "$source_file")
    elif [ -n "$TASKS_DIR" ] && [ -f "${TASKS_DIR}/${source_file}" ]; then
      body=$(cat "${TASKS_DIR}/${source_file}")
    fi
  fi
  [ -n "$dep_text" ] && body+="$dep_text"

  echo "CREATE: t${task_num}: ${task_title}"
  issue_url=$(gh issue create \
    --repo "$REPO" \
    --title "t${task_num}: ${task_title}" \
    --body "$body" \
    --json url -q '.url')

  issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')
  echo "${task_num}	${issue_number}" >> "$ISSUE_MAP"
  echo "  -> #${issue_number}: ${issue_url}"

  gh project item-add "$PROJECT_NUM" --owner "$OWNER" --url "$issue_url" >/dev/null 2>&1 && \
    echo "  -> Added to project #${PROJECT_NUM}" || \
    echo "  -> Warning: Failed to add to project"

  CREATED=$((CREATED + 1))

done < "$TASK_LIST"

echo ""
echo "=== Sync Complete ==="
echo "Created: ${CREATED}"
echo "Skipped: ${SKIPPED}"
echo "Total:   ${TASK_COUNT}"
```

## Notes

- **Format detection is best-effort.** The skill tries tables → headings → lists in order. If your format isn't detected, the agent should adapt the parsing logic to match what it sees in your file.
- **Deduplication** matches on task-ID prefix in the issue title (e.g., `t4:`, `T4:`, `Task 4:`) and falls back to fuzzy title matching. Conservative by design.
- **Dependencies** are encoded as `#N` cross-references in issue bodies. GitHub auto-links these.
- **Sub-issues** require the `gh-sub-issue` extension. If not installed, the skill skips hierarchy linking.
- **Idempotent**: safe to run multiple times — skips existing tasks.
- **Large projects**: fetches up to 500 existing issues. Increase `--limit` for larger repos.
- **Title format**: created issues use `t{N}: {Title}`. The agent may adjust this based on the project's existing conventions.

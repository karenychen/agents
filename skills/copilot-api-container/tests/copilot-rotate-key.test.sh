#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$SCRIPT_DIR/../scripts/copilot-rotate-key.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_fake_bin() {
  local dir state_file
  dir="$1"
  state_file="$2"

  cat > "$dir/uname" <<'SH'
#!/bin/sh
echo Darwin
SH
  chmod +x "$dir/uname"

  cat > "$dir/launchctl" <<'SH'
#!/bin/sh
state_file="$FAKE_LAUNCHCTL_STATE"
case "$1" in
  setenv)
    tmp="${state_file}.tmp.$$"
    awk -F= -v key="$2" '$1 != key' "$state_file" > "$tmp"
    mv "$tmp" "$state_file"
    printf '%s=%s\n' "$2" "$3" >> "$state_file"
    ;;
  unsetenv)
    tmp="${state_file}.tmp.$$"
    awk -F= -v key="$2" '$1 != key' "$state_file" > "$tmp"
    mv "$tmp" "$state_file"
    ;;
  getenv)
    awk -F= -v key="$2" '$1 == key { value=$2 } END { if (value != "") print value }' "$state_file"
    ;;
  *)
    echo "unexpected launchctl command: $*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$dir/launchctl"
}

assert_contains() {
  local file expected
  file="$1"
  expected="$2"
  grep -Fxq "$expected" "$file" || fail "expected '$expected' in $file"
}

assert_not_contains() {
  local file unexpected
  file="$1"
  unexpected="$2"
  if grep -Fxq "$unexpected" "$file"; then
    fail "did not expect '$unexpected' in $file"
  fi
}

assert_section_contains() {
  local file section expected
  file="$1"
  section="$2"
  expected="$3"
  awk -v section="$section" -v expected="$expected" '
    $0 == "[" section "]" { in_section = 1; next }
    /^\[/ { in_section = 0 }
    in_section && $0 == expected { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$file" || fail "expected '$expected' in [$section] of $file"
}

test_sync_launch_env_only_sets_proxy_key() {
  local tmp fake_bin state
  tmp=$(mktemp -d)
  fake_bin="$tmp/bin"
  state="$tmp/launchctl.env"
  mkdir -p "$fake_bin"
  : > "$state"
  make_fake_bin "$fake_bin" "$state"
  printf 'export COPILOT_API_KEY="proxy-key"\n' > "$tmp/.zshrc"

  HOME="$tmp" \
    PATH="$fake_bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_STATE="$state" \
    "$SCRIPT" --sync-launch-env

  assert_contains "$state" "COPILOT_API_KEY=proxy-key"
  assert_not_contains "$state" "GITHUB_COPILOT_API_KEY=proxy-key"
}

test_sync_launch_env_clears_prior_poisoned_github_key() {
  local tmp fake_bin state
  tmp=$(mktemp -d)
  fake_bin="$tmp/bin"
  state="$tmp/launchctl.env"
  mkdir -p "$fake_bin"
  printf 'GITHUB_COPILOT_API_KEY=proxy-key\n' > "$state"
  make_fake_bin "$fake_bin" "$state"
  printf 'export COPILOT_API_KEY="proxy-key"\n' > "$tmp/.zshrc"

  HOME="$tmp" \
    PATH="$fake_bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_STATE="$state" \
    "$SCRIPT" --sync-launch-env

  assert_contains "$state" "COPILOT_API_KEY=proxy-key"
  assert_not_contains "$state" "GITHUB_COPILOT_API_KEY=proxy-key"
}

test_sync_launch_env_updates_codex_tool_token() {
  local tmp fake_bin state config
  tmp=$(mktemp -d)
  fake_bin="$tmp/bin"
  state="$tmp/launchctl.env"
  config="$tmp/.codex/config.toml"
  mkdir -p "$fake_bin" "$tmp/.codex"
  : > "$state"
  make_fake_bin "$fake_bin" "$state"
  printf 'export COPILOT_API_KEY="proxy-key"\n' > "$tmp/.zshrc"
  cat > "$config" <<'TOML'
[features]
memories = true
remote_compaction_v2 = true

[shell_environment_policy]
inherit = "core"

[shell_environment_policy.set]
PATH = "/usr/bin:/bin"
ANTHROPIC_AUTH_TOKEN = "old-key"
ANTHROPIC_BASE_URL = "http://localhost:4141"
TOML

  HOME="$tmp" \
    PATH="$fake_bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_STATE="$state" \
    "$SCRIPT" --sync-launch-env

  assert_section_contains "$config" "shell_environment_policy.set" 'ANTHROPIC_AUTH_TOKEN = "proxy-key"'
  assert_section_contains "$config" "features" 'remote_compaction_v2 = false'
}

test_sync_launch_env_adds_missing_codex_tool_sections() {
  local tmp fake_bin state config
  tmp=$(mktemp -d)
  fake_bin="$tmp/bin"
  state="$tmp/launchctl.env"
  config="$tmp/.codex/config.toml"
  mkdir -p "$fake_bin" "$tmp/.codex"
  : > "$state"
  make_fake_bin "$fake_bin" "$state"
  printf 'export COPILOT_API_KEY="proxy-key"\n' > "$tmp/.zshrc"
  printf 'model = "gpt-5.5"\n' > "$config"

  HOME="$tmp" \
    PATH="$fake_bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_STATE="$state" \
    "$SCRIPT" --sync-launch-env

  assert_section_contains "$config" "features" 'remote_compaction_v2 = false'
  assert_section_contains "$config" "shell_environment_policy.set" 'ANTHROPIC_AUTH_TOKEN = "proxy-key"'
}

test_sync_launch_env_only_sets_proxy_key
test_sync_launch_env_clears_prior_poisoned_github_key
test_sync_launch_env_updates_codex_tool_token
test_sync_launch_env_adds_missing_codex_tool_sections

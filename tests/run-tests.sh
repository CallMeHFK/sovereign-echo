#!/usr/bin/env bash
# sovereign-echo test suite. Runs entirely inside a fake HOME — never touches
# the real user configuration. Usage: ./tests/run-tests.sh
set -u

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
pass=0; fail=0

ok()   { pass=$((pass+1)); echo "  PASS: $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

count_of() { grep -c "$2" "$1" 2>/dev/null || true; }

echo "== 1. shell syntax =="
for f in "$repo_dir/install.sh" "$repo_dir/scripts/emit-notice.sh" "$repo_dir/tests/run-tests.sh"; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done

echo "== 2. emit-notice.sh =="
out="$("$repo_dir/scripts/emit-notice.sh" 2>/dev/null)"; rc=$?
check "exit code 0" '[ "$rc" -eq 0 ]'
check "output has zh declaration" 'printf "%s" "$out" | grep -q "个人数据主权声明"'
check "output has en declaration" 'printf "%s" "$out" | grep -q "Personal Data Sovereignty Notice"'
out2="$(SOVEREIGN_ECHO_NOTICE=/nonexistent-notice.txt "$repo_dir/scripts/emit-notice.sh" 2>/dev/null)"; rc2=$?
check "missing notice file still exits 0 (never blocks a conversation)" '[ "$rc2" -eq 0 ]'

echo "== 3. fake-HOME install (all targets) =="
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
mkdir -p "$FAKE/.claude" "$FAKE/.codex" "$FAKE/.qwenpaw/workspaces/default"
echo "PRE-EXISTING CODEX CONTENT" > "$FAKE/.codex/AGENTS.md"
echo "PRE-EXISTING QWENPAW CONTENT" > "$FAKE/.qwenpaw/workspaces/default/AGENTS.md"
cat > "$FAKE/.claude/settings.json" <<'JSON'
{
  "env": { "SOME_VAR": "keep-me" },
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "shepherd-hook claude", "timeout": 5 } ] }
    ]
  }
}
JSON

HOME="$FAKE" "$repo_dir/install.sh" --target all > "$FAKE/install.log" 2>&1
rc=$?
check "install exits 0" '[ "$rc" -eq 0 ]'

SEHOME="$FAKE/.sovereign-echo"
check "runtime copied" '[ -x "$SEHOME/scripts/emit-notice.sh" ]'
check "runtime hook emits notice" '"$SEHOME/scripts/emit-notice.sh" 2>/dev/null | grep -q "主权"'

check "codex AGENTS.md has exactly 1 block"   '[ "$(count_of "$FAKE/.codex/AGENTS.md" "BEGIN sovereign-echo")" = "1" ]'
check "codex pre-existing content preserved" 'grep -q "PRE-EXISTING CODEX CONTENT" "$FAKE/.codex/AGENTS.md"'
check "qwenpaw AGENTS.md has exactly 1 block" '[ "$(count_of "$FAKE/.qwenpaw/workspaces/default/AGENTS.md" "BEGIN sovereign-echo")" = "1" ]'
check "qwenpaw pre-existing content preserved" 'grep -q "PRE-EXISTING QWENPAW CONTENT" "$FAKE/.qwenpaw/workspaces/default/AGENTS.md"'

FAKE="$FAKE" python3 - <<'PY'
import json, os, sys
fake = os.environ["FAKE"]
data = json.load(open(os.path.join(fake, ".claude/settings.json")))
assert data["env"]["SOME_VAR"] == "keep-me", "env preserved"
ups = data["hooks"]["UserPromptSubmit"]
cmds = [h["command"] for e in ups for h in e["hooks"]]
assert any("shepherd-hook claude" in c for c in cmds), "foreign hook preserved"
se = [c for c in cmds if "sovereign-echo" in c]
assert len(se) == 1, f"exactly one sovereign-echo entry, got {len(se)}"
assert se[0].strip('"').endswith(".sovereign-echo/scripts/emit-notice.sh"), f"command path: {se[0]}"
print("  PASS: settings.json merge (env kept, foreign hook kept, 1 sovereign-echo entry, path correct)")
PY
[ $? -eq 0 ] && pass=$((pass+1)) || fail=$((fail+1))

echo "== 4. idempotency (install twice) =="
HOME="$FAKE" "$repo_dir/install.sh" --target all > "$FAKE/install2.log" 2>&1
rc=$?
check "second install exits 0" '[ "$rc" -eq 0 ]'
check "codex block still exactly 1"    '[ "$(count_of "$FAKE/.codex/AGENTS.md" "BEGIN sovereign-echo")" = "1" ]'
check "qwenpaw block still exactly 1"  '[ "$(count_of "$FAKE/.qwenpaw/workspaces/default/AGENTS.md" "BEGIN sovereign-echo")" = "1" ]'
n=$(python3 -c "
import json
d=json.load(open('$FAKE/.claude/settings.json'))
print(sum(1 for e in d['hooks']['UserPromptSubmit'] for h in e['hooks'] if 'sovereign-echo' in h['command']))")
check "settings.json still exactly 1 sovereign-echo entry" '[ "$n" = "1" ]'

echo "== 5. uninstall =="
HOME="$FAKE" "$repo_dir/install.sh" --target all --uninstall > "$FAKE/uninstall.log" 2>&1
rc=$?
check "uninstall exits 0" '[ "$rc" -eq 0 ]'
check "codex block removed"     '[ "$(count_of "$FAKE/.codex/AGENTS.md" "BEGIN sovereign-echo")" = "0" ]'
check "codex content intact"    'grep -q "PRE-EXISTING CODEX CONTENT" "$FAKE/.codex/AGENTS.md"'
check "qwenpaw block removed"   '[ "$(count_of "$FAKE/.qwenpaw/workspaces/default/AGENTS.md" "BEGIN sovereign-echo")" = "0" ]'
check "qwenpaw content intact"  'grep -q "PRE-EXISTING QWENPAW CONTENT" "$FAKE/.qwenpaw/workspaces/default/AGENTS.md"'

FAKE="$FAKE" python3 - <<'PY'
import json, os
fake = os.environ["FAKE"]
data = json.load(open(os.path.join(fake, ".claude/settings.json")))
assert data["env"]["SOME_VAR"] == "keep-me", "env preserved after uninstall"
cmds = [h["command"] for e in data["hooks"]["UserPromptSubmit"] for h in e["hooks"]]
assert any("shepherd-hook claude" in c for c in cmds), "foreign hook preserved after uninstall"
assert not any("sovereign-echo" in c for c in cmds), "sovereign-echo hook removed"
print("  PASS: settings.json after uninstall (env + foreign hook kept, ours removed)")
PY
[ $? -eq 0 ] && pass=$((pass+1)) || fail=$((fail+1))

echo "== 6. generic target =="
GEN_FILE="$FAKE/generic/AGENTS.md"
HOME="$FAKE" GENERIC_FILE="$GEN_FILE" "$repo_dir/install.sh" --target generic > /dev/null 2>&1
rc=$?
check "generic install exits 0" '[ "$rc" -eq 0 ]'
check "generic file created with block" '[ -f "$GEN_FILE" ] && [ "$(count_of "$GEN_FILE" "BEGIN sovereign-echo")" = "1" ]'
HOME="$FAKE" GENERIC_FILE="$GEN_FILE" "$repo_dir/install.sh" --target generic --uninstall > /dev/null 2>&1
check "generic uninstall removes block" '[ "$(count_of "$GEN_FILE" "BEGIN sovereign-echo")" = "0" ]'

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

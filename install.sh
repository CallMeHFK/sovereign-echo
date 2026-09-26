#!/usr/bin/env bash
# sovereign-echo installer
#
# Wires the personal data-sovereignty notice into coding agents so it is
# restated in every conversation.
#
# Targets:
#   claude   Claude Code   -> UserPromptSubmit hook in ~/.claude/settings.json
#   codex    OpenAI Codex  -> marker block in ~/.codex/AGENTS.md
#   qwenpaw  QwenPaw       -> marker block in workspace AGENTS.md
#   generic  any agent     -> marker block in $GENERIC_FILE (AGENTS.md-style)
#
# Usage:
#   ./install.sh --target claude --target codex
#   ./install.sh --target all
#   ./install.sh --target all --uninstall
#   ./install.sh --print-notice
#
# Environment overrides:
#   SOVEREIGN_ECHO_HOME  runtime dir            (default: $HOME/.sovereign-echo)
#   CLAUDE_HOME          Claude config dir      (default: $HOME/.claude)
#   CODEX_HOME           Codex config dir       (default: $HOME/.codex)
#   QWENPAW_WORKSPACE    QwenPaw workspace dir  (default: $HOME/.qwenpaw/workspaces/default)
#   GENERIC_FILE         target file for --target generic
#   SOVEREIGN_ECHO_NOTICE  custom notice file used by the hook at runtime
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

SE_HOME="${SOVEREIGN_ECHO_HOME:-$HOME/.sovereign-echo}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
QWENPAW_WORKSPACE="${QWENPAW_WORKSPACE:-$HOME/.qwenpaw/workspaces/default}"
GENERIC_FILE="${GENERIC_FILE:-}"

MARK_BEGIN="<!-- BEGIN sovereign-echo"
MARK_END="<!-- END sovereign-echo"

uninstall=0
targets=()

usage() { sed -n '2,30p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --target|-t)
      [ $# -ge 2 ] || { echo "error: --target needs a value" >&2; exit 2; }
      case "$2" in
        all) targets+=(claude codex qwenpaw) ;;
        claude|codex|qwenpaw|generic) targets+=("$2") ;;
        *) echo "error: unknown target '$2' (claude|codex|qwenpaw|generic|all)" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    --print-notice) cat "$repo_dir/declarations/notice.compact.txt"; exit 0 ;;
    --help|-h) usage ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ ${#targets[@]} -eq 0 ]; then
  echo "Nothing to do. Pass --target claude|codex|qwenpaw|generic|all (see --help)." >&2
  exit 2
fi

require_python3() {
  command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required for JSON merging" >&2; exit 1; }
}

# Remove any existing sovereign-echo marker block from a file (no-op if absent).
strip_block() {
  local file="$1"
  [ -f "$file" ] || return 0
  local tmp; tmp="$(mktemp)"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    index($0, b) { skip=1; next }
    index($0, e) { skip=0; next }
    !skip { print }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Insert the marker block into a file (idempotent: strip first, then append).
insert_block() {
  local file="$1"
  strip_block "$file"
  if [ "$uninstall" -eq 1 ]; then
    echo "  removed notice block from $file"
    return 0
  fi
  if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then echo >> "$file"; fi
  cat "$repo_dir/templates/agents-block.md" >> "$file"
  echo "  inserted notice block into $file"
}

# --- claude -----------------------------------------------------------------
target_claude() {
  require_python3
  local settings="$CLAUDE_HOME/settings.json"
  if [ "$uninstall" -eq 1 ]; then
    [ -f "$settings" ] || { echo "claude: no $settings, nothing to remove"; return 0; }
    cp "$settings" "$settings.bak-sovereign-echo-$(date +%s)"
    SE_HOME="$SE_HOME" python3 - "$settings" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
hooks = data.get("hooks", {})
for event, entries in list(hooks.items()):
    kept = []
    for entry in entries:
        cmds = [h.get("command", "") for h in entry.get("hooks", [])]
        if not any("sovereign-echo" in c for c in cmds):
            kept.append(entry)
    if kept:
        hooks[event] = kept
    else:
        hooks.pop(event, None)
if not hooks:
    data.pop("hooks", None)
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
    echo "claude: removed sovereign-echo hook from $settings"
    return 0
  fi
  if [ ! -d "$CLAUDE_HOME" ]; then
    echo "claude: $CLAUDE_HOME not found (Claude Code not installed?) — skipped" >&2
    return 0
  fi
  install_runtime
  mkdir -p "$CLAUDE_HOME"
  cp -f "$settings" "$settings.bak-sovereign-echo-$(date +%s)" 2>/dev/null || true
  SE_HOME="$SE_HOME" python3 - "$settings" <<'PY'
import json, os, sys
path = sys.argv[1]
se_home = os.environ["SE_HOME"]
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
cmd = '"%s/scripts/emit-notice.sh"' % se_home
hooks = data.setdefault("hooks", {})
entries = [e for e in hooks.get("UserPromptSubmit", [])
           if not any("sovereign-echo" in h.get("command", "") for h in e.get("hooks", []))]
entries.append({"hooks": [{"type": "command", "command": cmd, "timeout": 5}]})
hooks["UserPromptSubmit"] = entries
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  echo "claude: UserPromptSubmit hook installed in $settings"
}

# --- codex ------------------------------------------------------------------
target_codex() {
  if [ "$uninstall" -eq 1 ]; then
    [ -f "$CODEX_HOME/AGENTS.md" ] || { echo "codex: no AGENTS.md, nothing to remove"; return 0; }
    insert_block "$CODEX_HOME/AGENTS.md"
    return 0
  fi
  if [ ! -d "$CODEX_HOME" ]; then
    echo "codex: $CODEX_HOME not found (Codex not installed?) — skipped" >&2
    return 0
  fi
  insert_block "$CODEX_HOME/AGENTS.md"
}

# --- qwenpaw ----------------------------------------------------------------
target_qwenpaw() {
  if [ "$uninstall" -eq 1 ]; then
    [ -f "$QWENPAW_WORKSPACE/AGENTS.md" ] || { echo "qwenpaw: no AGENTS.md, nothing to remove"; return 0; }
    insert_block "$QWENPAW_WORKSPACE/AGENTS.md"
    return 0
  fi
  if [ ! -d "$QWENPAW_WORKSPACE" ]; then
    echo "qwenpaw: workspace $QWENPAW_WORKSPACE not found — skipped" >&2
    echo "         set QWENPAW_WORKSPACE to your workspace dir and retry" >&2
    return 0
  fi
  insert_block "$QWENPAW_WORKSPACE/AGENTS.md"
}

# --- generic ----------------------------------------------------------------
target_generic() {
  if [ -z "$GENERIC_FILE" ]; then
    echo "generic: set GENERIC_FILE=/path/to/AGENTS.md (or CLAUDE.md, GEMINI.md, ...)" >&2
    exit 2
  fi
  if [ "$uninstall" -eq 1 ]; then
    [ -f "$GENERIC_FILE" ] || { echo "generic: $GENERIC_FILE does not exist, nothing to remove"; return 0; }
    insert_block "$GENERIC_FILE"
    return 0
  fi
  mkdir -p "$(dirname "$GENERIC_FILE")"
  touch "$GENERIC_FILE"
  insert_block "$GENERIC_FILE"
}

# --- runtime copy ------------------------------------------------------------
runtime_installed=0
install_runtime() {
  [ "$runtime_installed" -eq 1 ] && return 0
  mkdir -p "$SE_HOME"
  cp -r "$repo_dir/declarations" "$repo_dir/scripts" "$repo_dir/templates" "$SE_HOME/"
  chmod +x "$SE_HOME"/scripts/*.sh
  runtime_installed=1
  echo "runtime installed to $SE_HOME"
}

for t in "${targets[@]}"; do
  echo "==> $t"
  "target_$t"
done

if [ "$uninstall" -eq 0 ]; then
  install_runtime
fi

echo
if [ "$uninstall" -eq 1 ]; then
  echo "sovereign-echo uninstalled from: ${targets[*]}"
  echo "Runtime files remain in $SE_HOME — remove with: rm -rf \"$SE_HOME\""
else
  target_flags=""
  for t in "${targets[@]}"; do target_flags="$target_flags --target $t"; done
  echo "Done. Your data-sovereignty notice will now be restated in every conversation."
  echo "Preview the notice:  $repo_dir/install.sh --print-notice"
  echo "Uninstall later:     $repo_dir/install.sh$target_flags --uninstall"
fi

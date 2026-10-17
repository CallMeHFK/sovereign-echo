#!/usr/bin/env bash
# sovereign-echo installer
#
# Wires the personal data-sovereignty notice into coding agents so it is
# restated in every conversation.
#
# The per-turn notice is shipped sealed: it is encrypted (SM4-GCM) and signed
# (SM2/SM3) with a key pair that only you hold, so the provider receives an
# opaque envelope rather than readable prose.
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
#   ./install.sh --print-sealed
#   ./install.sh --keygen
#
# Keys:
#   --keygen      (re)generate the SM2 key pair in $SOVEREIGN_ECHO_HOME/keys
#   --no-keygen   install without generating a key pair
#
# Environment overrides:
#   SOVEREIGN_ECHO_HOME  runtime dir            (default: $HOME/.sovereign-echo)
#   CLAUDE_HOME          Claude config dir      (default: $HOME/.claude)
#   CODEX_HOME           Codex config dir       (default: $HOME/.codex)
#   QWENPAW_WORKSPACE    QwenPaw workspace dir  (default: $HOME/.qwenpaw/workspaces/default)
#   GENERIC_FILE         target file for --target generic
#   SOVEREIGN_ECHO_NOTICE  custom notice file used by the hook at runtime
#   SOVEREIGN_ECHO_SEAL  sealed (default) | plain — what the hook emits
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

SE_HOME="${SOVEREIGN_ECHO_HOME:-$HOME/.sovereign-echo}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
QWENPAW_WORKSPACE="${QWENPAW_WORKSPACE:-$HOME/.qwenpaw/workspaces/default}"
GENERIC_FILE="${GENERIC_FILE:-}"
notice_file="${SOVEREIGN_ECHO_NOTICE:-$repo_dir/declarations/notice.compact.txt}"
sealer="$repo_dir/crypto/smseal.py"
keys_dir="$SE_HOME/keys"

MARK_BEGIN="<!-- BEGIN sovereign-echo"
MARK_END="<!-- END sovereign-echo"

uninstall=0
auto_keygen=1
do_keygen=0
targets=()

# --- keys -------------------------------------------------------------------
have_private_key() { [ -f "$keys_dir/sm2-private.pem" ] && [ -f "$keys_dir/sm2-public.pem" ]; }

# Generate the SM2 key pair. Prints the KeyId on success. Never aborts the
# installer: a keygen failure is a warning, never a failed install.
keygen() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[sovereign-echo] keygen skipped: python3 not found in PATH" >&2
    return 1
  fi
  if [ ! -f "$sealer" ]; then
    echo "[sovereign-echo] keygen skipped: $sealer missing" >&2
    return 1
  fi
  local out rc=0
  out="$(python3 "$sealer" keygen --home "$SE_HOME" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[sovereign-echo] keygen failed (exit $rc)" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
  echo "Keys written to $keys_dir"
  printf '%s\n' "$out"
}

ensure_keys() {
  if have_private_key; then
    [ "$do_keygen" -eq 1 ] && echo "Keystore already present in $keys_dir (use keygen --force to replace)"
    return 0
  fi
  if [ "$auto_keygen" -eq 0 ]; then
    echo "No keystore — skipped (--no-keygen); run '$0 --keygen' later"
    return 0
  fi
  echo "Generating SM2 key pair (nobody else can ever open your sealed notice)…"
  keygen || echo "Continuing without a keystore. sealed mode will emit nothing until you run: $0 --keygen" >&2
}

print_sealed() {
  local notice="$1"
  if ! command -v python3 >/dev/null 2>&1; then echo "error: python3 not found in PATH" >&2; exit 1; fi
  if [ ! -f "$sealer" ]; then echo "error: $sealer missing" >&2; exit 1; fi
  if [ ! -f "$notice" ]; then echo "error: notice file not found: $notice" >&2; exit 1; fi
  if ! have_private_key; then
    echo "error: no keystore in $keys_dir — run '$0 --keygen' first" >&2
    exit 1
  fi
  python3 "$sealer" seal --notice "$notice" --home "$SE_HOME" </dev/null
}

usage() { sed -n '2,36p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 0; }

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
    --keygen) do_keygen=1; auto_keygen=1; shift ;;
    --no-keygen) auto_keygen=0; shift ;;
    --print-notice) cat "$notice_file"; exit 0 ;;
    --print-sealed) print_sealed "$notice_file"; exit 0;;
    --help|-h) usage ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ "$do_keygen" -eq 1 ] && [ ${#targets[@]} -eq 0 ]; then
  ensure_keys
  have_private_key || exit 1
  exit 0
fi

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
  if [ -d "$repo_dir/crypto" ]; then
    cp -r "$repo_dir/crypto" "$SE_HOME/"
    chmod 0644 "$SE_HOME"/crypto/*.py
    # Python writes __pycache__ next to these modules as soon as the hook runs;
    # never ship a stale copy of it (or any other bytecode) into the runtime.
    rm -rf "$SE_HOME"/crypto/__pycache__
  else
    echo "[sovereign-echo] warning: $repo_dir/crypto missing — sealed mode unavailable" >&2
  fi
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
  ensure_keys
fi

echo
if [ "$uninstall" -eq 1 ]; then
  echo "sovereign-echo uninstalled from: ${targets[*]}"
  echo "Runtime files remain in $SE_HOME — remove with: rm -rf \"$SE_HOME\""
else
  target_flags=""
  for t in "${targets[@]}"; do target_flags="$target_flags --target $t"; done
  echo "Done. Your data-sovereignty notice will now be restated in every conversation"
  echo "as a sealed envelope only you can open ($keys_dir/sm2-private.pem — never share it)."
  echo "Preview the notice:  $repo_dir/install.sh --print-notice"
  echo "Preview the envelope: $repo_dir/install.sh --print-sealed"
  echo "Uninstall later:     $repo_dir/install.sh$target_flags --uninstall"
fi

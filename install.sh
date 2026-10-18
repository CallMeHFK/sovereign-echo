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
#   ./install.sh                     # zero-config: wires every agent it detects
#   ./install.sh --target claude     # or pick targets explicitly (repeatable)
#   ./install.sh --target all        # claude + codex + qwenpaw
#   ./install.sh --status            # what is wired, and where the keys are
#   ./install.sh --uninstall         # removes all wiring, keeps your keys
#   ./install.sh --uninstall --purge # also deletes the private key (permanent!)
#   ./install.sh --print-notice
#   ./install.sh --print-sealed
#   ./install.sh --keygen            # (re)generate the key pair, prints KeyId
#   ./install.sh --keygen --force    # rotate the key pair
#   ./install.sh --export-key PATH   # back the private key up to PATH (0600)
#
# Keys:
#   --keygen        (re)generate the SM2 key pair in $SOVEREIGN_ECHO_HOME/keys
#   --no-keygen     install without generating a key pair
#   --force         with --keygen: replace an existing key pair (rotation)
#   --export-key PATH  copy the private key to PATH (mode 0600)
#
# Other flags:
#   --uninstall     remove what sovereign-echo wired (bare: auto-detects all)
#   --purge         with --uninstall: also delete $SOVEREIGN_ECHO_HOME and the
#                   private key — irreversible, past envelopes become unreadable
#   --yes           confirm --purge without prompting (needed when stdin is not
#                   a terminal; a harmless no-op otherwise)
#   --status        print a read-only report and exit 0
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
purge=0
purge_confirmed=0
assume_yes=0
force=0
status=0
auto_keygen=1
do_keygen=0
export_key=""
targets=()
wired=()      # "target — detail" for the final summary
skipped=()    # "target — reason" for the final summary
explicit_targets=0

err() { echo "error: $*" >&2; }

note_wired()   { wired+=("$1"); }
note_skipped() { echo "  skipped: $1" >&2; skipped+=("$1"); }

# --- keys -------------------------------------------------------------------
have_private_key() { [ -f "$keys_dir/sm2-private.pem" ] && [ -f "$keys_dir/sm2-public.pem" ]; }

# Read-only: the KeyId of the local key pair (16 lowercase hex chars), or
# nothing if the keys are missing or unreadable. Never writes, never generates.
key_id_now() {
  command -v python3 >/dev/null 2>&1 || return 1
  [ -f "$sealer" ] || return 1
  PYTHONDONTWRITEBYTECODE=1 python3 - "$sealer" "$keys_dir" <<'PY' 2>/dev/null
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[1])))
import smseal
keys = sys.argv[2]
pub = os.path.join(keys, "sm2-public.pem")
priv = os.path.join(keys, "sm2-private.pem")
try:
    if os.path.exists(pub):
        k = smseal.keyid(smseal.load_public_pem(open(pub).read()))
    elif os.path.exists(priv):
        k = smseal.keyid(smseal.load_private_pem(open(priv).read()).public_key())
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
sys.stdout.write(k + "\n")
PY
}

# The custody warning, printed the moment a key pair comes into existence
# (fresh keygen or rotation) and whenever the private key is exported.
print_key_custody() {
  cat <<EOF

  Key custody — read this once:
    Private key: $keys_dir/sm2-private.pem (mode 0600)
    * NEVER share this file. Anyone holding it can open every notice you ever sealed.
    * BACK IT UP now. Without it, past sealed notices cannot be opened —
      there is no recovery mechanism. For example:
        $0 --export-key /path/to/sm2-private.pem
EOF
}

# Generate the SM2 key pair. Prints the KeyId on success. Never aborts the
# installer on its own: a keygen failure is a warning, never a failed install.
keygen() {
  local force_flag=""
  [ "$force" -eq 1 ] && force_flag="--force"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[sovereign-echo] keygen skipped: python3 not found in PATH" >&2
    return 1
  fi
  if [ ! -f "$sealer" ]; then
    echo "[sovereign-echo] keygen skipped: $sealer missing" >&2
    return 1
  fi
  local out rc=0
  # shellcheck disable=SC2086
  out="$(python3 "$sealer" keygen --home "$SE_HOME" $force_flag 2>&1)" || rc=$?
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
    if [ "$do_keygen" -eq 1 ] && [ "$force" -eq 1 ]; then
      echo "Rotating the key pair in $keys_dir (--force)…"
      echo "WARNING: every notice sealed with the previous key becomes permanently unreadable." >&2
      if keygen; then
        print_key_custody
        return 0
      fi
      echo "Rotation failed — continuing with the previous key pair." >&2
      return 1
    fi
    if [ "$do_keygen" -eq 1 ]; then
      echo "Keystore already present in $keys_dir — keeping it."
      echo "To replace it anyway: $0 --keygen --force"
      echo "(rotation makes every previously sealed notice permanently unreadable)"
    fi
    return 0
  fi
  if [ "$auto_keygen" -eq 0 ]; then
    echo "No keystore — skipped (--no-keygen); run '$0 --keygen' later"
    return 0
  fi
  echo "Generating SM2 key pair (nobody else can ever open your sealed notice)…"
  if keygen; then
    print_key_custody
    return 0
  fi
  echo "Continuing without a keystore. Sealed mode will emit nothing until you run: $0 --keygen" >&2
  return 1
}

do_export_key() {
  local dest="$1"
  if ! have_private_key; then
    err "no keystore in $keys_dir — run '$0 --keygen' first"
    exit 1
  fi
  if [ -e "$dest" ] && [ "$force" -eq 0 ]; then
    err "$dest already exists — refusing to overwrite it (pass --force to replace)"
    exit 1
  fi
  local dir
  dir="$(dirname "$dest")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null || { err "cannot create $dir — pick another --export-key path"; exit 1; }
  fi
  if [ ! -w "$dir" ]; then
    err "$dir is not writable — pick another --export-key path"
    exit 1
  fi
  print_key_custody
  cp "$keys_dir/sm2-private.pem" "$dest"
  chmod 600 "$dest"
  echo "Private key exported to $dest (mode 0600)."
  echo "Keep it somewhere safe and offline — without it, past sealed notices cannot be opened."
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

usage() { sed -n '2,/^set -euo pipefail/p' "${BASH_SOURCE[0]:-$0}" | sed '$d; s/^# \{0,1\}//'; exit 0; }

# --- detection (read-only) ---------------------------------------------------
# Is the agent's own config directory present? (zero-config install detection)
agent_home_present() {
  case "$1" in
    claude)  [ -d "$CLAUDE_HOME" ] ;;
    codex)   [ -d "$CODEX_HOME" ] ;;
    qwenpaw) [ -d "$QWENPAW_WORKSPACE" ] ;;
  esac
}

# Does the file carry a sovereign-echo marker block?
block_installed() {
  [ -f "$1" ] && grep -q "$MARK_BEGIN" "$1" 2>/dev/null
}

# Is the sovereign-echo hook wired into Claude's settings.json?
claude_hook_installed() {
  local settings="$CLAUDE_HOME/settings.json"
  [ -f "$settings" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    local rc=0
    python3 - "$settings" <<'PY' 2>/dev/null || rc=$?
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(2)
for e in data.get("hooks", {}).get("UserPromptSubmit", []):
    for h in e.get("hooks", []):
        c = h.get("command", "")
        if "sovereign-echo" in c or "emit-notice.sh" in c:
            sys.exit(0)
sys.exit(1)
PY
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 1 ] && return 1
  fi
  # No python3 (or unreadable JSON): fall back to a text match on the command.
  grep -q "emit-notice.sh" "$settings" 2>/dev/null
}

# Octal permission bits, portable across GNU/BSD stat.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null && return 0
  stat -f '%Lp' "$1" 2>/dev/null && return 0
  echo "?"
}

# --- pre-flight (friendly failures, never a raw traceback) -------------------
require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 was not found in PATH."
    echo "     python3 is required: without it the sealed hook cannot run, and" >&2
    echo "     neither key generation nor the Claude Code settings merge works." >&2
    echo "     Install python3 (package manager or python.org), then run $0 again." >&2
    exit 1
  fi
}

validate_settings_json() {
  local settings="$1"
  [ -f "$settings" ] || return 0
  local rc=0
  python3 - "$settings" <<'PY' 2>/dev/null || rc=$?
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
if not isinstance(data, dict):
    sys.exit(3)
PY
  if [ "$rc" -eq 0 ]; then return 0; fi
  err "$settings is not a valid JSON object."
  echo "     Fix the file by hand, or restore one of the *.bak-sovereign-echo-*" >&2
  echo "     backups next to it, then run $0 again." >&2
  exit 1
}

# --- marker blocks ------------------------------------------------------------
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
  local settings="$CLAUDE_HOME/settings.json"
  if [ "$uninstall" -eq 1 ]; then
    if ! claude_hook_installed; then
      echo "claude: no sovereign-echo hook in $settings — nothing to remove"
      return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      err "python3 is required to rewrite $settings — the claude hook was NOT removed"
      note_skipped "claude — python3 missing (cannot rewrite $settings)"
      return 0
    fi
    local backup="$settings.bak-sovereign-echo-$(date +%s)-$$"
    cp "$settings" "$backup"
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
        if not any("sovereign-echo" in c or "emit-notice.sh" in c for c in cmds):
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
    echo "       (previous settings backed up to $(basename "$backup"))"
    return 0
  fi
  if [ ! -d "$CLAUDE_HOME" ]; then
    note_skipped "claude — $CLAUDE_HOME not found (Claude Code not installed?)"
    return 0
  fi
  if [ ! -w "$CLAUDE_HOME" ]; then
    note_skipped "claude — $CLAUDE_HOME is not writable (fix its permissions, or set CLAUDE_HOME elsewhere)"
    return 0
  fi
  if [ -f "$settings" ] && [ ! -w "$settings" ]; then
    note_skipped "claude — $settings is not writable (fix its permissions)"
    return 0
  fi
  install_runtime
  local backup=""
  if [ -f "$settings" ]; then
    backup="$settings.bak-sovereign-echo-$(date +%s)-$$"
    cp "$settings" "$backup" 2>/dev/null || backup=""
  fi
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
           if not any("sovereign-echo" in h.get("command", "") or "emit-notice.sh" in h.get("command", "")
                      for h in e.get("hooks", []))]
entries.append({"hooks": [{"type": "command", "command": cmd, "timeout": 5}]})
hooks["UserPromptSubmit"] = entries
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  echo "claude: UserPromptSubmit hook installed in $settings"
  if [ -n "$backup" ]; then
    echo "       (previous settings backed up to $(basename "$backup"))"
  fi
  note_wired "claude — UserPromptSubmit hook in $settings"
  return 0
}

# --- codex ------------------------------------------------------------------
target_codex() {
  local file="$CODEX_HOME/AGENTS.md"
  if [ "$uninstall" -eq 1 ]; then
    if ! block_installed "$file"; then
      echo "codex: no notice block in $file — nothing to remove"
      return 0
    fi
    insert_block "$file"
    return 0
  fi
  if [ ! -d "$CODEX_HOME" ]; then
    note_skipped "codex — $CODEX_HOME not found (Codex not installed?)"
    return 0
  fi
  if [ ! -w "$CODEX_HOME" ] || { [ -f "$file" ] && [ ! -w "$file" ]; }; then
    note_skipped "codex — cannot write $file (fix its permissions, or set CODEX_HOME elsewhere)"
    return 0
  fi
  insert_block "$file"
  note_wired "codex — notice block in $file"
  return 0
}

# --- qwenpaw ----------------------------------------------------------------
target_qwenpaw() {
  local file="$QWENPAW_WORKSPACE/AGENTS.md"
  if [ "$uninstall" -eq 1 ]; then
    if ! block_installed "$file"; then
      echo "qwenpaw: no notice block in $file — nothing to remove"
      return 0
    fi
    insert_block "$file"
    return 0
  fi
  if [ ! -d "$QWENPAW_WORKSPACE" ]; then
    note_skipped "qwenpaw — workspace $QWENPAW_WORKSPACE not found (set QWENPAW_WORKSPACE to your workspace dir)"
    return 0
  fi
  if [ ! -w "$QWENPAW_WORKSPACE" ] || { [ -f "$file" ] && [ ! -w "$file" ]; }; then
    note_skipped "qwenpaw — cannot write $file (fix its permissions, or set QWENPAW_WORKSPACE elsewhere)"
    return 0
  fi
  insert_block "$file"
  note_wired "qwenpaw — notice block in $file"
  return 0
}

# --- generic ----------------------------------------------------------------
target_generic() {
  if [ -z "$GENERIC_FILE" ]; then
    note_skipped "generic — GENERIC_FILE is not set (example: GENERIC_FILE=~/myagent/AGENTS.md $0 --target generic)"
    return 0
  fi
  local file="$GENERIC_FILE"
  if [ "$uninstall" -eq 1 ]; then
    if ! block_installed "$file"; then
      echo "generic: no notice block in $file — nothing to remove"
      return 0
    fi
    insert_block "$file"
    return 0
  fi
  local dir
  dir="$(dirname "$file")"
  if [ -d "$dir" ] && [ ! -w "$dir" ]; then
    note_skipped "generic — $dir is not writable (fix its permissions, or pick another GENERIC_FILE)"
    return 0
  fi
  if [ -f "$file" ] && [ ! -w "$file" ]; then
    note_skipped "generic — $file is not writable (fix its permissions)"
    return 0
  fi
  if ! mkdir -p "$dir" 2>/dev/null; then
    note_skipped "generic — cannot create $dir (pick another GENERIC_FILE)"
    return 0
  fi
  if ! touch "$file" 2>/dev/null; then
    note_skipped "generic — cannot create $file (pick another GENERIC_FILE)"
    return 0
  fi
  insert_block "$file"
  note_wired "generic — notice block in $file"
  return 0
}

# --- runtime copy ------------------------------------------------------------
runtime_installed=0
install_runtime() {
  [ "$runtime_installed" -eq 1 ] && return 0
  if ! mkdir -p "$SE_HOME" 2>/dev/null; then
    err "cannot create $SE_HOME — check the permissions, or set SOVEREIGN_ECHO_HOME to a writable directory"
    exit 1
  fi
  if [ ! -w "$SE_HOME" ]; then
    err "$SE_HOME is not writable — check the permissions, or set SOVEREIGN_ECHO_HOME elsewhere"
    exit 1
  fi
  # SE_HOME holds the private key: keep it to ourselves.
  chmod 700 "$SE_HOME"
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
  return 0
}

# --- status (read-only, always exits 0) --------------------------------------
cmd_status() {
  echo "sovereign-echo status"
  echo
  if [ -d "$SE_HOME/scripts" ]; then
    echo "Runtime:  present at $SE_HOME"
  elif [ -d "$SE_HOME" ]; then
    echo "Runtime:  not installed (only leftover files in $SE_HOME, no runtime scripts)"
  else
    echo "Runtime:  not installed (nothing at $SE_HOME)"
  fi
  if have_private_key; then
    local keyid=""
    keyid="$(key_id_now || true)"
    echo "Keys:     $keys_dir"
    if [ -n "$keyid" ]; then
      echo "          KeyId: $keyid"
    else
      echo "          KeyId: unknown (python3 or crypto/ missing — cannot read the key pair)"
    fi
    echo "          private: $keys_dir/sm2-private.pem (mode $(file_mode "$keys_dir/sm2-private.pem"))"
    echo "          public:  $keys_dir/sm2-public.pem (mode $(file_mode "$keys_dir/sm2-public.pem"))"
  elif [ -d "$keys_dir" ]; then
    echo "Keys:     incomplete pair in $keys_dir — run $0 --keygen to repair"
  else
    echo "Keys:     no key pair yet (one is generated on install)"
  fi
  echo
  echo "Targets:"
  if claude_hook_installed; then
    echo "  claude    wired — UserPromptSubmit hook in $CLAUDE_HOME/settings.json"
  elif [ ! -d "$CLAUDE_HOME" ]; then
    echo "  claude    not wired — $CLAUDE_HOME not found (Claude Code not installed?)"
  else
    echo "  claude    not wired — no sovereign-echo hook in $CLAUDE_HOME/settings.json"
  fi
  if block_installed "$CODEX_HOME/AGENTS.md"; then
    echo "  codex     wired — notice block in $CODEX_HOME/AGENTS.md"
  else
    echo "  codex     not wired — no notice block in $CODEX_HOME/AGENTS.md"
  fi
  if block_installed "$QWENPAW_WORKSPACE/AGENTS.md"; then
    echo "  qwenpaw   wired — notice block in $QWENPAW_WORKSPACE/AGENTS.md"
  else
    echo "  qwenpaw   not wired — no notice block in $QWENPAW_WORKSPACE/AGENTS.md"
  fi
  if [ -z "$GENERIC_FILE" ]; then
    echo "  generic   not set — wire with: GENERIC_FILE=/path/to/AGENTS.md $0 --target generic"
  elif block_installed "$GENERIC_FILE"; then
    echo "  generic   wired — notice block in $GENERIC_FILE"
  else
    echo "  generic   not wired — no notice block in $GENERIC_FILE"
  fi
  echo
  if [ -d "$SE_HOME/scripts" ] || claude_hook_installed \
     || block_installed "$CODEX_HOME/AGENTS.md" || block_installed "$QWENPAW_WORKSPACE/AGENTS.md"; then
    echo "sovereign-echo is installed. Check any time with: ./install.sh --status"
  elif [ -d "$keys_dir" ]; then
    echo "sovereign-echo is not installed. The key pair in $keys_dir was kept —"
    echo "you still need it to open notices sealed in the past. Delete it with:"
    echo "  ./install.sh --uninstall --purge --yes"
  else
    echo "sovereign-echo is not installed. Run ./install.sh to set it up —"
    echo "it wires every agent it detects, no flags needed."
  fi
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target|-t)
      [ $# -ge 2 ] || { err "--target needs a value"; exit 2; }
      case "$2" in
        all) targets+=(claude codex qwenpaw); explicit_targets=1 ;;
        claude|codex|qwenpaw|generic) targets+=("$2"); explicit_targets=1 ;;
        *) err "unknown target '$2' (claude|codex|qwenpaw|generic|all)"; exit 2 ;;
      esac
      shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    --purge) purge=1; shift ;;
    --yes) assume_yes=1; shift ;;
    --force) force=1; shift ;;
    --status) status=1; shift ;;
    --keygen) do_keygen=1; auto_keygen=1; shift ;;
    --no-keygen) auto_keygen=0; shift ;;
    --export-key)
      [ $# -ge 2 ] || { err "--export-key needs a path"; exit 2; }
      export_key="$2"; shift 2 ;;
    --print-notice)
      [ -f "$notice_file" ] || { err "notice file not found: $notice_file"; exit 1; }
      cat "$notice_file"; exit 0 ;;
    --print-sealed) print_sealed "$notice_file"; exit 0 ;;
    --help|-h) usage ;;
    *) err "unknown argument '$1' (see --help)"; exit 2 ;;
  esac
done

if [ "$status" -eq 1 ]; then
  cmd_status
fi

# --- resolve what to act on ---------------------------------------------------
if [ "$uninstall" -eq 1 ]; then
  if [ ${#targets[@]} -eq 0 ]; then
    # One-command uninstall: find whatever is actually wired.
    claude_hook_installed && targets+=(claude)
    block_installed "$CODEX_HOME/AGENTS.md" && targets+=(codex)
    block_installed "$QWENPAW_WORKSPACE/AGENTS.md" && targets+=(qwenpaw)
    if [ -n "$GENERIC_FILE" ] && block_installed "$GENERIC_FILE"; then
      targets+=(generic)
    fi
    if [ ${#targets[@]} -gt 0 ]; then
      echo "Found sovereign-echo wired into: ${targets[*]}"
    elif [ -d "$SE_HOME" ]; then
      echo "No wiring found — but $SE_HOME still exists; cleaning it up."
    else
      echo "sovereign-echo is not installed — nothing to remove."
      exit 0
    fi
  fi
elif [ ${#targets[@]} -eq 0 ] && [ "$do_keygen" -eq 0 ] && [ -z "$export_key" ]; then
  # Zero-config install: wire every agent we can detect.
  for t in claude codex qwenpaw; do
    agent_home_present "$t" && targets+=("$t")
  done
  if [ ${#targets[@]} -eq 0 ]; then
    err "no coding-agent configuration found — nothing to wire."
    echo "     Looked for: $CLAUDE_HOME (Claude Code), $CODEX_HOME (Codex)," >&2
    echo "                 $QWENPAW_WORKSPACE (QwenPaw)." >&2
    echo "     Install one of those agents and re-run, or wire a target explicitly:" >&2
    echo "       ./install.sh --target claude" >&2
    echo "       GENERIC_FILE=/path/to/AGENTS.md ./install.sh --target generic" >&2
    exit 2
  fi
  echo "Detected agents: ${targets[*]}"
fi

# --- --purge confirmation (before anything is touched) ------------------------
if [ "$purge" -eq 1 ] && [ ! -d "$SE_HOME" ]; then
  echo "--purge: nothing at $SE_HOME — nothing to purge."
  purge=0
fi
if [ "$purge" -eq 1 ]; then
  if [ "$assume_yes" -eq 1 ]; then
    purge_confirmed=1
  elif [ -t 0 ]; then
    echo "WARNING: --purge deletes $SE_HOME entirely, including the private key." >&2
    echo "         Every notice sealed so far becomes permanently unreadable —" >&2
    echo "         there is no recovery mechanism." >&2
    printf "Delete everything including the private key? [y/N] " >&2
    answer=""
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes|YES)
        purge_confirmed=1 ;;
      *)
        echo "Keeping the key pair — continuing with the default uninstall."
        purge=0 ;;
    esac
  else
    err "--purge needs --yes when stdin is not a terminal."
    echo "     Deleting the private key is irreversible: every notice sealed so far" >&2
    echo "     would become permanently unreadable, with no recovery mechanism." >&2
    echo "     If that is what you want, re-run: ./install.sh --uninstall --purge --yes" >&2
    exit 1
  fi
fi

# --- pre-flight ---------------------------------------------------------------
if [ "$uninstall" -eq 0 ]; then
  require_python3
fi
if [ ${#targets[@]} -gt 0 ]; then
  case " ${targets[*]} " in
    *" claude "*) validate_settings_json "$CLAUDE_HOME/settings.json" ;;
  esac
fi

# --- act ----------------------------------------------------------------------
if [ ${#targets[@]} -gt 0 ]; then
  for t in "${targets[@]}"; do
    echo "==> $t"
    "target_$t"
  done
fi

if [ "$uninstall" -eq 1 ]; then
  # Bare (auto-detected) uninstall also removes the runtime scripts; an
  # explicit --target X --uninstall only unwires X, as before.
  if [ -d "$SE_HOME" ]; then
    if [ "$purge_confirmed" -eq 1 ]; then
      rm -rf "$SE_HOME"
      echo "Deleted $SE_HOME entirely — the private key is gone."
      echo "Every notice sealed so far is now permanently unreadable (no recovery mechanism)."
    elif [ "$explicit_targets" -eq 0 ]; then
      leftovers="$(find "$SE_HOME" -mindepth 1 -maxdepth 1 ! -name keys 2>/dev/null || true)"
      if [ -n "$leftovers" ]; then
        if find "$SE_HOME" -mindepth 1 -maxdepth 1 ! -name keys -exec rm -rf {} + 2>/dev/null; then
          echo "Removed the sovereign-echo runtime from $SE_HOME (kept $keys_dir)."
        else
          err "could not fully remove $SE_HOME (permission denied?) — $keys_dir was kept"
        fi
      fi
      if have_private_key; then
        echo "Your private key is still at $keys_dir/sm2-private.pem — you need it"
        echo "to open notices sealed in the past. Delete the key too (past notices"
        echo "become permanently unreadable) with:"
        echo "  ./install.sh --uninstall --purge"
      fi
    else
      echo "Runtime files remain in $SE_HOME (keys included)."
      echo "Run ./install.sh --uninstall to remove everything except your keys."
    fi
  fi
  echo
  echo "sovereign-echo uninstalled."
  exit 0
fi

# --- install: key-only mode (--keygen / --export-key without targets) ---------
if [ ${#targets[@]} -eq 0 ]; then
  ensure_keys || true
  if [ -n "$export_key" ]; then
    do_export_key "$export_key"
  fi
  have_private_key || exit 1
  exit 0
fi

# --- install: wire, runtime, keys ---------------------------------------------
if [ ${#wired[@]} -eq 0 ]; then
  echo
  echo "Nothing was installed — every target was skipped:"
  for line in ${skipped[@]+"${skipped[@]}"}; do
    echo "  skipped: $line"
  done
  exit 1
fi

install_runtime
ensure_keys || true
if [ -n "$export_key" ]; then
  do_export_key "$export_key"
fi

echo
echo "Summary:"
for line in ${wired[@]+"${wired[@]}"}; do
  echo "  wired:   $line"
done
for line in ${skipped[@]+"${skipped[@]}"}; do
  echo "  skipped: $line"
done
echo
echo "Done — your data-sovereignty notice will be restated in every conversation."
if have_private_key; then
  echo "Your key pair lives in $keys_dir — never share the private key, and back it up."
fi
echo "Check what is wired:  ./install.sh --status"
echo "Uninstall later:      ./install.sh --uninstall"
exit 0

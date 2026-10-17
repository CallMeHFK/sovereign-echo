#!/usr/bin/env bash
# sovereign-echo test suite. Runs entirely inside a fake HOME — never touches
# the real user configuration. Usage: ./tests/run-tests.sh
set -u
export PYTHONDONTWRITEBYTECODE=1

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
sealer="$repo_dir/crypto/smseal.py"
notice="$repo_dir/declarations/notice.compact.txt"
pass=0; fail=0

ok()   { pass=$((pass+1)); echo "  PASS: $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL: $1 [$2]"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }
skip() { echo "  SKIP: $1"; }

# octal permission bits, portable across GNU/BSD stat
mode_of() { python3 -c 'import os,sys;print(format(os.stat(sys.argv[1]).st_mode & 0o777, "04o"))' "$1"; }
now_ms() { python3 -c 'import time;print(int(time.time() * 1000))'; }

count_of() { grep -c "$2" "$1" 2>/dev/null || true; }

echo "== 1. shell syntax =="
for f in "$repo_dir/install.sh" "$repo_dir/scripts/emit-notice.sh" "$repo_dir/tests/run-tests.sh"; do
  check "bash -n $(basename "$f")" 'bash -n "$f" 2>/dev/null'
done

if [ -d "$repo_dir/crypto" ]; then
  pyc_tmp="$(mktemp -d)"
  found_py=0
  for f in "$repo_dir"/crypto/*.py; do
    [ -f "$f" ] || continue
    found_py=1
    check "py_compile $(basename "$f")" 'PYTHONPYCACHEPREFIX="$pyc_tmp" python3 -m py_compile "$f" 2>/dev/null'
  done
  rm -rf "$pyc_tmp"
  [ "$found_py" -eq 1 ] || skip "py_compile crypto/*.py (no python files found)"
else
  skip "py_compile crypto/*.py (crypto/ not present)"
fi

echo "== 2. emit-notice.sh (plain mode) =="
# These checks are about the notice text reaching stdout, so they pin the
# plain path. Sealed mode is covered in section 7.
out="$(SOVEREIGN_ECHO_SEAL=plain "$repo_dir/scripts/emit-notice.sh" 2>/dev/null)"; rc=$?
check "exit code 0" '[ "$rc" -eq 0 ]'
check "output has zh declaration" 'printf "%s" "$out" | grep -q "个人数据主权声明"'
check "output has en declaration" 'printf "%s" "$out" | grep -q "Personal Data Sovereignty Notice"'
out2="$(SOVEREIGN_ECHO_SEAL=plain SOVEREIGN_ECHO_NOTICE=/nonexistent-notice.txt "$repo_dir/scripts/emit-notice.sh" 2>/dev/null)"; rc2=$?
check "missing notice file still exits 0 (never blocks a conversation)" '[ "$rc2" -eq 0 ]'
check "missing notice file emits nothing on stdout" '[ -z "$out2" ]'

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
check "runtime hook emits notice (plain)" 'SOVEREIGN_ECHO_SEAL=plain "$SEHOME/scripts/emit-notice.sh" 2>/dev/null | grep -q "主权"'

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

echo "== 7. keystore (keygen) =="
KEYHOME="$(mktemp -d)"
if [ -f "$sealer" ]; then
  keyout="$(python3 "$sealer" keygen --home "$KEYHOME" </dev/null 2>&1)"; rc=$?
  check "keygen exits 0" '[ "$rc" -eq 0 ]'
  check "keygen prints a KeyId (16 hex chars)" 'printf "%s" "$keyout" | grep -qE "[0-9a-fA-F]{16}"'
  check "keys dir is 0700" '[ "$(mode_of "$KEYHOME/keys")" = "0700" ]'
  check "private key is 0600" '[ "$(mode_of "$KEYHOME/keys/sm2-private.pem")" = "0600" ]'
  check "public key is 0644" '[ "$(mode_of "$KEYHOME/keys/sm2-public.pem")" = "0644" ]'

  cp -f "$KEYHOME/keys/sm2-private.pem" "$KEYHOME/privkey.snapshot"
  python3 "$sealer" keygen --home "$KEYHOME" </dev/null >/dev/null 2>&1; rc=$?
  check "second keygen (no --force) exits 0" '[ "$rc" -eq 0 ]'
  check "second keygen is idempotent (private key unchanged)" 'cmp -s "$KEYHOME/keys/sm2-private.pem" "$KEYHOME/privkey.snapshot"'
else
  skip "keystore checks (crypto/ not present)"
fi

echo "== 8. seal / open / verify =="
if [ -f "$sealer" ]; then
  envelope="$KEYHOME/sealed.txt"
  opened="$KEYHOME/opened.txt"

  t0="$(now_ms)"
  python3 "$sealer" seal --notice "$notice" --home "$KEYHOME" </dev/null > "$envelope" 2>"$KEYHOME/seal.err"; rc=$?
  seal_ms="$(( $(now_ms) - t0 ))"
  check "seal exits 0" '[ "$rc" -eq 0 ]'
  check "seal completes in under 2000 ms" '[ "$seal_ms" -lt 2000 ]'
  check "envelope has BEGIN marker" 'grep -q "BEGIN SOVEREIGN-ECHO SEALED NOTICE" "$envelope"'
  check "envelope has END marker" 'grep -q "END SOVEREIGN-ECHO SEALED NOTICE" "$envelope"'
  check "envelope declares the v1 format" 'grep -q "Format: sovereign-echo/sm-envelope/v1" "$envelope"'
  check "envelope contains no plaintext notice" '! grep -q "主权" "$envelope"'

  python3 "$sealer" open --home "$KEYHOME" --in "$envelope" > "$opened" 2>"$KEYHOME/open.err"; rc=$?
  check "open exits 0" '[ "$rc" -eq 0 ]'
  check "seal -> open round trip recovers the notice byte for byte" 'cmp -s "$opened" "$notice"'

  PUBONLY="$(mktemp -d)"
  cp -f "$KEYHOME/keys/sm2-public.pem" "$PUBONLY/"
  python3 "$sealer" verify --home "$PUBONLY" --pubkey "$PUBONLY/sm2-public.pem" --in "$envelope" >/dev/null 2>&1; rc=$?
  check "verify succeeds with the public key alone" '[ "$rc" -eq 0 ]'
  rm -rf "$PUBONLY"

  # Tamper with a header line: one character flipped.
  bad_hdr="$KEYHOME/tampered-header.txt"
  python3 - "$envelope" "$bad_hdr" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")
out, done = [], False
for ln in lines:
    if not done and ln.startswith("KeyId:"):
        ln = ln.rstrip() + "f"
        done = True
    out.append(ln)
open(dst, "w").write("\n".join(out))
PY
  python3 "$sealer" open --home "$KEYHOME" --in "$bad_hdr" >/dev/null 2>&1; rc=$?
  check "tampered header makes open fail" '[ "$rc" -ne 0 ]'

  # Tamper inside the base64 body: one character flipped.
  bad_body="$KEYHOME/tampered-body.txt"
  python3 - "$envelope" "$bad_body" <<'PY'
import string, sys
src, dst = sys.argv[1], sys.argv[2]
alphabet = string.ascii_letters + string.digits + "+/="
lines = open(src).read().split("\n")
out, done = [], False
for ln in lines:
    body = ln.strip()
    if not done and body and "-" not in body and ":" not in body and all(c in alphabet for c in body):
        first = body[0]
        ln = ln.replace(first, "A" if first != "A" else "B", 1)
        done = True
    out.append(ln)
open(dst, "w").write("\n".join(out))
PY
  python3 "$sealer" open --home "$KEYHOME" --in "$bad_body" >/dev/null 2>&1; rc=$?
  check "tampered ciphertext makes open fail" '[ "$rc" -ne 0 ]'
  check "tampered body actually differs from the original" '! cmp -s "$envelope" "$bad_body"'
else
  skip "seal/open/verify checks (crypto/ not present)"
fi

echo "== 9. emit-notice.sh sealed mode =="
if [ -f "$sealer" ]; then
  check "install ships crypto/ into the runtime" '[ -f "$SEHOME/crypto/smseal.py" ]'
  check "installed crypto module is not executable" '[ ! -x "$SEHOME/crypto/smseal.py" ]'

  sealed_out="$(SOVEREIGN_ECHO_HOME="$KEYHOME" "$repo_dir/scripts/emit-notice.sh" </dev/null 2>"$KEYHOME/hook.err")"; rc=$?
  check "sealed hook exits 0" '[ "$rc" -eq 0 ]'
  check "sealed hook emits an envelope" 'printf "%s" "$sealed_out" | grep -q "BEGIN SOVEREIGN-ECHO SEALED NOTICE"'
  check "sealed hook leaks no plaintext notice" '! printf "%s" "$sealed_out" | grep -q "主权"'

  sealed_pipe="$(printf "{\"prompt\":\"hello world\"}" | SOVEREIGN_ECHO_HOME="$KEYHOME" "$repo_dir/scripts/emit-notice.sh" 2>/dev/null)"; rc=$?
  check "sealed hook handles a hook payload on stdin" '[ "$rc" -eq 0 ]'
  check "hook payload still produces an envelope" 'printf "%s" "$sealed_pipe" | grep -q "BEGIN SOVEREIGN-ECHO SEALED NOTICE"'

  plain_out="$(SOVEREIGN_ECHO_SEAL=plain SOVEREIGN_ECHO_HOME="$KEYHOME" "$repo_dir/scripts/emit-notice.sh" </dev/null 2>/dev/null)"
  check "SOVEREIGN_ECHO_SEAL=plain emits the plaintext notice" 'printf "%s" "$plain_out" | grep -q "主权"'

  # Installed runtime (what Claude Code actually runs) rather than the repo copy.
  inst_out="$(SOVEREIGN_ECHO_HOME="$SEHOME" "$SEHOME/scripts/emit-notice.sh" </dev/null 2>/dev/null)"; rc=$?
  check "installed hook exits 0" '[ "$rc" -eq 0 ]'
  check "installed hook emits an envelope" 'printf "%s" "$inst_out" | grep -q "BEGIN SOVEREIGN-ECHO SEALED NOTICE"'

  # Fail closed: no keystore means no envelope AND no plaintext fallback.
  mv "$KEYHOME/keys" "$KEYHOME/keys-hidden"
  nokey_out="$(SOVEREIGN_ECHO_HOME="$KEYHOME" "$repo_dir/scripts/emit-notice.sh" </dev/null 2>"$KEYHOME/nokey.err")"; rc=$?
  check "no keystore: still exits 0 (never blocks a conversation)" '[ "$rc" -eq 0 ]'
  check "no keystore: emits nothing on stdout (fails closed)" '[ -z "$nokey_out" ]'
  check "no keystore: points at the fix on stderr" 'grep -q "install.sh --keygen" "$KEYHOME/nokey.err"'
  mv "$KEYHOME/keys-hidden" "$KEYHOME/keys"
else
  skip "sealed-mode hook checks (crypto/ not present)"
fi
rm -rf "$KEYHOME"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

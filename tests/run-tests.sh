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
T2=""; T3=""; T4=""; T5=""; T6=""; T7=""; T8=""; T9=""
trap 'rm -rf "$FAKE" ${T2:+"$T2"} ${T3:+"$T3"} ${T4:+"$T4"} ${T5:+"$T5"} ${T6:+"$T6"} ${T7:+"$T7"} ${T8:+"$T8"} ${T9:+"$T9"}' EXIT
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
  # `open` prints a human-readable "OK key=... created=... request=..." status
  # line first, then the recovered plaintext.
  check "open prints an OK status line" 'head -n 1 "$opened" | grep -q "^OK "'
  check "status line reports the KeyId" 'head -n 1 "$opened" | grep -q "key="'
  check "seal -> open round trip recovers the notice byte for byte" 'tail -n +2 "$opened" | cmp -s - "$notice"'

  # Users paste an envelope straight out of a transcript — surrounding prose
  # must not stop it from opening.
  pasted="$KEYHOME/pasted.txt"
  { echo "…earlier conversation prose…"; cat "$envelope"; echo "…later prose…"; } > "$pasted"
  python3 "$sealer" open --home "$KEYHOME" --in "$pasted" > "$KEYHOME/pasted.out" 2>/dev/null; rc=$?
  check "open finds the envelope inside pasted transcript prose" '[ "$rc" -eq 0 ]'
  check "pasted round trip is still byte for byte" 'tail -n +2 "$KEYHOME/pasted.out" | cmp -s - "$notice"'

  # Prompt binding: seal --hook digests obj["prompt"] and open must agree.
  bound="$KEYHOME/bound.txt"
  printf '{"session_id":"s1","prompt":"please review my code"}' | \
    python3 "$sealer" seal --notice "$notice" --home "$KEYHOME" --hook > "$bound" 2>/dev/null; rc=$?
  check "seal --hook exits 0" '[ "$rc" -eq 0 ]'
  check "hook-sealed envelope carries a 64-hex Request digest" 'grep -qE "^Request: [0-9a-f]{64}$" "$bound"'
  python3 "$sealer" open --home "$KEYHOME" --in "$bound" --request "please review my code" >/dev/null 2>&1; rc=$?
  check "open accepts the matching prompt" '[ "$rc" -eq 0 ]'
  python3 "$sealer" open --home "$KEYHOME" --in "$bound" --request "a different prompt" >/dev/null 2>&1; rc=$?
  check "open rejects a substituted prompt" '[ "$rc" -ne 0 ]'

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

  # TLV-order malleability: the signature must cover the bytes as received,
  # so permuting two records on the wire must not still verify and open.
  permuted="$KEYHOME/permuted-tlv.txt"
  python3 - "$envelope" "$permuted" <<'PY'
import base64, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")
i = lines.index("-----BEGIN SOVEREIGN-ECHO SEALED NOTICE-----")
j = lines.index("-----END SOVEREIGN-ECHO SEALED NOTICE-----")
k = i + 1
while lines[k].strip():
    k += 1                      # header block, then the blank separator
raw = bytearray(base64.b64decode("".join(l.strip() for l in lines[k:j] if l.strip())))
# 0x01 ephemeral point (3+33 B) followed by 0x02 CEK-wrap nonce (3+12 B)
assert raw[0] == 0x01 and raw[36] == 0x02, "unexpected TLV layout"
first, second = bytes(raw[:36]), bytes(raw[36:51])
raw[0:51] = second + first
b64 = base64.b64encode(bytes(raw)).decode("ascii")
wrapped = [b64[n:n + 64] for n in range(0, len(b64), 64)]
open(dst, "w").write("\n".join(lines[:k] + [""] + wrapped + [""] + lines[j:]))
PY
  python3 "$sealer" open --home "$KEYHOME" --in "$permuted" >/dev/null 2>&1; rc=$?
  check "permuted TLV records make open fail" '[ "$rc" -ne 0 ]'
  check "permuted envelope actually differs from the original" '! cmp -s "$envelope" "$permuted"'
else
  skip "seal/open/verify checks (crypto/ not present)"
fi

echo "== 9. emit-notice.sh sealed mode =="
if [ -f "$sealer" ]; then
  check "install ships crypto/ into the runtime" '[ -f "$SEHOME/crypto/smseal.py" ]'
  check "installed crypto module is not executable" '[ ! -x "$SEHOME/crypto/smseal.py" ]'
  check "install ships no __pycache__" '[ ! -d "$SEHOME/crypto/__pycache__" ]'

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

echo "== 10. zero-config install, status, uninstall, purge =="
T2="$(mktemp -d)"
mkdir -p "$T2/.claude" "$T2/.codex"
cat > "$T2/.claude/settings.json" <<'JSON'
{
  "env": { "SOME_VAR": "keep-me" },
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "shepherd-hook claude", "timeout": 5 } ] }
    ]
  }
}
JSON

# --- bare install auto-detects the agents that exist ---
out="$(HOME="$T2" "$repo_dir/install.sh" 2>&1)"; rc=$?
check "bare install exits 0 when agent dirs exist" '[ "$rc" -eq 0 ]'
check "bare install wires claude (hook entry present)" 'grep -q "emit-notice.sh" "$T2/.claude/settings.json"'
check "bare install wires codex (block present)" '[ "$(count_of "$T2/.codex/AGENTS.md" "BEGIN sovereign-echo")" = "1" ]'
check "bare install leaves undetected qwenpaw alone" '[ ! -f "$T2/.qwenpaw/workspaces/default/AGENTS.md" ]'
check "bare install reports what it detected" 'printf "%s" "$out" | grep -q "Detected agents: claude codex"'
check "bare install summary lists wired targets" 'printf "%s" "$out" | grep -q "wired:.*claude" && printf "%s" "$out" | grep -q "wired:.*codex"'
check "bare install keeps the foreign hook" 'grep -q "shepherd-hook claude" "$T2/.claude/settings.json"'
check "bare install keeps foreign env" 'grep -q "keep-me" "$T2/.claude/settings.json"'
check "SE_HOME is chmod 0700" '[ "$(mode_of "$T2/.sovereign-echo")" = "0700" ]'

# --- --status after install ---
st="$(HOME="$T2" "$repo_dir/install.sh" --status 2>&1)"; src=$?
check "--status exits 0 after install" '[ "$src" -eq 0 ]'
check "--status reports the runtime location" 'printf "%s" "$st" | grep -q "Runtime:.*present at"'
check "--status reports the KeyId" 'printf "%s" "$st" | grep -qE "KeyId: [0-9a-f]{16}"'
check "--status reports both key paths" 'printf "%s" "$st" | grep -q "sm2-private.pem" && printf "%s" "$st" | grep -q "sm2-public.pem"'
check "--status reports claude wired" 'printf "%s" "$st" | grep -q "claude.*wired"'
check "--status reports codex wired" 'printf "%s" "$st" | grep -q "codex.*wired"'
check "--status reports qwenpaw not wired" 'printf "%s" "$st" | grep -q "qwenpaw.*not wired"'

# --- bare uninstall: no target flags, keys kept ---
out="$(HOME="$T2" "$repo_dir/install.sh" --uninstall 2>&1)"; rc=$?
check "bare uninstall exits 0" '[ "$rc" -eq 0 ]'
check "bare uninstall removes the claude hook" '[ "$(count_of "$T2/.claude/settings.json" "emit-notice.sh")" = "0" ]'
check "bare uninstall removes the codex block" '[ "$(count_of "$T2/.codex/AGENTS.md" "BEGIN sovereign-echo")" = "0" ]'
check "bare uninstall keeps the foreign hook" 'grep -q "shepherd-hook claude" "$T2/.claude/settings.json"'
check "bare uninstall keeps foreign env" 'grep -q "keep-me" "$T2/.claude/settings.json"'
check "bare uninstall keeps keys/" '[ -f "$T2/.sovereign-echo/keys/sm2-private.pem" ]'
check "bare uninstall removes runtime scripts" '[ ! -f "$T2/.sovereign-echo/scripts/emit-notice.sh" ]'
check "bare uninstall says where the key is" 'printf "%s" "$out" | grep -q "sm2-private.pem"'
check "bare uninstall gives the purge command" 'printf "%s" "$out" | grep -q -- "--uninstall --purge"'
check "bare uninstall left a settings backup" 'ls "$T2/.claude" | grep -q "bak-sovereign-echo"'
HOME="$T2" "$repo_dir/install.sh" --uninstall </dev/null > /dev/null 2>&1; rc=$?
check "second bare uninstall still exits 0" '[ "$rc" -eq 0 ]'
check "second bare uninstall still keeps keys/" '[ -f "$T2/.sovereign-echo/keys/sm2-private.pem" ]'

# --- empty HOME: helpful failure, clean status ---
T3="$(mktemp -d)"
out="$(HOME="$T3" "$repo_dir/install.sh" 2>&1)"; rc=$?
check "bare install with no agents exits non-zero" '[ "$rc" -ne 0 ]'
check "bare install names what it looked for" 'printf "%s" "$out" | grep -q "\.claude" && printf "%s" "$out" | grep -q "\.codex"'
check "bare install suggests explicit targets" 'printf "%s" "$out" | grep -q -- "--target"'
check "bare install with no agents installs nothing" '[ ! -d "$T3/.sovereign-echo" ]'
out="$(HOME="$T3" "$repo_dir/install.sh" --target all 2>&1)"; rc=$?
check "--target all with nothing present exits non-zero" '[ "$rc" -ne 0 ]'
check "--target all with nothing present says why" 'printf "%s" "$out" | grep -q "skipped:"'
out="$(HOME="$T3" "$repo_dir/install.sh" --status 2>&1)"; rc=$?
check "--status exits 0 in an empty HOME" '[ "$rc" -eq 0 ]'
check "--status says nothing is installed" 'printf "%s" "$out" | grep -qi "not installed"'

# --- purge: refuse without --yes on non-TTY, then --yes ---
kid1="$(HOME="$T2" "$repo_dir/install.sh" --status | sed -n 's/.*KeyId: \([0-9a-f]*\).*/\1/p')"
HOME="$T2" "$repo_dir/install.sh" > /dev/null 2>&1
kid2="$(HOME="$T2" "$repo_dir/install.sh" --status | sed -n 's/.*KeyId: \([0-9a-f]*\).*/\1/p')"
check "reinstall keeps the existing key pair" '[ -n "$kid1" ] && [ "$kid1" = "$kid2" ]'
out="$(HOME="$T2" "$repo_dir/install.sh" --uninstall --purge </dev/null 2>&1)"; rc=$?
check "--purge without --yes refuses on non-TTY" '[ "$rc" -ne 0 ]'
check "--purge refusal explains the key loss" 'printf "%s" "$out" | grep -qi "unreadable"'
check "--purge refusal names the fix" 'printf "%s" "$out" | grep -q -- "--yes"'
check "--purge refusal changed nothing" 'grep -q "emit-notice.sh" "$T2/.claude/settings.json" && [ -d "$T2/.sovereign-echo/keys" ]'
HOME="$T2" "$repo_dir/install.sh" --uninstall --purge --yes </dev/null > /dev/null 2>&1; rc=$?
check "--purge --yes exits 0" '[ "$rc" -eq 0 ]'
check "--purge --yes removes SE_HOME entirely" '[ ! -d "$T2/.sovereign-echo" ]'
check "--purge --yes removes the hook" '[ "$(count_of "$T2/.claude/settings.json" "emit-notice.sh")" = "0" ]'
check "--purge --yes removes the codex block" '[ "$(count_of "$T2/.codex/AGENTS.md" "BEGIN sovereign-echo")" = "0" ]'

# --- --export-key ---
T4="$(mktemp -d)"
mkdir -p "$T4/.claude"
out="$(HOME="$T4" "$repo_dir/install.sh" --export-key "$T4/backup/sm2-private.pem" 2>&1)"; rc=$?
check "--export-key exits 0" '[ "$rc" -eq 0 ]'
check "--export-key prints the custody warning" 'printf "%s" "$out" | grep -qi "never share" && printf "%s" "$out" | grep -qi "back it up" && printf "%s" "$out" | grep -qi "no recovery mechanism"'
check "--export-key writes a 0600 file" '[ "$(mode_of "$T4/backup/sm2-private.pem")" = "0600" ]'
check "--export-key copies the real private key" 'cmp -s "$T4/backup/sm2-private.pem" "$T4/.sovereign-echo/keys/sm2-private.pem"'
cp -f "$T4/backup/sm2-private.pem" "$T4/snapshot.pem"
HOME="$T4" "$repo_dir/install.sh" --export-key "$T4/backup/sm2-private.pem" </dev/null > /dev/null 2>&1; rc=$?
check "--export-key refuses to overwrite without --force" '[ "$rc" -ne 0 ]'
check "--export-key refusal left the file untouched" 'cmp -s "$T4/backup/sm2-private.pem" "$T4/snapshot.pem"'
HOME="$T4" "$repo_dir/install.sh" --export-key "$T4/backup/sm2-private.pem" --force </dev/null > /dev/null 2>&1; rc=$?
check "--export-key --force overwrites" '[ "$rc" -eq 0 ]'

# --- friendly failure: malformed settings.json ---
T5="$(mktemp -d)"
mkdir -p "$T5/.claude"
printf '{ this is not json' > "$T5/.claude/settings.json"
out="$(HOME="$T5" "$repo_dir/install.sh" 2>&1)"; rc=$?
check "malformed settings.json exits non-zero" '[ "$rc" -ne 0 ]'
check "malformed settings.json names the file" 'printf "%s" "$out" | grep -q "settings.json"'
check "malformed settings.json prints no traceback" '! printf "%s" "$out" | grep -q "Traceback"'
check "malformed settings.json was left untouched" 'grep -q "this is not json" "$T5/.claude/settings.json"'

# --- --force key rotation ---
T6="$(mktemp -d)"
mkdir -p "$T6/.claude"
HOME="$T6" "$repo_dir/install.sh" > /dev/null 2>&1
priv_before="$(cat "$T6/.sovereign-echo/keys/sm2-private.pem")"
kid_before="$(HOME="$T6" "$repo_dir/install.sh" --status | sed -n 's/.*KeyId: \([0-9a-f]*\).*/\1/p')"
out="$(HOME="$T6" "$repo_dir/install.sh" --keygen --force 2>&1)"; rc=$?
check "--keygen --force exits 0" '[ "$rc" -eq 0 ]'
check "--keygen --force rotates the private key" '[ "$priv_before" != "$(cat "$T6/.sovereign-echo/keys/sm2-private.pem")" ]'
kid_after="$(HOME="$T6" "$repo_dir/install.sh" --status | sed -n 's/.*KeyId: \([0-9a-f]*\).*/\1/p')"
check "--keygen --force changes the KeyId" '[ -n "$kid_after" ] && [ "$kid_before" != "$kid_after" ]'
check "rotation warns old envelopes are unreadable" 'printf "%s" "$out" | grep -qi "unreadable"'
priv_rotated="$(cat "$T6/.sovereign-echo/keys/sm2-private.pem")"
out="$(HOME="$T6" "$repo_dir/install.sh" --keygen 2>&1)"
check "--keygen without --force keeps the key" '[ "$priv_rotated" = "$(cat "$T6/.sovereign-echo/keys/sm2-private.pem")" ]'
check "--keygen points at --force as the real command" 'printf "%s" "$out" | grep -q -- "--keygen --force"'

echo "== 11. targeted uninstall edge cases =="
T7="$(mktemp -d)"
mkdir -p "$T7/.claude" "$T7/.codex" "$T7/.qwenpaw/workspaces/default"
HOME="$T7" "$repo_dir/install.sh" --target all > /dev/null 2>&1; rc=$?
check "setup: --target all install exits 0" '[ "$rc" -eq 0 ]'

# A PATH without python3 must report the missing interpreter — never blame
# the user's (valid) settings.json — and must not touch anything.
NOPY="$(mktemp -d)"
for b in bash sh grep awk sed cat cp rm mkdir chmod stat date find tail head mktemp dirname basename ls env cut tr sort; do
  src="$(command -v "$b" 2>/dev/null)" && ln -s "$src" "$NOPY/$b" 2>/dev/null
done
out="$(PATH="$NOPY" HOME="$T7" "$repo_dir/install.sh" --target claude --uninstall 2>&1)"; rc=$?
check "python3-less uninstall exits non-zero" '[ "$rc" -ne 0 ]'
check "python3-less uninstall reports the missing interpreter" 'printf "%s" "$out" | grep -q "python3"'
check "python3-less uninstall does not blame the JSON" '! printf "%s" "$out" | grep -q "not a valid JSON"'
check "python3-less uninstall leaves the claude hook wired" 'grep -q "emit-notice.sh" "$T7/.claude/settings.json"'
check "python3-less uninstall leaves no backup behind" '! ls "$T7/.claude" | grep -q "bak-sovereign-echo"'
check "python3-less uninstall deletes nothing" '[ -f "$T7/.sovereign-echo/scripts/emit-notice.sh" ]'
rm -rf "$NOPY"

# Targeted uninstall: the final line must name what is still wired instead of
# claiming everything was uninstalled.
out="$(HOME="$T7" "$repo_dir/install.sh" --target claude --uninstall 2>&1)"; rc=$?
check "targeted uninstall exits 0" '[ "$rc" -eq 0 ]'
check "targeted uninstall removes only the claude hook" '! grep -q "emit-notice.sh" "$T7/.claude/settings.json" && [ "$(count_of "$T7/.codex/AGENTS.md" "BEGIN sovereign-echo")" = "1" ] && [ "$(count_of "$T7/.qwenpaw/workspaces/default/AGENTS.md" "BEGIN sovereign-echo")" = "1" ]'
check "targeted uninstall keeps the runtime and keys" '[ -f "$T7/.sovereign-echo/scripts/emit-notice.sh" ] && [ -f "$T7/.sovereign-echo/keys/sm2-private.pem" ]'
check "targeted uninstall final line names the remaining agents" 'tail -n 1 <<< "$out" | grep -q "codex" && tail -n 1 <<< "$out" | grep -q "qwenpaw"'
check "targeted uninstall does not claim a full uninstall" '! printf "%s\n" "$out" | grep -qx "sovereign-echo uninstalled."'

out="$(HOME="$T7" "$repo_dir/install.sh" --uninstall 2>&1)"; rc=$?
check "bare uninstall after a targeted one exits 0" '[ "$rc" -eq 0 ]'
check "bare uninstall removes the remaining agents" '[ "$(count_of "$T7/.codex/AGENTS.md" "BEGIN sovereign-echo")" = "0" ] && [ "$(count_of "$T7/.qwenpaw/workspaces/default/AGENTS.md" "BEGIN sovereign-echo")" = "0" ]'
check "bare uninstall with nothing left prints the plain final line" 'printf "%s\n" "$out" | grep -qx "sovereign-echo uninstalled."'

echo "== 12. README accuracy =="
check "README.md backup note names settings.json" 'grep -q "settings.json.bak-sovereign-echo" "$repo_dir/README.md"'
check "README.md no longer claims every modified file is backed up" '! grep -qi "backups of modified files" "$repo_dir/README.md"'
check "README.md says bak files are safe to delete" 'grep -qi "safe to delete" "$repo_dir/README.md"'
check "README.md documents CLAUDE_HOME" 'grep -q "CLAUDE_HOME" "$repo_dir/README.md"'
check "README.md documents CODEX_HOME" 'grep -q "CODEX_HOME" "$repo_dir/README.md"'
check "README.md documents QWENPAW_WORKSPACE" 'grep -q "QWENPAW_WORKSPACE" "$repo_dir/README.md"'
check "README.md documents GENERIC_FILE" 'grep -q "GENERIC_FILE" "$repo_dir/README.md"'
check "README.zh-CN.md backup note names settings.json" 'grep -q "settings.json.bak-sovereign-echo" "$repo_dir/README.zh-CN.md"'
check "README.zh-CN.md no longer claims every modified file is backed up" '! grep -q "被修改文件的备份" "$repo_dir/README.zh-CN.md"'
check "README.zh-CN.md says bak files are safe to delete" 'grep -q "可以直接删除" "$repo_dir/README.zh-CN.md"'
check "README.zh-CN.md documents CLAUDE_HOME" 'grep -q "CLAUDE_HOME" "$repo_dir/README.zh-CN.md"'
check "README.zh-CN.md documents CODEX_HOME" 'grep -q "CODEX_HOME" "$repo_dir/README.zh-CN.md"'
check "README.zh-CN.md documents QWENPAW_WORKSPACE" 'grep -q "QWENPAW_WORKSPACE" "$repo_dir/README.zh-CN.md"'
check "README.zh-CN.md documents GENERIC_FILE" 'grep -q "GENERIC_FILE" "$repo_dir/README.zh-CN.md"'
check "README.md says the Request: header is present only when bound" 'grep -q "present only when the notice is bound" "$repo_dir/README.md"'
check "README.md says --request is not a control over the key holder" 'grep -q "not a control over the key holder" "$repo_dir/README.md"'
check "README.zh-CN.md says the Request: header appears only when bound" 'grep -q "仅在声明被绑定到具体请求时出现" "$repo_dir/README.zh-CN.md"'
check "README.zh-CN.md says --request is not a control over the key holder" 'grep -q "不是对持钥人的约束" "$repo_dir/README.zh-CN.md"'

echo "== 13. installer safety (unsafe SOVEREIGN_ECHO_HOME, glob resilience) =="
T8="$(mktemp -d)"

# --- an unsafe runtime home must refuse, never delete ---
mkdir -p "$T8/unsafe/.claude"
out="$(SOVEREIGN_ECHO_HOME=/ HOME="$T8/unsafe" "$repo_dir/install.sh" --uninstall --purge --yes 2>&1)"; rc=$?
check "purge with SOVEREIGN_ECHO_HOME=/ refuses (non-zero exit)" '[ "$rc" -ne 0 ]'
check "unsafe-home purge refusal names the refusal" 'printf "%s" "$out" | grep -q "refusing to remove the runtime home"'
check "unsafe-home purge deleted nothing" '[ -d / ] && [ -d "$T8/unsafe" ] && [ ! -e "$T8/unsafe/.sovereign-echo" ]'
out="$(SOVEREIGN_ECHO_HOME=/ HOME="$T8/unsafe" "$repo_dir/install.sh" --uninstall </dev/null 2>&1)"; rc=$?
check "bare uninstall with SOVEREIGN_ECHO_HOME=/ also refuses" '[ "$rc" -ne 0 ]'
check "bare-uninstall refusal names the refusal" 'printf "%s" "$out" | grep -q "refusing to remove the runtime home"'
check "bare-uninstall refusal deleted nothing" '[ -d / ] && [ ! -e "$T8/unsafe/.sovereign-echo" ]'

# --- a glob that matches nothing must not abort the install ---
# A plain reinstall re-copies crypto/*.py (cp merges into the existing
# directory), so an emptied runtime alone cannot fail: install from a repo
# copy whose crypto/ has no *.py — the same chmod glob, genuinely unexpanded.
T8GLOB="$T8/glob"
mkdir -p "$T8GLOB/repo" "$T8GLOB/home/.claude"
cp "$repo_dir/install.sh" "$T8GLOB/repo/"
cp -r "$repo_dir/declarations" "$repo_dir/scripts" "$repo_dir/templates" "$repo_dir/crypto" "$T8GLOB/repo/"
rm -f "$T8GLOB/repo"/crypto/*.py
out="$(HOME="$T8GLOB/home" "$T8GLOB/repo/install.sh" --target claude 2>&1)"; rc=$?
check "install survives a crypto/*.py glob that matches nothing" '[ "$rc" -eq 0 ]'
check "the sandbox really had no crypto/*.py (failure mode was live)" '[ ! -e "$T8GLOB/repo/crypto/smseal.py" ]'

echo "== 14. key import hardening (foreign curves, RSA, SM2 interop) =="
T9="$(mktemp -d)"
if [ -f "$sealer" ] && command -v openssl >/dev/null 2>&1; then
  # --- a foreign-curve EC key is rejected, and seal/open fail closed ---
  openssl ecparam -name prime256v1 -genkey 2>/dev/null > "$T9/prime256v1.pem"
  if [ -s "$T9/prime256v1.pem" ]; then
    python3 "$sealer" keygen --home "$T9/p256home" </dev/null >/dev/null 2>&1
    python3 "$sealer" seal --notice "$notice" --home "$T9/p256home" </dev/null > "$T9/p256good.env" 2>/dev/null
    check "setup: a valid envelope exists for the open check" 'grep -q "BEGIN SOVEREIGN-ECHO SEALED NOTICE" "$T9/p256good.env"'
    cp -f "$T9/prime256v1.pem" "$T9/p256home/keys/sm2-private.pem"
    out="$(python3 "$sealer" seal --notice "$notice" --home "$T9/p256home" </dev/null 2>&1)"; rc=$?
    check "prime256v1 key is rejected by seal" '[ "$rc" -ne 0 ]'
    check "rejection names the wrong curve" 'printf "%s" "$out" | grep -q "prime256v1"'
    check "rejected key produced no envelope" '! printf "%s" "$out" | grep -q "BEGIN SOVEREIGN-ECHO SEALED NOTICE"'
    python3 "$sealer" open --home "$T9/p256home" --in "$T9/p256good.env" >/dev/null 2>&1; rc=$?
    check "open also fails with a foreign-curve key" '[ "$rc" -ne 0 ]'
  else
    skip "prime256v1 rejection (openssl could not generate the key)"
  fi

  # --- an RSA PKCS#8 key is rejected with the clear algorithm message ---
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null > "$T9/rsa.pem"
  if [ -s "$T9/rsa.pem" ]; then
    mkdir -p "$T9/rsahome/keys"
    cp -f "$T9/rsa.pem" "$T9/rsahome/keys/sm2-private.pem"
    out="$(python3 "$sealer" seal --notice "$notice" --home "$T9/rsahome" </dev/null 2>&1)"; rc=$?
    check "RSA PKCS#8 key is rejected" '[ "$rc" -ne 0 ]'
    check "RSA rejection keeps the clear algorithm message" 'printf "%s" "$out" | grep -q "not EC/SM2"'
  else
    skip "RSA PKCS#8 rejection (openssl could not generate the key)"
  fi

  # --- regression: OpenSSL's SM2 PKCS#8 output still round-trips ---
  openssl ecparam -name SM2 -genkey 2>/dev/null > "$T9/sm2pkcs8.pem"
  if [ -s "$T9/sm2pkcs8.pem" ]; then
    mkdir -p "$T9/sm2home/keys"
    cp -f "$T9/sm2pkcs8.pem" "$T9/sm2home/keys/sm2-private.pem"
    python3 "$sealer" seal --notice "$notice" --home "$T9/sm2home" </dev/null > "$T9/sm2pkcs8.env" 2>/dev/null; rc=$?
    check "OpenSSL SM2 PKCS#8 key still seals" '[ "$rc" -eq 0 ]'
    python3 "$sealer" open --home "$T9/sm2home" --in "$T9/sm2pkcs8.env" > "$T9/sm2pkcs8.out" 2>/dev/null; rc=$?
    check "OpenSSL SM2 PKCS#8 key still opens" '[ "$rc" -eq 0 ]'
    check "SM2 PKCS#8 round trip is byte for byte" 'tail -n +2 "$T9/sm2pkcs8.out" | cmp -s - "$notice"'
  else
    skip "SM2 PKCS#8 interop (openssl lacks SM2 support)"
  fi
else
  skip "key import hardening checks (crypto/ or openssl not present)"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

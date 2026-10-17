#!/usr/bin/env bash
# sovereign-echo: print the data-sovereignty notice to stdout for each turn.
#
# Used as a UserPromptSubmit hook: stdout is injected into the conversation
# context on every turn. This script MUST NOT block or break a conversation —
# any internal failure still exits 0 (silently or with a stderr note).
#
# Default mode (SOVEREIGN_ECHO_SEAL=sealed) emits the notice as a signed,
# encrypted envelope instead of plaintext — see crypto/smseal.py. If sealing
# is impossible we emit NOTHING rather than falling back to plaintext.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
root="$(dirname "$here")"

# Allow an explicit override, e.g. a customized personal notice.
notice="${SOVEREIGN_ECHO_NOTICE:-$root/declarations/notice.compact.txt}"
mode="${SOVEREIGN_ECHO_SEAL:-sealed}"

home_dir="${SOVEREIGN_ECHO_HOME:-${HOME:-}/.sovereign-echo}"
sealer="$root/crypto/smseal.py"
privkey="$home_dir/keys/sm2-private.pem"

if [ ! -f "$notice" ]; then
  echo "[sovereign-echo] notice file not found: $notice" >&2
  exit 0
fi

if [ "$mode" = "plain" ]; then
  cat "$notice"
  exit 0
fi

# Fail closed: never print the plaintext notice when sealing was requested.
bail() {
  echo "[sovereign-echo] $1 — nothing was emitted on stdout. Fix: install.sh --keygen" >&2
  exit 0
}

command -v python3 >/dev/null 2>&1 || bail "python3 not found in PATH"
[ -f "$sealer" ] || bail "sealing module missing ($sealer)"
[ -f "$privkey" ] || bail "no private key at $privkey"

# Read the hook payload only when something is actually piped in — running
# this script by hand must never block on stdin.
hook_input=""
if [ ! -t 0 ]; then
  hook_input="$(cat 2>/dev/null || true)"
fi

rc=0
if [ -n "$hook_input" ]; then
  out="$(printf '%s' "$hook_input" | python3 "$sealer" seal --notice "$notice" --hook 2>&1)" || rc=$?
else
  out="$(python3 "$sealer" seal --notice "$notice" </dev/null 2>&1)" || rc=$?
fi

if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
  printf '%s\n' "$out"
else
  bail "sealing failed (smseal.py exit $rc)"
fi

exit 0

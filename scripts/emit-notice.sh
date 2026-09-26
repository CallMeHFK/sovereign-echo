#!/usr/bin/env bash
# sovereign-echo: print the compact data-sovereignty notice to stdout.
#
# Used as a UserPromptSubmit hook: stdout is injected into the conversation
# context on every turn. This script MUST NOT block or break a conversation —
# any internal failure still exits 0 (silently or with a stderr note).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
root="$(dirname "$here")"

# Allow an explicit override, e.g. a customized personal notice.
notice="${SOVEREIGN_ECHO_NOTICE:-$root/declarations/notice.compact.txt}"

if [ -f "$notice" ]; then
  cat "$notice"
else
  echo "[sovereign-echo] notice file not found: $notice" >&2
fi

exit 0

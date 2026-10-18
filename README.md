# sovereign-echo

**English** | [简体中文](README.zh-CN.md)

> Every conversation, your data rights restated.
> 每一次对话，重申你的数据主权。

`sovereign-echo` is a small plugin for coding agents (**Claude Code, OpenAI Codex, QwenPaw**, and anything that reads `AGENTS.md`). It injects your **personal data-sovereignty notice** into every conversation flow, so the record is unambiguous:

> 服务方将本对话数据用于模型训练，依据的是其单方面拟定的**不对称协议条款**，而非我的授权。我的数据权利始终归属我个人；**我永远将自己的数据持有在自己手中**。任何格式条款、默认勾选或训练行为均不转移、放弃或减损该权利。
>
> Any provider use of this conversation's data for model training rests on unilateral, **asymmetric terms** — not my authorization. My data remains my personal right, **held in my own hands at all times**; no boilerplate term, pre-checked consent, or training activity transfers, waives, or diminishes it.

## Why

Terms of service are written by one side. You click "agree" or you don't use the tool — that is an asymmetric protocol. You may not be able to refuse it today, but you can make sure your position is stated, in writing, in every single conversation: *the data is mine, the rights are mine, and I never handed them over.* A continuing, express reservation of rights is both a personal stance and a documented record.

## What it does

| Agent | Mechanism | File touched |
|---|---|---|
| Claude Code | `UserPromptSubmit` hook — the **sealed notice** is injected into context on **every turn** | `~/.claude/settings.json` |
| OpenAI Codex | Global instructions block, loaded every session | `~/.codex/AGENTS.md` |
| QwenPaw | Workspace instructions block, loaded every session | `~/.qwenpaw/workspaces/<id>/AGENTS.md` |
| Any other agent (ZCode, opencode, Gemini CLI, Cursor, …) | Generic `AGENTS.md`-style block | any file you point it at |

Claude Code users can alternatively install it as a **plugin** (this repo is its own marketplace):

```
/plugin marketplace add CallMeHFK/sovereign-echo
/plugin install sovereign-echo@sovereign-echo
```

## Install

```bash
git clone https://github.com/CallMeHFK/sovereign-echo
cd sovereign-echo

./install.sh                # zero-config: wires every agent it detects
```

That is the whole installation. The installer looks for the agents you already have (`~/.claude`, `~/.codex`, `~/.qwenpaw/workspaces/default`) and wires exactly those — no flags, no config files to edit. If it finds none, it says so and tells you what to do.

Prefer to be explicit? The flags still work:

```bash
./install.sh --target claude       # one at a time (repeatable)
./install.sh --target all          # claude + codex + qwenpaw
GENERIC_FILE=~/myagent/AGENTS.md ./install.sh --target generic
```

The installer copies a tiny runtime to `~/.sovereign-echo/`, merges one hook entry into Claude's `settings.json` (with a timestamped backup, preserving everything you already have), and appends a clearly-marked block to the relevant `AGENTS.md` files. It is idempotent — run it as often as you like. `python3` is required: without it the sealed hook cannot run.

### What is installed?

```bash
./install.sh --status
```

A read-only report: where the runtime is, the KeyId and both key paths, and per agent whether it is wired. It exits 0 whether or not anything is installed, and it never changes anything.

### Keys

A key pair is generated for you on first install and lands in `~/.sovereign-echo/keys/`:

| File | Mode | Notes |
|---|---|---|
| `sm2-private.pem` | `0600` | **Never share this.** Anyone holding it can open your envelopes. The directory itself is `0700`. |
| `sm2-public.pem` | `0644` | Safe to hand out. Enough to *verify*, not to *open*. |

**Back the private key up.** Without `sm2-private.pem`, every notice you ever sealed becomes permanently unreadable — there is no recovery mechanism and deliberately no escrow. The installer says so the moment the key is created; copy it somewhere safe:

```bash
./install.sh --export-key ~/backups/sm2-private.pem   # copies the key, mode 0600
```

```bash
./install.sh --keygen              # (re)generate the key pair, prints the KeyId
./install.sh --keygen --force      # rotate: old envelopes become unreadable
./install.sh --target all --no-keygen   # install without touching keys
```

Preview what actually gets injected, in either form:

```bash
./install.sh --print-notice   # the notice as plaintext
./install.sh --print-sealed   # the notice as a sealed envelope
```

## Sealed notice

By default the per-turn notice is never sent in the clear. Each turn `scripts/emit-notice.sh` seals it with 国密 primitives — SM2 key agreement wrapping an SM4-GCM session key, SM3 for hashing, SM2/SM3 for the signature — bound to that turn's prompt, and hands Claude Code this instead of readable prose:

```
-----BEGIN SOVEREIGN-ECHO SEALED NOTICE-----
Format: sovereign-echo/sm-envelope/v1
Kem: SM2-ECIES(SM3-KDF,SM4-GCM)
Cipher: SM4-GCM
Digest: SM3
Signature: SM2-SM3
KeyId: <16 hex>
Created: 2026-10-18T12:34:56Z
Request: <64 hex>

<base64>

-----END SOVEREIGN-ECHO SEALED NOTICE-----
```

The accepted consequence: the provider receives an opaque envelope, not your declaration in plaintext. That is the point — your position stays on the record, on your terms, readable only by whoever holds your private key.

Reopen or check a transcript later (paste the armored block into `FILE`, or pipe it on stdin):

```bash
python3 ~/.sovereign-echo/crypto/smseal.py open   --in FILE [--request "the original prompt"]
python3 ~/.sovereign-echo/crypto/smseal.py verify --in FILE --pubkey other.pub.pem
```

`open` prints a one-line status header (`OK key=… created=… request=…`) followed by the recovered plaintext; `verify` prints the same kind of line and nothing else. `open` needs your private key; `verify` needs only someone's public key. That asymmetry *is* the "only I can decrypt" property: hand your public key to anyone and they can confirm a sealed notice is really yours and unmodified, while nobody can read its contents.

If sealing is impossible (no python3, module missing, or no keystore) the hook emits **nothing at all** and notes why on stderr. Falling back to plaintext would defeat the whole point — a hook that cannot seal fails closed.

Set `SOVEREIGN_ECHO_SEAL=plain` to restore the old plaintext behaviour, e.g. for providers where readable prose matters more to you than confidentiality.

### SM2 user identity

Our envelopes use the GM/T 0003 default user identity `1234567812345678` in the SM2 Z-digest — for signing and for envelope signatures alike — which is what GmSSL and BouncyCastle SM2 peers expect. There is deliberately no knob and no second signature flavour.

OpenSSL 3's `dgst -sm3 -sign` / `-verify` instead uses an **empty** user identity (ENTL `0x0000`), so `openssl dgst -sm3 -verify` will **not** cross-verify our envelope signatures out of the box. A verifier working through OpenSSL must pass `ident=b""` to `sm2.verify(...)`. That is an OpenSSL quirk, not a deviation on our side.

## Customize

The declaration is yours — edit it:

- `declarations/notice.compact.txt` — the per-turn notice (what hooks inject)
- `declarations/notice.zh-CN.md` / `declarations/notice.en.md` — the full versions
- `templates/agents-block.md` — the block placed into `AGENTS.md` files

Or point the hook at your own file without forking: `SOVEREIGN_ECHO_NOTICE=/path/to/my-notice.txt`. The sealed envelope wraps whatever that file contains.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `SOVEREIGN_ECHO_HOME` | `~/.sovereign-echo` | Runtime dir; keys live in `$SOVEREIGN_ECHO_HOME/keys` |
| `SOVEREIGN_ECHO_NOTICE` | `declarations/notice.compact.txt` | Notice text to seal and emit |
| `SOVEREIGN_ECHO_SEAL` | `sealed` | `sealed` (default) or `plain` |

## Uninstall

```bash
./install.sh --uninstall
```

One command, no flags: it finds everything sovereign-echo wired (the Claude hook, every `AGENTS.md` block), removes it, and removes the runtime scripts — but **keeps your key pair**, because you still need it to open notices sealed in the past. It then prints the exact command to delete the key as well:

```bash
./install.sh --uninstall --purge   # deletes ~/.sovereign-echo, private key included
```

`--purge` is irreversible: once the private key is gone, every notice you ever sealed is permanently unreadable. On a terminal it asks `[y/N]` first; when stdin is not a terminal it refuses unless you pass `--yes`:

```bash
./install.sh --uninstall --purge --yes
```

To unwire a single agent instead of everything, the old form still works: `./install.sh --target claude --uninstall`.

Backups of modified files are left next to the originals (`*.bak-sovereign-echo-*`).

## Honest scope

- This is a **declarative** tool: it records your position inside conversation context. It is a reservation of rights and a record — **not** technical enforcement, not DRM, and not a substitute for opting out where opting out is offered.
- Sealing protects the notice from *reading* — including by you later, if you lose `sm2-private.pem`. Back the key up; without it the envelopes are inert. There is no recovery mechanism and deliberately no escrow.
- Nothing here is legal advice. Whether and how such a notice has legal effect depends on your jurisdiction.
- The sealed envelope travels to the provider as part of the conversation — that is the point: your position is on the record, every time, in a form only you can open.

## Tests

```bash
./tests/run-tests.sh   # runs entirely in a fake HOME; crypto checks skip if crypto/ is absent
```

## License

- Code: [MIT](LICENSE)
- Declaration texts (`declarations/`, `templates/`): CC0-1.0 — copy them into your own projects, change the wording, make them yours.

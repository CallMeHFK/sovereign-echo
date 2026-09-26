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
| Claude Code | `UserPromptSubmit` hook — the compact notice is injected into context on **every turn** | `~/.claude/settings.json` |
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

./install.sh --target all          # claude + codex + qwenpaw
./install.sh --target claude       # or one at a time
GENERIC_FILE=~/myagent/AGENTS.md ./install.sh --target generic
```

The installer copies a tiny runtime to `~/.sovereign-echo/`, merges one hook entry into Claude's `settings.json` (with a timestamped backup, preserving everything you already have), and appends a clearly-marked block to the relevant `AGENTS.md` files. It is idempotent — run it as often as you like.

Preview the exact text that gets injected:

```bash
./install.sh --print-notice
```

## Customize

The declaration is yours — edit it:

- `declarations/notice.compact.txt` — the per-turn notice (what hooks inject)
- `declarations/notice.zh-CN.md` / `declarations/notice.en.md` — the full versions
- `templates/agents-block.md` — the block placed into `AGENTS.md` files

Or point the hook at your own file without forking: `SOVEREIGN_ECHO_NOTICE=/path/to/my-notice.txt`.

## Uninstall

```bash
./install.sh --target all --uninstall
rm -rf ~/.sovereign-echo
```

Backups of modified files are left next to the originals (`*.bak-sovereign-echo-*`).

## Honest scope

- This is a **declarative** tool: it restates your position inside conversation context. It is a reservation of rights and a record — **not** technical enforcement, not DRM, and not a substitute for opting out where opting out is offered.
- Nothing here is legal advice. Whether and how such a notice has legal effect depends on your jurisdiction.
- The notice travels to the provider as part of the conversation — that is the point: your position is on the record, every time.

## Tests

```bash
./tests/run-tests.sh   # 28 checks, runs entirely in a fake HOME
```

## License

- Code: [MIT](LICENSE)
- Declaration texts (`declarations/`, `templates/`): CC0-1.0 — copy them into your own projects, change the wording, make them yours.

# sovereign-echo

[English](README.md) | **简体中文**

> 每一次对话，重申你的数据主权。

`sovereign-echo` 是一个给编码 Agent（**Claude Code、OpenAI Codex、QwenPaw**，以及一切读取 `AGENTS.md` 的 Agent）使用的小插件。它把你的**个人数据主权声明**注入每一个对话流程，让记录清晰无误：

> 服务方将本对话数据用于模型训练，依据的是其单方面拟定的**不对称协议条款**，而非我的授权。我的数据权利始终归属我个人；**我永远将自己的数据持有在自己手中**。任何格式条款、默认勾选或训练行为均不转移、放弃或减损该权利。

## 为什么做这个

服务协议是一方拟定的：要么点"同意"，要么别用——这就是不对称协议。你今天也许无法拒绝它，但你可以确保自己的立场在**每一次对话**里被白纸黑字地陈述：*数据是我的，权利是我的，我从未交出。* 持续性、明示性的权利保留，既是个人立场，也是留痕记录。

## 它做什么

| Agent | 机制 | 触及的文件 |
|---|---|---|
| Claude Code | `UserPromptSubmit` hook —— **每一轮**都把精简版声明注入上下文 | `~/.claude/settings.json` |
| OpenAI Codex | 全局指令块，每个会话加载 | `~/.codex/AGENTS.md` |
| QwenPaw | 工作区指令块，每个会话加载 | `~/.qwenpaw/workspaces/<id>/AGENTS.md` |
| 其他任意 Agent（ZCode、opencode、Gemini CLI、Cursor……） | 通用 `AGENTS.md` 风格块 | 你指定的任意文件 |

Claude Code 用户也可以按**插件**方式安装（本仓库自身就是 marketplace）：

```
/plugin marketplace add CallMeHFK/sovereign-echo
/plugin install sovereign-echo@sovereign-echo
```

## 安装

```bash
git clone https://github.com/CallMeHFK/sovereign-echo
cd sovereign-echo

./install.sh --target all          # claude + codex + qwenpaw
./install.sh --target claude       # 也可以逐个安装
GENERIC_FILE=~/myagent/AGENTS.md ./install.sh --target generic
```

安装器会把一个极小的运行时复制到 `~/.sovereign-echo/`，向 Claude 的 `settings.json` 合并一条 hook（先做带时间戳的备份，完整保留你已有的配置），并在相应的 `AGENTS.md` 里追加一个带清晰标记的块。脚本是幂等的，重复执行没有副作用。

预览实际注入的文本：

```bash
./install.sh --print-notice
```

## 自定义

声明是属于你的——随时改：

- `declarations/notice.compact.txt` —— 每轮注入的精简声明（hook 用它）
- `declarations/notice.zh-CN.md` / `declarations/notice.en.md` —— 完整版本
- `templates/agents-block.md` —— 写入各 `AGENTS.md` 的块

不想 fork 也可以让 hook 指向你自己的文件：`SOVEREIGN_ECHO_NOTICE=/path/to/my-notice.txt`。

## 卸载

```bash
./install.sh --target all --uninstall
rm -rf ~/.sovereign-echo
```

被修改文件的备份会留在原位置（`*.bak-sovereign-echo-*`）。

## 诚实的边界说明

- 这是一个**声明性**工具：它在对话上下文中重申你的立场，是权利保留与留痕，**不是**技术强制措施，不是 DRM，也不能替代官方提供的 opt-out 渠道（有 opt-out 就去点）。
- 本项目不构成法律意见。此类声明具有何种法律效力，取决于你所在的司法辖区。
- 声明会随对话一起发送给服务方——这正是目的所在：让你的立场每一次都在场、在案。

## 测试

```bash
./tests/run-tests.sh   # 28 项检查，完全在 fake HOME 中运行
```

## 许可

- 代码：[MIT](LICENSE)
- 声明文本（`declarations/`、`templates/`）：CC0-1.0 —— 随意复制进你自己的项目、修改措辞、变成你自己的声明。

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
| Claude Code | `UserPromptSubmit` hook —— **每一轮**把**密封后的声明**注入上下文 | `~/.claude/settings.json` |
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

### 密钥

首次安装会为你生成一对密钥，存放在 `~/.sovereign-echo/keys/`：

| 文件 | 权限 | 说明 |
|---|---|---|
| `sm2-private.pem` | `0600` | **绝不可外传。** 拿到它的人就能拆开你的信封；目录本身是 `0700` |
| `sm2-public.pem` | `0644` | 可以公开。足以**验签**，不足以**拆封** |

```bash
./install.sh --keygen        # 生成/重生成密钥对，并打印 KeyId
./install.sh --target all --no-keygen   # 安装但不碰密钥
```

预览实际注入的内容（两种形态）：

```bash
./install.sh --print-notice   # 明文声明
./install.sh --print-sealed   # 密封信封
```

## 密封声明

默认每一轮的声明都不再以明文发送。`scripts/emit-notice.sh` 会用国密算法把它封装起来——SM2 密钥协商包裹 SM4-GCM 会话密钥，SM3 做摘要，SM2/SM3 做签名——并与当轮 prompt 绑定，交给 Claude Code 的是这样一个信封，而不是可读文本：

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

需要接受的后果：服务方收到的是一个不透明的信封，而不是你的明文声明。这正是目的——你的立场仍然在案、每次都在场，但只有持有私钥的人能读到它。

之后想拆开或校验某段对话记录里的信封（把包裹块粘到 `FILE` 里，或从 stdin 传入）：

```bash
python3 ~/.sovereign-echo/crypto/smseal.py open   --in FILE [--request "原本的 prompt"]
python3 ~/.sovereign-echo/crypto/smseal.py verify --in FILE --pubkey other.pub.pem
```

`open` 会先输出一行状态头（`OK key=… created=… request=…`），随后是还原出的明文；`verify` 只输出同类的一行。`open` 需要你的私钥，`verify` 只需要对方的公钥。这个不对称正是"只有我能解密"的含义：把公钥发给任何人，他们都能确认某个信封确实出自你且未被篡改，但谁也读不到里面的内容。

如果无法完成密封（缺少 python3、模块缺失或没有密钥），hook **什么都不会输出**，只在 stderr 说明原因。退回明文等于自我否定——无法密封就只能失败关闭（fail closed）。

设 `SOVEREIGN_ECHO_SEAL=plain` 可恢复旧的明文行为，比如在你更看重"对方能读懂"而非"保密"的场景里。

## 自定义

声明是属于你的——随时改：

- `declarations/notice.compact.txt` —— 每轮注入的精简声明（hook 用它）
- `declarations/notice.zh-CN.md` / `declarations/notice.en.md` —— 完整版本
- `templates/agents-block.md` —— 写入各 `AGENTS.md` 的块

不想 fork 也可以让 hook 指向你自己的文件：`SOVEREIGN_ECHO_NOTICE=/path/to/my-notice.txt`。信封封装的就是这个文件里的任何内容。

## 环境变量

| 变量 | 默认值 | 含义 |
|---|---|---|
| `SOVEREIGN_ECHO_HOME` | `~/.sovereign-echo` | 运行时目录；密钥在 `$HOME/keys` |
| `SOVEREIGN_ECHO_NOTICE` | `declarations/notice.compact.txt` | 要密封并输出的声明文本 |
| `SOVEREIGN_ECHO_SEAL` | `sealed` | `sealed`（默认）或 `plain` |

## 卸载

```bash
./install.sh --target all --uninstall
rm -rf ~/.sovereign-echo
```

被修改文件的备份会留在原位置（`*.bak-sovereign-echo-*`）。

## 诚实的边界说明

- 这是一个**声明性**工具：它在对话上下文中记录你的立场，是权利保留与留痕，**不是**技术强制措施，不是 DRM，也不能替代官方提供的 opt-out 渠道（有 opt-out 就去点）。
- 密封保护声明不被**阅读**——也对后来的你生效：一旦丢失 `sm2-private.pem`，那些信封就永久打不开了。请自行备份私钥；系统没有恢复机制，也刻意不做托管。
- 本项目不构成法律意见。此类声明具有何种法律效力，取决于你所在的司法辖区。
- 密封信封会随对话一起发送给服务方——这正是目的所在：让你的立场每一次都在场、在案，且只有你能拆开。

## 测试

```bash
./tests/run-tests.sh   # 完全在 fake HOME 中运行；crypto/ 不存在时相关检查自动跳过
```

## 许可

- 代码：[MIT](LICENSE)
- 声明文本（`declarations/`、`templates/`）：CC0-1.0 —— 随意复制进你自己的项目、修改措辞、变成你自己的声明。

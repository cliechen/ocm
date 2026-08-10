# ocm — OpenClaw/Hermes Model Manager v2.2

🚀 交互式管理 **OpenClaw** 和 **Hermes Agent** 的 API 供应商、模型和默认模型的终端工具。

![Shell](https://img.shields.io/badge/Bash-5.2+-green)
![License](https://img.shields.io/badge/License-MIT-blue)

## ✨ 功能

- **双模式管理** — 主菜单选择 OpenClaw（JSON）或 Hermes（YAML）模式，随时切换（v2.2 新增）
- **API 供应商管理** — 添加/编辑/删除 API 提供商（URL、API Key）
- **模型管理** — 从本地配置读取模型，支持添加和删除
- **默认模型切换** — fzf 搜索切换，秒级响应，不依赖远程 API；跨供应商自动同步 base_url/api_key
- **Fallback 管理** — 设置降级模型链（Hermes 模式读写 `fallback_providers`）
- **🔗 连接测试** — 一键测试所有供应商连接状态（v2.1 新增）
- **💬 模型可用性测试** — 发送真实聊天请求验证模型（v2.1 新增）
- **💰 价格标签** — 模型列表显示输入成本和上下文窗口（v2.1 新增）
- **⚡ 自动验证** — 编辑 URL/Key 后自动测试连接（v2.1 新增）
- **🏃 运行时模型** — 显示 Gateway 当前实际使用的模型（v2.1 新增）
- **自动备份** — 每次修改前自动备份；还原时保存 clobbered 存档
- **方向键交互** — 基于 `gum` 的美观终端 UI，ESC 返回上级菜单

## 📦 安装

### 一键安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/cliechen/ocm/main/install.sh)
```

### 手动安装

```bash
curl -sL https://raw.githubusercontent.com/cliechen/ocm/main/ocm.sh -o ~/.local/bin/ocm
chmod +x ~/.local/bin/ocm
```

### 依赖

| 工具 | 用途 | 安装 |
|------|------|------|
| jq | 读写 OpenClaw JSON 配置 | `sudo apt install jq` / `brew install jq` |
| gum | 终端 UI | [charmbracelet/gum](https://github.com/charmbracelet/gum) |
| fzf | 模糊搜索切换 | `sudo apt install fzf` / `brew install fzf` |
| curl | 云端同步 / 连接测试 | 通常已预装 |
| python3 | 模型列表解析 / Hermes YAML 读取 | 通常已预装 |
| python3-yaml | **Hermes 模式必需**（pyyaml） | `pip3 install pyyaml` / `brew install libyaml python-yaml` |
| hermes | **Hermes 模式必需**（Nous Research Agent CLI） | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) |
| openclaw | OpenClaw 模式使用（网关重启/状态） | https://docs.openclaw.ai |

> 💡 Hermes 模式未安装 pyyaml 时会自动回退到 `hermes config get --json` 官方 CLI 读取配置。

## 🎯 使用

### 模式选择

直接运行 `ocm` 时先选择管理模式，之后随时可在主菜单中切换：

```
  ❯ 🟦 OpenClaw   (JSON 配置)
    🟩 Hermes     (YAML 配置)
    🚪 退出
```

也可用命令行参数或环境变量指定模式，跳过选择器：

```bash
ocm hermes            # 直接进入 Hermes 模式主菜单
ocm openclaw ls       # OpenClaw 模式列出模型
OCM_MODE=hermes ocm   # 环境变量方式
```

### 快捷命令

| 命令 | 说明 |
|------|------|
| `ocm` | 交互式主菜单（可选管理模式） |
| `ocm [hermes\|openclaw]` | 指定模式进入主菜单 |
| `ocm ls` | 列出所有模型（含价格标签） |
| `ocm switch` | fzf 快速切换默认模型 |
| `ocm sync` | 同步云端模型 |
| `ocm test` | 测试所有供应商连接状态 |
| `ocm status` | 查看 Gateway 状态 |
| `ocm restart` | 重启 Gateway |
| `ocm mode` | 显示当前管理模式 |
| `ocm help` | 显示帮助 |

### 主菜单示例

```
  ┌─ OpenClaw Model Manager v2.2 ─┐
  │ 默认模型 : kilo/mimo-v2-pro:free 💰免费 │
  │ 供应商   : 4                     │
  │ 模型总数 : 632                   │
  └─────────────────────────────────┘

  ❯ 🎯  快速切换模型
    📡  供应商管理
    📦  模型管理
    🔄  同步云端模型
    🔗  测试连接
    🔃  重启网关
    📊  查看状态
    ⏪  还原备份
    ↔  切换管理模式 (当前: OpenClaw)
    🚪  退出
```

### 测试供应商连接

```
━━ 测试所有供应商连接 ━━

  🔗 测试 kilo (https://api.kilo.ai)...
  ✅ kilo: 连接成功! 842ms, 338 个模型

  🔗 测试 openrouter (https://openrouter.ai)...
  ✅ openrouter: 连接成功! 280ms, 350 个模型

✓ 全部通过: 4/4 供应商正常
```

### 编辑供应商（v2.1）

编辑 URL 或 Key 后自动测试连接，确认修改生效：

```
编辑 openrouter
  🔗 测试连接 (Models API)       ← 新增
  💬 测试聊天 (Chat Completions)  ← 新增
  ✏️  修改地址
  🔑 修改密钥
  🔄 同步模型
  返回
```

### 模型列表

```
kilo/xiaomi/mimo-v2-pro:free [FREE] 1M    ← 免费模型
kilo/anthropic/claude-opus-4.6 $2.00入    ← 付费模型
kilo/openai/gpt-4.1 $1.25入 1M            ← 付费 + 百万上下文
```

## 🔧 工作原理

### OpenClaw 模式（JSON）

- 配置文件：`~/.openclaw/openclaw.json`（JSON，直接读写）
- 每次修改前自动备份到 `~/.openclaw/openclaw.json.bak`
- 模型切换写入 `agents.defaults.model.primary`，Fallback 写入 `agents.defaults.model.fallbacks`

### Hermes 模式（YAML）

- 配置文件：`~/.hermes/config.yaml`（YAML，通过官方 CLI 写入）
- 读取：python3+yaml 直接解析；未装 pyyaml 时回退 `hermes config get --json`
- 写入：`hermes config set --force <dotted.key> <value>`（支持点号嵌套键）
- 模型切换 → `model.default` / `model.provider` / `model.base_url` / `model.api_key`（跨供应商自动补齐）
- 供应商增删改 → `providers.<name>.base_url` / `providers.<name>.api_key`
- Fallback 管理 → 读写 `fallback_providers`（`provider/model` 条目）
- 同步模型 → 拉取 `/models` 写入 `~/.hermes/ocm-models.json` 缓存（Hermes 配置本身不存模型目录）
- 网关操作 → `hermes gateway restart / status`
- API Key 解析优先级：`providers.<name>.api_key` → `key_env` → 标准环境变量（`OPENROUTER_API_KEY` 等）→ `model.api_key`

### 通用

- `ocm test` 通过 `/models` 端点测试供应商连接
- `ocm test` 通过 `/chat/completions` 端点 (max_tokens=1) 测试模型
- 模型列表直接从本地配置读取，不调用远程 API

> ⚠ Hermes 模式前提：已安装 `hermes` CLI 并生成过 `~/.hermes/config.yaml`（`hermes setup` / `hermes model`）。

## 🛡️ 安全

- API Key 在终端中以 `****` 遮盖显示
- 密码输入使用 `gum --password` 隐藏
- 操作前均有确认提示
- 自动备份 + clobbered 存档，可随时还原
- Hermes 模式 API Key 优先从环境变量（`OPENROUTER_API_KEY` 等）读取，不强制落盘

## 📝 Changelog

### v2.2.0 (2026-08-11)
- ✦ 新增: Hermes Agent 管理模式，主菜单选择 OpenClaw / Hermes
- ✦ 新增: `ocm hermes <cmd>` / `OCM_MODE=hermes ocm <cmd>` 命令行用法
- ✦ Hermes: 切换默认模型 → `hermes config set model.default`（自动同步 provider/base_url/api_key）
- ✦ Hermes: 同步模型 → 拉取 `/models` 写入 `~/.hermes/ocm-models.json` 缓存（Hermes 配置本身不存模型目录）
- ✦ Hermes: 供应商增删改 → `hermes config set providers.<name>.*`
- ✦ Hermes: Fallback 管理 → 读写 `config.yaml` 的 `fallback_providers`（`provider/model` 条目）
- ✦ Hermes: 重启/状态 → `hermes gateway restart/status`；运行时模型从配置读取
- ⚠ Hermes 模式需要 `python3-yaml`（pyyaml）与 `hermes` CLI

### v2.1.4 (2026-08-11)
- ✦ 修复: 15 处 `[ -z "$ || return" ]` 错误占位符，ESC 返回逻辑恢复正常
- ✦ 修复: 所有 fzf/gum 调用补回 `|| return` 保护，按 ESC 不再被 `set -e` 直接退出程序
- ✦ 修复: 覆盖/删除供应商时按「否」仍继续执行的逻辑错误
- ✦ 修复: 全部乱码 (mojibake) 还原为正确中文显示
- ✦ 修复: 空列表时 `grep -c` 计数输出双行的问题
- ✦ 修复: 同步云端模型时 `jq input` 管道失效，模型无法写入配置的问题
- ✦ 恢复: 模型价格标签 ([FREE] / $0.15入 / 百万上下文)
- ✦ 修复: macOS 安装时 `gum` 误装 Linux 二进制、PATH 写入错误 shell 配置的问题

### v2.1.0 (2026-04-02)
- ✦ 新增: 测试供应商连接 (`ocm test` / 🔗 测试连接)
- ✦ 新增: 测试模型可用性 (发送真实聊天请求)
- ✦ 新增: 模型价格标签显示 (💰免费 / $0.15入)
- ✦ 新增: Gateway 运行时实际使用模型
- ✦ 新增: 批量测试所有供应商
- ✦ 增强: 编辑 URL/Key 后自动验证
- ✦ 增强: 同步云端后自动验证
- ✦ 增强: 还原备份保存 clobbered 存档
- ✦ 增强: 添加供应商前自动验证

### v2.0.0
- 全面重写：本地读取 0.2s 响应，不依赖远程 API
- 中文化：所有菜单和提示改为中文
- ESC 键改为返回上级菜单

## 📄 License

MIT

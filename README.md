# ocm — OpenClaw Model Manager v2.1

🚀 交互式管理 OpenClaw 的 API 供应商、模型和默认模型的终端工具。

![Shell](https://img.shields.io/badge/Bash-5.2+-green)
![License](https://img.shields.io/badge/License-MIT-blue)

## ✨ 功能

- **API 供应商管理** — 添加/编辑/删除 API 提供商（URL、API Key）
- **模型管理** — 从本地配置读取模型，支持添加和删除
- **默认模型切换** — fzf 搜索切换，秒级响应，不依赖远程 API
- **Fallback 管理** — 设置降级模型链
- **🔗 连接测试** — 一键测试所有供应商连接状态（v2.1 新增）
- **💬 模型可用性测试** — 发送真实聊天请求验证模型（v2.1 新增）
- **💰 价格标签** — 模型列表显示输入成本和上下文窗口（v2.1 新增）
- **⚡ 自动验证** — 编辑 URL/Key 后自动测试连接（v2.1 新增）
- **🏃 运行时模型** — 显示 Gateway 当前实际使用的模型（v2.1 新增）
- **自动备份** — 每次修改前自动备份；还原时保存 clobbered 存档
- **方向键交互** — 基于 `gum` 的美观终端 UI，ESC/q 退出

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

| 工具 | 安装 |
|------|------|
| jq | `sudo apt install jq` |
| gum | [charmbracelet/gum](https://github.com/charmbracelet/gum) |
| fzf | `sudo apt install fzf` |
| curl | `sudo apt install curl` |
| python3 | 通常已预装 |

## 🎯 使用

### 快捷命令

| 命令 | 说明 |
|------|------|
| `ocm` | 交互式主菜单 |
| `ocm ls` | 列出所有模型（含价格标签） |
| `ocm switch` | fzf 快速切换默认模型 |
| `ocm sync` | 同步云端模型 |
| `ocm test` | 测试所有供应商连接状态 |
| `ocm status` | 查看 Gateway 状态 |
| `ocm restart` | 重启 Gateway |
| `ocm help` | 显示帮助 |

### 主菜单示例

```
  ┌─ OpenClaw Model Manager v2.1 ─┐
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
kilo/xiaomi/mimo-v2-pro:free 💰免费 1M    ← 免费模型
kilo/anthropic/claude-opus-4.6 $2.00入    ← 付费模型
kilo/openai/gpt-4.1 $1.25入 1M            ← 付费 + 百万上下文
```

## 🔧 工作原理

- 配置文件：`~/.openclaw/openclaw.json`
- 每次修改前自动备份到 `~/.openclaw/openclaw.json.bak`
- `ocm test` 通过 `/models` 端点测试供应商连接
- `ocm test` 通过 `/chat/completions` 端点 (max_tokens=1) 测试模型
- 模型列表直接从本地 JSON 读取，不调用远程 API

## 🛡️ 安全

- API Key 在终端中以 `****` 遮盖显示
- 密码输入使用 `gum --password` 隐藏
- 操作前均有确认提示
- 自动备份 + clobbered 存档，可随时还原

## 📝 Changelog

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

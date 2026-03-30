# ocm — OpenClaw Model Manager

🚀 交互式管理 OpenClaw 的 API 供应商、模型和默认模型的终端工具。

![Shell](https://img.shields.io/badge/Bash-5.2+-green)
![License](https://img.shields.io/badge/License-MIT-blue)

## ✨ 功能

- **API 供应商管理** — 添加/编辑/删除 API 提供商（URL、API Key）
- **模型管理** — 从本地配置读取模型，支持添加和删除
- **默认模型切换** — fzf 搜索切换，秒级响应，不依赖远程 API
- **Fallback 管理** — 设置降级模型链
- **分类选择** — 免费模型 / 高端模型 / 全部模型分组展示
- **方向键交互** — 基于 `gum` 的美观终端 UI，ESC/q 退出
- **自动备份** — 每次修改前自动备份 `openclaw.json`

## 📦 安装

### 一键安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/cliechen/ocm/main/install.sh)
```

### 手动安装

```bash
# 下载
curl -sL https://raw.githubusercontent.com/cliechen/ocm/main/ocm.sh -o ~/.local/bin/ocm
chmod +x ~/.local/bin/ocm

# 确保 ~/.local/bin 在 PATH 中
export PATH="$HOME/.local/bin:$PATH"
```

### 依赖

| 工具 | 安装 |
|------|------|
| jq | `sudo apt install jq` |
| gum | `sudo apt install gum` |
| fzf | `sudo apt install fzf` |
| python3 | 通常已预装 |

## 🎯 使用

### 交互式菜单

```bash
ocm
```

方向键 `↑↓` 移动，`Enter` 确认，`q` / `ESC` 退出或返回上一步。

### 快捷命令

| 命令 | 说明 |
|------|------|
| `ocm` | 交互式主菜单 |
| `ocm ls` | 列出所有 Provider 和模型 |
| `ocm switch` | fzf 快速切换默认模型 |
| `ocm status` | 查看 Gateway 状态 |
| `ocm restart` | 重启 Gateway |
| `ocm help` | 显示帮助 |

### 主菜单

```
╔══════════════════════════════════════════╗
║     OpenClaw Model Manager (ocm)         ║
╠══════════════════════════════════════════╣
│  默认模型: kilo/xiaomi/mimo-v2-pro:free  │
╚══════════════════════════════════════════╝

  ❯ API 供应商管理
    模型管理
    快速切换模型
    查看总览
    重启 Gateway
    Gateway 状态
    还原配置备份
    退出
```

### API 供应商管理

```
  ❯ 添加 API 供应商
    编辑 URL
    编辑 API Key
    删除 API 供应商
    返回主菜单
```

添加供应商时会自动从 `/models` 端点获取模型列表，并用 fzf 选择默认模型。

### 模型切换

```
  ❯ kilo/xiaomi/mimo-v2-pro:free  ← DEFAULT
    kilo/anthropic/claude-opus-4.5
    kilo/openai/gpt-5.2
    kilo/google/gemini-2.5-pro
    ...
```

直接从本地配置读取，**无需联网**，响应秒级。

## 🔧 工作原理

- 配置文件：`~/.openclaw/openclaw.json`
- 每次修改前自动备份到 `~/.openclaw/openclaw.json.bak`
- 模型列表直接从本地 JSON 读取，不调用远程 API
- 修改后可选择自动重启 Gateway

## 🛡️ 安全

- API Key 在终端中以 `****` 遮盖显示
- 密码输入使用 `gum --password` 隐藏
- 操作前均有确认提示
- 自动备份可随时还原

## 📄 License

MIT

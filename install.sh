#!/usr/bin/env bash
# ============================================================
#  ocm installer
#  用法: bash <(curl -sL https://raw.githubusercontent.com/USER/ocm/main/install.sh)
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║    OpenClaw Model Manager Installer   ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
echo ""

# 检查依赖
echo -e "${YELLOW}检查依赖...${NC}"

missing=()
command -v jq  &>/dev/null || missing+=("jq")
command -v gum &>/dev/null || missing+=("gum")
command -v fzf &>/dev/null || missing+=("fzf")
command -v python3 &>/dev/null || missing+=("python3") # Python3 required
command -v openclaw &>/dev/null || missing+=("openclaw")

if [[ " ${missing[*]} " == *" openclaw "* ]]; then
  echo -e "${RED}✗ 未检测到 OpenClaw，请先安装: https://docs.openclaw.ai${NC}"
  exit 1
fi

if [ ${#missing[@]} -gt 0 ]; then
  echo -e "正在安装缺失依赖: ${missing[*]}"
  if command -v apt &>/dev/null; then
    sudo apt update -qq && sudo apt install -y -qq "${missing[@]}" 2>/dev/null
  elif command -v dnf &>/dev/null; then
    sudo dnf install -y "${missing[@]}" 2>/dev/null
  elif command -v yum &>/dev/null; then
    sudo yum install -y "${missing[@]}" 2>/dev/null
  elif command -v pacman &>/dev/null; then
    sudo pacman -S --noconfirm "${missing[@]}" 2>/dev/null
  elif command -v brew &>/dev/null; then
    brew install "${missing[@]}" 2>/dev/null
  else
    echo -e "${RED}✗ 无法自动安装，请手动安装: ${missing[*]}${NC}"
    exit 1
  fi
fi

# 安装 ocm
INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "$INSTALL_DIR"

echo -e "${YELLOW}安装 ocm 到 ${INSTALL_DIR}/ocm ...${NC}"

curl -sL "https://raw.githubusercontent.com/cliechen/ocm/main/ocm.sh" -o "${INSTALL_DIR}/ocm"
chmod +x "${INSTALL_DIR}/ocm"

# 确保 ~/.local/bin 在 PATH 中
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
  SHELL_RC=""
  if [ -n "${BASH_VERSION:-}" ]; then
    SHELL_RC="$HOME/.bashrc"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    SHELL_RC="$HOME/.zshrc"
  else
    SHELL_RC="$HOME/.bashrc"
  fi

  echo "" >> "$SHELL_RC"
  echo "# OpenClaw Model Manager" >> "$SHELL_RC"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
  echo -e "${YELLOW}已添加 PATH 到 $SHELL_RC，请运行: source $SHELL_RC${NC}"
fi

# 创建全局快捷方式
if [ -w /usr/local/bin ] 2>/dev/null || sudo -n true 2>/dev/null; then
  sudo ln -sf "${INSTALL_DIR}/ocm" /usr/local/bin/ocm 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}✓ 安装完成！${NC}"
echo ""
echo "  用法:"
echo "    ocm              交互式菜单"
echo "    ocm ls           列出所有模型"
echo "    ocm switch       快速切换模型"
echo "    ocm help         查看帮助"
echo ""

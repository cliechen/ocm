#!/usr/bin/env bash
# ============================================================
#  ocm installer
#  用法: bash <(curl -sL https://raw.githubusercontent.com/cliechen/ocm/main/install.sh)
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   OpenClaw Model Manager (ocm) Installer  ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
echo ""

# 检查 OpenClaw
if ! command -v openclaw &>/dev/null; then
  echo -e "${RED}✗ 未检测到 OpenClaw，请先安装: https://docs.openclaw.ai${NC}"
  exit 1
fi

# 检查并安装依赖
install_pkg() {
  local pkg="$1"
  echo -e "  ${YELLOW}安装 ${pkg}...${NC}"
  if command -v apt &>/dev/null; then
    sudo apt install -y -qq "$pkg" 2>/dev/null
  elif command -v dnf &>/dev/null; then
    sudo dnf install -y "$pkg" 2>/dev/null
  elif command -v yum &>/dev/null; then
    sudo yum install -y "$pkg" 2>/dev/null
  elif command -v pacman &>/dev/null; then
    sudo pacman -S --noconfirm "$pkg" 2>/dev/null
  elif command -v brew &>/dev/null; then
    brew install "$pkg" 2>/dev/null
  else
    return 1
  fi
}

install_gum() {
  # gum 不在标准源，用官方安装脚本
  echo -e "  ${YELLOW}安装 gum (Charmbracelet)...${NC}"
  if command -v apt &>/dev/null; then
    # Debian/Ubuntu: 用官方 apt 源
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg 2>/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
    sudo apt update -qq 2>/dev/null && sudo apt install -y -qq gum 2>/dev/null
  else
    # 通用: go install 或下载二进制
    local arch
    arch=$(uname -m)
    case "$arch" in
      x86_64)  arch="amd64" ;;
      aarch64) arch="arm64" ;;
      armv7l)  arch="armv7" ;;
    esac
    local url="https://github.com/charmbracelet/gum/releases/latest/download/gum_0.17.0_Linux_${arch}.tar.gz"
    curl -sL "$url" | sudo tar -xz -C /usr/local/bin gum 2>/dev/null
  fi
}

install_fzf() {
  echo -e "  ${YELLOW}安装 fzf...${NC}"
  if command -v apt &>/dev/null; then
    sudo apt install -y -qq fzf 2>/dev/null
  elif command -v git &>/dev/null; then
    git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf 2>/dev/null
    ~/.fzf/install --all --no-update-rc 2>/dev/null
  else
    return 1
  fi
}

echo -e "${CYAN}检查依赖...${NC}"

# jq
if ! command -v jq &>/dev/null; then
  install_pkg jq || { echo -e "${RED}✗ jq 安装失败${NC}"; exit 1; }
  echo -e "  ${GREEN}✓ jq${NC}"
else
  echo -e "  ${GREEN}✓ jq${NC}"
fi

# python3
if ! command -v python3 &>/dev/null; then
  install_pkg python3 || { echo -e "${RED}✗ python3 安装失败${NC}"; exit 1; }
  echo -e "  ${GREEN}✓ python3${NC}"
else
  echo -e "  ${GREEN}✓ python3${NC}"
fi

# gum
if ! command -v gum &>/dev/null; then
  install_gum || { echo -e "${RED}✗ gum 安装失败，请手动安装: https://github.com/charmbracelet/gum${NC}"; exit 1; }
  echo -e "  ${GREEN}✓ gum${NC}"
else
  echo -e "  ${GREEN}✓ gum${NC}"
fi

# fzf
if ! command -v fzf &>/dev/null; then
  install_fzf || { echo -e "${RED}✗ fzf 安装失败，请手动安装: https://github.com/junegunn/fzf${NC}"; exit 1; }
  echo -e "  ${GREEN}✓ fzf${NC}"
else
  echo -e "  ${GREEN}✓ fzf${NC}"
fi

# 安装 ocm
INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "$INSTALL_DIR"

echo ""
echo -e "${CYAN}下载 ocm...${NC}"
curl -fsSL "https://raw.githubusercontent.com/cliechen/ocm/main/ocm.sh" -o "${INSTALL_DIR}/ocm"
chmod +x "${INSTALL_DIR}/ocm"

# PATH
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
  SHELL_RC="${HOME}/.bashrc"
  [ -n "${ZSH_VERSION:-}" ] && SHELL_RC="${HOME}/.zshrc"

  if ! grep -q '.local/bin' "$SHELL_RC" 2>/dev/null; then
    echo '' >> "$SHELL_RC"
    echo '# OpenClaw Model Manager' >> "$SHELL_RC"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
    echo -e "  ${YELLOW}已添加 PATH 到 $SHELL_RC${NC}"
  fi
  export PATH="$INSTALL_DIR:$PATH"
fi

# 快捷方式
if sudo ln -sf "${INSTALL_DIR}/ocm" /usr/local/bin/ocm 2>/dev/null; then
  echo -e "  ${GREEN}✓ 快捷方式: /usr/local/bin/ocm${NC}"
fi

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           ✓ 安装完成！                    ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}ocm${NC}              交互式菜单"
echo -e "  ${CYAN}ocm ls${NC}           列出所有模型"
echo -e "  ${CYAN}ocm switch${NC}       快速切换模型"
echo -e "  ${CYAN}ocm sync${NC}         同步云端模型"
echo -e "  ${CYAN}ocm help${NC}         查看帮助"
echo ""

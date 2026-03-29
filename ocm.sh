#!/usr/bin/env bash
# ============================================================
#  ocm.sh — OpenClaw Model Manager (gum UI)
#  交互式管理 OpenClaw 的 Providers / Models / 默认模型
#  依赖: jq, gum, fzf
#  用法: ocm
# ============================================================
set -euo pipefail

CONFIG="$HOME/.openclaw/openclaw.json"
BACKUP="$HOME/.openclaw/openclaw.json.bak"

# ---------- 颜色 ----------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1;37m'; NC='\033[0m'

# ---------- 依赖检查 ----------
need_jq()  { command -v jq  &>/dev/null || { echo -e "${R}需要 jq${NC}"; exit 1; }; }
need_gum() { command -v gum &>/dev/null || { echo -e "${R}需要 gum: apt install gum${NC}"; exit 1; }; }
need_fzf() { command -v fzf &>/dev/null || { echo -e "${R}需要 fzf: apt install fzf${NC}"; exit 1; }; }

# ---------- 工具函数 ----------
info() { gum style --foreground 46 "✓ $*"; }
warn() { gum style --foreground 214 "⚠ $*"; }
err()  { gum style --foreground 196 "✗ $*"; }

backup() {
  cp "$CONFIG" "$BACKUP"
  gum style --foreground 240 "  已备份 → $BACKUP"
}

list_providers() { jq -r '.models.providers | keys[]' "$CONFIG" 2>/dev/null; }
get_base_url()   { jq -r ".models.providers.\"$1\".baseUrl // \"(未设置)\"" "$CONFIG"; }
get_api_type()   { jq -r ".models.providers.\"$1\".api // \"openai-completions\"" "$CONFIG"; }
get_api_key_mask() { local k; k=$(jq -r ".models.providers.\"$1\".apiKey // \"\"" "$CONFIG"); echo "${k:0:8}****"; }
list_models()    { jq -r ".models.providers.\"$1\".models[]?.id // empty" "$CONFIG" 2>/dev/null; }
get_default_model() { jq -r '.agents.defaults.model.primary // "(未设置)"' "$CONFIG"; }
get_fallbacks()  { jq -r '(.agents.defaults.model.fallbacks // [])[]' "$CONFIG" 2>/dev/null; }

# ============================================================
#  Provider 列表（带延迟检测）
# ============================================================
show_provider_list() {
  echo ""
  gum style --bold --foreground 51 "━━ API 供应商列表 ━━"
  echo ""

  local current
  current=$(get_default_model)
  echo -e "  默认模型: ${C}${current}${NC}"
  local fc
  fc=$(get_fallbacks | wc -l | tr -d ' ')
  [ "$fc" -gt 0 ] && echo -e "  Fallback: ${Y}${fc}${NC} 个"
  echo ""

  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(list_providers)

  if [ ${#providers[@]} -eq 0 ]; then
    warn "没有配置任何 Provider"
    return
  fi

  for i in "${!providers[@]}"; do
    local p="${providers[$i]}"
    local url api key_mask model_count
    url=$(get_base_url "$p")
    api=$(get_api_type "$p")
    key_mask=$(get_api_key_mask "$p")
    model_count=$(list_models "$p" | wc -l | tr -d ' ')

    printf "  ${Y}[%d]${NC} %-15s ${C}%-40s${NC}\n" "$((i+1))" "$p" "$url"
    printf "      API: %-25s 模型: ${G}%s${NC}  Key: %s\n" "$api" "$model_count" "$key_mask"
  done
  echo ""
}

# ============================================================
#  添加 Provider（gum 交互式）
# ============================================================
add_provider() {
  echo ""
  gum style --bold --foreground 51 "━━ 添加 API 供应商 ━━"
  echo ""

  local pname base_url api_key api_type
  pname=$(gum input --placeholder "Provider 名称 (如: openai, anthropic, deepseek)" --prompt "Provider > ") || return
  [ -z "$pname" ] && { warn "名称不能为空"; return; }

  if jq -e ".models.providers.\"$pname\"" "$CONFIG" &>/dev/null; then
    gum confirm "Provider '$pname' 已存在，覆盖?" || return
  fi

  base_url=$(gum input --placeholder "https://api.xxx.com/v1" --prompt "Base URL > ") || return
  [ -z "$base_url" ] && { warn "URL 不能为空"; return; }
  base_url="${base_url%/}"

  api_key=$(gum input --password --placeholder "sk-xxx" --prompt "API Key > ") || return
  [ -z "$api_key" ] && { warn "API Key 不能为空"; return; }

  api_type=$(gum input --placeholder "openai-completions" --prompt "API 类型 > ")
  api_type="${api_type:-openai-completions}"

  # 尝试自动获取模型列表
  local models_json available_models model_count=0
  gum style --foreground 240 "  正在获取模型列表..."
  models_json=$(curl -s -m 10 -H "Authorization: Bearer $api_key" "${base_url}/models" 2>/dev/null || true)

  if [ -n "$models_json" ]; then
    available_models=$(echo "$models_json" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get("data", data) if isinstance(data, dict) else data
    ids = sorted(set(m["id"] for m in models if isinstance(m, dict) and "id" in m))
    print("\n".join(ids))
except: pass
' 2>/dev/null || true)
    model_count=$(echo "$available_models" | grep -c . 2>/dev/null || echo 0)
  fi

  if [ -n "$available_models" ] && [ "$model_count" -gt 0 ]; then
    gum style --foreground 46 "  发现 $model_count 个模型"
    echo ""

    # 用 fzf 选择默认模型
    local default_model
    default_model=$(echo "$available_models" | fzf \
      --prompt="  ❯ " \
      --header="  选择默认模型  │  ↑↓ 移动  / 搜索  Enter 确认  Esc 跳过" \
      --header-first \
      --height=15 --layout=reverse --border=rounded \
      --border-label=" ◈ DEFAULT MODEL " \
      --color=border:51,label:51,header:51,prompt:201,pointer:46,marker:208,hl:208,hl+:208) || default_model=""

    echo ""
    gum style --border normal --border-foreground 99 --padding "0 2" \
      "Provider  : $pname" \
      "Base URL  : $base_url" \
      "API Key   : ${api_key:0:8}****" \
      "API 类型  : $api_type" \
      "模型总数  : $model_count" \
      "默认模型  : ${default_model:-(未选择)}"
    echo ""

    gum confirm "确认添加?" || { echo "已取消"; return; }
    backup

    # 构建 models 数组
    local models_arr="[]"
    while IFS= read -r mid; do
      [ -z "$mid" ] && continue
      models_arr=$(echo "$models_arr" | jq --arg id "$mid" '. += [{id: $id, name: $id, input: ["text"], contextWindow: 128000, maxTokens: 16384}]')
    done <<< "$available_models"

    jq --arg p "$pname" --arg url "$base_url" --arg key "$api_key" --arg api "$api_type" --argjson models "$models_arr" \
      '.models.providers[$p] = {baseUrl: $url, apiKey: $key, api: $api, models: $models}' \
      "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

    # 设置默认模型
    if [ -n "$default_model" ]; then
      jq --arg m "${pname}/${default_model}" '.agents.defaults.model.primary = $m' \
        "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
    fi

    info "Provider '$pname' 已添加，$model_count 个模型"
  else
    # 没有获取到模型，手动添加
    gum style --foreground 214 "  未能自动获取模型列表"
    echo ""

    gum style --border normal --border-foreground 99 --padding "0 2" \
      "Provider  : $pname" \
      "Base URL  : $base_url" \
      "API Key   : ${api_key:0:8}****" \
      "API 类型  : $api_type"
    echo ""

    gum confirm "确认添加?" || { echo "已取消"; return; }
    backup

    jq --arg p "$pname" --arg url "$base_url" --arg key "$api_key" --arg api "$api_type" \
      '.models.providers[$p] = {baseUrl: $url, apiKey: $key, api: $api, models: []}' \
      "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

    info "Provider '$pname' 已添加（无模型，稍后手动添加）"
  fi
}

# ============================================================
#  编辑 Provider URL
# ============================================================
edit_provider_url() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(list_providers)
  [ ${#providers[@]} -eq 0 ] && { warn "没有 Provider"; return; }

  local items=("返回")
  for p in "${providers[@]}"; do
    items+=("$(printf '%-15s → %s' "$p" "$(get_base_url "$p")")")
  done

  local choice
  choice=$(gum choose --cursor "❯ " --header $'选择要编辑的 Provider\n↑↓ 移动 · Enter 确认 · q 退出' "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local pname
  pname=$(echo "$choice" | awk '{print $1}')
  local old_url
  old_url=$(get_base_url "$pname")

  local new_url
  new_url=$(gum input --value "$old_url" --placeholder "新 URL" --prompt "Base URL > ") || return
  [ -z "$new_url" ] && return
  new_url="${new_url%/}"

  backup
  jq --arg p "$pname" --arg url "$new_url" '.models.providers[$p].baseUrl = $url' \
    "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "URL 已更新: $pname"
}

# ============================================================
#  编辑 API Key
# ============================================================
edit_provider_key() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(list_providers)
  [ ${#providers[@]} -eq 0 ] && { warn "没有 Provider"; return; }

  local items=("返回")
  for p in "${providers[@]}"; do
    items+=("$(printf '%-15s Key: %s' "$p" "$(get_api_key_mask "$p")")")
  done

  local choice
  choice=$(gum choose --cursor "❯ " --header $'选择要编辑的 Provider\n↑↓ 移动 · Enter 确认 · q 退出' "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local pname
  pname=$(echo "$choice" | awk '{print $1}')

  local new_key
  new_key=$(gum input --password --placeholder "新 API Key" --prompt "API Key > ") || return
  [ -z "$new_key" ] && return

  backup
  jq --arg p "$pname" --arg key "$new_key" '.models.providers[$p].apiKey = $key' \
    "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "API Key 已更新: $pname"
}

# ============================================================
#  删除 Provider
# ============================================================
delete_provider() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(list_providers)
  [ ${#providers[@]} -eq 0 ] && { warn "没有 Provider"; return; }

  local items=("返回")
  for p in "${providers[@]}"; do
    local mc
    mc=$(list_models "$p" | wc -l | tr -d ' ')
    items+=("$(printf '%-15s %s 个模型' "$p" "$mc")")
  done

  local choice
  choice=$(gum choose --cursor "❯ " --header $'选择要删除的 Provider\n↑↓ 移动 · Enter 确认 · q 退出' "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local pname
  pname=$(echo "$choice" | awk '{print $1}')

  gum confirm "⚠ 确认删除 Provider '$pname' 及其所有模型?" || return

  backup
  jq "del(.models.providers.\"$pname\")" "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "Provider '$pname' 已删除"
}

# ============================================================
#  添加模型
# ============================================================
add_model() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(list_providers)
  [ ${#providers[@]} -eq 0 ] && { warn "没有 Provider"; return; }

  local items=("返回")
  items+=("${providers[@]}")

  local choice
  choice=$(gum choose --cursor "❯ " --header $'选择 Provider\n↑↓ 移动 · Enter 确认 · q 退出' "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local provider="$choice"
  local model_id
  model_id=$(gum input --placeholder "模型 ID (如 gpt-4o)" --prompt "Model ID > ") || return
  [ -z "$model_id" ] && return

  local model_name
  model_name=$(gum input --placeholder "$model_id" --prompt "显示名称 > ")
  model_name="${model_name:-$model_id}"

  backup
  jq --arg p "$provider" --arg id "$model_id" --arg name "$model_name" \
    '.models.providers[$p].models += [{id: $id, name: $name, input: ["text"], contextWindow: 128000, maxTokens: 16384}]' \
    "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "模型 '$model_id' 已添加到 '$provider'"
}

# ============================================================
#  删除模型
# ============================================================
delete_model() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(list_providers)
  [ ${#providers[@]} -eq 0 ] && { warn "没有 Provider"; return; }

  local items=("返回")
  items+=("${providers[@]}")

  local choice
  choice=$(gum choose --cursor "❯ " --header $'选择 Provider\n↑↓ 移动 · Enter 确认 · q 退出' "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local provider="$choice"
  local models=()
  while IFS= read -r m; do [ -n "$m" ] && models+=("$m"); done < <(list_models "$provider")
  [ ${#models[@]} -eq 0 ] && { warn "该 Provider 下没有模型"; return; }

  local mitems=("返回")
  mitems+=("${models[@]}")

  local mid
  mid=$(gum choose --cursor "❯ " --header $'选择要删除的模型\n↑↓ 移动 · Enter 确认 · q 退出' "${mitems[@]}") || return
  [[ "$mid" == "返回" ]] && return

  backup
  jq --arg p "$provider" --arg id "$mid" \
    '.models.providers[$p].models = [.models.providers[$p].models[] | select(.id != $id)]' \
    "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "模型 '$mid' 已删除"
}

# ============================================================
#  快速切换模型（fzf 搜索选择）
# ============================================================
quick_switch() {
  local all_models=()
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(list_providers)

  for p in "${providers[@]}"; do
    while IFS= read -r m; do
      [ -n "$m" ] && all_models+=("${p}/${m}")
    done < <(list_models "$p")
  done

  [ ${#all_models[@]} -eq 0 ] && { warn "没有可用模型"; return; }

  local current
  current=$(get_default_model)

  # 写入临时文件用于 fzf
  local tmpfile
  tmpfile=$(mktemp)
  for m in "${all_models[@]}"; do
    if [ "$m" = "$current" ]; then
      echo "$m  ← 当前默认" >> "$tmpfile"
    else
      echo "$m" >> "$tmpfile"
    fi
  done

  local selected
  selected=$(fzf \
    --prompt="  ❯ " \
    --header="  当前: $current  │  ↑↓ 移动  / 搜索  Enter 确认  Esc 取消" \
    --header-first \
    --height=20 --layout=reverse --border=rounded \
    --border-label=" ◈ 切换默认模型 " \
    --color=border:51,label:51,header:51,prompt:201,pointer:46,marker:208,hl:208,hl+:208 \
    < "$tmpfile") || { rm -f "$tmpfile"; return; }
  rm -f "$tmpfile"

  [ -z "$selected" ] && return
  selected=$(echo "$selected" | sed 's/  ← 当前默认//')

  backup
  jq --arg m "$selected" '.agents.defaults.model.primary = $m' \
    "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "默认模型已切换为: $selected"

  gum confirm "重启 Gateway 生效?" && {
    gum spin --spinner minidot --title "正在重启..." -- openclaw gateway restart 2>/dev/null && info "Gateway 已重启" || warn "重启失败"
  }
}

# ============================================================
#  设置默认模型（分类选择）
# ============================================================
set_default() {
  local all_models=()
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(list_providers)

  for p in "${providers[@]}"; do
    while IFS= read -r m; do
      [ -n "$m" ] && all_models+=("${p}/${m}")
    done < <(list_models "$p")
  done

  [ ${#all_models[@]} -eq 0 ] && { warn "没有可用模型"; return; }

  local current
  current=$(get_default_model)

  # 分类
  local free_models=() top_models=() other_models=()
  for m in "${all_models[@]}"; do
    if [[ "$m" == *":free"* ]]; then
      free_models+=("$m")
    elif [[ "$m" =~ (opus|gpt-5[^a-z]|gemini.*pro|grok-4[^a-z]|deepseek-r1[^a-z]|o3[^a-z]|o4[^a-z]|claude-sonnet-4[^a-z]|qwen3-max) ]] && [[ "$m" != *":free"* ]]; then
      top_models+=("$m")
    else
      other_models+=("$m")
    fi
  done

  # 构建选择列表
  local items=("返回")
  if [ ${#free_models[@]} -gt 0 ]; then
    items+=("── 免费模型 ──")
    for m in "${free_models[@]}"; do items+=("$m"); done
  fi
  if [ ${#top_models[@]} -gt 0 ]; then
    items+=("── 高端模型 ──")
    for m in "${top_models[@]}"; do items+=("$m"); done
  fi
  items+=("── 全部模型 ──")
  for m in "${other_models[@]}"; do items+=("$m"); done

  local selected
  selected=$(gum choose --cursor "❯ " --header "当前默认: $current\n↑↓ 移动 · / 搜索 · Enter 确认 · q 退出" --height 25 "${items[@]}") || return
  [[ "$selected" == "返回" ]] && return
  [[ "$selected" == "──"* ]] && return

  backup
  jq --arg m "$selected" '.agents.defaults.model.primary = $m' \
    "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "默认模型已设为: $selected"
}

# ============================================================
#  设置 Fallback 模型
# ============================================================
set_fallback() {
  local action
  action=$(gum choose --cursor "❯ " --header $'Fallback 模型管理\n↑↓ 移动 · Enter 确认 · q 退出' \
    "查看当前 Fallback" \
    "添加 Fallback" \
    "移除 Fallback" \
    "清空全部 Fallback" \
    "返回") || return

  case "$action" in
    "查看当前 Fallback")
      echo ""
      gum style --bold "当前 Fallback 模型:"
      local has=false
      while IFS= read -r fb; do
        [ -z "$fb" ] && continue
        has=true
        echo "  → $fb"
      done < <(get_fallbacks)
      $has || echo "  (空)"
      echo ""
      gum input --placeholder "按回车返回" > /dev/null
      ;;
    "添加 Fallback")
      local all_models=()
      local providers=()
      while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(list_providers)
      for p in "${providers[@]}"; do
        while IFS= read -r m; do [ -n "$m" ] && all_models+=("${p}/${m}"); done < <(list_models "$p")
      done
      [ ${#all_models[@]} -eq 0 ] && { warn "没有可用模型"; return; }

      local mid
      mid=$(printf '%s\n' "${all_models[@]}" | fzf \
        --prompt="  ❯ " \
        --header="  选择 Fallback 模型  │  ↑↓ / 搜索  Enter 确认  Esc 取消" \
        --header-first --height=15 --layout=reverse --border=rounded \
        --border-label=" ◈ ADD FALLBACK " \
        --color=border:51,label:51,header:51,prompt:201,pointer:46,marker:208,hl:208,hl+:208) || return
      [ -z "$mid" ] && return

      backup
      jq --arg m "$mid" \
        '.agents.defaults.model.fallbacks = ((.agents.defaults.model.fallbacks // []) + [$m] | unique)' \
        "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
      info "已添加 Fallback: $mid"
      ;;
    "移除 Fallback")
      local fbs=()
      while IFS= read -r fb; do [ -n "$fb" ] && fbs+=("$fb"); done < <(get_fallbacks)
      [ ${#fbs[@]} -eq 0 ] && { warn "没有 Fallback"; return; }

      local mitems=("返回")
      mitems+=("${fbs[@]}")
      local mid
      mid=$(gum choose --cursor "❯ " --header "选择要移除的 Fallback" "${mitems[@]}") || return
      [[ "$mid" == "返回" ]] && return

      backup
      jq --arg m "$mid" \
        '.agents.defaults.model.fallbacks = [(.agents.defaults.model.fallbacks // [])[] | select(. != $m)]' \
        "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
      info "已移除 Fallback: $mid"
      ;;
    "清空全部 Fallback")
      gum confirm "确认清空所有 Fallback?" || return
      backup
      jq '.agents.defaults.model.fallbacks = []' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
      info "已清空 Fallback"
      ;;
    "返回"|*) return ;;
  esac
}

# ============================================================
#  Provider 管理子菜单
# ============================================================
provider_menu() {
  while true; do
    clear
    gum style --bold --foreground 51 "━━ API 供应商管理 ━━"
    echo ""
    show_provider_list

    local action
    action=$(gum choose --cursor "❯ " --header $'选择操作\n↑↓ 移动 · Enter 确认 · q/ESC 返回' \
      "添加 API 供应商" \
      "编辑 URL" \
      "编辑 API Key" \
      "删除 API 供应商" \
      "返回主菜单") || return

    case "$action" in
      "添加 API 供应商")    add_provider; gum input --placeholder "按回车继续" > /dev/null ;;
      "编辑 URL")           edit_provider_url; gum input --placeholder "按回车继续" > /dev/null ;;
      "编辑 API Key")       edit_provider_key; gum input --placeholder "按回车继续" > /dev/null ;;
      "删除 API 供应商")    delete_provider; gum input --placeholder "按回车继续" > /dev/null ;;
      "返回主菜单"|*)       return ;;
    esac
  done
}

# ============================================================
#  模型管理子菜单
# ============================================================
model_menu() {
  while true; do
    clear
    gum style --bold --foreground 51 "━━ 模型管理 ━━"
    echo ""
    echo -e "  默认模型: ${C}$(get_default_model)${NC}"
    local fc; fc=$(get_fallbacks | wc -l | tr -d ' ')
    [ "$fc" -gt 0 ] && echo -e "  Fallback: ${Y}${fc}${NC} 个"
    echo ""

    local action
    action=$(gum choose --cursor "❯ " --header $'选择操作\n↑↓ 移动 · Enter 确认 · q/ESC 返回' \
      "快速切换默认模型 (fzf)" \
      "选择默认模型 (分类)" \
      "管理 Fallback 模型" \
      "添加模型" \
      "删除模型" \
      "返回主菜单") || return

    case "$action" in
      "快速切换默认模型 (fzf)") quick_switch; gum input --placeholder "按回车继续" > /dev/null ;;
      "选择默认模型 (分类)")    set_default; gum input --placeholder "按回车继续" > /dev/null ;;
      "管理 Fallback 模型")     set_fallback ;;
      "添加模型")               add_model; gum input --placeholder "按回车继续" > /dev/null ;;
      "删除模型")               delete_model; gum input --placeholder "按回车继续" > /dev/null ;;
      "返回主菜单"|*)           return ;;
    esac
  done
}

# ============================================================
#  主菜单
# ============================================================
main_menu() {
  while true; do
    clear
    local default_model
    default_model=$(get_default_model)

    echo ""
    gum style --bold --foreground 51 --border double --border-foreground 51 --padding "0 2" \
      "OpenClaw Model Manager (ocm)"
    echo ""
    gum style --foreground 240 "  默认模型: ${default_model}"
    echo ""

    local action
    action=$(gum choose --cursor "❯ " --header $'↑↓ 移动 · Enter 确认 · q/ESC 退出' \
      "API 供应商管理" \
      "模型管理" \
      "快速切换模型" \
      "查看总览" \
      "重启 Gateway" \
      "Gateway 状态" \
      "还原配置备份" \
      "退出") || exit 0

    case "$action" in
      "API 供应商管理")   provider_menu ;;
      "模型管理")          model_menu ;;
      "快速切换模型")      quick_switch; gum input --placeholder "按回车继续" > /dev/null ;;
      "查看总览")          show_provider_list; gum input --placeholder "按回车继续" > /dev/null ;;
      "重启 Gateway")      gum spin --spinner minidot --title "正在重启..." -- openclaw gateway restart 2>/dev/null && info "Gateway 已重启" || warn "重启失败"; gum input --placeholder "按回车继续" > /dev/null ;;
      "Gateway 状态")      openclaw gateway status 2>/dev/null || openclaw status 2>/dev/null || warn "状态查询失败"; echo ""; gum input --placeholder "按回车继续" > /dev/null ;;
      "还原配置备份")
        if [ -f "$BACKUP" ]; then
          gum confirm "从备份还原配置?" && { cp "$BACKUP" "$CONFIG"; info "已还原"; }
        else
          warn "没有备份文件"
        fi
        gum input --placeholder "按回车继续" > /dev/null
        ;;
      "退出"|*) exit 0 ;;
    esac
  done
}

# ============================================================
#  入口
# ============================================================
need_jq
need_gum
need_fzf

[ -f "$CONFIG" ] || { err "配置文件不存在: $CONFIG"; exit 1; }

# 快捷命令模式
case "${1:-}" in
  ls|list)    show_provider_list; exit ;;
  switch)     quick_switch; exit ;;
  status)     openclaw gateway status 2>/dev/null || openclaw status; exit ;;
  restart)    openclaw gateway restart; exit ;;
  help|--help|-h)
    gum style --bold "ocm — OpenClaw Model Manager"
    echo ""
    echo "  ocm              交互式菜单 (方向键选择)"
    echo "  ocm ls           列出所有 Provider 和模型"
    echo "  ocm switch       快速切换默认模型 (fzf)"
    echo "  ocm status       查看 Gateway 状态"
    echo "  ocm restart      重启 Gateway"
    echo "  ocm help         显示帮助"
    exit 0
    ;;
  "") ;;
  *) err "未知命令: $1 (运行 ocm help)"; exit 1 ;;
esac

main_menu

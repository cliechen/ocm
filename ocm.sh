#!/usr/bin/env bash
# ============================================================
#  ocm — OpenClaw Model Manager v2.1
#  交互式管理 API 供应商 / 模型 / 默认模型
#  依赖: jq, gum, fzf, python3, curl
#  用法: ocm [ls|switch|status|restart|sync|test|help]
# ============================================================
#  v2.1.2 (2026-04-02):
#   ✦ ESC: 主菜单刷新，分菜单返回上一级（不再直接退出）
#   ✦ 修复: 编辑模型 ESC 卡死（添加 prompt_continue）
#   ✦ 修复: 模型价格 emoji 双重编码乱码
#   ✦ 新增: 测试供应商连接 (URL + Key 验证)
#   ✦ 新增: 测试模型可用性 (发送真实聊天请求)
#   ✦ 新增: Gateway 运行时实际使用模型
#   ✦ 新增: 批量测试所有供应商
# ============================================================
set -euo pipefail

VERSION="2.1.2"
CONFIG="$HOME/.openclaw/openclaw.json"
BACKUP="$HOME/.openclaw/openclaw.json.bak"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOBBERED_DIR="$HOME/.openclaw/backups/ocm-clobbered"
mkdir -p "$CLOBBERED_DIR"

# ---------- 颜色 ----------
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; GRAY='\033[0;90m'; NC='\033[0m'

# ---------- 依赖 ----------
for cmd in jq gum fzf python3 curl; do
  command -v "$cmd" &>/dev/null || { echo -e "${RED}缺少依赖: $cmd${NC}"; exit 1; }
done

# ---------- 核心工具函数 ----------
info() { gum style --foreground 46 "✓ $*"; }
warn() { gum style --foreground 214 "⚠ $*"; }
fail_msg() { gum style --foreground 196 "✗ $*"; }

backup() {
  cp "$CONFIG" "$BACKUP"
  gum style --foreground 240 "  ✓ 已备份 → $BACKUP"
}

backup_clobbered() {
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  cp "$CONFIG" "$CLOBBERED_DIR/openclaw-pre-${ts}.json"
}

prompt_continue() { gum input --placeholder "按回车继续" > /dev/null 2>&1 || true; }

# ---------- JSON 快捷操作 ----------
j() { jq -r "$1" "$CONFIG" 2>/dev/null; }
providers_list() { j '.models.providers | keys[]'; }
provider_url()   { j ".models.providers.\"$1\".baseUrl // \"-\""; }
provider_key()   { local k; k=$(j ".models.providers.\"$1\".apiKey // \"\""); echo "${k:0:8}****"; }
provider_models() { j ".models.providers.\"$1\".models[].id" 2>/dev/null || true; }
model_count()    { provider_models "$1" | grep -c . 2>/dev/null || echo 0; }

# ---------- 模型读取（本地，秒开） ----------
list_models_for_fzf() {
  python3 -c "
import json, os, sys
config = os.environ['OCM_CONFIG']
with open(config) as f: obj = json.load(f)
p = (obj.get('models') or {}).get('providers') or {}
a = obj.get('agents') or {}
pr = ((a.get('defaults') or {}).get('model') or {}).get('primary', '')
seen = set()
for pn in sorted(p.keys()):
    pd = p[pn]
    if not isinstance(pd, dict): continue
    for m in (pd.get('models') or []):
        if isinstance(m, dict) and m.get('id'):
            full = pn + '/' + m['id']
            if full in seen: continue
            seen.add(full)
            tag = '  ★ 已设为默认' if full == pr else ''
            cap = ''
            cost = m.get('cost', {})
            if isinstance(cost, dict):
                ci, co = cost.get('input', 0), cost.get('output', 0)
                if ci == 0 and co == 0: cap += ' [FREE]'
                elif ci or co: cap += ' \$%.2f入' % ci
            ctx = m.get('contextWindow', 0)
            if isinstance(ctx, (int, float)) and ctx >= 100000:
                cap += ' %dM' % (int(ctx) // 1000000)
            print(full + cap + tag)
for mid in sorted((a.get('models') or {}).keys()):
    if mid not in seen: print(mid)
" 2>/dev/null
}

get_current_model() { python3 -c "
import json, os
config = os.environ['OCM_CONFIG']
with open(config) as f: obj = json.load(f)
a = obj.get('agents', {})
print(((a.get('defaults') or {}).get('model') or {}).get('primary', ''))
" 2>/dev/null; }

runtime_model() { python3 -c "
import json, sys
try:
    with open(os.environ['OCM_CONFIG']) as f: obj = json.load(f)
    a = obj.get('agents', {})
    r = ((a.get('runtime') or {}).get('model') or {}).get('id', '')
    print(r)
except: pass
" 2>/dev/null || true; }

export OCM_CONFIG="$CONFIG"

# ---------- 状态显示 ----------
show_status() {
  local dm rm
  dm=$(get_current_model)
  rm=$(runtime_model)
  echo -e "  ${CYAN}配置默认: ${GREEN}${dm:-未设置}${NC}"
  [ -n "$rm" ] && echo -e "  ${CYAN}Gateway 运行时: ${YELLOW}${rm}${NC}"
}

# ============================================================
#  测试供应商连接
# ============================================================
test_provider() {
  local pname="$1"
  local url api_key
  url=$(provider_url "$pname"); api_key=$(j ".models.providers.\"$pname\".apiKey // \"\"")
  [ -z "$api_key" -o "$url" = "-" ] && { warn "$pname: URL/Key 缺失"; return 1; }

  local resp hc elapsed
  elapsed=$(date +%s%3N)
  resp=$(curl -s -w "\n%{http_code}" --max-time 10 \
    -H "Authorization: Bearer $api_key" "${url}/models" 2>/dev/null || echo -e "\n000")
  elapsed=$(( $(date +%s%3N) - elapsed ))
  hc=$(echo "$resp" | tail -1)

  if [ "$hc" = "000" ]; then
    warn "$pname: 网络错误/超时"; return 1
  fi
  local mc=0
  if [ "$hc" = "200" ]; then
    mc=$(echo "$resp" | head -n-1 | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    ms = d.get('data', d) if isinstance(d, dict) else d
    print(len(ms))
except: print(0)
" 2>/dev/null || echo 0)
  fi

  case "$hc" in
    200) printf '  \033[0;32m  ✓ %s: 连接成功! %sms, %s 个模型\033[0m\n' "$pname" "$elapsed" "$mc"; return 0 ;;
    401|403) printf '  \033[0;31m  ✗ %s: 认证失败 HTTP %s (Key 可能过期)\033[0m\ n' "$pname" "$hc"; return 1 ;;
    404) printf '  \033[1;33m  ⚠  %s: /models 端点不存在 HTTP %s\033[0m\n' "$pname" "$hc"; return 1 ;;
    *) printf '  \033[1;33m  ⚠  %s: HTTP %s (%sms)\033[0m\n' "$pname" "$hc" "$elapsed"; return 1 ;;
  esac
}

test_model_chat() {
  local pname="$1" mid="$2"
  local url api_key
  url=$(provider_url "$pname"); api_key=$(j ".models.providers.\"$pname\".apiKey // \"\"")
  [ -z "$api_key" -o "$url" = "-" ] && { warn "$pname: URL/Key 缺失"; return 1; }

  local resp hc elapsed
  elapsed=$(date +%s%3N)
  resp=$(curl -s -w "\n%{http_code}" --max-time 15 \
    -H "Authorization: Bearer $api_key" -H "Content-Type: application/json" \
    -d "{\"model\":\"$mid\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":1}" \
    "${url}/chat/completions" 2>/dev/null || echo -e "\n000")
  elapsed=$(( $(date +%s%3N) - elapsed ))
  hc=$(echo "$resp" | tail -1)

  case "$hc" in
    200) printf '  \033[0;32m  ✓ %s: 可用! %sms\033[0m\n' "$mid" "$elapsed"; return 0 ;;
    401|403) printf '  \033[0;31m  ✗ %s: 认证失败 HTTP %s\033[0m\n' "$mid" "$hc"; return 1 ;;
    429) printf '  \033[1;33m  ⚠  %s: 速率限制 HTTP %s\033[0m\n' "$mid" "$hc"; return 0 ;;
    *) printf '  \033[1;33m  ⚠  %s: HTTP %s (%sms)\033[0m\n' "$mid" "$hc" "$elapsed"; return 1 ;;
  esac
}

test_all_providers() {
  local p=()
  while IFS= read -r p; do [ -n "$p" ] && p+=("$p"); done < <(providers_list)
  [ ${#p[@]} -eq 0 ] && { warn "没有供应商"; return; }

  gum style --bold --foreground 51 "━━ 批量测试连接 ━━"
  echo ""
  for pn in "${p[@]}"; do
    test_provider "$pn" || true
  done
}

# ============================================================
#  快速切换模型（fzf）
# ============================================================
cmd_switch() {
  local all_models
  all_models=$(list_models_for_fzf)
  [ -z "$all_models" ] && { fail_msg "没有可用模型"; return 1; }

  local selected
  selected=$(echo "$all_models" | fzf \
    --prompt="  ❯ " \
    --header="选择默认模型 · ESC 取消" \
    --height=20 --layout=reverse --border=rounded \
    --color=border:51,label:51,header:51,prompt:201,pointer:46,marker:208,hl:208,hl+:208) || return
  [ -z "$selected" ] && return
  selected="${selected%% *}"

  backup
  jq --arg m "$selected" '.agents.defaults.model.primary=$m' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "已切换: $selected"
}

# ============================================================
#  同步云端模型
# ============================================================
cmd_sync() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有供应商"; return; }

  gum style --bold --foreground 51 "━━ 同步云端模型 ━━"
  echo ""

  local items=("同步全部" "返回")
  for p in "${providers[@]}"; do
    items+=("$(printf '%-15s %-30s %s模型' "$p" "$(provider_url "$p")" "$(model_count "$p")")")
  done

  local choice
  choice=$(gum choose --cursor "❯ " --header "选择要同步的供应商 · ESC 返回" "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  if [[ "$choice" == "同步全部" ]]; then
    for p in "${providers[@]}"; do
      _sync_one "$p"
    done
  else
    _sync_one "$choice"
  fi
}

_sync_one() {
  local pname="$1"
  local url api_key
  url=$(provider_url "$pname")
  api_key=$(j ".models.providers.\"$pname\".apiKey // \"\"")

  if [ -z "$api_key" ] || [ "$url" = "-" ]; then
    warn "$pname: URL 或 Key 缺失，跳过"
    return
  fi

  echo -e "  ${GRAY}同步 $pname ($url)...${NC}"

  local models_json
  models_json=$(curl -s -m 10 -H "Authorization: Bearer $api_key" "${url}/models" 2>/dev/null || true)

  if [ -z "$models_json" ]; then
    warn "$pname: 无法获取模型列表"
    return
  fi

  local model_count
  model_count=$(echo "$models_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', data) if isinstance(data, dict) else data
    ids = [m['id'] for m in models if isinstance(m, dict) and 'id' in m]
    print(len(ids))
except: print(0)
" 2>/dev/null || echo 0)

  if [ "$model_count" -eq 0 ]; then
    warn "$pname: 无模型"
    return
  fi

  backup
  echo "$models_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = data.get('data', data) if isinstance(data, dict) else data
result = []
for m in models:
    if isinstance(m, dict) and 'id' in m:
        result.append({
            'id': m['id'],
            'name': m.get('id'),
            'input': ['text'],
            'contextWindow': m.get('context_length', 128000),
            'maxTokens': 4096
        })
result.sort(key=lambda x: x['id'])
print(json.dumps(result))
" | jq --arg p "$pname" \
  '. as $models | input | .models.providers[$p].models = $models' \
  "$CONFIG" > "${CONFIG}.tmp" 2>/dev/null && mv "${CONFIG}.tmp" "$CONFIG"

  info "$pname: 已同步 $model_count 个模型"
  echo ""; test_provider "$pname" || true
}

# ============================================================
#  添加供应商
# ============================================================
add_provider() {
  echo ""
  gum style --bold --foreground 51 "━━ 添加供应商 ━━"
  echo ""

  local pname base_url api_key api_type
  pname=$(gum input --placeholder "供应商名称 (如: openai)" --prompt "供应商 > ") || { warn "已取消"; return; }
  [ -z "$pname" ] && { warn "名称不能为空"; return; }

  if jq -e ".models.providers.\"$pname\"" "$CONFIG" &>/dev/null; then
    gum confirm "供应商 '$pname' 已存在，覆盖?" || return
  fi

  base_url=$(gum input --placeholder "https://api.xxx.com/v1" --prompt "地址 > ") || { warn "已取消"; return; }
  [ -z "$base_url" ] && return
  base_url="${base_url%/}"

  api_key=$(gum input --password --placeholder "sk-xxx" --prompt "密钥 > ") || { warn "已取消"; return; }
  [ -z "$api_key" ] && return

  api_type=$(gum input --placeholder "openai-completions" --prompt "API 类型 > ")
  api_type="${api_type:-openai-completions}"

  # 自动获取模型
  local models_json model_count=0
  models_json=$(curl -s -m 10 -H "Authorization: Bearer $api_key" "${base_url}/models" 2>/dev/null || true)

  local models_arr="[]"
  if [ -n "$models_json" ]; then
    model_count=$(echo "$models_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', data) if isinstance(data, dict) else data
    ids = sorted(set(m['id'] for m in models if isinstance(m, dict) and 'id' in m))
    print(len(ids))
except: print(0)
" 2>/dev/null || echo 0)

    if [ "$model_count" -gt 0 ]; then
      models_arr=$(echo "$models_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = data.get('data', data) if isinstance(data, dict) else data
result = []
for m in models:
    if isinstance(m, dict) and 'id' in m:
        result.append({'id': m['id'], 'name': m.get('id'), 'input': ['text'], 'contextWindow': 128000, 'maxTokens': 4096})
result.sort(key=lambda x: x['id'])
print(json.dumps(result))
" 2>/dev/null || echo "[]")
    fi
  fi

  # fzf 选默认模型
  local default_model_id=""
  if [ "$model_count" -gt 1 ]; then
    echo ""
    gum style --foreground 240 "选择默认模型（可跳过）"
    local model_ids
    model_ids=$(echo "$models_arr" | python3 -c "
import sys, json
models = json.loads(sys.stdin)
print('\n'.join(m['id'] for m in models))
" 2>/dev/null || echo "")
    if [ -n "$model_ids" ]; then
      local default_sel
      default_sel=$(echo "$model_ids" | fzf \
        --prompt="  ❯ " \
        --header="选择默认模型 · ESC 跳过" \
        --height=15 --layout=reverse --border=rounded \
        --color=border:51,label:51,prompt:201,pointer:46,marker:208) || true
      [ -n "$default_sel" ] && default_model_id="$default_sel"
    fi
  fi

  echo ""
  gum style --bold --foreground 240 "━━ 确认信息 ━━"
  echo -e "  ${CYAN}供应商: ${GREEN}$pname${NC}"
  echo -e "  ${CYAN}地址: ${GREEN}$base_url${NC}"
  echo -e "  ${CYAN}密钥: ${GREEN}${api_key:0:8}****${NC}"
  echo -e "  ${CYAN}模型: ${GREEN}${model_count} 个${NC}"
  [ -n "$default_model_id" ] && echo -e "  ${CYAN}默认模型: ${GREEN}$default_model_id${NC}"
  echo ""

  gum confirm "确认添加?" || { echo "已取消"; return; }

  backup

  # 添加供应商
  local provider_obj
  provider_obj=$(jq -n --arg bt "$api_type" --arg bu "$base_url" --arg key "$api_key" \
    '{baseUrl:$bu, apiKey:$key, api:$bt}')

  # 如果自动获取了模型
  if [ "$model_count" -gt 0 ] && [ "$models_arr" != "[]" ]; then
    local provider_with_models
    provider_with_models=$(echo "$provider_obj" | jq --argjson mc "$models_arr" '. + {models: $mc}')
    jq --arg p "$pname" --argjson pr "$provider_with_models" \
      '.models.providers[$p] = $pr' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  else
    jq --arg p "$pname" --argjson pr "$provider_obj" \
      '.models.providers[$p] = $pr' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  fi

  # 设置默认模型
  if [ -n "$default_model_id" ]; then
    local full_id="$pname/$default_model_id"
    jq --arg m "$full_id" '.agents.defaults.model.primary=$m' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
    info "供应商 $pname 已添加 (默认模型: $full_id)"
  else
    info "供应商 $pname 已添加 ($model_count 个模型)"
  fi

  echo ""; test_provider "$pname" || true
}

# ============================================================
#  供应商管理
# ============================================================
delete_provider() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有供应商"; return; }

  local items=()
  for p in "${providers[@]}"; do
    items+=("$(printf '%-15s %-30s %s模型' "$p" "$(provider_url "$p")" "$(model_count "$p")")")
  done
  items+=("返回")

  local choice
  choice=$(gum choose --cursor "❯ " --header "选择要删除的供应商 · ESC 返回" "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local pname; pname=$(echo "$choice" | awk '{print $1}')
  gum confirm "⚠ 删除 '$pname' 及所有模型?" || return

  backup
  jq "del(.models.providers.\"$pname\")" "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "已删除: $pname"
}

edit_provider() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有供应商"; return; }

  local items=("返回")
  for p in "${providers[@]}"; do
    items+=("$(printf '%-15s %-30s %s模型' "$p" "$(provider_url "$p")" "$(model_count "$p")")")
  done

  local choice
  choice=$(gum choose --cursor "❯ " --header "选择供应商 · ESC 返回" "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local pname; pname=$(echo "$choice" | awk '{print $1}')
  _edit_submenu "$pname"
}

_edit_submenu() {
  local pn="$1"
  while true; do
    local a; a=$(gum choose --cursor "❯ " --header "编辑 $pn" \
      "🔗 测试连接 (Models API)" \
      "💬 测试聊天 (Chat Completions)" \
      "✏️  修改地址" \
      "🔑 修改密钥" \
      "🔄 同步模型" \
      "返回") || return
    case "$a" in
      "🔗 测试连接 (Models API)")
        echo ""; test_provider "$pn"; prompt_continue ;;
      "💬 测试聊天 (Chat Completions)")
        echo ""; local ml=(); while IFS= read -r m; do [ -n "$m" ] && ml+=("$m"); done < <(provider_models "$pn")
        if [ ${#ml[@]} -eq 0 ]; then warn "无模型，先同步?"; prompt_continue; continue; fi
        local s; s=$(printf '%s\n' "${ml[@]}" | fzf --prompt="  ❯ " --header="选择模型 · ESC 取消" \
          --height=15 --layout=reverse --border=rounded --color=border:51,label:51,prompt:201,pointer:46) || continue
        [ -z "$s" ] && continue; test_model_chat "$pn" "$s"; prompt_continue ;;
      "✏️  修改地址")
        local o n; o=$(provider_url "$pn")
        n=$(gum input --value "$o" --prompt "URL > ") || { warn "已取消"; prompt_continue; continue; }
        if [ -z "$n" ]; then warn "地址不能为空"; prompt_continue; continue; fi
        n="${n%/}"; backup
        jq --arg p "$pn" --arg u "$n" '.models.providers[$p].baseUrl=$u' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        info "地址已更新: $n"
        echo ""; test_provider "$pn" || true
        prompt_continue ;;
      "🔑 修改密钥")
        local n; n=$(gum input --password --prompt "密钥 > ") || { warn "已取消"; prompt_continue; continue; }
        if [ -z "$n" ]; then warn "密钥不能为空"; prompt_continue; continue; fi
        backup
        jq --arg p "$pn" --arg k "$n" '.models.providers[$p].apiKey=$k' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        info "密钥已更新"
        echo ""; test_provider "$pn" || true
        prompt_continue ;;
      "🔄 同步模型")
        echo ""; _sync_one "$pn"; prompt_continue ;;
      "返回"|*) return ;;
    esac
  done
}

provider_menu() {
  while true; do
    clear
    gum style --bold --foreground 51 "━━ 供应商管理 ━━"
    echo ""
    show_status
    echo ""

    local action
    action=$(gum choose --cursor "❯ " --header "↑↓ 移动 · Enter 确认 · ESC 返回上级" \
      "添加供应商" "编辑供应商" "删除供应商" "返回主菜单") || return

    case "$action" in
      "添加供应商") add_provider; prompt_continue ;;
      "编辑供应商") edit_provider; prompt_continue ;;
      "删除供应商") delete_provider; prompt_continue ;;
      "返回主菜单"|*) return ;;
    esac
  done
}

# ============================================================
#  模型管理
# ============================================================
_add_model() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有供应商"; return; }

  local items=()
  for p in "${providers[@]}"; do
    items+=("$(printf '%-15s %-30s %s模型' "$p" "$(provider_url "$p")" "$(model_count "$p")")")
  done
  items+=("返回")

  local choice
  choice=$(gum choose --cursor "❯ " --header "选择供应商 · ESC 返回" "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local pname; pname=$(echo "$choice" | awk '{print $1}')
  local mid; mid=$(gum input --placeholder "模型 ID (如: gpt-4)" --prompt "模型 ID > ") || return
  [ -z "$mid" ] && { warn "ID 不能为空"; return; }

  # 检查是否已存在
  local existing
  existing=$(j ".models.providers[\"$pname\"].models[] | select(.id == \"$mid\") | .id" 2>/dev/null || true)
  [ -n "$existing" ] && { warn "$mid 已存在于 $pname 中"; prompt_continue; return; }

  backup
  jq --arg p "$pname" --arg m "$mid" '.models.providers[$p].models += [{"id":$m,"name":$m,"input":["text"],"contextWindow":128000,"maxTokens":4096}]' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "已添加 $mid 到 $pname"
}

_delete_model() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有供应商"; return; }

  local items=()
  for p in "${providers[@]}"; do
    items+=("$p ($(model_count "$p")模型)")
  done
  items+=("返回")

  local choice
  choice=$(gum choose --cursor "❯ " --header "选择供应商 · ESC 返回" "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local prov; prov=$(echo "$choice" | awk '{print $1}')
  local models=()
  while IFS= read -r m; do [ -n "$m" ] && models+=("$m"); done < <(provider_models "$prov")
  [ ${#models[@]} -eq 0 ] && { warn "没有模型"; return; }

  local mitems=()
  for m in "${models[@]}"; do
    mitems+=("$(printf '%-40s' "$m")")
  done
  mitems+=("返回")

  local mid
  mid=$(gum choose --cursor "❯ " --header "选择要删除的模型 · ESC 返回" "${mitems[@]}") || return
  [[ "$mid" == "返回" ]] && return
  mid=$(echo "$mid" | xargs)

  gum confirm "⚠ 删除 $prov/$mid?" || return
  backup
  jq --arg p "$prov" --arg m "$mid" '.models.providers[$p].models = [.models.providers[$p].models[] | select(.id != $m)]' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "已删除: $prov/$mid"
}

# ============================================================
#  Fallback 管理
# ============================================================
_manage_fallback() {
  while true; do
    clear
    gum style --bold --foreground 51 "━━ Fallback 管理 ━━"
    echo ""
    show_status
    echo ""

    local fb_count=0
    has=$(j ".agents.defaults.model.fallbacks // [] | length" 2>/dev/null || echo 0)
    [ "$has" -gt 0 ] && fb_count=$has

    if [ "$fb_count" -gt 0 ]; then
      echo -e "  ${CYAN}当前已配置 ${fb_count} 个 Fallback:${NC}"
      echo ""
      for i in $(seq 0 $((fb_count - 1))); do
        local fb; fb=$(j ".agents.defaults.model.fallbacks[$i]" 2>/dev/null || true)
        [ -n "$fb" ] && [ "$fb" != "null" ] && echo -e "  ${GREEN}→ $fb${NC}"
      done
      echo ""
    else
      echo -e "  ${GRAY}(无 Fallback 配置)${NC}"
      echo ""
    fi

    local action
    action=$(gum choose --cursor "❯ " --header "Fallback 管理 · ESC 返回" \
      "添加" "移除" "清空" "返回主菜单") || return

    case "$action" in
      "添加")
        local all_models
        all_models=$(list_models_for_fzf)
        [ -z "$all_models" ] && { warn "没有模型"; prompt_continue; continue; }
        local sel
        sel=$(echo "$all_models" | fzf \
          --prompt="  ❯ " \
          --header="选择 Fallback 模型" \
          --height=15 --layout=reverse --border=rounded \
          --color=border:51,label:51,prompt:201,pointer:46,marker:208) || continue
        [ -z "$sel" ] && continue
        sel="${sel%% *}"
        backup
        jq --arg m "$sel" '.agents.defaults.model.fallbacks = ((.agents.defaults.model.fallbacks // []) + [$m] | unique)' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        info "已添加 Fallback: $sel"; prompt_continue ;;
      "移除")
        local mitems=()
        for fb in $(j ".agents.defaults.model.fallbacks[]" 2>/dev/null || true); do
          mitems+=("$fb")
        done
        [ ${#mitems[@]} -eq 0 ] && { warn "没有 Fallback"; prompt_continue; continue; }
        mitems+=("返回")
        local sel
        sel=$(gum choose --cursor "❯ " --header="选择要移除的 Fallback · ESC 返回" "${mitems[@]}") || continue
        [[ "$sel" == "返回" ]] && continue
        [ -z "$sel" ] && continue
        backup
        jq --arg m "$sel" '.agents.defaults.model.fallbacks = [.agents.defaults.model.fallbacks[] | select(. != $m)]' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        info "已移除 Fallback: $sel"; prompt_continue ;;
      "清空")
        gum confirm "清空所有 Fallback?" || continue
        backup
        jq '.agents.defaults.model.fallbacks = []' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        info "已清空所有 Fallback"; prompt_continue ;;
      "返回主菜单"|"返回") return ;;
      *"返回"*) return ;;
      *) return ;;
    esac
  done
}

# ============================================================
#  manage_models() 子菜单
# ============================================================
manage_models() {
  while true; do
    clear
    gum style --bold --foreground 51 "━━ 模型管理 ━━"
    echo ""
    show_status
    echo ""

    local action
    action=$(gum choose --cursor "❯ " --header "↑↓ 移动 · Enter 确认 · ESC 返回上级" \
      "快速切换 (fzf)" \
      "添加模型" \
      "删除模型" \
      "管理 Fallback" \
      "💬 测试模型可用" \
      "返回主菜单") || return

    case "$action" in
      "快速切换 (fzf)")  cmd_switch; prompt_continue ;;
      "添加模型")        _add_model; prompt_continue ;;
      "删除模型")        _delete_model; prompt_continue ;;
      "管理 Fallback")   _manage_fallback ;;
      "💬 测试模型可用")
        local tp=(); while IFS= read -r p; do [ -n "$p" ] && tp+=("$p"); done < <(providers_list)
        if [ ${#tp[@]} -eq 0 ]; then warn "无供应商"; prompt_continue; continue; fi
        local tv; tv=$(gum choose --cursor "❯ " --header="选择供应商 · ESC 返回" "${tp[@]}") || { prompt_continue; continue; }
        local tm=(); while IFS= read -r m; do [ -n "$m" ] && tm+=("$m"); done < <(provider_models "$tv")
        if [ ${#tm[@]} -eq 0 ]; then warn "$tv 无模型"; prompt_continue; continue; fi
        echo ""; for m in "${tm[@]}"; do test_model_chat "$tv" "$m" || true; done
        prompt_continue ;;
      "返回主菜单"|*) return ;;
    esac
  done
}

================
#  主菜单
============================================================
main_menu() {
  while true; do
    clear
    local dm pc mc
    dm=$(get_current_model)
    pc=$(providers_list | grep -c . 2>/dev/null || echo 0)
    mc=$(list_models_for_fzf | grep -c . 2>/dev/null || echo 0)

    echo ""
    gum style --bold --foreground 51 --border double --border-foreground 51 --padding "0 3" \
      "OpenClaw Model Manager v$VERSION"
    echo ""

    # 状态卡片
    gum style --border rounded --border-foreground 240 --padding "0 2" \
      "默认模型  : $dm" \
      "供应商    : $pc" \
      "模型总数  : $mc"

    local action
    action=$(gum choose --cursor "❯ " --header "↑↓ 移动 · Enter 确认 · ESC 刷新" \
      "🎯  快速切换模型" \
      "📡  供应商管理" \
      "📦  模型管理" \
      "🔄  同步云端模型" \
      "🔗  测试连接" \
      "🔃  重启网关" \
      "📊  查看状态" \
      "⏪  还原备份" \
      "🚪  退出") || continue

    case "$action" in
      *"快速切换"*)   cmd_switch; prompt_continue ;;
      *"供应商管理"*) provider_menu ;;
      *"模型管理"*)   manage_models ;;
      *"同步云端"*)   cmd_sync; prompt_continue ;;
      *"测试连接"*)  test_all_providers; prompt_continue ;;
      *"重启"*)
        gum spin --spinner minidot --title "正在重启..." -- openclaw gateway restart 2>/dev/null && info "网关已重启" || fail_msg "重启失败"
        prompt_continue ;;
      *"查看状态"*)
        echo ""
        openclaw gateway status 2>/dev/null || openclaw status 2>/dev/null || warn "状态查询失败"
        prompt_continue ;;
      *"还原备份"*)
        if [ -f "$BACKUP" ]; then
          backup_clobbered
          gum confirm "从备份还原? (当前配置已自动保存为 clobbered)" && {
            cp "$BACKUP" "$CONFIG"; info "已还原"; }
        else
          warn "无备份"
        fi
        prompt_continue ;;
      *"退出"|*) exit 0 ;;
    esac
  done
}

# ============================================================
#  入口
# ============================================================
[ -f "$CONFIG" ] || { fail_msg "配置不存在: $CONFIG"; exit 1; }

case "${1:-}" in
  ls|list)      list_models_for_fzf; exit ;;
  switch|sw)    cmd_switch; exit ;;
  sync)         cmd_sync; exit ;;
  test|check)   test_all_providers; exit ;;
  status|st)    openclaw gateway status 2>/dev/null || openclaw status; exit ;;
  restart|rs)   openclaw gateway restart; exit ;;
  help|-h|--help)
    gum style --bold "ocm v$VERSION — OpenClaw Model Manager"
    echo ""
    echo "  ocm              交互式菜单"
    echo "  ocm ls           列出所有模型"
    echo "  ocm switch       快速切换 (fzf)"
    echo "  ocm sync         同步云端模型"
    echo "  ocm test         测试供应商连接"
    echo "  ocm status       网关状态"
    echo "  ocm restart      重启网关"
    exit 0 ;;
  "") ;;
  *) fail_msg "未知: $1 (ocm help)"; exit 1 ;;
esac

main_menu
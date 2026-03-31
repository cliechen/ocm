#!/usr/bin/env bash
# ============================================================
#  ocm — OpenClaw Model Manager v2.0
#  交互式管理 API 供应商 / 模型 / 默认模型
#  依赖: jq, gum, fzf, python3
#  用法: ocm [ls|switch|status|restart|sync|help]
# ============================================================
set -euo pipefail

VERSION="2.0.0"
CONFIG="$HOME/.openclaw/openclaw.json"
BACKUP="$HOME/.openclaw/openclaw.json.bak"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 颜色 ----------
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; GRAY='\033[0;90m'; NC='\033[0m'

# ---------- 依赖 ----------
for cmd in jq gum fzf python3; do
  command -v "$cmd" &>/dev/null || { echo -e "${RED}缺少依赖: $cmd${NC}"; exit 1; }
done

# ---------- 核心工具函数 ----------
info() { gum style --foreground 46 "✓ $*"; }
warn() { gum style --foreground 214 "⚠ $*"; }
fail() { gum style --foreground 196 "✗ $*"; }

backup() {
  cp "$CONFIG" "$BACKUP"
  gum style --foreground 240 "  已备份 → $BACKUP"
}

prompt_continue() { gum input --placeholder "按回车继续" > /dev/null 2>&1 || true; }

# ---------- JSON 快捷操作 ----------
j() { jq -r "$1" "$CONFIG" 2>/dev/null; }
providers_list() { j '.models.providers | keys[]'; }
provider_url()   { j ".models.providers.\"$1\".baseUrl // \"-\""; }
provider_api()   { j ".models.providers.\"$1\".api // \"openai-completions\""; }
provider_key()   { local k; k=$(j ".models.providers.\"$1\".apiKey // \"\""); echo "${k:0:8}****"; }
provider_models() { j ".models.providers.\"$1\".models[]?.id // empty"; }
default_model()  { j '.agents.defaults.model.primary // "(未设置)"'; }
fallback_list()  { j '(.agents.defaults.model.fallbacks // [])[]'; }
model_count()    { provider_models "$1" | grep -c . 2>/dev/null || echo 0; }

# ---------- 模型读取（本地，秒开） ----------
list_all_models() {
  python3 -c "
import json, sys
try:
    with open('$CONFIG') as f: obj = json.load(f)
    p = (obj.get('models') or {}).get('providers') or {}
    a = obj.get('agents') or {}
    pr = ((a.get('defaults') or {}).get('model') or {}).get('primary', '')
    ms = set()
    for pn, pd in p.items():
        if not isinstance(pd, dict): continue
        for m in (pd.get('models') or []):
            if isinstance(m, dict) and m.get('id'):
                ms.add(pn + '/' + m['id'])
    for mid in (a.get('models') or {}): ms.add(mid)
    for m in sorted(ms):
        tag = '  * DEFAULT' if m == pr else ''
        print(m + tag)
except: pass
" 2>/dev/null
}

get_current_model() {
  list_all_models | grep "DEFAULT" | sed 's/  \* DEFAULT//' | head -1
}

# ---------- 状态摘要 ----------
show_status() {
  local dm pc fc
  dm=$(default_model)
  pc=$(providers_list | grep -c . 2>/dev/null || echo 0)
  fc=$(fallback_list | grep -c . 2>/dev/null || echo 0)

  gum style --foreground 240 "  默认: $dm  |  供应商: $pc  |  Fallback: $fc"
}

# ============================================================
#  快速切换模型（fzf）
# ============================================================
cmd_switch() {
  local all_models
  all_models=$(list_all_models)
  [ -z "$all_models" ] && { fail "没有可用模型"; return 1; }

  local current
  current=$(echo "$all_models" | grep "DEFAULT" | sed 's/  \* DEFAULT//' | head -1)

  local selected
  selected=$(echo "$all_models" | fzf \
    --prompt="  ❯ " \
    --header="  当前: $current  │  ↑↓/搜索  Enter 确认  Esc 取消" \
    --header-first \
    --height=20 --layout=reverse --border=rounded \
    --border-label=" ◈ 切换默认模型 " \
    --color=border:51,label:51,header:51,prompt:201,pointer:46,marker:208,hl:208,hl+:208) || return

  [ -z "$selected" ] && return
  selected=$(echo "$selected" | sed 's/  \* DEFAULT//' | awk '{print $1}')

  jq --arg m "$selected" '.agents.defaults.model.primary = $m' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "已切换为: $selected"

  gum confirm "重启 Gateway 生效?" && {
    gum spin --spinner minidot --title "重启中..." -- openclaw gateway restart 2>/dev/null
    info "Gateway 已重启"
  }
}

# ============================================================
#  同步云端模型
# ============================================================
cmd_sync() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有 Provider"; return; }

  echo ""
  gum style --bold --foreground 51 "━━ 同步云端模型 ━━"
  echo ""

  local items=("同步全部" "返回")
  items+=("${providers[@]}")

  local choice
  choice=$(gum choose --cursor "❯ " --header "选择要同步的 Provider\n↑↓ 移动 · Enter 确认 · q 退出" "${items[@]}") || return
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
}

# ============================================================
#  添加 Provider
# ============================================================
add_provider() {
  echo ""
  gum style --bold --foreground 51 "━━ 添加 API 供应商 ━━"
  echo ""

  local pname base_url api_key api_type
  pname=$(gum input --placeholder "Provider 名称 (如: openai)" --prompt "Provider > ") || return
  [ -z "$pname" ] && { warn "名称不能为空"; return; }

  if jq -e ".models.providers.\"$pname\"" "$CONFIG" &>/dev/null; then
    gum confirm "Provider '$pname' 已存在，覆盖?" || return
  fi

  base_url=$(gum input --placeholder "https://api.xxx.com/v1" --prompt "Base URL > ") || return
  [ -z "$base_url" ] && return
  base_url="${base_url%/}"

  api_key=$(gum input --password --placeholder "sk-xxx" --prompt "API Key > ") || return
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
  local default_sel=""
  if [ "$model_count" -gt 0 ]; then
    local model_ids
    model_ids=$(echo "$models_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = data.get('data', data) if isinstance(data, dict) else data
for m in sorted(set(n['id'] for n in models if isinstance(n, dict) and 'id' in n)):
    print(m)
" 2>/dev/null)

    default_sel=$(echo "$model_ids" | fzf \
      --prompt="  ❯ " \
      --header="  发现 $model_count 个模型 · 选默认模型  │  Esc 跳过" \
      --header-first --height=15 --layout=reverse --border=rounded \
      --border-label=" ◈ DEFAULT MODEL " \
      --color=border:51,label:51,header:51,prompt:201,pointer:46,marker:208,hl:208,hl+:208) || true
  fi

  echo ""
  gum style --border normal --border-foreground 99 --padding "0 2" \
    "Provider : $pname" \
    "URL      : $base_url" \
    "Key      : ${api_key:0:8}****" \
    "API      : $api_type" \
    "模型     : $model_count" \
    "默认     : ${default_sel:-(未选)}"
  echo ""

  gum confirm "确认添加?" || { echo "已取消"; return; }

  backup
  jq --arg p "$pname" --arg url "$base_url" --arg key "$api_key" --arg api "$api_type" --argjson models "$models_arr" \
    '.models.providers[$p] = {baseUrl: $url, apiKey: $key, api: $api, models: $models}' \
    "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

  if [ -n "$default_sel" ]; then
    jq --arg m "${pname}/${default_sel}" '.agents.defaults.model.primary = $m' \
      "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  fi

  info "Provider '$pname' 已添加 ($model_count 个模型)"
}

# ============================================================
#  删除 Provider
# ============================================================
delete_provider() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有 Provider"; return; }

  local items=("返回")
  for p in "${providers[@]}"; do
    items+=("$(printf '%-15s %s 个模型' "$p" "$(model_count "$p")")")
  done

  local choice
  choice=$(gum choose --cursor "❯ " --header "选择要删除的 Provider\n↑↓ · Enter 确认 · q 退出" "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local pname; pname=$(echo "$choice" | awk '{print $1}')
  gum confirm "⚠ 删除 '$pname' 及所有模型?" || return

  backup
  jq "del(.models.providers.\"$pname\")" "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "已删除: $pname"
}

# ============================================================
#  编辑 Provider
# ============================================================
edit_provider() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有 Provider"; return; }

  local items=("返回")
  for p in "${providers[@]}"; do
    items+=("$(printf '%-15s %s' "$p" "$(provider_url "$p")")")
  done

  local choice
  choice=$(gum choose --cursor "❯ " --header "选择 Provider\n↑↓ · Enter · q 退出" "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local pname; pname=$(echo "$choice" | awk '{print $1}')

  local action
  action=$(gum choose --cursor "❯ " --header "编辑 $pname\n↑↓ · Enter · q 退出" \
    "修改 URL" "修改 API Key" "返回") || return

  case "$action" in
    "修改 URL")
      local old new
      old=$(provider_url "$pname")
      new=$(gum input --value "$old" --prompt "URL > ") || return
      [ -z "$new" ] && return
      new="${new%/}"
      backup
      jq --arg p "$pname" --arg url "$new" '.models.providers[$p].baseUrl = $url' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
      info "URL 已更新"
      ;;
    "修改 API Key")
      local new
      new=$(gum input --password --prompt "API Key > ") || return
      [ -z "$new" ] && return
      backup
      jq --arg p "$pname" --arg key "$new" '.models.providers[$p].apiKey = $key' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
      info "API Key 已更新"
      ;;
    "返回"|*) return ;;
  esac
}

# ============================================================
#  模型管理
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
      "返回主菜单") || return

    case "$action" in
      "快速切换 (fzf)")  cmd_switch; prompt_continue ;;
      "添加模型")        _add_model; prompt_continue ;;
      "删除模型")        _delete_model; prompt_continue ;;
      "管理 Fallback")   _manage_fallback ;;
      "返回主菜单"|*)    return ;;
    esac
  done
}

_add_model() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有 Provider"; return; }

  local items=("返回")
  items+=("${providers[@]}")
  local choice
  choice=$(gum choose --cursor "❯ " --header "选择 Provider" "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local mid mname
  mid=$(gum input --placeholder "模型 ID" --prompt "Model ID > ") || return
  [ -z "$mid" ] && return
  mname=$(gum input --placeholder "$mid" --prompt "名称 > ")
  mname="${mname:-$mid}"

  backup
  jq --arg p "$choice" --arg id "$mid" --arg name "$mname" \
    '.models.providers[$p].models += [{id: $id, name: $name, input: ["text"], contextWindow: 128000, maxTokens: 4096}]' \
    "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "已添加: $mid → $choice"
}

_delete_model() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有 Provider"; return; }

  local items=("返回")
  items+=("${providers[@]}")
  local prov
  prov=$(gum choose --cursor "❯ " --header "选择 Provider" "${items[@]}") || return
  [[ "$prov" == "返回" ]] && return

  local models=()
  while IFS= read -r m; do [ -n "$m" ] && models+=("$m"); done < <(provider_models "$prov")
  [ ${#models[@]} -eq 0 ] && { warn "无模型"; return; }

  local mitems=("返回")
  mitems+=("${models[@]}")
  local mid
  mid=$(gum choose --cursor "❯ " --header "选择要删除的模型" "${mitems[@]}") || return
  [[ "$mid" == "返回" ]] && return

  backup
  jq --arg p "$prov" --arg id "$mid" \
    '.models.providers[$p].models = [.models.providers[$p].models[] | select(.id != $id)]' \
    "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "已删除: $mid"
}

_manage_fallback() {
  local action
  action=$(gum choose --cursor "❯ " --header "Fallback 管理\n↑↓ · Enter · q 返回" \
    "查看" "添加" "移除" "清空" "返回") || return

  case "$action" in
    "查看")
      echo ""
      local has=false
      while IFS= read -r fb; do [ -z "$fb" ] && continue; has=true; echo "  → $fb"; done < <(fallback_list)
      $has || echo "  (空)"
      prompt_continue
      ;;
    "添加")
      local all_models
      all_models=$(list_all_models)
      [ -z "$all_models" ] && { warn "无模型"; return; }
      local sel
      sel=$(echo "$all_models" | fzf --prompt="  ❯ " --header="选 Fallback · Esc 取消" \
        --height=15 --layout=reverse --border=rounded --border-label=" ADD FALLBACK " \
        --color=border:51,label:51,prompt:201,pointer:46,marker:208) || return
      sel=$(echo "$sel" | sed 's/  \* DEFAULT//')
      backup
      jq --arg m "$sel" '.agents.defaults.model.fallbacks = ((.agents.defaults.model.fallbacks // []) + [$m] | unique)' \
        "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
      info "已添加: $sel"
      prompt_continue
      ;;
    "移除")
      local fbs=()
      while IFS= read -r fb; do [ -n "$fb" ] && fbs+=("$fb"); done < <(fallback_list)
      [ ${#fbs[@]} -eq 0 ] && { warn "无 Fallback"; return; }
      local mitems=("返回")
      mitems+=("${fbs[@]}")
      local sel
      sel=$(gum choose --cursor "❯ " --header "选择要移除的 Fallback" "${mitems[@]}") || return
      [[ "$sel" == "返回" ]] && return
      backup
      jq --arg m "$sel" '.agents.defaults.model.fallbacks = [(.agents.defaults.model.fallbacks // [])[] | select(. != $m)]' \
        "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
      info "已移除: $sel"
      prompt_continue
      ;;
    "清空")
      gum confirm "清空所有 Fallback?" || return
      backup
      jq '.agents.defaults.model.fallbacks = []' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
      info "已清空"
      prompt_continue
      ;;
    "返回"|*) return ;;
  esac
}

# ============================================================
#  API 供应商菜单
# ============================================================
provider_menu() {
  while true; do
    clear
    gum style --bold --foreground 51 "━━ API 供应商管理 ━━"
    echo ""

    # 快速总览
    local providers=()
    while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
    for p in "${providers[@]}"; do
      printf "  ${YELLOW}%-15s${NC} ${CYAN}%-35s${NC} %s 个模型\n" "$p" "$(provider_url "$p")" "$(model_count "$p")"
    done
    [ ${#providers[@]} -eq 0 ] && echo -e "  ${GRAY}(无 Provider)${NC}"
    echo ""

    local action
    action=$(gum choose --cursor "❯ " --header "↑↓ 移动 · Enter 确认 · ESC 返回上级" \
      "添加 Provider" \
      "编辑 Provider" \
      "删除 Provider" \
      "同步云端模型" \
      "返回主菜单") || return

    case "$action" in
      "添加 Provider")    add_provider; prompt_continue ;;
      "编辑 Provider")    edit_provider; prompt_continue ;;
      "删除 Provider")    delete_provider; prompt_continue ;;
      "同步云端模型")      cmd_sync; prompt_continue ;;
      "返回主菜单"|*)     return ;;
    esac
  done
}

# ============================================================
#  主菜单
# ============================================================
main_menu() {
  while true; do
    clear
    local dm pc mc
    dm=$(default_model)
    pc=$(providers_list | grep -c . 2>/dev/null || echo 0)
    mc=$(list_all_models | grep -c . 2>/dev/null || echo 0)

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
      "📡  API 供应商管理" \
      "📦  模型管理" \
      "🔄  同步云端模型" \
      "🔃  重启 Gateway" \
      "📊  查看状态" \
      "⏪  还原备份" \
      "🚪  退出") || continue

    case "$action" in
      *"快速切换"*)   cmd_switch; prompt_continue ;;
      *"供应商管理"*) provider_menu ;;
      *"模型管理"*)   manage_models ;;
      *"同步云端"*)   cmd_sync; prompt_continue ;;
      *"重启"*)
        gum spin --spinner minidot --title "重启中..." -- openclaw gateway restart 2>/dev/null && info "Gateway 已重启" || fail "重启失败"
        prompt_continue ;;
      *"查看状态"*)
        echo ""
        openclaw gateway status 2>/dev/null || openclaw status 2>/dev/null || warn "状态查询失败"
        prompt_continue ;;
      *"还原备份"*)
        if [ -f "$BACKUP" ]; then
          gum confirm "从备份还原?" && { cp "$BACKUP" "$CONFIG"; info "已还原"; }
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
[ -f "$CONFIG" ] || { fail "配置不存在: $CONFIG"; exit 1; }

case "${1:-}" in
  ls|list)      list_all_models; exit ;;
  switch|sw)    cmd_switch; exit ;;
  sync)         cmd_sync; exit ;;
  status|st)    openclaw gateway status 2>/dev/null || openclaw status; exit ;;
  restart|rs)   openclaw gateway restart; exit ;;
  help|-h|--help)
    gum style --bold "ocm v$VERSION — OpenClaw Model Manager"
    echo ""
    echo "  ocm              交互式菜单"
    echo "  ocm ls           列出所有模型"
    echo "  ocm switch       快速切换 (fzf)"
    echo "  ocm sync         同步云端模型"
    echo "  ocm status       Gateway 状态"
    echo "  ocm restart      重启 Gateway"
    exit 0 ;;
  "") ;;
  *) fail "未知: $1 (ocm help)"; exit 1 ;;
esac

main_menu

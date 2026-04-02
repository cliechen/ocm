#!/usr/bin/env bash
# ============================================================
#  ocm — OpenClaw Model Manager v2.1
#  交互式管理 API 供应商 / 模型 / 默认模型
#  依赖: jq, gum, fzf, python3, curl
#  用法: ocm [ls|switch|status|restart|sync|test|help]
# ============================================================
#  v2.1.1 (2026-04-02):
#   ✦ 新增: 测试供应商连接 (URL + Key 验证)
#   ✦ 新增: 测试模型可用性 (发送真实聊天请求)
#   ✦ 新增: 模型价格标签 (💰免费 / $0.15入)
#   ✦ 新增: Gateway 运行时实际使用模型
#   ✦ 新增: 批量测试所有供应商
#   ✦ 增强: 编辑 URL/Key 后自动验证
#   ✦ 增强: 同步/添加供应商自动验证
#   ✦ 增强: 还原备份保存 clobbered 存档
# ============================================================
set -euo pipefail

VERSION="2.1.1"
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
provider_api()   { j ".models.providers.\"$1\".api // \"openai-completions\""; }
provider_key()   { local k; k=$(j ".models.providers.\"$1\".apiKey // \"\""); echo "${k:0:8}****"; }
provider_models() { j ".models.providers.\"$1\".models[]?.id // empty"; }
default_model()  { j '.agents.defaults.model.primary // "(未设置)"'; }
fallback_list()  { j '(.agents.defaults.model.fallbacks // [])[]'; }
model_count()    { provider_models "$1" | grep -c . 2>/dev/null || echo 0; }

# ---------- 模型读取（本地，秒开） ----------
list_all_models() {
  python3 << 'PYEOF'
import json, os
config = os.environ.get("OCM_CONFIG", "")
try:
    with open(config) as f: obj = json.load(f)
    p = (obj.get("models") or {}).get("providers") or {}
    a = obj.get("agents") or {}
    pr = ((a.get("defaults") or {}).get("model") or {}).get("primary", "")
    for pn, pd in sorted(p.items()):
        if not isinstance(pd, dict): continue
        for m in (pd.get("models") or []):
            if isinstance(m, dict) and m.get("id"):
                full = pn + "/" + m["id"]
                tag = "  ★ 已设为默认" if full == pr else ""
                cap = ""
                cost = m.get("cost", {})
                if isinstance(cost, dict):
                    ci, co = cost.get("input", 0), cost.get("output", 0)
                    if ci == 0 and co == 0: cap += " 💰免费"
                    elif ci or co: cap += " $%.2f入" % ci
                ctx = m.get("contextWindow", 0)
                if isinstance(ctx, (int, float)) and ctx >= 100000:
                    cap += " %dM" % (int(ctx) // 1000000)
                print(full + cap + tag)
except: pass
PYEOF
}

export OCM_CONFIG="$CONFIG"

get_current_model() { list_all_models | grep "★ 已设为默认" | sed 's/  ★ 已设为默认//' | head -1; }

# ---------- 运行时模型（从 Gateway 读取） ----------
runtime_model() {
  local resp; resp=$(openclaw gateway call config.get --params '{}' 2>/dev/null || true)
  if [ -n "$resp" ]; then
    echo "$resp" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); c=json.loads(d.get('config','{}'))
    a=c.get('agents',{}); m=(a.get('defaults') or {}).get('model') or {}
    p=m.get('primary',''); f=m.get('fallbacks',[])
    r=p if p else '(未配置)'
    if f: r+=' â '+' â '.join(f)
    print(r)
except: print('(解析失败)')
" 2>/dev/null
  else echo "(Gateway 不可达)"; fi
}

# ---------- 状态摘要 ----------
show_status() {
  local dm pc fc rm
  dm=$(default_model); pc=$(providers_list | grep -c . 2>/dev/null || echo 0)
  fc=$(fallback_list | grep -c . 2>/dev/null || echo 0); rm=$(runtime_model)
  gum style --foreground 240 "  默认: $dm  â  è¿è¡æ¶: $rm  â  ä¾åºå: $pc  â  Fallback: $fc"
}

# ======================================================================
# v2.1.0 â: æµè¯ä¾åºåè¿æ¥
# ======================================================================
test_provider() {
  local pname="$1" url api_key
  url=$(provider_url "$pname"); api_key=$(j ".models.providers.\"$pname\".apiKey // \"\"")
  [ -z "$api_key" -o "$url" = "-" ] && { printf '  \033[0;90m  â­ %s: URL/Key ç¼ºå¤±\033[0m\n' "$pname"; return 1; }
  printf '  \033[0;90m  ð æµè¯ %s (%s)...\033[0m\n' "$pname" "$url"
  local st raw hc body elapsed; st=$(date +%s%N)
  raw=$(curl -s -w "\n%{http_code}" --max-time 15 -H "Authorization: Bearer $api_key" "${url}/models" 2>/dev/null) || {
    printf '  \033[0;31m  â %s: ç½ç»éè¯¯/è¶æ¶\033[0m\n' "$pname"; return 1; }
  elapsed=$(( ($(date +%s%N) - st) / 1000000 )); hc=$(echo "$raw" | tail -1); body=$(echo "$raw" | sed '$d')
  case "$hc" in
    200) local mc; mc=$(echo "$body" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); ms=d.get('data',d) if isinstance(d,dict) else d
    print(len([m for m in ms if isinstance(m,dict) and 'id' in m]))
except: print(0)" 2>/dev/null || echo "0")
      printf '  \033[0;32m  â %s: è¿æ¥æå! %sms, %s ä¸ªæ¨¡å\033[0m\n' "$pname" "$elapsed" "$mc"; return 0 ;;
    401|403) printf '  \033[0;31m  â %s: è®¤è¯å¤±è´¥ HTTP %s (Key å¯è½è¿æ)\033[0m\n' "$pname" "$hc"; return 1 ;;
    404) printf '  \033[1;33m  â   %s: /models ä¸å­å¨ HTTP %s\033[0m\n' "$pname" "$hc"; return 1 ;;
    *) printf '  \033[1;33m  â   %s: HTTP %s (%sms)\033[0m\n' "$pname" "$hc" "$elapsed"; return 1 ;;
  esac
}

test_model_chat() {
  local pname="$1" mid="$2" url api_key
  url=$(provider_url "$pname"); api_key=$(j ".models.providers.\"$pname\".apiKey // \"\"")
  [ -z "$api_key" -o "$url" = "-" ] && { warn "$pname: URL/Key ç¼ºå¤±"; return 1; }
  printf '  \033[0;90m  ð¬ æµè¯ %s (%s)...\033[0m\n' "$mid" "$pname"
  local st raw hc elapsed; st=$(date +%s%N)
  raw=$(curl -s -w "\n%{http_code}" --max-time 30 -H "Authorization: Bearer $api_key" -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$mid" '{model:$m,messages:[{role:"user",content:"Hi"}],max_tokens:1}')" \
    "${url}/chat/completions" 2>/dev/null) || { printf '  \033[0;31m  â %s: ç½ç»éè¯¯\033[0m\n' "$mid"; return 1; }
  elapsed=$(( ($(date +%s%N) - st) / 1000000 )); hc=$(echo "$raw" | tail -1)
  case "$hc" in
    200) printf '  \033[0;32m  â %s: å¯ç¨! %sms\033[0m\n' "$mid" "$elapsed"; return 0 ;;
    401|403) printf '  \033[0;31m  â %s: è®¤è¯å¤±è´¥ HTTP %s\033[0m\n' "$mid" "$hc"; return 1 ;;
    429) printf '  \033[1;33m  â   %s: éçéå¶ HTTP %s\033[0m\n' "$mid" "$hc"; return 0 ;;
    *) printf '  \033[1;33m  â   %s: HTTP %s (%sms)\033[0m\n' "$mid" "$hc" "$elapsed"; return 1 ;;
  esac
}

test_all_providers() {
  echo ""; gum style --bold --foreground 51 "ââ æµè¯ææä¾åºåè¿æ¥ ââ"; echo ""
  local p=(); while IFS= read -r x; do [ -n "$x" ] && p+=("$x"); done < <(providers_list)
  [ ${#p[@]} -eq 0 ] && { warn "æ²¡æä¾åºå"; return; }
  local ok=0 fc=0
  for x in "${p[@]}"; do echo ""; if test_provider "$x"; then ((ok++))||true; else ((fc++))||true; fi; done
  echo ""; local total=$((ok+fc))
  [ $fc -eq 0 ] && info "å¨é¨éè¿: $ok/$total ä¾åºåæ­£å¸¸" || warn "ç»æ: $ok æ­£å¸¸, $fc/$total å¼å¸¸"
}

# ======================================================================
#  å¿«éåæ¢æ¨¡åï¼fzfï¼
# ======================================================================
cmd_switch() {
  local all_models
  all_models=$(list_all_models)
  [ -z "$all_models" ] && { fail_msg "没有可用模型"; return 1; }

  local current
  current=$(echo "$all_models" | grep "已设为默认" | sed 's/  ★ 已设为默认//' | head -1)

  local selected
  selected=$(echo "$all_models" | fzf \
    --prompt="  ❯ " \
    --header="  当前: $current  │  ↑↓ 搜索 · Enter 确认 · Esc 取消" \
    --header-first \
    --height=20 --layout=reverse --border=rounded \
    --border-label=" ◈ 切换默认模型 " \
    --color=border:51,label:51,header:51,prompt:201,pointer:46,marker:208,hl:208,hl+:208) || return

  [ -z "$selected" ] && return
  selected=$(echo "$selected" | sed 's/  ★ 已设为默认//' | awk '{print $1}')

  backup
  jq --arg m "$selected" '.agents.defaults.model.primary = $m' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "已切换为: $selected"

  gum confirm "重启网关生效?" && {
    gum spin --spinner minidot --title "正在重启..." -- openclaw gateway restart 2>/dev/null
    info "网关已重启"
  }
}

# ============================================================
#  同步云端模型
# ============================================================
cmd_sync() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有供应商"; return; }

  echo ""
  gum style --bold --foreground 51 "━━ 同步云端模型 ━━"
  echo ""

  local items=("同步全部" "返回")
  items+=("${providers[@]}")

  local choice
  choice=$(gum choose --cursor "❯ " --header "选择要同步的供应商\n↑↓ 移动 · Enter 确认 · q 退出" "${items[@]}") || return
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
  pname=$(gum input --placeholder "供应商名称 (如: openai)" --prompt "供应商 > ") || return
  [ -z "$pname" ] && { warn "名称不能为空"; return; }

  if jq -e ".models.providers.\"$pname\"" "$CONFIG" &>/dev/null; then
    gum confirm "供应商 '$pname' 已存在，覆盖?" || return
  fi

  base_url=$(gum input --placeholder "https://api.xxx.com/v1" --prompt "地址 > ") || return
  [ -z "$base_url" ] && return
  base_url="${base_url%/}"

  api_key=$(gum input --password --placeholder "sk-xxx" --prompt "密钥 > ") || return
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
      --header="  发现 $model_count 个模型 · 选择默认模型 · Esc 跳过" \
      --header-first --height=15 --layout=reverse --border=rounded \
      --border-label=" ◈ 已设为默认 MODEL " \
      --color=border:51,label:51,header:51,prompt:201,pointer:46,marker:208,hl:208,hl+:208) || true
  fi

  echo ""
  gum style --border normal --border-foreground 99 --padding "0 2" \
    "供应商 : $pname" \
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

  info "供应商 '$pname' 已添加 ($model_count 个模型)"
}

# ============================================================
#  删除供应商
# ============================================================
delete_provider() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有供应商"; return; }

  local items=("返回")
  for p in "${providers[@]}"; do
    items+=("$(printf '%-15s %s 个模型' "$p" "$(model_count "$p")")")
  done

  local choice
  choice=$(gum choose --cursor "❯ " --header "选择要删除的供应商\n↑↓ 移动 · Enter 确认 · Esc 返回" "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local pname; pname=$(echo "$choice" | awk '{print $1}')
  gum confirm "⚠ 删除 '$pname' 及所有模型?" || return

  backup
  jq "del(.models.providers.\"$pname\")" "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  info "已删除: $pname"
}

# ============================================================
#  v2.1.0 编辑供应商（增强 - 支持测试连接）
# ============================================================
edit_provider() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有供应商"; return; }

  local items=("返回")
  for p in "${providers[@]}"; do
    items+=("$(printf '%-15s %-30s %s模型' "$p" "$(provider_url "$p")" "$(model_count "$p")")")
  done

  local choice
  choice=$(gum choose --cursor "❯ " --header "选择供应商" "${items[@]}") || return
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
        local s; s=$(printf '%s\n' "${ml[@]}" | fzf --prompt="  ❯ " --header="选择模型" \
          --height=15 --layout=reverse --border=rounded --color=border:51,label:51,prompt:201,pointer:46) || continue
        [ -z "$s" ] && continue; test_model_chat "$pn" "$s"; prompt_continue ;;
      "✏️  修改地址")
        local o n; o=$(provider_url "$pn"); n=$(gum input --value "$o" --prompt "URL > ") || continue
        [ -z "$n" ] && continue; n="${n%/}"; backup
        jq --arg p "$pn" --arg u "$n" '.models.providers[$p].baseUrl=$u' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        info "地址已更新: $n"; echo ""; test_provider "$pn" || true ;;
      "🔑 修改密钥")
        local n; n=$(gum input --password --prompt "密钥 > ") || continue
        [ -z "$n" ] && continue; backup
        jq --arg p "$pn" --arg k "$n" '.models.providers[$p].apiKey=$k' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        info "密钥已更新"; echo ""; test_provider "$pn" || true ;;
      "🔄 同步模型")
        echo ""; _sync_one "$pn"; prompt_continue ;;
      "返回"|*) return ;;
    esac
  done
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
        local tv; tv=$(gum choose --cursor "❯ " --header="选择供应商" "${tp[@]}") || { prompt_continue; continue; }
        local tm=(); while IFS= read -r m; do [ -n "$m" ] && tm+=("$m"); done < <(provider_models "$tv")
        if [ ${#tm[@]} -eq 0 ]; then warn "$tv 无模型"; prompt_continue; continue; fi
        echo ""; for m in "${tm[@]}"; do test_model_chat "$tv" "$m" || true; done
        prompt_continue ;;
      "返回主菜单"|*)    return ;;
    esac
  done
}

_add_model() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有供应商"; return; }

  local items=("返回")
  items+=("${providers[@]}")
  local choice
  choice=$(gum choose --cursor "❯ " --header "选择供应商" "${items[@]}") || return
  [[ "$choice" == "返回" ]] && return

  local mid mname
  mid=$(gum input --placeholder "模型 ID" --prompt "模型 ID > ") || return
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
  [ ${#providers[@]} -eq 0 ] && { warn "没有供应商"; return; }

  local items=("返回")
  items+=("${providers[@]}")
  local prov
  prov=$(gum choose --cursor "❯ " --header "选择供应商" "${items[@]}") || return
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
  action=$(gum choose --cursor "❯ " --header "Fallback 管理\n↑↓ 移动 · Enter 确认 · Esc 返回" \
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
      sel=$(echo "$all_models" | fzf --prompt="  ❯ " --header="选择 Fallback · Esc 取消" \
        --height=15 --layout=reverse --border=rounded --border-label=" 添加 Fallback " \
        --color=border:51,label:51,prompt:201,pointer:46,marker:208) || return
      sel=$(echo "$sel" | sed 's/  ★ 已设为默认//')
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
    gum style --bold --foreground 51 "━━ 供应商管理 ━━"
    echo ""

    # 快速总览
    local providers=()
    while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
    for p in "${providers[@]}"; do
      printf "  ${YELLOW}%-15s${NC} ${CYAN}%-35s${NC} %s 个模型\n" "$p" "$(provider_url "$p")" "$(model_count "$p")"
    done
    [ ${#providers[@]} -eq 0 ] && echo -e "  ${GRAY}(无供应商)${NC}"
    echo ""

    local action
    action=$(gum choose --cursor "❯ " --header "↑↓ 移动 · Enter 确认 · ESC 返回上级" \
      "添加供应商" \
      "编辑供应商" \
      "删除供应商" \
      "同步云端模型" \
      "🔗 测试所有连接" \
      "返回主菜单") || return

    case "$action" in
      "添加供应商")    add_provider; prompt_continue ;;
      "编辑供应商")    edit_provider; prompt_continue ;;
      "删除供应商")    delete_provider; prompt_continue ;;
      "同步云端模型")  cmd_sync; prompt_continue ;;
      "🔗 测试所有连接") test_all_providers; prompt_continue ;;
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
  ls|list)      list_all_models; exit ;;
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

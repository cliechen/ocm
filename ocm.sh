#!/usr/bin/env bash
# ============================================================
#  ocm — OpenClaw/Hermes Model Manager v2.2
#  交互式管理 API 供应商 / 模型 / 默认模型
#  支持两种模式:
#    OpenClaw : ~/.openclaw/openclaw.json   (JSON + jq)
#    Hermes   : ~/.hermes/config.yaml       (YAML, 写入用 hermes config set)
#  依赖: jq, gum, fzf, python3, curl  (Hermes 模式需要 python3-yaml 与 hermes CLI)
#  用法: ocm [hermes|openclaw] [ls|switch|status|restart|sync|test|help]
#        也可用环境变量 OCM_MODE=hermes ocm ls
# ============================================================
#  v2.2.0 (2026-08-11): 新增 Hermes Agent 模式
#   ✦ 主菜单可切换管理模式 (OpenClaw / Hermes)
#   ✦ Hermes: 切换默认模型 → hermes config set model.default
#   ✦ Hermes: 同步模型 → 拉取 /models 写入 ~/.hermes/ocm-models.json 缓存
#   ✦ Hermes: 供应商增删改 → hermes config set providers.<name>.*
#   ✦ Hermes: Fallback 管理 → 读写 config.yaml 的 fallback_providers
#   ✦ CLI: ocm hermes ls / OCM_MODE=hermes ocm ls
#  v2.1.4 (2026-08-11): Bugfix release
#   ✦ 修复: 15 处 `[ -z "$ || return" ]` 错误占位符 → 恢复正确的 ESC 返回逻辑
#   ✦ 修复: 所有 fzf / gum 调用补回 `|| return` 保护, 按 ESC 不再被 set -e 直接退出
#   ✦ 修复: 覆盖供应商 / 删除供应商确认按"否"时仍继续执行
#   ✦ 修复: 全部乱码 (mojibake) 还原为正确中文
#   ✦ 修复: 空列表时 grep -c 计数输出双行的问题
#   ✦ 修复: 同步模型时 jq `input` 管道失效, 改为 --argjson
#   ✦ 恢复: 模型价格标签 ([FREE] / $0.15入 / 百万上下文)
#  v2.1.0 (2026-04-02):
#   ✦ 新增: 测试供应商连接 / 测试模型可用性 / 批量测试
#   ✦ 新增: 模型价格标签 / Gateway 运行时实际使用模型
#   ✦ 增强: 编辑 URL/Key 后自动验证 / 同步添加自动验证 / clobbered 存档
# ============================================================
set -euo pipefail

VERSION="2.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"

# ---------- 模式 ----------
# 支持: OCM_MODE=openclaw|hermes ; ocm hermes|openclaw [cmd]
OCM_MODE="${OCM_MODE:-openclaw}"

set_mode() {
  OCM_MODE="$1"
  case "$OCM_MODE" in
    hermes)
      GW="hermes"
      CONFIG="$HOME/.hermes/config.yaml"
      BACKUP="$HOME/.hermes/config.yaml.bak"
      CLOBBERED_DIR="$HOME/.hermes/backups/ocm-clobbered"
      MODE_CACHE="$HOME/.hermes/ocm-models.json"
      MODE_LABEL="Hermes"
      ;;
    *)
      OCM_MODE="openclaw"
      GW="openclaw"
      CONFIG="$HOME/.openclaw/openclaw.json"
      BACKUP="$HOME/.openclaw/openclaw.json.bak"
      CLOBBERED_DIR="$HOME/.openclaw/backups/ocm-clobbered"
      MODE_CACHE=""
      MODE_LABEL="OpenClaw"
      ;;
  esac
  mkdir -p "$CLOBBERED_DIR"
  export OCM_CONFIG="$CONFIG"
  export OCM_MODE
  if [ -n "$MODE_CACHE" ]; then export OCM_CACHE="$MODE_CACHE"; fi
  return 0
}

is_hermes() { [ "$OCM_MODE" = "hermes" ]; }

set_mode "$OCM_MODE"

# ---------- 颜色 ----------
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; GRAY='\033[0;90m'; NC='\033[0m'

# ---------- 依赖 ----------
for cmd in jq gum fzf python3 curl; do
  command -v "$cmd" &>/dev/null || { echo -e "${RED}缺少依赖: $cmd${NC}"; exit 1; }
done
if is_hermes && ! command -v hermes &>/dev/null; then
  echo -e "${YELLOW}⚠ 未检测到 hermes CLI（切换/写入配置时需要）${NC}"
fi

# ---------- 核心工具函数 ----------
info() { gum style --foreground 46 "✓ $*"; }
warn() { gum style --foreground 214 "⚠ $*"; }
fail_msg() { gum style --foreground 196 "✗ $*"; }

backup() {
  cp "$CONFIG" "$BACKUP"
  if is_hermes && [ -f "$MODE_CACHE" ]; then cp "$MODE_CACHE" "${MODE_CACHE}.bak"; fi
  gum style --foreground 240 "  ✓ 已备份 → $BACKUP"
}

backup_clobbered() {
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  cp "$CONFIG" "$CLOBBERED_DIR/${OCM_MODE}-pre-${ts}.yaml" 2>/dev/null \
    || cp "$CONFIG" "$CLOBBERED_DIR/${OCM_MODE}-pre-${ts}.json"
}

prompt_continue() { gum input --placeholder "按回车继续" > /dev/null 2>&1 || true; }

# ---------- JSON 快捷操作 (OpenClaw) ----------
j() { jq -r "$1" "$CONFIG" 2>/dev/null; }

# ======================================================================
#  Hermes: YAML 读取 / 写入
# ======================================================================
# 读取 Hermes config.yaml 的任意点号键 (含 ${ENV} 展开), 缺失时输出空
# 无 pyyaml 时回退: hermes config get --json (官方 CLI)
hget() {
  python3 - "$CONFIG" "$1" <<'PYEOF'
import sys, os, re
try:
    import yaml
    HAVE_YAML = True
except Exception:
    HAVE_YAML = False
path, key = sys.argv[1], sys.argv[2]
try:
    node = None
    if HAVE_YAML:
        with open(path) as f: d = yaml.safe_load(f) or {}
        node = d
        for part in key.split('.'):
            if isinstance(node, dict) and part in node:
                node = node[part]
            else:
                node = None; break
    if node is None and not HAVE_YAML:
        import subprocess, json
        try:
            out = subprocess.check_output(['hermes', 'config', 'get', key, '--json'],
                                          text=True, stderr=subprocess.DEVNULL).strip()
            node = json.loads(out) if out else None
        except Exception:
            node = None
    if node is None or isinstance(node, (dict, list)):
        print('')
    elif isinstance(node, bool):
        print('true' if node else 'false')
    elif isinstance(node, str):
        m = re.fullmatch(r'\$\{(\w+)\}', node.strip())
        print(os.environ.get(m.group(1), '') if m else node)
    else:
        print(node)
except Exception:
    print('')
PYEOF
}

# 写入 Hermes 配置 (官方 CLI, 支持点号键)
hset() { "$GW" config set --force "$1" "$2" >/dev/null 2>&1; }

# Hermes 提供商列表: providers 映射 + 当前 model.provider
h_providers_list() {
  python3 - "$CONFIG" <<'PYEOF'
import sys
try:
    import yaml
except Exception:
    raise SystemExit
try:
    with open(sys.argv[1]) as f: d = yaml.safe_load(f) or {}
    names = set()
    pv = d.get('providers')
    if isinstance(pv, dict): names.update(pv.keys())
    m = d.get('model')
    if isinstance(m, dict):
        prov = m.get('provider')
        if prov and prov != 'auto': names.add(prov)
    for n in sorted(names): print(n)
except Exception:
    pass
PYEOF
}

# 常见提供商 baseUrl 注册表 (OpenAI 兼容, 用于 /models 与 /chat/completions)
h_provider_base_url() {
  local pn="$1" u
  u=$(hget "providers.$pn.base_url")
  [ -n "$u" ] && { echo "${u%/}"; return; }
  case "$pn" in
    custom) u=$(hget model.base_url) ;;
    openrouter) u="https://openrouter.ai/api/v1" ;;
    openai) u="https://api.openai.com/v1" ;;
    deepseek) u="https://api.deepseek.com/v1" ;;
    gemini) u="https://generativelanguage.googleapis.com/v1beta" ;;
    xai|grok) u="https://api.x.ai/v1" ;;
    groq) u="https://api.groq.com/openai/v1" ;;
    mistral) u="https://api.mistral.ai/v1" ;;
    together) u="https://api.together.xyz/v1" ;;
    lmstudio) u="${LM_BASE_URL:-http://localhost:1234/v1}" ;;
  esac
  [ -n "$u" ] && { echo "${u%/}"; return; }
  echo "-"
}

# 解析提供商 API Key: providers.api_key → key_env → model.api_key → 常见环境变量
h_provider_key() {
  local pn="$1" k envn
  k=$(hget "providers.$pn.api_key"); [ -n "$k" ] && { echo "$k"; return; }
  envn=$(hget "providers.$pn.key_env")
  if [ -n "$envn" ]; then
    k=$(printenv "$envn" 2>/dev/null || true); [ -n "$k" ] && { echo "$k"; return; }
  fi
  # 标准环境变量优先 (OPENROUTER_API_KEY 等), 避免跨供应商切换时误用旧 key
  case "$pn" in
    openai) k=$(printenv OPENAI_API_KEY 2>/dev/null || true) ;;
    anthropic) k=$(printenv ANTHROPIC_API_KEY 2>/dev/null || true) ;;
    openrouter) k=$(printenv OPENROUTER_API_KEY 2>/dev/null || true) ;;
    deepseek) k=$(printenv DEEPSEEK_API_KEY 2>/dev/null || true) ;;
    gemini) k=$(printenv GEMINI_API_KEY 2>/dev/null || true); [ -z "$k" ] && k=$(printenv GOOGLE_API_KEY 2>/dev/null || true) ;;
    xai|grok) k=$(printenv XAI_API_KEY 2>/dev/null || true) ;;
    groq) k=$(printenv GROQ_API_KEY 2>/dev/null || true) ;;
  esac
  [ -n "$k" ] && { echo "$k"; return; }
  # 兜底: custom 或当前 provider 使用 model.api_key
  if [ "$pn" = "custom" ] || [ "$pn" = "$(hget model.provider)" ]; then
    k=$(hget model.api_key); [ -n "$k" ] && { echo "$k"; return; }
  fi
  echo ""
}

# 当前模型 (完整 "provider/model" 形式)
h_current_model() {
  local d p
  d=$(hget model.default)
  [ -z "$d" ] && d=$(hget model)
  [ -z "$d" ] && { echo ""; return; }
  p=$(hget model.provider)
  if [ -n "$p" ] && [ "$p" != "auto" ] && [[ "$d" != */* ]]; then
    echo "$p/$d"
  else
    echo "$d"
  fi
}

# Hermes fallback 链 (fallback_providers → provider/model 行)
h_fallback_list() {
  python3 - "$CONFIG" <<'PYEOF'
import sys
try:
    import yaml
except Exception:
    raise SystemExit
try:
    with open(sys.argv[1]) as f: d = yaml.safe_load(f) or {}
    for e in (d.get('fallback_providers') or []):
        if isinstance(e, dict) and e.get('provider') and e.get('model'):
            print("%s/%s" % (e['provider'], e['model']))
        elif isinstance(e, str):
            print(e)
except Exception:
    pass
PYEOF
}

# 写入 fallback 链 (输入: 每行 "provider/model")
h_write_fallbacks() {
  local arr
  arr=$(printf '%s\n' "$1" | python3 -c "
import sys, json
out = []
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if not line: continue
    p, m = line.split('/', 1)
    out.append({'provider': p, 'model': m})
print(json.dumps(out))
")
  hset fallback_providers "$arr"
}

# 从 YAML 中删除 providers.<name> 块 (保留其他内容)
h_remove_provider() {
  local pn="$1"
  python3 - "$CONFIG" "$pn" <<'PYEOF'
import sys, re
path, name = sys.argv[1], sys.argv[2]
with open(path) as f: lines = f.readlines()
out = []
i = 0
removed = False
while i < len(lines):
    line = lines[i]
    if re.match(r'^providers:\s*$', line):
        out.append(line); i += 1
        while i < len(lines) and (lines[i].startswith(' ') or lines[i].strip() == ''):
            m = re.match(r'^  ([A-Za-z0-9_.-]+):', lines[i])
            if m and m.group(1) == name:
                removed = True
                i += 1
                while i < len(lines) and (lines[i].startswith('    ') or lines[i].strip() == ''):
                    i += 1
                continue
            out.append(lines[i]); i += 1
        continue
    out.append(line); i += 1
if not removed:
    sys.exit(1)
with open(path, 'w') as f: f.writelines(out)
PYEOF
}

# 当前供应商要写入配置的目标 (Hermes 用 providers.<name>.*, 当前提供商用 model.*)
h_edit_target() {
  local pn="$1"
  if [ -n "$(hget "providers.$pn.base_url")" ] || [ -n "$(hget "providers.$pn.api_key")" ]; then
    echo "providers.$pn"
  elif [ "$pn" = "$(hget model.provider)" ]; then
    echo "model"
  else
    echo ""
  fi
}

# ======================================================================
#  模式分发: 供应商 / 模型 / 默认模型 / fallback
# ======================================================================
providers_list() {
  if is_hermes; then h_providers_list; else j '.models.providers | keys[]'; fi
}
provider_url() {
  if is_hermes; then h_provider_base_url "$1"; else j ".models.providers.\"$1\".baseUrl // \"-\""; fi
}
provider_api() {
  if is_hermes; then echo "openai-completions"; else j ".models.providers.\"$1\".api // \"openai-completions\""; fi
}
pkey() {  # 原始 API Key (用于请求)
  if is_hermes; then h_provider_key "$1"; else j ".models.providers.\"$1\".apiKey // \"\""; fi
}
provider_key() {  # 遮盖显示
  local k; k=$(pkey "$1")
  if [ -n "$k" ]; then echo "${k:0:8}****"; else echo "(无)"; fi
}
provider_models() {
  if is_hermes; then
    [ -f "$MODE_CACHE" ] && jq -r ".models.providers.\"$1\".models[]?.id // empty" "$MODE_CACHE" 2>/dev/null || true
  else
    j ".models.providers.\"$1\".models[]?.id // empty"
  fi
}
default_model() {
  if is_hermes; then
    local m; m=$(h_current_model); echo "${m:-(未设置)}"
  else
    j '.agents.defaults.model.primary // "(未设置)"'
  fi
}
fallback_list() {
  if is_hermes; then h_fallback_list; else j '(.agents.defaults.model.fallbacks // [])[]'; fi
}
# 注意: grep -c 无匹配时输出 0 且退出码为 1, 用 || true 兜底避免重复输出
model_count()    { provider_models "$1" | grep -c . 2>/dev/null || true; }

# ---------- 模型读取（本地，秒开） ----------
list_all_models() {
  if is_hermes; then
    export OCM_CURRENT="$(h_current_model)"
  fi
  python3 << 'PYEOF'
import json, os
mode = os.environ.get("OCM_MODE", "")
path = os.environ.get("OCM_CACHE", "") if mode == "hermes" else os.environ.get("OCM_CONFIG", "")
cur = os.environ.get("OCM_CURRENT", "")
try:
    with open(path) as f: obj = json.load(f)
except Exception:
    obj = {}
p = (obj.get("models") or {}).get("providers") or {}
a = obj.get("agents") or {}
pr = ((a.get("defaults") or {}).get("model") or {}).get("primary", "")
if mode == "hermes" and cur:
    pr = cur
found = False
for pn, pd in sorted(p.items()):
    if not isinstance(pd, dict): continue
    for m in (pd.get("models") or []):
        if isinstance(m, dict) and m.get("id"):
            found = True
            full = pn + "/" + m["id"]
            tag = "  ★ 已设为默认" if full == pr else ""
            cap = ""
            cost = m.get("cost", {})
            if isinstance(cost, dict):
                ci, co = cost.get("input", 0), cost.get("output", 0)
                if ci == 0 and co == 0: cap += " [FREE]"
                elif ci or co: cap += " $%.2f入" % ci
            ctx = m.get("contextWindow", 0)
            if isinstance(ctx, (int, float)) and ctx >= 1000000:
                cap += " %dM" % (int(ctx) // 1000000)
            print(full + cap + tag)
if mode == "hermes" and not found and pr:
    print(pr + "  ★ 已设为默认")
PYEOF
}

# ---------- 运行时模型 ----------
runtime_model() {
  if is_hermes; then
    local m; m=$(h_current_model)
    if command -v "$GW" &>/dev/null && "$GW" gateway status >/dev/null 2>&1; then
      echo "${m:-（未配置）} · gateway 运行中"
    else
      echo "${m:-（未配置）} · gateway 未运行"
    fi
    return
  fi
  local resp; resp=$(openclaw gateway call config.get --params '{}' 2>/dev/null || true)
  if [ -n "$resp" ]; then
    echo "$resp" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); c=json.loads(d.get('config','{}'))
    a=c.get('agents',{}); m=(a.get('defaults') or {}).get('model') or {}
    p=m.get('primary',''); f=m.get('fallbacks',[])
    r=p if p else '(未配置)'
    if f: r += ' → ' + ' → '.join(f)
    print(r)
except: print('(解析失败)')
" 2>/dev/null
  else echo "(Gateway 不可达)"; fi
}

# ---------- 状态摘要 ----------
show_status() {
  local dm pc fc rm
  dm=$(default_model); pc=$(providers_list | grep -c . 2>/dev/null || true)
  fc=$(fallback_list | grep -c . 2>/dev/null || true); rm=$(runtime_model)
  gum style --foreground 240 "  默认: $dm  │  运行时: $rm  │  供应商: $pc  │  Fallback: $fc"
}

# ======================================================================
# v2.1.0 ★: 测试供应商连接
# ======================================================================
test_provider() {
  local pname="$1" url api_key
  url=$(provider_url "$pname"); api_key=$(pkey "$pname")
  [ -z "$api_key" -o "$url" = "-" ] && { printf '  \033[0;90m  ⏭ %s: URL/Key 缺失\033[0m\n' "$pname"; return 1; }
  printf '  \033[0;90m  🔗 测试 %s (%s)...\033[0m\n' "$pname" "$url"
  local st raw hc body elapsed; st=$(date +%s%N)
  raw=$(curl -s -w "\n%{http_code}" --max-time 15 -H "Authorization: Bearer $api_key" "${url}/models" 2>/dev/null) || {
    printf '  \033[0;31m  ✗ %s: 网络错误/超时\033[0m\n' "$pname"; return 1; }
  elapsed=$(( ($(date +%s%N) - st) / 1000000 )); hc=$(echo "$raw" | tail -1); body=$(echo "$raw" | sed '$d')
  case "$hc" in
    200) local mc; mc=$(echo "$body" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); ms=d.get('data',d) if isinstance(d,dict) else d
    print(len([m for m in ms if isinstance(m,dict) and 'id' in m]))
except: print(0)" 2>/dev/null || echo "0")
      printf '  \033[0;32m  ✅ %s: 连接成功! %sms, %s 个模型\033[0m\n' "$pname" "$elapsed" "$mc"; return 0 ;;
    401|403) printf '  \033[0;31m  ✗ %s: 认证失败 HTTP %s (Key 可能过期)\033[0m\n' "$pname" "$hc"; return 1 ;;
    404) printf '  \033[1;33m  ⚠ %s: /models 不存在 HTTP %s\033[0m\n' "$pname" "$hc"; return 1 ;;
    *) printf '  \033[1;33m  ⚠ %s: HTTP %s (%sms)\033[0m\n' "$pname" "$hc" "$elapsed"; return 1 ;;
  esac
}

test_model_chat() {
  local pname="$1" mid="$2" url api_key
  url=$(provider_url "$pname"); api_key=$(pkey "$pname")
  [ -z "$api_key" -o "$url" = "-" ] && { warn "$pname: URL/Key 缺失"; return 1; }
  printf '  \033[0;90m  💬 测试 %s (%s)...\033[0m\n' "$mid" "$pname"
  local st raw hc elapsed; st=$(date +%s%N)
  raw=$(curl -s -w "\n%{http_code}" --max-time 30 -H "Authorization: Bearer $api_key" -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$mid" '{model:$m,messages:[{role:"user",content:"Hi"}],max_tokens:1}')" \
    "${url}/chat/completions" 2>/dev/null) || { printf '  \033[0;31m  ✗ %s: 网络错误\033[0m\n' "$mid"; return 1; }
  elapsed=$(( ($(date +%s%N) - st) / 1000000 )); hc=$(echo "$raw" | tail -1)
  case "$hc" in
    200) printf '  \033[0;32m  ✅ %s: 可用! %sms\033[0m\n' "$mid" "$elapsed"; return 0 ;;
    401|403) printf '  \033[0;31m  ✗ %s: 认证失败 HTTP %s\033[0m\n' "$mid" "$hc"; return 1 ;;
    429) printf '  \033[1;33m  ⚠ %s: 速率限制 HTTP %s\033[0m\n' "$mid" "$hc"; return 0 ;;
    *) printf '  \033[1;33m  ⚠ %s: HTTP %s (%sms)\033[0m\n' "$mid" "$hc" "$elapsed"; return 1 ;;
  esac
}

test_all_providers() {
  echo ""; gum style --bold --foreground 51 "━━ 测试所有供应商连接 ━━"; echo ""
  local p=(); while IFS= read -r x; do [ -n "$x" ] && p+=("$x"); done < <(providers_list)
  [ ${#p[@]} -eq 0 ] && { warn "没有供应商"; return; }
  local ok=0 fc=0
  for x in "${p[@]}"; do echo ""; if test_provider "$x"; then ((ok++))||true; else ((fc++))||true; fi; done
  echo ""; local total=$((ok+fc))
  [ $fc -eq 0 ] && info "全部通过: $ok/$total 供应商正常" || warn "结果: $ok 正常, $fc/$total 异常"
}

# ======================================================================
#  快速切换模型（fzf）
# ======================================================================
cmd_switch() {
  local all_models
  all_models=$(list_all_models)
  [ -z "$all_models" ] && { fail_msg "没有可用模型"; return 0; }

  local current
  current=$(echo "$all_models" | grep "已设为默认" | sed 's/  ★ 已设为默认//' | head -1)

  local selected
  # fzf 按 ESC / Ctrl-C 退出码非 0, 必须 || return 0, 否则 set -e 会直接退出程序
  selected=$(echo "$all_models" | fzf \
    --prompt="  ❯ " \
    --header="  当前: $current  │  ↑↓ 搜索 · Enter 确认 · Esc 返回主菜单" \
    --header-first \
    --height=20 --layout=reverse --border=rounded \
    --border-label=" ◈ 切换默认模型 " \
    --color=border:51,label:51,header:51,prompt:201,pointer:46,marker:208,hl:208,hl+:208) || return 0

  [ -z "$selected" ] && return 0
  selected=$(echo "$selected" | sed 's/  ★ 已设为默认//' | awk '{print $1}')

  backup
  if is_hermes; then
    local p m; p="${selected%%/*}"; m="${selected#*/}"
    if [ -z "$p" ] || [ -z "$m" ] || [ "$p" = "$selected" ]; then
      warn "无效的模型: $selected"; return 0
    fi
    if ! hset model.default "$m"; then
      fail_msg "写入 Hermes 配置失败 (hermes config set model.default)"; return 0
    fi
    local curp; curp=$(hget model.provider)
    if [ "$p" != "$curp" ]; then
      # 先解析 base_url / api_key (此时 model.provider 仍是旧值,
      # 避免 h_provider_key 兜底命中而误用上一个供应商的 key)
      local bu k
      bu=$(h_provider_base_url "$p")
      k=$(h_provider_key "$p")
      hset model.provider "$p" || true
      if [ -n "$bu" ] && [ "$bu" != "-" ]; then hset model.base_url "$bu" || true; fi
      if [ -n "$k" ]; then hset model.api_key "$k" || true; else warn "$p: 未找到 API Key（可在编辑供应商中设置）"; fi
    fi
    info "已切换为: $p/$m"
  else
    jq --arg m "$selected" '.agents.defaults.model.primary = $m' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
    info "已切换为: $selected"
  fi

  if gum confirm "重启网关生效?"; then
    if gum spin --spinner minidot --title "正在重启..." -- "$GW" gateway restart 2>/dev/null; then
      info "网关已重启"
    else
      fail_msg "重启失败"
    fi
    prompt_continue
  fi
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
  # ESC → 返回上级菜单
  choice=$(gum choose --cursor "❯ " --header "选择要同步的供应商\n↑↓ 移动 · Enter 确认 · Esc 返回" "${items[@]}") || return 0
  [ -z "$choice" ] && return 0
  [[ "$choice" == "返回" ]] && return 0

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
  api_key=$(pkey "$pname")

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

  # 把云端模型列表转换成配置格式 (--argjson 方式, 避免 jq input 管道失效)
  local models_list
  models_list=$(echo "$models_json" | python3 -c "
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
" 2>/dev/null || echo "[]")

  backup
  if is_hermes; then
    # 写入 ocm 模型缓存 (Hermes 配置本身不存模型目录)
    local target="$MODE_CACHE"
    [ -f "$target" ] || echo '{"models":{"providers":{}}}' > "$target"
    jq --arg p "$pname" --arg u "$url" --argjson models "$models_list" \
      '.models.providers[$p].baseUrl = $u | .models.providers[$p].models = $models' \
      "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
  else
    jq --arg p "$pname" --argjson models "$models_list" \
      '.models.providers[$p].models = $models' \
      "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  fi

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

  local pname base_url api_key
  # ESC → 返回上级菜单
  pname=$(gum input --placeholder "供应商名称 (如: openrouter)" --prompt "供应商 > ") || return 0
  [ -z "$pname" ] && { warn "名称不能为空"; return; }

  if is_hermes; then
    if [ -n "$(hget "providers.$pname.api_key")" ] || [ -n "$(hget "providers.$pname.base_url")" ]; then
      gum confirm "供应商 '$pname' 已存在，覆盖?" || return 0
    fi
    base_url=$(gum input --placeholder "https://api.xxx.com/v1" --prompt "地址 > ") || return 0
    [ -z "$base_url" ] && { warn "地址不能为空"; return; }
    base_url="${base_url%/}"
    api_key=$(gum input --password --placeholder "sk-xxx (可留空, 用 .env)" --prompt "密钥 > ") || return 0

    backup
    hset "providers.$pname.base_url" "$base_url" || { fail_msg "写入 Hermes 配置失败"; return 0; }
    if [ -n "$api_key" ]; then hset "providers.$pname.api_key" "$api_key" || true; fi

    # 自动获取模型 → 缓存
    local models_json model_count=0 models_arr="[]"
    models_json=$(curl -s -m 10 -H "Authorization: Bearer $api_key" "${base_url}/models" 2>/dev/null || true)
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
    if [ "$model_count" -gt 0 ]; then
      local target="$MODE_CACHE"
      [ -f "$target" ] || echo '{"models":{"providers":{}}}' > "$target"
      jq --arg p "$pname" --arg u "$base_url" --argjson models "$models_arr" \
        '.models.providers[$p].baseUrl = $u | .models.providers[$p].models = $models' \
        "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
    fi

    # fzf 选默认模型 (ESC 跳过)
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
      "模型     : $model_count" \
      "默认     : ${default_sel:-(未选)}"
    echo ""

    gum confirm "确认添加?" || { echo "已取消"; return; }

    if [ -n "$default_sel" ]; then
      hset model.default "$default_sel" || true
      hset model.provider "$pname" || true
      hset model.base_url "$base_url" || true
      if [ -n "$api_key" ]; then hset model.api_key "$api_key" || true; fi
    fi
    info "供应商 '$pname' 已添加 ($model_count 个模型)"
    return
  fi

  # ---- OpenClaw 模式 ----
  if jq -e ".models.providers.\"$pname\"" "$CONFIG" &>/dev/null; then
    # 用户选"否"时取消操作
    gum confirm "供应商 '$pname' 已存在，覆盖?" || return 0
  fi

  local api_type
  base_url=$(gum input --placeholder "https://api.xxx.com/v1" --prompt "地址 > ") || return 0
  [ -z "$base_url" ] && { warn "地址不能为空"; return; }
  base_url="${base_url%/}"

  api_key=$(gum input --password --placeholder "sk-xxx" --prompt "密钥 > ") || return 0
  [ -z "$api_key" ] && { warn "密钥不能为空"; return; }

  api_type=$(gum input --placeholder "openai-completions" --prompt "API 类型 > ") || true
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

  # fzf 选默认模型 (ESC 跳过)
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
  # ESC → 返回上级菜单
  choice=$(gum choose --cursor "❯ " --header "选择要删除的供应商\n↑↓ 移动 · Enter 确认 · Esc 返回" "${items[@]}") || return 0
  [ -z "$choice" ] && return 0
  [[ "$choice" == "返回" ]] && return

  local pname; pname=$(echo "$choice" | awk '{print $1}')
  # 用户选"否"时取消删除
  gum confirm "⚠ 删除 '$pname' 及所有模型?" || return 0

  backup
  if is_hermes; then
    if h_remove_provider "$pname"; then
      if [ "$pname" = "$(hget model.provider)" ]; then
        warn "注意: '$pname' 是当前模型提供商，已移除其配置 (模型键仍指向它)"
      fi
      info "已删除: $pname"
    else
      warn "'$pname' 无独立配置（可能由 .env 提供密钥），未做修改"
    fi
    return
  fi

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
  # ESC → 返回上级菜单
  choice=$(gum choose --cursor "❯ " --header "选择供应商" "${items[@]}") || return 0
  [ -z "$choice" ] && return 0
  [[ "$choice" == "返回" ]] && return

  local pname; pname=$(echo "$choice" | awk '{print $1}')
  _edit_submenu "$pname"
}

_edit_submenu() {
  local pn="$1"
  while true; do
    # ESC → 返回上级菜单
    local a; a=$(gum choose --cursor "❯ " --header "编辑 $pn" \
      "🔗 测试连接 (Models API)" \
      "💬 测试聊天 (Chat Completions)" \
      "✏️  修改地址" \
      "🔑 修改密钥" \
      "🔄 同步模型" \
      "返回") || return 0
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
        local o n; o=$(provider_url "$pn"); n=$(gum input --value "$o" --prompt "URL > ") || { continue; }
        if [ -z "$n" ]; then warn "地址不能为空"; prompt_continue; continue; fi
        n="${n%/}"; backup
        if is_hermes; then
          local tgt; tgt=$(h_edit_target "$pn")
          if [ -z "$tgt" ]; then warn "'$pn' 无独立配置，无法直接修改"; prompt_continue; continue; fi
          if ! hset "$tgt.base_url" "$n"; then fail_msg "写入 Hermes 配置失败"; prompt_continue; continue; fi
        else
          jq --arg p "$pn" --arg u "$n" '.models.providers[$p].baseUrl=$u' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        fi
        info "地址已更新: $n"
        echo ""; test_provider "$pn" || true
        prompt_continue ;;
      "🔑 修改密钥")
        local n; n=$(gum input --password --prompt "密钥 > ") || { continue; }
        if [ -z "$n" ]; then warn "密钥不能为空"; prompt_continue; continue; fi
        backup
        if is_hermes; then
          local tgt; tgt=$(h_edit_target "$pn")
          if [ -z "$tgt" ]; then warn "'$pn' 无独立配置，无法直接修改"; prompt_continue; continue; fi
          if ! hset "$tgt.api_key" "$n"; then fail_msg "写入 Hermes 配置失败"; prompt_continue; continue; fi
        else
          jq --arg p "$pn" --arg k "$n" '.models.providers[$p].apiKey=$k' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        fi
        info "密钥已更新"
        echo ""; test_provider "$pn" || true
        prompt_continue ;;
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
    gum style --bold --foreground 51 "━━ 模型管理 [$MODE_LABEL] ━━"
    echo ""
    show_status
    echo ""

    # ESC → 返回上级菜单
    local action
    action=$(gum choose --cursor "❯ " --header "↑↓ 移动 · Enter 确认 · ESC 返回上级" \
      "快速切换 (fzf)" \
      "添加模型" \
      "删除模型" \
      "管理 Fallback" \
      "💬 测试模型可用" \
      "返回主菜单") || return 0

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
  # ESC → 返回上级菜单
  choice=$(gum choose --cursor "❯ " --header "选择供应商" "${items[@]}") || return 0
  [ -z "$choice" ] && return 0
  [[ "$choice" == "返回" ]] && return

  local mid mname
  # ESC → 返回上级菜单
  mid=$(gum input --placeholder "模型 ID" --prompt "模型 ID > ") || return 0
  [ -z "$mid" ] && { warn "模型 ID 不能为空"; return; }
  # ESC → 使用默认名称
  mname=$(gum input --placeholder "$mid" --prompt "名称 > ") || true
  mname="${mname:-$mid}"

  local target="$CONFIG"
  if is_hermes; then
    target="$MODE_CACHE"
    [ -f "$target" ] || echo '{"models":{"providers":{}}}' > "$target"
  fi

  backup
  jq --arg p "$choice" --arg id "$mid" --arg name "$mname" \
    '.models.providers[$p].models += [{id: $id, name: $name, input: ["text"], contextWindow: 128000, maxTokens: 4096}]' \
    "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
  info "已添加: $mid → $choice"
}

_delete_model() {
  local providers=()
  while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
  [ ${#providers[@]} -eq 0 ] && { warn "没有供应商"; return; }

  local items=("返回")
  items+=("${providers[@]}")
  local prov
  # ESC → 返回上级菜单
  prov=$(gum choose --cursor "❯ " --header "选择供应商" "${items[@]}") || return 0
  [ -z "$prov" ] && return 0
  [[ "$prov" == "返回" ]] && return

  local models=()
  while IFS= read -r m; do [ -n "$m" ] && models+=("$m"); done < <(provider_models "$prov")
  [ ${#models[@]} -eq 0 ] && { warn "无模型"; return; }

  local mitems=("返回")
  mitems+=("${models[@]}")
  local mid
  # ESC → 返回上级菜单
  mid=$(gum choose --cursor "❯ " --header "选择要删除的模型" "${mitems[@]}") || return 0
  [ -z "$mid" ] && return 0
  [[ "$mid" == "返回" ]] && return

  local target="$CONFIG"
  if is_hermes; then
    target="$MODE_CACHE"
    [ -f "$target" ] || echo '{"models":{"providers":{}}}' > "$target"
  fi

  backup
  jq --arg p "$prov" --arg id "$mid" \
    '.models.providers[$p].models = [.models.providers[$p].models[] | select(.id != $id)]' \
    "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
  info "已删除: $mid"
}

_manage_fallback() {
  # ESC → 返回上级菜单
  local action
  action=$(gum choose --cursor "❯ " --header "Fallback 管理\n↑↓ 移动 · Enter 确认 · Esc 返回" \
    "查看" "添加" "移除" "清空" "返回") || return 0

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
      # ESC → 取消添加
      sel=$(echo "$all_models" | fzf --prompt="  ❯ " --header="选择 Fallback · Esc 取消" \
        --height=15 --layout=reverse --border=rounded --border-label=" 添加 Fallback " \
        --color=border:51,label:51,prompt:201,pointer:46,marker:208) || return 0
      [ -z "$sel" ] && return 0
      # 去掉价格标签和默认标记, 只保留 provider/model
      sel=$(echo "$sel" | sed 's/  ★ 已设为默认//' | awk '{print $1}')
      [ -z "$sel" ] && return 0
      backup
      if is_hermes; then
        local cur_chain; cur_chain=$(h_fallback_list)
        local new_chain
        new_chain=$(printf '%s\n%s\n' "$cur_chain" "$sel" | python3 -c "
import sys
seen = set()
out = []
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if line and line not in seen:
        seen.add(line); out.append(line)
print('\n'.join(out))
")
        if h_write_fallbacks "$new_chain"; then info "已添加 Fallback: $sel"; else fail_msg "写入失败"; fi
      else
        jq --arg m "$sel" '.agents.defaults.model.fallbacks = ((.agents.defaults.model.fallbacks // []) + [$m] | unique)' \
          "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        info "已添加: $sel"
      fi
      prompt_continue
      ;;
    "移除")
      local fbs=()
      while IFS= read -r fb; do [ -n "$fb" ] && fbs+=("$fb"); done < <(fallback_list)
      [ ${#fbs[@]} -eq 0 ] && { warn "无 Fallback"; return; }
      local mitems=("返回")
      mitems+=("${fbs[@]}")
      local sel
      # ESC → 返回上级菜单
      sel=$(gum choose --cursor "❯ " --header "选择要移除的 Fallback" "${mitems[@]}") || return 0
      [ -z "$sel" ] && return 0
      [[ "$sel" == "返回" ]] && return
      backup
      if is_hermes; then
        local new_chain
        new_chain=$(h_fallback_list | grep -vxF "$sel" || true)
        if h_write_fallbacks "$new_chain"; then info "已移除: $sel"; else fail_msg "写入失败"; fi
      else
        jq --arg m "$sel" '.agents.defaults.model.fallbacks = [(.agents.defaults.model.fallbacks // [])[] | select(. != $m)]' \
          "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        info "已移除: $sel"
      fi
      prompt_continue
      ;;
    "清空")
      gum confirm "清空所有 Fallback?" || return
      backup
      if is_hermes; then
        h_write_fallbacks "" && info "已清空" || fail_msg "写入失败"
      else
        jq '.agents.defaults.model.fallbacks = []' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
        info "已清空"
      fi
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
    gum style --bold --foreground 51 "━━ 供应商管理 [$MODE_LABEL] ━━"
    echo ""

    # 快速总览
    local providers=()
    while IFS= read -r p; do [ -n "$p" ] && providers+=("$p"); done < <(providers_list)
    for p in "${providers[@]}"; do
      printf "  ${YELLOW}%-15s${NC} ${CYAN}%-35s${NC} %s 个模型\n" "$p" "$(provider_url "$p")" "$(model_count "$p")"
    done
    [ ${#providers[@]} -eq 0 ] && echo -e "  ${GRAY}(无供应商)${NC}"
    echo ""

    # ESC → 返回主菜单
    local action
    action=$(gum choose --cursor "❯ " --header "↑↓ 移动 · Enter 确认 · ESC 返回上级" \
      "添加供应商" \
      "编辑供应商" \
      "删除供应商" \
      "同步云端模型" \
      "🔗 测试所有连接" \
      "返回主菜单") || return 0

    case "$action" in
      "添加供应商")    add_provider; prompt_continue ;;
      "编辑供应商")    edit_provider; prompt_continue ;;
      "删除供应商")    delete_provider; prompt_continue ;;
      "同步云端模型")  cmd_sync; prompt_continue ;;
      "🔗 测试所有连接") test_all_providers; prompt_continue ;;
      "返回主菜单"|*) return ;;
    esac
  done
}

# ============================================================
#  管理模式选择
# ============================================================
mode_picker() {
  local m
  # ESC → 退出
  m=$(gum choose --cursor "❯ " --header "选择要管理的模型系统\n↑↓ 移动 · Enter 确认 · Esc 退出" \
    "🟦 OpenClaw" "🟩 Hermes" "🚪 退出") || exit 0
  case "$m" in
    "🟩 Hermes") set_mode hermes ;;
    "🚪 退出"|"") exit 0 ;;
    *) set_mode openclaw ;;
  esac
}

# ============================================================
#  主菜单
# ============================================================
main_menu() {
  while true; do
    clear
    local dm pc mc
    dm=$(default_model)
    pc=$(providers_list | grep -c . 2>/dev/null || true)
    mc=$(list_all_models | grep -c . 2>/dev/null || true)

    echo ""
    gum style --bold --foreground 51 --border double --border-foreground 51 --padding "0 3" \
      "Model Manager v$VERSION — $MODE_LABEL 模式"
    echo ""

    # 状态卡片
    gum style --border rounded --border-foreground 240 --padding "0 2" \
      "默认模型  : $dm" \
      "供应商    : $pc" \
      "模型总数  : $mc"

    # ESC → 刷新菜单
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
      "↔  切换管理模式 (当前: $MODE_LABEL)" \
      "🚪  退出") || continue

    case "$action" in
      *"快速切换"*)   cmd_switch; prompt_continue ;;
      *"供应商管理"*) provider_menu ;;
      *"模型管理"*)   manage_models ;;
      *"同步云端"*)   cmd_sync; prompt_continue ;;
      *"测试连接"*)  test_all_providers; prompt_continue ;;
      *"重启"*)
        gum spin --spinner minidot --title "正在重启..." -- "$GW" gateway restart 2>/dev/null && info "网关已重启" || fail_msg "重启失败"
        prompt_continue ;;
      *"查看状态"*)
        echo ""
        "$GW" gateway status 2>/dev/null || "$GW" status 2>/dev/null || warn "状态查询失败"
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
      *"切换管理模式"*)
        mode_picker
        if [ ! -f "$CONFIG" ]; then
          warn "该模式配置不存在: $CONFIG"
          if is_hermes; then echo -e "  ${GRAY}请先运行: hermes setup / hermes model 生成配置${NC}"; fi
        fi
        continue ;;
      *"退出"|*) exit 0 ;;
    esac
  done
}

# ============================================================
#  入口
# ============================================================
# 支持: ocm [hermes|openclaw] [子命令]  ; 或 OCM_MODE=hermes ocm [子命令]
MODE_EXPLICIT=0
case "${1:-}" in
  hermes|openclaw) OCM_MODE="$1"; MODE_EXPLICIT=1; shift ;;
esac
set_mode "${OCM_MODE:-openclaw}"

[ -f "$CONFIG" ] || {
  fail_msg "配置不存在: $CONFIG"
  if is_hermes; then echo -e "  ${GRAY}请先运行: hermes setup / hermes model 生成配置${NC}"; fi
  exit 1
}

case "${1:-}" in
  ls|list)      list_all_models; exit ;;
  switch|sw)    cmd_switch; exit ;;
  sync)         cmd_sync; exit ;;
  test|check)   test_all_providers; exit ;;
  status|st)    "$GW" gateway status 2>/dev/null || "$GW" status; exit ;;
  restart|rs)   "$GW" gateway restart; exit ;;
  mode)         echo "$OCM_MODE"; exit 0 ;;
  help|-h|--help)
    gum style --bold "ocm v$VERSION — OpenClaw/Hermes Model Manager"
    echo ""
    echo "  用法: ocm [hermes|openclaw] [命令]   (默认 OpenClaw, 也可 OCM_MODE=hermes)"
    echo ""
    echo "  ocm              交互式菜单 (可选管理模式)"
    echo "  ocm hermes       进入 Hermes 模式主菜单"
    echo "  ocm ls           列出所有模型"
    echo "  ocm switch       快速切换 (fzf)"
    echo "  ocm sync         同步云端模型"
    echo "  ocm test         测试供应商连接"
    echo "  ocm status       网关状态"
    echo "  ocm restart      重启网关"
    echo "  ocm mode         显示当前模式"
    exit 0 ;;
  "") 
    if [ "$MODE_EXPLICIT" = "1" ]; then
      main_menu
    else
      mode_picker
      [ -f "$CONFIG" ] || { fail_msg "配置不存在: $CONFIG"; exit 1; }
      main_menu
    fi
    ;;
  *) fail_msg "未知: $1 (ocm help)"; exit 1 ;;
esac

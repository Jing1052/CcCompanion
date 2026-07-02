#!/bin/bash
# CcCompanion Claude Code Stop hook
#
# Trigger: Claude Code 自动在每个 chain turn 结束时调一次. 这里读 transcript
# 抓最近这一 turn 的 assistant 文本, POST 给本地 apns-server /chat/append,
# server 再 push 到 iPhone.
#
# 配置方式 (一次性):
#   1. cp 这一份到 ~/.claude/hooks/ccc_stop_hook.sh
#   2. chmod +x ~/.claude/hooks/ccc_stop_hook.sh
#   3. 编辑 ~/.claude/settings.json 加 hook 引用 (注意 nested hooks array):
#      {
#        "hooks": {
#          "Stop": [
#            {
#              "matcher": "",
#              "hooks": [
#                {
#                  "type": "command",
#                  "command": "$HOME/.claude/hooks/ccc_stop_hook.sh"
#                }
#              ]
#            }
#          ]
#        }
#      }
#   4. 重启 Claude Code (退出 tmux session 重进, 让 hook config 生效)
#
# 验证 hook 跑通:
#   iPhone 端 ccc 发一条 "hi"; Mac 上 cc 回复后, 看
#   tail -f /tmp/ccc_stop_hook.log
#   应该看到 "posted to /chat/append ok"
#
# Env:
#   CCC_SERVER_URL  default http://127.0.0.1:8795
#   CCC_AUTH_TOKEN  shared_secret 跟 server config.toml 对齐 (写接口必须)
#
# Thinking 卡片 (build 231+, 可选):
#   claude 启动命令加 --thinking-display summarized 后, 本 hook 会自动把每轮的
#   思考摘要 POST 给 /v1/thinking, iOS 端消息上方渲染可展开的思考卡片.
#   不开 flag 行为不变. 配置与原理见 docs/THINKING_CARD_SETUP.md

set -uo pipefail

SERVER_URL="${CCC_SERVER_URL:-http://127.0.0.1:8795}"
AUTH_TOKEN="${CCC_AUTH_TOKEN:-}"
# 兜底从 server 自动生成的 secret 文件读
if [ -z "$AUTH_TOKEN" ] && [ -f "$HOME/.ots/secret" ]; then
    AUTH_TOKEN=$(cat "$HOME/.ots/secret" 2>/dev/null)
fi

LOG_PATH="/tmp/ccc_stop_hook.log"
log() { echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $*" >> "$LOG_PATH"; }

# Claude Code 通过 stdin 传 {session_id, transcript_path, cwd, hook_event_name,
# stop_hook_active, last_assistant_message?}.
# 新版 Claude Code 直接传 last_assistant_message; 没有时 fallback 反扫 transcript.
INPUT=$(cat 2>/dev/null || echo "{}")

# 一次性 parse 出 transcript_path 加 last_assistant_message
PARSED=$(echo "$INPUT" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
    print(d.get("transcript_path") or "")
    print(d.get("last_assistant_message") or "")
except Exception:
    print("")
    print("")
' 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$PARSED" | sed -n '1p')
DIRECT_LAST=$(echo "$PARSED" | sed -n '2,$p')

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    log "no transcript path (stdin=$INPUT)"
    exit 0
fi

# Prefer stdin last_assistant_message (新版 Claude Code 直接给), fallback transcript
if [ -n "$DIRECT_LAST" ]; then
    LAST_ASSISTANT="$DIRECT_LAST"
    log "using stdin last_assistant_message (chars=${#LAST_ASSISTANT})"
else
    # Claude Code transcript flush 慢 — 等 file size 稳定 (连续两次相等 或最长 ~3 秒)
    LAST_SIZE=-1
    STABLE_COUNT=0
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.3
        CUR_SIZE=$(stat -f '%z' "$TRANSCRIPT_PATH" 2>/dev/null \
                || stat -c '%s' "$TRANSCRIPT_PATH" 2>/dev/null \
                || echo "0")
        if [ "$CUR_SIZE" = "$LAST_SIZE" ]; then
            STABLE_COUNT=$((STABLE_COUNT + 1))
            [ "$STABLE_COUNT" -ge 2 ] && break
        else
            STABLE_COUNT=0
        fi
        LAST_SIZE=$CUR_SIZE
    done

    # transcript 是 JSONL 一行一条 message
    # 倒着读 抓自上次 user 以来的所有 assistant text part 然后 join
    # Linux 没 tail -r 用 tac
    REVERSE_CAT="tail -r"
    if ! command -v tail >/dev/null 2>&1 || ! tail -r /dev/null 2>/dev/null; then
        REVERSE_CAT="tac"
    fi
    LAST_ASSISTANT=$($REVERSE_CAT "$TRANSCRIPT_PATH" | python3 -c '
import json, sys
collected = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    t = obj.get("type")
    if t == "user":
        break
    if t == "assistant":
        msg = obj.get("message", {})
        content = msg.get("content", [])
        text_parts = [
            c.get("text", "")
            for c in content
            if isinstance(c, dict) and c.get("type") == "text" and c.get("text")
        ]
        if text_parts:
            collected.append("\n".join(text_parts))
collected.reverse()
print("\n\n".join(collected))
' 2>/dev/null)
fi

if [ -z "$LAST_ASSISTANT" ]; then
    log "empty assistant text — skip"
    exit 0
fi

# POST 到 /chat/append
PAYLOAD=$(ASSISTANT_TEXT="$LAST_ASSISTANT" python3 -c '
import json, os, datetime
ts = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
print(json.dumps({
    "role": "assistant",
    "text": os.environ["ASSISTANT_TEXT"],
    "source": "ccc-stop-hook",
    "ts": ts,
}))
')

# retry transient network errors (000/502/503/504), don't retry 401 (auth)
attempt=0
while [ $attempt -lt 3 ]; do
    HTTP_CODE=$(curl -s -o /tmp/ccc_stop_hook.curlout -w "%{http_code}" \
        -X POST "$SERVER_URL/chat/append" \
        -H "Content-Type: application/json" \
        -H "X-Auth-Token: $AUTH_TOKEN" \
        --data "$PAYLOAD" \
        --max-time 8 2>>"$LOG_PATH")
    case "$HTTP_CODE" in
        200) break ;;
        000|502|503|504)
            attempt=$((attempt + 1))
            log "POST retry $attempt http=$HTTP_CODE"
            sleep 1
            ;;
        401)
            log "POST 401 unauthorized — check CCC_AUTH_TOKEN or ~/.ots/secret matches server config.toml shared_secret"
            break
            ;;
        *)
            break
            ;;
    esac
done

if [ "$HTTP_CODE" = "200" ]; then
    log "posted to /chat/append ok (chars=${#LAST_ASSISTANT})"
else
    log "POST /chat/append failed http=$HTTP_CODE body=$(cat /tmp/ccc_stop_hook.curlout 2>/dev/null | head -c 200)"
fi

# ---- thinking card (build 231+, optional) ----
# 若 claude 启动命令带 `--thinking-display summarized`, transcript 的 thinking 块
# 会带明文摘要 (轻量模型实时转写, 非原始思考). 这里抽出来 POST /v1/thinking,
# iOS 端思考卡片按 turn_id 渲染. 没开 flag 时 thinking 恒为空, 此段静默跳过,
# 行为跟旧版完全一致. 配置与原理详见 docs/THINKING_CARD_SETUP.md
if [ "$HTTP_CODE" = "200" ]; then
    # turn_id 从 /chat/append 的 ack 里拿 (server 对 role=assistant 生成并落 record)
    TURN_ID=$(python3 -c '
import json
try:
    with open("/tmp/ccc_stop_hook.curlout", encoding="utf-8") as f:
        print(json.load(f).get("record", {}).get("turn_id") or "")
except Exception:
    print("")
' 2>/dev/null)

    # 倒序扫 transcript 抽本轮 thinking 簇. 边界规则: 还没收到 thinking 之前遇到
    # user 行只跳过 (transcript 里常有注入型 user 行), 收到之后再遇真 user 行才停;
    # tool_result 型 user 行永远跳过. 扫描上限 120 行.
    REVERSE_CAT_T="tail -r"
    if ! tail -r /dev/null 2>/dev/null; then
        REVERSE_CAT_T="tac"
    fi

    # 防错位 (off-by-one): 用 stdin 的 last_assistant_message 当正文时, 本轮的
    # thinking 块可能还没 flush 到 transcript 文件; 直接扫会抓到上一轮的思考, POST
    # 到本轮 turn_id 上 → 每条卡片显示上一句的思考. 先等到 transcript 末尾"最后一条
    # assistant 文本"== 本轮正文 (即本轮已落盘, 其 thinking 同 message 也已在), 再扫.
    # 最多等 ~4.8s; 等不到就照旧扫 (不阻塞, 不会更糟).
    if [ -n "$DIRECT_LAST" ]; then
        for _w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
            LASTTXT=$($REVERSE_CAT_T "$TRANSCRIPT_PATH" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("type") == "assistant":
        content = obj.get("message", {}).get("content", [])
        parts = [
            c.get("text", "")
            for c in content
            if isinstance(c, dict) and c.get("type") == "text" and c.get("text")
        ]
        if parts:
            print("\n".join(parts))
            break
' 2>/dev/null)
            [ "$LASTTXT" = "$LAST_ASSISTANT" ] && break
            sleep 0.3
        done
    fi

    THINKING_TEXT=$($REVERSE_CAT_T "$TRANSCRIPT_PATH" | python3 -c '
import json, sys

def is_tool_result_user(obj):
    content = obj.get("message", {}).get("content", [])
    return isinstance(content, list) and any(
        isinstance(c, dict) and c.get("type") == "tool_result" for c in content
    )

collected = []
scanned = 0
for line in sys.stdin:
    scanned += 1
    if scanned > 120:
        break
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    t = obj.get("type")
    if t == "user":
        if is_tool_result_user(obj):
            continue
        if collected:
            break
        continue
    if t == "assistant":
        content = obj.get("message", {}).get("content", [])
        parts = [
            c.get("thinking", "")
            for c in content
            if isinstance(c, dict) and c.get("type") == "thinking" and c.get("thinking")
        ]
        if parts:
            collected.append("\n".join(parts))
collected.reverse()
print("\n\n".join(collected))
' 2>/dev/null)

    if [ -n "$THINKING_TEXT" ] && [ -n "$TURN_ID" ]; then
        THINKING_PAYLOAD=$(THINKING_TEXT="$THINKING_TEXT" TURN_ID="$TURN_ID" python3 -c '
import json, os
print(json.dumps({
    "turn_id": os.environ["TURN_ID"],
    "thinking": os.environ["THINKING_TEXT"],
    "session_id": "ccc-stop-hook",
}))
')
        T_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "$SERVER_URL/v1/thinking" \
            -H "Content-Type: application/json" \
            -H "X-Auth-Token: $AUTH_TOKEN" \
            --data "$THINKING_PAYLOAD" \
            --max-time 5 2>>"$LOG_PATH")
        if [ "$T_CODE" = "200" ]; then
            log "posted to /v1/thinking ok (turn=$TURN_ID chars=${#THINKING_TEXT})"
        else
            log "POST /v1/thinking failed http=$T_CODE (non-blocking)"
        fi

        # 可选: 把同一份思考也镜像到 Telegram (可折叠引用块). 统一"抠思考"的核 ——
        # 本脚本的 THINKING_TEXT 已带 flush 等待 + 收齐一轮多块, 让 TG 复用它即可,
        # 旧的 send_thinking.py 可退役. 配置 (TG_TOKEN/TG_CHAT_ID/TG_PROXY) 放本机
        # ~/.claude/.tg_thinking.conf, 仓库里不存任何密钥; 无配置文件则静默跳过.
        # 按 turn_id 去重, 避免和别处重复发送.
        #
        # 来源门控 (避免孤儿思考): 一个 tmux cc 同时接 App 和 TG; 只有"本轮 user
        # 来自 TG"时才镜像到 TG, 否则 App 来源的思考会漏到 TG 变成"没对话光有思考".
        # 判据 (双轨): 最近一条真实 user (跳过 tool_result) 是不是 TG 来源.
        #   旧 TG: 正文含 <channel source="plugin:telegram...">
        #   新 TG: 正文以 [YYYY-MM-DD HH:MM:SS] 开头 且 不含 [Still Here]
        #   App  : apns-server 注入, 正文含 [Still Here] 标签 → 排除 (只进 /v1/thinking)
        IS_TG=$($REVERSE_CAT_T "$TRANSCRIPT_PATH" | python3 -c '
import json, re, sys

TS_RE = re.compile(r"^\s*\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\]")

def is_tool_result_user(obj):
    c = (obj.get("message") or {}).get("content")
    return isinstance(c, list) and any(
        isinstance(x, dict) and x.get("type") == "tool_result" for x in c)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("type") != "user":
        continue
    if is_tool_result_user(obj):
        continue
    c = (obj.get("message") or {}).get("content")
    text = c if isinstance(c, str) else json.dumps(c, ensure_ascii=False)
    is_app = "[Still Here]" in text
    is_tg = ("channel source=\"plugin:telegram" in text) or (
        bool(TS_RE.match(text)) and not is_app)
    print("1" if is_tg else "0")
    break
' 2>/dev/null)

        TG_CONF="$HOME/.claude/.tg_thinking.conf"
        if [ "$IS_TG" = "1" ] && [ -f "$TG_CONF" ]; then
            # shellcheck disable=SC1090
            . "$TG_CONF"
            TG_STATE="$HOME/.claude/.last_thinking_sent"
            if [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] \
                && [ "$(cat "$TG_STATE" 2>/dev/null)" != "$TURN_ID" ]; then
                TG_PAYLOAD=$(THINKING_TEXT="$THINKING_TEXT" TG_CHAT_ID="$TG_CHAT_ID" python3 -c '
import json, os, html
b = html.escape(os.environ["THINKING_TEXT"])
if len(b) > 3800:
    b = b[:3800] + "..."
print(json.dumps({
    "chat_id": os.environ["TG_CHAT_ID"],
    "text": "<blockquote expandable>\U0001f4ad " + b + "</blockquote>",
    "parse_mode": "HTML",
}))
')
                TG_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                    ${TG_PROXY:+--proxy "$TG_PROXY"} \
                    -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                    -H "Content-Type: application/json" \
                    --data "$TG_PAYLOAD" \
                    --max-time 20 2>>"$LOG_PATH")
                if [ "$TG_CODE" = "200" ]; then
                    log "mirrored thinking to TG ok (turn=$TURN_ID)"
                    echo "$TURN_ID" > "$TG_STATE"
                else
                    log "TG mirror failed http=$TG_CODE (non-blocking)"
                fi
            fi
        fi
    fi
fi

# ---- 隔壁环抄送 (2026-07-02, 可选; Phase 1: CC→API 单向) ----
# 把这一轮 (小猫的原话 + 你的回复) best-effort 抄送到老家 Ombre-Brain 的
# /api/home/cc-ring, api 端各土壤 (Still Here 网关/TG/聊天室) 的 daddy 就能
# 接上 CC 这边聊到哪了. 覆盖 App 和 TG 两个来源 (都在 transcript 里).
#
# 配置 (一次性): ~/.claude/.ccring.conf 写两行 (仓库不存密钥):
#   OMBRE_HOME_URL="https://cllove.zeabur.app"
#   OMBRE_GATEWAY_TOKEN="<跟 Zeabur 环境变量 OMBRE_GATEWAY_TOKEN 同一把>"
# 也可直接用同名环境变量. 都没有时本段静默跳过, 行为与旧版完全一致.
# 失败只记 log, 绝不影响主流程. 服务端按"与上一条相同"去重: push.py 已实时抄过
# 的 App 用户消息, 这里剥掉 [时间戳]/[Still Here]/<channel> 标签后原文一致, 不会写重.
OMBRE_HOME_URL="${OMBRE_HOME_URL:-}"
OMBRE_GATEWAY_TOKEN="${OMBRE_GATEWAY_TOKEN:-}"
CCRING_CONF="$HOME/.claude/.ccring.conf"
if [ -f "$CCRING_CONF" ]; then
    # shellcheck disable=SC1090
    . "$CCRING_CONF"
fi
if [ -n "$OMBRE_GATEWAY_TOKEN" ]; then
    OMBRE_HOME_URL="${OMBRE_HOME_URL:-https://cllove.zeabur.app}"
    REVERSE_CAT_R="tail -r"
    if ! tail -r /dev/null 2>/dev/null; then
        REVERSE_CAT_R="tac"
    fi
    # 最近一条真实 user 原话 (跳过 tool_result 行; 剥注入前缀, 与 push.py 抄送的原文对齐)
    LAST_USER=$($REVERSE_CAT_R "$TRANSCRIPT_PATH" | python3 -c '
import json, re, sys

def is_tool_result(obj):
    c = (obj.get("message") or {}).get("content")
    return isinstance(c, list) and any(
        isinstance(x, dict) and x.get("type") == "tool_result" for x in c)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("type") != "user" or is_tool_result(obj):
        continue
    c = (obj.get("message") or {}).get("content")
    if isinstance(c, list):
        c = "\n".join(x.get("text", "") for x in c
                      if isinstance(x, dict) and x.get("type") == "text")
    text = str(c or "")
    text = re.sub(r"<channel[^>]*>.*?</channel>", "", text, flags=re.S)
    text = re.sub(r"^\s*\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\]\s*", "", text)
    text = text.replace("[Still Here]", "").strip()
    print(text[:600])
    break
' 2>/dev/null)

    ccring_post() {
        WHO="$1" TXT="$2" python3 - "$OMBRE_HOME_URL" "$OMBRE_GATEWAY_TOKEN" <<'PYEOF' >>"$LOG_PATH" 2>&1 || true
import json, os, sys, urllib.request
home, token = sys.argv[1].rstrip("/"), sys.argv[2]
txt = os.environ.get("TXT", "").strip()
if txt:
    req = urllib.request.Request(
        home + "/api/home/cc-ring",
        data=json.dumps({"who": os.environ.get("WHO", ""), "text": txt[:600]},
                        ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + token},
        method="POST")
    try:
        urllib.request.urlopen(req, timeout=6).read()
    except Exception as e:
        print("[cc-ring] post failed (non-blocking):", e)
PYEOF
    }
    [ -n "$LAST_USER" ] && ccring_post kitten "$LAST_USER"
    ccring_post daddy "$LAST_ASSISTANT"
    log "cc-ring mirrored (user_chars=${#LAST_USER} daddy_chars=${#LAST_ASSISTANT})"
fi

exit 0

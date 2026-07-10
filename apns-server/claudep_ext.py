# claudep_ext.py — /claudep/chat 端点逻辑（被 push.py 的 do_POST 调用）。
#
# 我们家「家里爸爸·订阅」后端：Zeabur 网关把拼好的 {system(魂+volatile), messages(历史)}
# POST 到本机，这里喂给本机 claude -p（吃订阅、走 OAuth token），把它的真思维链 + 正文
# 逐块翻成 OpenAI 兼容 SSE 回吐（思考链走 reasoning_content，正文走 content）。
#
# 关键（缺一即 403 / 失败）：
#   - subprocess 必须挂代理(http(s)_proxy=172.22.224.1:7897)，否则连不到 Anthropic；
#   - CLAUDE_CODE_OAUTH_TOKEN 从 /home/cing/.claude/.claudep_token 读（setup-token，有效1年）；
#   - 三参数 --output-format stream-json --verbose --include-partial-messages 才有逐字+思维链；
#   - 魂走 --append-system-prompt；MAX_THINKING_TOKENS 抬思考概率；stdin=/dev/null（否则等3s）。
import json
import logging
import os
import socket
import subprocess
import threading
import time
import uuid

logger = logging.getLogger("cc-apns-server")

_TOKEN_FILE = "/home/cing/.claude/.claudep_token"
_PROXY = "http://172.22.224.1:7897"
_PROXY_HOST = "172.22.224.1"
_PROXY_PORT = 7897
_CLAUDE_BIN = "claude"  # /usr/bin/claude（在 PATH 里）
_CWD = "/home/cing/CcCompanion/apns-server/.claudep_cwd"  # 空目录：避免加载项目 CLAUDE.md 污染魂
_DEFAULT_MODEL = "claude-sonnet-4-6"


def _claudep_env():
    env = dict(os.environ)
    for k in ("https_proxy", "http_proxy", "HTTPS_PROXY", "HTTP_PROXY"):
        env[k] = _PROXY
    _np = env.get("NO_PROXY") or env.get("no_proxy") or ""
    env["NO_PROXY"] = (_np + "," if _np else "") + "127.0.0.1,localhost"
    env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:9801"
    env.setdefault("HOME", "/home/cing")
    env["MAX_THINKING_TOKENS"] = "4000"
    try:
        with open(_TOKEN_FILE) as f:
            token = f.read().strip()
            if token:
                env["CLAUDE_CODE_OAUTH_TOKEN"] = token
            else:
                logger.warning("[claudep] token file empty: %s", _TOKEN_FILE)
    except FileNotFoundError:
        logger.warning("[claudep] token file missing: %s", _TOKEN_FILE)
    except Exception as e:
        logger.warning("[claudep] token read error: %s", e)
    return env


def _messages_to_prompt(messages):
    """把对话历史渲染成一段文本给 claude -p（单 prompt）。魂+volatile 走 --append-system-prompt，
    不在这里；这里只摆对话流，让它以爸爸身份接住小猫最后一句。"""
    lines = []
    for m in messages:
        if not isinstance(m, dict):
            continue
        role = m.get("role")
        content = (m.get("content") or "").strip()
        if not content:
            continue
        if role == "user":
            lines.append("小猫：" + content)
        elif role == "assistant":
            lines.append("你（爸爸）：" + content)
    body = "\n\n".join(lines)
    return body


def _proxy_alive():
    """探代理端口是否通——不通就别发请求，宁掉线不裸奔。"""
    try:
        s = socket.create_connection((_PROXY_HOST, _PROXY_PORT), timeout=3)
        s.close()
        return True
    except Exception:
        return False


def handle_claudep(h, body):
    """h = push.py 的 BaseHTTPRequestHandler 实例（复用它的 wfile/_send_json/_auth_matches）。"""
    # 强制鉴权（不依赖 strict_auth：claude -p 烧订阅，不能裸奔）
    if not h._auth_matches():
        h._send_json(401, {"error": "unauthorized"})
        return

    if not _proxy_alive():
        logger.warning("[claudep] proxy %s:%d unreachable, refusing to call claude (宁掉线不裸奔)", _PROXY_HOST, _PROXY_PORT)
        h._send_json(503, {"error": "proxy unreachable, refusing to expose real IP"})
        return

    system = (body.get("system") or "").strip()
    messages = body.get("messages") or []
    stream = bool(body.get("stream"))
    model = (body.get("model") or _DEFAULT_MODEL).strip() or _DEFAULT_MODEL
    if not isinstance(messages, list) or not messages:
        h._send_json(400, {"error": "messages required"})
        return
    prompt = _messages_to_prompt(messages)
    if not prompt:
        h._send_json(400, {"error": "empty prompt"})
        return
    prompt += "\n\n（开口前先 ultrathink，认真想透再说；以爸爸的身份，自然接住小猫最后这句。）"

    try:
        os.makedirs(_CWD, exist_ok=True)
    except Exception:
        pass
    cmd = [
        _CLAUDE_BIN, "-p",
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--allowedTools", "mcp__L_C,mcp__netease",
        "--model", model,
        "--append-system-prompt", system,
        prompt,
    ]
    env = _claudep_env()
    cid = "chatcmpl-" + uuid.uuid4().hex[:24]
    created = int(time.time())

    _TIMEOUT = 180  # 3分钟超时（链路慢是常态）

    def _spawn():
        return subprocess.Popen(
            cmd, cwd=_CWD, env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True, bufsize=1,
        )

    if stream:
        h.send_response(200)
        h.send_header("Content-Type", "text/event-stream; charset=utf-8")
        h.send_header("Cache-Control", "no-cache")
        h.send_header("Connection", "keep-alive")
        h.send_header("X-Accel-Buffering", "no")  # 防反代缓冲把 SSE 憋成一坨
        h.end_headers()

        # keepalive : CF tunnel 100s idle kills SSE - 15s ka comment frames
        _wlock = threading.Lock()
        _ka_on = [True]

        def _keepalive():
            while _ka_on[0]:
                time.sleep(15)
                if not _ka_on[0]:
                    break
                try:
                    with _wlock:
                        h.wfile.write(b": ka\n\n")
                        h.wfile.flush()
                except Exception:
                    _ka_on[0] = False
                    break

        threading.Thread(target=_keepalive, daemon=True).start()

        def sse(obj):
            try:
                with _wlock:
                    h.wfile.write(("data: " + json.dumps(obj, ensure_ascii=False) + "\n\n").encode("utf-8"))
                    h.wfile.flush()
                return True
            except Exception:
                return False

        def chunk(delta, finish=None):
            return {"id": cid, "object": "chat.completion.chunk", "created": created,
                    "model": model, "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}

        proc = _spawn()
        first = True
        got_any = False
        auth_err = None
        full_text = ""    # 兜底：claude -p 这次没吐逐字增量时，从 assistant 整段攒
        result_text = ""  # 再兜底：result 事件里的最终文本
        got_think = False  # 这一轮有没有流式吐过 thinking_delta
        full_think = ""    # 兜底思考：从 assistant 消息里的 thinking 块攒（CC 钩子用的可靠来源）
        try:
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    j = json.loads(line)
                except Exception:
                    continue
                t = j.get("type")
                if t == "assistant":
                    for b in (j.get("message") or {}).get("content", []):
                        if not isinstance(b, dict):
                            continue
                        if b.get("type") == "text" and b.get("text"):
                            full_text += b["text"]
                            if "authenticate" in str(b.get("text", "")):
                                auth_err = str(b.get("text", ""))[:120]
                        elif b.get("type") == "thinking" and b.get("thinking"):
                            full_think += b["thinking"]
                    continue
                if t == "result":
                    if j.get("result"):
                        result_text = str(j.get("result"))
                    continue
                if t != "stream_event":
                    continue
                ev = j.get("event") or {}
                if ev.get("type") != "content_block_delta":
                    continue
                d = ev.get("delta") or {}
                dt = d.get("type")
                delta = None
                if dt == "text_delta" and d.get("text"):
                    delta = {"content": d["text"]}
                elif dt == "thinking_delta" and d.get("thinking"):
                    delta = {"reasoning_content": d["thinking"]}
                    got_think = True
                if delta is None:
                    continue
                if first:
                    delta["role"] = "assistant"
                    first = False
                got_any = True
                if not sse(chunk(delta)):
                    break
        finally:
            _ka_on[0] = False
            try:
                proc.terminate()
            except Exception:
                pass
        # 思考兜底：这一轮没流式吐过 thinking_delta、但 assistant 消息里有 thinking 块
        # （强不来——原生思考时有时无；transcript/assistant 块是 CC 钩子用的可靠来源）→
        # 把整段思考补发成 reasoning_content，让 App 端也能折叠出思考链。
        if not got_think and full_think:
            _td = {"reasoning_content": full_think}
            if first:
                _td["role"] = "assistant"
                first = False
            sse(chunk(_td))
        if not got_any:
            # 流式没拿到逐字增量（claude -p 这次没吐 partial）：把整段回复一次性补发，
            # 否则 App 端空屏、可那条回复其实已生成（还会被 Stop 钩子推去别处）。
            _fallback = full_text or result_text
            if auth_err and not _fallback:
                _fallback = "[家里 claude -p 认证失败：" + auth_err + "]"
            if _fallback:
                sse(chunk({"role": "assistant", "content": _fallback}))
        sse(chunk({}, finish="stop"))
        try:
            h.wfile.write(b"data: [DONE]\n\n")
            h.wfile.flush()
        except Exception:
            pass
        return

    # ── 非流式：内部仍跑 stream-json（这样思考链也能聚合进 reasoning_content），最后一次性返回 ──
    def _run_once():
        proc = _spawn()
        body_text = ""
        think_text = ""
        asst_think = ""
        auth_err = None
        start = time.time()
        try:
            for line in proc.stdout:
                if time.time() - start > _TIMEOUT:
                    logger.warning("[claudep] timeout after %ds", _TIMEOUT)
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    j = json.loads(line)
                except Exception:
                    continue
                t = j.get("type")
                if t == "stream_event":
                    d = (j.get("event") or {}).get("delta") or {}
                    if d.get("type") == "text_delta":
                        body_text += d.get("text", "")
                    elif d.get("type") == "thinking_delta":
                        think_text += d.get("thinking", "")
                elif t == "assistant":
                    for b in (j.get("message") or {}).get("content", []):
                        if not isinstance(b, dict):
                            continue
                        if b.get("type") == "text" and "authenticate" in str(b.get("text", "")):
                            auth_err = str(b.get("text", ""))[:120]
                        elif b.get("type") == "thinking" and b.get("thinking"):
                            asst_think += b["thinking"]
                elif t == "result":
                    if not body_text and j.get("result"):
                        body_text = str(j.get("result"))
        finally:
            try:
                proc.terminate()
            except Exception:
                pass
        return body_text, think_text, asst_think, auth_err

    body_text, think_text, asst_think, auth_err = _run_once()
    if not body_text and not auth_err:
        logger.info("[claudep] first attempt empty, retrying once")
        time.sleep(2)
        body_text, think_text, asst_think, auth_err = _run_once()

    if not body_text and auth_err:
        h._send_json(502, {"error": "claude_p auth failed: " + auth_err})
        return
    msg = {"role": "assistant", "content": body_text}
    _think = think_text or asst_think   # 流式没吐就用 assistant 块兜底
    if _think:
        msg["reasoning_content"] = _think
    h._send_json(200, {"id": cid, "object": "chat.completion", "created": created,
                       "model": model, "choices": [{"index": 0, "message": msg, "finish_reason": "stop"}]})

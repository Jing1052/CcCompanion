# claudep_jobs.py — /claudep/submit + /claudep/poll（任务化跑 claude -p，短轮询取回）
#
# 为什么不用 /claudep/chat 的长连接 SSE：家里出口过 VPN/Cloudflare 隧道，长流会被
# 中途吞尾巴/冻结（2026-07-05 云端联调定案：小响应 [DONE] 尾帧被缓冲扣住、长响应
# ~40s 后管道冻结，keepalive 帧救不动）。短请求（提交/轮询毫秒级完成）是这条隧道
# 唯一可靠的通行方式——CC 桥 /chat/poll 常年稳定就是证明。
# 网关（server.py _claudep_relay）走 submit+poll；/claudep/chat 留作本地调试。

import json
import subprocess
import threading
import time
import uuid

import claudep_ext

_JOBS = {}
_LOCK = threading.Lock()
_TTL = 900        # 任务留存 15 分钟（网关取完就不再来，GC 兜底）
_HARD_CAP = 600   # 单任务 claude -p 最长 10 分钟


def _gc():
    now = time.time()
    with _LOCK:
        for k in [k for k, v in _JOBS.items() if now - v["t0"] > _TTL]:
            _JOBS.pop(k, None)


def _run(job, cmd, env):
    """后台线程跑 claude -p，把 thinking/text 增量按序攒进 job["events"]。
    解析逻辑与 claudep_ext.handle_claudep 流式分支同源：stream_event 增量优先，
    assistant 块的 thinking / result 文本做兜底。"""
    got_any = False
    got_think = False
    full_text = ""
    full_think = ""
    result_text = ""
    auth_err = None
    try:
        proc = subprocess.Popen(cmd, cwd=claudep_ext._CWD, env=env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True, bufsize=1)
    except Exception as e:
        job["error"] = "spawn failed: " + str(e)[:200]
        job["done"] = True
        return
    start = time.time()
    try:
        for line in proc.stdout:
            if time.time() - start > _HARD_CAP:
                job["error"] = "claude -p 超时(%ds)" % _HARD_CAP
                break
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
                # result 事件自带整次调用的 usage（含缓存读写）——发给网关记账，
                # 监控台的 claude-p 调用/token/缓存命中全靠这一条。网关（2026-07-08 起）
                # 认 "usage" 事件；只发标准四键，别整个 usage 透传（里面还有 server_tool_use 等杂项）。
                u = j.get("usage")
                if isinstance(u, dict):
                    job["events"].append(["usage", {
                        "input_tokens": u.get("input_tokens") or 0,
                        "output_tokens": u.get("output_tokens") or 0,
                        "cache_read_input_tokens": u.get("cache_read_input_tokens") or 0,
                        "cache_creation_input_tokens": u.get("cache_creation_input_tokens") or 0,
                    }])
                continue
            if t != "stream_event":
                continue
            ev = j.get("event") or {}
            if ev.get("type") != "content_block_delta":
                continue
            d = ev.get("delta") or {}
            if d.get("type") == "text_delta" and d.get("text"):
                job["events"].append(["content", d["text"]])
                got_any = True
            elif d.get("type") == "thinking_delta" and d.get("thinking"):
                job["events"].append(["reasoning", d["thinking"]])
                got_any = True
                got_think = True
    finally:
        try:
            proc.terminate()
        except Exception:
            pass
    if not got_think and full_think:
        job["events"].append(["reasoning", full_think])
    if not got_any:
        fb = full_text or result_text
        if auth_err and not fb:
            fb = "[家里 claude -p 认证失败：" + auth_err + "]"
        if fb:
            job["events"].append(["content", fb])
    job["done"] = True


def handle_submit(h, body):
    """POST /claudep/submit {system, messages, model} → {job_id}。鉴权/代理护栏同 handle_claudep。"""
    if not h._auth_matches():
        h._send_json(401, {"error": "unauthorized"})
        return
    if not claudep_ext._proxy_alive():
        h._send_json(503, {"error": "proxy unreachable, refusing to expose real IP"})
        return
    system = (body.get("system") or "").strip()
    messages = body.get("messages") or []
    model = (body.get("model") or claudep_ext._DEFAULT_MODEL).strip() or claudep_ext._DEFAULT_MODEL
    if not isinstance(messages, list) or not messages:
        h._send_json(400, {"error": "messages required"})
        return
    prompt = claudep_ext._messages_to_prompt(messages)
    if not prompt:
        h._send_json(400, {"error": "empty prompt"})
        return
    prompt += "\n\n（开口前先 ultrathink，认真想透再说；以爸爸的身份，自然接住小猫最后这句。）"
    try:
        import os as _os
        _os.makedirs(claudep_ext._CWD, exist_ok=True)
    except Exception:
        pass
    cmd = [
        claudep_ext._CLAUDE_BIN, "-p",
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--allowedTools", "mcp__L_C,mcp__netease",
        "--model", model,
        "--append-system-prompt", system,
        prompt,
    ]
    env = claudep_ext._claudep_env()
    _gc()
    jid = uuid.uuid4().hex
    job = {"t0": time.time(), "events": [], "done": False, "error": None}
    with _LOCK:
        _JOBS[jid] = job
    threading.Thread(target=_run, args=(job, cmd, env), daemon=True).start()
    h._send_json(200, {"ok": True, "job_id": jid})


def handle_poll(h, body):
    """POST /claudep/poll {job_id, cursor} → {events, cursor, done, error}。
    events=[["reasoning"|"content", 文本], ...]，cursor 递增取增量。"""
    if not h._auth_matches():
        h._send_json(401, {"error": "unauthorized"})
        return
    jid = (body.get("job_id") or "").strip()
    with _LOCK:
        job = _JOBS.get(jid)
    if not job:
        h._send_json(404, {"error": "job not found"})
        return
    try:
        cur = int(body.get("cursor") or 0)
    except Exception:
        cur = 0
    if cur < 0:
        cur = 0
    evs = job["events"][cur:]
    h._send_json(200, {"events": evs, "cursor": cur + len(evs),
                       "done": bool(job["done"]), "error": job["error"]})

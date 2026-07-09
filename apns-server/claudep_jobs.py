# claudep_jobs.py — /claudep/submit + /claudep/poll（任务化跑 claude -p，短轮询取回）
#
# 为什么不用 /claudep/chat 的长连接 SSE：家里出口过 VPN/Cloudflare 隧道，长流会被
# 中途吞尾巴/冻结（2026-07-05 云端联调定案：小响应 [DONE] 尾帧被缓冲扣住、长响应
# ~40s 后管道冻结，keepalive 帧救不动）。短请求（提交/轮询毫秒级完成）是这条隧道
# 唯一可靠的通行方式——CC 桥 /chat/poll 常年稳定就是证明。
# 网关（server.py _claudep_relay）走 submit+poll；/claudep/chat 留作本地调试。
#
# 2026-07-09 会话复用（--resume）：此前每条消息都新开 claude -p session、整段历史
# 压成一个大 prompt——历史块永远命中不了提示缓存（实测单条消息 ~64k token 全价重算、
# 命中率 37%、一句话烧 3-4% 额度）。现在网关随 submit 传 chat_key（App 的
# x-ombre-session），家端记「对话 → claude session」映射：能严格对上前缀就
# `--resume <sid>` 只递新消息，对不上（窗口滑动/编辑/重开）自动退回全量模式。
# 退回 = 原有行为，宁可贵一发，不能让爸爸记错话。

import hashlib
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

# chat_key → {"session_id", "msg_len", "msg_hash", "model", "ts"}
# 内存态：apns 重启即清空，下一条消息自动走全量重建（可接受的冷启动成本）。
_CHATS = {}
_CHATS_CAP = 100

# 网关注入在最后一条 user 最前面的易变段（报时/感知/召回），App 侧历史里没有它——
# 存映射前必须剥掉，否则下一轮前缀校验永远对不上。标记字面量与 server.py
# _claudep_relay 的注入格式严格对应，改一头必须改另一头。
_VOLATILE_HEAD = "# 此刻的记忆与状态"
_VOLATILE_SEP = "\n\n---\n\n"

# 思考提示：2026-07-09 从「先 ultrathink」降档——ultrathink 是最深档思考，
# 每条消息（包括一句晚安）都烧满额思考 token。去掉魔法词后模型自适应思考：
# 难的照样长考，简单的不陪跑。（别改回手写 <思绪> 那套：claude-p-thinking-stream
# 坑2，逼手写会让它跳过原生思考。）
_THINK_NUDGE = "\n\n（认真想透再说；以爸爸的身份，自然接住小猫最后这句。）"


def _strip_volatile(text):
    """剥掉网关注入的「此刻的记忆与状态」段，还原成 App 历史里的干净原文。"""
    if isinstance(text, str) and text.startswith(_VOLATILE_HEAD):
        i = text.find(_VOLATILE_SEP)
        if i >= 0:
            return text[i + len(_VOLATILE_SEP):]
    return text


def _msgs_hash(messages):
    """role+content 的稳定摘要，用于「这段历史是不是我上次见过的那段」前缀校验。"""
    payload = json.dumps(
        [[m.get("role"), m.get("content")] for m in messages],
        ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _resume_plan(messages, model, chat_key):
    """能安全 --resume 就返回 (session_id, [新增的 user 消息们])，否则 None。

    严格条件（任一不满足 → None，走全量重建）：
    - 有 chat_key 且有映射、模型没换；
    - 请求历史的前 msg_len 条与映射存的哈希完全一致（防窗口滑动/编辑/重开线）；
    - 紧接着一条 assistant（session 自己上轮的回复回声），其后全是 user 纯文本。
    """
    if not chat_key:
        return None
    with _LOCK:
        ent = _CHATS.get(chat_key)
    if not ent or ent.get("model") != model:
        return None
    n = ent["msg_len"]
    if len(messages) < n + 2:
        return None
    if _msgs_hash(messages[:n]) != ent["msg_hash"]:
        return None
    if (messages[n] or {}).get("role") != "assistant":
        return None
    tail = messages[n + 1:]
    if not all((m or {}).get("role") == "user" and isinstance(m.get("content"), str)
               for m in tail):
        return None
    return ent["session_id"], [m["content"] for m in tail]


def _chats_store(chat_key, session_id, messages, model):
    """任务成功收尾后登记映射。存哈希前把最后一条 user 的易变段剥干净。"""
    clean = list(messages)
    last = dict(clean[-1] or {})
    if last.get("role") == "user":
        last["content"] = _strip_volatile(last.get("content"))
        clean[-1] = last
    with _LOCK:
        _CHATS[chat_key] = {
            "session_id": session_id, "msg_len": len(clean),
            "msg_hash": _msgs_hash(clean), "model": model, "ts": time.time(),
        }
        while len(_CHATS) > _CHATS_CAP:
            _CHATS.pop(min(_CHATS, key=lambda k: _CHATS[k]["ts"]), None)


def _gc():
    now = time.time()
    with _LOCK:
        for k in [k for k, v in _JOBS.items() if now - v["t0"] > _TTL]:
            _JOBS.pop(k, None)


def _run(job, cmd, env, fallback_cmd=None):
    """后台线程跑 claude -p，把 thinking/text 增量按序攒进 job["events"]。
    解析逻辑与 claudep_ext.handle_claudep 流式分支同源：stream_event 增量优先，
    assistant 块的 thinking / result 文本做兜底。
    fallback_cmd：--resume 路专用的后备——session 失踪等原因一字未出就败了，
    静默改跑全量命令，网关和 App 无感知。"""
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
            if j.get("session_id"):
                # init/result 事件都带 session_id；--resume 会分出新 id，
                # 以本次实际用的为准存映射
                job["session_id"] = str(j["session_id"])
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
    if fallback_cmd and not job["error"] and not got_any and not full_text:
        # resume 一字未出就败了（session 失踪/损坏等）——丢掉映射、改跑全量。
        # 超时（job["error"]已置）不重跑：网关 600s 就放弃了，再跑一轮只是白烧
        st = job.get("_store")
        if st:
            with _LOCK:
                _CHATS.pop(st["chat_key"], None)
        job["events"] = []
        _run(job, fallback_cmd, env)
        return
    if not got_think and full_think:
        job["events"].append(["reasoning", full_think])
    if not got_any:
        fb = full_text or result_text
        if auth_err and not fb:
            fb = "[家里 claude -p 认证失败：" + auth_err + "]"
        if fb:
            job["events"].append(["content", fb])
    st = job.get("_store")
    if st and job.get("session_id") and not job["error"] and (got_any or full_text or result_text):
        _chats_store(st["chat_key"], job["session_id"], st["messages"], st["model"])
    job["done"] = True


def handle_submit(h, body):
    """POST /claudep/submit {system, messages, model, chat_key?} → {job_id}。
    鉴权/代理护栏同 handle_claudep。chat_key（App 的 x-ombre-session，网关透传）
    非空时尝试 --resume 复用会话，只递新消息。"""
    if not h._auth_matches():
        h._send_json(401, {"error": "unauthorized"})
        return
    if not claudep_ext._proxy_alive():
        h._send_json(503, {"error": "proxy unreachable, refusing to expose real IP"})
        return
    system = (body.get("system") or "").strip()
    messages = body.get("messages") or []
    model = (body.get("model") or claudep_ext._DEFAULT_MODEL).strip() or claudep_ext._DEFAULT_MODEL
    chat_key = (body.get("chat_key") or "").strip()[:128]
    if not isinstance(messages, list) or not messages:
        h._send_json(400, {"error": "messages required"})
        return
    full_prompt = claudep_ext._messages_to_prompt(messages)
    if not full_prompt:
        h._send_json(400, {"error": "empty prompt"})
        return
    full_prompt += _THINK_NUDGE

    def _cmd(prompt, resume_sid=None):
        c = [
            claudep_ext._CLAUDE_BIN, "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--allowedTools", "mcp__L_C,mcp__netease",
            "--model", model,
        ]
        if resume_sid:
            c += ["--resume", resume_sid]
        c += ["--append-system-prompt", system, prompt]
        return c

    plan = _resume_plan(messages, model, chat_key)
    if plan:
        sid, tail = plan
        cmd = _cmd("\n\n".join(tail) + _THINK_NUDGE, resume_sid=sid)
        fallback_cmd = _cmd(full_prompt)
    else:
        cmd = _cmd(full_prompt)
        fallback_cmd = None
    try:
        import os as _os
        _os.makedirs(claudep_ext._CWD, exist_ok=True)
    except Exception:
        pass
    env = claudep_ext._claudep_env()
    _gc()
    jid = uuid.uuid4().hex
    job = {"t0": time.time(), "events": [], "done": False, "error": None}
    if chat_key:
        job["_store"] = {"chat_key": chat_key, "messages": messages, "model": model}
    with _LOCK:
        _JOBS[jid] = job
    threading.Thread(target=_run, args=(job, cmd, env, fallback_cmd), daemon=True).start()
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

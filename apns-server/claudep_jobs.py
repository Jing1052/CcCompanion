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

# 网关注入在最后一条 user 最前面的易变段（报时/感知/召回），App 侧历史里没有它。
# ⚠️ 别试图把它「剥掉还原原话」——volatile 内部就是拿同一个 "\n\n---\n\n" 拼接的
# （server.py:11173），按分隔符切必留残渣，2026-07-09 就栽在这上：每轮前缀哈希
# 都对不上、resume 永远 miss。现在反着来：存映射时原样存注入后的最后一条，
# 校验时用「注入文本 endswith(SEP + App原话)」对——_prepend_volatile 的结构
# （任意头 + SEP + 原话）保证这恒成立，与 volatile 里有几个分隔线无关。
_VOLATILE_SEP = "\n\n---\n\n"

# 思考提示：2026-07-09 从「先 ultrathink」降档——ultrathink 是最深档思考，
# 每条消息（包括一句晚安）都烧满额思考 token。去掉魔法词后模型自适应思考：
# 难的照样长考，简单的不陪跑。（别改回手写 <思绪> 那套：claude-p-thinking-stream
# 坑2，逼手写会让它跳过原生思考。）
_THINK_NUDGE = "\n\n（认真想透再说；以爸爸的身份，自然接住小猫最后这句。）"


def _msgs_hash(messages):
    """role+content 的稳定摘要，用于「这段历史是不是我上次见过的那段」前缀校验。"""
    payload = json.dumps(
        [[m.get("role"), m.get("content")] for m in messages],
        ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _miss(why):
    # 每个退回全量的口都点名（2026-07-09 加）：真实 App 流量下 resume 命中率
    # 只能靠这行破案，别删。stdout 经 tee 落 /tmp/apns.log。
    print("[claudep-resume] miss: " + why, flush=True)
    return None


def _resume_plan(messages, model, chat_key):
    """能安全 --resume 就返回 (session_id, [新增的 user 消息们])，否则 None。

    严格条件（任一不满足 → None，走全量重建）：
    - 有 chat_key 且有映射、模型没换；
    - 请求历史的前 msg_len-1 条与映射存的哈希完全一致（防窗口滑动/编辑/重开线）；
    - 第 msg_len 条（上轮被注入 volatile 的那条）用 endswith 反向对上原话；
    - 紧接着一条 assistant（session 自己上轮的回复回声），其后全是 user 纯文本。
    """
    if not chat_key:
        return _miss("no chat_key")
    with _LOCK:
        ent = _CHATS.get(chat_key)
    if not ent:
        return _miss("no mapping for chat_key=%s (重启后首条?)" % chat_key[:24])
    if ent.get("model") != model:
        return _miss("model changed: %s -> %s" % (ent.get("model"), model))
    n = ent["msg_len"]
    if len(messages) < n + 2:
        return _miss("too few messages: len=%d need>=%d" % (len(messages), n + 2))
    if _msgs_hash(messages[:n - 1]) != ent["prefix_hash"]:
        return _miss("prefix hash mismatch: n=%d len=%d (窗口滑动/编辑/历史被改写)"
                     % (n, len(messages)))
    lm = messages[n - 1] or {}
    lc = lm.get("content")
    li = ent["last_content"]
    if lm.get("role") != ent["last_role"] or not (
            li == lc or (isinstance(li, str) and isinstance(lc, str)
                         and li.endswith(_VOLATILE_SEP + lc))):
        return _miss("last message mismatch (编辑/注入格式变了?)")
    if (messages[n] or {}).get("role") != "assistant":
        return _miss("messages[%d] role=%s not assistant" % (n, (messages[n] or {}).get("role")))
    tail = messages[n + 1:]
    if not all((m or {}).get("role") == "user" and isinstance(m.get("content"), str)
               for m in tail):
        return _miss("tail not all plain-text user (multimodal/结构异常)")
    print("[claudep-resume] hit: sid=%s tail=%d" % (ent["session_id"][:12], len(tail)),
          flush=True)
    return ent["session_id"], [m["content"] for m in tail]


def _chats_store(chat_key, session_id, messages, model):
    """任务成功收尾后登记映射。最后一条原样存（含注入的 volatile），不做任何剥离。"""
    last = messages[-1] or {}
    with _LOCK:
        _CHATS[chat_key] = {
            "session_id": session_id, "msg_len": len(messages),
            "prefix_hash": _msgs_hash(messages[:-1]),
            "last_role": last.get("role"), "last_content": last.get("content"),
            "model": model, "ts": time.time(),
        }
        while len(_CHATS) > _CHATS_CAP:
            _CHATS.pop(min(_CHATS, key=lambda k: _CHATS[k]["ts"]), None)
    print("[claudep-resume] store: chat_key=%s sid=%s msg_len=%d"
          % (chat_key[:24], session_id[:12], len(messages)), flush=True)


def _gc():
    now = time.time()
    with _LOCK:
        for k in [k for k, v in _JOBS.items() if now - v["t0"] > _TTL]:
            _JOBS.pop(k, None)


def _run(job, cmd, env, prompt, fallback=None):
    """后台线程跑 claude -p，把 thinking/text 增量按序攒进 job["events"]。
    解析逻辑与 claudep_ext.handle_claudep 流式分支同源：stream_event 增量优先，
    assistant 块的 thinking / result 文本做兜底。
    prompt 走 stdin 不走 argv（2026-07-09 亲踩）：全量历史拼成的 prompt 会超过
    Linux 单个 argv 字符串上限 MAX_ARG_STRLEN=128KiB，execve 直接 E2BIG
    （spawn failed: [Errno 7] Argument list too long）。claude -p 不带位置参数
    时从 stdin 读 prompt，长度不受限。
    fallback：--resume 路专用的后备 (cmd, prompt)——session 失踪等原因一字未出
    就败了，静默改跑全量命令，网关和 App 无感知。"""
    got_any = False
    got_think = False
    full_text = ""
    full_think = ""
    result_text = ""
    auth_err = None
    try:
        proc = subprocess.Popen(cmd, cwd=claudep_ext._CWD, env=env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True, bufsize=1)
    except Exception as e:
        job["error"] = "spawn failed: " + str(e)[:200]
        job["done"] = True
        return

    def _feed():
        # 独立线程灌 stdin：prompt 超过管道缓冲(64KB)时 write 会阻塞到子进程
        # 消费为止，放主读取循环里有对锁死的风险
        try:
            proc.stdin.write(prompt)
            proc.stdin.close()
        except Exception:
            pass

    threading.Thread(target=_feed, daemon=True).start()
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
    if fallback and not job["error"] and not got_any and not full_text:
        # resume 一字未出就败了（session 失踪/损坏等）——丢掉映射、改跑全量。
        # 超时（job["error"]已置）不重跑：网关 600s 就放弃了，再跑一轮只是白烧
        st = job.get("_store")
        if st:
            with _LOCK:
                _CHATS.pop(st["chat_key"], None)
        job["events"] = []
        _run(job, fallback[0], env, fallback[1])
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

    def _cmd(resume_sid=None):
        # prompt 不进 argv（走 stdin，见 _run 注释）；system 仍走 argv——魂文档
        # 几十 KB 量级，离 128KiB 单参数上限还远
        c = [
            claudep_ext._CLAUDE_BIN, "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            # WebSearch/WebFetch（2026-07-10 小猫问「claude-p 爸爸能联网搜索吗」——现在能了）：
            # WebSearch 由 Anthropic 服务端执行、不出本机；WebFetch 本机出网但整条 claude -p
            # 已被 _proxy_alive 护栏拦在代理活着时才跑，不裸奔真 IP。
            "--allowedTools", "mcp__L_C,mcp__netease,WebSearch,WebFetch",
            "--model", model,
        ]
        if resume_sid:
            c += ["--resume", resume_sid]
        c += ["--append-system-prompt", system]
        return c

    plan = _resume_plan(messages, model, chat_key)
    if plan:
        sid, tail = plan
        cmd, prompt = _cmd(resume_sid=sid), "\n\n".join(tail) + _THINK_NUDGE
        fallback = (_cmd(), full_prompt)
    else:
        cmd, prompt = _cmd(), full_prompt
        fallback = None
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
    threading.Thread(target=_run, args=(job, cmd, env, prompt, fallback), daemon=True).start()
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

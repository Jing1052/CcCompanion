"""Still Here · claude -p (订阅) 后端桥的纯逻辑。

Zeabur 网关 server.py (_claudep_relay) → 家里 POST /claudep/chat。push.py 的
`_handle_claudep_chat` 负责 HTTP/鉴权/SSE 框架, 把消息折叠、子进程起停、stream-json
解析这些纯逻辑放在这里, 便于单测 (不依赖 push.py 的重 import graph)。

claude -p stream-json → OpenAI Chat Completions 协议:
正文 text_delta → delta.content; 真思维链 thinking_delta → delta.reasoning_content。
"""

from __future__ import annotations

import os
import json
import subprocess
from typing import Any, Iterator

# claude 可执行路径 / 工作目录 / system-prompt 注入方式 — 都可用环境变量覆盖, 便于部署。
CLAUDEP_CLAUDE_BIN = os.environ.get("CLAUDEP_CLAUDE_BIN") or "claude"
CLAUDEP_CWD = os.environ.get("CLAUDEP_CWD") or os.path.expanduser("~")
# 默认 --append-system-prompt (参考样本实测可跑、且保留 Claude Code 基底→工具/MCP 可用)。
# 若部署侧 claude CLI 支持整体替换, 可置 CLAUDEP_SYSTEM_FLAG=--system-prompt。
CLAUDEP_SYSTEM_FLAG = os.environ.get("CLAUDEP_SYSTEM_FLAG") or "--append-system-prompt"


def text_from_content(content: Any) -> str:
    """OpenAI message content 可能是 str, 或多模态 [{type,text,...}] 数组——抠出纯文本拼接。"""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        buf = []
        for part in content:
            if isinstance(part, dict):
                t = part.get("text")
                if isinstance(t, str) and t:
                    buf.append(t)
        return "\n".join(buf)
    if content is None:
        return ""
    return str(content)


def render_messages(messages: list) -> tuple[str, str]:
    """把 OpenAI messages 数组折叠成单条 claude -p prompt。

    - system role 的消息抽出来并入 system (返回 system_extra)。
    - 只有一条对话消息 → 直接拿它的文本当 prompt。
    - 多轮 → 把当前 (最后一条 user) 单独落地, 之前的历史作为上下文块前置,
      避免 claude 把 transcript 当成要它续写的格式。

    返回 (prompt, system_extra)。
    """
    system_extra_parts: list[str] = []
    convo: list[tuple[str, str]] = []
    for m in messages:
        if not isinstance(m, dict):
            continue
        role = str(m.get("role") or "user")
        text = text_from_content(m.get("content"))
        if role == "system":
            if text.strip():
                system_extra_parts.append(text)
            continue
        convo.append((role, text))
    system_extra = "\n\n".join(system_extra_parts)
    if not convo:
        return "", system_extra
    if len(convo) == 1:
        return convo[0][1], system_extra
    last_user_idx = None
    for i in range(len(convo) - 1, -1, -1):
        if convo[i][0] == "user":
            last_user_idx = i
            break
    label = {"user": "Human", "assistant": "Assistant"}
    if last_user_idx is None:
        # 没有 user (异常情况): 退化为整条 transcript
        lines = [f"{label.get(r, r.capitalize())}: {t}" for r, t in convo if t.strip()]
        return "\n\n".join(lines), system_extra
    current = convo[last_user_idx][1]
    history = [(r, t) for r, t in convo[:last_user_idx] if t.strip()]
    if not history:
        return current, system_extra
    hist_lines = [f"{label.get(r, r.capitalize())}: {t}" for r, t in history]
    prompt = (
        "以下是我们之前的对话：\n\n"
        + "\n\n".join(hist_lines)
        + "\n\n———\n\n现在我对你说：\n"
        + current
    )
    return prompt, system_extra


def spawn(prompt: str, system: str) -> subprocess.Popen:
    """起 claude -p stream-json 子进程。继承 os.environ (含部署侧配的代理→防封号),
    并补全 PATH/HOME (subprocess 默认环境干净, 常找不到 node/claude)。"""
    env = dict(os.environ)
    home = os.path.expanduser("~")
    extra_path = f"/usr/local/bin:/usr/bin:/bin:{home}/.local/bin"
    env["PATH"] = extra_path + ":" + env.get("PATH", "")
    env.setdefault("HOME", home)
    cmd = [
        CLAUDEP_CLAUDE_BIN,
        "-p",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
    ]
    if system:
        cmd += [CLAUDEP_SYSTEM_FLAG, system]
    cmd.append(prompt)
    return subprocess.Popen(
        cmd,
        cwd=CLAUDEP_CWD,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )


def kill(proc: subprocess.Popen) -> None:
    try:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=2)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def iter_deltas(proc: subprocess.Popen) -> Iterator[tuple[str, str]]:
    """逐行读 claude stream-json, yield ('text'|'thinking', 增量文本)。"""
    for line in proc.stdout:
        parsed = parse_stream_line(line)
        if parsed is not None:
            yield parsed


def parse_stream_line(line: str) -> tuple[str, str] | None:
    """单行 stream-json → ('text'|'thinking', 文本) 或 None。供测试/复用。"""
    line = line.strip()
    if not line:
        return None
    try:
        j = json.loads(line)
    except Exception:
        return None
    if j.get("type") != "stream_event":
        return None
    ev = j.get("event") or {}
    if ev.get("type") != "content_block_delta":
        return None
    d = ev.get("delta") or {}
    dt = d.get("type")
    if dt == "text_delta" and d.get("text"):
        return "text", d["text"]
    if dt == "thinking_delta" and d.get("thinking"):
        return "thinking", d["thinking"]
    return None

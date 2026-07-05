# tg_poller.py — Telegram getUpdates 中继（Bug3）
#
# 背景：CC 端（tmux cc 里的 Claude Code）原本靠 `--channels plugin:telegram` 插件轮询收 TG。
# VPN 一断，插件掉线且不自动重连，要等 session 轮换——期间「你发 TG → CC 收不到」（但 CC
# 发 TG 仍可，走 tg_split_send.sh 直调 Bot API）。
#
# 这个模块让 apns-server 自己用 getUpdates 轮询一个【CC 专用 bot】，收到消息就 POST 到本机
# /chat/send 注入 tmux——不依赖那个脆弱的插件。两个 bot 分开（CC 一个、API 端网关 webhook 一个），
# 同一 bot 上 webhook 与 getUpdates 互斥（409），分开就互不冲突。
#
# 配置（本机 config.toml，token 不进仓库）：
#   [telegram]
#   cc_bot_token = "123:ABC..."   # CC 专用 bot 的 token（留空=不启用，行为不变）
#   cc_chat_id   = "数字chat_id"  # 只接受这个 chat 的消息（强烈建议填，否则陌生人能往 CC 注消息）
#   poll_interval = 2
#
# ⚠️ 部署注意：这个 bot 上不能再有别的 getUpdates 消费者，否则两边抢更新。也就是 CC 启动命令里
#    那个 `--channels plugin:telegram`（用同一个 bot 收消息的）要去掉，改由本轮询器统一收。
import io
import json
import logging
import time
import urllib.parse
import urllib.request

from PIL import Image

logger = logging.getLogger("cc-apns-server")

_API = "https://api.telegram.org/bot{token}/{method}"


def _opener_for(proxy: str):
    """proxy 非空 → 走该代理（Telegram 国内要代理）；空 → 跟随环境/直连。"""
    if proxy:
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy})
        )
    return urllib.request.build_opener()


# 本机 /chat/send 永远直连，绕过任何代理（含环境里的）。
_LOCAL_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _tg_get_updates(token: str, offset: int, proxy: str = "", timeout: int = 25):
    """长轮询 getUpdates。返回 (updates_list, conflict_bool)。出错回 ([], False)。"""
    url = _API.format(token=token, method="getUpdates") + "?" + urllib.parse.urlencode(
        {"offset": offset, "timeout": timeout, "allowed_updates": json.dumps(["message"])}
    )
    try:
        # socket 超时给长轮询留足余量；走配置的代理
        with _opener_for(proxy).open(url, timeout=timeout + 10) as resp:
            data = json.loads(resp.read().decode("utf-8", "ignore"))
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "ignore")
        except Exception:
            pass
        if e.code == 409:
            logger.warning("[tg_poller] 409 Conflict：这个 bot 上还有别的 getUpdates/webhook 在抢。"
                           "确认 CC 没再挂 plugin:telegram、且这个 bot 没设 webhook。%s", body[:160])
            return [], True
        logger.warning("[tg_poller] getUpdates HTTP %s: %s", e.code, body[:160])
        return [], False
    except Exception as e:
        logger.warning("[tg_poller] getUpdates error: %s", e)
        return [], False
    if not data.get("ok"):
        logger.warning("[tg_poller] getUpdates not ok: %s", str(data.get("description"))[:160])
        return [], False
    return data.get("result", []) or [], False


def _inject_via_chat_send(state, text: str) -> bool:
    """POST 本机 /chat/send（复用完整注入+历史落库路径）。"""
    url = f"http://127.0.0.1:{state.port}/chat/send"
    payload = json.dumps({"text": text}).encode("utf-8")
    req = urllib.request.Request(url, data=payload, method="POST")
    req.add_header("Content-Type", "application/json")
    if state.shared_secret:
        req.add_header("X-Auth-Token", state.shared_secret)
    try:
        with _LOCAL_OPENER.open(req, timeout=15) as resp:  # 本机直连，别走代理
            return 200 <= resp.status < 300
    except urllib.error.HTTPError as e:
        logger.warning("[tg_poller] /chat/send HTTP %s", e.code)
        return False
    except Exception as e:
        logger.warning("[tg_poller] /chat/send error: %s", e)
        return False


def _tg_get_file(token: str, file_id: str, proxy: str = ""):
    """getFile → 返回 file_path（拿不到回 None）。"""
    url = _API.format(token=token, method="getFile") + "?" + urllib.parse.urlencode(
        {"file_id": file_id}
    )
    try:
        with _opener_for(proxy).open(url, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8", "ignore"))
    except Exception as e:
        logger.warning("[tg_poller] getFile error: %s", e)
        return None
    if not data.get("ok"):
        logger.warning("[tg_poller] getFile not ok: %s", str(data.get("description"))[:160])
        return None
    return ((data.get("result") or {}).get("file_path")) or None


def _tg_download_file(token: str, file_path: str, proxy: str = ""):
    """下载 TG 文件原始字节（失败回 None）。"""
    url = f"https://api.telegram.org/file/bot{token}/{file_path}"
    try:
        with _opener_for(proxy).open(url, timeout=60) as resp:
            return resp.read()
    except Exception as e:
        logger.warning("[tg_poller] download file error: %s", e)
        return None


def _inject_via_chat_upload(state, raw: bytes, filename: str, text: str) -> bool:
    """POST 本机 /chat/upload（原始字节 body），复用图片落库+注入路径。"""
    qs = urllib.parse.urlencode({"filename": filename, "role": "user", "text": text})
    url = f"http://127.0.0.1:{state.port}/chat/upload?{qs}"
    req = urllib.request.Request(url, data=raw, method="POST")
    req.add_header("Content-Type", "application/octet-stream")
    if state.shared_secret:
        req.add_header("X-Auth-Token", state.shared_secret)
    try:
        with _LOCAL_OPENER.open(req, timeout=30) as resp:  # 本机直连，别走代理
            return 200 <= resp.status < 300
    except urllib.error.HTTPError as e:
        logger.warning("[tg_poller] /chat/upload HTTP %s", e.code)
        return False
    except Exception as e:
        logger.warning("[tg_poller] /chat/upload error: %s", e)
        return False


def _compress_image(raw: bytes, max_dim: int = 1024, quality: int = 80) -> bytes:
    """缩放图片到 max_dim 以内，JPEG 压缩。省 Claude 视觉 token。"""
    try:
        img = Image.open(io.BytesIO(raw))
        if img.mode in ("RGBA", "P"):
            img = img.convert("RGB")
        w, h = img.size
        if max(w, h) > max_dim:
            ratio = max_dim / max(w, h)
            img = img.resize((int(w * ratio), int(h * ratio)), Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=quality, optimize=True)
        result = buf.getvalue()
        logger.info("[tg_poller] image compressed: %dKB → %dKB (%dx%d)",
                    len(raw) // 1024, len(result) // 1024, img.size[0], img.size[1])
        return result
    except Exception as e:
        logger.warning("[tg_poller] image compress failed: %s, using original", e)
        return raw


def _relay_photo(state, token: str, msg: dict, proxy: str) -> bool:
    """中继 TG 图片：取最大尺寸 file_id → getFile → 下载 → 压缩 → POST /chat/upload。"""
    sizes = msg.get("photo") or []
    if not sizes:
        return False
    # photo 是同一张图的多种尺寸，最后一个最大
    file_id = (sizes[-1] or {}).get("file_id")
    if not file_id:
        return False
    file_path = _tg_get_file(token, file_id, proxy)
    if not file_path:
        return False
    raw = _tg_download_file(token, file_path, proxy)
    if not raw:
        return False
    raw = _compress_image(raw)
    fname = f"tg_{msg.get('message_id', 'photo')}.jpg"
    caption = (msg.get("caption") or "").strip()
    text = "[TG] " + caption if caption else "[TG]"
    return _inject_via_chat_upload(state, raw, fname, text)


def _relay_voice(state, token: str, msg: dict, proxy: str) -> bool:
    """中继 TG 语音/音频：file_id → getFile → 下载 → POST /chat/upload。
    注入的 hint 自带本地路径，CC 端用 transcribe.py 转写后当她亲口说的话。"""
    voice = msg.get("voice") or msg.get("audio") or {}
    file_id = voice.get("file_id")
    if not file_id:
        return False
    file_path = _tg_get_file(token, file_id, proxy)
    if not file_path:
        return False
    raw = _tg_download_file(token, file_path, proxy)
    if not raw:
        return False
    ext = "." + file_path.rsplit(".", 1)[-1] if "." in file_path else ".oga"
    fname = "tg_{}{}".format(msg.get("message_id", "voice"), ext)
    caption = (msg.get("caption") or "").strip()
    text = "[TG] (小猫发来语音消息——先用 python3 ~/.claude/tools/transcribe.py 转写下面本地路径的文件，把转写内容当她亲口说的话来回)"
    if caption:
        text += " " + caption
    return _inject_via_chat_upload(state, raw, fname, text)


def _load_offset(path) -> int:
    try:
        return int(json.loads(path.read_text(encoding="utf-8")).get("offset", 0))
    except Exception:
        return 0


def _save_offset(path, offset: int):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps({"offset": offset}), encoding="utf-8")
        tmp.replace(path)
    except Exception as e:
        logger.warning("[tg_poller] save offset failed: %s", e)


def tg_poller_loop(state):
    """后台线程：轮询 CC 专用 bot 的 getUpdates，把消息注入 tmux。配了 token 才真正跑。"""
    token = (getattr(state, "tg_cc_bot_token", "") or "").strip()
    if not token:
        logger.info("[tg_poller] disabled (telegram.cc_bot_token 未配)")
        return
    allow_chat = str(getattr(state, "tg_cc_chat_id", "") or "").strip()
    interval = float(getattr(state, "tg_poll_interval", 2) or 2)
    proxy = (getattr(state, "tg_proxy", "") or "").strip()
    offset_path = state.tg_offset_path
    offset = _load_offset(offset_path)
    logger.info("[tg_poller] starting (chat_id allowlist=%s, proxy=%s, offset=%d)",
                allow_chat or "(none)", proxy or "(env/none)", offset)

    while True:
        try:
            updates, conflict = _tg_get_updates(token, offset, proxy)
            if conflict:
                time.sleep(15)  # webhook/插件冲突，退避久一点别刷屏
                continue
            for up in updates:
                uid = up.get("update_id")
                if isinstance(uid, int):
                    offset = max(offset, uid + 1)  # 即便这条不处理也要推进 offset，别死循环
                msg = up.get("message") or {}
                text = (msg.get("text") or "").strip()
                has_photo = bool(msg.get("photo"))
                has_voice = bool(msg.get("voice") or msg.get("audio"))
                chat_id = str(((msg.get("chat") or {}).get("id")) or "")
                if not text and not has_photo and not has_voice:
                    continue  # 文字/图片/语音之外的（视频/文件等）暂不中继
                if allow_chat and chat_id != allow_chat:
                    logger.info("[tg_poller] 丢弃非白名单 chat_id=%s 的消息", chat_id)
                    continue
                # [TG] 前缀：让 CC 认出这条来自 TG、该用 tg 脚本回 TG，而不是只回终端。
                if has_photo:
                    ok = _relay_photo(state, token, msg, proxy)
                    kind = "图片"
                elif has_voice:
                    ok = _relay_voice(state, token, msg, proxy)
                    kind = "语音"
                else:
                    ok = _inject_via_chat_send(state, "[TG] " + text)
                    kind = "消息"
                if ok:
                    logger.info("[tg_poller] 注入 TG %s update_id=%s", kind, uid)
                else:
                    logger.warning("[tg_poller] 注入失败 update_id=%s（保留 offset 下轮重试）", uid)
                    # 注入失败：回退 offset 到这条，下轮重试这条（避免丢消息）
                    if isinstance(uid, int):
                        offset = uid
                    _save_offset(offset_path, offset)
                    break
            _save_offset(offset_path, offset)
            if not updates:
                time.sleep(interval)
        except Exception:
            logger.exception("[tg_poller] loop error")
            time.sleep(5)

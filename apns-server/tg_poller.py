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
import json
import logging
import time
import urllib.parse
import urllib.request

logger = logging.getLogger("cc-apns-server")

_API = "https://api.telegram.org/bot{token}/{method}"


def _tg_get_updates(token: str, offset: int, timeout: int = 25):
    """长轮询 getUpdates。返回 (updates_list, conflict_bool)。出错回 ([], False)。"""
    url = _API.format(token=token, method="getUpdates") + "?" + urllib.parse.urlencode(
        {"offset": offset, "timeout": timeout, "allowed_updates": json.dumps(["message"])}
    )
    try:
        # socket 超时给长轮询留足余量
        with urllib.request.urlopen(url, timeout=timeout + 10) as resp:
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
        with urllib.request.urlopen(req, timeout=15) as resp:
            return 200 <= resp.status < 300
    except urllib.error.HTTPError as e:
        logger.warning("[tg_poller] /chat/send HTTP %s", e.code)
        return False
    except Exception as e:
        logger.warning("[tg_poller] /chat/send error: %s", e)
        return False


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
    offset_path = state.tg_offset_path
    offset = _load_offset(offset_path)
    logger.info("[tg_poller] starting (chat_id allowlist=%s, offset=%d)", allow_chat or "(none)", offset)

    while True:
        try:
            updates, conflict = _tg_get_updates(token, offset)
            if conflict:
                time.sleep(15)  # webhook/插件冲突，退避久一点别刷屏
                continue
            for up in updates:
                uid = up.get("update_id")
                if isinstance(uid, int):
                    offset = max(offset, uid + 1)  # 即便这条不处理也要推进 offset，别死循环
                msg = up.get("message") or {}
                text = (msg.get("text") or "").strip()
                chat_id = str(((msg.get("chat") or {}).get("id")) or "")
                if not text:
                    continue  # 暂只中继文字（图片/语音另说）
                if allow_chat and chat_id != allow_chat:
                    logger.info("[tg_poller] 丢弃非白名单 chat_id=%s 的消息", chat_id)
                    continue
                if _inject_via_chat_send(state, text):
                    logger.info("[tg_poller] 注入 TG 消息 update_id=%s", uid)
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

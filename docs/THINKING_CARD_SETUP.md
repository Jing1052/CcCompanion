# 思考卡片配置指南（Thinking Card Setup）

> Build 231+ 支持。配置完成后，iPhone 上每条 AI 回复的上方会出现一张可展开的「思考卡片」，实时显示 Claude 回复你时的思考摘要：它在想什么、怎么定位问题、为什么这么答。

English version coming soon. 本文先以中文为准。

---

## 这是什么

Claude Code 回复你之前会先「思考」。默认情况下这段思考不对外显示，你在 ccc 里只能看到最终回复。

配置思考卡片后，每个回复上方会多一行灰色斜体的折叠卡片，点开能看到这一轮的思考摘要。效果上，你等于多了一扇「看它怎么想」的窗口——调试它为什么答偏了、看它怎么拆解你的问题，都很有用。

**先说清楚两件事，避免期望落空：**

1. 卡片显示的是**思考摘要**，不是原始思考全文。Anthropic 出于防蒸馏考虑，原始思考链（raw chain-of-thought）不落任何客户端文件；你能拿到的是一个轻量模型（Haiku）对思考过程的**实时转写**。
2. 转写有它自己的脾气：偏好英文（即使原始思考是中文）、偶有字面误读、对敏感内容会直接消音改写。把它当「窗口」而不是「逐字稿」。

## 工作原理

```
claude 启动时带 --thinking-display summarized
        │
        ▼
transcript (~/.claude/projects/.../*.jsonl) 里的 thinking 块带上明文摘要
        │
        ▼
ccc_stop_hook.sh（每轮回复结束时触发）抽取本轮思考摘要
        │
        ▼
POST /v1/thinking → apns-server 落库 + 静默推送
        │
        ▼
iOS app 按 turn_id 拉取，思考卡片渲染在该轮第一条回复气泡上方
```

五个环节缺一不可：启动 flag、新版 server、新版 hook、app build 231+、hook 正常触发。

## 配置步骤

### 第 1 步：claude 启动命令加 flag

在你平时启动 Claude Code 的命令上加 `--thinking-display summarized`：

```bash
claude --thinking-display summarized
```

如果你是在 tmux 里跑 claude（ccc 的标准用法），把 flag 加进你的启动命令即可。**已经在跑的 session 需要退出重启才会生效。**

> 这个 flag 只能跟随启动命令，写进 settings.json 是无效的。

### 第 2 步：更新 apns-server

思考卡片需要 server 端的 `/v1/thinking` 接口（build 231 对应的 server 代码已包含）。

```bash
cd ~/CcCompanion
git pull
# 重启你的 apns-server（按你部署时的方式，例如 launchctl kickstart 或直接重跑 python）
```

验证接口存在：

```bash
curl -s "http://127.0.0.1:8795/v1/thinking?turn_id=ping"
# 返回 {"ok": true, "records": [], "count": 0} 即为新版
```

### 第 3 步：更新 Stop hook

新版 `ccc_stop_hook.sh` 已内置思考摘要的抽取与上报，重新拷贝一次即可：

```bash
cp ~/CcCompanion/apns-server/claude_hooks/ccc_stop_hook.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/ccc_stop_hook.sh
```

settings.json 里的 hook 注册不需要任何改动（还是原来那条 Stop hook）。

### 第 4 步：更新 app

TestFlight 更新到 build 231 或更新版本。

## 验证

1. 确认 claude 是带着 flag 启动的（重启过 session）。
2. iPhone 上发一条需要动脑的消息，例如「帮我比较一下两种方案的取舍」。
3. 回复出现后，几秒到几十秒内，回复上方应出现思考卡片（思考上报比回复本身稍慢，app 会自动重试拉取约 90 秒）。
4. Mac 上看 hook 日志：

```bash
tail -f /tmp/ccc_stop_hook.log
# 配置成功后每轮应有一行: posted to /v1/thinking ok (turn=xxxx chars=NNN)
```

## 已知限制

- **摘要不是原文。** 显示内容由轻量模型实时转写，可能偏英文、偶有失真、丢语气。
- **敏感内容会被消音。** 转写模型遇到它认为敏感的思考内容会整段跳过或替换成拒绝说明，这是上游行为，ccc 无法控制。
- **不是每轮都有卡片。** 简单的回复可能没有思考块；没开 flag 的 session 永远不会有。
- **思考摘要存在你自己的 server 上**（`apns-server/state/thinking_log.jsonl`），跟你的聊天记录一样 local-first，不经过任何第三方。

## 故障排查

| 现象 | 排查 |
| --- | --- |
| 卡片从不出现 | 确认 claude 启动命令带 flag 且重启过 session；`tail /tmp/ccc_stop_hook.log` 看有没有 `posted to /v1/thinking ok` |
| hook 日志没有 thinking 行 | hook 没更新到新版，重新执行第 3 步 |
| 日志报 `POST /v1/thinking failed http=404` | server 是旧版，执行第 2 步 |
| 日志报 `http=401` | `CCC_AUTH_TOKEN` 跟 server 的 shared_secret 不一致，跟 `/chat/append` 用的是同一个 token |
| 卡片冒出来但内容是英文 | 正常现象，转写模型偏好英文，参见「已知限制」 |
| 回复到了卡片迟迟不来 | 思考上报最多比回复晚约 30 秒，app 端有约 90 秒的自动重试窗口；超过后该轮不再补卡 |

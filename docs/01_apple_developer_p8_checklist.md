---
date: 2026-05-14
target: CcCompanion 用户 (想走原生 APNs 推送的)
time_estimate: 约 5 分钟
prerequisite: Apple Developer Program 付费账号 (99 美元/年) 审核通过
---

# Apple Developer 拿 .p8 + Team ID + Key ID

> 本文档给"想给 CcCompanion 配原生 Apple Push (APNs) 推送"的用户用。如果你不想买 Apple Developer 账号, 跳过本文档, 走 Bark fallback (`docs/AI_GUIDED_SETUP_MAC.md` Phase B.2.B)。

走完你会拿到 4 项, 后面 `apns-server/config.toml` 的 `[apns]` 段需要这 4 项填入。

---

## 你要拿的 4 项

1. **Team ID** (10 位字母数字, 例如 `ABCD1E2F3G`)
2. **Key ID** (10 位字母数字, 例如 `XYZ123ABC4`)
3. **`.p8` 文件本地路径** (下载后建议放 `~/CcCompanion/apns-server/secrets/AuthKey_<Key ID>.p8`, 这个路径已经在 `.gitignore` 里)
4. **Bundle ID** (你自己定, 推荐 `com.<你的-handle>.cccompanion`, 例如 `com.alice.cccompanion`)

---

## 步骤 1 · 拿 Team ID (30 秒)

1. 打开 <https://developer.apple.com/account>
2. 登录你的 paid Apple Developer Apple ID
3. 进 **Membership Details** 或者 **Account → Membership**
4. 复制 **Team ID** 那一栏 (10 位字符)

---

## 步骤 2 · 创建 .p8 APNs Auth Key + 拿 Key ID (2 分钟)

1. 同一个登录态下 → 进 **Certificates, Identifiers & Profiles**
2. 左侧选 **Keys**
3. 点右上角 **+** 新建一个 Key
4. **Key Name** 填: `CcCompanion APNs Key` (或者你想叫别的)
5. 勾选 **Apple Push Notifications service (APNs)**
6. 别勾其它 (精简权限)
7. 点 **Continue** → **Register**
8. 立即下载 `.p8` 文件 (**只能下载一次** 错过就重建)
9. 屏幕上显示的 **Key ID** (10 位字符) 复制下来
10. 把 `.p8` 文件移到 server secrets 目录:

```bash
mkdir -p ~/CcCompanion/apns-server/secrets
mv ~/Downloads/AuthKey_*.p8 ~/CcCompanion/apns-server/secrets/
chmod 600 ~/CcCompanion/apns-server/secrets/AuthKey_*.p8
```

---

## 步骤 3 · 注册 App ID + 开 Push Notifications capability (2 分钟)

1. 还是 **Certificates, Identifiers & Profiles** 页面
2. 左侧选 **Identifiers** → 右上 **+**
3. 选 **App IDs** → Continue
4. 选 **App** → Continue
5. **Description**: `CcCompanion` (或者你想要的)
6. **Bundle ID**: 选 **Explicit**, 填你定的 (例如 `com.alice.cccompanion`)
7. 往下滚 **Capabilities** 列表, **勾选**:
   - ✅ Push Notifications
8. Continue → Register

---

## 完事填进 config.toml

回到 `apns-server/config.toml`, 填:

```toml
[apns]
p8_path = "~/CcCompanion/apns-server/secrets/AuthKey_XXXXXXXXXX.p8"
team_id = "XXXXXXXXXX"      # 步骤 1 拿到
key_id = "XXXXXXXXXX"       # 步骤 2 拿到 (跟 .p8 文件名里那段一致)
bundle_id = "com.alice.cccompanion"  # 步骤 3 填的
sandbox = true              # 真机 dev build 用 true, TestFlight / App Store build 用 false
```

然后重启 `apns-server`:

```bash
launchctl unload ~/Library/LaunchAgents/com.user.apns-server.plist
launchctl load ~/Library/LaunchAgents/com.user.apns-server.plist
```

---

## 几个常见坑

- **`.p8` 只能下载一次**: 错过只能重新建一个 Key。
- **Bundle ID 用 Explicit 不要 wildcard**: APNs 推送需要 explicit bundle id。
- **Team ID ≠ Apple ID**: Team ID 是 10 位字符, 不是邮箱。
- **`.p8` 别进 git**: 这是 secret, 拿到就能给该 bundle id 的所有设备发推送。`.gitignore` 已经挡了 `apns-server/secrets/` 整个目录, 但别手动复制到别处再 commit。
- **sandbox 跟 production 别搞混**: Xcode 直接 `⌘R` 装到真机的 build 用 sandbox APNs 端点, TestFlight / App Store 走 production。`config.toml` 的 `sandbox = true/false` 要跟你测试的 build 类型对齐, 不然推不通。

//
//  GroupMessage.swift
//  CcCompanion
//
//  Workgroup chat records from apns-server /group endpoints.
//

import Foundation
import SwiftUI
import UIKit

nonisolated struct GroupMessage: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let ts: String
    let conversationId: String?
    let senderId: String
    let senderModel: String?
    let text: String
    let mentions: [String]
    let parentMsgId: String?
    let replyTo: String?
    let source: String?
    let messageType: String
    let taskId: String?
    let parentTaskId: String?
    let owner: String?
    // Build 217-patch-A — attachment fields (image / file / video / audio)
    let attachmentUrl: String?
    let attachmentFilename: String?
    let attachmentType: String?

    enum CodingKeys: String, CodingKey {
        case id, ts, text, mentions, source, owner
        case conversationId = "conversation_id"
        case senderId = "sender_id"
        case senderModel = "sender_model"
        case parentMsgId = "parent_msg_id"
        case replyTo = "reply_to"
        case messageType = "message_type"
        case taskId = "task_id"
        case parentTaskId = "parent_task_id"
        case attachmentUrl = "attachment_url"
        case attachmentFilename = "attachment_filename"
        case attachmentType = "attachment_type"
    }

    init(
        id: String,
        ts: String,
        conversationId: String? = nil,
        senderId: String,
        senderModel: String? = nil,
        text: String,
        mentions: [String] = [],
        parentMsgId: String? = nil,
        replyTo: String? = nil,
        source: String? = nil,
        messageType: String = "chat",
        taskId: String? = nil,
        parentTaskId: String? = nil,
        owner: String? = nil,
        attachmentUrl: String? = nil,
        attachmentFilename: String? = nil,
        attachmentType: String? = nil
    ) {
        self.id = id
        self.ts = ts
        self.conversationId = conversationId
        self.senderId = senderId
        self.senderModel = senderModel
        self.text = text
        self.mentions = mentions
        self.parentMsgId = parentMsgId
        self.replyTo = replyTo
        self.source = source
        self.messageType = messageType
        self.taskId = taskId
        self.parentTaskId = parentTaskId
        self.owner = owner
        self.attachmentUrl = attachmentUrl
        self.attachmentFilename = attachmentFilename
        self.attachmentType = attachmentType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.ts = try c.decodeIfPresent(String.self, forKey: .ts) ?? ""
        self.conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
        self.senderId = try c.decodeIfPresent(String.self, forKey: .senderId) ?? "unknown"
        self.senderModel = try c.decodeIfPresent(String.self, forKey: .senderModel)
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.mentions = try c.decodeIfPresent([String].self, forKey: .mentions) ?? []
        self.parentMsgId = try c.decodeIfPresent(String.self, forKey: .parentMsgId)
        self.replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
        self.source = try c.decodeIfPresent(String.self, forKey: .source)
        self.messageType = try c.decodeIfPresent(String.self, forKey: .messageType) ?? "chat"
        self.taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        self.parentTaskId = try c.decodeIfPresent(String.self, forKey: .parentTaskId)
        self.owner = try c.decodeIfPresent(String.self, forKey: .owner)
        self.attachmentUrl = try c.decodeIfPresent(String.self, forKey: .attachmentUrl)
        self.attachmentFilename = try c.decodeIfPresent(String.self, forKey: .attachmentFilename)
        self.attachmentType = try c.decodeIfPresent(String.self, forKey: .attachmentType)
    }

    var isHumanSender: Bool { senderId == "amian" }

    /// Build 217-patch-A — resolve attachment_url (server-relative or http) to absolute URL.
    func attachmentFullURL() -> URL? {
        guard let path = attachmentUrl, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: CcServerConfig.serverURL.absoluteString + path)
    }
    var isShip: Bool { messageType == "ship" }
    var isTask: Bool { messageType == "task" }
    var isBlock: Bool { messageType == "block" }

    var shortTime: String {
        guard let tIndex = ts.firstIndex(of: "T") else { return "" }
        let afterT = ts[ts.index(after: tIndex)...]
        return String(afterT.prefix(5))
    }
}

nonisolated struct GroupMember: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let kind: String?
    let avatar: String?
    let color: String?
    let model: String?
    let tmux: String?
    let canReply: Bool?
    let optional: Bool?
    let customAvatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, avatar, color, model, tmux, optional
        case displayName = "display_name"
        case canReply = "can_reply"
        case customAvatarURL = "custom_avatar_url"
    }

    init(
        id: String,
        displayName: String,
        kind: String? = nil,
        avatar: String? = nil,
        color: String? = nil,
        model: String? = nil,
        tmux: String? = nil,
        canReply: Bool? = nil,
        optional: Bool? = nil,
        customAvatarURL: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.avatar = avatar
        self.color = color
        self.model = model
        self.tmux = tmux
        self.canReply = canReply
        self.optional = optional
        self.customAvatarURL = customAvatarURL
    }

    var title: String {
        // Build 218 S3 — 用户在 Settings 群聊 row 编辑过的 displayName override 优先.
        // 未设 override 则回退到 server roster / agents_config.json 给的 displayName.
        if let override = GroupMemberOverrideStore.displayNameOverride(for: id), !override.isEmpty {
            return override
        }
        return displayName
    }

    var avatarText: String {
        if let avatar, !avatar.isEmpty { return avatar }
        return String(title.prefix(1))
    }

    func withCustomAvatarURL(_ path: String?) -> GroupMember {
        GroupMember(
            id: id,
            displayName: displayName,
            kind: kind,
            avatar: avatar,
            color: color,
            model: model,
            tmux: tmux,
            canReply: canReply,
            optional: optional,
            customAvatarURL: path
        )
    }

    var avatarColor: Color {
        // Build 220 item 8/9 — 走统一 designer 色板 (avatar / mention chip / nickname / sender label 同源)
        GroupMember.uiColor(for: color)
    }

    /// Build 220 item 8/9 — central palette resolver. 走 designer-grade muted 色 (避免荧光), 全 WCAG AA on cream/beige bg.
    /// 任何需要"按 color 字段染色"的地方都调这里 保证一致 (mention chip / nickname / sender label / avatar).
    static func uiColor(for colorTag: String?) -> Color {
        switch colorTag {
        case "orange":  return Color(red: 0.80, green: 0.50, blue: 0.10)  // 暖橙 (= ccAccent)
        case "blue":    return Color(red: 0.37, green: 0.55, blue: 0.66)  // 雾青
        case "green":   return Color(red: 0.42, green: 0.57, blue: 0.39)  // 苔绿
        case "purple":  return Color(red: 0.53, green: 0.44, blue: 0.66)  // 鸢尾紫
        case "slate":   return Color(red: 0.42, green: 0.45, blue: 0.50)  // 石板
        case "neutral": return Color(red: 0.55, green: 0.51, blue: 0.45)  // 米白 (作为前景需更深)
        default:        return Color(red: 0.80, green: 0.50, blue: 0.10)
        }
    }

    /// Display swatch (for picker / preview) — saturated 一些方便 UI 看清.
    static func swatchColor(for colorTag: String?) -> Color {
        switch colorTag {
        case "orange":  return Color(red: 0.85, green: 0.55, blue: 0.18)
        case "blue":    return Color(red: 0.45, green: 0.65, blue: 0.78)
        case "green":   return Color(red: 0.50, green: 0.65, blue: 0.48)
        case "purple":  return Color(red: 0.60, green: 0.50, blue: 0.72)
        case "slate":   return Color(red: 0.50, green: 0.55, blue: 0.60)
        case "neutral": return Color(red: 0.85, green: 0.80, blue: 0.72)
        default:        return Color(red: 0.85, green: 0.55, blue: 0.18)
        }
    }

    // Default roster. IDs are protocol identifiers kept for back-compat with the
    // shipped Python server; display names / avatars / tmux session names are
    // generic placeholders. Server-side override via `agents_config.json` will
    // populate the real roster from `/group/roster` on first poll — these
    // defaults only ever show during the initial fetch race.
    static let defaults: [GroupMember] = [
        GroupMember(id: "amian", displayName: "User", kind: "human", avatar: "U", color: "neutral", model: nil, tmux: nil, canReply: false, optional: nil),
        GroupMember(id: "opia", displayName: "Assistant", kind: "agent", avatar: "A", color: "orange", model: "Claude Opus 4.7", tmux: "assistant", canReply: true, optional: nil),
        GroupMember(id: "sonnet", displayName: "Agent B", kind: "agent", avatar: "B", color: "blue", model: "Claude Sonnet 4.6", tmux: "agent-b", canReply: true, optional: nil),
        GroupMember(id: "shu", displayName: "Agent C", kind: "agent", avatar: "C", color: "green", model: "Codex GPT-5.5", tmux: "agent-c", canReply: true, optional: nil),
        GroupMember(id: "opus47_fresh", displayName: "Agent D", kind: "agent", avatar: "D", color: "purple", model: "Claude Opus 4.7", tmux: "agent-d", canReply: true, optional: true),
        GroupMember(id: "di", displayName: "Agent E", kind: "agent", avatar: "E", color: "slate", model: "Claude Opus 4.7", tmux: "agent-e", canReply: true, optional: nil),
    ]

    static var defaultMap: [String: GroupMember] {
        Dictionary(uniqueKeysWithValues: defaults.map { ($0.id, $0) })
    }

    /// Build 220 item 5 — 用户实际在群里看到的成员列表 (default - removals + additions).
    /// 任何"render 群成员名单/状态条" 走这个 source 不直接走 defaults / defaultMap.
    static var activeRoster: [GroupMember] {
        let removals = GroupMemberRemovalsStore.removals()
        var list = defaults.filter { !removals.contains($0.id) }
        for added in GroupMemberAdditionsStore.additions() where !removals.contains(added.id) {
            // 避免重复 (additions 可能跟 defaults 有 id 重叠 — additions win)
            list.removeAll { $0.id == added.id }
            list.append(added)
        }
        return list
    }

    static var activeRosterMap: [String: GroupMember] {
        Dictionary(uniqueKeysWithValues: activeRoster.map { ($0.id, $0) })
    }
}

nonisolated struct GroupAgentStatus: Codable, Hashable, Sendable {
    let state: String?
    let tmux: String?
    let lastSeen: String?
    let isTyping: Bool?
    let typingSince: String?
    let dispatchId: String?
    let statusText: String?

    enum CodingKeys: String, CodingKey {
        case state, tmux
        case lastSeen = "last_seen"
        case isTyping = "is_typing"
        case typingSince = "typing_since"
        case dispatchId = "dispatch_id"
        case statusText = "status_text"
    }
}

nonisolated struct GroupStatusSnapshot: Codable, Hashable, Sendable {
    let agents: [String: GroupAgentStatus]
}

extension Notification.Name {
    static let ccGroupAppearanceDidChange = Notification.Name("CcGroupAppearanceDidChange")
}

enum GroupAvatarStore {
    static let pathsKey = "group_member_avatar_paths"
    static let revisionKey = "group_avatar_revision"

    static func avatarPath(for memberId: String) -> String? {
        avatarPaths()[memberId]
    }

    static func avatarPaths() -> [String: String] {
        rawAvatarPaths().mapValues { AvatarDiskStore.filename(fromStoredValue: $0) }
    }

    private static func rawAvatarPaths() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: pathsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func setAvatarPath(_ path: String, for memberId: String) {
        var paths = avatarPaths()
        paths[memberId] = AvatarDiskStore.filename(fromStoredValue: path)
        persist(paths)
        bumpRevision()
    }

    static func removeAvatar(for memberId: String) {
        if let path = avatarPath(for: memberId) {
            AvatarDiskStore.remove(storedValue: path)
        }
        var paths = avatarPaths()
        paths.removeValue(forKey: memberId)
        persist(paths)
        bumpRevision()
    }

    static func filename(for memberId: String) -> String {
        let clean = memberId.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "_" || ch == "-" ? ch : "_"
        }
        return "groupAvatar_\(String(clean)).png"
    }

    private static func persist(_ paths: [String: String]) {
        guard let data = try? JSONEncoder().encode(paths) else { return }
        UserDefaults.standard.set(data, forKey: pathsKey)
    }

    private static func bumpRevision() {
        let next = UserDefaults.standard.integer(forKey: revisionKey) + 1
        UserDefaults.standard.set(next, forKey: revisionKey)
        NotificationCenter.default.post(name: .ccGroupAppearanceDidChange, object: nil)
    }

    static func migrateLegacyPathsIfNeeded() {
        let current = rawAvatarPaths()
        guard !current.isEmpty else { return }
        let migrated = current.mapValues { AvatarDiskStore.filename(fromStoredValue: $0) }
        guard migrated != current else { return }
        persist(migrated)
        bumpRevision()
    }
}

struct GroupAvatarView: View {
    let member: GroupMember
    let size: CGFloat

    @AppStorage(GroupAvatarStore.revisionKey) private var avatarRevision: Int = 0

    private var avatarPath: String? {
        member.customAvatarURL ?? GroupAvatarStore.avatarPath(for: member.id)
    }

    var body: some View {
        ZStack {
            if let avatarPath, !avatarPath.isEmpty,
               let image = AvatarDiskStore.load(storedValue: avatarPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(member.avatarColor)
                Text(member.avatarText)
                    .font(.ccSerifAdaptive(size: max(11, size * 0.42), weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .id("\(member.id)-\(avatarRevision)-\(AvatarDiskStore.filename(fromStoredValue: avatarPath ?? ""))")
    }
}

// MARK: - Build 218 S3/S4 — 用户对群成员名单的本地覆盖 / 增 / 删

/// 用户在 Settings 编辑过的 member displayName 覆盖. JSON map<id, override-name> 落 UserDefaults.
enum GroupMemberOverrideStore {
    static let storageKey = "group_member_overrides"
    static let revisionKey = "group_member_overrides_revision"

    static func overrides() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func displayNameOverride(for memberId: String) -> String? {
        overrides()[memberId]
    }

    static func setDisplayNameOverride(_ name: String?, for memberId: String) {
        var map = overrides()
        if let name, !name.isEmpty {
            map[memberId] = name
        } else {
            map.removeValue(forKey: memberId)
        }
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        bumpRevision()
    }

    private static func bumpRevision() {
        let next = UserDefaults.standard.integer(forKey: revisionKey) + 1
        UserDefaults.standard.set(next, forKey: revisionKey)
        NotificationCenter.default.post(name: .ccGroupAppearanceDidChange, object: nil)
    }
}

/// 用户自加的 agent 成员 — JSON Array 落 UserDefaults; 跟 default roster 叠加.
enum GroupMemberAdditionsStore {
    static let storageKey = "group_member_additions"
    static let revisionKey = "group_member_additions_revision"

    static func additions() -> [GroupMember] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([GroupMember].self, from: data) else {
            return []
        }
        return decoded
    }

    static func add(_ member: GroupMember) {
        var list = additions().filter { $0.id != member.id }
        list.append(member)
        persist(list)
    }

    static func remove(id: String) {
        let list = additions().filter { $0.id != id }
        persist(list)
    }

    private static func persist(_ list: [GroupMember]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        bumpRevision()
    }

    private static func bumpRevision() {
        let next = UserDefaults.standard.integer(forKey: revisionKey) + 1
        UserDefaults.standard.set(next, forKey: revisionKey)
        NotificationCenter.default.post(name: .ccGroupAppearanceDidChange, object: nil)
    }
}

/// 用户删除过的 member id 集合 — 显示时从 default roster 中过滤掉.
enum GroupMemberRemovalsStore {
    static let storageKey = "group_member_removals"
    static let revisionKey = "group_member_removals_revision"

    static func removals() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(decoded)
    }

    static func isRemoved(_ id: String) -> Bool {
        removals().contains(id)
    }

    static func markRemoved(_ id: String) {
        var set = removals()
        set.insert(id)
        persist(set)
    }

    static func unmarkRemoved(_ id: String) {
        var set = removals()
        set.remove(id)
        persist(set)
    }

    private static func persist(_ set: Set<String>) {
        guard let data = try? JSONEncoder().encode(Array(set)) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        bumpRevision()
    }

    private static func bumpRevision() {
        let next = UserDefaults.standard.integer(forKey: revisionKey) + 1
        UserDefaults.standard.set(next, forKey: revisionKey)
        NotificationCenter.default.post(name: .ccGroupAppearanceDidChange, object: nil)
    }
}

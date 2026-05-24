//
//  ChatBadgeStore.swift
//  CcCompanion
//
//  Build 215 P4 — app 级 chat tab unread 计数 store.
//  ChatViewModel 的 unreadCount 只在 ChatListView 在屏时活, 切到群聊 / 终端 / 设置 tab 时 vm.stop() 不 polling.
//  这份 store 在 ContentView 层 @StateObject, featureGroupView 开关无关一直跑 light polling, tab 0 badge 能稳显.
//  逻辑跟 GroupStore unread 一致: lastSeenTs 持久化 UserDefaults, 拉新消息按 r.ts > lastSeenTs 算 unread.
//

import Foundation
import Combine

@MainActor
final class ChatBadgeStore: ObservableObject {
    @Published var unreadCount: Int = 0

    private var pollTask: Task<Void, Never>? = nil
    private var latestKnownTs: String = ""
    private let lastSeenKey = "chat_last_seen_ts"

    private var lastSeenTs: String {
        get { UserDefaults.standard.string(forKey: lastSeenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lastSeenKey) }
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.fetchOnce(reset: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s — 比 ChatViewModel 1s 慢, 只为 badge 状态
                await self?.fetchOnce(reset: false)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 视图打开 chat tab 时调. 清 unread 计数并把 lastSeenTs 推到最新已知 ts.
    func markAllRead() {
        unreadCount = 0
        if !latestKnownTs.isEmpty {
            lastSeenTs = latestKnownTs
        }
    }

    private func fetchOnce(reset: Bool) async {
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/poll")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "limit", value: "50")]
        // 第一次 reset=true 走 since=lastSeenTs 算 cold-start unread.
        // 后续 reset=false 走 since=latestKnownTs 只拉新.
        let since = reset ? lastSeenTs : latestKnownTs
        if !since.isEmpty {
            items.append(URLQueryItem(name: "since", value: since))
        }
        components?.queryItems = items
        guard let finalURL = components?.url else { return }
        let request = CcServerConfig.authenticatedRequest(url: finalURL)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            // 解码 — 不依赖 ChatViewModel.ChatPollResponse, 走自己最小 schema (只要 records[*].ts + role).
            let decoded = try JSONDecoder().decode(BadgePollResponse.self, from: data)
            let baseline = lastSeenTs
            for r in decoded.records where r.role != "user" && r.role != "task" {
                if !baseline.isEmpty && r.ts > baseline {
                    unreadCount += 1
                } else if baseline.isEmpty {
                    // cold start 且没 baseline — 不算 unread (避免老用户首次启动看到大数字)
                    break
                }
                if r.ts > latestKnownTs {
                    latestKnownTs = r.ts
                }
            }
            // 如果 server 给的 last_ts 比本地新, 更新 latestKnownTs (不算 unread, 只追 baseline)
            if let last = decoded.lastTs, last > latestKnownTs {
                latestKnownTs = last
            }
        } catch {
            // 静默 — badge 不是关键路径
        }
    }
}

/// 最小 schema — 只要 ts / role 算 unread, 不解析 text/attachment 节省 cpu.
private struct BadgePollResponse: Codable {
    let records: [BadgeRecord]
    let lastTs: String?

    enum CodingKeys: String, CodingKey {
        case records
        case lastTs = "last_ts"
    }
}

private struct BadgeRecord: Codable {
    let ts: String
    let role: String?

    enum CodingKeys: String, CodingKey {
        case ts
        case role
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ts = try c.decodeIfPresent(String.self, forKey: .ts) ?? ""
        self.role = try c.decodeIfPresent(String.self, forKey: .role)
    }
}

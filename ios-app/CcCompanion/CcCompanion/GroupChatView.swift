//
//  GroupChatView.swift
//  CcCompanion
//
//  Read-only workgroup view for multi-agent coordination messages.
//

import SwiftUI

struct GroupChatView: View {
    @StateObject private var store = GroupStore()
    @AppStorage("group_name") private var groupName: String = "工作群"
    @State private var searchVisible = false
    @State private var searchText = ""
    @State private var showFavorites = false
    @State private var favoriteMessageIds: Set<String> = GroupFavoritesStore.ids()

    private var visibleMessages: [GroupMessage] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searchVisible, !q.isEmpty else { return store.messages }
        return store.messages.filter { message in
            GroupMessageSearch.matches(message, member: store.member(for: message.senderId), query: q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GroupChatStatusStrip(store: store)
            if searchVisible {
                GroupSearchBar(
                    text: $searchText,
                    visibleCount: visibleMessages.count,
                    totalCount: store.messages.count,
                    onClose: {
                        searchText = ""
                        searchVisible = false
                    }
                )
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if store.loading && store.messages.isEmpty {
                            ProgressView("加载工作群")
                                .font(.ccSerifAdaptive(size: 14))
                                .foregroundStyle(Color.ccTextDim)
                                .padding(.top, 40)
                        } else if store.messages.isEmpty {
                            emptyState
                        } else if visibleMessages.isEmpty {
                            GroupSearchEmptyState(query: searchText)
                        } else {
                            ForEach(visibleMessages) { message in
                                let member = store.member(for: message.senderId)
                                GroupMessageRow(
                                    message: message,
                                    member: member,
                                    isFavorite: favoriteMessageIds.contains(message.id),
                                    onToggleFavorite: {
                                        toggleFavorite(message: message, member: member)
                                    }
                                )
                                    .id(message.id)
                            }
                        }

                        if !store.typingMembers.isEmpty {
                            GroupTypingIndicator(members: store.typingMembers)
                                .id("typing-indicator")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .background(Color.ccBg)
                .onChange(of: store.messages.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
                .onChange(of: store.typingMembers.map(\.id).joined(separator: ",")) { _, marker in
                    guard !marker.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo("typing-indicator", anchor: .bottom)
                    }
                }
            }
        }
        .background(Color.ccBg)
        .navigationTitle(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "工作群" : groupName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        searchVisible.toggle()
                        if !searchVisible { searchText = "" }
                    }
                } label: {
                    Image(systemName: searchVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
                }
                .tint(Color.ccAccent)

                Button {
                    showFavorites = true
                } label: {
                    Image(systemName: "star")
                }
                .tint(Color.ccAccent)

                Button {
                    Task { await store.refreshNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .tint(Color.ccAccent)
            }
        }
        .sheet(isPresented: $showFavorites) {
            NavigationStack { GroupFavoritesView() }
        }
        .onAppear {
            favoriteMessageIds = GroupFavoritesStore.ids()
            store.start()
        }
        .onDisappear { store.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .ccGroupFavoritesDidChange)) { _ in
            favoriteMessageIds = GroupFavoritesStore.ids()
        }
        .refreshable { await store.refreshNow() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.ccAccent)
            Text("工作群暂无消息")
                .font(.ccSerifAdaptive(size: 16, weight: .semibold))
                .foregroundStyle(Color.ccText)
            Text("打开后会从 Mac 上的 /group/poll 拉取最近协作消息。")
                .font(.ccSerifAdaptive(size: 13))
                .foregroundStyle(Color.ccTextDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    private func toggleFavorite(message: GroupMessage, member: GroupMember) {
        let isNowFavorite = GroupFavoritesStore.toggle(message: message, member: member)
        favoriteMessageIds = GroupFavoritesStore.ids()
        CcToastBus.shared.show(isNowFavorite ? "已收藏工作群消息" : "已取消收藏")
    }
}

private struct GroupChatStatusStrip: View {
    @ObservedObject var store: GroupStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(statusMembers) { member in
                        let status = store.agentStatus[member.id]
                        HStack(spacing: 6) {
                            Circle()
                                .fill(status?.state == "online" ? Color.green : Color.ccTextDim.opacity(0.35))
                                .frame(width: 7, height: 7)
                            Text(member.title)
                                .font(.ccSerifAdaptive(size: 12, weight: .semibold))
                                .foregroundStyle(Color.ccText)
                            if status?.isTyping == true {
                                Text("typing")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.ccAccent)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.ccCard.opacity(0.75)))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            if let lastError = store.lastError {
                Text(lastError)
                    .font(.ccSerifAdaptive(size: 11))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 7)
            }
        }
        .background(Color.ccBg)
    }

    private var statusMembers: [GroupMember] {
        let preferred = ["opia", "sonnet", "di", "shu", "opus47_fresh"]
        return preferred.map { store.member(for: $0) }
    }
}

private struct GroupMessageRow: View {
    let message: GroupMessage
    let member: GroupMember
    let isFavorite: Bool
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isHumanSender { Spacer(minLength: 46) }

            if !message.isHumanSender {
                avatar
            }

            VStack(alignment: message.isHumanSender ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if message.isHumanSender { messageTypeBadge }
                    Text(member.title)
                        .font(.ccSerifAdaptive(size: 12, weight: .semibold))
                        .foregroundStyle(Color.ccTextDim)
                    Text(message.shortTime)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.ccTextDim.opacity(0.8))
                    if !message.isHumanSender { messageTypeBadge }
                }

                highlightedText(message.text)
                    .font(.ccSerifAdaptive(size: 15))
                    .foregroundStyle(Color.ccText)
                    .lineSpacing(3)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(bubbleColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.ccTextDim.opacity(0.08), lineWidth: 0.5)
                    )
                    .frame(maxWidth: 330, alignment: message.isHumanSender ? .trailing : .leading)
            }

            if message.isHumanSender {
                avatar
            }

            if !message.isHumanSender { Spacer(minLength: 46) }
        }
        .contextMenu {
            Button(action: onToggleFavorite) {
                Label(isFavorite ? "取消收藏" : "收藏", systemImage: isFavorite ? "star.slash" : "star")
            }
        }
    }

    private var avatar: some View {
        GroupAvatarView(member: member, size: 32)
    }

    @ViewBuilder
    private var messageTypeBadge: some View {
        if message.messageType != "chat" {
            Text(message.messageType.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(messageTypeColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(messageTypeColor.opacity(0.12)))
        }
    }

    private var bubbleColor: Color {
        if message.isHumanSender { return Color.ccAccent.opacity(0.16) }
        if message.isBlock { return Color.red.opacity(0.12) }
        if message.isTask { return Color.blue.opacity(0.11) }
        if message.isShip { return Color.green.opacity(0.12) }
        return Color.ccCard.opacity(0.82)
    }

    private var messageTypeColor: Color {
        if message.isBlock { return .red }
        if message.isTask { return .blue }
        if message.isShip { return .green }
        return Color.ccAccent
    }

    private func highlightedText(_ text: String) -> Text {
        let pattern = #"@([A-Za-z0-9_\-]+|[\u{4E00}-\u{9FFF}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return Text(text)
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return Text(text) }

        var result = Text("")
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound {
                result = result + Text(String(text[cursor..<range.lowerBound]))
            }
            result = result + Text(String(text[range]))
                .foregroundColor(Color.ccAccent)
                .bold()
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result = result + Text(String(text[cursor..<text.endIndex]))
        }
        return result
    }
}

private struct GroupTypingIndicator: View {
    let members: [GroupMember]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(members.prefix(3)) { member in
                GroupAvatarView(member: member, size: 26)
            }
            Text("\(members.map(\.title).joined(separator: "、")) 正在输入")
                .font(.ccSerifAdaptive(size: 13))
                .foregroundStyle(Color.ccTextDim)
            GroupTypingDots()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.ccCard.opacity(0.72)))
    }
}

private struct GroupTypingDots: View {
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.32)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.32) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.ccAccent.opacity(phase == i ? 1.0 : 0.35))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        GroupChatView()
    }
}

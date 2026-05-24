//
//  GroupChatView.swift
//  CcCompanion
//
//  Workgroup chat view (build 215 — input parity + bg + contextMenu + scroll-on-focus).
//

import SwiftUI

struct GroupChatView: View {
    @ObservedObject var store: GroupStore
    @AppStorage("group_name") private var groupName: String = "群聊"
    @AppStorage("chat_font_size_level") private var chatFontLevel: String = "medium"
    // Build 215 S1 — 群聊自定义背景, 跟 chat_background_path 独立 key
    @AppStorage("group_chat_background_path") private var groupBackgroundPath: String = ""
    // Build 217 S1 — 群聊整体头像 (SettingsView GroupSettingsEditSheet 编辑后落地, 这里读出)
    @AppStorage("group_avatar_path") private var groupAvatarPath: String = ""
    @State private var searchVisible = false
    @State private var searchText = ""
    // Build 215 P3 — 搜索 filter chip (跟 ChatView 搜索 chip 对齐 + 日期)
    @State private var searchFilter: GroupSearchFilter = .all
    @State private var showFavorites = false
    @State private var favoriteMessageIds: Set<String> = GroupFavoritesStore.ids()

    // Build 214 T1 — input bar state
    @State private var draftText: String = ""
    @FocusState private var inputFocused: Bool
    @State private var showAgentPicker: Bool = false
    @State private var sending: Bool = false
    @State private var inputToast: String = ""
    // Build 217 Q1 — 引用 quoting state (跟 ChatView vm.quoting 同款), 发送时带 reply_to, 不立刻发让用户加文本
    @State private var quoting: GroupMessage? = nil

    private var chatBodySize: CGFloat {
        chatFontLevel == "small" ? 15 : chatFontLevel == "large" ? 18 : 17
    }

    private var visibleMessages: [GroupMessage] {
        guard searchVisible else { return store.messages }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var pool = store.messages
        // Build 215 P3 — filter chip 先过, 再过 text query
        if searchFilter != .all {
            pool = pool.filter { searchFilter.matches($0) }
        }
        guard !q.isEmpty else { return pool }
        return pool.filter { message in
            GroupMessageSearch.matches(message, member: store.member(for: message.senderId), query: q)
        }
    }

    private var headerTitle: String {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "群聊" : trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            customHeader

            GroupChatStatusStrip(store: store)
            // Build 215 P3 — 搜索栏 + filter chip (copy ChatView 模式 ChatView.swift:2704-2743)
            if searchVisible {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.ccTextDim)
                        TextField("搜对话 / 文件名", text: $searchText)
                            .textFieldStyle(.plain)
                            .submitLabel(.search)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.ccTextDim)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.ccCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button("取消") {
                        searchVisible = false
                        searchText = ""
                        searchFilter = .all
                    }
                    .foregroundStyle(Color.ccAccent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                GroupSearchFilterBar(
                    selected: searchFilter,
                    onSelect: { searchFilter = $0 }
                )
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if store.loading && store.messages.isEmpty {
                            ProgressView("加载群聊")
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
                                let parent = parentLookup(for: message)
                                GroupMessageRow(
                                    message: message,
                                    member: member,
                                    bodySize: chatBodySize,
                                    isFavorite: favoriteMessageIds.contains(message.id),
                                    parentPreview: parent.map { ($0.text, store.member(for: $0.senderId).displayName) },
                                    onToggleFavorite: {
                                        toggleFavorite(message: message, member: member)
                                    },
                                    onQuote: { quoteMessage(message, member: member) },
                                    onDelete: { /* T4 stub — server 端删消息单独 spec */ }
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
                // Build 215 S1 — bg image 存在时走 clear 透出 image, 否则走 ccBg
                .background(groupBackgroundPath.isEmpty ? Color.ccBg : Color.clear)
                .refreshable { await store.refreshNow() }
                .scrollDismissesKeyboard(.immediately)
                // Build 217 T8 — 点聊天区域 (空白处) 收起键盘. 不抢 LazyVStack 内 row 的 contextMenu hit-test.
                .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
                // Build 217 T7 — onAppear 立刻 scroll 到最底端 (跟 ChatView 同款进 tab 进底)
                .onAppear {
                    if let id = store.messages.last?.id {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
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
                // Build 215 T3 — 点输入栏聚焦时自动 scroll 到底
                .onChange(of: inputFocused) { _, focused in
                    guard focused, let id = store.messages.last?.id else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }

            if !inputToast.isEmpty {
                Text(inputToast)
                    .font(.ccSerifAdaptive(size: 11))
                    .foregroundStyle(Color.ccTextDim)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Build 217 Q1 — quote preview 条 (跟 ChatView QuotePreviewBar 同款 在 input bar 上方)
            if let q = quoting {
                HStack(spacing: 8) {
                    Image(systemName: "quote.bubble.fill")
                        .font(.ccSerifAdaptive(size: 12))
                        .foregroundStyle(Color.ccAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("引用 \(store.member(for: q.senderId).displayName)")
                            .font(.ccSerifAdaptive(size: 11, weight: .semibold))
                            .foregroundStyle(Color.ccAccent)
                        Text(q.text)
                            .font(.ccSerifAdaptive(size: 12))
                            .foregroundStyle(Color.ccTextDim)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        quoting = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.ccSerifAdaptive(size: 16))
                            .foregroundStyle(Color.ccTextDim)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.ccCard.opacity(0.55))
            }

            GroupInputBar(
                draft: $draftText,
                sending: $sending,
                inputFocused: $inputFocused,
                onSend: { commitSend() },
                onAt: { showAgentPicker = true },
                onPlusFile: {
                    inputToast = "T1 backend wire pending — 文件发送待接 /group/append"
                },
                onPlusCamera: {
                    inputToast = "T1 backend wire pending — 拍照待接 /group/append"
                },
                onImage: {
                    inputToast = "T1 backend wire pending — 图片待接 /group/append"
                }
            )
        }
        // Build 215 S1 — 顶层 ZStack 加群聊背景图渲染 (复用 ChatView 模式)
        .background(
            ZStack {
                Color.ccBg
                #if canImport(UIKit)
                if !groupBackgroundPath.isEmpty,
                   let img = AvatarDiskStore.load(storedValue: groupBackgroundPath) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                #endif
            }
            .id(groupBackgroundPath)
        )
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showFavorites) {
            NavigationStack { GroupFavoritesView() }
        }
        .sheet(isPresented: $showAgentPicker) {
            AgentMentionPicker(
                members: store.agentMembers,
                onPick: { member in
                    insertMention(member: member)
                    showAgentPicker = false
                },
                onPickAll: {
                    // Build 217 T2 — 艾特所有人, draft 插 `@all `, backend 解 mentions=["all"] 走全 agent fan-out
                    if draftText.isEmpty {
                        draftText = "@all "
                    } else if draftText.hasSuffix(" ") || draftText.hasSuffix("\n") {
                        draftText += "@all "
                    } else {
                        draftText += " @all "
                    }
                    showAgentPicker = false
                    inputFocused = true
                }
            )
        }
        .onAppear {
            favoriteMessageIds = GroupFavoritesStore.ids()
            store.start()
            // Build 215 T1 — 用户进入群聊 tab 视为已读, 清未读 / mention 计数
            store.markAllRead()
        }
        .onDisappear { store.snapshotLastSeen() }
        .onReceive(NotificationCenter.default.publisher(for: .ccGroupFavoritesDidChange)) { _ in
            favoriteMessageIds = GroupFavoritesStore.ids()
        }
    }

    @ViewBuilder
    private var customHeader: some View {
        HStack(spacing: 12) {
            // Build 217 S1 — 优先读 group_avatar_path AppStorage 设置过的群头像; 空 fallback SF symbol
            ZStack {
                if !groupAvatarPath.isEmpty,
                   let img = AvatarDiskStore.load(storedValue: groupAvatarPath) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Circle().fill(Color.ccCard.opacity(0.6))
                    Image(systemName: "person.3.sequence.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.ccAccent)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
            Text(headerTitle)
                .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                .foregroundStyle(Color.ccAccent)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    searchVisible.toggle()
                    if !searchVisible { searchText = "" }
                }
            } label: {
                Image(systemName: searchVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
            }
            Button {
                showFavorites = true
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
            }
            Button {
                Task { await store.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.ccSerifAdaptive(size: 18, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.ccBg)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.ccAccent)
            Text("群聊暂无消息")
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
        CcToastBus.shared.show(isNowFavorite ? "已收藏群聊消息" : "已取消收藏")
    }

    // Build 217 Q1 — 引用回复. 设 quoting state 弹 QuotePreviewBar, 不立刻发, 让用户加文本.
    // commitSend 把 quoting.id 当 reply_to 传给 backend, send 完清 quoting.
    private func quoteMessage(_ message: GroupMessage, member: GroupMember) {
        quoting = message
        inputFocused = true
    }

    private func insertMention(member: GroupMember) {
        let token = "@\(member.displayName) "
        if draftText.isEmpty {
            draftText = token
        } else if draftText.hasSuffix(" ") || draftText.hasSuffix("\n") {
            draftText += token
        } else {
            draftText += " " + token
        }
        inputFocused = true
    }

    private func commitSend() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        let mentions = resolveMentions(in: text)
        let replyTo = quoting?.id
        sending = true
        inputToast = ""
        Task {
            let ok = await store.sendUserMessage(text: text, mentions: mentions, replyTo: replyTo)
            await MainActor.run {
                sending = false
                if ok {
                    draftText = ""
                    quoting = nil
                } else {
                    inputToast = store.lastError ?? "发送失败"
                }
            }
        }
    }

    /// Build 217 Q1 — render reply_to 用. parent message 若在当前 messages 列表里查得到返回, 否则 nil.
    private func parentLookup(for message: GroupMessage) -> GroupMessage? {
        let parentId = message.replyTo ?? message.parentMsgId
        guard let parentId, !parentId.isEmpty else { return nil }
        return store.messages.first { $0.id == parentId }
    }

    private func resolveMentions(in text: String) -> [String] {
        let pattern = #"@([A-Za-z0-9_\-]+|[\u{4E00}-\u{9FFF}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var hits: [String] = []
        let agents = store.agentMembers
        for m in matches where m.numberOfRanges >= 2 {
            let token = nsText.substring(with: m.range(at: 1))
            if let hit = agents.first(where: { $0.displayName == token || $0.id == token || $0.title == token }) {
                if !hits.contains(hit.id) { hits.append(hit.id) }
            }
        }
        return hits
    }
}

// MARK: - Status Strip

private struct GroupChatStatusStrip: View {
    @ObservedObject var store: GroupStore

    var body: some View {
        VStack(spacing: 0) {
            // Build 215 T5 — 横向 ScrollView, 不挂任何 .draggable / DragGesture, 元素不能被拖动只能滑.
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
                            // Build 214 T2 — agent 名字后带模型名 半透明小字 (status strip 保留 model)
                            if let model = member.model, !model.isEmpty {
                                Text("· \(model)")
                                    .font(.ccSerifAdaptive(size: 11))
                                    .foregroundStyle(Color.ccTextDim)
                                    .lineLimit(1)
                            }
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

// MARK: - Message Row

private struct GroupMessageRow: View {
    let message: GroupMessage
    let member: GroupMember
    let bodySize: CGFloat
    let isFavorite: Bool
    // Build 217 Q1 — parent message preview (text + sender displayName) 用来 render 引用回复 badge
    let parentPreview: (text: String, senderName: String)?
    let onToggleFavorite: () -> Void
    let onQuote: () -> Void
    let onDelete: () -> Void

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
                    // Build 214 T2 — name · model (message row 保留 model)
                    if let model = member.model, !model.isEmpty {
                        Text("· \(model)")
                            .font(.ccSerifAdaptive(size: 11))
                            .foregroundStyle(Color.ccTextDim.opacity(0.7))
                            .lineLimit(1)
                    }
                    Text(message.shortTime)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.ccTextDim.opacity(0.8))
                    if !message.isHumanSender { messageTypeBadge }
                }

                VStack(alignment: message.isHumanSender ? .trailing : .leading, spacing: 4) {
                    // Build 217 Q1 — 引用 parent message 时 render 一个小 quote 头条
                    if let parent = parentPreview {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.up.left")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.ccAccent)
                            Text("回复 \(parent.senderName): \(parent.text)")
                                .font(.ccSerifAdaptive(size: 11))
                                .foregroundStyle(Color.ccTextDim)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.ccCard.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    highlightedText(message.text)
                        .font(.ccSerifAdaptive(size: bodySize))
                        .foregroundStyle(Color.ccText)
                        .lineSpacing(3)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(bubbleColor)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.ccTextDim.opacity(0.08), lineWidth: 0.5)
                        )
                }
                .frame(maxWidth: 330, alignment: message.isHumanSender ? .trailing : .leading)
            }

            if message.isHumanSender {
                avatar
            }

            if !message.isHumanSender { Spacer(minLength: 46) }
        }
        // Build 215 T4 — contextMenu copy chat 子集 (复制 / 引用 / 收藏 / 分享 / 删除)
        .contextMenu {
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = message.text
                #endif
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button(action: onQuote) {
                Label("引用回复", systemImage: "quote.bubble")
            }
            Button(action: onToggleFavorite) {
                Label(isFavorite ? "取消收藏" : "收藏", systemImage: isFavorite ? "star.slash" : "star")
            }
            ShareLink(item: message.text) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
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

    // Build 217 T6 — bubble 用 solid color 不再带 opacity, 跟 ChatView 视觉一致 (不让背景图透过 bubble 看不清字)
    private var bubbleColor: Color {
        if message.isHumanSender { return Color.ccAccent.opacity(0.22) }
        if message.isBlock { return Color.red.opacity(0.16) }
        if message.isTask { return Color.blue.opacity(0.14) }
        if message.isShip { return Color.green.opacity(0.16) }
        return Color.ccCard
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

// MARK: - Typing Indicator

private struct GroupTypingIndicator: View {
    let members: [GroupMember]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(members.prefix(3)) { member in
                GroupAvatarView(member: member, size: 26)
            }
            // Build 215 T2 — typing indicator 只 title 不带 model (per feedback: model 噪声大)
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

// MARK: - Input Bar (build 215 T7 — icon 顺序对齐 ChatInputBar)

private struct GroupInputBar: View {
    @Binding var draft: String
    @Binding var sending: Bool
    var inputFocused: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onAt: () -> Void
    let onPlusFile: () -> Void
    let onPlusCamera: () -> Void
    let onImage: () -> Void

    private var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Build 215 T7 — 顺序对齐 ChatInputBar: 加号 → 图片 → @ → TextField+mic → 发送
    // 之前是 加号 → @ → TextField → 图片 → 发送 把图片挤到右边 距离不均.
    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button { onPlusCamera() } label: { Label("拍照", systemImage: "camera") }
                Button { onPlusFile() } label: { Label("文件", systemImage: "doc") }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.ccSerifAdaptive(size: 28, weight: .bold))
                    .foregroundStyle(Color.ccTextDim)
            }
            .disabled(sending)

            // 图片按钮 — 摘出加号菜单, 跟 ChatInputBar 同款放第二位 (line 3223)
            Button { onImage() } label: {
                Image(systemName: "photo.fill")
                    .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                    .foregroundStyle(Color.ccTextDim)
            }
            .disabled(sending)

            // @ 按钮 — 群聊特有, 跟 ChatInputBar 图片按钮平级
            Button { onAt() } label: {
                Image(systemName: "at")
                    .font(.ccSerifAdaptive(size: 22, weight: .semibold))
                    .foregroundStyle(Color.ccTextDim)
            }
            .disabled(sending)

            ZStack(alignment: .trailing) {
                TextField("说点什么…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 17))
                    .tint(Color.ccAccent)
                    .padding(.leading, 6)
                    .textFieldStyle(.roundedBorder)
                    .focused(inputFocused)
                    .submitLabel(.send)
                    .onSubmit { onSend() }
                    .onChange(of: draft) { oldValue, newValue in
                        if newValue.hasSuffix("\n") && !oldValue.hasSuffix("\n") {
                            draft = String(newValue.dropLast())
                            onSend()
                        }
                    }
                    .padding(.trailing, 40)

                if !inputFocused.wrappedValue {
                    Image(systemName: "mic")
                        .font(.ccSerifAdaptive(size: 17))
                        .foregroundStyle(Color.ccTextDim.opacity(0.5))
                        .padding(.trailing, 10)
                }
            }

            Button { onSend() } label: {
                Image(systemName: sending ? "ellipsis.circle" : "paperplane.fill")
                    .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                    .scaleEffect(x: sending ? 1 : -1, y: 1)
                    .rotationEffect(.degrees(sending ? 0 : -15))
                    .foregroundStyle(Color.ccAccent.opacity(hasContent ? 1.0 : 0.35))
            }
            .disabled(sending || !hasContent)
        }
        .padding(10)
        .background(Color.ccBg)
    }
}

// MARK: - Agent @ Picker

private struct AgentMentionPicker: View {
    let members: [GroupMember]
    let onPick: (GroupMember) -> Void
    let onPickAll: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Build 217 T2 — 第一行固定 "艾特所有人" 选项, 选中 → @all
                Button {
                    onPickAll()
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.ccAccent.opacity(0.18))
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.ccAccent)
                        }
                        .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("艾特所有人")
                                .font(.ccSerifAdaptive(size: 15, weight: .semibold))
                                .foregroundStyle(Color.ccText)
                            Text("@all 群里全员 fan-out")
                                .font(.ccSerifAdaptive(size: 11))
                                .foregroundStyle(Color.ccTextDim)
                        }
                        Spacer()
                        Text("@all")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.ccAccent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                ForEach(members) { member in
                    Button {
                        onPick(member)
                    } label: {
                        HStack(spacing: 12) {
                            GroupAvatarView(member: member, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName)
                                    .font(.ccSerifAdaptive(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.ccText)
                                if let model = member.model, !model.isEmpty {
                                    Text(model)
                                        .font(.ccSerifAdaptive(size: 11))
                                        .foregroundStyle(Color.ccTextDim)
                                }
                            }
                            Spacer()
                            Text("@\(member.id)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.ccTextDim)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle("选 agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Search Filter (build 215 P3)

/// 群聊搜索 filter chip — 跟 ChatView SearchFilter 对齐 (全部 / 图片视频 / 文件 / 链接 / 音乐音频 / 日期).
/// 当前 GroupMessage 没有 attachment 字段, 图片视频 / 文件 / 音乐音频 只能走文本 URL 后缀粗匹配 (大概率空 result).
/// 链接走 http(s) URL 检测真能用. 日期 chip 暂只切 filter 不弹 date picker (后续 spec).
enum GroupSearchFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case image = "图片视频"
    case file = "文件"
    case link = "链接"
    case audio = "音乐音频"
    case date = "日期"
    var id: String { rawValue }

    func matches(_ message: GroupMessage) -> Bool {
        let text = message.text.lowercased()
        switch self {
        case .all:
            return true
        case .image:
            // 文本中含图片扩展名 URL 粗匹配
            return text.range(of: #"https?://\S+\.(png|jpg|jpeg|gif|webp|heic|mp4|mov)\b"#, options: .regularExpression) != nil
        case .file:
            return text.range(of: #"https?://\S+\.(pdf|zip|doc|docx|xls|xlsx|ppt|pptx|txt|md|json|csv)\b"#, options: .regularExpression) != nil
        case .link:
            return text.range(of: #"https?://"#, options: .regularExpression) != nil
        case .audio:
            return text.range(of: #"https?://\S+\.(mp3|wav|m4a|aac|flac|ogg)\b"#, options: .regularExpression) != nil
        case .date:
            // 日期 chip 当前作 placeholder — 不在前端做日期过滤, 全显示. 后续接 date picker spec
            return true
        }
    }
}

private struct GroupSearchFilterBar: View {
    let selected: GroupSearchFilter
    let onSelect: (GroupSearchFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(GroupSearchFilter.allCases) { filter in
                    Button {
                        onSelect(filter)
                    } label: {
                        Text(filter.rawValue)
                            .font(.footnote.weight(selected == filter ? .semibold : .regular))
                            .foregroundStyle(selected == filter ? Color.white : Color.ccText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(selected == filter ? Color.ccAccent : Color.ccCard)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Color.ccBg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.ccCard)
                .frame(height: 0.5)
        }
    }
}

#Preview {
    NavigationStack {
        GroupChatView(store: GroupStore())
    }
}

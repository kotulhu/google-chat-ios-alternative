import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var authManager: GoogleAuthManager
    let space: ChatSpace
    @State private var draft = ""
    @State private var isSending = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(chatStore.messages(for: space)) { message in
                            MessageBubble(message: message, space: space)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .overlay {
                    if chatStore.loadingSpaceIDs.contains(space.id) {
                        ProgressView("Загрузка сообщений...")
                    } else if chatStore.messages(for: space).isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "bubble.left")
                                .font(.title2)
                            Text("Нет сообщений")
                                .font(.subheadline)
                            if let errorMessage = chatStore.errorMessage {
                                Text(errorMessage)
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.red)
                                Button("Повторить") {
                                    Task {
                                        await chatStore.loadMessages(for: space, accessToken: authManager.accessToken)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding()
                        .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: chatStore.messages(for: space)) { messages in
                    if let lastID = messages.last?.id {
                        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                }
            }

            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Сообщение", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                Button(action: send) {
                    if isSending || chatStore.sendingSpaceIDs.contains(space.id) {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
            .padding()
            .background(.bar)
        }
        .navigationTitle(space.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(space.id)-\(authManager.isSignedIn)") {
            print("[Chat] ChatView task started: space=\(space.id), signedIn=\(authManager.isSignedIn)")
            chatStore.markRead(space)
            await loadMessagesIfAuthorized()
        }
        .onChange(of: authManager.accessToken) { _ in
            Task {
                await loadMessagesIfAuthorized()
            }
        }
        .refreshable {
            await loadMessagesIfAuthorized()
        }
    }

    private func loadMessagesIfAuthorized() async {
        print("[Chat] Authorization state for messages: signedIn=\(authManager.isSignedIn), token=\(authManager.accessToken.isEmpty ? "missing" : "present")")
        guard !authManager.accessToken.isEmpty else { return }
        await chatStore.loadMessages(for: space, accessToken: authManager.accessToken)
    }

    private func send() {
        let text = draft
        print("[Chat] Send button tapped: space=\(space.id), token=\(authManager.accessToken.isEmpty ? "missing" : "present")")
        guard !authManager.accessToken.isEmpty else {
            chatStore.errorMessage = "Сессия Google истекла. Выполните вход снова."
            return
        }
        draft = ""
        isSending = true
        Task {
            await chatStore.send(text, to: space, accessToken: authManager.accessToken)
            isSending = false
        }
    }
}

private struct MessageBubble: View {
    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var authManager: GoogleAuthManager
    let message: Message
    let space: ChatSpace
    @State private var showingReactionMenu = false

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isFromMe { Spacer(minLength: 48) }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                if !message.isFromMe {
                    Text(message.authorName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .background(message.isFromMe ? Color.accentColor : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if message.likeCount > 0 || message.dislikeCount > 0 {
                    HStack(spacing: 6) {
                        if message.likeCount > 0 {
                            ReactionButton(emoji: "👍", count: message.likeCount) {
                                toggle("👍")
                            }
                        }
                        if message.dislikeCount > 0 {
                            ReactionButton(emoji: "👎", count: message.dislikeCount) {
                                toggle("👎")
                            }
                        }
                    }
                }
            }
            if !message.isFromMe { Spacer(minLength: 48) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            toggle("👍")
        }
        .onLongPressGesture {
            showingReactionMenu = true
        }
        .confirmationDialog("Реакция на сообщение", isPresented: $showingReactionMenu, titleVisibility: .visible) {
            Button("👍  Нравится") {
                toggle("👍")
            }
            Button("👎  Не нравится") {
                toggle("👎")
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func toggle(_ emoji: String) {
        Task {
            await chatStore.toggleReaction(to: message, in: space, with: emoji, accessToken: authManager.accessToken)
        }
    }
}

private struct ReactionButton: View {
    let emoji: String
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(emoji) \(count)")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color(uiColor: .tertiarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

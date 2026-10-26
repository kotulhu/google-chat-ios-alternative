import SwiftUI

struct ChatRootView: View {
    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var authManager: GoogleAuthManager
    @State private var selectedSpace: ChatSpace?
    @State private var isSettingsPresented = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSpace) {
                Section("Пространства") {
                    ForEach(chatStore.spaces) { space in
                        NavigationLink(value: space) {
                            SpaceRow(space: space)
                        }
                    }
                }

                Section {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Label("Настройки", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Чаты")
            .navigationDestination(for: ChatSpace.self) { space in
                ChatView(space: space)
            }
        } detail: {
            if let selectedSpace {
                ChatView(space: selectedSpace)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("Выберите чат")
                        .font(.headline)
                    Text("Здесь появятся сообщения выбранного пространства")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .onAppear {
            if selectedSpace == nil {
                selectedSpace = chatStore.spaces.first
            }
        }
        .task(id: authManager.accessToken) {
            guard !authManager.accessToken.isEmpty else { return }
            await chatStore.loadSpaces(accessToken: authManager.accessToken)
            if selectedSpace == nil {
                selectedSpace = chatStore.spaces.first
            }
        }
        .onChange(of: chatStore.spaces) { spaces in
            if let selectedSpace, spaces.contains(where: { $0.id == selectedSpace.id }) == false {
                self.selectedSpace = spaces.first
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Настройки")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if chatStore.isLoadingSpaces {
                    ProgressView()
                }
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = chatStore.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.red, in: Capsule())
                    .padding()
            }
        }
    }
}

private struct SpaceRow: View {
    let space: ChatSpace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(space.name)
                    .font(.body.weight(.medium))
                if let lastMessage = space.lastMessage {
                    Text(lastMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if space.unreadCount > 0 {
                Text("\(space.unreadCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.tint, in: Circle())
            }
        }
        .padding(.vertical, 4)
    }
}

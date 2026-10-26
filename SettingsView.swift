import SwiftUI
import Foundation

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: GoogleAuthManager
    @State private var isCheckingAuthorization = false

    private var clientID: String {
        Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        clientID.isEmpty ? "OAuth Client ID не настроен" : "OAuth Client ID настроен",
                        systemImage: clientID.isEmpty ? "exclamationmark.triangle" : "checkmark.circle"
                    )
                    .foregroundStyle(clientID.isEmpty ? .orange : .secondary)
                } header: {
                    Text("Подключение")
                } footer: {
                    Text("OAuth Client ID берётся из локальной конфигурации сборки и не хранится в исходном коде.")
                }

                Section {
                    Button {
                        Task { await authManager.signIn(clientID: clientID) }
                    } label: {
                        Label(authManager.isSignedIn ? "Вход выполнен" : "Войти через Google", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .disabled(clientID.isEmpty || authManager.isSignedIn)
                    if authManager.isSignedIn {
                        Text(authManager.userEmail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Выйти", role: .destructive) {
                            authManager.signOut()
                        }
                    }
                }

                Section("Проверка") {
                    Button {
                        isCheckingAuthorization = true
                        Task {
                            await authManager.checkChatAuthorization()
                            isCheckingAuthorization = false
                        }
                    } label: {
                        if isCheckingAuthorization {
                            HStack {
                                ProgressView()
                                Text("Проверка подключения...")
                            }
                        } else {
                            Label("Проверить авторизацию", systemImage: "network")
                        }
                    }
                    .disabled(!authManager.isSignedIn || isCheckingAuthorization)

                    if let result = authManager.lastCheckResult {
                        Text(result)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        dismiss()
                    }
                }
            }
        }
    }

}

#Preview {
    SettingsView()
}

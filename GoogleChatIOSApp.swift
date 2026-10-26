import SwiftUI

@main
struct GoogleChatIOSApp: App {
    @StateObject private var chatStore = ChatStore()
    @StateObject private var authManager = GoogleAuthManager()

    var body: some Scene {
        WindowGroup {
            ChatRootView()
                .environmentObject(chatStore)
                .environmentObject(authManager)
                .task {
                    let clientID = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String ?? ""
                    await authManager.restoreSession(clientID: clientID)
                }
        }
    }
}

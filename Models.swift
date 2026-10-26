import Foundation

/// Shared in spirit with the macOS ChatSpace model. API identifiers are kept
/// from the beginning so the local prototype can later consume real spaces.
struct ChatSpace: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var lastMessage: String?
    var unreadCount: Int

    static let samples = [
        ChatSpace(id: "general", name: "Общий чат", lastMessage: "Добро пожаловать в Google Chat", unreadCount: 0),
        ChatSpace(id: "project", name: "Проект iOS", lastMessage: "Обсудим первый экран", unreadCount: 2),
        ChatSpace(id: "direct-alex", name: "Алексей", lastMessage: "Файл уже отправил", unreadCount: 0)
    ]
}

struct Message: Identifiable, Codable, Equatable {
    let id: String
    let text: String
    let authorName: String
    let isFromMe: Bool
    let timestamp: Date
    var likeCount: Int
    var dislikeCount: Int

    init(id: String = UUID().uuidString, text: String, authorName: String, isFromMe: Bool, timestamp: Date = .now, likeCount: Int = 0, dislikeCount: Int = 0) {
        self.id = id
        self.text = text
        self.authorName = authorName
        self.isFromMe = isFromMe
        self.timestamp = timestamp
        self.likeCount = likeCount
        self.dislikeCount = dislikeCount
    }
}

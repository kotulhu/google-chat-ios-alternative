import Foundation
import Combine

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var spaces: [ChatSpace] = ChatSpace.samples
    @Published private(set) var messagesBySpace: [String: [Message]] = [:]
    @Published private(set) var isLoadingSpaces = false
    @Published private(set) var loadingSpaceIDs: Set<String> = []
    @Published private(set) var sendingSpaceIDs: Set<String> = []
    @Published var errorMessage: String?

    private let spacesKey = "ios.chat.spaces"
    private let messagesKey = "ios.chat.messages"
    private let defaults = UserDefaults.standard

    init() {
        load()
    }

    func messages(for space: ChatSpace) -> [Message] {
        if let messages = messagesBySpace[space.id] {
            return messages
        }
        return space.id.hasPrefix("spaces/") ? [] : sampleMessages(for: space)
    }

    func send(_ text: String, to space: ChatSpace, accessToken: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !accessToken.isEmpty, space.id.hasPrefix("spaces/") else { return }
        guard !sendingSpaceIDs.contains(space.id) else { return }

        sendingSpaceIDs.insert(space.id)
        errorMessage = nil
        defer { sendingSpaceIDs.remove(space.id) }

        do {
            let payload = CreateMessagePayload(text: trimmed)
            let message: APIChatMessage = try await post(
                URL(string: "https://chat.googleapis.com/v1/\(space.id)/messages")!,
                payload: payload,
                accessToken: accessToken
            )
            let newMessage = makeMessage(message)
            messagesBySpace[space.id, default: []].append(newMessage)
            updateLastMessage(newMessage.text, in: space.id)
            save()
            print("[Chat] Message sent: \(message.name)")
        } catch let error as URLError where error.code == .cancelled {
            print("[Chat] Send message cancelled")
        } catch {
            errorMessage = error.localizedDescription
            print("[Chat] Failed to send message to \(space.id): \(error.localizedDescription)")
        }
    }

    func markRead(_ space: ChatSpace) {
        guard let index = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        spaces[index].unreadCount = 0
        save()
    }

    func loadSpaces(accessToken: String) async {
        guard !accessToken.isEmpty, !isLoadingSpaces else { return }
        isLoadingSpaces = true
        errorMessage = nil
        defer { isLoadingSpaces = false }

        do {
            var allSpaces: [ChatSpace] = []
            var pageToken: String?

            repeat {
                var components = URLComponents(string: "https://chat.googleapis.com/v1/spaces")!
                components.queryItems = [
                    URLQueryItem(name: "pageSize", value: "100"),
                    URLQueryItem(name: "pageToken", value: pageToken)
                ].filter { $0.value != nil }
                let response: SpaceListResponse = try await request(components.url!, accessToken: accessToken)
                allSpaces.append(contentsOf: response.spaces.map(makeSpace))
                pageToken = response.nextPageToken
            } while pageToken != nil && pageToken != ""

            spaces = allSpaces
            save()
        } catch {
            errorMessage = error.localizedDescription
            print("[Chat] Failed to load spaces: \(error.localizedDescription)")
        }
    }

    func loadMessages(for space: ChatSpace, accessToken: String) async {
        print("[Chat] Load messages requested: space=\(space.id), token=\(accessToken.isEmpty ? "missing" : "present")")
        guard !accessToken.isEmpty,
              space.id.hasPrefix("spaces/"),
              !loadingSpaceIDs.contains(space.id) else { return }
        loadingSpaceIDs.insert(space.id)
        errorMessage = nil
        defer { loadingSpaceIDs.remove(space.id) }

        do {
            var apiMessages: [APIChatMessage] = []
            var pageToken: String?

            repeat {
                var components = URLComponents(string: "https://chat.googleapis.com/v1/\(space.id)/messages")!
                components.queryItems = [
                    URLQueryItem(name: "pageSize", value: "100"),
                    URLQueryItem(name: "orderBy", value: "createTime DESC"),
                    URLQueryItem(name: "pageToken", value: pageToken)
                ].filter { $0.value != nil }
                print("[Chat] Request: GET \(components.url!.absoluteString)")
                let response: MessageListResponse = try await request(components.url!, accessToken: accessToken)
                apiMessages.append(contentsOf: response.messages)
                pageToken = response.nextPageToken
            } while pageToken != nil && pageToken != ""

            messagesBySpace[space.id] = apiMessages
                .reversed()
                .map(makeMessage)
            print("[Chat] Loaded \(messagesBySpace[space.id]?.count ?? 0) messages for \(space.id)")
            if let latest = messagesBySpace[space.id]?.last?.text {
                updateLastMessage(latest, in: space.id)
            }
            save()
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                print("[Chat] Loading messages cancelled for \(space.id)")
                return
            }
            errorMessage = error.localizedDescription
            print("[Chat] Failed to load messages for \(space.id): \(error.localizedDescription)")
        }
    }

    func toggleReaction(to message: Message, in space: ChatSpace, with emoji: String, accessToken: String) async {
        guard !accessToken.isEmpty, space.id.hasPrefix("spaces/") else { return }
        do {
            let reactions = try await listReactions(for: message, emoji: emoji, accessToken: accessToken)
            if let ownReaction = reactions.first {
                try await deleteReaction(ownReaction, accessToken: accessToken)
                print("[Chat] Reaction removed: \(ownReaction.name)")
            } else {
                let reaction: APIChatReaction = try await post(
                    URL(string: "https://chat.googleapis.com/v1/\(message.id)/reactions")!,
                    payload: CreateReactionPayload(emoji: ReactionEmoji(unicode: emoji)),
                    accessToken: accessToken
                )
                print("[Chat] Reaction added: \(reaction.name)")
            }
            await loadMessages(for: space, accessToken: accessToken)
        } catch {
            errorMessage = error.localizedDescription
            print("[Chat] Failed to toggle reaction: \(error.localizedDescription)")
        }
    }

    private func listReactions(for message: Message, emoji: String, accessToken: String) async throws -> [APIChatReaction] {
        var components = URLComponents(string: "https://chat.googleapis.com/v1/\(message.id)/reactions")!
        components.queryItems = [
            URLQueryItem(name: "pageSize", value: "200"),
            URLQueryItem(name: "filter", value: "user.name = \"users/me\" AND emoji.unicode = \"\(emoji)\"")
        ]
        let response: ReactionListResponse = try await request(
            components.url!,
            accessToken: accessToken
        )
        return response.reactions
    }

    private func deleteReaction(_ reaction: APIChatReaction, accessToken: String) async throws {
        let url = URL(string: "https://chat.googleapis.com/v1/\(reaction.name)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[Chat] Response status: \(statusCode) for DELETE \(url.absoluteString)")
        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw ChatAPIError.http(statusCode, body)
        }
    }

    private func request<T: Decodable>(_ url: URL, accessToken: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[Chat] Response status: \(statusCode) for \(url.absoluteString)")
        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            print("[Chat] Response body: \(body)")
            throw ChatAPIError.http(statusCode, body)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[Chat] Response decode failed: \(error.localizedDescription)")
            print("[Chat] Response body: \(String(data: data, encoding: .utf8) ?? "<non-UTF8 response>")")
            throw error
        }
    }

    private func post<T: Decodable, Payload: Encodable>(_ url: URL, payload: Payload, accessToken: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        print("[Chat] Request: POST \(url.absoluteString)")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[Chat] Response status: \(statusCode) for POST \(url.absoluteString)")
        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            print("[Chat] Response body: \(body)")
            throw ChatAPIError.http(statusCode, body)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func makeSpace(_ space: APIChatSpace) -> ChatSpace {
        ChatSpace(id: space.name, name: space.displayName ?? space.name, lastMessage: nil, unreadCount: 0)
    }

    private func makeMessage(_ message: APIChatMessage) -> Message {
        let reactions = message.emojiReactionSummaries ?? []
        return Message(
            id: message.name,
            text: message.text ?? "",
            authorName: message.sender?.displayName ?? "Неизвестный пользователь",
            isFromMe: message.sender?.name == "users/me",
            timestamp: ISO8601DateFormatter().date(from: message.createTime ?? "") ?? .now,
            likeCount: reactions.first(where: { $0.emoji?.unicode == "👍" })?.reactionCount ?? 0,
            dislikeCount: reactions.first(where: { $0.emoji?.unicode == "👎" })?.reactionCount ?? 0
        )
    }

    private func updateLastMessage(_ text: String, in spaceID: String) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        spaces[index].lastMessage = text
    }

    private func sampleMessages(for space: ChatSpace) -> [Message] {
        switch space.id {
        case "project":
            return [
                Message(text: "Начинаем перенос Google Chat на iOS.", authorName: "Команда", isFromMe: false, timestamp: .now.addingTimeInterval(-3600)),
                Message(text: "Сначала сделаем список чатов и отправку текста.", authorName: "Команда", isFromMe: false, timestamp: .now.addingTimeInterval(-1800))
            ]
        case "direct-alex":
            return [Message(text: "Файл уже отправил", authorName: "Алексей", isFromMe: false, timestamp: .now.addingTimeInterval(-900))]
        default:
            return [Message(text: "Добро пожаловать в Google Chat", authorName: "Команда", isFromMe: false, timestamp: .now.addingTimeInterval(-7200))]
        }
    }

    private func load() {
        if let data = defaults.data(forKey: spacesKey),
           let savedSpaces = try? JSONDecoder().decode([ChatSpace].self, from: data) {
            spaces = savedSpaces
        }
        if let data = defaults.data(forKey: messagesKey),
           let savedMessages = try? JSONDecoder().decode([String: [Message]].self, from: data) {
            messagesBySpace = savedMessages
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(spaces) {
            defaults.set(data, forKey: spacesKey)
        }
        if let data = try? JSONEncoder().encode(messagesBySpace) {
            defaults.set(data, forKey: messagesKey)
        }
    }
}

private struct SpaceListResponse: Decodable {
    let spaces: [APIChatSpace]
    let nextPageToken: String?

    enum CodingKeys: String, CodingKey {
        case spaces
        case nextPageToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spaces = try container.decodeIfPresent([APIChatSpace].self, forKey: .spaces) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

private struct APIChatSpace: Decodable {
    let name: String
    let displayName: String?
}

private struct MessageListResponse: Decodable {
    let messages: [APIChatMessage]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeIfPresent([APIChatMessage].self, forKey: .messages) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }

    private enum CodingKeys: String, CodingKey {
        case messages
        case nextPageToken
    }
}

private struct APIChatMessage: Decodable {
    let name: String
    let text: String?
    let createTime: String?
    let sender: APIChatUser?
    let emojiReactionSummaries: [APIEmojiReactionSummary]?
}

private struct CreateMessagePayload: Encodable {
    let text: String
}

private struct APIChatUser: Decodable {
    let name: String?
    let displayName: String?
}

private struct APIEmojiReactionSummary: Decodable {
    let emoji: ReactionEmoji?
    let reactionCount: Int?
}

private struct ReactionEmoji: Codable {
    let unicode: String?
}

private struct CreateReactionPayload: Encodable {
    let emoji: ReactionEmoji
}

private struct APIChatReaction: Decodable {
    let name: String
    let user: APIChatUser?
    let emoji: ReactionEmoji?
}

private struct ReactionListResponse: Decodable {
    let reactions: [APIChatReaction]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reactions = try container.decodeIfPresent([APIChatReaction].self, forKey: .reactions) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }

    private enum CodingKeys: String, CodingKey {
        case reactions
        case nextPageToken
    }
}

private enum ChatAPIError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case let .http(statusCode, body):
            return "Google Chat API: HTTP \(statusCode) (\(body))"
        }
    }
}

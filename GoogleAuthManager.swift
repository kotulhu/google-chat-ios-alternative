import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
final class GoogleAuthManager: NSObject, ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var accessToken = ""
    @Published private(set) var userEmail = ""
    @Published private(set) var lastCheckResult: String?

    private var browserSession: ASWebAuthenticationSession?
    private var refreshToken = ""
    private let refreshTokenKey = "googlechat.oauth.refresh_token"
    private let scopeSignatureKey = "googlechat.oauth.scope_signature"

    private let scopes = [
        "https://www.googleapis.com/auth/chat.spaces.readonly",
        "https://www.googleapis.com/auth/chat.messages.readonly",
        "https://www.googleapis.com/auth/chat.messages.create",
        "https://www.googleapis.com/auth/chat.messages.reactions.readonly",
        "https://www.googleapis.com/auth/chat.messages.reactions.create",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile"
    ]

    private var scopeSignature: String {
        scopes.joined(separator: " ")
    }

    func signIn(clientID: String) async {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            print("[Auth] OAuth sign-in skipped: client ID is empty")
            return
        }

        let verifier = randomString(length: 64)
        let challenge = sha256Base64URL(verifier)
        let state = randomString(length: 32)
        let callbackURLScheme = reversedClientID(from: clientID)
        if let configuredScheme = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_REVERSED_CLIENT_ID") as? String,
           !configuredScheme.isEmpty,
           configuredScheme != callbackURLScheme {
            lastCheckResult = "Client ID не совпадает с OAuth-конфигурацией приложения"
            print("[Auth] OAuth sign-in skipped: configured callback scheme does not match client ID")
            return
        }
        let redirectURI = "\(callbackURLScheme):/oauth2redirect"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        print("[Auth] Starting browser OAuth authorization")
        print("[Auth] Authorization request: GET https://accounts.google.com/o/oauth2/v2/auth")
        print("[Auth] OAuth redirect URI: \(redirectURI)")
        print("[Auth] OAuth client ID: <configured>")
        print("[Auth] Requested scopes: \(scopes.joined(separator: ", "))")

        do {
            let callbackURL = try await openBrowser(url: components.url!, callbackURLScheme: callbackURLScheme)
            guard let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  callback.queryItems?.first(where: { $0.name == "state" })?.value == state else {
                print("[Auth] OAuth callback rejected: invalid state")
                return
            }
            guard let code = callback.queryItems?.first(where: { $0.name == "code" })?.value else {
                let error = callback.queryItems?.first(where: { $0.name == "error" })?.value ?? "unknown_error"
                print("[Auth] OAuth callback returned error: \(error)")
                return
            }

            try await exchangeCode(code, verifier: verifier, clientID: clientID, redirectURI: redirectURI)
            print("[Auth] OAuth sign-in succeeded")
            print("[Auth] Access token received: \(accessToken.isEmpty ? "no" : "yes")")
        } catch {
            print("[Auth] OAuth sign-in failed: \(error.localizedDescription)")
        }
    }

    func restoreSession(clientID: String) async {
        guard !isSignedIn else { return }
        guard keychainValue(for: scopeSignatureKey) == scopeSignature else {
            deleteKeychainValue(for: refreshTokenKey)
            deleteKeychainValue(for: scopeSignatureKey)
            print("[Auth] Stored session discarded because OAuth scopes changed")
            return
        }
        guard let storedRefreshToken = keychainValue(for: refreshTokenKey),
              !storedRefreshToken.isEmpty else { return }

        do {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "refresh_token", value: storedRefreshToken),
                URLQueryItem(name: "grant_type", value: "refresh_token")
            ]
            request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
            print("[Auth] Restoring Google session with refresh token")

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(statusCode) else {
                deleteKeychainValue(for: refreshTokenKey)
                print("[Auth] Session restore failed: HTTP \(statusCode)")
                return
            }

            let token = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
            accessToken = token.access_token
            isSignedIn = true
            logGrantedScopes(token.scope)
            print("[Auth] Google session restored")
        } catch {
            print("[Auth] Session restore failed: \(error.localizedDescription)")
        }
    }

    func signOut() {
        browserSession?.cancel()
        browserSession = nil
        isSignedIn = false
        accessToken = ""
        refreshToken = ""
        deleteKeychainValue(for: refreshTokenKey)
        deleteKeychainValue(for: scopeSignatureKey)
        userEmail = ""
        print("[Auth] Google session signed out")
    }

    func checkChatAuthorization() async {
        guard !accessToken.isEmpty else {
            lastCheckResult = "Сначала выполните вход через Google"
            print("[Auth] Chat API check skipped: no OAuth access token")
            return
        }

        var request = URLRequest(url: URL(string: "https://chat.googleapis.com/v1/spaces")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        print("[Auth] Request: GET https://chat.googleapis.com/v1/spaces")
        print("[Auth] Request authorization: Bearer <redacted>")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
            print("[Auth] Response status: \(statusCode)")
            print("[Auth] Response headers: \((response as? HTTPURLResponse)?.allHeaderFields ?? [:])")
            print("[Auth] Response body: \(body)")
            lastCheckResult = (200..<300).contains(statusCode)
                ? "OAuth работает (HTTP \(statusCode))"
                : "OAuth отклонён (HTTP \(statusCode))"
        } catch {
            print("[Auth] Chat API request failed: \(error.localizedDescription)")
            lastCheckResult = "Ошибка запроса: \(error.localizedDescription)"
        }
    }

    private func exchangeCode(_ code: String, verifier: String, clientID: String, redirectURI: String) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        print("[Auth] Request: POST https://oauth2.googleapis.com/token")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[Auth] Token response status: \(statusCode)")
        guard (200..<300).contains(statusCode) else {
            print("[Auth] Token response body: \(String(data: data, encoding: .utf8) ?? "<non-UTF8 response>")")
            throw URLError(.userAuthenticationRequired)
        }
        let token = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        accessToken = token.access_token
        refreshToken = token.refresh_token ?? ""
        if !refreshToken.isEmpty {
            saveKeychainValue(refreshToken, for: refreshTokenKey)
        }
        saveKeychainValue(scopeSignature, for: scopeSignatureKey)
        isSignedIn = true
        logGrantedScopes(token.scope)
    }

    private func keychainValue(for key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveKeychainValue(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private func deleteKeychainValue(for key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func logGrantedScopes(_ grantedScopes: String?) {
        print("[Auth] Granted scopes: \(grantedScopes ?? "<not returned>")")
    }

    private func openBrowser(url: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme) { [weak self] callback, error in
                self?.browserSession = nil
                if let error {
                    let nsError = error as NSError
                    print("[Auth] Browser callback error: domain=\(nsError.domain), code=\(nsError.code), message=\(nsError.localizedDescription)")
                    continuation.resume(throwing: error)
                } else if let callback {
                    print("[Auth] OAuth callback received: scheme=\(callback.scheme ?? "<none>"), host=\(callback.host ?? "<none>")")
                    continuation.resume(returning: callback)
                } else {
                    print("[Auth] Browser callback finished without URL or error")
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            browserSession = session
            let started = session.start()
            print("[Auth] Browser session start result: \(started)")
            if !started {
                browserSession = nil
                continuation.resume(throwing: URLError(.cannotOpenFile))
            }
        }
    }

    private func randomString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    /// Google iOS OAuth clients require the reversed dot-separated client ID.
    /// For example, 123.apps.googleusercontent.com becomes
    /// com.googleusercontent.apps.123.
    private func reversedClientID(from clientID: String) -> String {
        clientID
            .split(separator: ".")
            .reversed()
            .map(String.init)
            .joined(separator: ".")
    }

    private func sha256Base64URL(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct OAuthTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let scope: String?
}

extension GoogleAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })
        return window ?? ASPresentationAnchor()
    }
}

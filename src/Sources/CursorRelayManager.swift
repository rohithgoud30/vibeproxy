import Foundation
import Security

/**
 Owns the "Codex Proxy for Cursor" feature: a persistent relay API key, the
 authenticated CursorRelayServer on port 8319, and a Cloudflare quick tunnel
 (via TunnelManager) that makes the relay reachable from Cursor's backend.

 Cursor setup once running:
 - Override OpenAI Base URL: <tunnel URL>/v1
 - OpenAI API Key: the relay API key
 */
class CursorRelayManager {
    static let relayPort: UInt16 = 8319

    private static let apiKeyDefaultsKey = "cursorRelayAPIKey"
    private static let enabledDefaultsKey = "cursorRelayEnabled"

    private let server = CursorRelayServer(listenPort: CursorRelayManager.relayPort)
    private let tunnel = TunnelManager()

    private(set) var isStarting = false

    var isRunning: Bool { server.isRunning && tunnel.isRunning }

    /// OpenAI-compatible base URL for Cursor, e.g. https://xxx.trycloudflare.com/v1
    var cursorBaseURL: String? {
        guard isRunning, let url = tunnel.publicURL else { return nil }
        return url + "/v1"
    }

    /// Whether the user wants the relay on (persisted; relay auto-starts with the server).
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey) }
    }

    /// The relay API key, generated on first use and persisted.
    var apiKey: String {
        if let existing = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey), !existing.isEmpty {
            return existing
        }
        return regenerateAPIKey()
    }

    @discardableResult
    func regenerateAPIKey() -> String {
        let key = Self.generateKey()
        UserDefaults.standard.set(key, forKey: Self.apiKeyDefaultsKey)
        server.apiKey = key
        return key
    }

    private static func generateKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0...255)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Starts the relay server and the public tunnel. Completion delivers the
    /// Cursor base URL (tunnel URL + /v1) on success.
    func start(completion: @escaping (Bool, String?) -> Void) {
        server.apiKey = apiKey
        server.start()
        isStarting = true
        NotificationCenter.default.post(name: .serverStatusChanged, object: nil)

        tunnel.start(port: Int(Self.relayPort)) { [weak self] success, url in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isStarting = false
                if !success {
                    self.server.stop()
                }
                NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
                completion(success, url.map { $0 + "/v1" })
            }
        }
    }

    func stop() {
        tunnel.stop()
        server.stop()
        isStarting = false
        NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
    }
}

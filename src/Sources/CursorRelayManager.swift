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

    private static let legacyAPIKeyDefaultsKey = "cursorRelayAPIKey"
    private static let enabledDefaultsKey = "cursorRelayEnabled"
    private static let keychainService = "io.automaze.vibeproxy.cursor-relay"
    private static let keychainAccount = "relay-api-key"

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

    /// The relay API key — an authentication secret, so it lives in the
    /// Keychain (not UserDefaults). Generated on first use and persisted.
    var apiKey: String {
        if let existing = Self.keychainRead(), !existing.isEmpty {
            return existing
        }
        // Migrate any key written to UserDefaults by older builds — but only
        // scrub the plaintext copy once it is safely in the Keychain, so a
        // Keychain failure can't silently rotate the user's credentials.
        if let legacy = UserDefaults.standard.string(forKey: Self.legacyAPIKeyDefaultsKey), !legacy.isEmpty {
            if Self.keychainWrite(legacy) {
                UserDefaults.standard.removeObject(forKey: Self.legacyAPIKeyDefaultsKey)
            }
            return legacy
        }
        return regenerateAPIKey()
    }

    @discardableResult
    func regenerateAPIKey() -> String {
        let key = Self.generateKey()
        if Self.keychainWrite(key) {
            UserDefaults.standard.removeObject(forKey: Self.legacyAPIKeyDefaultsKey)
        }
        server.apiKey = key
        return key
    }

    // MARK: - Keychain (generic password in the login keychain)

    private static func keychainRead() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    /// Persists the key to the Keychain. Returns true only on success.
    @discardableResult
    private static func keychainWrite(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("[CursorRelay] Keychain add failed: %d", Int(addStatus))
                return false
            }
            return true
        } else if updateStatus != errSecSuccess {
            NSLog("[CursorRelay] Keychain update failed: %d", Int(updateStatus))
            return false
        }
        return true
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
    /// Cursor base URL (tunnel URL + /v1) on success. The tunnel is only
    /// started once the relay listener has actually bound, so we never expose
    /// a public URL pointing at a relay that failed to come up.
    func start(completion: @escaping (Bool, String?) -> Void) {
        server.apiKey = apiKey
        server.start()
        isStarting = true
        NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
        waitForRelayReady(attempts: 0, maxAttempts: 40, intervalMs: 50, completion: completion)
    }

    private func waitForRelayReady(attempts: Int, maxAttempts: Int, intervalMs: Int, completion: @escaping (Bool, String?) -> Void) {
        if server.isRunning {
            startTunnel(completion: completion)
            return
        }
        if attempts >= maxAttempts {
            NSLog("[CursorRelay] Relay listener did not become ready; aborting tunnel start")
            server.stop()
            isStarting = false
            NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
            completion(false, nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(intervalMs) / 1000.0) { [weak self] in
            self?.waitForRelayReady(attempts: attempts + 1, maxAttempts: maxAttempts, intervalMs: intervalMs, completion: completion)
        }
    }

    private func startTunnel(completion: @escaping (Bool, String?) -> Void) {
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

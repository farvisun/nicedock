import Foundation
import Security

/// Widget credentials live in the login Keychain, never in the JSON state file.
enum Secrets {
    private static let service = "app.cooldock.credentials"
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    private static func account(_ id: UUID, _ key: String) -> String { "\(id.uuidString).\(key)" }

    static func get(_ id: UUID, _ key: String) -> String? {
        let acct = account(id, key)
        lock.lock(); defer { lock.unlock() }
        if let v = cache[acct] { return v.isEmpty ? nil : v }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        let value = status == errSecSuccess ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        cache[acct] = value ?? ""
        return value
    }

    static func set(_ value: String?, _ id: UUID, _ key: String) {
        let acct = account(id, key)
        lock.lock(); defer { lock.unlock() }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct
        ]
        SecItemDelete(base as CFDictionary)
        cache[acct] = value ?? ""
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "CoolDock widget credential"
        SecItemAdd(add as CFDictionary, nil)
    }

    static func removeAll(for id: UUID) {
        for key in ["token", "secret", "password"] { set(nil, id, key) }
    }

    static func copyAll(from: UUID, to: UUID) {
        for key in ["token", "secret", "password"] {
            if let v = get(from, key) { set(v, to, key) }
        }
    }

    /// Removes every CoolDock credential from the Keychain.
    static func wipe() {
        lock.lock(); defer { lock.unlock() }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
        cache.removeAll()
    }
}

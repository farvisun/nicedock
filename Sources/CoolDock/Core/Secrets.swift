import CryptoKit
import Foundation
import IOKit
import Security

/// Widget credentials live outside the JSON state file: in the login Keychain (default, recommended) or, for Macs where
/// the login Keychain can't be unlocked reliably, in an AES-GCM encrypted file (Settings → Privacy & Permissions →
/// Credential Storage). The call sites only see this facade.
enum Secrets {
    /// Process-wide vault. Test processes get an in-memory one (see `CredentialVault.live()`), so no test can reach
    /// the real Keychain or the user's credential file.
    nonisolated(unsafe) static var vault: CredentialVault = .live()

    private static func account(_ id: UUID, _ key: String) -> String { "\(id.uuidString).\(key)" }

    static func get(_ id: UUID, _ key: String) -> String? { vault.get(account(id, key)) }

    @discardableResult
    static func set(_ value: String?, _ id: UUID, _ key: String) -> Bool { vault.set(value, account(id, key)) }

    static func removeAll(for id: UUID) {
        for key in ["token", "secret", "password"] { set(nil, id, key) }
    }

    static func copyAll(from: UUID, to: UUID) {
        for key in ["token", "secret", "password"] {
            if let v = get(from, key) { set(v, to, key) }
        }
    }

    /// Removes every NiceDock credential from the active storage.
    static func wipe() { vault.wipe() }

    static var backend: CredentialBackend { vault.backend }

    /// Moves every credential to `target` and makes it the active storage. See `CredentialVault.switchBackend`.
    static func switchBackend(to target: CredentialBackend) throws -> CredentialMigration { try vault.switchBackend(to: target) }

    static func status() -> CredentialStatus { vault.status() }

    /// Puts an unreadable credential file aside so a fresh one can be written.
    static func resetEncryptedFile() throws { try vault.resetEncryptedFile() }
}

// MARK: - Backends

enum CredentialBackend: String, Codable, CaseIterable, Identifiable {
    case keychain, encryptedFile
    var id: String { rawValue }
}

/// One place credentials can be stored. Accounts are "<widget UUID>.<key>". Implementations need not be thread-safe;
/// `CredentialVault` serialises every call.
protocol CredentialStore: AnyObject {
    func read(_ account: String) throws -> String?
    /// nil or "" deletes.
    func write(_ value: String?, _ account: String) throws
    func accounts() throws -> [String]
    /// Writes several values at once (one encryption pass for the file store).
    func write(contentsOf items: [String: String]) throws
    func removeAll() throws
}

extension CredentialStore {
    func write(contentsOf items: [String: String]) throws {
        for (account, value) in items.sorted(by: { $0.key < $1.key }) { try write(value, account) }
    }
}

enum CredentialError: Error, Equatable {
    case keychain(OSStatus)
    /// The encrypted file failed authentication: it was modified, or it was written on another Mac / with another key.
    case tampered
    /// The encrypted file isn't a NiceDock credential file (truncated, wrong format, unknown version).
    case corrupt
    /// The credential file exists but its key file is gone.
    case keyMissing
    case io(String)
    /// A migrated value didn't read back identically from the destination.
    case verifyFailed

    var message: String {
        switch self {
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            return L("The Keychain reported an error: %@", text)
        case .tampered: return L("The encrypted credential file was modified or comes from another Mac.")
        case .corrupt: return L("The encrypted credential file is damaged.")
        case .keyMissing: return L("The key of the encrypted credential file is missing.")
        case .io(let text): return text
        case .verifyFailed: return L("A credential didn't read back correctly, so nothing was moved.")
        }
    }
}

/// Generic passwords in the login Keychain, service `app.nicedock.credentials`.
final class KeychainCredentialStore: CredentialStore {
    let service: String

    init(service: String = "app.nicedock.credentials") { self.service = service }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    func read(_ account: String) throws -> String? {
        var query = base
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        return (out as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    func write(_ value: String?, _ account: String) throws {
        var query = base
        query[kSecAttrAccount as String] = account
        let deleted = SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else {
            if deleted != errSecSuccess && deleted != errSecItemNotFound { throw CredentialError.keychain(deleted) }
            return
        }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecAttrLabel as String] = "NiceDock widget credential"
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }

    func accounts() throws -> [String] {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        return ((out as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    func removeAll() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }
}

/// Credentials in one AES-256-GCM encrypted file, for Macs where the login Keychain can't be unlocked reliably.
///
/// Layout (`~/Library/Application Support/NiceDock/`):
/// * `credentials.cdvault` — JSON envelope `{format, version, kdf, cipher, salt, sealed}`; `sealed` is the AES-GCM
///   combined box (12-byte random nonce ‖ ciphertext ‖ 16-byte tag) of the JSON dictionary account → value.
///   The format name, version and salt are authenticated as associated data, so editing any of them is detected.
/// * `credentials.key` — 32 random bytes created on first use (`0600`).
///
/// Key = HKDF-SHA256(input: key-file bytes ‖ the Mac's hardware UUID, salt: per-install random 32-byte salt from the
/// envelope, info: "app.nicedock.credentials.v1"). Every save uses a fresh nonce. Both files are written atomically
/// with owner-only permissions.
///
/// Threat model, stated plainly: the file protects tokens when the credential file is copied on its own (a synced or
/// shared folder, a support upload, a stray commit) and when the NiceDock folder is copied to another Mac (the hardware
/// UUID differs). It does **not** protect against malware or a person using your macOS account, root, or a complete
/// copy of this Mac's disk, because everything needed to derive the key is readable by your account. The login
/// Keychain is stronger and stays the recommended option.
final class EncryptedFileCredentialStore: CredentialStore {
    static let format = "app.nicedock.credentials"
    static let version = 1
    static let info = Data("app.nicedock.credentials.v1".utf8)

    let fileURL: URL
    let keyURL: URL
    private let machineID: () -> String

    init(directory: URL, machineID: @escaping () -> String = MachineIdentity.hardwareUUID) {
        fileURL = directory.appendingPathComponent("credentials.cdvault")
        keyURL = directory.appendingPathComponent("credentials.key")
        self.machineID = machineID
    }

    struct Envelope: Codable, Equatable {
        var format: String
        var version: Int
        var kdf: String
        var cipher: String
        var salt: Data
        var sealed: Data
    }

    var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    // MARK: CredentialStore

    func read(_ account: String) throws -> String? {
        let v = try load()[account]
        return v?.isEmpty == false ? v : nil
    }

    func write(_ value: String?, _ account: String) throws {
        var items = try load()
        if let value, !value.isEmpty { items[account] = value } else {
            guard items[account] != nil else { return }
            items[account] = nil
        }
        try save(items)
    }

    func write(contentsOf new: [String: String]) throws {
        var items = try load()
        for (k, v) in new { items[k] = v.isEmpty ? nil : v }
        try save(items)
    }

    func accounts() throws -> [String] { try load().keys.sorted() }

    func removeAll() throws {
        for url in [fileURL, keyURL] where FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch { throw CredentialError.io(error.localizedDescription) }
        }
    }

    // MARK: File

    /// Decrypted contents; an absent file is an empty store.
    func load() throws -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else {
            if exists { throw CredentialError.io(L("NiceDock can't read the encrypted credential file.")) }
            return [:]
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data),
              env.format == Self.format, env.version == Self.version, env.salt.count == 32 else { throw CredentialError.corrupt }
        guard let secret = try? Data(contentsOf: keyURL), secret.count == 32 else { throw CredentialError.keyMissing }
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(combined: env.sealed)
            plain = try AES.GCM.open(box, using: key(secret: secret, salt: env.salt), authenticating: Self.aad(env.salt))
        } catch {
            throw CredentialError.tampered
        }
        guard let items = try? JSONDecoder().decode([String: String].self, from: plain) else { throw CredentialError.corrupt }
        return items
    }

    func save(_ items: [String: String]) throws {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let secret = try installSecret(creating: !exists)
            // Keep the per-install salt; a new store gets a new one.
            let salt = (try? JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL)))?.salt ?? Self.random(32)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let plain = try enc.encode(items)
            let box = try AES.GCM.seal(plain, using: key(secret: secret, salt: salt), nonce: AES.GCM.Nonce(), authenticating: Self.aad(salt))
            guard let sealed = box.combined else { throw CredentialError.corrupt }
            let env = Envelope(format: Self.format, version: Self.version, kdf: "HKDF-SHA256", cipher: "AES-256-GCM", salt: salt, sealed: sealed)
            try Self.writePrivate(enc.encode(env), to: fileURL)
        } catch let e as CredentialError {
            throw e
        } catch {
            throw CredentialError.io(error.localizedDescription)
        }
    }

    /// Renames an unreadable file to `credentials.cdvault.unreadable-<time>` and drops the key, so the next save starts
    /// a fresh store. The old file is kept in case the user can restore the matching key.
    func quarantine(now: Date = Date()) throws {
        let fm = FileManager.default
        if exists {
            let stamp = Int(now.timeIntervalSince1970)
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent("credentials.cdvault.unreadable-\(stamp)")
            do { try fm.moveItem(at: fileURL, to: aside) } catch { throw CredentialError.io(error.localizedDescription) }
        }
        if fm.fileExists(atPath: keyURL.path) {
            let stamp = Int(now.timeIntervalSince1970)
            try? fm.moveItem(at: keyURL, to: keyURL.deletingLastPathComponent().appendingPathComponent("credentials.key.unreadable-\(stamp)"))
        }
    }

    // MARK: Crypto

    private func installSecret(creating: Bool) throws -> Data {
        if let s = try? Data(contentsOf: keyURL), s.count == 32 { return s }
        guard creating else { throw CredentialError.keyMissing }
        let s = Self.random(32)
        try Self.writePrivate(s, to: keyURL)
        return s
    }

    private func key(secret: Data, salt: Data) -> SymmetricKey {
        var ikm = secret
        ikm.append(Data(machineID().utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: Self.info, outputByteCount: 32)
    }

    static func aad(_ salt: Data) -> Data {
        var d = Data("\(format)|v\(version)|".utf8)
        d.append(salt)
        return d
    }

    static func random(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    /// Atomic write, then owner read/write only.
    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum MachineIdentity {
    /// IOPlatformUUID of this Mac (stable across reinstalls, different on every Mac).
    static func hardwareUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "unknown-mac" }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? String) ?? "unknown-mac"
    }
}

/// In-memory store: the stand-in for both backends inside test processes.
final class MemoryCredentialStore: CredentialStore {
    var items: [String: String] = [:]
    init(_ items: [String: String] = [:]) { self.items = items }
    func read(_ account: String) throws -> String? { items[account] }
    func write(_ value: String?, _ account: String) throws { items[account] = value?.isEmpty == false ? value : nil }
    func accounts() throws -> [String] { items.keys.sorted() }
    func removeAll() throws { items.removeAll() }
}

// MARK: - Vault

struct CredentialMigration: Equatable {
    var from: CredentialBackend
    var to: CredentialBackend
    /// Credentials now stored in `to`.
    var moved: Int
    /// Accounts that couldn't be read from `from`; they stay there and those widgets need to be connected again.
    var unreadable: [String]
}

struct CredentialStatus: Equatable {
    enum FileState: Equatable {
        /// No credential file yet (nothing stored, or Keychain in use).
        case none
        case ready(count: Int)
        case unreadable(CredentialError)
    }

    var backend: CredentialBackend
    var file: FileState
    /// Shown in Settings with `~` for the home folder.
    var filePath: String
}

/// Thread-safe credential access with a read cache and the Keychain ⇄ encrypted file switch.
final class CredentialVault: @unchecked Sendable {
    let keychain: CredentialStore
    let file: CredentialStore
    private let loadPreference: () -> CredentialBackend?
    private let savePreference: (CredentialBackend) -> Void
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private(set) var backend: CredentialBackend
    /// True for the vault test processes get: no real Keychain, no files in the user's Library.
    let isIsolated: Bool

    init(keychain: CredentialStore, file: CredentialStore,
         loadPreference: @escaping () -> CredentialBackend?, savePreference: @escaping (CredentialBackend) -> Void,
         isIsolated: Bool = false) {
        self.keychain = keychain
        self.file = file
        self.loadPreference = loadPreference
        self.savePreference = savePreference
        self.isIsolated = isIsolated
        backend = loadPreference() ?? .keychain
    }

    static let preferenceKey = "CredentialStorage"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NiceDock", isDirectory: true)
    }

    /// The real stores, or in-memory ones when this process is a test runner.
    static func live() -> CredentialVault {
        if isTestProcess {
            var preference: CredentialBackend?
            return CredentialVault(keychain: MemoryCredentialStore(), file: MemoryCredentialStore(),
                                   loadPreference: { preference }, savePreference: { preference = $0 }, isIsolated: true)
        }
        return CredentialVault(
            keychain: KeychainCredentialStore(),
            file: EncryptedFileCredentialStore(directory: directory),
            loadPreference: { UserDefaults.standard.string(forKey: preferenceKey).flatMap(CredentialBackend.init(rawValue:)) },
            savePreference: { UserDefaults.standard.set($0.rawValue, forKey: preferenceKey) })
    }

    static var isTestProcess: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || env["XCTestSessionIdentifier"] != nil { return true }
        let name = ProcessInfo.processInfo.processName
        if name == "xctest" || name.hasPrefix("swiftpm-testing-helper") || name.hasSuffix("PackageTests") { return true }
        return Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
    }

    private func store(_ b: CredentialBackend) -> CredentialStore { b == .keychain ? keychain : file }

    // MARK: Access

    func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let v = cache[account] { return v.isEmpty ? nil : v }
        // A failed read is cached as "missing" so a locked Keychain isn't asked again on every refresh.
        let value = (try? store(backend).read(account)) ?? nil
        cache[account] = value ?? ""
        return value
    }

    @discardableResult
    func set(_ value: String?, _ account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            try store(backend).write(value, account)
            cache[account] = value ?? ""
            return true
        } catch {
            NSLog("NiceDock credential write failed: \((error as? CredentialError)?.message ?? error.localizedDescription)")
            cache[account] = nil
            return false
        }
    }

    func wipe() {
        lock.lock(); defer { lock.unlock() }
        try? store(backend).removeAll()
        // A file left behind by an earlier switch goes too; the Keychain is only touched when it is in use.
        if backend == .keychain { try? file.removeAll() }
        cache.removeAll()
    }

    // MARK: Switching

    /// Copies every readable credential from the active storage to `target`, verifies each one reads back, and only
    /// then deletes it from the old storage and makes `target` active. On any write or verification error the
    /// destination is rolled back and the active storage stays as it was. Stale entries already in `target` are
    /// replaced (the active storage is the source of truth). Unreadable source items stay where they are.
    func switchBackend(to target: CredentialBackend) throws -> CredentialMigration {
        lock.lock(); defer { lock.unlock() }
        let from = backend
        guard target != from else { return CredentialMigration(from: from, to: target, moved: 0, unreadable: []) }
        let source = store(from)
        let destination = store(target)

        var items: [String: String] = [:]
        var unreadable: [String] = []
        let accounts: [String]
        do { accounts = try source.accounts() } catch {
            // The list itself is unreadable (e.g. a tampered file): nothing can be carried over.
            accounts = []
        }
        for account in accounts {
            do {
                if let v = try source.read(account), !v.isEmpty { items[account] = v }
            } catch {
                unreadable.append(account)
            }
        }

        try destination.removeAll()
        do {
            if !items.isEmpty { try destination.write(contentsOf: items) }
            for (account, value) in items {
                if try destination.read(account) != value { throw CredentialError.verifyFailed }
            }
        } catch {
            try? destination.removeAll()
            throw error
        }

        for account in items.keys { try? source.write(nil, account) }
        if from == .encryptedFile && unreadable.isEmpty { try? source.removeAll() }
        backend = target
        savePreference(target)
        cache.removeAll()
        return CredentialMigration(from: from, to: target, moved: items.count, unreadable: unreadable.sorted())
    }

    // MARK: Settings

    func status() -> CredentialStatus {
        lock.lock(); defer { lock.unlock() }
        var path = (file as? EncryptedFileCredentialStore)?.fileURL.path ?? "~/Library/Application Support/NiceDock/credentials.cdvault"
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
        let state: CredentialStatus.FileState
        if let f = file as? EncryptedFileCredentialStore, !f.exists {
            state = .none
        } else {
            do {
                let n = try file.accounts().count
                state = backend == .encryptedFile || n > 0 ? .ready(count: n) : .none
            } catch let e as CredentialError {
                state = .unreadable(e)
            } catch {
                state = .unreadable(.io(error.localizedDescription))
            }
        }
        return CredentialStatus(backend: backend, file: state, filePath: path)
    }

    func resetEncryptedFile() throws {
        lock.lock(); defer { lock.unlock() }
        if let f = file as? EncryptedFileCredentialStore { try f.quarantine() } else { try file.removeAll() }
        cache.removeAll()
    }
}

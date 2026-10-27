import CryptoKit
import Foundation
import Testing
@testable import CoolDock

/// Stand-in for the login Keychain. These tests never construct `KeychainCredentialStore`.
final class FakeKeychain: CredentialStore {
    var items: [String: String]
    /// Accounts whose read fails like a locked / damaged Keychain item.
    var unreadable: Set<String> = []
    var failWrites = false
    var writes = 0

    init(_ items: [String: String] = [:]) { self.items = items }

    func read(_ account: String) throws -> String? {
        if unreadable.contains(account) { throw CredentialError.keychain(-25293) } // errSecAuthFailed
        return items[account]
    }

    func write(_ value: String?, _ account: String) throws {
        if failWrites, value != nil { throw CredentialError.keychain(-25308) } // errSecInteractionNotAllowed
        writes += 1
        items[account] = value?.isEmpty == false ? value : nil
    }

    func accounts() throws -> [String] { items.keys.sorted() }
    func removeAll() throws { items = items.filter { unreadable.contains($0.key) } }
}

/// Encrypted local-file credential storage and the Keychain ⇄ file migration.
@Suite struct CredentialStorageTests {
    static let mac = "8C1F6A52-3B0E-4C55-9F0B-6D2E1A7C9B41"

    /// A fresh directory per test, removed by the caller.
    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cooldock-cred-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func fileStore(_ dir: URL, mac: String = mac) -> EncryptedFileCredentialStore {
        EncryptedFileCredentialStore(directory: dir, machineID: { mac })
    }

    static func vault(keychain: CredentialStore, file: CredentialStore, start: CredentialBackend = .keychain) -> (CredentialVault, () -> CredentialBackend?) {
        var saved: CredentialBackend? = start
        let v = CredentialVault(keychain: keychain, file: file, loadPreference: { saved }, savePreference: { saved = $0 })
        return (v, { saved })
    }

    static let tokens = [
        "11111111-1111-1111-1111-111111111111.token": "sk_live_51H8xYz-stripe",
        "22222222-2222-2222-2222-222222222222.token": "ghp_16C7e42F292c6912E7710c838347Ae178B4a",
        "33333333-3333-3333-3333-333333333333.feedURL": "https://calendar.google.com/calendar/ical/abc%40group/private-0123456789abcdef/basic.ics",
        "44444444-4444-4444-4444-444444444444.token": "توکن-فارسی ✓",
    ]

    // MARK: Isolation

    @Test func testProcessesNeverReachTheRealKeychain() {
        #expect(CredentialVault.isTestProcess)
        #expect(Secrets.vault.isIsolated)
        #expect(Secrets.vault.keychain is MemoryCredentialStore)
        #expect(Secrets.vault.file is MemoryCredentialStore)
    }

    // MARK: Encrypted file

    @Test func roundTrip() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Self.fileStore(dir)
        for (k, v) in Self.tokens { try store.write(v, k) }

        let reopened = Self.fileStore(dir)
        #expect(try reopened.load() == Self.tokens)
        #expect(try reopened.accounts() == Self.tokens.keys.sorted())
        #expect(try reopened.read("missing") == nil)

        try reopened.write(nil, "11111111-1111-1111-1111-111111111111.token")
        #expect(try Self.fileStore(dir).read("11111111-1111-1111-1111-111111111111.token") == nil)
        try reopened.write("", "22222222-2222-2222-2222-222222222222.token")
        #expect(try Self.fileStore(dir).accounts().count == 2)
    }

    @Test func fileHoldsNoPlaintextAndIsPrivate() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Self.fileStore(dir)
        try store.write(contentsOf: Self.tokens)
        let raw = try Data(contentsOf: store.fileURL)
        let text = String(decoding: raw, as: UTF8.self)
        for (account, value) in Self.tokens {
            #expect(!text.contains(value))
            #expect(!text.contains(account))
            #expect(raw.range(of: Data(value.utf8)) == nil)
        }
        let env = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: raw)
        #expect(env.format == "app.cooldock.credentials" && env.version == 1)
        #expect(env.kdf == "HKDF-SHA256" && env.cipher == "AES-256-GCM")
        #expect(env.salt.count == 32)
        #expect(env.sealed.count > 12 + 16)
        for url in [store.fileURL, store.keyURL] {
            let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(perms == 0o600, "\(url.lastPathComponent)")
        }
        #expect(try Data(contentsOf: store.keyURL).count == 32)
    }

    @Test func everySaveUsesAFreshNonceAndKeepsTheSalt() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Self.fileStore(dir)
        try store.write(contentsOf: Self.tokens)
        let first = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: Data(contentsOf: store.fileURL))
        try store.save(Self.tokens)
        let second = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: Data(contentsOf: store.fileURL))
        #expect(first.salt == second.salt)
        #expect(first.sealed.prefix(12) != second.sealed.prefix(12))
        #expect(first.sealed != second.sealed)
    }

    @Test func keyIsHKDFOverTheKeyFileAndTheMachine() throws {
        // Decrypt independently with the documented derivation.
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Self.fileStore(dir)
        try store.write(contentsOf: Self.tokens)
        let env = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: Data(contentsOf: store.fileURL))
        var ikm = try Data(contentsOf: store.keyURL)
        ikm.append(Data(Self.mac.utf8))
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: env.salt,
                                         info: Data("app.cooldock.credentials.v1".utf8), outputByteCount: 32)
        var aad = Data("app.cooldock.credentials|v1|".utf8)
        aad.append(env.salt)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: env.sealed), using: key, authenticating: aad)
        #expect(try JSONDecoder().decode([String: String].self, from: plain) == Self.tokens)
    }

    // MARK: Tamper detection

    private func tampered(_ edit: (inout EncryptedFileCredentialStore.Envelope) -> Void) throws -> Error? {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Self.fileStore(dir)
        try store.write(contentsOf: Self.tokens)
        var env = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: Data(contentsOf: store.fileURL))
        edit(&env)
        try JSONEncoder().encode(env).write(to: store.fileURL)
        do { _ = try Self.fileStore(dir).load(); return nil } catch { return error }
    }

    @Test func flippedCiphertextBitIsDetected() throws {
        let error = try tampered { env in
            var bytes = [UInt8](env.sealed)
            bytes[20] ^= 0x01
            env.sealed = Data(bytes)
        }
        #expect(error as? CredentialError == .tampered)
    }

    @Test func flippedTagOrNonceIsDetected() throws {
        #expect(try tampered { env in var b = [UInt8](env.sealed); b[b.count - 1] ^= 0x80; env.sealed = Data(b) } as? CredentialError == .tampered)
        #expect(try tampered { env in var b = [UInt8](env.sealed); b[0] ^= 0x01; env.sealed = Data(b) } as? CredentialError == .tampered)
    }

    @Test func changedSaltIsDetected() throws {
        // The salt is authenticated data and feeds the key: editing it can't go unnoticed.
        let error = try tampered { env in env.salt = EncryptedFileCredentialStore.random(32) }
        #expect(error as? CredentialError == .tampered)
    }

    @Test func swappedBoxFromAnotherInstallIsDetected() throws {
        let other = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: other) }
        let foreign = Self.fileStore(other)
        try foreign.write("attacker-chosen", "11111111-1111-1111-1111-111111111111.token")
        let foreignBox = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: Data(contentsOf: foreign.fileURL)).sealed
        let error = try tampered { env in env.sealed = foreignBox }
        #expect(error as? CredentialError == .tampered)
    }

    @Test func unknownVersionOrDamagedFileIsCorrupt() throws {
        #expect(try tampered { env in env.version = 2 } as? CredentialError == .corrupt)
        #expect(try tampered { env in env.format = "something.else" } as? CredentialError == .corrupt)
        #expect(try tampered { env in env.sealed = Data(env.sealed.prefix(10)) } as? CredentialError == .tampered)

        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Self.fileStore(dir)
        try store.write(contentsOf: Self.tokens)
        let raw = try Data(contentsOf: store.fileURL)
        try raw.prefix(raw.count / 2).write(to: store.fileURL)
        #expect(throws: CredentialError.corrupt) { try Self.fileStore(dir).load() }
        // Nothing is silently overwritten while the file is unreadable.
        #expect(throws: CredentialError.corrupt) { try Self.fileStore(dir).write("x", "a.token") }
        #expect(try Data(contentsOf: store.fileURL) == raw.prefix(raw.count / 2))
    }

    @Test func copiedToAnotherMacIsUnreadable() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.fileStore(dir).write(contentsOf: Self.tokens)
        // Same files (data + key), different hardware UUID.
        #expect(throws: CredentialError.tampered) { try Self.fileStore(dir, mac: "00000000-0000-0000-0000-000000000000").load() }
    }

    @Test func fileWithoutItsKeyIsUnreadable() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Self.fileStore(dir)
        try store.write(contentsOf: Self.tokens)
        try FileManager.default.removeItem(at: store.keyURL)
        #expect(throws: CredentialError.keyMissing) { try Self.fileStore(dir).load() }
        #expect(throws: CredentialError.keyMissing) { try Self.fileStore(dir).write("x", "a.token") }
    }

    @Test func quarantineKeepsTheBadFileAndStartsFresh() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Self.fileStore(dir)
        try store.write(contentsOf: Self.tokens)
        try FileManager.default.removeItem(at: store.keyURL)
        try store.quarantine(now: Date(timeIntervalSince1970: 1_793_000_000))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains("credentials.cdvault.unreadable-1793000000"))
        #expect(try store.load().isEmpty)
        try store.write("fresh", "a.token")
        #expect(try Self.fileStore(dir).read("a.token") == "fresh")
    }

    // MARK: Vault and migration

    @Test func keychainToFileMovesEverything() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = FakeKeychain(Self.tokens)
        let file = Self.fileStore(dir)
        let (vault, saved) = Self.vault(keychain: keychain, file: file)
        #expect(vault.get("11111111-1111-1111-1111-111111111111.token") == "sk_live_51H8xYz-stripe") // warms the cache

        let result = try vault.switchBackend(to: .encryptedFile)
        #expect(result == CredentialMigration(from: .keychain, to: .encryptedFile, moved: 4, unreadable: []))
        #expect(vault.backend == .encryptedFile)
        #expect(saved() == .encryptedFile)
        #expect(keychain.items.isEmpty)
        #expect(try file.load() == Self.tokens)
        for (k, v) in Self.tokens { #expect(vault.get(k) == v) }

        // New writes go to the file only.
        vault.set("new", "55555555-5555-5555-5555-555555555555.token")
        #expect(keychain.items.isEmpty)
        #expect(try Self.fileStore(dir).read("55555555-5555-5555-5555-555555555555.token") == "new")
        #expect(vault.status() == CredentialStatus(backend: .encryptedFile, file: .ready(count: 5), filePath: vault.status().filePath))
    }

    @Test func fileToKeychainMovesEverythingAndDeletesTheFile() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = FakeKeychain(["stale.token": "old"])
        let file = Self.fileStore(dir)
        try file.write(contentsOf: Self.tokens)
        let (vault, saved) = Self.vault(keychain: keychain, file: file, start: .encryptedFile)

        let result = try vault.switchBackend(to: .keychain)
        #expect(result.moved == 4 && result.unreadable.isEmpty)
        #expect(keychain.items == Self.tokens) // the stale entry was replaced: the file was the source of truth
        #expect(!FileManager.default.fileExists(atPath: file.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: file.keyURL.path))
        #expect(saved() == .keychain)
        #expect(vault.status().file == .none)
        for (k, v) in Self.tokens { #expect(vault.get(k) == v) }
    }

    @Test func roundTripKeychainFileKeychain() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = FakeKeychain(Self.tokens)
        let (vault, _) = Self.vault(keychain: keychain, file: Self.fileStore(dir))
        _ = try vault.switchBackend(to: .encryptedFile)
        _ = try vault.switchBackend(to: .keychain)
        #expect(keychain.items == Self.tokens)
        #expect(vault.backend == .keychain)
        // Switching to the active backend is a no-op.
        #expect(try vault.switchBackend(to: .keychain).moved == 0)
    }

    @Test func failedWritesRollBackAndKeepTheOldStorage() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = FakeKeychain()
        keychain.failWrites = true
        let file = Self.fileStore(dir)
        try file.write(contentsOf: Self.tokens)
        let (vault, saved) = Self.vault(keychain: keychain, file: file, start: .encryptedFile)

        #expect(throws: CredentialError.keychain(-25308)) { try vault.switchBackend(to: .keychain) }
        #expect(vault.backend == .encryptedFile)
        #expect(saved() == .encryptedFile)
        #expect(try file.load() == Self.tokens)
        #expect(keychain.items.isEmpty)
        for (k, v) in Self.tokens { #expect(vault.get(k) == v) }
    }

    @Test func unreadableKeychainItemsStayAndAreReported() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = FakeKeychain(Self.tokens)
        keychain.unreadable = ["22222222-2222-2222-2222-222222222222.token"]
        let file = Self.fileStore(dir)
        let (vault, _) = Self.vault(keychain: keychain, file: file)

        let result = try vault.switchBackend(to: .encryptedFile)
        #expect(result.moved == 3)
        #expect(result.unreadable == ["22222222-2222-2222-2222-222222222222.token"])
        #expect(keychain.items.keys.sorted() == ["22222222-2222-2222-2222-222222222222.token"])
        #expect(try file.accounts().count == 3)
    }

    @Test func tamperedFileShowsAsUnreadableAndCanBeReset() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = Self.fileStore(dir)
        try file.write(contentsOf: Self.tokens)
        var env = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: Data(contentsOf: file.fileURL))
        var sealed = [UInt8](env.sealed)
        sealed[sealed.count / 2] ^= 0x40
        env.sealed = Data(sealed)
        try JSONEncoder().encode(env).write(to: file.fileURL)

        let (vault, _) = Self.vault(keychain: FakeKeychain(), file: file, start: .encryptedFile)
        #expect(vault.status().file == .unreadable(.tampered))
        #expect(vault.get("11111111-1111-1111-1111-111111111111.token") == nil)
        #expect(!vault.set("x", "a.token")) // refuses to overwrite what it can't read
        try vault.resetEncryptedFile()
        #expect(vault.status().file == .none)
        #expect(vault.set("x", "a.token"))
        #expect(vault.get("a.token") == "x")
    }

    @Test func wipeClearsTheActiveStorage() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = FakeKeychain(Self.tokens)
        let (vault, _) = Self.vault(keychain: keychain, file: Self.fileStore(dir))
        _ = vault.get("11111111-1111-1111-1111-111111111111.token")
        vault.wipe()
        #expect(keychain.items.isEmpty)
        #expect(vault.get("11111111-1111-1111-1111-111111111111.token") == nil)
    }
}

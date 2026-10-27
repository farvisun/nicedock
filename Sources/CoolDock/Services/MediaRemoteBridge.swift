import AppKit

/// System-wide Now Playing (browsers, Podcasts, VLC, IINA… anything in Control Center) through MediaRemote.
///
/// Since macOS 15.4 MediaRemote only answers Apple-signed clients, so NiceDock runs `/usr/bin/perl` with a tiny
/// helper library (`Helpers/MediaRemote`, bundled in `Contents/Resources/MediaRemote`) that streams one JSON object
/// per line and takes commands on stdin. The helper exits as soon as its stdin closes, so it never outlives NiceDock.
@MainActor
final class MediaRemoteBridge {
    struct Update: Decodable, Equatable {
        var type: String
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var timestamp: Double?
        var rate: Double?
        var playing: Bool?
        var pid: Int32?
        var bundle: String?
        var parent: String?
        var artworkID: String?
        var artwork: String?
    }

    /// Splits a byte stream into complete lines (the helper's output can arrive in arbitrary chunks).
    struct LineBuffer {
        private var pending = Data()
        mutating func append(_ data: Data) -> [Data] {
            pending.append(data)
            var lines: [Data] = []
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                if !line.isEmpty { lines.append(Data(line)) }
                pending.removeSubrange(pending.startIndex...nl)
            }
            return lines
        }
    }

    static let perl = "/usr/bin/perl"

    /// Set by tests that build the helper themselves.
    static var directoryOverride: URL?

    /// Helper files: the app bundle's `Resources/MediaRemote`, or `COOLDOCK_MEDIAREMOTE_DIR` (tests, dev builds).
    static var helperDirectory: URL? {
        if let directoryOverride { return directoryOverride }
        if let dir = ProcessInfo.processInfo.environment["COOLDOCK_MEDIAREMOTE_DIR"] { return URL(fileURLWithPath: dir) }
        return Bundle.main.resourceURL?.appendingPathComponent("MediaRemote")
    }

    static var isAvailable: Bool {
        guard let dir = helperDirectory else { return false }
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: perl)
            && fm.fileExists(atPath: dir.appendingPathComponent("mediaremote.pl").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("libCoolDockMediaRemote.dylib").path)
    }

    var onUpdate: ((Update) -> Void)?
    /// Called when the helper can't run (missing files, MediaRemote refused, repeated crashes): fall back to AppleScript.
    var onUnavailable: (() -> Void)?
    /// True once the helper said it is ready; until then the AppleScript sources stay in charge.
    private(set) var isReady = false

    private var process: Process?
    private var input: FileHandle?
    private var lines = LineBuffer()
    private var crashes = 0
    private var stopped = true

    func start() {
        guard stopped else { return }
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        isReady = false
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
    }

    func send(_ command: String) {
        guard isReady, let input else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    private func launch() {
        guard Self.isAvailable, let dir = Self.helperDirectory else { onUnavailable?(); return }
        // Writing to a helper that just died must not kill NiceDock.
        signal(SIGPIPE, SIG_IGN)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.perl)
        p.arguments = [dir.appendingPathComponent("mediaremote.pl").path, dir.appendingPathComponent("libCoolDockMediaRemote.dylib").path]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        lines = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.terminated(proc, status: status) } }
        }
        do {
            try p.run()
            process = p
            input = stdin.fileHandleForWriting
        } catch {
            onUnavailable?()
        }
    }

    private func consume(_ data: Data) {
        for line in lines.append(data) {
            guard let update = try? JSONDecoder().decode(Update.self, from: line) else { continue }
            if update.type == "ready" { isReady = true; crashes = 0; continue }
            onUpdate?(update)
        }
    }

    private func terminated(_ p: Process, status: Int32) {
        guard p === process else { return }
        process = nil
        input = nil
        let wasReady = isReady
        isReady = false
        guard !stopped else { return }
        crashes += 1
        // A helper that never got ready (MediaRemote refused) or keeps crashing: hand over to AppleScript.
        guard wasReady, crashes <= 3 else { stopped = true; onUnavailable?(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(crashes) * 2) { [weak self] in
            guard let self, !self.stopped else { return }
            self.launch()
        }
    }
}

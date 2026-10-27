import Foundation
@testable import CoolDock

/// Fixture files under `Tests/Fixtures/<provider>/`. Real responses were captured with curl on the
/// date in their file name; `*-docs.json` files follow the provider's documented response schema.
enum Fixture {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    static func data(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }

    static func string(_ path: String) throws -> String { String(decoding: try data(path), as: UTF8.self) }

    static func json(_ path: String) throws -> Any { try ConnJSON.decode(data(path)) }

    static func object(_ path: String) throws -> [String: Any] { try ConnJSON.object(data(path)) }
}

/// Local-calendar dates (the app buckets in the user's time zone), so expectations hold in any zone.
enum TestDate {
    static func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        ConnDate.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    static func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
}

extension Double {
    /// Equality within `eps` for money/float sums.
    func near(_ other: Double, _ eps: Double = 1e-9) -> Bool { abs(self - other) <= eps * max(1, abs(other)) }
}

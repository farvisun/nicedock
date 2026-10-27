import Foundation

/// A JSON document as a value: what the MCP server reads from stdin, sends to the app and returns to clients.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Accessors

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    var isNull: Bool { self == .null }

    /// Whole numbers only (JSON-RPC ids, positions).
    var intValue: Int? {
        guard case .number(let n) = self, n.rounded() == n, abs(n) < 9e15 else { return nil }
        return Int(n)
    }

    /// Short human-readable rendering for error messages.
    var brief: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n.rounded() == n && abs(n) < 9e15 ? String(Int(n)) : String(n)
        case .string(let s): return "\"\(s.count > 60 ? String(s.prefix(60)) + "…" : s)\""
        case .array: return "an array"
        case .object: return "an object"
        }
    }

    // MARK: Encoding

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

    /// Compact single-line JSON (newline-delimited framing relies on it) with sorted keys for stable output.
    func encoded(pretty: Bool = false) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data("null".utf8)
    }

    func text(pretty: Bool = false) -> String { String(decoding: encoded(pretty: pretty), as: UTF8.self) }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 9e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// No ExpressibleByNilLiteral on purpose: `flag ? nil : value` must stay Optional.none, not JSON null.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements) { _, new in new }) }
}

extension JSONValue {
    static func int(_ v: Int) -> JSONValue { .number(Double(v)) }
    static func double(_ v: Double) -> JSONValue { .number(v) }
    static func strings(_ v: [String]) -> JSONValue { .array(v.map { .string($0) }) }
    /// Optional string → string or null.
    static func optional(_ v: String?) -> JSONValue { v.map { .string($0) } ?? .null }
}

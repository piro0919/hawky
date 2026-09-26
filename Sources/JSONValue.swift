import Foundation

/// キーの並びを保つ JSON。`~/.claude/settings.json` を書き換えるために使う。
/// Foundation の JSONSerialization は辞書の並びを保たないので、そのまま書き戻すと
/// 利用者の設定ファイルのキーが丸ごと並べ替わる。書き出しは Node の
/// `JSON.stringify(value, null, 2)` と同じ形にして、以前の install.mjs と差が出ないようにする
enum JSONValue: Equatable {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    /// 数値は読んだ文字のまま持つ。浮動小数に通すと桁や書き方が変わる
    case number(String)
    case bool(Bool)
    case null

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.array(let a), .array(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// そのキーの値を差し替える。無ければ末尾に足す。nil なら消す
    func setting(_ key: String, _ value: JSONValue?) -> JSONValue {
        guard case .object(var pairs) = self else { return self }
        if let index = pairs.firstIndex(where: { $0.key == key }) {
            if let value { pairs[index].value = value } else { pairs.remove(at: index) }
        } else if let value {
            pairs.append((key, value))
        }
        return .object(pairs)
    }

    // MARK: - 書き出し

    func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent + 1)
        let close = String(repeating: "  ", count: indent)
        switch self {
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            let body = pairs.map { "\(pad)\(Self.quote($0.key)): \($0.value.serialized(indent: indent + 1))" }
            return "{\n\(body.joined(separator: ",\n"))\n\(close)}"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let body = items.map { "\(pad)\($0.serialized(indent: indent + 1))" }
            return "[\n\(body.joined(separator: ",\n"))\n\(close)]"
        case .string(let text): return Self.quote(text)
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    /// JSON.stringify と同じ逃がし方。制御文字と `"` `\` だけを逃がし、日本語や `/` はそのまま
    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - 読み込み

    struct ParseError: Error {}

    static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        let value = try parser.value()
        parser.skipSpace()
        guard parser.atEnd else { throw ParseError() }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        var atEnd: Bool { index >= scalars.count }

        mutating func skipSpace() {
            while !atEnd, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
        }

        mutating func value() throws -> JSONValue {
            skipSpace()
            guard !atEnd else { throw ParseError() }
            switch scalars[index] {
            case "{": return try object()
            case "[": return try array()
            case "\"": return .string(try string())
            case "t":
                try literal("true")
                return .bool(true)
            case "f":
                try literal("false")
                return .bool(false)
            case "n":
                try literal("null")
                return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            for scalar in word.unicodeScalars {
                guard !atEnd, scalars[index] == scalar else { throw ParseError() }
                index += 1
            }
        }

        mutating func object() throws -> JSONValue {
            index += 1
            var pairs: [(key: String, value: JSONValue)] = []
            skipSpace()
            if !atEnd, scalars[index] == "}" {
                index += 1
                return .object(pairs)
            }
            while true {
                skipSpace()
                guard !atEnd, scalars[index] == "\"" else { throw ParseError() }
                let key = try string()
                skipSpace()
                guard !atEnd, scalars[index] == ":" else { throw ParseError() }
                index += 1
                pairs.append((key, try value()))
                skipSpace()
                guard !atEnd else { throw ParseError() }
                if scalars[index] == "," {
                    index += 1
                    continue
                }
                guard scalars[index] == "}" else { throw ParseError() }
                index += 1
                return .object(pairs)
            }
        }

        mutating func array() throws -> JSONValue {
            index += 1
            var items: [JSONValue] = []
            skipSpace()
            if !atEnd, scalars[index] == "]" {
                index += 1
                return .array(items)
            }
            while true {
                items.append(try value())
                skipSpace()
                guard !atEnd else { throw ParseError() }
                if scalars[index] == "," {
                    index += 1
                    continue
                }
                guard scalars[index] == "]" else { throw ParseError() }
                index += 1
                return .array(items)
            }
        }

        mutating func string() throws -> String {
            index += 1
            var out = String.UnicodeScalarView()
            while !atEnd {
                let scalar = scalars[index]
                index += 1
                switch scalar {
                case "\"": return String(out)
                case "\\":
                    guard !atEnd else { throw ParseError() }
                    let escape = scalars[index]
                    index += 1
                    switch escape {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        var code = try hex4()
                        // サロゲートの組は1文字に戻す
                        if (0xD800...0xDBFF).contains(code), index + 1 < scalars.count,
                            scalars[index] == "\\", scalars[index + 1] == "u"
                        {
                            index += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let decoded = Unicode.Scalar(code) else { throw ParseError() }
                        out.append(decoded)
                    default: throw ParseError()
                    }
                default: out.append(scalar)
                }
            }
            throw ParseError()
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= scalars.count else { throw ParseError() }
            let digits = String(String.UnicodeScalarView(scalars[index..<index + 4]))
            index += 4
            guard let code = UInt32(digits, radix: 16) else { throw ParseError() }
            return code
        }

        mutating func number() throws -> JSONValue {
            let start = index
            while !atEnd, "+-0123456789.eE".unicodeScalars.contains(scalars[index]) { index += 1 }
            guard index > start else { throw ParseError() }
            return .number(String(String.UnicodeScalarView(scalars[start..<index])))
        }
    }
}

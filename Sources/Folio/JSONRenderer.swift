import Foundation

/// JSON → colour-coded, collapsible HTML. Keeps key order and numbers exactly as written,
/// and folds with <details> so it works with page scripts disabled.
enum JSONRenderer {
    indirect enum Value {
        case object([(key: String, value: Value)])
        case array([Value])
        case string(String)  // raw source between the quotes, escapes kept as written
        case number(String)
        case bool(Bool)
        case null
    }

    struct ParseError: Error {
        let message: String
        let line: Int
        let column: Int
    }

    static func render(_ text: String) -> String {
        do {
            var parser = Parser(Array(text.utf8))
            let value = try parser.parseDocument()
            return "<div class=\"json\">\(html(value, key: nil, last: true))</div>"
        } catch let error as ParseError {
            return """
            <div class="json-error">Invalid JSON: \(HTMLRenderer.escape(error.message)) \
            (line \(error.line), column \(error.column))</div>
            <pre><code>\(HTMLRenderer.escape(text))</code></pre>
            """
        } catch {
            return ""
        }
    }

    // MARK: HTML

    private static func html(_ value: Value, key: String?, last: Bool) -> String {
        let keyHTML = key.map { "<span class=\"k\">\"\(HTMLRenderer.escape($0))\"</span><span class=\"p\">: </span>" } ?? ""
        let comma = last ? "" : "<span class=\"p\">,</span>"

        func container(_ open: String, _ close: String, _ children: [String], count: String) -> String {
            guard !children.isEmpty else {
                return "<div class=\"r\">\(keyHTML)<span class=\"p\">\(open)\(close)</span>\(comma)</div>"
            }
            let folded = HTMLRenderer.escape(" … \(close)\(last ? "" : ",")  \(count)")
            return """
            <details open><summary data-folded="\(folded)">\(keyHTML)<span class="p">\(open)</span></summary>\
            <div class="c">\(children.joined())</div>\
            <div class="r"><span class="p">\(close)</span>\(comma)</div></details>
            """
        }

        switch value {
        case .object(let members):
            let children = members.enumerated().map { i, m in html(m.value, key: m.key, last: i == members.count - 1) }
            return container("{", "}", children, count: "\(members.count) \(members.count == 1 ? "key" : "keys")")
        case .array(let items):
            let children = items.enumerated().map { i, v in html(v, key: nil, last: i == items.count - 1) }
            return container("[", "]", children, count: "\(items.count) \(items.count == 1 ? "item" : "items")")
        case .string(let s):
            return "<div class=\"r\">\(keyHTML)<span class=\"s\">\"\(HTMLRenderer.escape(s))\"</span>\(comma)</div>"
        case .number(let n):
            return "<div class=\"r\">\(keyHTML)<span class=\"n\">\(HTMLRenderer.escape(n))</span>\(comma)</div>"
        case .bool(let b):
            return "<div class=\"r\">\(keyHTML)<span class=\"b\">\(b)</span>\(comma)</div>"
        case .null:
            return "<div class=\"r\">\(keyHTML)<span class=\"z\">null</span>\(comma)</div>"
        }
    }

    // MARK: Parsing

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(_ bytes: [UInt8]) {
            // Skip a UTF-8 byte order mark.
            self.bytes = bytes
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        }

        mutating func parseDocument() throws -> Value {
            let value = try parseValue()
            skipWhitespace()
            if i < bytes.count { throw error("Unexpected text after the end of the JSON") }
            return value
        }

        mutating func parseValue() throws -> Value {
            skipWhitespace()
            guard i < bytes.count else { throw error("Unexpected end of input") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
            default: throw error("Unexpected character '\(Character(UnicodeScalar(bytes[i])))'")
            }
        }

        mutating func parseObject() throws -> Value {
            i += 1
            var members: [(key: String, value: Value)] = []
            skipWhitespace()
            if peek("}") { i += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard peek("\"") else { throw error("Expected a quoted key") }
                let key = try parseString()
                skipWhitespace()
                guard peek(":") else { throw error("Expected ':' after key") }
                i += 1
                members.append((key, try parseValue()))
                skipWhitespace()
                if peek(",") { i += 1; continue }
                if peek("}") { i += 1; return .object(members) }
                throw error("Expected ',' or '}'")
            }
        }

        mutating func parseArray() throws -> Value {
            i += 1
            var items: [Value] = []
            skipWhitespace()
            if peek("]") { i += 1; return .array(items) }
            while true {
                items.append(try parseValue())
                skipWhitespace()
                if peek(",") { i += 1; continue }
                if peek("]") { i += 1; return .array(items) }
                throw error("Expected ',' or ']'")
            }
        }

        mutating func parseString() throws -> String {
            let start = i + 1
            i += 1
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\\"): i += 2
                case UInt8(ascii: "\""):
                    defer { i += 1 }
                    return String(decoding: bytes[start..<i], as: UTF8.self)
                case 0..<0x20: throw error("Unescaped control character in string")
                default: i += 1
                }
            }
            throw error("Unterminated string")
        }

        mutating func parseNumber() throws -> String {
            let start = i
            if peek("-") { i += 1 }
            let digitsStart = i
            while i < bytes.count, isNumberByte(bytes[i]) { i += 1 }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            guard i > digitsStart, Double(text) != nil else { throw error("Invalid number '\(text)'") }
            return text
        }

        private func isNumberByte(_ b: UInt8) -> Bool {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b)
                || b == UInt8(ascii: ".") || b == UInt8(ascii: "e") || b == UInt8(ascii: "E")
                || b == UInt8(ascii: "+") || b == UInt8(ascii: "-")
        }

        mutating func expect(_ word: String) throws {
            let w = Array(word.utf8)
            guard bytes.count - i >= w.count, Array(bytes[i..<i + w.count]) == w else {
                throw error("Expected '\(word)'")
            }
            i += w.count
        }

        func peek(_ c: Unicode.Scalar) -> Bool { i < bytes.count && bytes[i] == UInt8(ascii: c) }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
        }

        func error(_ message: String) -> ParseError {
            let upTo = bytes[..<min(i, bytes.count)]
            let line = upTo.filter { $0 == 0x0A }.count + 1
            let lineStart = upTo.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            let column = String(decoding: bytes[lineStart..<min(i, bytes.count)], as: UTF8.self).count + 1
            return ParseError(message: message, line: line, column: column)
        }
    }

    static let css = """
    article.json-doc { max-width:none; padding:24px 28px 48px; }
    .json { font:13px/1.6 ui-monospace, "SF Mono", Menlo, monospace; }
    .json .c { margin-left:.6em; padding-left:1.4em; border-left:1px solid var(--border); }
    .json summary { list-style:none; cursor:pointer; position:relative; }
    .json summary::-webkit-details-marker { display:none; }
    .json summary::before { content:"▾"; position:absolute; left:-1.1em; color:var(--muted); font-size:.85em; }
    .json details:not([open]) > summary::before { content:"▸"; }
    .json details:not([open]) > summary::after { content:attr(data-folded); color:var(--muted); }
    .json summary:hover { background:var(--code-bg); }
    .json .k { color:var(--j-key); } .json .s { color:var(--j-str); } .json .n { color:var(--j-num); }
    .json .b, .json .z { color:var(--j-lit); } .json .p { color:var(--muted); }
    .json-error { color:var(--j-err); font-weight:600; margin-bottom:16px; }
    :root { --j-key:#0550ae; --j-str:#0a7d32; --j-num:#b35900; --j-lit:#a626a4; --j-err:#cf222e; }
    @media (prefers-color-scheme: dark) { :root { --j-key:#79c0ff; --j-str:#7ee787; --j-num:#ffa657; --j-lit:#d2a8ff; --j-err:#ff7b72; } }
    """
}

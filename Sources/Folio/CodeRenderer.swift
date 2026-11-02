import Foundation

/// Line-by-line colour coding for YAML and .env files. Shares the JSON colours.
enum CodeRenderer {
    static func yaml(_ text: String) -> String {
        var blockIndent: Int?  // inside a `|` or `>` block scalar deeper than this indent
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let indent = line.prefix { $0 == " " }.count
            if let parent = blockIndent {
                if line.trimmingCharacters(in: .whitespaces).isEmpty || indent > parent {
                    return span("s", line)
                }
                blockIndent = nil
            }
            var rest = Substring(line)
            var out = esc(String(rest.prefix { $0 == " " }))
            rest = rest.drop { $0 == " " }

            if rest.hasPrefix("#") { return out + span("c", String(rest)) }
            if rest == "---" || rest == "..." || rest.hasPrefix("--- ") { return out + span("p", String(rest)) }

            while rest.hasPrefix("- ") || rest == "-" {
                out += span("p", "-") + (rest.count > 1 ? " " : "")
                rest = rest.dropFirst(min(2, rest.count))
            }
            if let colon = keyColon(in: rest) {
                out += span("k", String(rest[..<colon])) + span("p", ":")
                rest = rest[rest.index(after: colon)...]
                let lead = rest.prefix { $0 == " " }
                out += String(lead)
                rest = rest.dropFirst(lead.count)
            }
            let (value, comment) = splitComment(rest)
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^[|>][+-]?[0-9]?$"#, options: .regularExpression) != nil {
                blockIndent = indent
            }
            return out + yamlScalar(value) + (comment.map { span("c", $0) } ?? "")
        }
        return wrap(lines)
    }

    static func env(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var rest = Substring(line)
            var out = esc(String(rest.prefix { $0 == " " || $0 == "\t" }))
            rest = rest.drop { $0 == " " || $0 == "\t" }
            if rest.hasPrefix("#") || rest.isEmpty { return out + span("c", String(rest)) }
            if rest.hasPrefix("export ") {
                out += span("b", "export") + " "
                rest = rest.dropFirst(7).drop { $0 == " " }
            }
            guard let eq = rest.firstIndex(of: "=") else { return out + esc(String(rest)) }
            out += span("k", String(rest[..<eq])) + span("p", "=")
            let (value, comment) = splitComment(rest[rest.index(after: eq)...])
            let single = value.hasPrefix("'")
            return out + span("s", String(value), interpolate: !single) + (comment.map { span("c", $0) } ?? "")
        }
        return wrap(lines)
    }

    // MARK: Helpers

    private static func yamlScalar(_ value: Substring) -> String {
        let t = value.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return esc(String(value)) }
        let lead = String(value.prefix { $0 == " " })
        let kind: String
        if t.hasPrefix("\"") || t.hasPrefix("'") {
            kind = "s"
        } else if ["true", "false", "yes", "no", "on", "off", "null", "~"].contains(t.lowercased()) {
            kind = "b"
        } else if t.range(of: #"^[-+]?(\d[\d_]*(\.\d*)?([eE][-+]?\d+)?|\.\d+|0x[0-9a-fA-F]+|\.inf|\.nan)$"#,
                           options: .regularExpression) != nil {
            kind = "n"
        } else if t.hasPrefix("&") || t.hasPrefix("*") || t.hasPrefix("!") || t.hasPrefix("|") || t.hasPrefix(">") {
            kind = "z"
        } else if t.hasPrefix("[") || t.hasPrefix("{") {
            kind = "p"
        } else {
            kind = "s"
        }
        return esc(lead) + span(kind, t) + esc(String(value.reversed().prefix { $0 == " " }))
    }

    /// The `:` ending a mapping key, skipping colons inside quotes or values like URLs.
    private static func keyColon(in s: Substring) -> String.Index? {
        var quote: Character?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'", i == s.startIndex {
                quote = c
            } else if c == "#", i > s.startIndex, s[s.index(before: i)] == " " {
                return nil
            } else if c == ":" {
                let next = s.index(after: i)
                if next == s.endIndex || s[next] == " " { return i == s.startIndex ? nil : i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Splits a trailing ` # comment` off a value, ignoring `#` inside quotes.
    private static func splitComment(_ s: Substring) -> (Substring, String?) {
        var quote: Character?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#", i == s.startIndex || s[s.index(before: i)] == " " || s[s.index(before: i)] == "\t" {
                return (s[..<i], String(s[i...]))
            }
            i = s.index(after: i)
        }
        return (s, nil)
    }

    private static func esc(_ s: String) -> String { HTMLRenderer.escape(s) }

    private static func span(_ cls: String, _ s: String, interpolate: Bool = false) -> String {
        guard !s.isEmpty else { return "" }
        var html = esc(s)
        if interpolate {
            html = html.replacingOccurrences(of: #"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*"#,
                                             with: "<span class=\"z\">$0</span>", options: .regularExpression)
        }
        return "<span class=\"\(cls)\">\(html)</span>"
    }

    private static func wrap(_ lines: [String]) -> String {
        var lines = lines
        if lines.last == "" { lines.removeLast() }
        return "<div class=\"code\">" + lines.map { "<div class=\"l\">\($0.isEmpty ? " " : $0)</div>" }.joined() + "</div>"
    }

    static let css = """
    article.code-doc { max-width:none; padding:20px 24px 48px 0; }
    .code { font:13px/1.6 ui-monospace, "SF Mono", Menlo, monospace; counter-reset:line; }
    .code .l { white-space:pre-wrap; word-break:break-word; padding-left:4.2em; text-indent:-4.2em; }
    .code .l::before { counter-increment:line; content:counter(line); display:inline-block; width:3em;
      margin-right:1.2em; text-align:right; color:var(--muted); opacity:.6; text-indent:0; user-select:none; }
    .code .k { color:var(--j-key); } .code .s { color:var(--j-str); } .code .n { color:var(--j-num); }
    .code .b { color:var(--j-lit); } .code .z { color:var(--j-num); font-style:italic; }
    .code .p { color:var(--muted); } .code .c { color:var(--muted); font-style:italic; }
    """
}

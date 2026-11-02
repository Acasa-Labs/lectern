import AppKit

/// Editor language, picked from the file name.
enum SyntaxLanguage {
    case markdown, json, yaml, env, swift, javascript, python, shell, html, css, cLike, plain

    init(url: URL?) {
        guard let url else { self = .markdown; return }
        let name = url.lastPathComponent.lowercased()
        switch url.pathExtension.lowercased() {
        case _ where DocumentKind.markdownExtensions.contains(url.pathExtension.lowercased()): self = .markdown
        case "json", "jsonc", "jsonl", "geojson", "resolved": self = .json
        case "yaml", "yml": self = .yaml
        case _ where DocumentKind(fileURL: url) == .env: self = .env
        case "swift": self = .swift
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts": self = .javascript
        case "py", "pyw": self = .python
        case "sh", "bash", "zsh", "fish", "command": self = .shell
        case _ where [".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile"].contains(name): self = .shell
        case "html", "htm", "xml", "svg", "plist", "xib", "storyboard", "vue": self = .html
        case "css", "scss", "sass", "less": self = .css
        case "c", "h", "cpp", "cc", "hpp", "m", "mm", "java", "kt", "kts", "go", "rs", "cs", "dart", "php", "scala", "gradle":
            self = .cLike
        default: self = .plain
        }
    }

    var indentUnit: String {
        switch self {
        case .swift, .python, .cLike, .plain: "    "
        default: "  "
        }
    }

    /// Characters that, at the end of a line, indent the next one.
    var indentOpeners: String {
        switch self {
        case .markdown, .env, .plain, .shell: ""
        case .yaml, .python: ":{[("
        default: "{[("
        }
    }
}

enum SyntaxHighlighter {
    /// Token kinds, coloured like Xcode's Default theme.
    enum Token: Int {
        case comment, string, number, keyword, type, key, literal, variable, heading, link, function

        var color: NSColor { Self.colors[rawValue] }
        var isBold: Bool { self == .keyword || self == .literal || self == .heading }

        private static let colors: [NSColor] = [
            EditorTheme.dynamic(0x5d6c79, 0x6c7986),  // comment
            EditorTheme.dynamic(0xc41a16, 0xfc6a5d),  // string
            EditorTheme.dynamic(0x1c00cf, 0xd0bf69),  // number
            EditorTheme.dynamic(0x9b2393, 0xfc5fa3),  // keyword
            EditorTheme.dynamic(0x3900a0, 0xd0a8ff),  // type
            EditorTheme.dynamic(0x326d74, 0x67b7a4),  // key (JSON/YAML keys, tags, properties)
            EditorTheme.dynamic(0x9b2393, 0xfc5fa3),  // literal (true, false, nil)
            EditorTheme.dynamic(0x643820, 0xfd8f3f),  // variable (attributes, $VARS, anchors)
            EditorTheme.dynamic(0x9b2393, 0xfc5fa3),  // heading
            EditorTheme.dynamic(0x0e0eff, 0x5482ff),  // link
            EditorTheme.dynamic(0x326d74, 0x67b7a4),  // function call
        ]
    }

    struct Match {
        let range: NSRange
        let token: Token
    }

    /// Scans left to right with one combined pattern, so whichever of a comment or string starts first wins.
    static func matches(in text: String, language: SyntaxLanguage) -> [Match] {
        guard let compiled = compiled(for: language) else { return [] }
        let ns = text as NSString
        var result: [Match] = []
        compiled.regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            for (index, token) in compiled.tokens.enumerated() {
                var range = match.range(at: index + 1)
                guard range.location != NSNotFound else { continue }
                if token == .key, language == .yaml {
                    // YAML keys are matched from the line start; colour only the key, not its indent or "- ".
                    while range.length > 0, [0x20, 0x09, 0x2D].contains(ns.character(at: range.location)) {
                        range = NSRange(location: range.location + 1, length: range.length - 1)
                    }
                }
                result.append(Match(range: range, token: token))
                break
            }
        }
        return result
    }

    // MARK: Rules

    private struct Compiled {
        let regex: NSRegularExpression
        let tokens: [Token]
    }

    private static var cache: [SyntaxLanguage: Compiled] = [:]

    private static func compiled(for language: SyntaxLanguage) -> Compiled? {
        if let cached = cache[language] { return cached }
        let rules = rules(for: language)
        guard !rules.isEmpty else { return nil }
        // Each rule becomes one capturing group; rules must only use non-capturing groups inside.
        let pattern = rules.map { "(\($0.1))" }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let compiled = Compiled(regex: regex, tokens: rules.map(\.0))
        cache[language] = compiled
        return compiled
    }

    private static let dq = #""(?:\\.|[^"\\\n])*""#
    private static let sq = #"'(?:\\.|[^'\\\n])*'"#
    private static let backtick = #"`(?:\\.|[^`\\])*`"#
    private static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b"#
    private static let slashComments = #"//[^\n]*|/\*[\s\S]*?\*/"#
    private static let hashComment = #"(?<![^\s])#[^\n]*"#
    private static let typeName = #"\b[A-Z][A-Za-z0-9_]*\b"#
    private static let functionCall = #"\b[a-z_][A-Za-z0-9_]*(?=\()"#

    private static func words(_ list: String) -> String {
        "\\b(?:" + list.split(separator: " ").joined(separator: "|") + ")\\b"
    }

    private static func rules(for language: SyntaxLanguage) -> [(Token, String)] {
        switch language {
        case .swift:
            return [
                (.comment, slashComments),
                (.string, #""""[\s\S]*?"""|"# + dq),
                (.number, number),
                (.literal, words("true false nil")),
                (.keyword, words("""
                    associatedtype class deinit enum extension fileprivate func import init inout internal let open \
                    operator private precedencegroup protocol public rethrows static struct subscript typealias var break \
                    case catch continue default defer do else fallthrough for guard if in repeat return throw switch where \
                    while as is try await async throws some any self Self super lazy weak unowned final override mutating \
                    nonmutating convenience required get set willSet didSet actor nonisolated isolated
                    """)),
                (.variable, #"@\w+"#),
                (.function, functionCall),
                (.type, typeName),
            ]
        case .javascript:
            return [
                (.comment, slashComments),
                (.string, dq + "|" + sq + "|" + backtick),
                (.number, number),
                (.literal, words("true false null undefined NaN Infinity")),
                (.keyword, words("""
                    break case catch class const continue debugger default delete do else export extends finally for \
                    function if import in instanceof let new return super switch this throw try typeof var void while with \
                    yield async await of static get set from as interface type enum implements private protected public \
                    readonly declare namespace abstract keyof infer satisfies
                    """)),
                (.variable, #"@\w+"#),
                (.function, functionCall),
                (.type, typeName),
            ]
        case .python:
            return [
                (.comment, hashComment),
                (.string, #"[rRbBfFuU]{0,2}(?:"""[\s\S]*?"""|'''[\s\S]*?''')|[rRbBfFuU]{0,2}"# + "(?:" + dq + "|" + sq + ")"),
                (.number, number),
                (.literal, words("True False None")),
                (.keyword, words("""
                    and as assert async await break class continue def del elif else except finally for from global if \
                    import in is lambda nonlocal not or pass raise return try while with yield match case self
                    """)),
                (.variable, #"@\w+(?:\.\w+)*"#),
                (.function, functionCall),
                (.type, typeName),
            ]
        case .shell:
            return [
                (.comment, hashComment),
                (.string, dq + "|" + sq),
                (.variable, #"\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@#?$!*-]"#),
                (.keyword, words("""
                    if then else elif fi for while until do done case esac in function return local export readonly \
                    declare unset shift exit source alias
                    """)),
                (.number, number),
            ]
        case .cLike:
            return [
                (.comment, slashComments),
                (.string, dq + "|" + sq + "|" + backtick),
                (.keyword, #"^[ \t]*#[ \t]*\w+"#),
                (.number, number),
                (.literal, words("true false null nil None")),
                (.keyword, words("""
                    auto break case catch char class const continue default delete do double else enum extern final \
                    finally float for func go goto if implements import int interface long namespace new package private \
                    protected public return short signed sizeof static struct super switch template this throw throws try \
                    typedef union unsigned using var virtual void volatile while fn let mut impl trait pub use mod crate \
                    match loop where async await yield defer chan map range type select fallthrough val fun object when is \
                    in override open data sealed bool string
                    """)),
                (.variable, #"@\w+"#),
                (.function, functionCall),
                (.type, typeName),
            ]
        case .json:
            return [
                (.comment, slashComments),
                (.key, dq + #"(?=\s*:)"#),
                (.string, dq),
                (.number, #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#),
                (.literal, words("true false null")),
            ]
        case .yaml:
            return [
                (.comment, hashComment),
                (.keyword, #"^(?:---|\.\.\.)(?=\s|$)"#),
                (.key, #"^[ \t]*(?:-[ \t]+)*(?:"[^"\n]*"|'[^'\n]*'|[^\s#'"\-:\[\]{},][^\n#:]*?)(?=[ \t]*:(?:[ \t]|$))"#),
                (.string, dq + "|" + sq),
                (.variable, #"[&*][A-Za-z0-9_-]+|![\w!/.-]*"#),
                (.literal, #"(?<=[\s:\-\[,])(?:true|false|yes|no|null|True|False|Null|~)(?=\s*(?:$|#|,|\]))"#),
                (.number, #"(?<=[\s:\-\[,])[-+]?\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?(?=\s*(?:$|#|,|\]))"#),
            ]
        case .env:
            return [
                (.comment, #"^[ \t]*#[^\n]*|(?<=\s)#[^\n]*"#),
                (.keyword, #"^[ \t]*export\b"#),
                (.key, #"\b[A-Za-z_][A-Za-z0-9_.]*(?==)"#),
                (.string, dq + "|" + sq),
                (.variable, #"\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*"#),
            ]
        case .markdown:
            return [
                (.string, #"^[ \t]*```[^\n]*\n[\s\S]*?^[ \t]*```"#),
                (.comment, #"<!--[\s\S]*?-->|^[ \t]*>[^\n]*"#),
                (.heading, #"^#{1,6}[ \t][^\n]*"#),
                (.keyword, #"^[ \t]*(?:[-*+]|\d+[.)])(?=[ \t])"#),
                (.string, #"`[^`\n]+`"#),
                (.link, #"!?\[[^\]\n]*\]\([^)\n]*\)"#),
                (.type, #"\*\*[^*\n]+\*\*|__[^_\n]+__"#),
                (.variable, #"(?<![*\w])\*[^*\n]+\*(?![*\w])|(?<![_\w])_[^_\n]+_(?![_\w])"#),
            ]
        case .html:
            return [
                (.comment, #"<!--[\s\S]*?-->"#),
                (.keyword, #"<![A-Za-z][^>]*>"#),
                (.string, dq + "|" + sq),
                (.key, #"</?[A-Za-z][\w:.-]*|/?>"#),
                (.variable, #"\b[\w:-]+(?=\s*=)|&\w+;"#),
            ]
        case .css:
            return [
                (.comment, #"/\*[\s\S]*?\*/"#),
                (.string, dq + "|" + sq),
                (.keyword, #"@[\w-]+|!important"#),
                (.number, #"#[0-9a-fA-F]{3,8}\b|-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr)?"#),
                (.key, #"[\w-]+(?=\s*:[^:])"#),
            ]
        case .plain:
            return []
        }
    }
}

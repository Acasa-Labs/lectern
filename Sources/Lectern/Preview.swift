import AppKit
import UniformTypeIdentifiers
import WebKit

extension UTType {
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown")
    static let dotenv = UTType(importedAs: "com.acasalabs.dotenv")
}

/// How a file is shown, picked from its name (a bare `.env` has no extension macOS can type).
enum DocumentKind {
    case markdown, json, yaml, env, code

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    init(fileURL: URL?) {
        guard let fileURL else { self = .markdown; return }
        let name = fileURL.lastPathComponent.lowercased()
        let ext = fileURL.pathExtension.lowercased()
        if Self.markdownExtensions.contains(ext) {
            self = .markdown
        } else if ext == "json" {
            self = .json
        } else if ext == "yaml" || ext == "yml" {
            self = .yaml
        } else if name == ".env" || name.hasPrefix(".env.") || ext == "env" {
            self = .env
        } else {
            self = .code
        }
    }

    /// Markdown and JSON open in a rendered preview. YAML and .env open straight in the editor,
    /// since their preview would only repeat the editor's colours.
    var hasPreview: Bool { self == .markdown || self == .json }
}

/// One tab's rendered preview. Kept alive with the tab so scroll position survives tab switches.
final class PreviewController: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var openFile: (URL) -> Void = { _ in }

    private var renderedText: String?
    private var renderedBase: URL?
    private var renderedKind: DocumentKind?
    private var pageLoaded = false
    private var mermaidLoaded = false
    private var pendingUpdate: DispatchWorkItem?
    private let pageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Lectern-\(UUID().uuidString).html")

    override init() {
        let config = WKWebViewConfiguration()
        // Raw HTML in a markdown file should never be able to run scripts.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        super.init()
        webView.navigationDelegate = self
    }

    deinit { try? FileManager.default.removeItem(at: pageURL) }

    func show(_ text: String, kind: DocumentKind, baseURL: URL?) {
        guard text != renderedText || baseURL != renderedBase || kind != renderedKind else { return }
        let baseChanged = baseURL != renderedBase || kind != renderedKind
        renderedText = text
        renderedBase = baseURL
        renderedKind = kind
        pendingUpdate?.cancel()

        guard pageLoaded, !baseChanged else {
            // Loaded from a temp file (not loadHTMLString) so relative local images can be read.
            pageLoaded = false
            mermaidLoaded = false
            try? Renderer.page(for: text, kind: kind, baseURL: baseURL).write(to: pageURL, atomically: true, encoding: .utf8)
            webView.loadFileURL(pageURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
            return
        }

        // While editing, swap the article in place so the preview keeps its scroll position.
        let update = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let html = Renderer.body(for: text, kind: kind, baseURL: baseURL)
            let literal = String(data: try! JSONEncoder().encode(html), encoding: .utf8)!
            webView.evaluateJavaScript("document.querySelector('article').innerHTML = \(literal); 0;",
                                       in: nil, in: .defaultClient) { _ in self.renderMermaid() }
        }
        pendingUpdate = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: update)
    }

    /// Bundled mermaid.js runs as app-injected script, so it works while page scripts stay disabled.
    static let mermaidLibrary: String? = Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map { $0 + """

            ;mermaid.initialize({ startOnLoad: false, securityLevel: "strict",
              theme: matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "default" });
            0;
            """ }

    private func renderMermaid() {
        guard renderedText?.contains("```mermaid") == true else { return }
        if !mermaidLoaded, let library = Self.mermaidLibrary {
            webView.evaluateJavaScript(library, in: nil, in: .defaultClient) { _ in }
            mermaidLoaded = true
        }
        webView.evaluateJavaScript(
            "mermaid.run({ querySelector: 'pre.mermaid:not([data-processed])', suppressErrors: true }); 0;",
            in: nil, in: .defaultClient) { _ in }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        renderMermaid()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            return decisionHandler(.allow)
        }
        // In-page anchors scroll within the document.
        if url.fragment != nil, url.path == webView.url?.path {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        // A link in a document must never launch an app or hand a custom URL scheme to another app.
        if url.isFileURL {
            openFile(url)
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Renderer {
    static func page(for text: String, kind: DocumentKind, baseURL: URL?) -> String {
        let articleClass = switch kind {
        case .markdown: ""
        case .json: " class=\"json-doc\""
        case .yaml, .env, .code: " class=\"code-doc\""
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>\(css)\(JSONRenderer.css)\(CodeRenderer.css)</style></head>
        <body><article\(articleClass)>\(body(for: text, kind: kind, baseURL: baseURL))</article></body></html>
        """
    }

    static func body(for text: String, kind: DocumentKind, baseURL: URL?) -> String {
        switch kind {
        case .markdown: HTMLRenderer.render(stripFrontMatter(text), baseURL: baseURL)
        case .json: JSONRenderer.render(text)
        case .yaml: CodeRenderer.yaml(text)
        case .env: CodeRenderer.env(text)
        case .code: "<pre><code>\(HTMLRenderer.escape(text))</code></pre>"
        }
    }

    static func stripFrontMatter(_ text: String) -> String {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return text }
        let lines = text.components(separatedBy: .newlines)
        guard let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return text }
        return lines[(end + 1)...].joined(separator: "\n")
    }

    static let css = """
    :root { color-scheme: light dark; --fg:#1f2328; --muted:#59636e; --border:#d1d9e0; --code-bg:#f6f8fa; --link:#0969da; }
    @media (prefers-color-scheme: dark) { :root { --fg:#e6edf3; --muted:#9198a1; --border:#3d444d; --code-bg:#151b23; --link:#4493f8; } }
    html { background: transparent; }
    body { margin:0; color:var(--fg); font:16px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; -webkit-font-smoothing:antialiased; }
    article { max-width: 820px; margin: 0 auto; padding: 32px 40px 64px; }
    h1,h2,h3,h4,h5,h6 { margin:1.5em 0 .6em; font-weight:600; line-height:1.25; }
    h1 { font-size:2em; padding-bottom:.3em; border-bottom:1px solid var(--border); }
    h2 { font-size:1.5em; padding-bottom:.3em; border-bottom:1px solid var(--border); }
    h3 { font-size:1.25em; } h4 { font-size:1em; } h5 { font-size:.875em; } h6 { font-size:.85em; color:var(--muted); }
    article > :first-child { margin-top:0; }
    p, ul, ol, blockquote, pre, table, aside { margin:0 0 16px; }
    a { color:var(--link); text-decoration:none; } a:hover { text-decoration:underline; }
    ul, ol { padding-left:2em; } li + li { margin-top:.25em; } li > p { margin:0; }
    li.task { list-style:none; } li.task > input { margin:0 .4em 0 -1.4em; vertical-align:middle; }
    code { font:.875em ui-monospace, "SF Mono", Menlo, monospace; background:var(--code-bg); padding:.2em .4em; border-radius:6px; }
    pre { background:var(--code-bg); padding:16px; border-radius:8px; overflow:auto; line-height:1.45; }
    pre code { background:none; padding:0; font-size:.85em; }
    blockquote, aside { padding:0 1em; color:var(--muted); border-left:.25em solid var(--border); }
    aside { color:var(--fg); border-left-color:var(--link); }
    table { border-collapse:collapse; display:block; width:max-content; max-width:100%; overflow:auto; }
    td, th { vertical-align:top; }
    th, td { padding:6px 13px; border:1px solid var(--border); } th { font-weight:600; }
    tr:nth-child(2n) td { background:var(--code-bg); }
    hr { height:1px; border:0; background:var(--border); margin:24px 0; }
    img { max-width:100%; }
    pre.mermaid { background:none; padding:0; text-align:center; font:inherit; color:transparent; }
    pre.mermaid[data-processed] { color:inherit; }
    """
}

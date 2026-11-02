import AppKit
import SwiftUI

struct SearchMatch: Identifiable {
    let id = UUID()
    let line: Int
    /// The match in the file's text (UTF-16).
    let range: NSRange
    /// The line around the match, split so the match can be highlighted.
    let before: String
    let matched: String
    let after: String
}

struct FileMatches: Identifiable {
    let url: URL
    let matches: [SearchMatch]
    var id: URL { url }
}

/// ⇧⌘F: search, and optionally replace, across every file in the open folder.
final class FolderSearch: ObservableObject {
    @Published var query = ""
    @Published var replacement = ""
    @Published var matchCase = false
    @Published var wholeWord = false
    @Published var isRegex = false
    @Published private(set) var results: [FileMatches] = []
    @Published private(set) var summary = ""
    @Published private(set) var isSearching = false
    private var task: Task<Void, Never>?

    static let maxMatches = 10_000

    var matchCount: Int { results.reduce(0) { $0 + $1.matches.count } }

    func makeRegex() throws -> NSRegularExpression {
        var pattern = isRegex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        return try NSRegularExpression(pattern: pattern, options: matchCase ? [.anchorsMatchLines] : [.caseInsensitive, .anchorsMatchLines])
    }

    @MainActor
    func run(in workspace: Workspace) {
        task?.cancel()
        guard !query.isEmpty else {
            results = []
            summary = ""
            return
        }
        guard let regex = try? makeRegex() else {
            results = []
            summary = "That regular expression isn't valid."
            return
        }
        isSearching = true
        summary = "Searching…"
        // Open tabs are searched as they are now, unsaved edits included.
        let openTexts = Dictionary(workspace.tabs.compactMap { tab in tab.url.map { ($0.standardizedFileURL.path, tab.text) } },
                                   uniquingKeysWith: { first, _ in first })
        task = Task { [weak self] in
            let files = await workspace.indexFiles()
            let found = await Task.detached(priority: .userInitiated) {
                Self.search(files, regex: regex, openTexts: openTexts)
            }.value
            guard let self, !Task.isCancelled else { return }
            results = found
            isSearching = false
            let count = matchCount
            summary = count == 0
                ? "No results"
                : "\(count == Self.maxMatches ? "\(count)+" : "\(count)") \(count == 1 ? "result" : "results") in \(found.count) \(found.count == 1 ? "file" : "files")"
        }
    }

    /// Replaces every match. Open files change in their editor (undoable, left unsaved for review);
    /// other files are written directly.
    @MainActor
    func replaceAll(in workspace: Workspace) {
        guard let regex = try? makeRegex(), !results.isEmpty else { return }
        let fileCount = results.count
        let alert = NSAlert()
        alert.messageText = "Replace \(matchCount) \(matchCount == 1 ? "match" : "matches") in \(fileCount) \(fileCount == 1 ? "file" : "files")?"
        alert.informativeText = "Files open in tabs can be undone there and stay unsaved until you save them. "
            + "Files that aren't open are changed on disk straight away and can't be undone."
        alert.addButton(withTitle: "Replace All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let template = isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        var failures: [String] = []
        for file in results {
            let path = file.url.standardizedFileURL.path
            if let tab = workspace.tabs.first(where: { $0.url?.standardizedFileURL.path == path }) {
                let text = tab.text
                let replaced = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                              withTemplate: template)
                tab.editor.replaceAllUndoably(with: replaced)
            } else {
                do {
                    let data = try Data(contentsOf: file.url)
                    let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                    let replaced = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                                  withTemplate: template)
                    // In place, so file permissions survive.
                    try Data(replaced.utf8).write(to: file.url)
                } catch {
                    failures.append(file.url.lastPathComponent)
                }
            }
        }
        if !failures.isEmpty {
            let warning = NSAlert()
            warning.messageText = "Some files couldn't be changed"
            warning.informativeText = failures.joined(separator: ", ")
            warning.runModal()
        }
        workspace.refreshFromDisk()
        run(in: workspace)
    }

    private static func search(_ files: [URL], regex: NSRegularExpression, openTexts: [String: String]) -> [FileMatches] {
        var found: [FileMatches] = []
        var total = 0
        for url in files {
            let path = url.standardizedFileURL.path
            guard let text = openTexts[path] ?? readText(url) else { continue }
            let ns = text as NSString
            var matches: [SearchMatch] = []
            var line = 1
            var counted = 0
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { result, _, stop in
                guard let result, result.range.length > 0 else { return }
                line += newlines(in: ns, from: counted, to: result.range.location)
                counted = result.range.location
                matches.append(preview(of: result.range, in: ns, line: line))
                total += 1
                if total >= maxMatches { stop.pointee = true }
            }
            if !matches.isEmpty { found.append(FileMatches(url: url, matches: matches)) }
            if total >= maxMatches { break }
        }
        return found
    }

    /// Text files only: skips anything over 5 MB or with NUL bytes (binary).
    private static func readText(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 5_000_000,
              let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func newlines(in ns: NSString, from start: Int, to end: Int) -> Int {
        var count = 0
        var location = start
        while location < end {
            let found = ns.range(of: "\n", options: .literal, range: NSRange(location: location, length: end - location))
            guard found.location != NSNotFound else { break }
            count += 1
            location = found.location + 1
        }
        return count
    }

    /// The match's line, trimmed of indentation and cut down around the match if it's long.
    private static func preview(of range: NSRange, in ns: NSString, line: Int) -> SearchMatch {
        let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
        var indentEnd = lineRange.location
        let lineEnd = NSMaxRange(lineRange)
        while indentEnd < range.location, [0x20, 0x09].contains(ns.character(at: indentEnd)) { indentEnd += 1 }
        let start = max(indentEnd, range.location - 60)
        let matchEnd = min(NSMaxRange(range), lineEnd)
        var end = min(lineEnd, matchEnd + 120)
        while end > matchEnd, [0x0A, 0x0D].contains(ns.character(at: end - 1)) { end -= 1 }
        let before = ns.substring(with: NSRange(location: start, length: range.location - start))
        let matched = ns.substring(with: NSRange(location: range.location, length: matchEnd - range.location))
        let after = ns.substring(with: NSRange(location: matchEnd, length: end - matchEnd))
        return SearchMatch(line: line, range: range,
                           before: (start > indentEnd ? "…" : "") + before,
                           matched: matched, after: after)
    }
}

/// The search panel shown in the sidebar, like Xcode's Find navigator.
struct FindNavigator: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var search: FolderSearch
    @FocusState private var findFocused: Bool
    @State private var collapsed: Set<URL> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Find", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($findFocused)
                    .onSubmit { search.run(in: workspace) }
                HStack(spacing: 4) {
                    option("textformat", "Match case", $search.matchCase)
                    option("character.cursor.ibeam", "Whole words", $search.wholeWord)
                    option("asterisk", "Regular expression", $search.isRegex)
                    Spacer()
                    Button("Find") { search.run(in: workspace) }
                        .disabled(search.query.isEmpty)
                }
                .controlSize(.small)
                TextField("Replace", text: $search.replacement)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text(search.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Replace All") { search.replaceAll(in: workspace) }
                        .controlSize(.small)
                        .disabled(search.results.isEmpty || search.isSearching)
                }
            }
            .padding(10)
            Divider()
            List {
                ForEach(search.results) { file in
                    DisclosureGroup(isExpanded: expansion(for: file.url)) {
                        ForEach(file.matches) { match in
                            matchRow(match)
                                .contentShape(Rectangle())
                                .onTapGesture { workspace.reveal(match.range, in: file.url) }
                        }
                    } label: {
                        fileRow(file)
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.sidebarRowSize, .small)
        }
        .onChange(of: workspace.searchFocusRequest, initial: true) { _, _ in findFocused = true }
        // Re-run when an option changes, as Xcode does.
        .onChange(of: search.matchCase) { _, _ in search.run(in: workspace) }
        .onChange(of: search.wholeWord) { _, _ in search.run(in: workspace) }
        .onChange(of: search.isRegex) { _, _ in search.run(in: workspace) }
    }

    private func option(_ symbol: String, _ help: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Image(systemName: symbol) }
            .toggleStyle(.button)
            .help(help)
    }

    private func expansion(for url: URL) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(url) },
                set: { if $0 { collapsed.remove(url) } else { collapsed.insert(url) } })
    }

    private func fileRow(_ file: FileMatches) -> some View {
        HStack(spacing: 6) {
            FileIcon(url: file.url)
            Text(file.url.lastPathComponent).fontWeight(.medium).lineLimit(1)
            Text(FuzzyMatch.folder(of: file.url, relativeTo: workspace.root?.url))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            Text("\(file.matches.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func matchRow(_ match: SearchMatch) -> some View {
        var highlighted = AttributedString(match.matched)
        highlighted.backgroundColor = .yellow.opacity(0.35)
        highlighted.foregroundColor = .primary
        var line = AttributedString(match.before)
        line.foregroundColor = .secondary
        var rest = AttributedString(match.after)
        rest.foregroundColor = .secondary
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "\(match.line)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 24, alignment: .trailing)
            Text(line + highlighted + rest)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
        }
    }
}

import SwiftUI

/// ⌘P: type part of a file name or path to jump to it.
struct QuickOpenView: View {
    @ObservedObject var workspace: Workspace
    @State private var query = ""
    @State private var files: [URL] = []
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [URL] {
        FuzzyMatch.rank(query, in: files, relativeTo: workspace.root?.url, limit: 60)
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            TextField("Search files by name", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(12)
                .focused($focused)
                .onSubmit { if results.indices.contains(selection) { open(results[selection]) } }
                .onKeyPress(.downArrow) {
                    selection = min(selection + 1, max(results.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selection = max(selection - 1, 0)
                    return .handled
                }
                .onExitCommand { workspace.showQuickOpen = false }
            Divider()
            if results.isEmpty {
                Text(files.isEmpty && workspace.root != nil ? "Indexing…" : "No matching files")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element) { index, url in
                                row(url, isSelected: index == selection)
                                    .id(index)
                                    .onTapGesture { open(url) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selection) { _, value in proxy.scrollTo(value) }
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .onAppear { focused = true }
        .task { files = await workspace.indexFiles() }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func row(_ url: URL, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            FileIcon(url: url)
                .frame(width: 16)
            Text(url.lastPathComponent)
                .lineLimit(1)
            Text(FuzzyMatch.folder(of: url, relativeTo: workspace.root?.url))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        .contentShape(Rectangle())
    }

    private func open(_ url: URL) {
        workspace.showQuickOpen = false
        workspace.open(url)
    }
}

enum FuzzyMatch {
    /// Best matches first. Letters must appear in order; matches in the file name, at word starts
    /// and in runs score higher.
    static func rank(_ query: String, in files: [URL], relativeTo root: URL?, limit: Int) -> [URL] {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Array(files.prefix(limit)) }
        var scored: [(score: Int, url: URL)] = []
        for url in files {
            let path = relativePath(of: url, relativeTo: root)
            if let score = score(needle, Array(path.lowercased()), nameStart: path.count - url.lastPathComponent.count) {
                scored.append((score, url))
            }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.url.path.count < $1.url.path.count }
            .prefix(limit)
            .map(\.url)
    }

    private static func score(_ needle: [Character], _ haystack: [Character], nameStart: Int) -> Int? {
        var score = 0
        var position = 0
        var previous = -2
        for character in needle {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            score += 1
            if found >= nameStart { score += 4 }
            if found == previous + 1 { score += 6 }
            if found == 0 || "/._- ".contains(haystack[found - 1]) { score += 5 }
            previous = found
            position = found + 1
        }
        return score - haystack.count / 20
    }

    static func relativePath(of url: URL, relativeTo root: URL?) -> String {
        guard let root else { return url.lastPathComponent }
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    static func folder(of url: URL, relativeTo root: URL?) -> String {
        let relative = relativePath(of: url, relativeTo: root)
        let folder = (relative as NSString).deletingLastPathComponent
        return folder.isEmpty ? "" : folder
    }
}

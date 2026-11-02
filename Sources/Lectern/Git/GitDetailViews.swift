import AppKit
import SwiftUI

// MARK: - Commit detail

/// A commit's message, metadata and every file it changed, with inline diffs.
struct GitCommitDetail: View {
    let oid: GitOID
    let model: GitViewModel
    let snapshot: GitSnapshot
    var note: String?
    var showCommit: (GitOID) -> Void

    @State private var commit: GitCommit?
    @State private var changes: [GitFileChange]?
    @State private var diffs: [String: GitFileDiff] = [:]
    @State private var expanded: Set<String> = []
    @State private var copied = false
    /// The commit the loaded state belongs to, so late diff loads for another commit are dropped.
    @State private var shownOID: GitOID?

    /// Diffs load up front for this many files; the rest when opened.
    private static let eagerDiffs = 120

    var body: some View {
        ScrollView {
            if let commit {
                VStack(alignment: .leading, spacing: 18) {
                    header(commit)
                    metadata(commit)
                    Divider()
                    files(commit)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().padding(40).frame(maxWidth: .infinity)
            }
        }
        .task(id: oid) { await load() }
    }

    private func load() async {
        // The view stays put across commits (so the pane keeps its width); start fresh.
        commit = nil
        changes = nil
        diffs = [:]
        expanded = []
        copied = false
        shownOID = oid
        guard let commit = await model.commit(oid), !Task.isCancelled else { return }
        self.commit = commit
        let changes = await model.changes(of: commit)
        // A newer commit was picked meanwhile; its own load fills the view.
        guard !Task.isCancelled else { return }
        self.changes = changes
        // Small commits open every file; big ones start folded.
        if changes.count <= 25 { expanded = Set(changes.map(\.id)) }
        var loaded: [String: GitFileDiff] = [:]
        for change in changes.prefix(Self.eagerDiffs) {
            loaded[change.id] = await model.diff(change)
            if Task.isCancelled { return }
        }
        for (id, diff) in loaded where diff.additions + diff.deletions > 800 { expanded.remove(id) }
        diffs = loaded
    }

    // MARK: Header

    private func header(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let badges = snapshot.badges[commit.id] ?? []
            if !badges.isEmpty || commit.isMerge || commit.id == snapshot.head.oid {
                GitFlowLayout(spacing: 5) {
                    if commit.id == snapshot.head.oid, snapshot.head.branchName != nil, !badges.contains(where: \.isHead) {
                        GitRefBadgeView(badge: .init(kind: .head, name: "HEAD", isHead: true))
                    }
                    ForEach(badges, id: \.self) { GitRefBadgeView(badge: $0) }
                    if commit.isMerge {
                        Label("Merge", systemImage: "arrow.triangle.merge")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(.secondary)
                            .background(Capsule().fill(.quaternary))
                    }
                }
            }
            Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !commit.body.isEmpty {
                Text(commit.body)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Metadata

    private func metadata(_ commit: GitCommit) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
            GridRow {
                label("Author")
                person(commit.author)
            }
            if commit.committer.name != commit.author.name || commit.committer.email != commit.author.email
                || abs(commit.committer.date.timeIntervalSince(commit.author.date)) > 60 {
                GridRow {
                    label("Committer")
                    person(commit.committer)
                }
            }
            if !commit.coAuthors.isEmpty {
                GridRow {
                    label("Co-authors")
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(commit.coAuthors, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                }
            }
            GridRow {
                label("Commit")
                HStack(spacing: 6) {
                    Text(commit.id.hex)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(commit.id.hex)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.id.hex, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy SHA")
                    .accessibilityLabel("Copy SHA")
                }
            }
            GridRow {
                label(commit.parents.count == 1 ? "Parent" : "Parents")
                if commit.parents.isEmpty {
                    Text("None (root commit)").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ForEach(commit.parents, id: \.self) { parent in
                            Button(parent.short) { showCommit(parent) }
                                .buttonStyle(.link)
                                .monospaced()
                                .help(parentHelp(parent))
                        }
                    }
                }
            }
            GridRow {
                label("Tree")
                Text(commit.tree.short).monospaced().font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if commit.isSigned {
                GridRow {
                    label("Signature")
                    Label("Signed (not verified here)", systemImage: "checkmark.seal")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func person(_ who: GitSignature) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            GitAvatar(name: who.name, email: who.email, size: 20)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(who.name).fontWeight(.medium).textSelection(.enabled)
                if !who.email.isEmpty {
                    Text(who.email)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(who.email)
                }
                Text(who.localDateText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(who.date.formatted(.relative(presentation: .named)))
            }
        }
    }

    private func parentHelp(_ oid: GitOID) -> String {
        snapshot.commits.first { $0.id == oid }?.subject ?? oid.hex
    }

    // MARK: Files

    @ViewBuilder
    private func files(_ commit: GitCommit) -> some View {
        if let changes {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(changes.count == 1 ? "1 file changed" : "\(changes.count.formatted()) files changed")
                        .font(.headline)
                    if diffs.count == min(changes.count, Self.eagerDiffs), !changes.isEmpty {
                        let additions = diffs.values.reduce(0) { $0 + $1.additions }
                        let deletions = diffs.values.reduce(0) { $0 + $1.deletions }
                        GitDiffStat(additions: additions, deletions: deletions)
                    }
                    Spacer()
                    if changes.count > 1 {
                        Button(expanded.isEmpty ? "Expand All" : "Collapse All") {
                            withAnimation(.snappy) {
                                expanded = expanded.isEmpty ? Set(changes.map(\.id)) : []
                            }
                            if !expanded.isEmpty { Task { await loadMissing(changes) } }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if commit.isMerge {
                    Label("Showing changes compared with the first parent.", systemImage: "arrow.triangle.merge")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if changes.isEmpty {
                    Text("No files changed.").foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(changes) { change in
                        GitFileDiffCard(
                            change: change,
                            diff: diffs[change.id],
                            isExpanded: Binding(
                                get: { expanded.contains(change.id) },
                                set: { open in
                                    if open { expanded.insert(change.id) } else { expanded.remove(change.id) }
                                    if open, diffs[change.id] == nil { Task { await loadDiff(change) } }
                                }
                            )
                        )
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading changes…").foregroundStyle(.secondary)
            }
        }
    }

    private func loadMissing(_ changes: [GitFileChange]) async {
        for change in changes where diffs[change.id] == nil {
            await loadDiff(change)
        }
    }

    private func loadDiff(_ change: GitFileChange) async {
        let target = oid
        let diff = await model.diff(change)
        if shownOID == target { diffs[change.id] = diff }
    }
}

// MARK: - File diffs

/// One changed file: a header that folds, then its diff.
struct GitFileDiffCard: View {
    let change: GitFileChange
    let diff: GitFileDiff?
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    GitFileTitle(change: change)
                    Spacer(minLength: 8)
                    if let diff, diff.additions + diff.deletions > 0 {
                        GitDiffStat(additions: diff.additions, deletions: diff.deletions)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor))
            .accessibilityLabel("\(change.path), \(change.kind.title)")
            .accessibilityHint(isExpanded ? "Hides the diff" : "Shows the diff")

            if isExpanded {
                Divider()
                GitDiffBody(change: change, diff: diff)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Status letter, folder and file name, and the old name for a rename.
struct GitFileTitle: View {
    let change: GitFileChange

    var body: some View {
        HStack(spacing: 7) {
            GitStatusBadge(kind: change.kind)
            (Text(change.directory).foregroundStyle(.secondary) + Text(change.fileName).fontWeight(.medium))
                .lineLimit(1)
                .truncationMode(.head)
                .help(change.path)
            if let old = change.oldPath {
                Text("from \(old)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if change.modeChanged {
                Text(modeText).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private var modeText: String {
        "\(String(change.oldMode, radix: 8)) → \(String(change.newMode, radix: 8))"
    }
}

struct GitStatusBadge: View {
    let kind: GitFileChange.Kind

    var body: some View {
        Text(kind.letter)
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(color))
            .help(kind.title)
            .accessibilityLabel(kind.title)
    }

    private var color: Color {
        switch kind {
        case .added: .green
        case .modified: .orange
        case .deleted: .red
        case .renamed: .blue
        case .typeChanged: .purple
        case .untracked: .gray
        case .conflicted: .pink
        }
    }
}

/// `+12 −3` with a five-block bar, like GitHub.
struct GitDiffStat: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(additions.formatted())").foregroundStyle(.green)
            Text("−\(deletions.formatted())").foregroundStyle(.red)
            HStack(spacing: 1.5) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color(for: index))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .font(.caption.monospacedDigit().weight(.semibold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(additions) additions, \(deletions) deletions")
    }

    private func color(for index: Int) -> Color {
        let total = additions + deletions
        guard total > 0 else { return Color.secondary.opacity(0.25) }
        let green = Int((Double(additions) / Double(total) * 5).rounded())
        return index < green ? .green : .red
    }
}

/// The lines of a diff, or why there are none to show.
struct GitDiffBody: View {
    let change: GitFileChange
    let diff: GitFileDiff?
    @State private var showAll = false

    private static let lineLimit = 1_500

    var body: some View {
        switch diff {
        case nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading diff…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        case .text(let hunks, _, _):
            if hunks.isEmpty {
                message(change.modeChanged ? "Only the file mode changed." : "Empty file.", symbol: "doc")
            } else {
                lines(hunks)
            }
        case .binary(let oldSize, let newSize):
            message(binaryText(oldSize, newSize), symbol: "doc.zipper")
        case .submodule(let old, let new):
            message("Submodule \(old?.short ?? "—") → \(new?.short ?? "—")", symbol: "shippingbox")
        case .tooLarge(let size):
            message("Too large to show (\(size.formatted(.byteCount(style: .file))))", symbol: "doc.badge.ellipsis")
        case .unreadable(let reason):
            message(reason, symbol: "exclamationmark.triangle")
        }
    }

    private func lines(_ hunks: [GitDiffHunk]) -> some View {
        let rows = Self.rows(hunks)
        let shown = showAll ? rows : Array(rows.prefix(Self.lineLimit))
        let numberWidth = CGFloat(max(String(hunks.last?.lines.last?.newNumber ?? 0).count,
                                      String(hunks.last?.lines.last?.oldNumber ?? 0).count, 2)) * 8 + 10
        return VStack(alignment: .leading, spacing: 0) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { row in
                    switch row.content {
                    case .header(let text):
                        Text(text)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.leading, numberWidth * 2 + 6)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.07))
                    case .line(let line):
                        GitDiffLineRow(line: line, numberWidth: numberWidth)
                    }
                }
            }
            .textSelection(.enabled)
            if rows.count > shown.count {
                Button("Show \((rows.count - shown.count).formatted()) More Lines") { showAll = true }
                    .buttonStyle(.link)
                    .padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: [])
    }

    private func message(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(16)
    }

    private func binaryText(_ old: Int, _ new: Int) -> String {
        let format = ByteCountFormatStyle(style: .file)
        switch (old, new) {
        case (0, let n): return "Binary file added (\(n.formatted(format)))"
        case (let o, 0): return "Binary file removed (\(o.formatted(format)))"
        default: return "Binary file changed (\(old.formatted(format)) → \(new.formatted(format)))"
        }
    }

    private struct Row: Identifiable {
        enum Content {
            case header(String)
            case line(GitDiffLine)
        }

        let id: Int
        let content: Content
    }

    private static func rows(_ hunks: [GitDiffHunk]) -> [Row] {
        var rows: [Row] = []
        for hunk in hunks {
            rows.append(Row(id: rows.count, content: .header(hunk.header)))
            for line in hunk.lines { rows.append(Row(id: rows.count, content: .line(line))) }
        }
        return rows
    }
}

private struct GitDiffLineRow: View {
    let line: GitDiffLine
    let numberWidth: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker)
                .foregroundStyle(markerColor)
                .frame(width: 18)
            Text(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout.monospaced())
        .padding(.vertical, 0.5)
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.trailing, 4)
            .background(background.opacity(0.6))
            .textSelection(.disabled)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: ""
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .added: .green
        case .removed: .red
        case .context: .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: Color.green.opacity(0.14)
        case .removed: Color.red.opacity(0.14)
        case .context: .clear
        }
    }
}

// MARK: - Working tree

struct GitWorkingTreeList: View {
    let snapshot: GitSnapshot
    let status: GitStatus?
    @Binding var selection: GitFileChange?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Changes").font(.headline)
                Spacer()
                if let branch = snapshot.head.branchName {
                    Label(branch, systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()
            if let status {
                if status.isClean {
                    ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                           description: Text("The working tree matches the last commit."))
                } else {
                    List(selection: $selection) {
                        section("Conflicts", status.conflicted, hint: "Fix these before you commit.")
                        section("Staged Changes", status.staged, hint: "In the next commit.")
                        section("Changes", status.unstaged, hint: "Not staged yet.")
                        section("Untracked Files", status.untracked,
                                hint: status.untrackedTruncated ? "Only the first ones are shown." : "New to git.")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ changes: [GitFileChange], hint: String) -> some View {
        if !changes.isEmpty {
            Section {
                ForEach(changes) { change in
                    GitFileTitle(change: change)
                        .tag(change)
                }
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(changes.count)").monospacedDigit()
                }
                .help(hint)
            }
        }
    }
}

/// The diff of one working-tree file, staged (HEAD → index) or not (index → disk).
struct GitWorkingFileDiff: View {
    let change: GitFileChange
    let isStaged: Bool
    let model: GitViewModel
    let reloadToken: Date?
    @State private var diff: GitFileDiff?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                GitFileTitle(change: change)
                Spacer()
                Text(stateText).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if let diff, diff.additions + diff.deletions > 0 {
                    GitDiffStat(additions: diff.additions, deletions: diff.deletions)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()
            if change.path.hasSuffix("/") {
                ContentUnavailableView("Untracked Folder", systemImage: "folder.badge.questionmark",
                                       description: Text("Nothing in \(change.path) is tracked yet."))
            } else {
                ScrollView {
                    GitDiffBody(change: change, diff: diff)
                        .id(change.id)
                }
                .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: [])
            }
        }
        .task(id: TaskKey(change: change, token: reloadToken)) {
            diff = await model.diff(change)
        }
    }

    private var stateText: String {
        switch change.kind {
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        default: isStaged ? "Staged" : "Not staged"
        }
    }

    private struct TaskKey: Hashable {
        let change: GitFileChange
        let token: Date?
    }
}

// MARK: - Overview

/// The repository at a glance: where HEAD is, the upstream, the working tree, remotes and more.
struct GitOverview: View {
    let snapshot: GitSnapshot
    let status: GitStatus?
    var show: (GitSidebarItem) -> Void
    var showCommit: (GitOID) -> Void
    var revealInFinder: () -> Void

    /// Width of the card grid, to pick how many cards go in a row.
    @State private var gridWidth: CGFloat = 0
    private static let cardCount = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let operation = snapshot.operation {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(operation.title).fontWeight(.semibold)
                            if let detail = operation.detail { Text(detail).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                }
                cardGrid
                GitHeatmap(commits: snapshot.commits, isTruncated: snapshot.isTruncated, showCommit: showCommit)
                if !snapshot.remotes.isEmpty { remotes }
                if snapshot.worktrees.count > 1 { worktrees }
                if !snapshot.submodules.isEmpty { submodules }
                recentCommits
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.name).font(.title.weight(.semibold))
                Text(((snapshot.workTree ?? snapshot.gitDir) as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let url = snapshot.remotes.first(where: { $0.name == "origin" })?.webURL ?? snapshot.remotes.first?.webURL {
                Link(destination: url) {
                    Label("Open \(url.host() ?? "Remote")", systemImage: "safari")
                }
                .buttonStyle(.bordered)
            }
            Button(action: revealInFinder) { Label("Show in Finder", systemImage: "folder") }
                .buttonStyle(.bordered)
        }
    }

    private var headCard: some View {
        GitCard(title: "Current Branch", symbol: "checkmark.circle") {
            switch snapshot.head {
            case .branch(let name, let oid):
                Text(name).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if oid == nil { Text("No commits yet").foregroundStyle(.secondary) }
            case .detached(let oid):
                Text("Detached HEAD").font(.title3.weight(.semibold))
                Text("At \(oid.short), not on a branch").foregroundStyle(.secondary)
            }
            if let commit = snapshot.headCommit {
                Button { showCommit(commit.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(commit.subject).lineLimit(2).multilineTextAlignment(.leading)
                        Text("\(commit.id.short) · \(commit.committer.date.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var upstreamCard: some View {
        GitCard(title: "Upstream", symbol: "arrow.up.arrow.down") {
            if let branch = snapshot.headBranch, let upstream = branch.upstream {
                Text(upstream).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if branch.upstreamGone {
                    Label("Deleted on the remote", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if branch.ahead == 0 && branch.behind == 0 {
                    Label("Up to date", systemImage: "checkmark").foregroundStyle(.green)
                } else {
                    HStack(spacing: 12) {
                        if branch.ahead > 0 { Label("\(branch.ahead) to push", systemImage: "arrow.up").foregroundStyle(.green) }
                        if branch.behind > 0 { Label("\(branch.behind) to pull", systemImage: "arrow.down").foregroundStyle(.orange) }
                    }
                }
                Text("As of the last fetch").font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("None").font(.title3.weight(.semibold))
                Text(snapshot.head.branchName == nil ? "HEAD isn’t on a branch." : "This branch doesn’t track a remote branch.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var workingTreeCard: some View {
        GitCard(title: "Working Tree", symbol: "doc.on.doc") {
            if let status {
                if status.isClean {
                    Text("Clean").font(.title3.weight(.semibold))
                    Text("Nothing to commit").foregroundStyle(.secondary)
                } else {
                    Button { show(.changes) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(status.count) changed").font(.title3.weight(.semibold))
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                                countRow("Staged", status.staged.count, .green)
                                countRow("Modified", status.unstaged.count, .orange)
                                countRow("Untracked", status.untracked.count, .secondary)
                                countRow("Conflicts", status.conflicted.count, .pink)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func countRow(_ title: String, _ count: Int, _ color: Color) -> some View {
        if count > 0 {
            GridRow {
                Text("\(count)").monospacedDigit().fontWeight(.semibold).foregroundStyle(color)
                Text(title).foregroundStyle(.secondary)
            }
        }
    }

    private var countsCard: some View {
        GitCard(title: "Repository", symbol: "shippingbox") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                stat(snapshot.isTruncated ? "\(snapshot.commits.count.formatted())+" : snapshot.commits.count.formatted(), "commits", .history)
                stat("\(snapshot.branches.count)", snapshot.branches.count == 1 ? "branch" : "branches", nil)
                stat("\(snapshot.remotes.reduce(0) { $0 + $1.branches.count })", "remote branches", nil)
                stat("\(snapshot.tags.count)", snapshot.tags.count == 1 ? "tag" : "tags", nil)
                stat("\(snapshot.stashes.count)", snapshot.stashes.count == 1 ? "stash" : "stashes",
                     snapshot.stashes.isEmpty ? nil : .stashes)
                if snapshot.worktrees.count > 1 { stat("\(snapshot.worktrees.count)", "worktrees", nil) }
            }
        }
    }

    private func stat(_ value: String, _ title: String, _ item: GitSidebarItem?) -> some View {
        GridRow {
            Text(value).monospacedDigit().fontWeight(.semibold)
            if let item {
                Button(title) { show(item) }.buttonStyle(.link)
            } else {
                Text(title).foregroundStyle(.secondary)
            }
        }
    }

    private var identityCard: some View {
        GitCard(title: "Identity", symbol: "person.crop.circle") {
            if let name = snapshot.userName ?? snapshot.userEmail {
                HStack(spacing: 8) {
                    GitAvatar(name: name, email: snapshot.userEmail ?? "", size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.userName ?? "—").fontWeight(.semibold)
                        if let email = snapshot.userEmail { Text(email).foregroundStyle(.secondary) }
                    }
                }
                Text("Set in this repository’s config").font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("Global").font(.title3.weight(.semibold))
                Text("Commits here use your global git name and email.").foregroundStyle(.secondary)
            }
        }
    }

    /// Six cards in even rows: every card in a row is as tall as the tallest, three or two to a row.
    private var cardGrid: some View {
        let columns = gridWidth >= 760 ? 3 : gridWidth >= 480 ? 2 : 1
        return Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            ForEach(Array(stride(from: 0, to: Self.cardCount, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + columns, Self.cardCount), id: \.self) { index in
                        card(index)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
    }

    @ViewBuilder
    private func card(_ index: Int) -> some View {
        switch index {
        case 0: headCard
        case 1: upstreamCard
        case 2: workingTreeCard
        case 3: countsCard
        case 4: identityCard
        default: latestTagCard
        }
    }

    private var latestTagCard: some View {
        GitCard(title: "Latest Tag", symbol: "tag") {
            if snapshot.tags.isEmpty {
                Text("None").font(.title3.weight(.semibold))
                Text("This repository has no tags yet.").foregroundStyle(.secondary)
            }
            if let tag = snapshot.tags.first {
                Button { show(.tag(tag.name)) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tag.name).font(.title3.weight(.semibold))
                        Text([tag.isAnnotated ? "Annotated" : "Lightweight",
                              tag.date?.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        if !tag.message.isEmpty { Text(tag.message).lineLimit(2).font(.callout).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var remotes: some View {
        section("Remotes") {
            ForEach(snapshot.remotes) { remote in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "network").font(.title3).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(remote.name).fontWeight(.semibold)
                            if let branch = remote.defaultBranch {
                                Text("default \(branch)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(remote.fetchURL.isEmpty ? "No URL" : remote.fetchURL)
                            .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        if remote.pushURL != remote.fetchURL, !remote.pushURL.isEmpty {
                            Text("Push: \(remote.pushURL)").font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                        Text("\(remote.branches.count) branches").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let url = remote.webURL {
                        Link(destination: url) { Image(systemName: "arrow.up.forward.app") }
                            .help("Open \(url.absoluteString)")
                    }
                }
                .padding(12)
            }
        }
    }

    private var worktrees: some View {
        section("Worktrees") {
            ForEach(snapshot.worktrees) { worktree in
                HStack(spacing: 12) {
                    Image(systemName: worktree.isMain ? "folder.fill" : "folder").foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((worktree.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Text([worktree.branch ?? worktree.head?.short, worktree.isMain ? "main worktree" : nil,
                              worktree.isLocked ? "locked" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
    }

    private var submodules: some View {
        section("Submodules") {
            ForEach(snapshot.submodules) { submodule in
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(submodule.path).fontWeight(.medium)
                        Text(submodule.url).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(submodule.commit?.short ?? "—").monospaced().foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
    }

    private var recentCommits: some View {
        section("Recent Commits") {
            ForEach(snapshot.commits.prefix(6)) { commit in
                Button { showCommit(commit.id) } label: {
                    HStack(spacing: 10) {
                        GitAvatar(name: commit.author.name, email: commit.author.email, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(commit.subject).lineLimit(1)
                            Text("\(commit.author.name) · \(commit.committer.date.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(commit.id.short).monospaced().font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(spacing: 0) {
                Group(subviews: content()) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                        if index > 0 { Divider().padding(.leading, 48) }
                        subview
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
        }
    }
}

/// Commits by day, like GitHub's contribution graph. Shows at least the last year and fills
/// any extra width with earlier weeks; the totals always cover the last 12 months.
private struct GitHeatmap: View {
    let commits: [GitCommit]
    let isTruncated: Bool
    var showCommit: (GitOID) -> Void

    private static let cell: CGFloat = 11
    private static let gap: CGFloat = 3
    private static let labelWidth: CGFloat = 30
    private static let yearWeeks = 53
    private static let maxWeeks = 53 * 5

    private let calendar = Calendar.current
    private let counts: [Date: Int]
    /// Each day's commits, newest first, for the hover callout.
    private let byDay: [Date: [GitCommit]]
    private let thisWeek: Date
    private let today: Date
    @State private var available: CGFloat = 0
    @State private var hoveredDay: Date?
    @State private var calloutSize: CGSize = .zero

    init(commits: [GitCommit], isTruncated: Bool, showCommit: @escaping (GitOID) -> Void) {
        self.commits = commits
        self.isTruncated = isTruncated
        self.showCommit = showCommit
        let calendar = Calendar.current
        today = calendar.startOfDay(for: .now)
        thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        var byDay: [Date: [GitCommit]] = [:]
        for commit in commits {
            byDay[calendar.startOfDay(for: commit.author.date), default: []].append(commit)
        }
        self.byDay = byDay.mapValues { $0.sorted { $0.author.date > $1.author.date } }
        counts = byDay.mapValues(\.count)
    }

    var body: some View {
        let days = columns(weeks: weeksShown)
        let lastYear = Array(columns(weeks: Self.yearWeeks).joined())
        let yearTotal = lastYear.reduce(0) { $0 + (counts[$1] ?? 0) }
        let activeDays = lastYear.filter { (counts[$0] ?? 0) > 0 }.count
        let streak = longestStreak(lastYear)
        let peak = days.joined().map { counts[$0] ?? 0 }.max() ?? 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Commit Activity", systemImage: "square.grid.3x3.square")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                legend
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                stat("\(yearTotal.formatted())", yearTotal == 1 ? "commit in the last year" : "commits in the last year")
                stat("\(activeDays)", activeDays == 1 ? "active day" : "active days")
                stat("\(streak)", streak == 1 ? "day longest streak" : "days longest streak")
            }
            // Narrower than a year: scroll, starting at the latest weeks.
            ScrollView(.horizontal, showsIndicators: false) {
                grid(days, peak: peak).padding(.bottom, 2)
            }
            .defaultScrollAnchor(.trailing)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
            if isTruncated {
                Text("Counts the latest \(commits.count.formatted()) commits.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
        // Drawn over the card, not inside the scroll view, so the callout isn't clipped.
        .overlayPreferenceValue(HoveredDayAnchor.self) { anchor in
            GeometryReader { proxy in
                if let anchor, let day = hoveredDay {
                    let cell = proxy[anchor]
                    let size = calloutSize
                    let fitsAbove = cell.minY - size.height - 8 >= 0
                    GitDayCallout(day: day, commits: byDay[day] ?? [])
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { calloutSize = $0 }
                        .position(
                            x: min(max(cell.midX, size.width / 2 + 4), proxy.size.width - size.width / 2 - 4),
                            y: fitsAbove ? cell.minY - 8 - size.height / 2 : cell.maxY + 8 + size.height / 2
                        )
                        .opacity(size == .zero ? 0 : 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Commit activity")
        .accessibilityValue("\(yearTotal) commits in the last year on \(activeDays) days, longest streak \(streak) days")
    }

    /// As many whole weeks as fit, never less than a year.
    private var weeksShown: Int {
        let fit = Int((available - Self.labelWidth - 6 + Self.gap) / (Self.cell + Self.gap))
        return min(Self.maxWeeks, max(Self.yearWeeks, fit))
    }

    /// One column per week, oldest first, ending today.
    private func columns(weeks: Int) -> [[Date]] {
        guard let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) else { return [] }
        return (0..<weeks).map { week in
            (0..<7).compactMap { day in
                calendar.date(byAdding: .day, value: week * 7 + day, to: first).flatMap { $0 <= today ? $0 : nil }
            }
        }
    }

    private func grid(_ days: [[Date]], peak: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Weekday labels, every other row like GitHub.
            VStack(alignment: .trailing, spacing: Self.gap) {
                Color.clear.frame(height: 14)
                ForEach(0..<7, id: \.self) { row in
                    Text(row % 2 == 1 ? weekdaySymbol(row) : "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.labelWidth, height: Self.cell, alignment: .trailing)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Self.gap) {
                    ForEach(days.indices, id: \.self) { week in
                        Text(monthLabel(days, week))
                            .font(.caption2)
                            .fontWeight(isYearStart(days, week) ? .semibold : .regular)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: Self.cell, height: 14, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(days.indices, id: \.self) { week in
                        VStack(spacing: Self.gap) {
                            ForEach(days[week], id: \.self) { day in
                                let count = counts[day] ?? 0
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(color(count, peak: peak))
                                    .frame(width: Self.cell, height: Self.cell)
                                    .overlay {
                                        if hoveredDay == day {
                                            RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .onHover { inside in
                                        if inside { hoveredDay = day } else if hoveredDay == day { hoveredDay = nil }
                                    }
                                    .onTapGesture {
                                        if let latest = byDay[day]?.first { showCommit(latest.id) }
                                    }
                                    .anchorPreference(key: HoveredDayAnchor.self, value: .bounds) { hoveredDay == day ? $0 : nil }
                            }
                        }
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("Less").padding(.trailing, 2)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(color(forLevel: level))
                    .frame(width: Self.cell, height: Self.cell)
            }
            Text("More").padding(.leading, 2)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func stat(_ value: String, _ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).foregroundStyle(.secondary)
        }
    }

    private func longestStreak(_ days: [Date]) -> Int {
        var best = 0, run = 0
        for day in days {
            if (counts[day] ?? 0) > 0 {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
        return best
    }

    private func color(_ count: Int, peak: Int) -> Color {
        guard count > 0, peak > 0 else { return color(forLevel: 0) }
        return color(forLevel: min(4, max(1, Int((Double(count) / Double(peak) * 4).rounded(.up)))))
    }

    private func color(forLevel level: Int) -> Color {
        switch level {
        case 0: Color.secondary.opacity(0.14)
        case 1: Color.green.opacity(0.35)
        case 2: Color.green.opacity(0.55)
        case 3: Color.green.opacity(0.78)
        default: Color.green
        }
    }

    private func isYearStart(_ days: [[Date]], _ week: Int) -> Bool {
        guard let first = days[week].first, calendar.component(.month, from: first) == 1 else { return false }
        return !monthLabel(days, week).isEmpty
    }

    /// The month's short name over the first week that starts in it; January shows the year.
    private func monthLabel(_ days: [[Date]], _ week: Int) -> String {
        guard let first = days[week].first else { return "" }
        let month = calendar.component(.month, from: first)
        if week > 0, let previous = days[week - 1].first, calendar.component(.month, from: previous) == month { return "" }
        // Skip a label squeezed against the next one at the very start.
        if week == 0, let next = days[safe: 2]?.first, calendar.component(.month, from: next) != month { return "" }
        if month == 1 { return String(calendar.component(.year, from: first)) }
        return calendar.shortMonthSymbols[month - 1]
    }

    private func weekdaySymbol(_ row: Int) -> String {
        calendar.shortWeekdaySymbols[(calendar.firstWeekday - 1 + row) % 7]
    }
}

private struct HoveredDayAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// What the heatmap shows for the day under the pointer.
private struct GitDayCallout: View {
    let day: Date
    let commits: [GitCommit]

    private static let shown = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year()))
                    .fontWeight(.semibold)
                Spacer(minLength: 8)
                Text(commits.isEmpty ? "No commits" : commits.count == 1 ? "1 commit" : "\(commits.count) commits")
                    .foregroundStyle(commits.isEmpty ? .secondary : Color.green)
                    .fontWeight(.medium)
            }
            if !commits.isEmpty {
                Divider()
                ForEach(commits.prefix(Self.shown)) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(commit.author.date.formatted(date: .omitted, time: .shortened))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(commit.subject).lineLimit(1)
                    }
                }
                if commits.count > Self.shown {
                    Text("and \(commits.count - Self.shown) more").foregroundStyle(.secondary)
                }
                Text("Click to open the latest").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .padding(10)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private struct GitCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            content()
        }
        // Fills its grid cell, so every card in a row matches the tallest.
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Flow layout

/// Lays out views left to right, wrapping onto new lines.
struct GitFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

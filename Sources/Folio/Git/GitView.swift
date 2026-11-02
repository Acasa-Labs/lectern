import AppKit
import SwiftUI

/// What the git viewer's sidebar shows in the content area.
enum GitSidebarItem: Hashable {
    case overview, changes, history, activity, stashes
    case branch(String)        // full ref name
    case remoteBranch(String)
    case tag(String)
}

/// Read-only browser for the open folder's repository: refs, history graph, commits, diffs and
/// the working tree. Shown in Folio's Source Control tab.
struct GitView: View {
    let model: GitViewModel
    var search: String = ""

    @State private var item: GitSidebarItem = .history
    @State private var selectedCommit: GitOID?
    @State private var selectedChange: GitFileChange?
    @State private var selectedReflog: Int?
    @State private var history = GitHistory()
    @AppStorage("gitSidebarWidth") private var sidebarWidth: Double = 200
    @AppStorage("gitDetailWidth") private var detailWidth: Double = 520

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView("Reading repository…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Can’t Read the Repository", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.start() } }
                }
            case .ready:
                if let snapshot = model.snapshot { browser(snapshot) }
            }
        }
        .focusedSceneValue(\.gitCommands, GitCommands(
            refresh: { Task { await model.reload() } },
            revealInFinder: revealInFinder,
            show: { item = $0 }
        ))
    }

    // MARK: - Layout

    private func browser(_ snapshot: GitSnapshot) -> some View {
        // SwiftUI splits, not HSplitView: it ignores ideal widths and draws its dividers up under the toolbar.
        HStack(spacing: 0) {
            GitSidebar(snapshot: snapshot, status: model.status, selection: $item)
                .frame(width: sidebarWidth)
            ResizeHandle(width: $sidebarWidth, range: 160...340, edge: .leading)
            content(snapshot)
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: HistoryKey(item: item, loaded: model.lastLoaded, search: search)) {
            history = GitHistory(snapshot: snapshot, tip: tip(of: item, in: snapshot), search: search)
            if let commit = selectedCommit, history.commits.contains(where: { $0.id == commit }) { return }
            selectedCommit = tip(of: item, in: snapshot) ?? history.commits.first?.id
        }
        .onChange(of: item) {
            selectedReflog = nil
            if item == .stashes { selectedCommit = snapshot.stashes.first?.oid }
            if let tip = tip(of: item, in: snapshot) { selectedCommit = tip }
        }
    }

    @ViewBuilder
    private func content(_ snapshot: GitSnapshot) -> some View {
        switch item {
        case .overview:
            GitOverview(snapshot: snapshot, status: model.status,
                        show: { item = $0 },
                        showCommit: { oid in
                            item = .history
                            selectedCommit = oid
                        },
                        revealInFinder: revealInFinder)
        case .changes:
            GitSplit(trailingWidth: $detailWidth, leadingMinWidth: 240) {
                GitWorkingTreeList(snapshot: snapshot, status: model.status, selection: $selectedChange)
            } trailing: {
                Group {
                    if let change = selectedChange {
                        GitWorkingFileDiff(change: change, isStaged: model.status?.staged.contains(change) ?? false, model: model,
                                           reloadToken: model.lastLoaded)
                    } else {
                        ContentUnavailableView(model.status?.isClean == true ? "Working Tree Clean" : "No File Selected",
                                               systemImage: model.status?.isClean == true ? "checkmark.circle" : "doc.text.magnifyingglass",
                                               description: Text(model.status?.isClean == true
                                                                 ? "Nothing to commit. Every file matches \(snapshot.head.branchName ?? "HEAD")."
                                                                 : "Select a file to see what changed."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .activity:
            GitSplit(trailingWidth: $detailWidth, leadingMinWidth: 280) {
                GitReflogList(entries: snapshot.reflog, selection: $selectedReflog)
            } trailing: {
                detail(for: selectedReflog.flatMap { id in snapshot.reflog.first { $0.id == id }?.new }, snapshot: snapshot,
                       empty: "Select an entry to see its commit.")
            }
        case .stashes:
            GitSplit(trailingWidth: $detailWidth, leadingMinWidth: 260) {
                GitStashList(stashes: snapshot.stashes, selection: $selectedCommit)
            } trailing: {
                detail(for: selectedCommit, snapshot: snapshot, empty: "Select a stash to see what it holds.",
                       note: "Changes compared with the commit the stash was made on.")
            }
        case .history, .branch, .remoteBranch, .tag:
            GitSplit(trailingWidth: $detailWidth, leadingMinWidth: 340) {
                GitCommitList(history: history, title: historyTitle(snapshot), badges: snapshot.badges,
                              headOID: snapshot.head.oid, isTruncated: snapshot.isTruncated, searching: !search.isEmpty,
                              selection: $selectedCommit)
            } trailing: {
                detail(for: selectedCommit, snapshot: snapshot, empty: "Select a commit to see its changes.")
            }
        }
    }

    private func detail(for oid: GitOID?, snapshot: GitSnapshot, empty: String, note: String? = nil) -> some View {
        Group {
            if let oid {
                // No `.id(oid)`: a new identity would rebuild the split pane and reset its width.
                GitCommitDetail(oid: oid, model: model, snapshot: snapshot, note: note,
                                showCommit: { selectedCommit = $0 })
            } else {
                ContentUnavailableView("No Commit Selected", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text(empty))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Kept out of the toolbar's safe area, so no second shade shows under the toolbar glass.
        .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: [])
    }

    // MARK: - Helpers

    private func tip(of item: GitSidebarItem, in snapshot: GitSnapshot) -> GitOID? {
        switch item {
        case .branch(let ref): snapshot.branches.first { $0.refName == ref }?.tip
        case .remoteBranch(let ref): snapshot.remotes.lazy.flatMap(\.branches).first { $0.refName == ref }?.tip
        case .tag(let name): snapshot.tags.first { $0.name == name }?.target
        default: nil
        }
    }

    private func historyTitle(_ snapshot: GitSnapshot) -> String {
        switch item {
        case .branch(let ref): snapshot.branches.first { $0.refName == ref }?.name ?? "Branch"
        case .remoteBranch(let ref): String(ref.dropFirst("refs/remotes/".count))
        case .tag(let name): name
        default: "All Branches"
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.snapshot?.workTree ?? model.path)])
    }

    private func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private struct HistoryKey: Hashable {
        let item: GitSidebarItem
        let loaded: Date?
        let search: String
    }
}

/// A list and a detail pane side by side. The detail keeps the width you drag it to,
/// shrinking only when the window is too narrow to fit both.
private struct GitSplit<Leading: View, Trailing: View>: View {
    @Binding var trailingWidth: Double
    var leadingMinWidth: CGFloat
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    private static var trailingMinWidth: Double { 320 }

    var body: some View {
        GeometryReader { proxy in
            let fits = max(Self.trailingMinWidth, Double(proxy.size.width - leadingMinWidth))
            HStack(spacing: 0) {
                leading()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ResizeHandle(width: $trailingWidth, range: Self.trailingMinWidth...min(1_000, fits), edge: .trailing)
                trailing()
                    .frame(width: min(trailingWidth, fits))
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

/// A divider between panes; drag it to resize the pane on its `edge` side.
private struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// Which side of the handle the resized pane is on.
    let edge: HorizontalEdge
    @State private var dragStart: Double?

    var body: some View {
        Divider()
            .overlay {
                // Wider invisible hit area for resizing.
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStart ?? width
                                dragStart = start
                                let delta = edge == .leading ? value.translation.width : -value.translation.width
                                width = min(max(start + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
            .accessibilityHidden(true)
    }
}

/// Actions the git viewer exposes to the menu bar.
struct GitCommands {
    var refresh: () -> Void
    var revealInFinder: () -> Void
    var show: (GitSidebarItem) -> Void
}

extension FocusedValues {
    @Entry var gitCommands: GitCommands?
}

/// The commits one history list shows, with their graph.
struct GitHistory {
    var commits: [GitCommit] = []
    var graph: [GitGraphRow] = []
    var laneCount = 1

    init() {}

    init(snapshot: GitSnapshot, tip: GitOID?, search: String) {
        var commits = snapshot.commits
        if let tip {
            // Only what's reachable from the chosen ref, like `git log <ref>`.
            let byID = Dictionary(commits.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var reachable: Set<GitOID> = [tip]
            var stack = [tip]
            while let next = stack.popLast() {
                for parent in byID[next]?.parents ?? [] where reachable.insert(parent).inserted { stack.append(parent) }
            }
            commits = commits.filter { reachable.contains($0.id) }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            graph = GitGraph.layout(commits)
            laneCount = min(max(graph.map(\.laneCount).max() ?? 1, 1), 12)
        } else {
            commits = commits.filter { commit in
                commit.message.localizedCaseInsensitiveContains(query)
                    || commit.author.name.localizedCaseInsensitiveContains(query)
                    || commit.author.email.localizedCaseInsensitiveContains(query)
                    || commit.id.hex.hasPrefix(query.lowercased())
            }
        }
        self.commits = commits
    }
}

// MARK: - Sidebar

private struct GitSidebar: View {
    let snapshot: GitSnapshot
    let status: GitStatus?
    @Binding var selection: GitSidebarItem

    @AppStorage("gitSidebar.branches") private var branchesExpanded = true
    @AppStorage("gitSidebar.remotes") private var remotesExpanded = true
    @AppStorage("gitSidebar.tags") private var tagsExpanded = false
    @AppStorage("gitSidebar.worktrees") private var worktreesExpanded = true
    @AppStorage("gitSidebar.submodules") private var submodulesExpanded = true

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let item = $0 { selection = item } })) {
            Section {
                Label(snapshot.name, systemImage: "shippingbox")
                    .tag(GitSidebarItem.overview)
                Label("Changes", systemImage: "plusminus.circle")
                    .badge(status?.count ?? 0)
                    .tag(GitSidebarItem.changes)
                Label("All Branches", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .tag(GitSidebarItem.history)
                Label("Activity", systemImage: "clock.arrow.circlepath")
                    .tag(GitSidebarItem.activity)
                    .help("Where HEAD has been (the reflog)")
                if !snapshot.stashes.isEmpty {
                    Label("Stashes", systemImage: "tray.full")
                        .badge(snapshot.stashes.count)
                        .tag(GitSidebarItem.stashes)
                }
            }

            Section("Branches", isExpanded: $branchesExpanded) {
                if case .detached(let oid) = snapshot.head {
                    Label {
                        Text("Detached at \(oid.short)")
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                    .help("HEAD points at a commit, not a branch")
                }
                ForEach(snapshot.branches) { branch in
                    GitBranchRow(branch: branch)
                        .tag(GitSidebarItem.branch(branch.refName))
                }
            }

            if !snapshot.remotes.isEmpty {
                Section("Remotes", isExpanded: $remotesExpanded) {
                    ForEach(snapshot.remotes) { remote in
                        DisclosureGroup {
                            ForEach(remote.branches) { branch in
                                Label {
                                    HStack {
                                        Text(branch.name)
                                        if branch.name == remote.defaultBranch {
                                            Spacer()
                                            Text("default").font(.caption2).foregroundStyle(.tertiary)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: "arrow.triangle.branch")
                                }
                                .tag(GitSidebarItem.remoteBranch(branch.refName))
                            }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(remote.name)
                                    if let host = remote.host ?? (remote.fetchURL.isEmpty ? nil : remote.fetchURL) {
                                        Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                            } icon: {
                                Image(systemName: "network")
                            }
                            .help(remote.fetchURL)
                            .contextMenu { GitRemoteMenu(remote: remote) }
                        }
                    }
                }
            }

            if !snapshot.tags.isEmpty {
                Section(isExpanded: $tagsExpanded) {
                    ForEach(snapshot.tags) { tag in
                        Label(tag.name, systemImage: tag.isAnnotated ? "tag.fill" : "tag")
                            .help(tag.message.isEmpty ? "Tag at \(tag.target.short)" : tag.message)
                            .tag(GitSidebarItem.tag(tag.name))
                    }
                } header: {
                    Text("Tags (\(snapshot.tags.count))")
                }
            }

            if snapshot.worktrees.count > 1 {
                Section("Worktrees", isExpanded: $worktreesExpanded) {
                    ForEach(snapshot.worktrees) { worktree in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text((worktree.path as NSString).lastPathComponent)
                                Text(worktree.branch ?? worktree.head?.short ?? "—")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: worktree.isMain ? "folder.fill" : "folder")
                        }
                        .help(worktree.path + (worktree.isLocked ? " (locked)" : ""))
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
                            }
                        }
                    }
                }
            }

            if !snapshot.submodules.isEmpty {
                Section("Submodules", isExpanded: $submodulesExpanded) {
                    ForEach(snapshot.submodules) { submodule in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(submodule.path)
                                Text(submodule.commit?.short ?? "not checked in").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "shippingbox.and.arrow.backward")
                        }
                        .help(submodule.url)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct GitBranchRow: View {
    let branch: GitBranch

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(branch.name)
                    .fontWeight(branch.isHead ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                GitAheadBehind(ahead: branch.ahead, behind: branch.behind, gone: branch.upstreamGone)
            }
        } icon: {
            Image(systemName: branch.isHead ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .foregroundStyle(branch.isHead ? Color.accentColor : .secondary)
        }
        .help(helpText)
        .accessibilityLabel(accessibilityText)
    }

    private var helpText: String {
        var lines = [branch.isHead ? "\(branch.name) (checked out)" : branch.name]
        if let upstream = branch.upstream {
            lines.append(branch.upstreamGone ? "Tracks \(upstream), which no longer exists" : "Tracks \(upstream)")
        } else {
            lines.append("No upstream branch")
        }
        if !branch.tipSubject.isEmpty { lines.append(branch.tipSubject) }
        return lines.joined(separator: "\n")
    }

    private var accessibilityText: String {
        var text = branch.name
        if branch.isHead { text += ", current branch" }
        if branch.ahead > 0 { text += ", \(branch.ahead) ahead" }
        if branch.behind > 0 { text += ", \(branch.behind) behind" }
        return text
    }
}

/// `↑2 ↓1` against the upstream branch.
struct GitAheadBehind: View {
    let ahead: Int
    let behind: Int
    var gone = false

    var body: some View {
        HStack(spacing: 4) {
            if gone {
                Text("gone").foregroundStyle(.orange)
            }
            if ahead > 0 {
                Text("↑\(ahead)").foregroundStyle(.green)
            }
            if behind > 0 {
                Text("↓\(behind)").foregroundStyle(.orange)
            }
        }
        .font(.caption.monospacedDigit().weight(.medium))
    }
}

private struct GitRemoteMenu: View {
    let remote: GitRemote

    var body: some View {
        if let url = remote.webURL {
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
        }
        Button("Copy URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(remote.fetchURL, forType: .string)
        }
    }
}

// MARK: - Commit list

private struct GitCommitList: View {
    let history: GitHistory
    let title: String
    let badges: [GitOID: [GitRefBadge]]
    let headOID: GitOID?
    let isTruncated: Bool
    let searching: Bool
    @Binding var selection: GitOID?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Text(countText).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()
            if history.commits.isEmpty {
                ContentUnavailableView(searching ? "No Matching Commits" : "No Commits Yet",
                                       systemImage: searching ? "magnifyingglass" : "circle.dashed",
                                       description: Text(searching ? "Try a different message, author or SHA." : "Make the first commit to start the history."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(history.commits.enumerated()), id: \.element.id) { index, commit in
                                GitCommitRow(
                                    commit: commit,
                                    graph: history.graph.indices.contains(index) ? history.graph[index] : nil,
                                    laneCount: history.laneCount,
                                    badges: badges[commit.id] ?? [],
                                    isHead: commit.id == headOID,
                                    isSelected: commit.id == selection,
                                    isFocused: focused
                                )
                                .id(commit.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = commit.id
                                    focused = true
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selection) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.pageDown) { move(15) }
        .onKeyPress(.pageUp) { move(-15) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commits")
    }

    private var countText: String {
        let count = history.commits.count.formatted()
        let noun = history.commits.count == 1 ? "commit" : "commits"
        return isTruncated && !searching ? "Latest \(count) \(noun)" : "\(count) \(noun)"
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        let commits = history.commits
        guard !commits.isEmpty else { return .ignored }
        let current = commits.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : commits.count)
        selection = commits[min(max(current + offset, 0), commits.count - 1)].id
        return .handled
    }
}

private struct GitCommitRow: View {
    static let height: CGFloat = 48

    let commit: GitCommit
    let graph: GitGraphRow?
    let laneCount: Int
    let badges: [GitRefBadge]
    let isHead: Bool
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let graph {
                GitGraphCell(row: graph, isHead: isHead, isMerge: commit.isMerge)
                    .frame(width: GitGraphCell.width(lanes: laneCount))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    ForEach(badges.prefix(2), id: \.self) { GitRefBadgeView(badge: $0, maxLength: 24) }
                        .layoutPriority(1)
                    if badges.count > 2 {
                        Text("+\(badges.count - 2)").font(.caption2.weight(.semibold)).foregroundStyle(secondary)
                            .help(badges.dropFirst(2).map(\.name).joined(separator: ", "))
                            .layoutPriority(1)
                    }
                    Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                        .fontWeight(isHead ? .semibold : .regular)
                        .foregroundStyle(isSelected && isFocused ? Color.white : .primary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    GitAvatar(name: commit.author.name, email: commit.author.email, size: 14)
                    Text(commit.author.name).lineLimit(1)
                    Text("·")
                    Text(commit.committer.date, format: .relative(presentation: .named))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(commit.id.short).monospaced()
                }
                .font(.caption)
                .foregroundStyle(secondary)
            }
            .padding(.leading, graph == nil ? 8 : 0)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.height)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isFocused ? Color(nsColor: .selectedContentBackgroundColor) : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                    .padding(.horizontal, 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(commit.subject), by \(commit.author.name), \(commit.committer.date.formatted(.relative(presentation: .named)))")
        .accessibilityValue(badges.map(\.name).joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var secondary: Color { isSelected && isFocused ? .white.opacity(0.85) : .secondary }
}

/// One row of the history graph: lane lines and the commit's dot.
private struct GitGraphCell: View {
    static let laneWidth: CGFloat = 14
    static let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red, .mint, .brown, .cyan, .yellow]
    static func width(lanes: Int) -> CGFloat { CGFloat(lanes) * laneWidth + 12 }

    let row: GitGraphRow
    let isHead: Bool
    let isMerge: Bool

    var body: some View {
        Canvas { context, size in
            func x(_ lane: Int) -> CGFloat { 12 + CGFloat(lane) * Self.laneWidth }
            let maxLane = Int((size.width - 12) / Self.laneWidth)
            for edge in row.edges where edge.fromLane <= maxLane && edge.toLane <= maxLane {
                var path = Path()
                let start = CGPoint(x: x(edge.fromLane), y: edge.fromY * size.height)
                let end = CGPoint(x: x(edge.toLane), y: edge.toY * size.height)
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    let middle = (start.y + end.y) / 2
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: middle), control2: CGPoint(x: end.x, y: middle))
                }
                context.stroke(path, with: .color(Self.color(edge.color)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            guard row.lane <= maxLane else { return }
            let center = CGPoint(x: x(row.lane), y: size.height / 2)
            let radius: CGFloat = isHead ? 6 : 4.5
            let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let color = Self.color(row.color)
            if isMerge {
                context.fill(dot, with: .color(Color(nsColor: .textBackgroundColor)))
                context.stroke(dot, with: .color(color), lineWidth: 2)
            } else {
                context.fill(dot, with: .color(color))
            }
            if isHead {
                let ring = Path(ellipseIn: CGRect(x: center.x - radius - 3, y: center.y - radius - 3,
                                                  width: (radius + 3) * 2, height: (radius + 3) * 2))
                context.stroke(ring, with: .color(color.opacity(0.45)), lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }

    static func color(_ index: Int) -> Color { palette[index % palette.count] }
}

struct GitRefBadgeView: View {
    let badge: GitRefBadge
    /// Longer names are shortened in the middle; the full name is in the tooltip.
    var maxLength = Int.max

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(badge.isHead ? Color.white : tint)
            .background(Capsule().fill(badge.isHead ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.16))))
            .fixedSize()
            .help(helpText)
    }

    private var title: String {
        guard badge.name.count > maxLength else { return badge.name }
        let half = (maxLength - 1) / 2
        return badge.name.prefix(half) + "…" + badge.name.suffix(half)
    }

    private var symbol: String {
        switch badge.kind {
        case .head: "location.fill"
        case .branch: badge.isHead ? "checkmark" : "arrow.triangle.branch"
        case .remote: "network"
        case .tag: "tag.fill"
        case .stash: "tray"
        }
    }

    private var tint: Color {
        switch badge.kind {
        case .head: .orange
        case .branch: badge.isHead ? .accentColor : .blue
        case .remote: .purple
        case .tag: .orange
        case .stash: .gray
        }
    }

    private var helpText: String {
        switch badge.kind {
        case .head: "HEAD (detached)"
        case .branch: badge.isHead ? "\(badge.name), checked out" : "Branch \(badge.name)"
        case .remote: "Remote branch \(badge.name)"
        case .tag: "Tag \(badge.name)"
        case .stash: badge.name
        }
    }
}

/// Initials in a colored circle, the color picked from the email so it's stable.
struct GitAvatar: View {
    let name: String
    let email: String
    var size: CGFloat = 22

    private static let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red, .mint, .brown, .cyan]

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
            .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return letters.isEmpty ? "?" : letters
    }

    private var color: Color {
        var hash: UInt32 = 5381
        for byte in (email.isEmpty ? name : email).lowercased().utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return Self.colors[Int(hash % UInt32(Self.colors.count))]
    }
}

// MARK: - Activity and stashes

private struct GitReflogList: View {
    let entries: [GitReflogEntry]
    @Binding var selection: Int?

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("No Activity", systemImage: "clock",
                                   description: Text("HEAD’s history (the reflog) is empty."))
        } else {
            List(entries, selection: $selection) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(entry.message))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action(entry.message)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(detail(entry.message)).lineLimit(2)
                        HStack(spacing: 5) {
                            Text("HEAD@{\(entry.id)}").monospaced()
                            Text("·")
                            Text(entry.who.date, format: .relative(presentation: .named))
                            Spacer()
                            if let new = entry.new { Text(new.short).monospaced() }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .tag(entry.id)
            }
        }
    }

    private func action(_ message: String) -> String {
        guard let colon = message.firstIndex(of: ":") else { return "update" }
        return String(message[..<colon]).capitalized
    }

    private func detail(_ message: String) -> String {
        guard let colon = message.firstIndex(of: ":") else { return message }
        return message[message.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    private func symbol(_ message: String) -> String {
        let action = message.lowercased()
        if action.hasPrefix("checkout") || action.hasPrefix("switch") { return "arrow.left.arrow.right" }
        if action.hasPrefix("merge") { return "arrow.triangle.merge" }
        if action.hasPrefix("rebase") { return "arrow.triangle.swap" }
        if action.hasPrefix("reset") { return "arrow.uturn.backward" }
        if action.hasPrefix("pull") || action.hasPrefix("fetch") { return "arrow.down.circle" }
        if action.hasPrefix("cherry-pick") { return "checkmark.diamond" }
        if action.hasPrefix("clone") { return "square.and.arrow.down" }
        if action.hasPrefix("commit (amend)") { return "pencil.circle" }
        return "circle.fill"
    }
}

private struct GitStashList: View {
    let stashes: [GitStash]
    @Binding var selection: GitOID?

    var body: some View {
        List(stashes, selection: $selection) { stash in
            VStack(alignment: .leading, spacing: 2) {
                Text(stash.message.replacingOccurrences(of: "WIP on ", with: "").replacingOccurrences(of: "On ", with: ""))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text("stash@{\(stash.index)}").monospaced()
                    Text("·")
                    Text(stash.date, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .tag(stash.oid)
        }
    }
}

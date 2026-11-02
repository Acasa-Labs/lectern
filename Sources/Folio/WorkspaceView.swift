import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        NavigationSplitView(columnVisibility: $workspace.columnVisibility) {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 160, ideal: 240, max: 420)
        } detail: {
            VStack(spacing: 0) {
                if !workspace.tabs.isEmpty {
                    TabBar(workspace: workspace)
                    Divider()
                }
                if let tab = workspace.selectedTab {
                    if tab.isFileTab {
                        JumpBar(workspace: workspace, tab: tab)
                        Divider()
                    }
                    TabContentView(tab: tab, git: workspace.git, showSourceControl: workspace.showSourceControl)
                        .id(tab.id)
                } else {
                    WelcomeView()
                }
            }
            .overlay {
                if workspace.showQuickOpen {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.001)
                            .onTapGesture { workspace.showQuickOpen = false }
                        QuickOpenView(workspace: workspace)
                            .padding(.top, 12)
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async { WorkspaceWindowController.open([url], preferring: workspace) }
                    }
                }
                return true
            }
        }
        .navigationTitle(workspace.title)
        .navigationSubtitle(workspace.root == nil ? "" : workspace.selectedTab?.title ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: workspace.goBack) { Label("Back", systemImage: "chevron.left") }
                    .disabled(!workspace.canGoBack)
                    .help("Go back (⌃⌘←)")
                Button(action: workspace.goForward) { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!workspace.canGoForward)
                    .help("Go forward (⌃⌘→)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { workspace.openTerminalTab() } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .help("New Terminal tab in this folder (⌃`)")
                if let tab = workspace.selectedTab, tab.isFileTab, tab.kind.hasPreview, !tab.isBinary {
                    EditToggle(tab: tab)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

private struct EditToggle: View {
    @ObservedObject var tab: EditorTab

    var body: some View {
        Button {
            tab.showsPreview.toggle()
        } label: {
            Label(tab.showsPreview ? "Edit" : "Preview", systemImage: tab.showsPreview ? "pencil" : "eye")
        }
        .help(tab.showsPreview ? "Back to the editor (⌘E)" : "Show the preview (⌘E)")
    }
}

// MARK: Sidebar

private struct SidebarView: View {
    @ObservedObject var workspace: Workspace
    @State private var rootExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            // Navigator switcher, as at the top of Xcode's sidebar.
            Picker("Navigator", selection: $workspace.sidebarMode) {
                Image(systemName: "folder").help("Files").tag(SidebarMode.files)
                Image(systemName: "arrow.triangle.branch").help("Source Control").tag(SidebarMode.sourceControl)
                Image(systemName: "magnifyingglass").help("Find in Folder (⇧⌘F)").tag(SidebarMode.search)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            switch workspace.sidebarMode {
            case .files: files
            case .sourceControl: SourceControlNavigator(workspace: workspace)
            case .search: FindNavigator(workspace: workspace, search: workspace.search)
            }
        }
    }

    @ViewBuilder
    private var files: some View {
        if let root = workspace.root {
            ScrollViewReader { proxy in
                List(selection: $workspace.sidebarSelection) {
                    // The open folder is the top item, like an Xcode project.
                    DisclosureGroup(isExpanded: $rootExpanded) {
                        // Re-read whenever the tree is refreshed from disk.
                        let _ = workspace.treeVersion
                        FileTreeRows(nodes: root.children ?? [], workspace: workspace)
                    } label: {
                        Label {
                            Text(root.name).fontWeight(.semibold)
                        } icon: {
                            Image(systemName: "folder.fill").foregroundStyle(FileIcon.folderColor)
                        }
                    }
                }
                .listStyle(.sidebar)
                // Compact rows like Xcode's navigator, whatever the system sidebar size is.
                .environment(\.sidebarRowSize, .small)
                // List-level menu and double-click, so single clicks still select rows normally.
                .contextMenu(forSelectionType: String.self) { paths in
                    if let path = paths.first {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        // A file's terminal starts in its folder.
                        let folder: URL = {
                            var isDirectory: ObjCBool = false
                            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                            let url = URL(fileURLWithPath: path)
                            return isDirectory.boolValue ? url : url.deletingLastPathComponent()
                        }()
                        Button("New Terminal Here") { workspace.openTerminalTab(in: folder) }
                        if let terminal = ExternalTerminal.preferred {
                            Button("Open in \(terminal.name)") { ExternalTerminal.open(folder) }
                        }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(path, forType: .string)
                        }
                    }
                } primaryAction: { paths in
                    // Double-click: folders open or close, files open.
                    for path in paths {
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
                        let url = URL(fileURLWithPath: path)
                        if isDirectory.boolValue {
                            workspace.isExpanded(url).wrappedValue.toggle()
                        } else {
                            workspace.open(url)
                        }
                    }
                }
                .onChange(of: workspace.sidebarSelection) { _, path in
                    guard let path else { return }
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
                    workspace.open(URL(fileURLWithPath: path))
                }
                .onChange(of: workspace.selectedTabID, initial: true) { _, _ in
                    if let url = workspace.selectedTab?.url { workspace.reveal(url) }
                }
                // Bring a revealed folder or file into view once its parents have expanded.
                .onChange(of: workspace.sidebarScrollRequest?.id) { _, _ in
                    guard let path = workspace.sidebarScrollRequest?.path else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation { proxy.scrollTo(path, anchor: .center) }
                    }
                }
            }
        } else {
            VStack(spacing: 12) {
                Text("No folder open")
                    .foregroundStyle(.secondary)
                Button("Open Folder…") { AppDelegate.shared.openFolder(nil) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Xcode-style file icons: blue folders, an orange Swift bird, coloured braces for JSON.
struct FileIcon: View {
    let url: URL?
    var isDirectory = false

    static let folderColor = Color(red: 0.33, green: 0.65, blue: 0.95)

    var body: some View {
        let (symbol, color) = Self.style(for: url, isDirectory: isDirectory)
        Image(systemName: symbol).foregroundStyle(color)
    }

    static func style(for url: URL?, isDirectory: Bool) -> (String, Color) {
        if isDirectory {
            return url?.pathExtension == "app" ? ("app.dashed", .secondary) : ("folder.fill", folderColor)
        }
        guard let url else { return ("doc.text", .secondary) }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "swift": return ("swift", .orange)
        case "json", "jsonc", "resolved": return ("curlybraces", Color(red: 0.93, green: 0.42, blue: 0.33))
        case "plist", "csv", "tsv": return ("tablecells", .secondary)
        case "sh", "bash", "zsh", "command": return ("terminal", .secondary)
        case "js", "jsx", "mjs", "cjs", "ts", "tsx": return ("curlybraces.square", .yellow)
        case "py": return ("chevron.left.forwardslash.chevron.right", .blue)
        case "html", "htm", "xml", "svg": return ("chevron.left.forwardslash.chevron.right", .orange)
        case "css", "scss", "less": return ("number", .blue)
        default: break
        }
        if DocumentKind.markdownExtensions.contains(ext) { return ("book", .secondary) }
        if UTType(filenameExtension: ext)?.conforms(to: .image) == true { return ("photo", Color(red: 0.33, green: 0.65, blue: 0.95)) }
        if UTType(filenameExtension: ext)?.conforms(to: .sourceCode) == true {
            return ("chevron.left.forwardslash.chevron.right", .secondary)
        }
        return ("doc.text", .secondary)
    }
}

/// The sidebar's Source Control tab: the branch and the changed files, like Xcode's navigator.
/// History opens Flowboard's full viewer as a tab.
private struct SourceControlNavigator: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if let git = workspace.git, git.isRepository {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    Text(git.branchName ?? "Detached HEAD").fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    Button("History", action: workspace.showSourceControl)
                        .controlSize(.small)
                        .help("Open Source Control (⌥⌘G)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
                if let status = git.status, !status.isClean {
                    List {
                        section("Conflicts", status.conflicted, git: git)
                        section("Staged", status.staged, git: git)
                        section("Changes", status.unstaged, git: git)
                        section("Untracked", status.untracked, git: git)
                    }
                    .listStyle(.sidebar)
                    .environment(\.sidebarRowSize, .small)
                } else {
                    ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                           description: Text("The working tree matches the last commit."))
                }
            }
        } else {
            ContentUnavailableView("No Repository", systemImage: "arrow.triangle.branch",
                                   description: Text(workspace.root == nil ? "Open a folder to see its changes."
                                                                          : "This folder isn't in a git repository."))
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ changes: [GitFileChange], git: GitViewModel) -> some View {
        if !changes.isEmpty {
            Section("\(title) (\(changes.count))") {
                ForEach(changes) { change in
                    Button {
                        open(change, git: git)
                    } label: {
                        HStack(spacing: 4) {
                            Label {
                                Text(change.fileName)
                            } icon: {
                                FileIcon(url: URL(fileURLWithPath: change.path))
                            }
                            Text(change.directory)
                                .foregroundStyle(.secondary)
                                .truncationMode(.head)
                            Spacer(minLength: 4)
                            Text(change.kind.letter)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(change.kind == .untracked ? Color.secondary : change.kind == .added ? .green
                                                 : change.kind == .deleted || change.kind == .conflicted ? .red : .orange)
                        }
                        .lineLimit(1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(change.kind == .deleted ? "\(change.path) was deleted" : change.path)
                }
            }
        }
    }

    /// Opens the changed file; deleted files have nothing to open, so they show in Source Control.
    private func open(_ change: GitFileChange, git: GitViewModel) {
        guard change.kind != .deleted, let workTree = git.snapshot?.workTree else {
            workspace.showSourceControl()
            return
        }
        workspace.open(URL(fileURLWithPath: workTree).appendingPathComponent(change.path))
    }
}

/// Folders and files in the sidebar; folders expand in place and remember their state.
private struct FileTreeRows: View {
    let nodes: [FileNode]
    @ObservedObject var workspace: Workspace

    var body: some View {
        ForEach(nodes) { node in
            if node.isDirectory {
                DisclosureGroup(isExpanded: workspace.isExpanded(node.url)) {
                    FileTreeRows(nodes: node.children ?? [], workspace: workspace)
                } label: {
                    row(node)
                }
            } else {
                row(node)
            }
        }
    }

    private func row(_ node: FileNode) -> some View {
        let path = node.url.standardizedFileURL.path
        return HStack(spacing: 4) {
            Label {
                Text(node.name)
            } icon: {
                FileIcon(url: node.url, isDirectory: node.isDirectory)
            }
            Spacer(minLength: 4)
            // Xcode-style source control letter: M, A, D, ?, U…
            if let kind = workspace.git?.fileStatus[path] {
                Text(kind.letter)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Self.color(for: kind))
                    .help(kind.title)
            }
        }
        .lineLimit(1)
        .tag(path)
        .id(path)
    }

    private static func color(for kind: GitFileChange.Kind) -> Color {
        switch kind {
        case .added: .green
        case .modified, .typeChanged: .orange
        case .deleted, .conflicted: .red
        case .renamed: .blue
        case .untracked: .secondary
        }
    }
}

// MARK: Tabs

private struct TabBar: View {
    @ObservedObject var workspace: Workspace

    /// The tabs' fixed widths plus separators, to know when they overflow.
    private var tabsWidth: CGFloat {
        workspace.tabs.reduce(0) { $0 + ($1.isPinned ? TabButton.pinnedWidth : TabButton.width) + 1 }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(workspace.tabs) { tab in
                                TabButton(tab: tab, workspace: workspace, isSelected: tab.id == workspace.selectedTabID)
                                    .id(tab.id)
                                // A short separator, like Xcode's; a full Divider would stretch up under the toolbar.
                                Rectangle()
                                    .fill(.separator)
                                    .frame(width: 1, height: 16)
                            }
                        }
                    }
                    // Keep the selected tab in view however it was chosen.
                    .onChange(of: workspace.selectedTabID, initial: true) { _, id in
                        guard let id else { return }
                        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    }
                }
                if tabsWidth > geometry.size.width {
                    Rectangle().fill(.separator).frame(width: 1, height: 16)
                    overflowMenu
                }
            }
        }
        .frame(height: 34)
        .background(.bar)
    }

    /// Every open tab, for when they don't all fit.
    private var overflowMenu: some View {
        Menu {
            ForEach(workspace.tabs) { tab in
                Button {
                    workspace.selectedTabID = tab.id
                } label: {
                    if tab.id == workspace.selectedTabID {
                        Label(tab.title, systemImage: "checkmark")
                    } else {
                        Text(tab.isDirty ? "\(tab.title)  •" : tab.title)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .help("Show all \(workspace.tabs.count) tabs")
    }
}

private struct TabButton: View {
    @ObservedObject var tab: EditorTab
    @ObservedObject var workspace: Workspace
    @ObservedObject private var bookmarks = BookmarkStore.shared
    let isSelected: Bool
    @State private var hovering = false

    /// Every tab is the same width, so after closing one the next tab's ✕ lands under the pointer.
    static let width: CGFloat = 180
    static let pinnedWidth: CGFloat = 130

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if tab.isSourceControl {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(tab.color?.color ?? .secondary)
                } else if tab.isTerminal {
                    Image(systemName: "terminal").foregroundStyle(tab.color?.color ?? .secondary)
                } else {
                    FileIcon(url: tab.url)
                }
            }
            .imageScale(.small)
            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
            Spacer(minLength: 0)
            trailingControl
                .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 12)
        .frame(width: tab.isPinned ? Self.pinnedWidth : Self.width)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                if isSelected { Color(nsColor: .textBackgroundColor) }
                if let color = tab.color { color.color.opacity(isSelected ? 0.22 : 0.14) }
            }
        }
        .overlay(alignment: .top) {
            // The tab's colour, or the accent colour on the selected tab.
            if let color = tab.color {
                Rectangle().fill(color.color).frame(height: isSelected ? 3 : 2)
            } else if isSelected {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectedTabID = tab.id }
        .onHover { hovering = $0 }
        .help(tab.url?.path ?? tab.terminalDirectory?.path ?? tab.title)
        .contextMenu { menu }
    }

    /// ✕ to close, a dot for unsaved changes, or a pin to unpin.
    @ViewBuilder
    private var trailingControl: some View {
        if tab.isPinned {
            Button { workspace.setPinned(tab, false) } label: {
                Image(systemName: "pin.fill").font(.system(size: 9)).rotationEffect(.degrees(45))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Unpin")
        } else if tab.isDirty && !hovering {
            Circle().frame(width: 7, height: 7).foregroundStyle(.secondary)
        } else {
            Button { workspace.close(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || isSelected ? 1 : 0)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename Tab…") { workspace.rename(tab) }
        Menu("Colour") {
            Button { tab.color = nil } label: {
                if tab.color == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            Divider()
            ForEach(TabColor.allCases, id: \.self) { color in
                Button { tab.color = color } label: {
                    Label {
                        Text(color.name)
                    } icon: {
                        Image(nsImage: color.swatch(selected: tab.color == color))
                    }
                }
            }
        }
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { workspace.setPinned(tab, !tab.isPinned) }
        if BookmarkStore.target(of: tab) != nil {
            Button(bookmarks.bookmark(for: tab) == nil ? "Add to Bookmarks" : "Remove from Bookmarks") {
                bookmarks.toggle(tab)
            }
        }
        Divider()
        Button("Close Tab") { workspace.close(tab) }
        Button("Close Other Tabs") { workspace.closeOthers(than: tab) }
        if let url = tab.url {
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

// MARK: Content

private struct TabContentView: View {
    @ObservedObject var tab: EditorTab
    let git: GitViewModel?
    let showSourceControl: () -> Void
    @AppStorage("zoom") private var zoom = 1.0

    var body: some View {
        if tab.isTerminal {
            TerminalTabView(tab: tab, fontSize: 13 * zoom)
        } else if tab.isSourceControl {
            if let git {
                GitView(model: git)
            } else {
                ContentUnavailableView("No Folder Open", systemImage: "arrow.triangle.branch",
                                       description: Text("Open a folder in a git repository to see its history."))
            }
        } else if tab.isBinary {
            BinaryFileView(url: tab.url)
        } else {
            // Every file opens in the editor; ⌘E swaps it for the preview and back.
            if tab.kind.hasPreview && tab.showsPreview {
                PreviewView(tab: tab, text: tab.text, zoom: zoom)
            } else {
                VStack(spacing: 0) {
                    CodeEditorView(tab: tab, fontSize: 13 * zoom)
                    Divider()
                    StatusBar(cursor: tab.editor.cursor, branch: git?.branchName, showSourceControl: showSourceControl)
                }
            }
        }
    }
}

/// Xcode's bottom bar: the cursor's line and column.
private struct StatusBar: View {
    @ObservedObject var cursor: CursorPosition
    let branch: String?
    let showSourceControl: () -> Void

    var body: some View {
        HStack {
            // The current branch, as in Xcode's toolbar; click it for Source Control.
            if let branch {
                Button(action: showSourceControl) {
                    Label(branch, systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.plain)
                .help("Show Source Control")
            }
            Spacer()
            Text(verbatim: "Line: \(cursor.line)  Col: \(cursor.column)")
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(.bar)
    }
}

/// Xcode's jump bar: the file's path from the open folder. Each part lists its neighbours.
private struct JumpBar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var tab: EditorTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, url in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                part(url, isFirst: index == 0, isLast: index == components.count - 1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }

    /// The open folder, the folders down to the file, then the file.
    private var components: [URL] {
        guard let url = tab.url else { return [] }
        guard let root = workspace.root?.url, workspace.contains(url) else { return [url] }
        var parts = [url]
        var folder = url.deletingLastPathComponent()
        while folder.standardizedFileURL.path.count > root.standardizedFileURL.path.count {
            parts.insert(folder, at: 0)
            folder = folder.deletingLastPathComponent()
        }
        return [root] + parts
    }

    @ViewBuilder
    private func part(_ url: URL, isFirst: Bool, isLast: Bool) -> some View {
        let isDirectory = !isLast
        Menu {
            if isDirectory {
                // A folder: show it in the sidebar, or jump into what it holds.
                Button("Reveal “\(url.lastPathComponent)” in Sidebar") { workspace.revealFolder(url) }
                Divider()
                ForEach(contents(of: url), id: \.url) { item in entry(item) }
            } else {
                ForEach(contents(of: url.deletingLastPathComponent()), id: \.url) { item in entry(item) }
            }
        } label: {
            HStack(spacing: 4) {
                if isFirst && isDirectory {
                    Image(systemName: "folder.fill").foregroundStyle(FileIcon.folderColor)
                } else {
                    FileIcon(url: url, isDirectory: isDirectory)
                }
                Text(url.lastPathComponent).foregroundStyle(isLast ? .primary : .secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// A folder reveals itself in the sidebar; a file opens.
    private func entry(_ item: (url: URL, isDirectory: Bool)) -> some View {
        Button {
            if item.isDirectory { workspace.revealFolder(item.url) } else { workspace.open(item.url) }
        } label: {
            Label(item.url.lastPathComponent, systemImage: FileIcon.style(for: item.url, isDirectory: item.isDirectory).0)
        }
    }

    /// A folder's items for a menu: folders first, then files, as in the sidebar.
    private func contents(of folder: URL) -> [(url: URL, isDirectory: Bool)] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items
            .filter { !FileNode.ignored.contains($0.lastPathComponent) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) }
            .sorted { a, b in
                a.1 != b.1 ? a.1 : a.0.lastPathComponent.localizedStandardCompare(b.0.lastPathComponent) == .orderedAscending
            }
    }
}

private struct PreviewView: NSViewRepresentable {
    let tab: EditorTab
    let text: String
    let zoom: Double

    func makeNSView(context: Context) -> HostedViewContainer { HostedViewContainer(tab.preview.webView) }

    func updateNSView(_ view: HostedViewContainer, context: Context) {
        tab.preview.webView.pageZoom = zoom
        tab.preview.show(text, kind: tab.kind, baseURL: tab.url?.deletingLastPathComponent())
    }
}

/// Hosts a tab's long-lived editor or web view so SwiftUI can add and remove it freely.
final class HostedViewContainer: NSView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        content.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

private struct BinaryFileView: View {
    let url: URL?

    var body: some View {
        if let url, let image = NSImage(contentsOf: url) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image).padding(24)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.questionmark").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("This file isn't text, so Folio can't show it.")
                    .foregroundStyle(.secondary)
                if let url {
                    Button("Open in Default App") { NSWorkspace.shared.open(url) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WelcomeView: View {
    @ObservedObject private var recents = RecentStore.shared
    @ObservedObject private var bookmarks = BookmarkStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Folio").font(.largeTitle.weight(.semibold))
                VStack(alignment: .leading, spacing: 8) {
                    shortcut("New File", "⌘N") { AppDelegate.shared.newFile(nil) }
                    shortcut("Open…", "⌘O") { AppDelegate.shared.openDocument(nil) }
                    shortcut("Open Folder…", "⌥⌘O") { AppDelegate.shared.openFolder(nil) }
                    shortcut("Quick Open", "⌘P") { AppDelegate.shared.quickOpen(nil) }
                }
            }
            if !recents.folders.isEmpty || !recents.files.isEmpty || !bookmarks.bookmarks.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    bookmarkSection
                    recentSection("Recent Folders", recents.folders, isFolder: true)
                    recentSection("Recent Files", recents.files, isFolder: false)
                }
                .frame(width: 320, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var bookmarkSection: some View {
        if !bookmarks.bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bookmarks").font(.headline)
                ForEach(bookmarks.bookmarks) { bookmark in
                    Button {
                        WorkspaceWindowController.open(bookmark)
                    } label: {
                        HStack(spacing: 8) {
                            Group {
                                if bookmark.isTerminal {
                                    Image(systemName: "terminal").foregroundStyle(bookmark.color?.color ?? .secondary)
                                } else {
                                    FileIcon(url: bookmark.url)
                                }
                            }
                            .frame(width: 16)
                            Text(bookmark.title).lineLimit(1)
                            Text((bookmark.isTerminal ? bookmark.url : bookmark.url.deletingLastPathComponent()).path
                                .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(bookmark.path)
                    .contextMenu {
                        Button("Remove Bookmark") { bookmarks.remove(bookmark) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentSection(_ title: String, _ urls: [URL], isFolder: Bool) -> some View {
        if !urls.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                ForEach(urls.prefix(8), id: \.self) { url in
                    Button {
                        WorkspaceWindowController.open([url])
                    } label: {
                        HStack(spacing: 8) {
                            FileIcon(url: url, isDirectory: isFolder).frame(width: 16)
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(url.path)
                }
            }
        }
    }

    private func shortcut(_ title: String, _ keys: String, action: @escaping () -> Void) -> some View {
        HStack {
            Button(title, action: action).buttonStyle(.link)
            Spacer(minLength: 40)
            Text(keys).foregroundStyle(.secondary).monospaced()
        }
        .frame(width: 240)
    }
}

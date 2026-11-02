import AppKit
import SwiftUI

/// A file or folder in the sidebar tree. Folders read their contents the first time they're shown.
final class FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    private var loaded: [FileNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// nil for files, so the outline shows no disclosure arrow.
    var children: [FileNode]? {
        guard isDirectory else { return nil }
        if loaded == nil { loaded = Self.contents(of: url, reusing: []) }
        return loaded
    }

    /// Re-reads folders that have been opened, keeping their already-loaded subfolders.
    func refresh() {
        guard let old = loaded else { return }
        loaded = Self.contents(of: url, reusing: old)
        loaded?.forEach { $0.refresh() }
    }

    static let ignored: Set<String> = [".git", ".DS_Store", ".svn", ".hg"]

    private static func contents(of url: URL, reusing old: [FileNode]) -> [FileNode] {
        let existing = Dictionary(old.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return urls
            .filter { !ignored.contains($0.lastPathComponent) }
            .map { child in
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if let node = existing[child], node.isDirectory == isDirectory { return node }
                return FileNode(url: child, isDirectory: isDirectory)
            }
            .sorted { a, b in
                a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    static func == (a: FileNode, b: FileNode) -> Bool { a.url == b.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// One open file. Its editor and preview views live as long as the tab, so switching tabs
/// keeps scroll position and undo history.
final class EditorTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var url: URL?
    @Published var text: String
    @Published private(set) var savedText: String
    /// Markdown and JSON can swap the editor for a rendered preview (⌘E).
    @Published var showsPreview = false
    let isBinary: Bool
    let undoManager = UndoManager()
    var onOpenLink: (URL) -> Void = { _ in }
    private var modificationDate: Date?
    private var editorController: EditorController?
    private var previewController: PreviewController?
    private var terminalController: TerminalController?
    /// Where a Terminal tab's shell starts.
    var terminalDirectory: URL?
    var onTerminalExit: () -> Void = {}

    var isDirty: Bool { text != savedText }
    /// The Source Control tab shows the repository instead of a file.
    let isSourceControl: Bool
    /// A Terminal tab runs your shell instead of showing a file.
    let isTerminal: Bool
    /// Source Control and Terminal tabs aren't files: no path bar, preview or saving.
    var isFileTab: Bool { !isSourceControl && !isTerminal }
    @Published private(set) var terminalTitle = "Terminal"
    /// Set from the tab's right-click menu.
    @Published var color: TabColor?
    @Published var isPinned = false
    @Published var customTitle: String?
    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if isSourceControl { return "Source Control" }
        if isTerminal { return terminalTitle }
        return url?.lastPathComponent ?? "Untitled"
    }
    var kind: DocumentKind { DocumentKind(fileURL: url) }

    init(url: URL?, isSourceControl: Bool = false, isTerminal: Bool = false) {
        self.url = url
        self.isSourceControl = isSourceControl
        self.isTerminal = isTerminal
        var contents = ""
        if let url, let data = try? Data(contentsOf: url) {
            isBinary = data.prefix(8000).contains(0)
            if !isBinary { contents = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self) }
            modificationDate = Self.modificationDate(of: url)
        } else {
            isBinary = false
        }
        text = contents
        savedText = contents
    }

    var editor: EditorController {
        if let editorController { return editorController }
        let controller = EditorController(tab: self)
        editorController = controller
        return controller
    }

    /// Tabs are only used from the main thread, where SwiftTerm's views live.
    var terminal: TerminalController {
        if let terminalController { return terminalController }
        let controller = MainActor.assumeIsolated {
            let controller = TerminalController(directory: terminalDirectory)
            controller.onTitleChange = { [weak self] title in
                self?.terminalTitle = title.isEmpty ? "Terminal" : title
            }
            controller.onExit = { [weak self] in self?.onTerminalExit() }
            return controller
        }
        terminalController = controller
        return controller
    }

    /// Ends a Terminal tab's shell.
    func endTerminal() {
        guard let terminalController else { return }
        MainActor.assumeIsolated { terminalController.terminate() }
    }

    var preview: PreviewController {
        if let previewController { return previewController }
        let controller = PreviewController()
        controller.openFile = { [weak self] in self?.onOpenLink($0) }
        previewController = controller
        return controller
    }

    func save(to destination: URL) throws {
        // Written in place (not atomically) so permissions such as a script's +x survive.
        try Data(text.utf8).write(to: destination)
        url = destination
        savedText = text
        modificationDate = Self.modificationDate(of: destination)
    }

    /// Picks up edits made by other apps, unless this tab has unsaved changes of its own.
    func reloadIfChangedOnDisk() {
        guard let url, !isDirty, !isBinary,
              let date = Self.modificationDate(of: url), date != modificationDate,
              let data = try? Data(contentsOf: url) else { return }
        modificationDate = date
        let fresh = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        guard fresh != text else { return }
        text = fresh
        savedText = fresh
        editorController?.replaceText(fresh)
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

enum SidebarMode {
    case files, sourceControl, search
}

/// Everything in one window: the open folder, its tabs, Quick Open and Find in Folder.
final class Workspace: ObservableObject {
    @Published private(set) var root: FileNode?
    @Published private(set) var tabs: [EditorTab] = []
    @Published var selectedTabID: UUID? { didSet { recordHistory() } }
    /// Sidebar rows are keyed by standardized path, so URLs from different sources still match.
    @Published var sidebarSelection: String?
    @Published var expandedFolders: Set<String> = []
    /// Path the sidebar should scroll to; the request id lets the same path be asked for twice.
    @Published private(set) var sidebarScrollRequest: (path: String, id: UUID)?
    @Published var showQuickOpen = false
    @Published var sidebarMode: SidebarMode = .files
    /// Bumped to put the cursor in the Find in Folder field.
    @Published private(set) var searchFocusRequest = 0
    let search = FolderSearch()
    @Published var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @Published private(set) var treeVersion = 0
    private var fileIndex: [URL]?
    private var history: [UUID] = []
    private var historyIndex = -1
    private var navigatingHistory = false

    var selectedTab: EditorTab? { tabs.first { $0.id == selectedTabID } }
    var title: String { root?.name ?? selectedTab?.title ?? "Folio" }
    var isEmpty: Bool { root == nil && tabs.allSatisfy { $0.url == nil && !$0.isDirty } }
    /// The open folder's repository (Flowboard's git reader), if the folder is in one.
    @Published private(set) var git: GitViewModel?

    init(root: URL? = nil) {
        if let root { setRoot(root) }
    }

    func setRoot(_ url: URL) {
        root = FileNode(url: url, isDirectory: true)
        fileIndex = nil
        columnVisibility = .all
        RecentStore.shared.addFolder(url)
        // Workspaces are only ever touched from the main thread (UI and menu actions).
        git = MainActor.assumeIsolated {
            let git = GitViewModel(path: url.path)
            Task { await git.start() }
            return git
        }
    }

    func contains(_ url: URL) -> Bool {
        guard let root else { return false }
        return url.standardizedFileURL.path.hasPrefix(root.url.standardizedFileURL.path + "/")
    }

    /// Expands the folders above a file so its sidebar row is visible, as Xcode does.
    func reveal(_ url: URL) {
        guard let root, contains(url) else { return }
        let rootPath = root.url.standardizedFileURL.path
        var folder = url.standardizedFileURL.deletingLastPathComponent()
        while folder.path.count > rootPath.count {
            expandedFolders.insert(folder.path)
            folder = folder.deletingLastPathComponent()
        }
        sidebarSelection = url.standardizedFileURL.path
        sidebarScrollRequest = (url.standardizedFileURL.path, UUID())
    }

    /// Shows a folder in the sidebar: switches to Files, expands it and the folders above it, and selects it.
    func revealFolder(_ url: URL) {
        sidebarMode = .files
        columnVisibility = .all
        guard let root else { return }
        let rootPath = root.url.standardizedFileURL.path
        var folder = url.standardizedFileURL
        while folder.path.count > rootPath.count {
            expandedFolders.insert(folder.path)
            folder = folder.deletingLastPathComponent()
        }
        sidebarSelection = url.standardizedFileURL.path == rootPath ? nil : url.standardizedFileURL.path
        sidebarScrollRequest = (url.standardizedFileURL.path, UUID())
    }

    func isExpanded(_ url: URL) -> Binding<Bool> {
        let path = url.standardizedFileURL.path
        return Binding(
            get: { self.expandedFolders.contains(path) },
            set: { expanded in
                if expanded { self.expandedFolders.insert(path) } else { self.expandedFolders.remove(path) }
            })
    }

    // MARK: Tabs

    func open(_ url: URL) {
        RecentStore.shared.addFile(url)
        let path = url.standardizedFileURL.path
        if let tab = tabs.first(where: { $0.url?.standardizedFileURL.path == path }) {
            selectedTabID = tab.id
            return
        }
        let tab = makeTab(url: url)
        // A blank, untouched Untitled tab gives way to the first real file.
        if tabs.count == 1, let only = tabs.first, only.url == nil, only.isFileTab, only.text.isEmpty {
            tabs = [tab]
        } else if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            // Never in among the pinned tabs, which stay first.
            tabs.insert(tab, at: max(index + 1, pinnedCount))
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
    }

    func newFile() {
        let tab = makeTab(url: nil)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    private func makeTab(url: URL?) -> EditorTab {
        let tab = EditorTab(url: url)
        // Links to files open here; folders and app bundles are only shown in Finder, never launched.
        tab.onOpenLink = { [weak self] link in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: link.path, isDirectory: &isDirectory) else { return }
            if isDirectory.boolValue {
                NSWorkspace.shared.activateFileViewerSelecting([link])
            } else {
                self?.open(link)
            }
        }
        return tab
    }

    @discardableResult
    func close(_ tab: EditorTab) -> Bool {
        guard confirmDiscard(tab), let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        tabs.remove(at: index)
        if tab.isTerminal { tab.endTerminal() }
        if selectedTabID == tab.id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        return true
    }

    /// Pinned tabs stay open.
    func closeOthers(than tab: EditorTab) {
        for other in tabs where other.id != tab.id && !other.isPinned {
            guard close(other) else { return }
        }
    }

    private var pinnedCount: Int { tabs.filter(\.isPinned).count }

    /// Pinned tabs sit together at the left; unpinning puts a tab just after them.
    func setPinned(_ tab: EditorTab, _ pinned: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }), tab.isPinned != pinned else { return }
        tabs.remove(at: index)
        tab.isPinned = pinned
        tabs.insert(tab, at: pinnedCount)
    }

    func rename(_ tab: EditorTab) {
        guard let name = promptForTabName(tab.title) else { return }
        tab.customTitle = name.isEmpty ? nil : name
        objectWillChange.send()
    }

    /// Opens a bookmark here: its file as a tab, or a new terminal in its folder. Its name and colour come too.
    func open(_ bookmark: Bookmark) {
        if bookmark.isTerminal {
            openTerminalTab(in: bookmark.url)
        } else {
            open(bookmark.url)
        }
        guard let tab = selectedTab else { return }
        if tab.customTitle == nil, bookmark.title != tab.title { tab.customTitle = bookmark.title }
        if tab.color == nil { tab.color = bookmark.color }
    }

    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectedTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    // MARK: Source Control

    /// Opens (or switches to) the Source Control tab.
    func showSourceControl() {
        if let tab = tabs.first(where: \.isSourceControl) {
            selectedTabID = tab.id
            return
        }
        let tab = EditorTab(url: nil, isSourceControl: true)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    // MARK: Terminal

    /// The folder a terminal starts in: the open folder, else the current file's folder, else home.
    private var terminalFolder: URL {
        root?.url
            ?? selectedTab?.url?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Opens a Terminal tab running your shell, in `folder` or the workspace's folder.
    func openTerminalTab(in folder: URL? = nil) {
        let tab = EditorTab(url: nil, isTerminal: true)
        tab.terminalDirectory = folder ?? terminalFolder
        tab.onTerminalExit = { [weak self, weak tab] in
            guard let self, let tab, tabs.contains(where: { $0.id == tab.id }) else { return }
            close(tab)
        }
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Opens the folder in your own terminal app (iTerm or Terminal), outside Folio.
    func openInTerminal() {
        ExternalTerminal.open(terminalFolder)
    }

    // MARK: Find in Folder

    func showFindInFolder() {
        columnVisibility = .all
        sidebarMode = .search
        searchFocusRequest += 1
    }

    /// Opens a search result and selects the match in the editor.
    func reveal(_ range: NSRange, in url: URL) {
        open(url)
        guard let tab = selectedTab, !tab.isBinary else { return }
        tab.showsPreview = false
        let editor = tab.editor
        // Give the editor a moment to be on screen so it can scroll.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { editor.select(range) }
    }

    // MARK: Back and forward

    var canGoBack: Bool { historyTarget(step: -1) != nil }
    var canGoForward: Bool { historyTarget(step: 1) != nil }

    func goBack() { navigateHistory(step: -1) }
    func goForward() { navigateHistory(step: 1) }

    private func recordHistory() {
        guard !navigatingHistory, let id = selectedTabID else { return }
        if history.indices.contains(historyIndex), history[historyIndex] == id { return }
        history = Array(history.prefix(historyIndex + 1)) + [id]
        historyIndex = history.count - 1
    }

    /// The nearest history entry in that direction whose tab is still open.
    private func historyTarget(step: Int) -> Int? {
        var index = historyIndex + step
        while history.indices.contains(index) {
            if history[index] != selectedTabID, tabs.contains(where: { $0.id == history[index] }) { return index }
            index += step
        }
        return nil
    }

    private func navigateHistory(step: Int) {
        guard let index = historyTarget(step: step) else { return }
        navigatingHistory = true
        historyIndex = index
        selectedTabID = history[index]
        navigatingHistory = false
    }

    // MARK: Saving

    /// Offers to save unsaved changes. Returns false if the user cancelled.
    func confirmDiscard(_ tab: EditorTab) -> Bool {
        guard tab.isDirty else { return true }
        selectedTabID = tab.id
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(tab.title)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(tab)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func confirmCloseAll() -> Bool {
        tabs.allSatisfy { confirmDiscard($0) }
    }

    @discardableResult
    func save(_ tab: EditorTab, choosingLocation: Bool = false) -> Bool {
        var destination = tab.url
        if destination == nil || choosingLocation {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = tab.url?.lastPathComponent ?? "Untitled.md"
            panel.directoryURL = tab.url?.deletingLastPathComponent() ?? root?.url
            panel.allowsOtherFileTypes = true
            panel.isExtensionHidden = false
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        do {
            try tab.save(to: destination!)
            refreshFromDisk()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    // MARK: Disk

    /// Called when the app comes back to the front: re-read the tree and any files changed elsewhere.
    func refreshFromDisk() {
        root?.refresh()
        fileIndex = nil
        treeVersion += 1
        tabs.forEach { $0.reloadIfChangedOnDisk() }
    }

    /// Every file in the folder for Quick Open, skipping the folders that are almost never wanted.
    @MainActor
    func indexFiles() async -> [URL] {
        if let fileIndex { return fileIndex }
        guard let rootURL = root?.url else { return tabs.compactMap(\.url) }
        let files = await Task.detached(priority: .userInitiated) { Self.enumerateFiles(in: rootURL) }.value
        fileIndex = files
        return files
    }

    private static func enumerateFiles(in root: URL) -> [URL] {
        let skipped: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods", ".svn", ".hg", ".DS_Store"]
        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            if skipped.contains(url.lastPathComponent) {
                enumerator?.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            files.append(url)
            if files.count >= 50_000 { break }
        }
        return files
    }
}

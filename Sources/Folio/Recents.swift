import AppKit

/// Recently opened folders and files, newest first, kept across launches.
final class RecentStore: ObservableObject {
    static let shared = RecentStore()
    private static let limit = 12

    @Published private(set) var folders: [URL]
    @Published private(set) var files: [URL]

    private init() {
        folders = Self.load("recentFolders")
        files = Self.load("recentFiles")
    }

    func addFolder(_ url: URL) { folders = Self.adding(url, to: folders, key: "recentFolders") }
    func addFile(_ url: URL) { files = Self.adding(url, to: files, key: "recentFiles") }

    func clear() {
        folders = []
        files = []
        UserDefaults.standard.removeObject(forKey: "recentFolders")
        UserDefaults.standard.removeObject(forKey: "recentFiles")
    }

    private static func adding(_ url: URL, to list: [URL], key: String) -> [URL] {
        let path = url.standardizedFileURL.path
        let updated = Array(([url.standardizedFileURL] + list.filter { $0.path != path }).prefix(limit))
        UserDefaults.standard.set(updated.map(\.path), forKey: key)
        return updated
    }

    /// Items that no longer exist on disk are dropped.
    private static func load(_ key: String) -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

/// What each window had open, so the next launch can pick up where you left off.
struct WindowSession: Codable {
    /// One tab: a file, or a terminal's folder, with what you set on it.
    struct Entry: Codable {
        var path: String?
        var terminal: String?
        var pinned: Bool?
        var color: TabColor?
        var title: String?
    }

    var root: String?
    /// File paths only; kept so sessions saved by older versions still load.
    var tabs: [String]
    var entries: [Entry]?
    var selected: String?
    var selectedIndex: Int?

    private static let key = "lastSession"

    init(_ workspace: Workspace) {
        root = workspace.root?.url.path
        tabs = workspace.tabs.compactMap { $0.url?.path }
        var entries: [Entry] = []
        for tab in workspace.tabs {
            let entry: Entry
            if tab.isTerminal, let folder = tab.terminalDirectory {
                entry = Entry(terminal: folder.path)
            } else if tab.isFileTab, let url = tab.url {
                entry = Entry(path: url.path)
            } else {
                continue
            }
            if tab.id == workspace.selectedTabID { selectedIndex = entries.count }
            entries.append(Entry(path: entry.path, terminal: entry.terminal, pinned: tab.isPinned,
                                 color: tab.color, title: tab.customTitle))
        }
        self.entries = entries
        selected = workspace.selectedTab?.url?.path
    }

    var isEmpty: Bool { root == nil && tabs.isEmpty && (entries ?? []).isEmpty }

    static func save(_ sessions: [WindowSession]) {
        let kept = sessions.filter { !$0.isEmpty }
        if let data = try? JSONEncoder().encode(kept) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func load() -> [WindowSession] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([WindowSession].self, from: data)) ?? []
    }
}

/// File → Open Recent, rebuilt each time it opens.
final class OpenRecentMenu: NSObject, NSMenuDelegate {
    static let shared = OpenRecentMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recents = RecentStore.shared
        for url in recents.folders { menu.addItem(item(for: url, isFolder: true)) }
        if !recents.folders.isEmpty && !recents.files.isEmpty { menu.addItem(.separator()) }
        for url in recents.files { menu.addItem(item(for: url, isFolder: false)) }
        if recents.folders.isEmpty && recents.files.isEmpty {
            let empty = NSMenuItem(title: "No Recent Items", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Menu", action: #selector(clear(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }

    private func item(for url: URL, isFolder: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: url.lastPathComponent, action: #selector(open(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.toolTip = url.path
        item.image = NSImage(systemSymbolName: isFolder ? "folder" : "doc.text", accessibilityDescription: nil)
        return item
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        WorkspaceWindowController.open([url])
    }

    @objc private func clear(_ sender: Any?) {
        RecentStore.shared.clear()
    }
}

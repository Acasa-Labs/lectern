import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static let shared = AppDelegate()

    private var workspace: Workspace? { WorkspaceWindowController.current?.workspace }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(target: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Files opened from Finder arrive around launch. If none did, pick up the last session,
        // or show the welcome window with recent items.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard WorkspaceWindowController.all.isEmpty else { return }
            let sessions = WindowSession.load()
            sessions.forEach(WorkspaceWindowController.restore)
            if WorkspaceWindowController.all.isEmpty { WorkspaceWindowController.newWindow() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WorkspaceWindowController.saveSession()
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        WorkspaceWindowController.open(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WorkspaceWindowController.newWindow() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        WorkspaceWindowController.all.forEach { $0.workspace.refreshFromDisk() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WorkspaceWindowController.all.allSatisfy { $0.workspace.confirmCloseAll() } ? .terminateNow : .terminateCancel
    }

    // MARK: Menu actions

    @objc func newFile(_ sender: Any?) {
        (workspace ?? WorkspaceWindowController.newWindow().workspace).newFile()
    }

    @objc func newWindow(_ sender: Any?) {
        WorkspaceWindowController.newWindow()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK { WorkspaceWindowController.open(panel.urls) }
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { WorkspaceWindowController.open(panel.urls) }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let workspace, let tab = workspace.selectedTab else { return }
        workspace.save(tab)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let workspace, let tab = workspace.selectedTab else { return }
        workspace.save(tab, choosingLocation: true)
    }

    @objc func closeTab(_ sender: Any?) {
        if let workspace, let tab = workspace.selectedTab {
            workspace.close(tab)
        } else {
            NSApp.keyWindow?.performClose(sender)
        }
    }

    @objc func quickOpen(_ sender: Any?) {
        workspace?.showQuickOpen.toggle()
    }

    @objc func findInFolder(_ sender: Any?) {
        (workspace ?? WorkspaceWindowController.newWindow().workspace).showFindInFolder()
    }

    @objc func bookmarkTab(_ sender: Any?) {
        guard let tab = workspace?.selectedTab else { return }
        BookmarkStore.shared.toggle(tab)
    }

    @objc func connectToServer(_ sender: Any?) {
        guard let target = SavedServers.promptForServer() else { return }
        (workspace ?? WorkspaceWindowController.newWindow().workspace).openSSHTab(target)
    }

    @objc func newTerminalTab(_ sender: Any?) {
        (workspace ?? WorkspaceWindowController.newWindow().workspace).openTerminalTab()
    }

    @objc func openInTerminal(_ sender: Any?) {
        if let workspace { workspace.openInTerminal() } else { ExternalTerminal.open(FileManager.default.homeDirectoryForCurrentUser) }
    }

    @objc func chooseTerminal(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        ExternalTerminal.choose(bundleID)
    }

    @objc func showSourceControl(_ sender: Any?) {
        workspace?.showSourceControl()
    }

    @objc func toggleFileSidebar(_ sender: Any?) {
        guard let workspace else { return }
        workspace.columnVisibility = workspace.columnVisibility == .detailOnly ? .all : .detailOnly
    }

    @objc func toggleEditing(_ sender: Any?) {
        guard let tab = workspace?.selectedTab, tab.isFileTab, tab.kind.hasPreview else { return }
        tab.showsPreview.toggle()
    }

    @objc func toggleWordWrap(_ sender: Any?) {
        UserDefaults.standard.set(!wordWrap, forKey: "wordWrap")
    }

    private var wordWrap: Bool { UserDefaults.standard.object(forKey: "wordWrap") as? Bool ?? true }

    @objc func toggleMinimap(_ sender: Any?) {
        UserDefaults.standard.set(!showsMinimap, forKey: "showMinimap")
    }

    private var showsMinimap: Bool { UserDefaults.standard.object(forKey: "showMinimap") as? Bool ?? true }

    @objc func goBack(_ sender: Any?) { workspace?.goBack() }
    @objc func goForward(_ sender: Any?) { workspace?.goForward() }

    @objc func nextTab(_ sender: Any?) { workspace?.selectTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { workspace?.selectTab(offset: -1) }

    @objc func zoomIn(_ sender: Any?) { setZoom(zoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(zoom - 0.1) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    private var zoom: Double { UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1 }
    private func setZoom(_ value: Double) { UserDefaults.standard.set(min(max(value, 0.5), 3), forKey: "zoom") }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)):
            return workspace?.selectedTab != nil
        case #selector(toggleEditing(_:)):
            let tab = workspace?.selectedTab
            item.title = tab?.showsPreview == true ? "Show Editor" : "Show Preview"
            return tab?.isFileTab == true && tab?.kind.hasPreview == true && tab?.isBinary == false
        case #selector(toggleWordWrap(_:)):
            item.state = wordWrap ? .on : .off
            return true
        case #selector(toggleMinimap(_:)):
            item.state = showsMinimap ? .on : .off
            return true
        case #selector(goBack(_:)):
            return workspace?.canGoBack == true
        case #selector(goForward(_:)):
            return workspace?.canGoForward == true
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            return (workspace?.tabs.count ?? 0) > 1
        case #selector(bookmarkTab(_:)):
            guard let tab = workspace?.selectedTab, BookmarkStore.target(of: tab) != nil else { return false }
            item.title = BookmarkStore.shared.bookmark(for: tab) == nil ? "Bookmark This Tab" : "Remove Bookmark for This Tab"
            return true
        case #selector(openInTerminal(_:)):
            item.title = "Open in \(ExternalTerminal.preferred?.name ?? "Terminal")"
            return ExternalTerminal.preferred != nil
        case #selector(chooseTerminal(_:)):
            item.state = (item.representedObject as? String) == ExternalTerminal.preferred?.bundleID ? .on : .off
            return true
        case #selector(showSourceControl(_:)):
            return workspace?.git?.isRepository == true
        case #selector(quickOpen(_:)), #selector(toggleFileSidebar(_:)):
            return workspace != nil
        default:
            return true
        }
    }
}

enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command, toApp: Bool = true, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = toApp ? target : nil
            item.tag = tag
            return item
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            return holder
        }
        // Items with toApp: false go to the first responder (the text view, window or app).
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services

        let find = menu("Find", [
            item("Find…", #selector(NSTextView.performTextFinderAction(_:)), "f", toApp: false, tag: 1),
            item("Find and Replace…", #selector(NSTextView.performTextFinderAction(_:)), "f", [.command, .option], toApp: false, tag: 12),
            item("Find Next", #selector(NSTextView.performTextFinderAction(_:)), "g", toApp: false, tag: 2),
            item("Find Previous", #selector(NSTextView.performTextFinderAction(_:)), "g", [.command, .shift], toApp: false, tag: 3),
            .separator(),
            item("Find in Folder…", #selector(AppDelegate.findInFolder(_:)), "f", [.command, .shift]),
        ])

        let window = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", toApp: false),
            item("Zoom", #selector(NSWindow.performZoom(_:)), toApp: false),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), toApp: false),
        ])
        NSApp.windowsMenu = window.submenu

        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecent.submenu = NSMenu(title: "Open Recent")
        openRecent.submenu?.delegate = OpenRecentMenu.shared

        // Bookmarks: the fixed item, then the saved bookmarks (filled in each time it opens).
        let bookmarks = menu("Bookmarks", [
            item("Bookmark This Tab", #selector(AppDelegate.bookmarkTab(_:)), "d"),
            .separator(),
        ])
        bookmarks.submenu?.delegate = BookmarksMenu.shared

        // View → Terminal App: which installed terminal "Open in Terminal" uses.
        let terminalApps = NSMenuItem(title: "Terminal App", action: nil, keyEquivalent: "")
        terminalApps.submenu = NSMenu(title: "Terminal App")
        for app in ExternalTerminal.installed {
            let choice = item(app.name, #selector(AppDelegate.chooseTerminal(_:)))
            choice.representedObject = app.bundleID
            terminalApps.submenu?.addItem(choice)
        }

        let main = NSMenu()
        [
            menu("Folio", [
                item("About Folio", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), toApp: false),
                .separator(),
                servicesItem,
                .separator(),
                item("Hide Folio", #selector(NSApplication.hide(_:)), "h", toApp: false),
                item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], toApp: false),
                item("Show All", #selector(NSApplication.unhideAllApplications(_:)), toApp: false),
                .separator(),
                item("Quit Folio", #selector(NSApplication.terminate(_:)), "q", toApp: false),
            ]),
            menu("File", [
                item("New File", #selector(AppDelegate.newFile(_:)), "n"),
                item("New Window", #selector(AppDelegate.newWindow(_:)), "n", [.command, .shift]),
                .separator(),
                item("Open…", #selector(AppDelegate.openDocument(_:)), "o"),
                item("Open Folder…", #selector(AppDelegate.openFolder(_:)), "o", [.command, .option]),
                openRecent,
                .separator(),
                item("Save", #selector(AppDelegate.saveDocument(_:)), "s"),
                item("Save As…", #selector(AppDelegate.saveDocumentAs(_:)), "s", [.command, .shift]),
                .separator(),
                item("Close Tab", #selector(AppDelegate.closeTab(_:)), "w"),
                item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift], toApp: false),
            ]),
            menu("Edit", [
                item("Undo", Selector(("undo:")), "z", toApp: false),
                item("Redo", Selector(("redo:")), "z", [.command, .shift], toApp: false),
                .separator(),
                item("Cut", #selector(NSText.cut(_:)), "x", toApp: false),
                item("Copy", #selector(NSText.copy(_:)), "c", toApp: false),
                item("Paste", #selector(NSText.paste(_:)), "v", toApp: false),
                item("Select All", #selector(NSText.selectAll(_:)), "a", toApp: false),
                .separator(),
                find,
            ]),
            menu("View", [
                item("Toggle Sidebar", #selector(AppDelegate.toggleFileSidebar(_:)), "b"),
                item("Source Control", #selector(AppDelegate.showSourceControl(_:)), "g", [.command, .option]),
                item("New Terminal Tab", #selector(AppDelegate.newTerminalTab(_:)), "`", .control),
                item("Connect to Server…", #selector(AppDelegate.connectToServer(_:)), "k", [.command, .shift]),
                item("Open in Terminal", #selector(AppDelegate.openInTerminal(_:)), "`", [.control, .shift]),
                terminalApps,
                item("Show Preview", #selector(AppDelegate.toggleEditing(_:)), "e"),
                item("Word Wrap", #selector(AppDelegate.toggleWordWrap(_:)), "z", .option),
                item("Minimap", #selector(AppDelegate.toggleMinimap(_:)), "m", [.command, .control, .shift]),
                .separator(),
                item("Actual Size", #selector(AppDelegate.actualSize(_:)), "0"),
                item("Zoom In", #selector(AppDelegate.zoomIn(_:)), "="),
                item("Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-"),
                .separator(),
                item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], toApp: false),
            ]),
            menu("Go", [
                item("Back", #selector(AppDelegate.goBack(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .control]),
                item("Forward", #selector(AppDelegate.goForward(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .control]),
                .separator(),
                item("Quick Open…", #selector(AppDelegate.quickOpen(_:)), "p"),
                .separator(),
                item("Next Tab", #selector(AppDelegate.nextTab(_:)), "]", [.command, .shift]),
                item("Previous Tab", #selector(AppDelegate.previousTab(_:)), "[", [.command, .shift]),
            ]),
            bookmarks,
            window,
        ].forEach(main.addItem)
        return main
    }
}

/// One workspace window, hosting the SwiftUI views.
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    static private(set) var all: [WorkspaceWindowController] = []
    let workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: WorkspaceView(workspace: workspace))
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        if let previous = Self.all.last?.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        } else {
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static var current: WorkspaceWindowController? {
        (NSApp.keyWindow?.windowController as? WorkspaceWindowController)
            ?? (NSApp.mainWindow?.windowController as? WorkspaceWindowController)
            ?? all.last
    }

    @discardableResult
    static func newWindow(root: URL? = nil) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(workspace: Workspace(root: root))
        all.append(controller)
        controller.showWindow(nil)
        return controller
    }

    /// Opens a bookmark in the front window, or a new one.
    static func open(_ bookmark: Bookmark) {
        if bookmark.ssh != nil {
            let controller = current ?? newWindow()
            controller.workspace.open(bookmark)
            controller.showWindow(nil)
            return
        }
        guard FileManager.default.fileExists(atPath: bookmark.path) else {
            let alert = NSAlert()
            alert.messageText = "“\(bookmark.title)” can't be found"
            alert.informativeText = "\(bookmark.path) was moved or deleted. Remove the bookmark?"
            alert.addButton(withTitle: "Remove Bookmark")
            alert.addButton(withTitle: "Keep")
            if alert.runModal() == .alertFirstButtonReturn { BookmarkStore.shared.remove(bookmark) }
            return
        }
        let controller = bookmark.isTerminal ? (current ?? newWindow())
            : (all.first { $0.workspace.contains(bookmark.url) } ?? current ?? newWindow())
        controller.workspace.open(bookmark)
        controller.showWindow(nil)
    }

    /// Folders open as a workspace window; files open as a tab in the window whose folder holds them,
    /// else the front window.
    static func open(_ urls: [URL], preferring preferred: Workspace? = nil) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let path = url.standardizedFileURL.path
                if let existing = all.first(where: { $0.workspace.root?.url.standardizedFileURL.path == path }) {
                    existing.showWindow(nil)
                } else if let empty = (all.first { $0.workspace === preferred } ?? current), empty.workspace.isEmpty {
                    empty.workspace.setRoot(url)
                    empty.showWindow(nil)
                } else {
                    newWindow(root: url)
                }
            } else {
                let controller = all.first { $0.workspace.contains(url) }
                    ?? all.first { $0.workspace === preferred }
                    ?? current
                    ?? newWindow()
                controller.workspace.open(url)
                controller.showWindow(nil)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        workspace.confirmCloseAll()
    }

    func windowWillClose(_ notification: Notification) {
        workspace.tabs.filter(\.isTerminal).forEach { $0.endTerminal() }
        // Closing the last window still leaves something to come back to.
        if Self.all.count == 1 { Self.saveSession() }
        Self.all.removeAll { $0 === self }
    }

    static func saveSession() {
        guard !all.isEmpty else { return }
        WindowSession.save(all.map { WindowSession($0.workspace) })
    }

    /// Reopens a saved window: its folder, then its tabs that still exist.
    static func restore(_ session: WindowSession) {
        let fileManager = FileManager.default
        let root = session.root.map { URL(fileURLWithPath: $0) }.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil }
        // Older sessions only listed file paths.
        let entries = session.entries ?? session.tabs.map { WindowSession.Entry(path: $0) }
        let available = entries.filter { entry in
            entry.ssh != nil || [entry.path, entry.terminal].compactMap { $0 }.contains { fileManager.fileExists(atPath: $0) }
        }
        guard root != nil || !available.isEmpty else { return }
        let workspace = newWindow(root: root).workspace
        var restored: [EditorTab?] = []
        for entry in entries {
            if let ssh = entry.ssh {
                // Reconnects only when the tab is first shown.
                workspace.openSSHTab(ssh)
            } else if let path = entry.path, fileManager.fileExists(atPath: path) {
                workspace.open(URL(fileURLWithPath: path))
            } else if let folder = entry.terminal, fileManager.fileExists(atPath: folder) {
                // A fresh shell in the same folder; it starts when the tab is first shown.
                workspace.openTerminalTab(in: URL(fileURLWithPath: folder))
            } else {
                restored.append(nil)
                continue
            }
            let tab = workspace.selectedTab
            tab?.color = entry.color
            tab?.customTitle = entry.title
            if entry.pinned == true, let tab { workspace.setPinned(tab, true) }
            restored.append(tab)
        }
        if let index = session.selectedIndex, restored.indices.contains(index), let tab = restored[index] {
            workspace.selectedTabID = tab.id
        } else if let selected = session.selected, fileManager.fileExists(atPath: selected) {
            workspace.open(URL(fileURLWithPath: selected))
        }
    }
}

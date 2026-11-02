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

    @objc func showSourceControl(_ sender: Any?) {
        workspace?.showSourceControl()
    }

    @objc func toggleFileSidebar(_ sender: Any?) {
        guard let workspace else { return }
        workspace.columnVisibility = workspace.columnVisibility == .detailOnly ? .all : .detailOnly
    }

    @objc func toggleEditing(_ sender: Any?) {
        guard let tab = workspace?.selectedTab, tab.kind.hasPreview else { return }
        tab.showsPreview.toggle()
    }

    @objc func toggleWordWrap(_ sender: Any?) {
        UserDefaults.standard.set(!wordWrap, forKey: "wordWrap")
    }

    private var wordWrap: Bool { UserDefaults.standard.object(forKey: "wordWrap") as? Bool ?? true }

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
            return tab?.kind.hasPreview == true && tab?.isBinary == false
        case #selector(toggleWordWrap(_:)):
            item.state = wordWrap ? .on : .off
            return true
        case #selector(goBack(_:)):
            return workspace?.canGoBack == true
        case #selector(goForward(_:)):
            return workspace?.canGoForward == true
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            return (workspace?.tabs.count ?? 0) > 1
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
                item("Show Preview", #selector(AppDelegate.toggleEditing(_:)), "e"),
                item("Word Wrap", #selector(AppDelegate.toggleWordWrap(_:)), "z", .option),
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
        let tabs = session.tabs.filter { fileManager.fileExists(atPath: $0) }
        guard root != nil || !tabs.isEmpty else { return }
        let workspace = newWindow(root: root).workspace
        tabs.forEach { workspace.open(URL(fileURLWithPath: $0)) }
        if let selected = session.selected, fileManager.fileExists(atPath: selected) {
            workspace.open(URL(fileURLWithPath: selected))
        }
    }
}

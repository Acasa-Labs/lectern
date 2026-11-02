import AppKit
import SwiftUI

/// A colour you can give a tab, to tell tabs apart at a glance.
enum TabColor: String, Codable, CaseIterable {
    case red, orange, yellow, green, blue, purple, gray

    var name: String { rawValue == "gray" ? "Grey" : rawValue.capitalized }

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }

    /// A coloured dot for menus, which draw SF Symbols in one tint. The current colour gets a ring.
    func swatch(selected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            if selected {
                NSColor.labelColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            self.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A saved file, or a folder to open a terminal in, kept across launches.
struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var path: String
    var isTerminal: Bool
    var color: TabColor?
    /// Set for an SSH bookmark.
    var ssh: SSHTarget?

    var url: URL { URL(fileURLWithPath: path) }
}

final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()
    private static let key = "bookmarks"

    @Published private(set) var bookmarks: [Bookmark]

    private init() {
        bookmarks = (UserDefaults.standard.data(forKey: Self.key))
            .flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []
    }

    /// The bookmark matching a tab: same file, or a terminal in the same folder.
    func bookmark(for tab: EditorTab) -> Bookmark? {
        guard let target = Self.target(of: tab) else { return nil }
        return bookmarks.first { $0.path == target.path && $0.isTerminal == target.isTerminal }
    }

    func toggle(_ tab: EditorTab) {
        if let existing = bookmark(for: tab) {
            remove(existing)
        } else if let target = Self.target(of: tab) {
            bookmarks.append(Bookmark(title: tab.title, path: target.path, isTerminal: target.isTerminal, color: tab.color,
                                      ssh: tab.sshTarget))
            save()
        }
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    /// Files and terminals can be bookmarked; Source Control and unsaved tabs can't.
    static func target(of tab: EditorTab) -> (path: String, isTerminal: Bool)? {
        if let ssh = tab.sshTarget { return (ssh.key, true) }
        if tab.isTerminal, let folder = tab.terminalDirectory { return (folder.path, true) }
        if tab.isFileTab, let url = tab.url { return (url.path, false) }
        return nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bookmarks) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// The Bookmarks menu, rebuilt each time it opens.
final class BookmarksMenu: NSObject, NSMenuDelegate {
    static let shared = BookmarksMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Keep the fixed "Bookmark This Tab" item and separator at the top.
        while menu.items.count > 2 { menu.removeItem(at: 2) }
        let bookmarks = BookmarkStore.shared.bookmarks
        if bookmarks.isEmpty {
            let empty = NSMenuItem(title: "No Bookmarks", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for bookmark in bookmarks {
            let item = NSMenuItem(title: bookmark.title, action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bookmark
            item.toolTip = bookmark.path
            item.image = NSImage(systemSymbolName: bookmark.ssh != nil ? "network" : bookmark.isTerminal ? "terminal" : "doc.text",
                                 accessibilityDescription: nil)
            menu.addItem(item)
        }
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let bookmark = sender.representedObject as? Bookmark else { return }
        WorkspaceWindowController.open(bookmark)
    }
}

/// Asks for a tab's new name. Empty goes back to the automatic name.
func promptForTabName(_ current: String) -> String? {
    let alert = NSAlert()
    alert.messageText = "Rename Tab"
    alert.informativeText = "Leave it empty to use the automatic name."
    let field = NSTextField(string: current)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue.trimmingCharacters(in: .whitespaces)
}

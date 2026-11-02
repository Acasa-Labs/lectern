import AppKit

/// Opens folders in the terminal app you already use: iTerm if it's installed, else macOS's Terminal,
/// unless you've picked one under View → Terminal App.
enum ExternalTerminal {
    struct App {
        let name: String
        let bundleID: String
        let url: URL
    }

    /// Terminal apps known to open a new window at a folder they're given. First installed one wins by default.
    private static let known: [(name: String, bundleID: String)] = [
        ("iTerm", "com.googlecode.iterm2"),
        ("Terminal", "com.apple.Terminal"),
    ]

    private static let choiceKey = "terminalApp"

    static var installed: [App] {
        known.compactMap { app in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID).map {
                App(name: app.name, bundleID: app.bundleID, url: $0)
            }
        }
    }

    static var preferred: App? {
        let apps = installed
        let chosen = UserDefaults.standard.string(forKey: choiceKey)
        return apps.first { $0.bundleID == chosen } ?? apps.first
    }

    static func choose(_ bundleID: String) {
        UserDefaults.standard.set(bundleID, forKey: choiceKey)
    }

    static func open(_ folder: URL) {
        guard let app = preferred else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: app.url, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async { NSAlert(error: error).runModal() }
        }
    }
}

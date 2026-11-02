import AppKit
import SwiftTerm
import SwiftUI

/// One Terminal tab: your own login shell (zsh, .zshrc, PATH, prompt) in a pseudo-terminal,
/// drawn by SwiftTerm and started in the folder.
final class TerminalController: NSObject, LocalProcessTerminalViewDelegate {
    let view: LocalProcessTerminalView
    /// The shell's own title (often the command or folder), shown on the tab.
    var onTitleChange: (String) -> Void = { _ in }
    /// The shell exited, e.g. after `exit`; the tab closes.
    var onExit: () -> Void = {}
    private var fontSize: CGFloat = 0

    /// With `ssh`, the shell runs ssh to that server instead of an interactive prompt.
    init(directory: URL?, ssh: SSHTarget? = nil) {
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        view.processDelegate = self
        view.nativeBackgroundColor = EditorTheme.background
        view.nativeForegroundColor = EditorTheme.text
        view.caretColor = .controlAccentColor
        setFontSize(13)

        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        // Apps launched from Finder get a bare environment; a login shell rebuilds PATH and the rest.
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Lectern"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        let directory = directory?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        // Through your login shell, so ssh sees your PATH (ProxyCommand tools) and agent.
        // After it disconnects the reason stays on screen until you press Return.
        var args: [String] = []
        if let command = ssh?.commandLine {
            args = ["-c", command + #"; rc=$?; printf '\n[Connection closed (exit %d). Press Return to close this tab.]' "$rc"; read -r _"#]
        }
        // A leading "-" in argv[0] makes it a login shell, as Terminal and iTerm start it.
        view.startProcess(executable: shell, args: args, environment: environment.map { "\($0.key)=\($0.value)" },
                          execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: directory)
    }

    func setFontSize(_ size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Ends the shell when its tab closes.
    func terminate() {
        view.terminate()
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { self.onTitleChange(title) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { self.onExit() }
    }
}

struct TerminalTabView: NSViewRepresentable {
    let tab: EditorTab
    let fontSize: Double

    func makeNSView(context: Context) -> HostedViewContainer {
        let terminal = tab.terminal
        DispatchQueue.main.async { terminal.view.window?.makeFirstResponder(terminal.view) }
        return HostedViewContainer(terminal.view)
    }

    func updateNSView(_ view: HostedViewContainer, context: Context) {
        tab.terminal.setFontSize(fontSize)
    }
}

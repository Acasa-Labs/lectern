import AppKit

/// Changes a repository by running your own `git`, so your config, hooks, signing and credentials apply.
/// Flowboard's reader (GitViewModel) still shows the state; it reloads when these commands touch the repo.
@MainActor
final class GitActions: ObservableObject {
    @Published private(set) var isRunning = false
    /// What's running, for the busy line ("Pushing…").
    @Published private(set) var activity = ""

    private let model: GitViewModel
    var afterChange: () -> Void = {}

    init(model: GitViewModel) {
        self.model = model
    }

    private var workTree: String? { model.snapshot?.workTree }

    // MARK: Files

    func stage(_ paths: [String]) { run("Staging…", ["add", "--"] + paths) }
    func unstage(_ paths: [String]) { run("Unstaging…", ["restore", "--staged", "--"] + paths) }

    /// Puts tracked files back to the last commit, after asking. Untracked files go to the Trash.
    func discard(_ changes: [GitFileChange]) {
        guard let workTree, !changes.isEmpty else { return }
        let untracked = changes.filter { $0.kind == .untracked }
        let tracked = changes.filter { $0.kind != .untracked }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = changes.count == 1
            ? "Discard changes to “\(changes[0].fileName)”?"
            : "Discard changes to \(changes.count) files?"
        alert.informativeText = [
            tracked.isEmpty ? nil : "Tracked files go back to the last commit. Those edits can't be recovered.",
            untracked.isEmpty ? nil : "New, untracked files are moved to the Trash.",
        ].compactMap { $0 }.joined(separator: " ")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if !untracked.isEmpty {
            let urls = untracked.map { URL(fileURLWithPath: workTree).appendingPathComponent($0.path) }
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error { Task { @MainActor in Self.show("Couldn't move files to the Trash", error.localizedDescription) } }
                Task { @MainActor in self.finished() }
            }
        }
        if !tracked.isEmpty {
            // Staged and unstaged edits both go; renamed files restore their old path too.
            let paths = tracked.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }
            run("Discarding…", ["restore", "--staged", "--worktree", "--source=HEAD", "--"] + paths)
        }
    }

    // MARK: Commit and sync

    /// Commits what's staged, or every tracked change when nothing is staged (`all`).
    func commit(message: String, all: Bool, amend: Bool, thenPush: Bool, done: @escaping () -> Void) {
        var args = ["commit", "-m", message]
        if all { args.insert("-a", at: 1) }
        if amend { args.append("--amend") }
        run(amend ? "Amending…" : "Committing…", args) { [weak self] in
            done()
            if thenPush { self?.push() }
        }
    }

    func fetch() { run("Fetching…", ["fetch", "--all", "--prune"]) }
    func pull() { run("Pulling…", ["pull"]) }

    /// Pushes; a branch without an upstream is published to origin and starts tracking it.
    func push() {
        if model.snapshot?.headBranch?.upstream == nil {
            run("Publishing…", ["push", "--set-upstream", "origin", "HEAD"])
        } else {
            run("Pushing…", ["push"])
        }
    }

    // MARK: Branches and stashes

    func switchTo(_ branch: String) { run("Switching…", ["switch", branch]) }

    func createBranch() {
        let alert = NSAlert()
        alert.messageText = "New Branch"
        alert.informativeText = "Creates the branch from the current commit and switches to it. Your changes come along."
        let field = NSTextField(string: "")
        field.placeholderString = "feature/name"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.hasPrefix("-") else { return }
        run("Creating branch…", ["switch", "-c", name])
    }

    func stash() { run("Stashing…", ["stash", "push", "--include-untracked"]) }
    func popStash() { run("Applying stash…", ["stash", "pop"]) }

    // MARK: Running git

    /// Runs one git command in the work tree, shows any error, then lets the views refresh.
    private func run(_ activity: String, _ args: [String], then: (() -> Void)? = nil) {
        guard let workTree, !isRunning else { return }
        isRunning = true
        self.activity = activity
        Task {
            let result = await Self.git(args, in: workTree)
            isRunning = false
            self.activity = ""
            if result.status != 0 {
                let output = [result.error, result.output].first { !$0.isEmpty } ?? "git exited with code \(result.status)."
                Self.show("git \(args.first ?? "") failed", output)
            } else {
                then?()
            }
            finished()
        }
    }

    private func finished() {
        afterChange()
        Task { await model.reload() }
    }

    private static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        alert.runModal()
    }

    /// `git` with your login shell's PATH (credential helpers like gh, signing tools) and no prompts:
    /// a command that needs a password fails with a message instead of hanging.
    nonisolated static func git(_ args: [String], in directory: String) async -> (status: Int32, output: String, error: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = loginPath
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_EDITOR"] = "true"
            process.environment = environment
            let output = Pipe(), error = Pipe()
            process.standardOutput = output
            process.standardError = error
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return (-1, "", error.localizedDescription) }
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
        }.value
    }

    /// PATH as your login shell sets it, read once. Apps started from Finder only get a minimal PATH.
    nonisolated private static let loginPath: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "/usr/bin:/bin:/usr/sbin:/sbin" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" : path
    }()
}

import AppKit
import SwiftUI

/// The sidebar's Source Control tab: branch, sync, a commit box and the changed files, like VS Code's
/// and Xcode's. Reading uses Flowboard's git reader; changes run your own `git`.
struct SourceControlNavigator: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if let git = workspace.git, git.isRepository, let actions = workspace.gitActions {
            SourceControlPanel(workspace: workspace, git: git, actions: actions)
        } else {
            ContentUnavailableView("No Repository", systemImage: "arrow.triangle.branch",
                                   description: Text(workspace.root == nil ? "Open a folder to see its changes."
                                                                          : "This folder isn't in a git repository."))
                .frame(maxHeight: .infinity)
        }
    }
}

private struct SourceControlPanel: View {
    @ObservedObject var workspace: Workspace
    let git: GitViewModel
    @ObservedObject var actions: GitActions
    @State private var message = ""
    @State private var amend = false
    /// Sections you've folded away.
    @State private var collapsed: Set<String> = []

    private var status: GitStatus? { git.status }
    private var branch: GitBranch? { git.snapshot?.headBranch }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            commitBox
            Divider()
            if let status, !status.isClean {
                changes(status)
            } else {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                       description: Text("The working tree matches the last commit."))
                    .frame(maxHeight: .infinity)
            }
            Divider()
            // The full viewer (history graph, branches, diffs) from Flowboard, as a tab.
            Button(action: workspace.showSourceControl) {
                Label("Open Source Control", systemImage: "arrow.up.forward.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 7)
            .help("History, branches and diffs in a tab (⌥⌘G)")
            if actions.isRunning {
                Divider()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(actions.activity).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
        }
        .disabled(actions.isRunning)
    }

    // MARK: Branch and sync

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                let others = (git.snapshot?.branches ?? []).filter { !$0.isHead }
                if !others.isEmpty {
                    Section("Switch To") {
                        ForEach(others) { branch in
                            Button(branch.name) { actions.switchTo(branch.name) }
                        }
                    }
                }
                Button("New Branch…") { actions.createBranch() }
                Button("Open Source Control") { workspace.showSourceControl() }
                Divider()
                Button("Stash Changes") { actions.stash() }
                    .disabled(status?.isClean ?? true)
                Button("Pop Latest Stash") { actions.popStash() }
                    .disabled(git.snapshot?.stashes.isEmpty ?? true)
            } label: {
                HStack(spacing: 5) {
                    Text(git.snapshot?.name ?? "Repository").fontWeight(.semibold)
                    Text(git.branchName ?? "detached").foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Switch or create a branch, or stash changes")
            Spacer(minLength: 4)
            if let branch, branch.upstream != nil, branch.ahead + branch.behind > 0 {
                Text(verbatim: "↓\(branch.behind) ↑\(branch.ahead)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("\(branch.behind) to pull, \(branch.ahead) to push (\(branch.upstream ?? ""))")
            }
            Group {
                Button(action: actions.fetch) { Image(systemName: "arrow.triangle.2.circlepath") }
                    .help("Fetch from all remotes")
                Button(action: actions.pull) { Image(systemName: "arrow.down") }
                    .help("Pull")
                    .disabled(branch?.upstream == nil)
                Button(action: actions.push) { Image(systemName: "arrow.up") }
                    .help(branch?.upstream == nil ? "Publish this branch to origin" : "Push")
                Button(action: workspace.showSourceControl) { Image(systemName: "clock.arrow.circlepath") }
                    .help("History (⌥⌘G)")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Commit

    private var hasStaged: Bool { !(status?.staged.isEmpty ?? true) }
    private var hasTrackedChanges: Bool { !(status?.unstaged.isEmpty ?? true) }
    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCommit: Bool { !trimmedMessage.isEmpty && (hasStaged || hasTrackedChanges || amend) }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Commit message", text: $message, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Toggle("Amend", isOn: $amend)
                    .toggleStyle(.checkbox)
                    .help("Replace the last commit instead of adding one")
                Spacer()
                Menu {
                    Button("\(commitTitle) & Push") { commit(push: true) }
                } label: {
                    Text(commitTitle)
                } primaryAction: {
                    commit(push: false)
                }
                .fixedSize()
                .disabled(!canCommit)
                .keyboardShortcut(.return, modifiers: .command)
                .help(hasStaged || amend ? "Commit the staged changes (⌘↩)"
                                         : "Nothing is staged: commit every tracked change (⌘↩)")
            }
            .controlSize(.small)
        }
        .padding(10)
        .onChange(of: amend) { _, isOn in
            // Amending starts from the last commit's message.
            if isOn, trimmedMessage.isEmpty, let last = git.snapshot?.headCommit?.message {
                message = last.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private var commitTitle: String { amend ? "Amend" : hasStaged ? "Commit" : "Commit All" }

    private func commit(push: Bool) {
        guard canCommit else { return }
        actions.commit(message: trimmedMessage, all: !hasStaged && !amend, amend: amend, thenPush: push) {
            message = ""
            amend = false
        }
    }

    // MARK: Changes

    private func changes(_ status: GitStatus) -> some View {
        List {
            section("Conflicts", "exclamationmark.triangle", status.conflicted, staged: false)
            section("Staged", "tray.full", status.staged, staged: true)
            section("Uncommitted Changes", "plus.forwardslash.minus", status.unstaged, staged: false)
            section("Untracked", "questionmark.folder", status.untracked, staged: false)
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .small)
    }

    @ViewBuilder
    /// A group of files, like Xcode's "Uncommitted Changes": a plain row (not a List section header,
    /// which macOS squeezes on hover) whose columns match the file rows below it.
    private func section(_ title: String, _ icon: String, _ changes: [GitFileChange], staged: Bool) -> some View {
        if !changes.isEmpty {
            let isOpen = !collapsed.contains(title)
            HStack(spacing: 4) {
                Button {
                    if isOpen { collapsed.insert(title) } else { collapsed.remove(title) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 10)
                        Image(systemName: icon)
                            .foregroundStyle(Color.accentColor)
                        Text(title)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Hide these files" : "Show these files")
                Spacer()
                // Same columns as a file row: (discard), stage / unstage, then the count where the badges are.
                Color.clear.frame(width: Self.actionWidth)
                Group {
                    if staged {
                        Button { actions.unstage(changes.map(\.path)) } label: { Image(systemName: "minus") }
                            .help("Unstage All")
                    } else {
                        Button { actions.stage(changes.map(\.path)) } label: { Image(systemName: "plus") }
                            .help(title == "Conflicts" ? "Mark All Resolved" : "Stage All")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(width: Self.actionWidth)
                Text(verbatim: "\(changes.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: Self.letterWidth)
            }
            .lineLimit(1)
            if isOpen {
                ForEach(changes) { change in row(change, staged: staged) }
            }
        }
    }

    private func row(_ change: GitFileChange, staged: Bool) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 16)  // indent under the group's arrow, as in Xcode
            Label {
                Text(change.fileName)
            } icon: {
                FileIcon(url: URL(fileURLWithPath: change.path))
            }
            // The folder is in the tooltip, as in Xcode, leaving the narrow sidebar to the file name.
            Spacer(minLength: 4)
            // Always shown, at fixed widths, so nothing shifts as the pointer moves.
            Group {
                Button { actions.discard([change]) } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Discard changes")
                if staged {
                    Button { actions.unstage([change.path]) } label: { Image(systemName: "minus") }
                        .help("Unstage")
                } else {
                    Button { actions.stage([change.path]) } label: { Image(systemName: "plus") }
                        .help(change.kind == .conflicted ? "Mark resolved" : "Stage")
                }
            }
            .buttonStyle(.borderless)
            .frame(width: Self.actionWidth)
            .foregroundStyle(.secondary)
            // Boxed status letter, like Xcode's.
            Text(change.kind.letter)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Self.color(for: change.kind))
                .frame(width: Self.letterWidth, height: Self.letterWidth)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Self.color(for: change.kind), lineWidth: 1))
        }
        .lineLimit(1)
        .contentShape(Rectangle())
        .onTapGesture { open(change) }
        .help(change.path)
        .contextMenu {
            Button("Open File") { open(change) }
                .disabled(change.kind == .deleted)
            Button("Show Changes") { workspace.showSourceControl() }
            Divider()
            if staged {
                Button("Unstage") { actions.unstage([change.path]) }
            } else {
                Button(change.kind == .conflicted ? "Mark Resolved" : "Stage") { actions.stage([change.path]) }
            }
            Button("Discard Changes…") { actions.discard([change]) }
            Divider()
            Button("Reveal in Finder") { if let url = url(of: change) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                .disabled(change.kind == .deleted)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url(of: change)?.path ?? change.path, forType: .string)
            }
        }
    }

    private func url(of change: GitFileChange) -> URL? {
        git.snapshot?.workTree.map { URL(fileURLWithPath: $0).appendingPathComponent(change.path) }
    }

    /// Opens the file; a deleted one has nothing to open, so its diff shows instead.
    private func open(_ change: GitFileChange) {
        guard change.kind != .deleted, let url = url(of: change) else {
            workspace.showSourceControl()
            return
        }
        workspace.open(url)
    }

    /// Shared by rows and section headers so their buttons line up.
    private static let actionWidth: CGFloat = 16
    private static let letterWidth: CGFloat = 15

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

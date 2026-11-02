import AppKit
import CoreServices
import Foundation

/// Calls back (on the main queue) when anything in a folder changes, a second after it settles.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(path: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            // New objects alone don't change what's shown; refs, the index or files do.
            if list.prefix(count).contains(where: { !$0.contains("/.git/objects/") }) { watcher.onChange() }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// Loads a repository for the git viewer and keeps it current as files change.
@MainActor
@Observable
final class GitViewModel {
    enum Phase: Equatable {
        case loading
        case failed(String)
        case ready
    }

    static let commitLimit = 4_000

    let path: String
    private(set) var phase: Phase = .loading
    private(set) var snapshot: GitSnapshot?
    private(set) var status: GitStatus?
    private(set) var isRefreshing = false
    private(set) var lastLoaded: Date?

    /// Each changed file's status by absolute path, for the letters in Lectern's file tree.
    private(set) var fileStatus: [String: GitFileChange.Kind] = [:]

    @ObservationIgnored private var repository: GitRepository?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var reloadAgain = false

    init(path: String) {
        self.path = path
    }

    /// Lectern isn't sandboxed, so it reads the folder directly.
    func start() async {
        phase = .loading
        await open()
    }

    func stop() {
        watcher = nil
    }

    var isRepository: Bool { phase == .ready }
    var branchName: String? { snapshot?.head.branchName }

    private func open() async {
        do {
            let path = path
            let repository = try await Task.detached { try GitRepository(path: path) }.value
            self.repository = repository
            await reload()
            let watched = repository.workTree?.path ?? path
            watcher = FolderWatcher(path: watched) { [weak self] in
                Task { await self?.reload() }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func reload() async {
        guard let repository else { return }
        guard !isRefreshing else {
            reloadAgain = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            reloadAgain = false
            do {
                snapshot = try await repository.snapshot(commitLimit: Self.commitLimit)
                status = await repository.status()
                fileStatus = Self.fileStatus(status, workTree: snapshot?.workTree)
                lastLoaded = .now
                phase = .ready
            } catch {
                if snapshot == nil { phase = .failed(error.localizedDescription) }
            }
        } while reloadAgain
    }

    /// Conflicts win over unstaged edits, which win over staged ones, then untracked files.
    private static func fileStatus(_ status: GitStatus?, workTree: String?) -> [String: GitFileChange.Kind] {
        guard let status, let workTree else { return [:] }
        var result: [String: GitFileChange.Kind] = [:]
        for group in [status.untracked, status.staged, status.unstaged, status.conflicted] {
            for change in group {
                result[URL(fileURLWithPath: workTree).appendingPathComponent(change.path).standardizedFileURL.path] = change.kind
            }
        }
        return result
    }

    func commit(_ oid: GitOID) async -> GitCommit? {
        if let loaded = snapshot?.commits.first(where: { $0.id == oid }) { return loaded }
        return try? await repository?.commit(oid)
    }

    func changes(of commit: GitCommit) async -> [GitFileChange] {
        (try? await repository?.changes(of: commit)) ?? []
    }

    func diff(_ change: GitFileChange) async -> GitFileDiff {
        await repository?.diff(change) ?? .unreadable("The repository isn’t open.")
    }
}

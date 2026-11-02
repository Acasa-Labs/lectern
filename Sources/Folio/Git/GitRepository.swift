import Compression
import CryptoKit
import Foundation

/// Reads a git repository straight from its `.git` folder: refs, packfiles, the index and
/// the work tree. Read-only by design. The app is sandboxed, so it can't run `git` itself.
actor GitRepository {
    enum Failure: LocalizedError {
        case notRepository(String)
        case missingObject(GitOID)
        case corrupt(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .notRepository(let path): "\((path as NSString).abbreviatingWithTildeInPath) isn’t a git repository."
            case .missingObject(let oid): "Object \(oid.short) is missing."
            case .corrupt(let what): "The repository looks damaged (\(what))."
            case .unsupported(let what): "\(what) isn’t supported yet."
            }
        }
    }

    let workTree: URL?
    let gitDir: URL
    let commonDir: URL

    private var packs: [GitPack] = []
    private var packNames: Set<String> = []
    private var commitCache: [GitOID: GitCommit] = [:]
    private var objectCache: [ObjectKey: GitRawObject] = [:]
    private var objectCacheBytes = 0

    init(path: String) throws {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var found: (work: URL?, git: URL)?
        // Walk up, so a subfolder of a repository works too.
        while true {
            let dotGit = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    found = (url, dotGit)
                } else if let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    // A linked worktree or submodule: `.git` is a file pointing at the real folder.
                    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    found = (url, URL(fileURLWithPath: target, relativeTo: url).standardizedFileURL)
                }
            } else if fm.fileExists(atPath: url.appendingPathComponent("HEAD").path),
                      fm.fileExists(atPath: url.appendingPathComponent("objects").path),
                      fm.fileExists(atPath: url.appendingPathComponent("refs").path) {
                found = (nil, url)   // bare repository
            }
            if found != nil || url.path == "/" { break }
            url.deleteLastPathComponent()
        }
        guard let found else { throw Failure.notRepository(path) }
        workTree = found.work
        gitDir = found.git
        if let common = try? String(contentsOf: found.git.appendingPathComponent("commondir"), encoding: .utf8) {
            commonDir = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: found.git)
                .standardizedFileURL
        } else {
            commonDir = found.git
        }
        guard fm.fileExists(atPath: gitDir.appendingPathComponent("HEAD").path) else {
            throw Failure.notRepository(path)
        }
    }

    // MARK: - Snapshot

    func snapshot(commitLimit: Int) throws -> GitSnapshot {
        loadPacks()
        let config = GitConfig(url: commonDir.appendingPathComponent("config"))
        let format = config.value("extensions", key: "objectformat") ?? "sha1"
        if format.lowercased() != "sha1" { throw Failure.unsupported("SHA-256 repositories") }

        let refs = readRefs()
        let head = readHead(refs: refs)
        var snapshot = GitSnapshot(
            name: (workTree ?? commonDir).lastPathComponent,
            workTree: workTree?.path,
            gitDir: gitDir.path,
            head: head
        )
        snapshot.isBare = workTree == nil || config.value("core", key: "bare") == "true"
        snapshot.userName = config.value("user", key: "name")
        snapshot.userEmail = config.value("user", key: "email")
        snapshot.objectFormat = format
        snapshot.packCount = packs.count
        snapshot.operation = readOperation()

        // Branches with their upstreams.
        var branches: [GitBranch] = []
        for (ref, oid) in refs.direct where ref.hasPrefix("refs/heads/") {
            let name = String(ref.dropFirst("refs/heads/".count))
            var branch = GitBranch(name: name, refName: ref, tip: oid)
            branch.isHead = head.branchName == name
            if let tip = try? self.commit(oid) {
                branch.tipDate = tip.committer.date
                branch.tipSubject = tip.subject
            }
            if let remote = config.value("branch", name, key: "remote"),
               let merge = config.value("branch", name, key: "merge") {
                let upstreamName = merge.hasPrefix("refs/heads/") ? String(merge.dropFirst("refs/heads/".count)) : merge
                if remote == "." {
                    branch.upstream = upstreamName
                    if let up = refs.direct["refs/heads/\(upstreamName)"] {
                        (branch.ahead, branch.behind) = aheadBehind(oid, up)
                    }
                } else {
                    branch.upstream = "\(remote)/\(upstreamName)"
                    if let up = refs.direct["refs/remotes/\(remote)/\(upstreamName)"] {
                        (branch.ahead, branch.behind) = aheadBehind(oid, up)
                    } else {
                        branch.upstreamGone = true
                    }
                }
            }
            branches.append(branch)
        }
        snapshot.branches = branches.sorted { ($0.isHead ? 0 : 1, $0.name.lowercased()) < ($1.isHead ? 0 : 1, $1.name.lowercased()) }

        // Remotes: from config, plus any with refs but no config.
        var remoteNames = config.subsections("remote")
        for ref in refs.direct.keys where ref.hasPrefix("refs/remotes/") {
            let name = ref.dropFirst("refs/remotes/".count).split(separator: "/").first.map(String.init) ?? ""
            if !name.isEmpty, !remoteNames.contains(name) { remoteNames.append(name) }
        }
        snapshot.remotes = remoteNames.map { name in
            var remote = GitRemote(name: name)
            remote.fetchURL = config.value("remote", name, key: "url") ?? ""
            remote.pushURL = config.value("remote", name, key: "pushurl") ?? remote.fetchURL
            remote.fetchSpecs = config.values("remote", name, key: "fetch")
            let prefix = "refs/remotes/\(name)/"
            if let target = refs.symbolic[prefix + "HEAD"], target.hasPrefix(prefix) {
                remote.defaultBranch = String(target.dropFirst(prefix.count))
            }
            remote.branches = refs.direct.compactMap { ref, oid -> GitRemoteBranch? in
                guard ref.hasPrefix(prefix), ref != prefix + "HEAD" else { return nil }
                return GitRemoteBranch(name: String(ref.dropFirst(prefix.count)), refName: ref, tip: oid,
                                       tipDate: (try? self.commit(oid))?.committer.date)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            return remote
        }

        // Tags, peeled to the commit they name.
        var tags: [GitTag] = []
        for (ref, oid) in refs.direct where ref.hasPrefix("refs/tags/") {
            let name = String(ref.dropFirst("refs/tags/".count))
            var target = oid
            var tag = GitTag(name: name, target: oid)
            var hops = 0
            while hops < 8, let object = try? self.object(target), object.kind == .tag {
                let parsed = GitParse.tag(object.data)
                if hops == 0 {
                    tag.isAnnotated = true
                    tag.tagger = parsed.tagger
                    tag.message = parsed.message
                    tag.date = parsed.tagger?.date
                }
                guard let next = parsed.object else { break }
                target = next
                hops += 1
            }
            tag = GitTag(name: name, target: target, isAnnotated: tag.isAnnotated, tagger: tag.tagger,
                         message: tag.message, date: tag.date ?? (try? self.commit(target))?.committer.date)
            tags.append(tag)
        }
        snapshot.tags = tags.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        snapshot.stashes = readLog(commonDir.appendingPathComponent("logs/refs/stash"))
            .reversed()
            .enumerated()
            .compactMap { index, entry in
                guard let oid = entry.new else { return nil }
                return GitStash(index: index, oid: oid, message: entry.message, date: entry.who.date)
            }
        snapshot.reflog = Array(readLog(gitDir.appendingPathComponent("logs/HEAD")).reversed().prefix(300))
            .enumerated().map { index, entry in
                GitReflogEntry(id: index, old: entry.old, new: entry.new, who: entry.who, message: entry.message)
            }
        snapshot.worktrees = readWorktrees(head: head)
        snapshot.submodules = readSubmodules(head: head)

        // History across every branch, remote branch and tag.
        var tips: [GitOID] = []
        if let oid = head.oid { tips.append(oid) }
        tips += snapshot.branches.map(\.tip)
        tips += snapshot.remotes.flatMap { $0.branches.map(\.tip) }
        tips += snapshot.tags.map(\.target)
        let walk = walk(from: tips, limit: commitLimit)
        snapshot.commits = walk.commits
        snapshot.isTruncated = walk.truncated

        var badges: [GitOID: [GitRefBadge]] = [:]
        if case .detached(let oid) = head { badges[oid, default: []].append(.init(kind: .head, name: "HEAD", isHead: true)) }
        for branch in snapshot.branches {
            badges[branch.tip, default: []].append(.init(kind: .branch, name: branch.name, isHead: branch.isHead))
        }
        for remote in snapshot.remotes {
            for branch in remote.branches {
                badges[branch.tip, default: []].append(.init(kind: .remote, name: "\(remote.name)/\(branch.name)"))
            }
        }
        for tag in snapshot.tags { badges[tag.target, default: []].append(.init(kind: .tag, name: tag.name)) }
        snapshot.badges = badges.mapValues { list in
            list.sorted { ($0.isHead ? 0 : 1, $0.kind.rawValue, $0.name) < ($1.isHead ? 0 : 1, $1.kind.rawValue, $1.name) }
        }
        return snapshot
    }

    // MARK: - Commits

    func commit(_ oid: GitOID) throws -> GitCommit {
        if let cached = commitCache[oid] { return cached }
        let object = try object(oid)
        guard object.kind == .commit, let commit = GitParse.commit(oid, object.data) else {
            throw Failure.corrupt("commit \(oid.short)")
        }
        commitCache[oid] = commit
        return commit
    }

    /// Every branch, remote branch and tag's history, newest first, without the rest of a snapshot.
    func history(limit: Int) -> (commits: [GitCommit], truncated: Bool) {
        loadPacks()
        let refs = readRefs()
        var tips = Array(refs.direct.values)
        if let head = readHead(refs: refs).oid { tips.insert(head, at: 0) }
        return walk(from: tips, limit: limit)
    }

    /// Files changed and lines added and removed by a commit, against its first parent.
    func lineStats(of commit: GitCommit) -> (files: Int, additions: Int, deletions: Int) {
        guard let changes = try? changes(of: commit) else { return (0, 0, 0) }
        var additions = 0, deletions = 0
        // Huge commits (vendored code, generated files) are counted by file only.
        for change in changes.prefix(200) {
            let diff = diff(change)
            additions += diff.additions
            deletions += diff.deletions
        }
        return (changes.count, additions, deletions)
    }

    /// Newest first by commit date, following every parent.
    private func walk(from tips: [GitOID], limit: Int) -> (commits: [GitCommit], truncated: Bool) {
        var seen = Set<GitOID>()
        var queue: [GitCommit] = []   // ascending by date; the newest is last
        func enqueue(_ commit: GitCommit) {
            let date = commit.committer.date
            var low = 0, high = queue.count
            while low < high {
                let mid = (low + high) / 2
                if queue[mid].committer.date <= date { low = mid + 1 } else { high = mid }
            }
            queue.insert(commit, at: low)
        }
        for tip in tips where seen.insert(tip).inserted {
            if let commit = try? self.commit(tip) { enqueue(commit) }
        }
        var out: [GitCommit] = []
        while out.count < limit, let next = queue.popLast() {
            out.append(next)
            for parent in next.parents where seen.insert(parent).inserted {
                if let commit = try? self.commit(parent) { enqueue(commit) }
            }
        }
        return (out, !queue.isEmpty)
    }

    /// Commits only on `a`, and only on `b`, like `git rev-list --left-right --count a...b`.
    private func aheadBehind(_ a: GitOID, _ b: GitOID) -> (Int, Int) {
        guard a != b else { return (0, 0) }
        var flags: [GitOID: UInt8] = [a: 1]
        flags[b, default: 0] |= 2
        var queue: [GitCommit] = []
        func enqueue(_ oid: GitOID) {
            guard let commit = try? self.commit(oid) else { return }
            let index = queue.firstIndex { $0.committer.date > commit.committer.date } ?? queue.endIndex
            queue.insert(commit, at: index)
        }
        enqueue(a)
        enqueue(b)
        var steps = 0
        while steps < 20_000, let next = queue.popLast() {
            steps += 1
            let flag = flags[next.id] ?? 0
            for parent in next.parents {
                let old = flags[parent] ?? 0
                if old | flag != old {
                    flags[parent] = old | flag
                    enqueue(parent)
                }
            }
            if queue.allSatisfy({ flags[$0.id] == 3 }) { break }
        }
        return (flags.values.filter { $0 == 1 }.count, flags.values.filter { $0 == 2 }.count)
    }

    // MARK: - Changes

    /// Files a commit changed, compared with its first parent.
    func changes(of commit: GitCommit) throws -> [GitFileChange] {
        let parentTree = try commit.parents.first.map { try self.commit($0).tree }
        var changes: [GitFileChange] = []
        try diffTrees(old: parentTree, new: commit.tree, prefix: "", into: &changes)
        return Self.pairRenames(changes).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Trees nested deeper than this are treated as damage (a crafted tree could nest without end).
    private static let maxTreeDepth = 256

    private func diffTrees(old: GitOID?, new: GitOID?, prefix: String, into changes: inout [GitFileChange]) throws {
        guard prefix.utf8.lazy.filter({ $0 == UInt8(ascii: "/") }).count < Self.maxTreeDepth else { throw Failure.corrupt("tree nesting") }
        let oldEntries = try old.map { try tree($0) } ?? []
        let newEntries = try new.map { try tree($0) } ?? []
        let oldByName = Dictionary(oldEntries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let newByName = Dictionary(newEntries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for name in Set(oldByName.keys).union(newByName.keys) {
            let path = prefix + name
            switch (oldByName[name], newByName[name]) {
            case let (a?, b?):
                guard a.oid != b.oid || a.mode != b.mode else { continue }
                if a.isTree, b.isTree {
                    try diffTrees(old: a.oid, new: b.oid, prefix: path + "/", into: &changes)
                } else if a.isTree {
                    try diffTrees(old: a.oid, new: nil, prefix: path + "/", into: &changes)
                    changes.append(.init(path: path, kind: .added, new: .object(b.oid), newMode: b.mode))
                } else if b.isTree {
                    changes.append(.init(path: path, kind: .deleted, old: .object(a.oid), oldMode: a.mode))
                    try diffTrees(old: nil, new: b.oid, prefix: path + "/", into: &changes)
                } else {
                    let kind: GitFileChange.Kind = (a.mode & 0o170000) == (b.mode & 0o170000) ? .modified : .typeChanged
                    changes.append(.init(path: path, kind: kind, old: .object(a.oid), new: .object(b.oid),
                                         oldMode: a.mode, newMode: b.mode))
                }
            case let (a?, nil):
                if a.isTree {
                    try diffTrees(old: a.oid, new: nil, prefix: path + "/", into: &changes)
                } else {
                    changes.append(.init(path: path, kind: .deleted, old: .object(a.oid), oldMode: a.mode))
                }
            case let (nil, b?):
                if b.isTree {
                    try diffTrees(old: nil, new: b.oid, prefix: path + "/", into: &changes)
                } else {
                    changes.append(.init(path: path, kind: .added, new: .object(b.oid), newMode: b.mode))
                }
            case (nil, nil):
                continue
            }
        }
    }

    /// Turns a delete and an add of the same content into a rename.
    private static func pairRenames(_ changes: [GitFileChange]) -> [GitFileChange] {
        var added: [GitOID: [Int]] = [:]
        for (index, change) in changes.enumerated() where change.kind == .added {
            if case .object(let oid) = change.new { added[oid, default: []].append(index) }
        }
        guard !added.isEmpty else { return changes }
        var drop = Set<Int>()
        var out: [GitFileChange] = []
        for (index, change) in changes.enumerated() where change.kind == .deleted {
            guard case .object(let oid) = change.old, var candidates = added[oid], let match = candidates.first else { continue }
            candidates.removeFirst()
            added[oid] = candidates
            drop.insert(index)
            drop.insert(match)
            let target = changes[match]
            out.append(.init(path: target.path, oldPath: change.path, kind: .renamed, old: change.old, new: target.new,
                             oldMode: change.oldMode, newMode: target.newMode))
        }
        return changes.enumerated().filter { !drop.contains($0.offset) }.map(\.element) + out
    }

    func diff(_ change: GitFileChange) -> GitFileDiff {
        if change.isSubmodule {
            func oid(_ side: GitFileChange.Side) -> GitOID? { if case .object(let o) = side { o } else { nil } }
            return .submodule(old: oid(change.old), new: oid(change.new))
        }
        do {
            let old = try content(change.old, path: change.oldPath ?? change.path)
            let new = try content(change.new, path: change.path)
            if old.count > Self.diffLimit || new.count > Self.diffLimit { return .tooLarge(size: max(old.count, new.count)) }
            if Self.isBinary(old) || Self.isBinary(new) { return .binary(oldSize: old.count, newSize: new.count) }
            return GitLineDiff.diff(old: String(decoding: old, as: UTF8.self), new: String(decoding: new, as: UTF8.self))
        } catch TooLarge.file(let size) {
            return .tooLarge(size: size)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Files bigger than this show as too large instead of as a diff.
    private static let diffLimit = 3 * 1024 * 1024

    private enum TooLarge: Error { case file(Int) }

    private func content(_ side: GitFileChange.Side, path: String) throws -> [UInt8] {
        switch side {
        case .none:
            return []
        case .object(let oid):
            return try object(oid).data
        case .workTree:
            guard let workTree else { return [] }
            let url = workTree.appendingPathComponent(path)
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                return Array(destination.utf8)
            }
            // Check the size first: a work-tree file can be any size.
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > Self.diffLimit { throw TooLarge.file(size) }
            return Array(try Data(contentsOf: url))
        }
    }

    private static func isBinary(_ bytes: [UInt8]) -> Bool {
        bytes.prefix(8000).contains(0)
    }

    // MARK: - Working tree status

    func status() -> GitStatus {
        guard let workTree else { return GitStatus() }
        let index = readIndex()
        let headFiles = files(at: readHeadOID())
        var status = GitStatus()

        let conflicted = Set(index.filter { $0.stage != 0 }.map(\.path))
        status.conflicted = conflicted.sorted().map { GitFileChange(path: $0, kind: .conflicted, new: .workTree) }

        var indexed: [String: IndexEntry] = [:]
        for entry in index where entry.stage == 0 { indexed[entry.path] = entry }

        // Staged: the index compared with HEAD.
        for (path, entry) in indexed where !entry.intentToAdd {
            if let head = headFiles[path] {
                guard head.oid != entry.oid || head.mode != entry.mode else { continue }
                let kind: GitFileChange.Kind = (head.mode & 0o170000) == (entry.mode & 0o170000) ? .modified : .typeChanged
                status.staged.append(.init(path: path, kind: kind, old: .object(head.oid), new: .object(entry.oid),
                                           oldMode: head.mode, newMode: entry.mode))
            } else {
                status.staged.append(.init(path: path, kind: .added, new: .object(entry.oid), newMode: entry.mode))
            }
        }
        for (path, head) in headFiles where indexed[path] == nil && !conflicted.contains(path) {
            status.staged.append(.init(path: path, kind: .deleted, old: .object(head.oid), oldMode: head.mode))
        }

        // Unstaged: the work tree compared with the index.
        for (path, entry) in indexed where !entry.skipWorktree && entry.mode != 0o160000 {
            let url = workTree.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                status.unstaged.append(.init(path: path, kind: .deleted, old: .object(entry.oid), oldMode: entry.mode))
                continue
            }
            let isLink = (info.st_mode & S_IFMT) == S_IFLNK
            let mode: UInt32 = isLink ? 0o120000 : (info.st_mode & 0o111 != 0 ? 0o100755 : 0o100644)
            let sameStat = UInt32(truncatingIfNeeded: info.st_size) == entry.size
                && UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec) == entry.mtime
                && UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec) == entry.mtimeNanos
            if sameStat, mode == entry.mode || entry.mode == 0o120000 { continue }
            if entry.assumeValid { continue }
            let changed: Bool
            if sameStat {
                changed = mode != entry.mode
            } else {
                let bytes: Data
                if isLink {
                    bytes = Data(((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "").utf8)
                } else if let data = try? Data(contentsOf: url, options: .alwaysMapped) {
                    // Mapped, so hashing a huge file doesn't read it all into memory.
                    bytes = data
                } else {
                    continue
                }
                changed = Self.blobOID(bytes) != entry.oid || mode != entry.mode
            }
            if changed {
                status.unstaged.append(.init(path: path, kind: .modified, old: .object(entry.oid), new: .workTree,
                                             oldMode: entry.mode, newMode: mode))
            }
        }

        // Untracked: files git doesn't know, minus ignored ones.
        var trackedDirs: Set<String> = []
        for path in indexed.keys {
            var dir = (path as NSString).deletingLastPathComponent
            while !dir.isEmpty, trackedDirs.insert(dir).inserted {
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        let untracked = untrackedFiles(in: workTree, tracked: Set(indexed.keys).union(conflicted), trackedDirs: trackedDirs)
        status.untracked = untracked.paths.map { GitFileChange(path: $0, kind: .untracked, new: .workTree) }
        status.untrackedTruncated = untracked.truncated

        let order: (GitFileChange, GitFileChange) -> Bool = { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        status.staged.sort(by: order)
        status.unstaged.sort(by: order)
        return status
    }

    private func untrackedFiles(in root: URL, tracked: Set<String>, trackedDirs: Set<String>) -> (paths: [String], truncated: Bool) {
        var ignore = GitIgnore()
        ignore.loadGlobalExcludes()
        ignore.load(commonDir.appendingPathComponent("info/exclude"), base: "")
        ignore.load(root.appendingPathComponent(".gitignore"), base: "")
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return ([], false) }
        var out: [String] = []
        var visited = 0
        while let rel = enumerator.nextObject() as? String {
            visited += 1
            if visited > 60_000 || out.count >= 2_000 { return (out, true) }
            let name = (rel as NSString).lastPathComponent
            let isDir = (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory
            if name == ".git" {
                if isDir { enumerator.skipDescendants() }
                continue
            }
            if isDir {
                if ignore.isIgnored(rel, isDirectory: true) {
                    enumerator.skipDescendants()
                } else if !trackedDirs.contains(rel) {
                    // Like git, show a folder with nothing tracked in it as one entry.
                    if Self.hasVisibleFile(root.appendingPathComponent(rel), relative: rel, ignore: ignore) {
                        out.append(rel + "/")
                    }
                    enumerator.skipDescendants()
                } else {
                    ignore.load(root.appendingPathComponent(rel).appendingPathComponent(".gitignore"), base: rel)
                }
            } else if !tracked.contains(rel), !ignore.isIgnored(rel, isDirectory: false) {
                out.append(rel)
            }
        }
        return (out, false)
    }

    /// Whether an untracked folder holds any file that isn't ignored, honoring its own `.gitignore`s
    /// (tools like pytest drop a `*` one into their cache folders).
    private static func hasVisibleFile(_ url: URL, relative: String, ignore: GitIgnore) -> Bool {
        var ignore = ignore
        ignore.load(url.appendingPathComponent(".gitignore"), base: relative)
        guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { return false }
        var checked = 0
        while let rel = enumerator.nextObject() as? String, checked < 2_000 {
            checked += 1
            let path = relative + "/" + rel
            let isDir = (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory
            if ignore.isIgnored(path, isDirectory: isDir) {
                if isDir { enumerator.skipDescendants() }
                continue
            }
            if isDir {
                ignore.load(url.appendingPathComponent(rel).appendingPathComponent(".gitignore"), base: path)
            } else {
                return true
            }
        }
        return checked >= 2_000
    }

    static func blobOID<D: DataProtocol>(_ bytes: D) -> GitOID {
        var hasher = Insecure.SHA1()
        hasher.update(data: Array("blob \(bytes.count)\0".utf8))
        hasher.update(data: bytes)
        return GitOID(bytes: hasher.finalize())
    }

    // MARK: - Trees

    private func tree(_ oid: GitOID) throws -> [GitTreeEntry] {
        let object = try object(oid)
        guard object.kind == .tree else { throw Failure.corrupt("tree \(oid.short)") }
        return GitParse.tree(object.data)
    }

    /// Every file in a commit, by path.
    private func files(at oid: GitOID?) -> [String: (oid: GitOID, mode: UInt32)] {
        guard let oid, let commit = try? self.commit(oid), let files = try? flatten(tree: commit.tree) else { return [:] }
        return files
    }

    private func flatten(tree oid: GitOID, prefix: String = "") throws -> [String: (oid: GitOID, mode: UInt32)] {
        guard prefix.utf8.lazy.filter({ $0 == UInt8(ascii: "/") }).count < Self.maxTreeDepth else { throw Failure.corrupt("tree nesting") }
        var out: [String: (oid: GitOID, mode: UInt32)] = [:]
        for entry in try tree(oid) {
            if entry.isTree {
                try out.merge(flatten(tree: entry.oid, prefix: prefix + entry.name + "/")) { a, _ in a }
            } else {
                out[prefix + entry.name] = (entry.oid, entry.mode)
            }
        }
        return out
    }

    // MARK: - Objects

    private struct ObjectKey: Hashable {
        let pack: Int
        let offset: Int
    }

    /// `depth` counts delta bases followed so far, across both kinds of delta, so a crafted chain
    /// (or two objects naming each other as base) stops instead of recursing for ever.
    func object(_ oid: GitOID, depth: Int = 0) throws -> GitRawObject {
        let hex = oid.hex
        let loose = commonDir.appendingPathComponent("objects")
            .appendingPathComponent(String(hex.prefix(2)))
            .appendingPathComponent(String(hex.dropFirst(2)))
        if let data = try? Data(contentsOf: loose) {
            guard let raw = Zlib.inflate(data), let nul = raw.firstIndex(of: 0) else { throw Failure.corrupt("object \(oid.short)") }
            let header = String(decoding: raw[..<nul], as: UTF8.self).split(separator: " ")
            guard let kind = header.first.flatMap({ GitObjectKind(name: String($0)) }) else {
                throw Failure.corrupt("object \(oid.short)")
            }
            return GitRawObject(kind: kind, data: Array(raw[(nul + 1)...]))
        }
        let bytes = oid.bytes
        for attempt in 0..<2 {
            for (index, pack) in packs.enumerated() {
                if let offset = pack.offset(of: bytes) { return try packObject(pack: index, offset: offset, depth: depth) }
            }
            // A `git gc` may have repacked since the last look.
            if attempt == 0 { loadPacks() }
        }
        throw Failure.missingObject(oid)
    }

    private func packObject(pack index: Int, offset: Int, depth: Int) throws -> GitRawObject {
        let key = ObjectKey(pack: index, offset: offset)
        if let cached = objectCache[key] { return cached }
        let pack = packs[index]
        guard depth < 64, let entry = pack.entry(at: offset) else { throw Failure.corrupt("pack entry") }
        let object: GitRawObject
        switch entry.type {
        case 1...4:
            guard let data = pack.inflate(entry), let kind = GitObjectKind(rawValue: entry.type) else {
                throw Failure.corrupt("pack entry")
            }
            object = GitRawObject(kind: kind, data: data)
        case 6, 7:
            let base: GitRawObject
            if let baseOffset = entry.baseOffset {
                base = try packObject(pack: index, offset: baseOffset, depth: depth + 1)
            } else if let baseOID = entry.baseOID {
                base = try self.object(baseOID, depth: depth + 1)
            } else {
                throw Failure.corrupt("delta base")
            }
            guard let delta = pack.inflate(entry), let data = GitPack.apply(delta: delta, to: base.data) else {
                throw Failure.corrupt("delta")
            }
            object = GitRawObject(kind: base.kind, data: data)
        default:
            throw Failure.corrupt("pack entry type \(entry.type)")
        }
        // Keep recent objects: delta chains reuse their bases a lot.
        if objectCacheBytes > 96 * 1024 * 1024 {
            objectCache.removeAll(keepingCapacity: true)
            objectCacheBytes = 0
        }
        objectCache[key] = object
        objectCacheBytes += object.data.count
        return object
    }

    private func loadPacks() {
        let dir = commonDir.appendingPathComponent("objects/pack")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".idx") }
        guard Set(names) != packNames else { return }
        packNames = Set(names)
        packs = names.sorted().compactMap { name in
            let base = dir.appendingPathComponent(String(name.dropLast(4)))
            return GitPack(pack: base.appendingPathExtension("pack"), index: base.appendingPathExtension("idx"))
        }
        objectCache.removeAll()
        objectCacheBytes = 0
    }

    // MARK: - Refs

    private struct Refs {
        var direct: [String: GitOID] = [:]
        var symbolic: [String: String] = [:]
    }

    private func readRefs() -> Refs {
        var refs = Refs()
        if let packed = try? String(contentsOf: commonDir.appendingPathComponent("packed-refs"), encoding: .utf8) {
            for line in packed.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("^") {
                let parts = line.split(separator: " ", maxSplits: 1)
                if parts.count == 2, let oid = GitOID(hex: String(parts[0])) { refs.direct[String(parts[1])] = oid }
            }
        }
        let root = commonDir.appendingPathComponent("refs")
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            while let rel = enumerator.nextObject() as? String {
                guard (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeRegular,
                      let text = try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) else { continue }
                let name = "refs/" + rel
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("ref:") {
                    refs.symbolic[name] = value.dropFirst(4).trimmingCharacters(in: .whitespaces)
                } else if let oid = GitOID(hex: value) {
                    refs.direct[name] = oid
                }
            }
        }
        // A symbolic ref (like origin/HEAD) isn't a branch of its own.
        for name in refs.symbolic.keys { refs.direct[name] = nil }
        return refs
    }

    private func readHead(refs: Refs) -> GitHead {
        let text = (try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.hasPrefix("ref:") {
            let ref = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let name = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            return .branch(name, refs.direct[ref])
        }
        if let oid = GitOID(hex: text) { return .detached(oid) }
        return .branch("main", nil)
    }

    private func readHeadOID() -> GitOID? {
        readHead(refs: readRefs()).oid
    }

    // MARK: - Logs, worktrees, submodules, operations

    private struct LogEntry {
        let old: GitOID?
        let new: GitOID?
        let who: GitSignature
        let message: String
    }

    private func readLog(_ url: URL) -> [LogEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let fields = parts[0].split(separator: " ", maxSplits: 2)
            guard fields.count == 3 else { return nil }
            let zero = String(repeating: "0", count: 40)
            return LogEntry(
                old: fields[0] == zero ? nil : GitOID(hex: String(fields[0])),
                new: fields[1] == zero ? nil : GitOID(hex: String(fields[1])),
                who: GitSignature(parsing: String(fields[2])),
                message: parts.count > 1 ? String(parts[1]) : ""
            )
        }
    }

    private func readWorktrees(head: GitHead) -> [GitWorktree] {
        var out: [GitWorktree] = []
        if commonDir == gitDir, let workTree {
            out.append(GitWorktree(path: workTree.path, branch: head.branchName, head: head.oid, isMain: true))
        } else if commonDir.lastPathComponent == ".git" {
            let mainHead = (try? String(contentsOf: commonDir.appendingPathComponent("HEAD"), encoding: .utf8)) ?? ""
            out.append(GitWorktree(path: commonDir.deletingLastPathComponent().path,
                                   branch: Self.branch(fromHead: mainHead), isMain: true))
        }
        let dir = commonDir.appendingPathComponent("worktrees")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let folder = dir.appendingPathComponent(name)
            guard let gitFile = try? String(contentsOf: folder.appendingPathComponent("gitdir"), encoding: .utf8) else { continue }
            let path = (gitFile.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).deletingLastPathComponent
            let headText = (try? String(contentsOf: folder.appendingPathComponent("HEAD"), encoding: .utf8)) ?? ""
            var worktree = GitWorktree(path: path, branch: Self.branch(fromHead: headText),
                                       head: GitOID(hex: headText))
            worktree.isLocked = FileManager.default.fileExists(atPath: folder.appendingPathComponent("locked").path)
            out.append(worktree)
        }
        return out
    }

    private static func branch(fromHead text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("ref:") else { return nil }
        let ref = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
        return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }

    private func readSubmodules(head: GitHead) -> [GitSubmodule] {
        guard let workTree else { return [] }
        let config = GitConfig(url: workTree.appendingPathComponent(".gitmodules"))
        let names = config.subsections("submodule")
        guard !names.isEmpty else { return [] }
        let tracked = self.files(at: head.oid)
        return names.compactMap { name in
            guard let path = config.value("submodule", name, key: "path") else { return nil }
            var submodule = GitSubmodule(name: name, path: path)
            submodule.url = config.value("submodule", name, key: "url") ?? ""
            submodule.branch = config.value("submodule", name, key: "branch")
            submodule.commit = tracked[path]?.oid
            return submodule
        }
    }

    private func readOperation() -> GitOperation? {
        let fm = FileManager.default
        func text(_ name: String) -> String? {
            (try? String(contentsOf: gitDir.appendingPathComponent(name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func short(_ ref: String?) -> String? {
            guard let ref else { return nil }
            if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
            return GitOID(hex: ref)?.short ?? ref
        }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path) {
            let step = [text("rebase-merge/msgnum"), text("rebase-merge/end")].compactMap { $0 }
            var detail = [short(text("rebase-merge/head-name")).map { "\($0) onto \(short(text("rebase-merge/onto")) ?? "?")" }]
            if step.count == 2 { detail.append("step \(step[0]) of \(step[1])") }
            return GitOperation(title: "Rebase in progress", detail: detail.compactMap { $0 }.joined(separator: ", "))
        }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").path) {
            let step = [text("rebase-apply/next"), text("rebase-apply/last")].compactMap { $0 }
            return GitOperation(title: fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply/applying").path)
                                ? "Applying patches" : "Rebase in progress",
                                detail: step.count == 2 ? "step \(step[0]) of \(step[1])" : nil)
        }
        if let merge = text("MERGE_HEAD") {
            return GitOperation(title: "Merge in progress", detail: (text("MERGE_MSG")?.split(separator: "\n").first).map(String.init)
                                ?? GitOID(hex: merge)?.short)
        }
        if let pick = text("CHERRY_PICK_HEAD") {
            return GitOperation(title: "Cherry-pick in progress", detail: GitOID(hex: pick)?.short)
        }
        if let revert = text("REVERT_HEAD") {
            return GitOperation(title: "Revert in progress", detail: GitOID(hex: revert)?.short)
        }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("BISECT_LOG").path) {
            return GitOperation(title: "Bisect in progress", detail: nil)
        }
        return nil
    }

    // MARK: - Index

    private struct IndexEntry {
        var mtime: UInt32
        var mtimeNanos: UInt32
        var mode: UInt32
        var size: UInt32
        var oid: GitOID
        var path: String
        var stage: Int
        var assumeValid: Bool
        var skipWorktree: Bool
        var intentToAdd: Bool
    }

    private func readIndex() -> [IndexEntry] {
        guard let data = try? Data(contentsOf: gitDir.appendingPathComponent("index")) else { return [] }
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4] == [0x44, 0x49, 0x52, 0x43] else { return [] }   // "DIRC"
        func u32(_ p: Int) -> UInt32 {
            UInt32(bytes[p]) << 24 | UInt32(bytes[p + 1]) << 16 | UInt32(bytes[p + 2]) << 8 | UInt32(bytes[p + 3])
        }
        func u16(_ p: Int) -> UInt16 { UInt16(bytes[p]) << 8 | UInt16(bytes[p + 1]) }
        let version = u32(4)
        let count = Int(u32(8))
        guard (2...4).contains(version) else { return [] }
        var entries: [IndexEntry] = []
        // The count comes from the file: reserve no more than its bytes could hold (62 per entry).
        entries.reserveCapacity(min(count, bytes.count / 62))
        var p = 12
        var previous: [UInt8] = []
        for _ in 0..<count {
            let start = p
            guard p + 62 <= bytes.count else { break }
            let flags = u16(p + 60)
            var entry = IndexEntry(
                mtime: u32(p + 8), mtimeNanos: u32(p + 12), mode: u32(p + 24), size: u32(p + 36),
                oid: GitOID(bytes: bytes[(p + 40)..<(p + 60)]), path: "",
                stage: Int((flags >> 12) & 3), assumeValid: flags & 0x8000 != 0,
                skipWorktree: false, intentToAdd: false
            )
            p += 62
            if version >= 3, flags & 0x4000 != 0 {
                guard p + 2 <= bytes.count else { break }
                let extended = u16(p)
                entry.skipWorktree = extended & 0x4000 != 0
                entry.intentToAdd = extended & 0x2000 != 0
                p += 2
            }
            var name: [UInt8]
            if version == 4 {
                // Path compressed against the previous entry's.
                guard p < bytes.count else { break }
                var c = bytes[p]; p += 1
                var strip = Int(c & 0x7f)
                var extra = 0
                while c & 0x80 != 0, p < bytes.count {
                    // Seven more bytes is already more than any path; more means a crafted file.
                    extra += 1
                    guard extra <= 7 else { return entries }
                    c = bytes[p]; p += 1
                    strip = ((strip + 1) << 7) | Int(c & 0x7f)
                }
                guard let nul = bytes[p...].firstIndex(of: 0) else { break }
                name = Array(previous.dropLast(min(strip, previous.count))) + bytes[p..<nul]
                p = nul + 1
            } else {
                guard let nul = bytes[p...].firstIndex(of: 0) else { break }
                name = Array(bytes[p..<nul])
                p = start + ((nul - start + 8) & ~7)
            }
            previous = name
            entry.path = String(decoding: name, as: UTF8.self)
            entries.append(entry)
        }
        return entries
    }
}

// MARK: - Objects

enum GitObjectKind: Int, Sendable {
    case commit = 1, tree = 2, blob = 3, tag = 4

    init?(name: String) {
        switch name {
        case "commit": self = .commit
        case "tree": self = .tree
        case "blob": self = .blob
        case "tag": self = .tag
        default: return nil
        }
    }
}

struct GitRawObject: Sendable {
    let kind: GitObjectKind
    let data: [UInt8]
}

struct GitTreeEntry: Sendable {
    let mode: UInt32
    let name: String
    let oid: GitOID
    var isTree: Bool { mode == 0o40000 }
}

enum GitParse {
    static func commit(_ oid: GitOID, _ data: [UInt8]) -> GitCommit? {
        let text = String(decoding: data, as: UTF8.self)
        let split = text.range(of: "\n\n")
        let header = split.map { String(text[..<$0.lowerBound]) } ?? text
        let message = split.map { String(text[$0.upperBound...]) } ?? ""
        var tree: GitOID?
        var parents: [GitOID] = []
        var author: GitSignature?
        var committer: GitSignature?
        var signed = false
        for line in header.split(separator: "\n") where !line.hasPrefix(" ") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            switch parts[0] {
            case "tree": tree = GitOID(hex: value)
            case "parent": if let oid = GitOID(hex: value) { parents.append(oid) }
            case "author": author = GitSignature(parsing: value)
            case "committer": committer = GitSignature(parsing: value)
            case "gpgsig", "gpgsig-sha256": signed = true
            default: break
            }
        }
        guard let tree else { return nil }
        let who = author ?? committer ?? GitSignature(parsing: "")
        return GitCommit(id: oid, tree: tree, parents: parents, author: who, committer: committer ?? who,
                         message: message.trimmingCharacters(in: .newlines), isSigned: signed)
    }

    static func tag(_ data: [UInt8]) -> (object: GitOID?, tagger: GitSignature?, message: String) {
        let text = String(decoding: data, as: UTF8.self)
        let split = text.range(of: "\n\n")
        let header = split.map { String(text[..<$0.lowerBound]) } ?? text
        var message = split.map { String(text[$0.upperBound...]) } ?? ""
        if let signature = message.range(of: "-----BEGIN PGP SIGNATURE-----") ?? message.range(of: "-----BEGIN SSH SIGNATURE-----") {
            message = String(message[..<signature.lowerBound])
        }
        var object: GitOID?
        var tagger: GitSignature?
        for line in header.split(separator: "\n") {
            if line.hasPrefix("object ") { object = GitOID(hex: String(line.dropFirst(7))) }
            if line.hasPrefix("tagger ") { tagger = GitSignature(parsing: String(line.dropFirst(7))) }
        }
        return (object, tagger, message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func tree(_ data: [UInt8]) -> [GitTreeEntry] {
        var entries: [GitTreeEntry] = []
        var p = 0
        while p < data.count {
            guard let space = data[p...].firstIndex(of: 0x20),
                  let nul = data[space...].firstIndex(of: 0),
                  nul + 21 <= data.count else { break }
            let mode = UInt32(String(decoding: data[p..<space], as: UTF8.self), radix: 8) ?? 0
            let name = String(decoding: data[(space + 1)..<nul], as: UTF8.self)
            entries.append(GitTreeEntry(mode: mode, name: name, oid: GitOID(bytes: data[(nul + 1)..<(nul + 21)])))
            p = nul + 21
        }
        return entries
    }
}

// MARK: - Packfiles

/// One `.pack` with its version 2 `.idx`, both memory-mapped.
final class GitPack: @unchecked Sendable {
    struct Entry {
        let type: Int
        let size: Int
        let dataOffset: Int
        var baseOffset: Int?
        var baseOID: GitOID?
    }

    private let pack: Data
    private let index: Data
    private let count: Int
    private let namesStart = 8 + 256 * 4

    init?(pack packURL: URL, index indexURL: URL) {
        guard let index = try? Data(contentsOf: indexURL, options: .alwaysMapped),
              let pack = try? Data(contentsOf: packURL, options: .alwaysMapped),
              index.count >= 8 + 256 * 4,
              index.prefix(4).elementsEqual([0xff, 0x74, 0x4f, 0x63]) else { return nil }   // "\377tOc", version 2
        self.index = index
        self.pack = pack
        count = index.withUnsafeBytes { Int(Self.u32($0, 8 + 255 * 4)) }
        guard index.count >= namesStart + count * 28 else { return nil }
        // The fanout must never decrease, or lookups would read past the name table.
        let fanoutValid = index.withUnsafeBytes { raw in
            var previous: UInt32 = 0
            for bucket in 0..<256 {
                let value = Self.u32(raw, 8 + bucket * 4)
                if value < previous { return false }
                previous = value
            }
            return true
        }
        guard fanoutValid else { return nil }
    }

    private static func u32(_ raw: UnsafeRawBufferPointer, _ p: Int) -> UInt32 {
        UInt32(raw[p]) << 24 | UInt32(raw[p + 1]) << 16 | UInt32(raw[p + 2]) << 8 | UInt32(raw[p + 3])
    }

    func offset(of oid: [UInt8]) -> Int? {
        index.withUnsafeBytes { raw -> Int? in
            let first = Int(oid[0])
            var low = first == 0 ? 0 : Int(Self.u32(raw, 8 + (first - 1) * 4))
            var high = min(Int(Self.u32(raw, 8 + first * 4)), count)
            guard low <= high else { return nil }
            while low < high {
                let mid = (low + high) / 2
                let order = oid.withUnsafeBytes { memcmp(raw.baseAddress! + namesStart + mid * 20, $0.baseAddress!, 20) }
                if order == 0 {
                    let small = Self.u32(raw, namesStart + count * 24 + mid * 4)
                    let offset: UInt64
                    if small & 0x8000_0000 == 0 {
                        offset = UInt64(small)
                    } else {
                        let large = namesStart + count * 28 + Int(small & 0x7fff_ffff) * 8
                        guard large + 8 <= raw.count else { return nil }
                        offset = UInt64(Self.u32(raw, large)) << 32 | UInt64(Self.u32(raw, large + 4))
                    }
                    guard offset < UInt64(pack.count) else { return nil }
                    return Int(offset)
                }
                if order < 0 { low = mid + 1 } else { high = mid }
            }
            return nil
        }
    }

    func entry(at offset: Int) -> Entry? {
        pack.withUnsafeBytes { raw -> Entry? in
            guard offset >= 12, offset < raw.count else { return nil }
            var p = offset
            var c = raw[p]; p += 1
            let type = Int((c >> 4) & 7)
            var size = Int(c & 15)
            var shift = 4
            while c & 0x80 != 0 {
                guard p < raw.count, shift <= 56 else { return nil }
                c = raw[p]; p += 1
                size |= Int(c & 0x7f) << shift
                shift += 7
            }
            switch type {
            case 6:
                guard p < raw.count else { return nil }
                c = raw[p]; p += 1
                var distance = Int(c & 0x7f)
                var extra = 0
                while c & 0x80 != 0 {
                    // Seven continuation bytes cover any real pack; beyond that the arithmetic could overflow.
                    extra += 1
                    guard p < raw.count, extra <= 7 else { return nil }
                    c = raw[p]; p += 1
                    distance = ((distance + 1) << 7) | Int(c & 0x7f)
                }
                return Entry(type: 6, size: size, dataOffset: p, baseOffset: offset - distance)
            case 7:
                guard p + 20 <= raw.count else { return nil }
                return Entry(type: 7, size: size, dataOffset: p + 20,
                             baseOID: GitOID(bytes: UnsafeRawBufferPointer(rebasing: raw[p..<(p + 20)])))
            default:
                return Entry(type: type, size: size, dataOffset: p)
            }
        }
    }

    func inflate(_ entry: Entry) -> [UInt8]? {
        pack.withUnsafeBytes { raw in
            Zlib.inflate(UnsafeRawBufferPointer(rebasing: raw[entry.dataOffset...]), size: entry.size)
        }
    }

    static func apply(delta: [UInt8], to base: [UInt8]) -> [UInt8]? {
        var p = 0
        func varint() -> Int {
            var value = 0, shift = 0
            while p < delta.count, shift < 56 {
                let byte = delta[p]; p += 1
                value |= Int(byte & 0x7f) << shift
                shift += 7
                if byte & 0x80 == 0 { break }
            }
            return value
        }
        guard varint() == base.count else { return nil }
        let targetSize = varint()
        guard targetSize <= Zlib.maxObjectBytes else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(targetSize)
        while p < delta.count {
            let op = delta[p]; p += 1
            if op & 0x80 != 0 {
                var offset = 0, size = 0
                for i in 0..<4 where op & (1 << i) != 0 {
                    guard p < delta.count else { return nil }
                    offset |= Int(delta[p]) << (8 * i); p += 1
                }
                for i in 0..<3 where op & (0x10 << i) != 0 {
                    guard p < delta.count else { return nil }
                    size |= Int(delta[p]) << (8 * i); p += 1
                }
                if size == 0 { size = 0x10000 }
                guard offset + size <= base.count, out.count + size <= targetSize else { return nil }
                out.append(contentsOf: base[offset..<(offset + size)])
            } else if op != 0 {
                let length = Int(op)
                guard p + length <= delta.count, out.count + length <= targetSize else { return nil }
                out.append(contentsOf: delta[p..<(p + length)])
                p += length
            } else {
                return nil
            }
        }
        return out.count == targetSize ? out : nil
    }
}

// MARK: - zlib

enum Zlib {
    /// The largest object read. Sizes come from the repository, which may be hostile.
    static let maxObjectBytes = 64 * 1024 * 1024

    /// Inflates a zlib stream of known inflated size (a pack entry), ignoring what follows it.
    static func inflate(_ source: UnsafeRawBufferPointer, size: Int) -> [UInt8]? {
        guard size > 0 else { return [] }
        guard size <= maxObjectBytes, source.count > 2, let base = source.baseAddress else { return nil }
        var out = [UInt8](repeating: 0, count: size)
        // Compression's ZLIB is raw DEFLATE: skip the two-byte zlib header.
        let written = out.withUnsafeMutableBufferPointer { buffer in
            compression_decode_buffer(buffer.baseAddress!, size,
                                      base.assumingMemoryBound(to: UInt8.self) + 2, source.count - 2,
                                      nil, COMPRESSION_ZLIB)
        }
        return written == size ? out : nil
    }

    /// Inflates a whole zlib stream (a loose object).
    static func inflate(_ data: Data) -> [UInt8]? {
        guard data.count > 2 else { return nil }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        return data.withUnsafeBytes { raw -> [UInt8]? in
            stream.pointee.src_ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + 2
            stream.pointee.src_size = raw.count - 2
            var out: [UInt8] = []
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let result = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(contentsOf: UnsafeBufferPointer(start: buffer, count: chunk - stream.pointee.dst_size))
                if out.count > maxObjectBytes { return nil }
                switch result {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK: if stream.pointee.src_size == 0 && stream.pointee.dst_size == chunk { return out }
                default: return nil
                }
            }
        }
    }
}

// MARK: - Config

/// A git config file: `[section "sub"]` headers and `key = value` lines.
struct GitConfig {
    private var entries: [(section: String, subsection: String?, key: String, value: String)] = []

    init(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var section = ""
        var subsection: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), let close = line.lastIndex(of: "]") {
                let inner = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                if let quote = inner.firstIndex(of: "\"") {
                    section = inner[..<quote].trimmingCharacters(in: .whitespaces).lowercased()
                    subsection = inner[inner.index(after: quote)...].replacingOccurrences(of: "\"", with: "")
                } else if let dot = inner.firstIndex(of: ".") {
                    section = inner[..<dot].lowercased()
                    subsection = String(inner[inner.index(after: dot)...])
                } else {
                    section = inner.lowercased()
                    subsection = nil
                }
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1)
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            var value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "true"
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if let comment = value.firstIndex(where: { $0 == "#" || $0 == ";" }) {
                value = value[..<comment].trimmingCharacters(in: .whitespaces)
            }
            entries.append((section, subsection, key, value))
        }
    }

    func value(_ section: String, _ subsection: String? = nil, key: String) -> String? {
        values(section, subsection, key: key).last
    }

    func values(_ section: String, _ subsection: String? = nil, key: String) -> [String] {
        entries.filter { $0.section == section && $0.subsection == subsection && $0.key == key }.map(\.value)
    }

    func subsections(_ section: String) -> [String] {
        var seen: [String] = []
        for entry in entries where entry.section == section {
            if let sub = entry.subsection, !seen.contains(sub) { seen.append(sub) }
        }
        return seen
    }
}

// MARK: - Ignore rules

/// `.gitignore` matching: globs with `*`, `?`, `**`, `[…]`, `!` negation and trailing `/` for folders.
struct GitIgnore {
    private struct Rule {
        let glob: GitGlob
        let base: String
        let negated: Bool
        let directoryOnly: Bool
        let matchesName: Bool
    }

    private var rules: [Rule] = []

    init() {
        // The global excludes file is outside the sandbox; Finder's metadata is in nearly everyone's.
        add(".DS_Store", base: "")
    }

    /// The user's global excludes file (`core.excludesFile`, else `~/.config/git/ignore`).
    /// Outside the sandbox, so this only works where the app can read the home folder.
    mutating func loadGlobalExcludes() {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return }
        let home = URL(fileURLWithPath: String(cString: dir))
        let config = GitConfig(url: home.appendingPathComponent(".gitconfig"))
        if let path = config.value("core", key: "excludesfile") {
            let expanded = path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))).path : path
            load(URL(fileURLWithPath: expanded), base: "")
        } else {
            load(home.appendingPathComponent(".config/git/ignore"), base: "")
        }
    }

    /// Ignore files come from the repository, which may be hostile: bound how much they add.
    private static let maxRules = 20_000
    private static let maxFileBytes = 1024 * 1024

    mutating func load(_ url: URL, base: String) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count <= Self.maxFileBytes else { return }
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard rules.count < Self.maxRules else { return }
            add(String(line), base: base)
        }
    }

    private mutating func add(_ line: String, base: String) {
        var pattern = line
        while pattern.hasSuffix(" "), !pattern.hasSuffix("\\ ") { pattern.removeLast() }
        guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return }
        var negated = false
        if pattern.hasPrefix("!") { negated = true; pattern.removeFirst() }
        if pattern.hasPrefix("\\") { pattern.removeFirst() }
        var directoryOnly = false
        if pattern.hasSuffix("/") { directoryOnly = true; pattern.removeLast() }
        let matchesName = !pattern.contains("/")
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        // Patterns come from the repository, which may be untrusted: keep them short.
        guard !pattern.isEmpty, pattern.count <= 1_024 else { return }
        rules.append(Rule(glob: GitGlob(pattern), base: base, negated: negated, directoryOnly: directoryOnly, matchesName: matchesName))
    }

    func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for rule in rules {
            if rule.directoryOnly && !isDirectory { continue }
            let relative: String
            if rule.base.isEmpty {
                relative = path
            } else if path.hasPrefix(rule.base + "/") {
                relative = String(path.dropFirst(rule.base.count + 1))
            } else {
                continue
            }
            let subject = rule.matchesName ? (relative as NSString).lastPathComponent : relative
            if rule.glob.matches(subject) { ignored = !rule.negated }
        }
        return ignored
    }
}

/// A gitignore glob, matched like git's wildmatch: `*` and `?` stop at `/`, `**/` spans folders,
/// `[…]` is a class. Memoized, so a hostile pattern can't make it backtrack exponentially.
struct GitGlob {
    private struct CharacterClass {
        let negated: Bool
        let ranges: [ClosedRange<Character>]
        /// Pattern index just after the closing `]`.
        let end: Int

        func contains(_ ch: Character) -> Bool {
            ranges.contains { $0.contains(ch) } != negated
        }
    }

    private let pattern: [Character]
    /// Classes parsed once, by the index of their `[`.
    private let classes: [Int: CharacterClass]

    init(_ pattern: String) {
        // Runs of three or more stars mean the same as `**`.
        var chars: [Character] = []
        for c in pattern {
            if c == "*", chars.count >= 2, chars[chars.count - 1] == "*", chars[chars.count - 2] == "*" { continue }
            chars.append(c)
        }
        self.pattern = chars
        var classes: [Int: CharacterClass] = [:]
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" {
                i += 2
            } else if chars[i] == "[", let parsed = Self.parseClass(chars, at: i) {
                classes[i] = parsed
                i = parsed.end
            } else {
                i += 1
            }
        }
        self.classes = classes
    }

    /// Whether `path` matches, or sits inside a folder that does (`foo` ignores `foo/bar`).
    func matches(_ path: String) -> Bool {
        let t = Array(path)
        guard t.count <= 1_024 else { return false }   // PATH_MAX; also bounds the recursion
        let p = pattern
        // Each state does constant work and is solved once: O(pattern × path) in all.
        var failed = Set<Int>()
        let width = t.count + 1

        /// Pattern position `pi` against text position `ti`.
        func go(_ pi: Int, _ ti: Int) -> Bool {
            let key = (pi * width + ti) * 2
            if failed.contains(key) { return false }
            let result = step(pi, ti)
            if !result { failed.insert(key) }
            return result
        }

        /// Inside a `**/` at `pi`, looking for the `/` that ends another folder.
        func scan(_ pi: Int, _ ti: Int) -> Bool {
            let key = (pi * width + ti) * 2 + 1
            if failed.contains(key) { return false }
            let result = ti < t.count && ((t[ti] == "/" && go(pi + 3, ti + 1)) || scan(pi, ti + 1))
            if !result { failed.insert(key) }
            return result
        }

        func step(_ pi: Int, _ ti: Int) -> Bool {
            // The whole pattern matched: the path itself, or a folder the path is inside.
            guard pi < p.count else { return ti == t.count || t[ti] == "/" }
            let c = p[pi]
            if c == "*" {
                if pi + 1 < p.count, p[pi + 1] == "*" {
                    if pi + 2 < p.count, p[pi + 2] == "/" {
                        // `**/`: zero or more whole folders.
                        return go(pi + 3, ti) || scan(pi, ti)
                    }
                    // `**` elsewhere: anything, slashes included.
                    return go(pi + 2, ti) || (ti < t.count && go(pi, ti + 1))
                }
                // `*`: anything but a slash.
                return go(pi + 1, ti) || (ti < t.count && t[ti] != "/" && go(pi, ti + 1))
            }
            guard ti < t.count else { return false }
            switch c {
            case "?":
                return t[ti] != "/" && go(pi + 1, ti + 1)
            case "[":
                if let set = classes[pi] {
                    return t[ti] != "/" && set.contains(t[ti]) && go(set.end, ti + 1)
                }
                return t[ti] == "[" && go(pi + 1, ti + 1)
            case "\\" where pi + 1 < p.count:
                return p[pi + 1] == t[ti] && go(pi + 2, ti + 1)
            default:
                return c == t[ti] && go(pi + 1, ti + 1)
            }
        }

        return go(0, 0)
    }

    /// Parses the class starting at `start` (`[`), or nil when it isn't closed.
    private static func parseClass(_ p: [Character], at start: Int) -> CharacterClass? {
        var i = start + 1
        var negated = false
        if i < p.count, p[i] == "!" || p[i] == "^" {
            negated = true
            i += 1
        }
        var ranges: [ClosedRange<Character>] = []
        var first = true
        while i < p.count {
            if p[i] == "]", !first { return CharacterClass(negated: negated, ranges: ranges, end: i + 1) }
            first = false
            var low = p[i]
            if low == "\\", i + 1 < p.count {
                i += 1
                low = p[i]
            }
            if i + 2 < p.count, p[i + 1] == "-", p[i + 2] != "]", low <= p[i + 2] {
                ranges.append(low...p[i + 2])
                i += 3
            } else {
                ranges.append(low...low)
                i += 1
            }
        }
        return nil
    }
}

import Foundation

// Value types the git viewer shows. `GitRepository` builds them from the `.git` folder.

/// A SHA-1 object name, kept as lowercase hex.
struct GitOID: Hashable, Comparable, Sendable, CustomStringConvertible {
    let hex: String

    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hex.count == 40, hex.allSatisfy(\.isHexDigit) else { return nil }
        self.hex = hex
    }

    init<S: Sequence>(bytes: S) where S.Element == UInt8 {
        hex = bytes.map { String(format: "%02x", $0) }.joined()
    }

    var bytes: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(20)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    var short: String { String(hex.prefix(7)) }
    var description: String { hex }
    static func < (a: GitOID, b: GitOID) -> Bool { a.hex < b.hex }
}

struct GitSignature: Hashable, Sendable {
    var name: String
    var email: String
    var date: Date
    /// The author's own offset, as written ("+0530").
    var timeZone: String

    /// Parses `Name <email> 1700000000 +0530`.
    init(parsing line: String) {
        let open = line.lastIndex(of: "<")
        let close = line.lastIndex(of: ">")
        if let open, let close, open < close {
            name = line[..<open].trimmingCharacters(in: .whitespaces)
            email = String(line[line.index(after: open)..<close])
            let rest = line[line.index(after: close)...].split(separator: " ")
            date = Date(timeIntervalSince1970: TimeInterval(rest.first.flatMap { Double($0) } ?? 0))
            timeZone = rest.count > 1 ? String(rest[1]) : "+0000"
        } else {
            name = line
            email = ""
            date = .distantPast
            timeZone = "+0000"
        }
    }

    /// The date in the author's own time zone, as git shows it.
    var localDateText: String {
        let sign = timeZone.first == "-" ? -1 : 1
        let digits = timeZone.dropFirst()
        let hours = Int(digits.prefix(2)) ?? 0
        let minutes = Int(digits.suffix(2)) ?? 0
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
        return "\(formatter.string(from: date)) (\(timeZone))"
    }
}

struct GitCommit: Identifiable, Hashable, Sendable {
    let id: GitOID
    let tree: GitOID
    let parents: [GitOID]
    let author: GitSignature
    let committer: GitSignature
    let message: String
    /// Has a GPG or SSH signature (not verified).
    let isSigned: Bool

    var subject: String {
        message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    var body: String {
        guard let newline = message.firstIndex(of: "\n") else { return "" }
        return message[newline...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isMerge: Bool { parents.count > 1 }

    /// `Co-authored-by:` trailers.
    var coAuthors: [String] {
        message.split(separator: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("co-authored-by:") else { return nil }
            return line.dropFirst("co-authored-by:".count).trimmingCharacters(in: .whitespaces)
        }
    }
}

enum GitHead: Hashable, Sendable {
    case branch(String, GitOID?)   // nil OID: unborn branch, no commits yet
    case detached(GitOID)

    var oid: GitOID? {
        switch self {
        case .branch(_, let oid): oid
        case .detached(let oid): oid
        }
    }

    var branchName: String? {
        if case .branch(let name, _) = self { name } else { nil }
    }
}

struct GitBranch: Identifiable, Hashable, Sendable {
    var id: String { refName }
    let name: String
    let refName: String
    let tip: GitOID
    var upstream: String?      // short name, e.g. origin/main
    var upstreamGone = false   // configured, but the remote branch no longer exists
    var ahead = 0
    var behind = 0
    var isHead = false
    var tipDate: Date?
    var tipSubject = ""
}

struct GitRemoteBranch: Identifiable, Hashable, Sendable {
    var id: String { refName }
    let name: String           // without the remote prefix
    let refName: String
    let tip: GitOID
    var tipDate: Date?
}

struct GitRemote: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    var fetchURL = ""
    var pushURL = ""
    var fetchSpecs: [String] = []
    var defaultBranch: String?
    var branches: [GitRemoteBranch] = []

    /// A web link for GitHub, GitLab, Bitbucket and the like.
    var webURL: URL? {
        var url = fetchURL
        if url.hasPrefix("git@"), let colon = url.firstIndex(of: ":") {
            url = "https://" + url[url.index(url.startIndex, offsetBy: 4)..<colon] + "/" + url[url.index(after: colon)...]
        } else if url.hasPrefix("ssh://") {
            url = "https://" + url.dropFirst(6).replacingOccurrences(of: "git@", with: "")
        }
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
        if url.hasSuffix(".git") { url.removeLast(4) }
        return URL(string: url)
    }

    var host: String? { webURL?.host() }
}

struct GitTag: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let target: GitOID         // the commit (peeled)
    var isAnnotated = false
    var tagger: GitSignature?
    var message = ""
    var date: Date?
}

struct GitStash: Identifiable, Hashable, Sendable {
    var id: GitOID { oid }
    let index: Int
    let oid: GitOID
    let message: String
    let date: Date
}

struct GitWorktree: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    var branch: String?
    var head: GitOID?
    var isMain = false
    var isLocked = false
}

struct GitSubmodule: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    var url = ""
    var branch: String?
    var commit: GitOID?
}

struct GitReflogEntry: Identifiable, Hashable, Sendable {
    let id: Int
    let old: GitOID?
    let new: GitOID?
    let who: GitSignature
    let message: String
}

/// A merge, rebase or similar that stopped part way.
struct GitOperation: Hashable, Sendable {
    let title: String
    var detail: String?
}

/// Where a commit's ref badges come from.
struct GitRefBadge: Hashable, Sendable {
    enum Kind: Int, Hashable, Sendable { case head, branch, remote, tag, stash }
    let kind: Kind
    let name: String
    var isHead = false
}

// MARK: - Changes and diffs

struct GitFileChange: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case added, modified, deleted, renamed, typeChanged, untracked, conflicted

        var letter: String {
            switch self {
            case .added: "A"
            case .modified: "M"
            case .deleted: "D"
            case .renamed: "R"
            case .typeChanged: "T"
            case .untracked: "?"
            case .conflicted: "U"
            }
        }

        var title: String {
            switch self {
            case .added: "Added"
            case .modified: "Modified"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .typeChanged: "Type changed"
            case .untracked: "Untracked"
            case .conflicted: "Conflicted"
            }
        }
    }

    enum Side: Hashable, Sendable {
        case object(GitOID)
        case workTree
        case none
    }

    var id: String { "\(kind.rawValue):\(oldPath ?? ""):\(path)" }
    let path: String
    var oldPath: String?
    let kind: Kind
    var old: Side = .none
    var new: Side = .none
    var oldMode: UInt32 = 0
    var newMode: UInt32 = 0

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }

    var isSubmodule: Bool { oldMode == 0o160000 || newMode == 0o160000 }
    var modeChanged: Bool { oldMode != 0 && newMode != 0 && oldMode != newMode }
}

struct GitStatus: Hashable, Sendable {
    var staged: [GitFileChange] = []
    var unstaged: [GitFileChange] = []
    var untracked: [GitFileChange] = []
    var conflicted: [GitFileChange] = []
    /// The walk stopped early on a very large folder.
    var untrackedTruncated = false

    var isClean: Bool { staged.isEmpty && unstaged.isEmpty && untracked.isEmpty && conflicted.isEmpty }
    var count: Int { staged.count + unstaged.count + untracked.count + conflicted.count }
}

struct GitDiffLine: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case context, added, removed }
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

struct GitDiffHunk: Hashable, Sendable, Identifiable {
    let id: Int
    let header: String
    let lines: [GitDiffLine]
}

enum GitFileDiff: Hashable, Sendable {
    case text(hunks: [GitDiffHunk], additions: Int, deletions: Int)
    case binary(oldSize: Int, newSize: Int)
    case submodule(old: GitOID?, new: GitOID?)
    case tooLarge(size: Int)
    case unreadable(String)

    var additions: Int { if case .text(_, let a, _) = self { a } else { 0 } }
    var deletions: Int { if case .text(_, _, let d) = self { d } else { 0 } }
}

// MARK: - Snapshot

/// Everything the viewer shows at once, read in one pass.
struct GitSnapshot: Sendable {
    var name: String
    var workTree: String?
    var gitDir: String
    var isBare = false
    var head: GitHead
    var operation: GitOperation?
    var branches: [GitBranch] = []
    var remotes: [GitRemote] = []
    var tags: [GitTag] = []
    var stashes: [GitStash] = []
    var worktrees: [GitWorktree] = []
    var submodules: [GitSubmodule] = []
    var reflog: [GitReflogEntry] = []
    var commits: [GitCommit] = []
    /// More history exists beyond `commits`.
    var isTruncated = false
    var badges: [GitOID: [GitRefBadge]] = [:]
    var userName: String?
    var userEmail: String?
    var objectFormat = "sha1"
    var packCount = 0
    var looseObjectCount = 0
    var status: GitStatus?

    var headBranch: GitBranch? { branches.first(where: \.isHead) }
    var headCommit: GitCommit? { head.oid.flatMap { oid in commits.first { $0.id == oid } } }
}

// MARK: - Commit graph

/// One row of the history graph: where the commit's dot sits and the lines through the row.
struct GitGraphRow: Sendable {
    struct Edge: Hashable, Sendable {
        /// Lane positions; y is 0 (top), 0.5 (middle) or 1 (bottom) of the row.
        let fromLane: Int
        let fromY: Double
        let toLane: Int
        let toY: Double
        let color: Int
    }

    let lane: Int
    let color: Int
    let edges: [Edge]
    let laneCount: Int
}

enum GitGraph {
    /// Lays commits (children before parents) out in lanes, like `git log --graph`.
    /// Parents that aren't in the list (beyond the loaded history) get no line.
    static func layout(_ commits: [GitCommit]) -> [GitGraphRow] {
        let known = Set(commits.map(\.id))
        var lanes: [GitOID?] = []
        var colors: [Int] = []
        var nextColor = 0
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeLane() -> Int {
            if let index = lanes.firstIndex(where: { $0 == nil }) { return index }
            lanes.append(nil)
            colors.append(0)
            return lanes.count - 1
        }

        for commit in commits {
            var edges: [GitGraphRow.Edge] = []
            let incoming = lanes.indices.filter { lanes[$0] == commit.id }
            let lane: Int
            if let first = incoming.first {
                lane = first
            } else {
                lane = freeLane()
                colors[lane] = nextColor
                nextColor += 1
            }
            let color = colors[lane]

            // Top half: lanes arriving at this commit bend into the dot; the rest pass straight down.
            for index in lanes.indices where lanes[index] != nil {
                if lanes[index] == commit.id {
                    edges.append(.init(fromLane: index, fromY: 0, toLane: lane, toY: 0.5, color: colors[index]))
                } else {
                    edges.append(.init(fromLane: index, fromY: 0, toLane: index, toY: 1, color: colors[index]))
                }
            }
            for index in incoming where index != lane { lanes[index] = nil }

            let parents = commit.parents.filter(known.contains)
            if let first = parents.first {
                lanes[lane] = first
                edges.append(.init(fromLane: lane, fromY: 0.5, toLane: lane, toY: 1, color: color))
            } else {
                lanes[lane] = nil
            }
            for parent in parents.dropFirst() {
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    edges.append(.init(fromLane: lane, fromY: 0.5, toLane: existing, toY: 1, color: colors[existing]))
                } else {
                    let index = freeLane()
                    lanes[index] = parent
                    colors[index] = nextColor
                    nextColor += 1
                    edges.append(.init(fromLane: lane, fromY: 0.5, toLane: index, toY: 1, color: colors[index]))
                }
            }
            while let last = lanes.last, last == nil {
                lanes.removeLast()
                colors.removeLast()
            }
            let width = max(edges.map { max($0.fromLane, $0.toLane) }.max() ?? 0, lane) + 1
            rows.append(GitGraphRow(lane: lane, color: color, edges: edges, laneCount: width))
        }
        return rows
    }
}

// MARK: - Line diff

enum GitLineDiff {
    static let contextLines = 3

    /// A unified diff of two texts, grouped into hunks with three lines of context.
    static func diff(old: String, new: String) -> GitFileDiff {
        let oldLines = lines(old)
        let newLines = lines(new)
        let difference = newLines.difference(from: oldLines)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var script: [GitDiffLine] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                script.append(.init(kind: .removed, oldNumber: i + 1, newNumber: nil, text: oldLines[i]))
                i += 1
            } else if j < newLines.count, inserted.contains(j) {
                script.append(.init(kind: .added, oldNumber: nil, newNumber: j + 1, text: newLines[j]))
                j += 1
            } else if i < oldLines.count, j < newLines.count {
                script.append(.init(kind: .context, oldNumber: i + 1, newNumber: j + 1, text: newLines[j]))
                i += 1
                j += 1
            } else {
                break
            }
        }

        // Keep changed lines plus their context, splitting where the gaps are long.
        let changed = script.indices.filter { script[$0].kind != .context }
        var hunks: [GitDiffHunk] = []
        var start: Int?
        var end = 0
        func flush() {
            guard let s = start else { return }
            let slice = Array(script[s...end])
            let firstOld = slice.compactMap(\.oldNumber).first ?? 0
            let firstNew = slice.compactMap(\.newNumber).first ?? 0
            let oldCount = slice.filter { $0.kind != .added }.count
            let newCount = slice.filter { $0.kind != .removed }.count
            hunks.append(.init(id: hunks.count, header: "@@ -\(firstOld),\(oldCount) +\(firstNew),\(newCount) @@", lines: slice))
            start = nil
        }
        for index in changed {
            let lower = max(index - contextLines, 0)
            let upper = min(index + contextLines, script.count - 1)
            if let _ = start, lower <= end + 1 {
                end = max(end, upper)
            } else {
                flush()
                start = lower
                end = upper
            }
        }
        flush()
        return .text(hunks: hunks, additions: script.filter { $0.kind == .added }.count,
                     deletions: script.filter { $0.kind == .removed }.count)
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
}

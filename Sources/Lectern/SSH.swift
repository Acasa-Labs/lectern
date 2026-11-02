import AppKit

/// A server to open an SSH tab to: a `~/.ssh/config` host alias, or `user@host` with an optional port.
struct SSHTarget: Codable, Hashable {
    var name: String?
    var destination: String
    var port: Int?

    var title: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? destination }
    /// Identifies the server for bookmarks and saved lists.
    var key: String { "ssh://\(destination)" + (port.map { ":\($0)" } ?? "") }

    /// The command an SSH tab runs. Each argument is single-quoted, and a destination can't start with "-",
    /// so nothing in it is read as a shell command or an ssh option.
    var commandLine: String? {
        guard !destination.isEmpty, !destination.hasPrefix("-"), !destination.contains(where: \.isWhitespace) else { return nil }
        let args = ["ssh"] + (port.map { ["-p", String($0)] } ?? []) + [destination]
        return args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
}

/// Host aliases from `~/.ssh/config` and the files it includes. Wildcard patterns are skipped.
enum SSHConfig {
    struct Host: Hashable {
        /// The first name on the `Host` line; the menu shows this one.
        let alias: String
        /// Other names on the same line, for the same server.
        var otherNames: [String] = []
        var hostName: String?
        var user: String?

        private static let gitServices = ["github.com", "gitlab.com", "bitbucket.org", "ssh.dev.azure.com", "vs-ssh.visualstudio.com"]

        /// Hosts that only serve git (push, pull, signing), not a shell. Hidden from the SSH list unless you show them.
        var isGitOnly: Bool {
            let names = ([alias, hostName] + otherNames).compactMap { $0?.lowercased() }
            return user == "git" || names.contains { name in Self.gitServices.contains { name == $0 || name.hasSuffix("." + $0) } }
        }
    }

    static func hosts() -> [Host] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var hosts: [Host] = []
        read(home.appendingPathComponent(".ssh/config"), depth: 0, into: &hosts)
        var seen: Set<String> = []
        return hosts.filter { seen.insert($0.alias).inserted }
    }

    private static func read(_ file: URL, depth: Int, into hosts: inout [Host]) {
        guard depth < 4, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        // The host the current `Host` line declared, so HostName and User apply to it.
        var current: [Int] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let keyword = parts[0].lowercased()
            let values = parts[1].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            switch keyword {
            case "host":
                // Every name on one Host line is the same server, so it's listed once.
                current = []
                let names = values.filter { !$0.contains(where: { "*?!".contains($0) }) }
                if let first = names.first {
                    current = [hosts.count]
                    hosts.append(Host(alias: first, otherNames: Array(names.dropFirst())))
                }
            case "match":
                current = []
            case "hostname":
                current.forEach { hosts[$0].hostName = values.first }
            case "user":
                current.forEach { hosts[$0].user = values.first }
            case "include":
                current = []
                for included in values.flatMap(expand) { read(included, depth: depth + 1, into: &hosts) }
            default:
                break
            }
        }
    }

    /// An Include path: `~` expanded, relative paths taken from `~/.ssh`, and `*` in the file name matched.
    private static func expand(_ pattern: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = pattern.hasPrefix("~") ? home.path + pattern.dropFirst()
            : pattern.hasPrefix("/") ? pattern : home.path + "/.ssh/" + pattern
        guard path.contains("*") || path.contains("?") else { return [URL(fileURLWithPath: path)] }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return entries.filter { fnmatch(name, $0, 0) == 0 }.sorted().map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
    }
}

/// Which `~/.ssh/config` hosts the SSH menus list. Git-only hosts start hidden; your ticks override that.
final class SSHHostChoices: ObservableObject {
    static let shared = SSHHostChoices()
    private static let key = "sshHostVisibility"

    @Published private var overrides: [String: Bool]

    private init() {
        overrides = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Bool] ?? [:]
    }

    func isShown(_ host: SSHConfig.Host) -> Bool {
        overrides[host.alias] ?? !host.isGitOnly
    }

    func setShown(_ host: SSHConfig.Host, _ shown: Bool) {
        overrides[host.alias] = shown
        UserDefaults.standard.set(overrides, forKey: Self.key)
    }
}

/// Servers you've added with Connect to Server…, kept across launches.
final class SavedServers: ObservableObject {
    static let shared = SavedServers()
    private static let key = "sshServers"

    @Published private(set) var servers: [SSHTarget]

    private init() {
        servers = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([SSHTarget].self, from: $0) } ?? []
    }

    func add(_ server: SSHTarget) {
        servers.removeAll { $0.key == server.key }
        servers.append(server)
        save()
    }

    func remove(_ server: SSHTarget) {
        servers.removeAll { $0.key == server.key }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Asks for a server. Returns nil if cancelled or the address isn't usable.
    static func promptForServer() -> SSHTarget? {
        let alert = NSAlert()
        alert.messageText = "Connect to Server"
        alert.informativeText = "Opens an SSH tab with your Mac's ssh, keys and ~/.ssh/config."
        let destination = NSTextField(string: "")
        destination.placeholderString = "user@host"
        let port = NSTextField(string: "")
        port.placeholderString = "Port (optional, 22)"
        let name = NSTextField(string: "")
        name.placeholderString = "Name (optional)"
        let save = NSButton(checkboxWithTitle: "Save to the SSH list", target: nil, action: nil)
        save.state = .on
        let stack = NSStackView(views: [destination, port, name, save])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for field in [destination, port, name] { field.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 112)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = destination
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let target = SSHTarget(name: name.stringValue.trimmingCharacters(in: .whitespaces),
                               destination: destination.stringValue.trimmingCharacters(in: .whitespaces),
                               port: Int(port.stringValue.trimmingCharacters(in: .whitespaces)))
        guard target.commandLine != nil else {
            let warning = NSAlert()
            warning.messageText = "That address can't be used"
            warning.informativeText = "Enter it as user@host or a host from ~/.ssh/config, without spaces."
            warning.runModal()
            return nil
        }
        if save.state == .on { shared.add(target) }
        return target
    }
}

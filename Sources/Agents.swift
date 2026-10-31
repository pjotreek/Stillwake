import Foundation

enum AgentStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Stillwake/Agents", isDirectory: true)

    static let staleAfter: TimeInterval = 30 * 60

    static func prepare() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

enum AgentHook {
    private static let workingEvents: Set<String> = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop", "PermissionRequest", "Progress",
    ]
    private static let finishedEvents: Set<String> = ["Stop", "StopFailure", "SessionEnd", "Notification"]

    static func run(arguments: [String]) -> Int32 {
        var provider = "agent"
        if let index = arguments.firstIndex(of: "--provider"), index + 1 < arguments.count {
            provider = arguments[index + 1]
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = payload["hook_event_name"] as? String,
              let session = payload["session_id"] as? String else { return 0 }

        let name = sanitize("\(provider)-\(session)")
        let file = AgentStore.directory.appendingPathComponent(name)

        if finishedEvents.contains(event) {
            try? FileManager.default.removeItem(at: file)
        } else if workingEvents.contains(event) {
            if FileManager.default.fileExists(atPath: file.path) {
                utimes(file.path, nil)
            } else {
                AgentStore.prepare()
                try? "\(agentProcess())\n".write(to: file, atomically: true, encoding: .utf8)
            }
        }
        return 0
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String(name.filter { allowed.contains($0) }.prefix(120))
    }

    private static func agentProcess() -> pid_t {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env"]
        var pid = getppid()
        for _ in 0..<4 {
            guard let info = processInfo(pid), shells.contains(info.name), info.parent > 1 else { break }
            pid = info.parent
        }
        return pid
    }

    private static func processInfo(_ pid: pid_t) -> (name: String, parent: pid_t)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (name, info.kp_eproc.e_ppid)
    }
}

final class AgentMonitor {
    var onChange: ((Int) -> Void)?
    private(set) var workingCount = 0

    private var directorySource: DispatchSourceFileSystemObject?
    private var exitSources: [pid_t: DispatchSourceProcess] = [:]
    private var expiryTimer: DispatchSourceTimer?
    private var pendingScan = false

    func start() {
        guard directorySource == nil else { return }
        AgentStore.prepare()
        let descriptor = open(AgentStore.directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleScan() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directorySource = source
        scan()
    }

    func stop() {
        directorySource?.cancel()
        directorySource = nil
        exitSources.values.forEach { $0.cancel() }
        exitSources.removeAll()
        expiryTimer?.cancel()
        expiryTimer = nil
        publish(0)
    }

    private func scheduleScan() {
        guard !pendingScan else { return }
        pendingScan = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pendingScan = false
            self?.scan()
        }
    }

    private func scan() {
        guard directorySource != nil else { return }
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: AgentStore.directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        let now = Date()
        var live: Set<pid_t> = []
        var working = 0
        var earliestExpiry: Date?

        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let pid = (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            let expiry = modified.addingTimeInterval(AgentStore.staleAfter)
            guard pid > 1, isAlive(pid), expiry > now else {
                try? manager.removeItem(at: file)
                continue
            }
            working += 1
            live.insert(pid)
            watch(pid)
            earliestExpiry = min(earliestExpiry ?? expiry, expiry)
        }

        for (pid, source) in exitSources where !live.contains(pid) {
            source.cancel()
            exitSources[pid] = nil
        }
        scheduleExpiry(earliestExpiry)
        publish(working)
    }

    private func publish(_ count: Int) {
        guard count != workingCount else { return }
        workingCount = count
        onChange?(count)
    }

    private func watch(_ pid: pid_t) {
        guard exitSources[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.scan() }
        source.resume()
        exitSources[pid] = source
    }

    private func scheduleExpiry(_ date: Date?) {
        expiryTimer?.cancel()
        expiryTimer = nil
        guard let date else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + max(1, date.timeIntervalSinceNow), leeway: .seconds(30))
        timer.setEventHandler { [weak self] in self?.scan() }
        timer.resume()
        expiryTimer = timer
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

enum AgentIntegration: String, CaseIterable {
    case claude, codex, opencode

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    private var configURL: URL {
        switch self {
        case .claude: Self.home.appendingPathComponent(".claude/settings.json")
        case .codex: Self.home.appendingPathComponent(".codex/hooks.json")
        case .opencode: Self.home.appendingPathComponent(".config/opencode/plugins/stillwake.js")
        }
    }

    private var events: [(name: String, matcher: String?)] {
        switch self {
        case .claude:
            [("UserPromptSubmit", nil), ("PostToolUse", nil), ("Stop", nil), ("StopFailure", nil), ("SessionEnd", nil), ("Notification", "idle_prompt")]
        case .codex:
            [("UserPromptSubmit", nil), ("PostToolUse", nil), ("Stop", nil), ("SessionEnd", nil)]
        case .opencode:
            []
        }
    }

    var isAvailable: Bool {
        let parent = configURL.deletingLastPathComponent().path
        let root = self == .opencode ? Self.home.appendingPathComponent(".config/opencode").path : parent
        return FileManager.default.fileExists(atPath: root)
    }

    var isConnected: Bool {
        if self == .opencode { return FileManager.default.fileExists(atPath: configURL.path) }
        guard let root = try? readJSON(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { groups in
            (groups as? [[String: Any]])?.contains { Self.isOwn($0) } ?? false
        }
    }

    private var helperCommand: String {
        "\(Bundle.main.executablePath ?? "/Applications/Stillwake.app/Contents/MacOS/Stillwake") hook --provider \(rawValue)"
    }

    func connect() throws {
        if self == .opencode {
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try openCodePlugin.write(to: configURL, atomically: true, encoding: .utf8)
            return
        }
        try editJSON { root in
            var hooks = Self.withoutOwn(root["hooks"] as? [String: Any] ?? [:])
            for event in events {
                var group: [String: Any] = ["hooks": [["type": "command", "command": helperCommand, "timeout": 5]]]
                if let matcher = event.matcher { group["matcher"] = matcher }
                hooks[event.name] = (hooks[event.name] as? [[String: Any]] ?? []) + [group]
            }
            root["hooks"] = hooks
        }
    }

    func disconnect() throws {
        if self == .opencode {
            try? FileManager.default.removeItem(at: configURL)
            return
        }
        try editJSON { root in
            let hooks = Self.withoutOwn(root["hooks"] as? [String: Any] ?? [:])
            root["hooks"] = hooks.isEmpty ? nil : hooks
        }
    }

    private static func isOwn(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains { hook in
            let command = hook["command"] as? String ?? ""
            return command.contains("Stillwake") && command.contains(" hook --provider ")
        } ?? false
    }

    private static func withoutOwn(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept = groups.filter { !isOwn($0) }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private func readJSON() throws -> [String: Any] {
        let url = configURL.resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return root
    }

    private func editJSON(_ edit: (inout [String: Any]) -> Void) throws {
        let url = configURL.resolvingSymlinksInPath()
        var root = try readJSON()
        let backup = url.appendingPathExtension("stillwake-backup")
        if FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        edit(&root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    private var openCodePlugin: String {
        let helper = (Bundle.main.executablePath ?? "/Applications/Stillwake.app/Contents/MacOS/Stillwake")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        import { spawn } from "node:child_process"

        const HELPER = "\(helper)"
        const PROGRESS_INTERVAL_MS = 60_000
        const lastProgress = new Map()

        function report(eventName, sessionID) {
          if (!sessionID || typeof sessionID !== "string") return
          if (eventName === "Progress") {
            const now = Date.now()
            if (now - (lastProgress.get(sessionID) ?? 0) < PROGRESS_INTERVAL_MS) return
            lastProgress.set(sessionID, now)
          } else if (eventName !== "UserPromptSubmit") {
            lastProgress.delete(sessionID)
          }
          try {
            const child = spawn(HELPER, ["hook", "--provider", "opencode"], { stdio: ["pipe", "ignore", "ignore"] })
            child.on("error", () => {})
            child.stdin.on("error", () => {})
            child.stdin.end(JSON.stringify({ hook_event_name: eventName, session_id: sessionID.slice(0, 256) }))
          } catch {}
        }

        export const StillwakePlugin = async () => ({
          "chat.message": async (input) => report("UserPromptSubmit", input?.sessionID),
          "tool.execute.after": async (input) => report("Progress", input?.sessionID),
          event: async ({ event }) => {
            const p = event?.properties ?? {}
            switch (event?.type) {
              case "session.idle": report("Stop", p.sessionID); break
              case "session.error": report("Stop", p.sessionID); break
              case "session.deleted": report("SessionEnd", p.sessionID ?? p.info?.id); break
            }
          },
        })

        """
    }

    static func runCommand(_ arguments: [String]) -> Int32 {
        guard let verb = arguments.first else { return 64 }
        let names = arguments.dropFirst()
        let targets = names.isEmpty || names.contains("all") ? allCases.filter(\.isAvailable) : names.compactMap(AgentIntegration.init(rawValue:))
        var status: Int32 = 0
        for target in targets {
            do {
                try verb == "connect" ? target.connect() : target.disconnect()
                print("\(target.title): \(verb == "connect" ? "connected" : "disconnected")")
            } catch {
                print("\(target.title): \(error.localizedDescription)")
                status = 1
            }
        }
        return status
    }
}

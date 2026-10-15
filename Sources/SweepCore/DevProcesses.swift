import Darwin
import Foundation

/// A developer process running as you: a dev server, MCP server, model server, language server or similar.
public struct DevProcess: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case server, ai, mcp, editorHelper, database, build, runtime

        public var title: String {
            switch self {
            case .server: "Dev server"
            case .ai: "AI model"
            case .mcp: "MCP server"
            case .editorHelper: "Editor helper"
            case .database: "Database"
            case .build: "Watcher"
            case .runtime: "Script"
            }
        }
    }

    public var id: Int32 { pid }
    public let pid: Int32
    public let parentPID: Int32
    public let name: String
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?
    public var ports: [Int]
    public let memoryBytes: Int64
    public let started: Date?
    public var kind: Kind
    /// The app this process belongs to, such as "Visual Studio Code", when it was started by one.
    public var ownerApp: String?
    /// Still running although the terminal or app that started it is gone.
    public var isLeftover: Bool
    /// How many processes run this exact command in this folder.
    public var copies: Int

    public var commandLine: String { arguments.joined(separator: " ") }

    /// A short, readable label such as "tsx watch server.ts" or "uvicorn main:app".
    public var displayName: String {
        let base = (executable as NSString).lastPathComponent
        let valueFlags: Set<String> = ["--require", "-r", "--import", "--loader", "--experimental-loader", "-c"]
        var words: [String] = []
        var tool: String?
        var skipNext = false
        for argument in arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            if valueFlags.contains(argument) { skipNext = true; continue }
            if argument.hasPrefix("-") { continue }
            if let range = argument.range(of: "/node_modules/", options: .backwards) {
                let parts = argument[range.upperBound...].split(separator: "/").map(String.init)
                let meaningful = parts.filter { $0 != ".bin" && $0 != ".." && $0 != "." && !$0.hasPrefix("@") }
                if tool == nil, let package = meaningful.first { tool = package }
                continue
            }
            let word = (argument as NSString).lastPathComponent
            if !word.isEmpty, word != ".", word != ".." { words.append(word) }
        }
        if commandLine.contains("multiprocessing") { return "\(base) worker" }
        if let module = arguments.firstIndex(of: "-m"), arguments.indices.contains(module + 1) {
            return ([arguments[module + 1]] + words.dropFirst().prefix(2)).joined(separator: " ")
        }
        let head = tool ?? (["node", "bun", "deno", "python", "python3", "Python", "ruby", "php"].contains(base) || base.hasPrefix("python")
            ? (words.first ?? base) : base)
        let rest = tool != nil || head == base ? words.prefix(3) : words.dropFirst().prefix(3)
        let name = ([head] + rest).filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? base : name
    }
}

public enum DevProcesses {
    static let runtimeNames: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "php", "java", "dotnet", "beam.smp", "elixir", "erl",
        "uvicorn", "gunicorn", "hypercorn", "celery", "flask", "rails", "puma", "esbuild", "vite", "tsx", "ts-node",
        "nodemon", "next-server", "turbo", "air", "cargo", "go", "watchexec",
    ]
    static let databaseNames: Set<String> = ["postgres", "mysqld", "mariadbd", "redis-server", "mongod", "clickhouse", "valkey-server", "memcached"]
    static let aiNames: Set<String> = ["ollama", "llama-server", "llama-cli", "lms", "mlx_lm.server", "vllm", "koboldcpp"]
    static let editorHelperMarkers = [
        "tsserver", "typescript-language-server", "pyright", "pylsp", "jedi-language-server", "ruff server", "rust-analyzer",
        "gopls", "sourcekit-lsp", "eslintServer", "tailwindServer", "languageserver", "language-server", "copilot", "jsonServerMain",
        "serverWorkerMain", "markdown-language-features",
    ]
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "nu", "login", "tmux", "screen"]

    struct Raw {
        let pid: Int32
        let parentPID: Int32
        let name: String
        let path: String
        let arguments: [String]
        let startSeconds: UInt64
        let memory: Int64
    }

    /// Every developer process you own, with ports, owner app, leftover and duplicate flags.
    public static func snapshot() -> [DevProcess] {
        let raws = allProcesses()
        let byPID = Dictionary(uniqueKeysWithValues: raws.map { ($0.pid, $0) })
        let ports = listeningPorts()
        let ownPID = getpid()
        let ownAncestors = ancestors(of: ownPID, in: byPID)

        var found: [DevProcess] = []
        for raw in raws where raw.pid != ownPID && !ownAncestors.contains(raw.pid) {
            guard let kind = classify(raw, hasPorts: ports[raw.pid] != nil) else { continue }
            let origin = origin(of: raw, in: byPID)
            let owner = origin.app.map { origin.viaShell ? "\($0) terminal" : $0 }
            let startedByApp = origin.app != nil && !origin.viaShell
            let leftover = raw.parentPID == 1 && origin.app == nil && kind != .database && kind != .ai
            found.append(DevProcess(
                pid: raw.pid, parentPID: raw.parentPID, name: raw.name, executable: raw.path, arguments: raw.arguments,
                workingDirectory: workingDirectory(of: raw.pid), ports: (ports[raw.pid] ?? []).sorted(),
                memoryBytes: raw.memory,
                started: raw.startSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(raw.startSeconds)) : nil,
                kind: startedByApp && kind != .mcp ? .editorHelper : kind,
                ownerApp: owner, isLeftover: leftover, copies: 1
            ))
        }

        let groups = Dictionary(grouping: found) { "\($0.commandLine)|\($0.workingDirectory ?? "")" }
        for index in found.indices {
            found[index].copies = groups["\(found[index].commandLine)|\(found[index].workingDirectory ?? "")"]?.count ?? 1
        }
        return found.sorted { ($0.ports.isEmpty ? 1 : 0, -$0.memoryBytes) < ($1.ports.isEmpty ? 1 : 0, -$1.memoryBytes) }
    }

    /// Which kind of developer process this is, or nil when it isn't one.
    static func classify(_ raw: Raw, hasPorts: Bool) -> DevProcess.Kind? {
        let base = (raw.path as NSString).lastPathComponent
        let command = raw.arguments.joined(separator: " ")
        let lowered = command.lowercased()
        if raw.path.hasPrefix("/System/") || raw.path.hasPrefix("/usr/libexec/") || raw.path.hasPrefix("/usr/sbin/")
            || raw.path.hasPrefix("/sbin/") || shells.contains(base) { return nil }

        if databaseNames.contains(base) { return .database }
        if aiNames.contains(base) || lowered.contains("ollama serve") || lowered.contains("llama.cpp") || lowered.contains("mlx_lm") { return .ai }
        if lowered.contains("mcp") && (lowered.contains("server") || lowered.contains("_mcp") || lowered.contains("mcp-") || lowered.contains("/mcp")) {
            return .mcp
        }
        if editorHelperMarkers.contains(where: { command.contains($0) }) { return .editorHelper }

        let isRuntime = runtimeNames.contains(base) || base.hasPrefix("python") || base == "Python"
            || raw.path.contains("/node_modules/.bin/") || raw.path.contains("/go-build")
        guard isRuntime else { return nil }
        if hasPorts { return .server }
        if ["watch", "nodemon", "--watch", "dev", "serve", "esbuild", "vite", "turbo"].contains(where: { lowered.contains($0) }) { return .build }
        return .runtime
    }

    /// The app that started this process and whether a terminal shell sits in between.
    static func origin(of raw: Raw, in byPID: [Int32: Raw]) -> (app: String?, viaShell: Bool) {
        if let app = appName(raw.path) { return (app, false) }
        var viaShell = false
        var current = byPID[raw.parentPID]
        var steps = 0
        while let process = current, process.pid > 1, steps < 32 {
            if shells.contains((process.path as NSString).lastPathComponent) || shells.contains(process.name) { viaShell = true }
            if let app = appName(process.path) { return (app, viaShell) }
            current = byPID[process.parentPID]
            steps += 1
        }
        return (nil, viaShell)
    }

    /// The app name when `path` is inside an app installed in an Applications folder (not, e.g., Homebrew's Python.app).
    static func appName(_ path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/") else { return nil }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        let folder = (bundle as NSString).deletingLastPathComponent
        let allowed = ["/Applications", "/System/Applications", "\(NSHomeDirectory())/Applications", "/Applications/Utilities"]
        guard allowed.contains(folder) else { return nil }
        return ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func ancestors(of pid: Int32, in byPID: [Int32: Raw]) -> Set<Int32> {
        var result: Set<Int32> = []
        var current = byPID[pid]?.parentPID
        while let parent = current, parent > 1, !result.contains(parent) {
            result.insert(parent)
            current = byPID[parent]?.parentPID
        }
        return result
    }

    // MARK: Reading processes

    static func allProcesses() -> [Raw] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let uid = getuid()
        return pids.prefix(Int(max(count, 0))).compactMap { pid -> Raw? in
            guard pid > 0, let info = bsdInfo(pid), info.pbi_uid == uid else { return nil }
            let name = withUnsafeBytes(of: info.pbi_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return Raw(pid: pid, parentPID: Int32(info.pbi_ppid), name: name, path: executablePath(pid),
                       arguments: arguments(of: pid), startSeconds: info.pbi_start_tvsec, memory: residentMemory(pid))
        }
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func executablePath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }

    static func residentMemory(_ pid: pid_t) -> Int64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? Int64(info.pti_resident_size) : 0
    }

    /// The process's arguments, read with sysctl(KERN_PROCARGS2).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }

        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var result: [String] = []
        var start = index
        while index < size, result.count < argc {
            if buffer[index] == 0 {
                result.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return result
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.count > 1 ? path : nil
    }

    /// Listening TCP ports per process, from lsof.
    static func listeningPorts() -> [Int32: Set<Int>] {
        let result = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"], timeout: 10)
        return parsePorts(result.output)
    }

    static func parsePorts(_ output: String) -> [Int32: Set<Int>] {
        var ports: [Int32: Set<Int>] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid, let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) {
                ports[pid, default: []].insert(port)
            }
        }
        return ports
    }

    // MARK: Stopping

    public struct StopResult: Sendable {
        public let stopped: [Int32]
        public let stillRunning: [Int32]
        public let refused: [Int32: String]
    }

    /// Stops processes and their children. Each one is re-identified first, so a reused PID never hits another program.
    public static func stop(_ targets: [DevProcess], force: Bool = false, grace: TimeInterval = 3) -> StopResult {
        let raws = allProcesses()
        let byPID = Dictionary(uniqueKeysWithValues: raws.map { ($0.pid, $0) })
        let protected = ancestors(of: getpid(), in: byPID).union([getpid(), 1, 0])
        var refused: [Int32: String] = [:]
        var victims: [Int32] = []

        for target in targets {
            guard let raw = byPID[target.pid] else {
                refused[target.pid] = "Already stopped"
                continue
            }
            let sameStart = target.started.map { UInt64($0.timeIntervalSince1970) == raw.startSeconds } ?? false
            guard sameStart, raw.path == target.executable else {
                refused[target.pid] = "A different program now uses this process ID"
                continue
            }
            guard !protected.contains(raw.pid) else {
                refused[target.pid] = "Protected"
                continue
            }
            victims.append(raw.pid)
            victims += descendants(of: raw.pid, in: raws).filter { !protected.contains($0) }
        }

        let unique = Array(Set(victims))
        for pid in unique { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, unique.contains(where: isAlive) { usleep(100_000) }
        if force {
            for pid in unique where isAlive(pid) { kill(pid, SIGKILL) }
            usleep(200_000)
        }
        let requested = Set(targets.map(\.pid))
        let alive = unique.filter { requested.contains($0) && isAlive($0) }
        let stopped = unique.filter { requested.contains($0) && !isAlive($0) }
        return StopResult(stopped: stopped, stillRunning: alive, refused: refused)
    }

    static func descendants(of pid: Int32, in raws: [Raw]) -> [Int32] {
        var result: [Int32] = []
        var frontier = [pid]
        while let current = frontier.popLast() {
            let children = raws.filter { $0.parentPID == current }.map(\.pid)
            result += children
            frontier += children
        }
        return result
    }

    /// Running and not a zombie that's only waiting for its parent to collect it.
    static func isAlive(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let info = bsdInfo(pid) else { return true }
        return info.pbi_status != UInt32(SZOMB)
    }

    /// Developer processes whose working folder is inside `path`, split into ones that block cleaning and editor helpers.
    public static func users(of path: String, among processes: [DevProcess]) -> (blocking: [DevProcess], helpers: [DevProcess]) {
        let resolved = path.resolvedPath
        let inside = processes.filter { process in
            guard let cwd = process.workingDirectory else { return false }
            return cwd.isInside(resolved) || cwd.isInside(path)
        }
        return (inside.filter { $0.kind != .editorHelper }, inside.filter { $0.kind == .editorHelper })
    }
}

/// What's running right now, used to decide whether a project is in use.
public struct ProcessContext: Sendable {
    /// Every process with a working folder, except editor helpers such as language servers.
    public let processes: [RunningProcess]
    public let devProcesses: [DevProcess]

    public static func current() -> ProcessContext {
        let devs = DevProcesses.snapshot()
        let helpers = Set(devs.filter { $0.kind == .editorHelper }.map(\.pid))
        return ProcessContext(processes: ProcessInspector.runningProcesses().filter { !helpers.contains($0.pid) }, devProcesses: devs)
    }

    /// The process keeping `path` busy and a readable reason, e.g. "In use by tsx watch server.ts on :3000 (PID 4182)".
    public func blocker(for path: String) -> (process: RunningProcess, label: String, reason: String)? {
        guard let user = ProcessInspector.user(of: path, among: processes) else { return nil }
        guard let dev = devProcesses.first(where: { $0.pid == user.pid }) else {
            return (user, user.name, "In use by \(user.name) (PID \(user.pid))")
        }
        let ports = dev.ports.isEmpty ? "" : " on " + dev.ports.map { ":\($0)" }.joined(separator: ", ")
        let leftover = dev.isLeftover ? ". It was left running after its terminal closed; stop it in Processes" : ""
        return (user, dev.displayName, "In use by \(dev.displayName)\(ports) (PID \(dev.pid))\(leftover)")
    }

    public func shell(in path: String) -> RunningProcess? {
        ProcessInspector.shell(in: path, among: processes)
    }
}

extension DevProcesses {
    /// Who is listening on a TCP port, including processes that aren't developer tools.
    public static func owner(ofPort port: Int) -> (pid: Int32, name: String)? {
        let result = Shell.run("/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "pc"], timeout: 10)
        var pid: Int32?
        for line in result.output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            if line.hasPrefix("c"), let pid { return (pid, String(line.dropFirst())) }
        }
        return nil
    }
}

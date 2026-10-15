import Darwin
import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
    public let timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Runs command-line tools without a shell, with a timeout and a usable PATH.
public enum Shell {
    public static func run(_ executable: String, _ arguments: [String], in directory: String? = nil, timeout: TimeInterval = 30, stdin: URL? = nil) -> ShellResult {
        var environment = ProcessInfo.processInfo.environment
        let toolDirectory = (executable as NSString).deletingLastPathComponent
        environment["PATH"] = ([toolDirectory] + ToolLocator.searchDirectories).joined(separator: ":")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["CI"] = "1"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NPM_CONFIG_UPDATE_NOTIFIER"] = "false"
        environment["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        environment["DOCKER_CLI_HINTS"] = "false"

        var outFDs: [Int32] = [-1, -1]
        var errFDs: [Int32] = [-1, -1]
        guard pipe(&outFDs) == 0 else { return failure("Couldn't create a pipe") }
        guard pipe(&errFDs) == 0 else {
            close(outFDs[0]); close(outFDs[1])
            return failure("Couldn't create a pipe")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, stdin?.path ?? "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outFDs[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errFDs[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory ?? neutralDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Close every other descriptor in the child, so no command inherits another command's pipes.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(outFDs[1])
        close(errFDs[1])
        guard spawned == 0 else {
            close(outFDs[0]); close(errFDs[0])
            return failure(String(cString: strerror(spawned)))
        }

        let collected = collect(pid: pid, out: outFDs[0], err: errFDs[0], timeout: timeout)
        let raw = collected.status
        let status: Int32 = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
        return ShellResult(
            status: collected.exited ? status : -1,
            output: String(decoding: collected.output, as: UTF8.self),
            error: String(decoding: collected.error, as: UTF8.self),
            timedOut: collected.timedOut || !collected.complete
        )
    }

    /// Reads both pipes and waits for the process on the calling thread, so no extra threads are needed.
    private static func collect(pid: pid_t, out: Int32, err: Int32, timeout: TimeInterval)
        -> (output: Data, error: Data, status: Int32, exited: Bool, timedOut: Bool, complete: Bool) {
        var output = Data()
        var error = Data()
        var open: [Int32: Bool] = [out: true, err: true]
        var status: Int32 = 0
        var exited = false
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        var exitedAt: Date?
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            if !exited, waitpid(pid, &status, WNOHANG) == pid {
                exited = true
                exitedAt = Date()
            }
            let readable = open.filter(\.value).map(\.key)
            if exited, readable.isEmpty { break }
            // A background process that kept the pipe open shouldn't hold us forever after the command ended.
            if let exitedAt, Date().timeIntervalSince(exitedAt) > 2 { break }
            if !timedOut, Date() > deadline {
                timedOut = true
                kill(-pid, SIGTERM)
                kill(pid, SIGTERM)
                let grace = Date().addingTimeInterval(2)
                while waitpid(pid, &status, WNOHANG) != pid, Date() < grace { usleep(20_000) }
                if waitpid(pid, &status, WNOHANG) == 0 {
                    kill(-pid, SIGKILL)
                    kill(pid, SIGKILL)
                    waitpid(pid, &status, 0)
                }
                exited = true
                exitedAt = Date()
            }

            guard !readable.isEmpty else {
                usleep(10_000)
                continue
            }
            var fds = readable.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&fds, nfds_t(fds.count), 50)
            if ready < 0, errno != EINTR { break }
            for entry in fds where entry.revents != 0 {
                let count = read(entry.fd, &buffer, buffer.count)
                if count > 0 {
                    if entry.fd == out { output.append(buffer, count: count) } else { error.append(buffer, count: count) }
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    open[entry.fd] = false
                }
            }
        }

        let complete = !open.values.contains(true)
        close(out)
        close(err)
        return (output, error, status, exited, timedOut, complete)
    }

    private static func failure(_ message: String) -> ShellResult {
        ShellResult(status: -1, output: "", error: message, timedOut: false)
    }

    /// An empty folder tools run in, so none of them picks up a project's config.
    public static let neutralDirectory: String = {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("DevSweep-run")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    public static func git(_ arguments: [String], in directory: String, timeout: TimeInterval = 20, stdin: URL? = nil) -> ShellResult {
        guard developerToolsInstalled else { return failure("Command Line Tools aren't installed") }
        return run("/usr/bin/git", ["-C", directory] + arguments, timeout: timeout, stdin: stdin)
    }

    /// Runs xcrun only when developer tools exist, since the /usr/bin stub otherwise pops up an install dialog.
    public static func xcrun(_ arguments: [String], timeout: TimeInterval = 30) -> ShellResult {
        guard developerToolsInstalled else { return failure("Xcode isn't installed") }
        return run("/usr/bin/xcrun", arguments, timeout: timeout)
    }

    /// Whether Xcode or the Command Line Tools are installed; xcode-select never shows the install dialog.
    public static let developerToolsInstalled: Bool = {
        let result = run("/usr/bin/xcode-select", ["-p"], timeout: 5)
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }()
}

/// Finds developer tools even when the app was launched from Finder with a minimal PATH.
public enum ToolLocator {
    private static let cache = LockedCache<String, String?>()

    static var searchDirectories: [String] {
        let home = NSHomeDirectory()
        var directories = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.bun/bin", "\(home)/.cargo/bin", "\(home)/.local/bin", "\(home)/.volta/bin",
            "\(home)/Library/pnpm", "\(home)/.deno/bin", "\(home)/go/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
        ]
        directories.insert(contentsOf: nodeVersionDirectories, at: 0)
        return directories
    }

    private static var nodeVersionDirectories: [String] {
        let home = NSHomeDirectory()
        var found: [String] = []
        for base in ["\(home)/.nvm/versions/node", "\(home)/.local/state/fnm_multishells", "\(home)/Library/Application Support/fnm/node-versions"] {
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for version in sorted {
                for candidate in ["\(base)/\(version)/bin", "\(base)/\(version)/installation/bin"] where FileManager.default.fileExists(atPath: candidate) {
                    found.append(candidate)
                }
            }
        }
        return found
    }

    public static func find(_ tool: String) -> String? {
        if let cached = cache.value(for: tool) { return cached }
        let found = locate(tool)
        cache.set(found, for: tool)
        return found
    }

    private static func locate(_ tool: String) -> String? {
        let fileManager = FileManager.default
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in pathDirectories + searchDirectories {
            let candidate = "\(directory)/\(tool)"
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        let shell = run("/bin/zsh", ["-l", "-c", "command -v \(tool)"], timeout: 5)
        let path = shell.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if shell.succeeded, path.hasPrefix("/"), fileManager.isExecutableFile(atPath: path) { return path }
        return nil
    }

    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ShellResult {
        Shell.run(executable, arguments, timeout: timeout)
    }
}

final class LockedCache<Key: Hashable, Value>: @unchecked Sendable {
    private var storage: [Key: Value] = [:]
    private let lock = NSLock()

    func value(for key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: Value, for key: Key) {
        lock.lock()
        storage[key] = value
        lock.unlock()
    }
}

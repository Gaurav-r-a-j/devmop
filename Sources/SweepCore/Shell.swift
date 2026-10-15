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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory ?? neutralDirectory)

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
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let stdin, let handle = try? FileHandle(forReadingFrom: stdin) {
            process.standardInput = handle
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let outCollector = PipeCollector(outPipe.fileHandleForReading)
        let errCollector = PipeCollector(errPipe.fileHandleForReading)

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, output: "", error: error.localizedDescription, timedOut: false)
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
        }

        return ShellResult(
            status: process.terminationStatus,
            output: outCollector.finish(),
            error: errCollector.finish(),
            timedOut: timedOut
        )
    }

    /// An empty folder tools run in, so none of them picks up a project's config.
    public static let neutralDirectory: String = {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("DevSweep-run")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    public static func git(_ arguments: [String], in directory: String, timeout: TimeInterval = 20, stdin: URL? = nil) -> ShellResult {
        run("/usr/bin/git", ["-C", directory] + arguments, timeout: timeout, stdin: stdin)
    }
}

private final class PipeCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let all = handle.readDataToEndOfFile()
            lock.lock()
            data = all
            lock.unlock()
            done.signal()
        }
    }

    func finish() -> String {
        _ = done.wait(timeout: .now() + 5)
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
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

import Darwin
import Foundation
import Testing
@testable import SweepCore

struct ProcessTests {
    private func raw(_ path: String, _ arguments: [String], parent: Int32 = 1) -> DevProcesses.Raw {
        DevProcesses.Raw(pid: 999, parentPID: parent, name: (path as NSString).lastPathComponent, path: path,
                         arguments: arguments, startSeconds: 0, memory: 0)
    }

    @Test func portsAreParsedFromLsof() {
        let output = "p612\nn*:58340\nn127.0.0.1:8010\np700\nn[::1]:5173\n"
        let ports = DevProcesses.parsePorts(output)
        #expect(ports[612] == [58340, 8010])
        #expect(ports[700] == [5173])
    }

    @Test func classificationSeparatesServersHelpersAndSystem() {
        #expect(DevProcesses.classify(raw("/usr/local/bin/node", ["node", "server.js"]), hasPorts: true) == .server)
        #expect(DevProcesses.classify(raw("/usr/local/bin/node", ["node", "/x/tsserver.js"]), hasPorts: false) == .editorHelper)
        #expect(DevProcesses.classify(raw("/opt/homebrew/bin/postgres", ["postgres"]), hasPorts: true) == .database)
        #expect(DevProcesses.classify(raw("/opt/homebrew/bin/ollama", ["ollama", "serve"]), hasPorts: true) == .ai)
        #expect(DevProcesses.classify(raw("/usr/bin/python3", ["python3", "orders_mcp.py"]), hasPorts: true) == .mcp)
        #expect(DevProcesses.classify(raw("/System/Library/CoreServices/x", ["x"]), hasPorts: true) == nil)
        #expect(DevProcesses.classify(raw("/bin/zsh", ["zsh"]), hasPorts: false) == nil)
        #expect(DevProcesses.classify(raw("/Applications/Notes.app/Contents/MacOS/Notes", ["Notes"]), hasPorts: false) == nil)
    }

    @Test func onlyRealApplicationsCountAsOwners() {
        #expect(DevProcesses.appName("/Applications/Visual Studio Code.app/Contents/MacOS/Electron") == "Visual Studio Code")
        #expect(DevProcesses.appName("/opt/homebrew/Cellar/python@3.12/3.12.14/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python") == nil)
    }

    @Test func displayNamesAreReadable() {
        func name(_ arguments: [String], _ executable: String = "/usr/local/bin/node") -> String {
            DevProcess(pid: 1, parentPID: 1, name: "", executable: executable, arguments: arguments, workingDirectory: nil, ports: [],
                       memoryBytes: 0, started: nil, kind: .runtime, ownerApp: nil, isLeftover: false, copies: 1).displayName
        }
        #expect(name(["node", "./node_modules/.bin/../tsx/dist/cli.mjs", "watch", "--env-file=../../.env", "src/server.ts"]) == "tsx watch server.ts")
        #expect(name(["node", "/a/node_modules/.pnpm/expo@54/node_modules/expo/bin/cli", "start", "--port", "8082"]) == "expo start 8082")
        #expect(name(["python3", "-m", "uvicorn", "main:app"], "/usr/bin/python3") == "uvicorn main:app")
        #expect(name(["python3", "../demo/orders_mcp.py"], "/usr/bin/python3") == "orders_mcp.py")
    }

    @Test func stopRefusesReusedProcessIDsAndStopsChildren() throws {
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "/bin/sleep 30 & wait"]
        try parent.run()
        defer { if parent.isRunning { parent.terminate() } }
        usleep(300_000)

        let pid = parent.processIdentifier
        guard let info = DevProcesses.bsdInfo(pid) else { return }
        let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
        let raws = DevProcesses.allProcesses()
        let children = DevProcesses.descendants(of: pid, in: raws)
        #expect(!children.isEmpty)

        func target(started: Date) -> DevProcess {
            DevProcess(pid: pid, parentPID: getpid(), name: "sh", executable: DevProcesses.executablePath(pid), arguments: [], workingDirectory: nil,
                       ports: [], memoryBytes: 0, started: started, kind: .runtime, ownerApp: nil, isLeftover: false, copies: 1)
        }

        let refused = DevProcesses.stop([target(started: started.addingTimeInterval(-500))], grace: 0.2)
        #expect(refused.refused[pid] != nil)
        #expect(DevProcesses.isAlive(pid))

        let stopped = DevProcesses.stop([target(started: started)], force: true, grace: 1)
        #expect(stopped.stopped == [pid])
        usleep(200_000)
        #expect(children.allSatisfy { !DevProcesses.isAlive($0) || DevProcesses.bsdInfo($0) == nil })
    }
}

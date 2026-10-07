import Foundation

public struct Machine: Codable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let target: String
    public let session: String
    public let enabled: Bool
}

public enum ConnectionState: String, Sendable {
    case checking = "확인 중"
    case ready = "연결 가능"
    case unreachable = "접속 불가"
    case serverStopped = "Herdr 서버 응답 없음"
    case disabled = "Herdr 연결 꺼짐"
    case reconnecting = "재연결 중"
}

public struct CommandResult: Sendable {
    public let code: Int32
    public let output: String
    public init(code: Int32, output: String) { self.code = code; self.output = output }
}

public enum Policy {
    public static func state(ssh: CommandResult, enabled: Bool) -> ConnectionState {
        if ssh.code != 0 { return .unreachable }
        if !ssh.output.contains("status: running") || !ssh.output.contains("endpoint_compatible: yes") {
            return .serverStopped
        }
        return enabled ? .ready : .disabled
    }
}

public enum Command {
    // Separate arguments throughout: host labels and output never become shell code.
    @concurrent public static func run(_ executable: String, _ arguments: [String], timeout: Double = 15) async -> CommandResult {
        guard !Task.isCancelled else { return .init(code: 130, output: "작업 취소됨") }
        let process = Process()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: path.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: path) else {
            return CommandResult(code: -1, output: "임시 출력 파일을 만들 수 없습니다.")
        }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: path) }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() } catch { return CommandResult(code: -1, output: error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Task.isCancelled || Date() > deadline {
                timedOut = true
                process.terminate()
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if timedOut {
            for _ in 0..<10 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let reader = try? FileHandle(forReadingFrom: path)
        defer { try? reader?.close() }
        let data = (try? reader?.read(upToCount: 128_000)) ?? Data()
        let output = String(decoding: data, as: UTF8.self)
        return CommandResult(code: timedOut ? 124 : process.terminationStatus,
                             output: timedOut ? "접속 제한시간 초과" : output)
    }
}

public enum Reconnection {
    public typealias Runner = @Sendable (String, [String]) async -> CommandResult
    public static func sshArguments(_ machine: Machine) -> [String]? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !machine.session.isEmpty, machine.session.allSatisfy(allowed.contains),
              !machine.target.isEmpty, !machine.target.hasPrefix("-") else { return nil }
        return ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=3",
                "-o", "ServerAliveCountMax=2", machine.target,
                "~/.local/bin/herdr --session \(machine.session) status server"]
    }

    public static func run(_ machine: Machine, herdr: String, runner: Runner) async -> CommandResult {
        guard let ssh = sshArguments(machine) else { return .init(code: -1, output: "SSH 대상 또는 세션 이름이 올바르지 않습니다.") }
        let before = await runner("/usr/bin/ssh", ssh)
        guard Policy.state(ssh: before, enabled: true) == .ready else {
            return .init(code: -1, output: "원격 서버가 응답하지 않아 연결 갱신을 실행하지 않았습니다.")
        }
        if machine.enabled {
            let disabled = await runner(herdr, ["machine", "disable", machine.id])
            guard disabled.code == 0 else { return .init(code: -1, output: "Herdr 연결 갱신 실패") }
        }
        var enabled = await runner(herdr, ["machine", "enable", machine.id])
        if enabled.code != 0 {
            // One bounded retry restores a profile disabled by this operation.
            enabled = await runner(herdr, ["machine", "enable", machine.id])
        }
        guard enabled.code == 0 else { return .init(code: -1, output: "Herdr 연결 켜기 실패 · 다시 재연결해주세요.") }
        let after = await runner("/usr/bin/ssh", ssh)
        guard Policy.state(ssh: after, enabled: true) == .ready else {
            return .init(code: -1, output: "Herdr 연결을 켰지만 원격 서버 응답이 확인되지 않았습니다.")
        }
        return .init(code: 0, output: "연결 갱신 완료 · 원격 서버 응답 확인")
    }
}

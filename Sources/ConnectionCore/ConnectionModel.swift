import Foundation
import Observation

@MainActor @Observable public final class ConnectionModel {
    public var machines: [Machine] = []
    public var states: [String: ConnectionState] = [:]
    public var details: [String: String] = [:]
    public var busy = false
    public var message = "등록된 Herdr 연결을 불러옵니다."
    public var updated: Date?
    private let runner: Reconnection.Runner
    private let herdr = "/opt/homebrew/bin/herdr"

    public init(autoRefresh: Bool = true,
                runner: @escaping Reconnection.Runner = { executable, arguments in
                    await Command.run(executable, arguments, timeout: 12)
                }) {
        self.runner = runner
        if autoRefresh {
            Task { [weak self] in
                while !Task.isCancelled {
                    if let self {
                        await self.refresh()
                    } else { return }
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    public func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false; updated = Date() }
        guard await loadRegistry() else { return }
        for machine in machines {
            states[machine.id] = .checking
            await check(machine)
        }
        message = "\(machines.count)개 연결 확인 · 서버 응답 기준"
    }

    @discardableResult private func loadRegistry() async -> Bool {
        let list = await runner(herdr, ["machine", "list", "--json"])
        guard list.code == 0, let data = list.output.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Machine].self, from: data) else {
            states = states.mapValues { _ in .unreachable }
            message = "Herdr 등록 목록을 읽지 못했습니다. 로컬 Herdr가 실행 중인지 확인해주세요."
            return false
        }
        machines = decoded
        states = states.filter { key, _ in decoded.contains { $0.id == key } }
        details = details.filter { key, _ in decoded.contains { $0.id == key } }
        return true
    }

    private func check(_ machine: Machine) async {
        guard let arguments = Reconnection.sshArguments(machine) else {
            states[machine.id] = .unreachable
            details[machine.id] = "등록된 SSH 대상 또는 세션 이름을 확인해주세요."
            return
        }
        let ssh = await runner("/usr/bin/ssh", arguments)
        states[machine.id] = Policy.state(ssh: ssh, enabled: machine.enabled)
        details[machine.id] = states[machine.id] == .ready || states[machine.id] == .disabled
            ? "SSH와 Herdr 서버 호환성 확인"
            : "원격 서버 응답을 확인하지 못했습니다."
    }

    public func reconnect(_ machine: Machine) async {
        guard !busy else { return }
        busy = true
        defer { busy = false; updated = Date() }
        guard await loadRegistry() else { return }
        guard let current = machines.first(where: { $0.id == machine.id }) else {
            message = "등록에서 제거된 연결입니다. 목록을 갱신했습니다."
            return
        }
        _ = await reconnectOne(current)
    }

    @discardableResult private func reconnectOne(_ machine: Machine) async -> Bool {
        await check(machine)
        guard [.ready, .disabled].contains(states[machine.id]) else {
            message = "\(machine.label): \(states[machine.id]?.rawValue ?? "접속 확인 필요")"
            return false
        }
        states[machine.id] = .reconnecting
        let result = await Reconnection.run(machine, herdr: herdr, runner: runner)
        if result.code == 0 {
            // Reconnection already verified the final remote response. Do not run
            // another probe and then overwrite its failure with a green status.
            states[machine.id] = .ready
            details[machine.id] = "연결 갱신과 원격 서버 응답 확인"
        } else {
            // An enable failure must not inherit the pre-operation green state.
            states[machine.id] = .unreachable
            details[machine.id] = result.output
        }
        message = "\(machine.label): \(result.output)"
        return result.code == 0
    }

    public func reconnectAll() async {
        guard !busy else { return }
        busy = true
        defer { busy = false; updated = Date() }
        guard await loadRegistry() else { return }
        var successes = 0
        var failed: [String] = []
        for machine in machines {
            if await reconnectOne(machine) { successes += 1 }
            else { failed.append("\(machine.label) (\(states[machine.id]?.rawValue ?? "확인 필요"))") }
        }
        message = "\(successes)개 연결 갱신 완료"
        if !failed.isEmpty { message += " · 확인 필요: " + failed.joined(separator: ", ") }
    }
}

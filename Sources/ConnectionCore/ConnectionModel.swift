import Foundation
import Observation

@MainActor @Observable public final class ConnectionModel {
    public var machines: [Machine] = []
    public var states: [String: ConnectionState] = [:]
    public var details: [String: String] = [:]
    public var busy = false
    public var message = "등록된 Herdr 연결을 불러옵니다."
    public var updated: Date?
    /// Machines chosen for 선택 재연결. Stored so the choice survives relaunches.
    public var selected: Set<String> = [] {
        didSet { preferences.set(Array(selected).sorted(), forKey: selectionKey) }
    }
    private let preferences: UserDefaults
    private let selectionKey = "selectedMachineIDs"
    private let runner: Reconnection.Runner
    private let herdr = "/opt/homebrew/bin/herdr"

    public init(autoRefresh: Bool = true, preferences: UserDefaults = .standard,
                runner: @escaping Reconnection.Runner = { executable, arguments in
                    await Command.run(executable, arguments, timeout: 12)
                }) {
        self.preferences = preferences
        self.runner = runner
        if let saved = preferences.stringArray(forKey: selectionKey) { selected = Set(saved) }
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
        // First run: start from the connections Herdr already has turned on.
        if preferences.object(forKey: selectionKey) == nil {
            selected = Set(decoded.filter(\.enabled).map(\.id))
        } else {
            let current = selected.intersection(decoded.map(\.id))
            if current != selected { selected = current }
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

    public func toggle(_ machine: Machine) {
        if selected.contains(machine.id) { selected.remove(machine.id) } else { selected.insert(machine.id) }
    }

    /// Replaces the selection with connections whose effective SSH host is on the tailnet.
    public func selectTailscale() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard await loadRegistry() else { return }
        var tailnet: Set<String> = []
        for machine in machines where Reconnection.sshArguments(machine) != nil {
            if await reachesTailnet(machine.target) { tailnet.insert(machine.id) }
        }
        selected = tailnet
        message = tailnet.isEmpty ? "Tailscale 연결을 찾지 못했습니다." : "Tailscale 연결 \(tailnet.count)개 선택"
    }

    /// True when the host itself, or a ProxyJump hop on the way to it, is on the tailnet.
    private func reachesTailnet(_ target: String) async -> Bool {
        var next: String? = target
        var seen: Set<String> = []
        // Bounded walk: jump chains are short, and a config loop must not spin.
        while let hop = next, seen.count < 4, seen.insert(hop).inserted {
            let config = await runner("/usr/bin/ssh", ["-G", hop])
            if let host = Policy.sshHostname(config), Policy.isTailscale(host: host) { return true }
            next = Policy.sshFirstJump(config)
        }
        return false
    }

    public func reconnectSelected() async {
        guard !busy else { return }
        busy = true
        defer { busy = false; updated = Date() }
        guard await loadRegistry() else { return }
        let targets = machines.filter { selected.contains($0.id) }
        guard !targets.isEmpty else { message = "선택한 연결이 없습니다."; return }
        var successes = 0
        var failed: [String] = []
        for machine in targets {
            if await reconnectOne(machine) { successes += 1 }
            else { failed.append("\(machine.label) (\(states[machine.id]?.rawValue ?? "확인 필요"))") }
        }
        message = "\(successes)개 연결 갱신 완료"
        if !failed.isEmpty { message += " · 확인 필요: " + failed.joined(separator: ", ") }
    }
}

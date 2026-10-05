import Foundation
import Observation

@MainActor @Observable public final class ConnectionModel {
    public var machines: [Machine] = []
    public var states: [String: ConnectionState] = [:]
    public var details: [String: String] = [:]
    public var busy = false
    public var message = "등록된 Herdr 연결을 불러옵니다."
    public var updated: Date?
    public var waitingForAuthentication = false
    public var loginURL: String {
        didSet { preferences.set(loginURL, forKey: "madpLoginURL") }
    }
    private let preferences: UserDefaults
    private let runner: Reconnection.Runner
    private let openURL: @MainActor (URL) -> Bool
    private let authenticationPoll: Duration
    private var authenticationID: UUID?
    private var loginTask: Task<Void, Never>?
    private let herdr = "/opt/homebrew/bin/herdr"
    private let tsh = "/opt/homebrew/bin/tsh"

    public init(autoRefresh: Bool = true, preferences: UserDefaults = .standard,
                authenticationPoll: Duration = .seconds(2),
                openURL: @escaping @MainActor (URL) -> Bool = { _ in false },
                runner: @escaping Reconnection.Runner = { executable, arguments in
                    await Command.run(executable, arguments, timeout: 12)
                }) {
        self.preferences = preferences
        self.runner = runner
        self.openURL = openURL
        self.authenticationPoll = authenticationPoll
        loginURL = preferences.string(forKey: "madpLoginURL") ?? ""
        if autoRefresh {
            Task { [weak self] in
                while !Task.isCancelled {
                    if let self {
                        if !self.waitingForAuthentication { await self.refresh() }
                    } else { return }
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    public func refresh() async {
        guard !busy, !waitingForAuthentication else { return }
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
        if machine.target == "madp" {
            let auth = await runner(tsh, ["status", "--format=json"])
            if !Policy.tshValid(auth) {
                states[machine.id] = .authentication
                details[machine.id] = "MADP 인증을 완료하면 자동으로 재연결합니다."
                return
            }
        }
        guard let arguments = Reconnection.sshArguments(machine) else {
            states[machine.id] = .unreachable
            details[machine.id] = "등록된 SSH 대상 또는 세션 이름을 확인해주세요."
            return
        }
        let ssh = await runner("/usr/bin/ssh", arguments)
        states[machine.id] = Policy.state(ssh: ssh, enabled: machine.enabled, authExpired: false)
        details[machine.id] = states[machine.id] == .ready || states[machine.id] == .disabled
            ? "SSH와 Herdr 서버 호환성 확인"
            : "원격 서버 응답을 확인하지 못했습니다."
    }

    public func reconnect(_ machine: Machine) async {
        guard !busy, !waitingForAuthentication else { return }
        busy = true
        defer { busy = false; updated = Date() }
        guard await loadRegistry() else { return }
        guard let current = machines.first(where: { $0.id == machine.id }) else {
            message = "등록에서 제거된 연결입니다. 목록을 갱신했습니다."
            return
        }
        _ = await reconnectOne(current)
        if states[current.id] == .authentication {
            busy = false
            startAuthentication()
        }
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
        guard !busy, !waitingForAuthentication else { return }
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

    public func startAuthentication() {
        guard !busy, !waitingForAuthentication else { return }
        guard let url = Policy.loginURL(loginURL) else {
            message = "MADP 로그인 링크 설정이 비어 있거나 올바르지 않습니다. 설정을 확인해주세요."
            return
        }
        guard openURL(url) else { message = "로그인 링크를 열지 못했습니다."; return }
        let id = UUID()
        authenticationID = id
        waitingForAuthentication = true
        message = "브라우저에서 인증해주세요. tsh 인증 완료를 확인한 뒤 재연결합니다."
        loginTask = Task {
            let deadline = Date().addingTimeInterval(300)
            while !Task.isCancelled && Date() < deadline {
                let status = await runner(tsh, ["status", "--format=json"])
                guard authenticationID == id, !Task.isCancelled else { return }
                if Policy.tshValid(status) {
                    waitingForAuthentication = false
                    authenticationID = nil
                    busy = true
                    defer { busy = false; updated = Date() }
                    if await loadRegistry(), let machine = machines.first(where: { $0.target == "madp" }) {
                        await reconnectOne(machine)
                    }
                    return
                }
                try? await Task.sleep(for: authenticationPoll)
            }
            guard authenticationID == id else { return }
            authenticationID = nil
            waitingForAuthentication = false
            if !Task.isCancelled { message = "인증 대기 종료 · 로그인 링크를 다시 열어주세요." }
        }
    }

    public func cancelAuthentication() {
        guard waitingForAuthentication else { return }
        authenticationID = nil
        loginTask?.cancel()
        loginTask = nil
        waitingForAuthentication = false
        message = "인증 대기를 취소했습니다."
    }
}

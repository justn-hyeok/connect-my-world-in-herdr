import Foundation
import Testing
@testable import ConnectionCore

private let healthy = CommandResult(code: 0, output: "status: running\nendpoint_compatible: yes")
private let ok = CommandResult(code: 0, output: "")
private let failed = CommandResult(code: 1, output: "failed")

private func machine(_ target: String, enabled: Bool = true) throws -> Machine {
    try JSONDecoder().decode(Machine.self, from: Data("""
    {"id":"\(target)-id","label":"\(target)","target":"\(target)","session":"default","enabled":\(enabled)}
    """.utf8))
}

private func registry(_ machines: [Machine]) throws -> CommandResult {
    .init(code: 0, output: String(decoding: try JSONEncoder().encode(machines), as: UTF8.self))
}

private actor Script {
    var responses: [CommandResult]
    var arguments: [[String]] = []
    init(_ responses: [CommandResult]) { self.responses = responses }
    func run(_ exe: String, _ args: [String]) -> CommandResult {
        arguments.append([exe] + args)
        return responses.isEmpty ? failed : responses.removeFirst()
    }
}

@Test @MainActor func enableFailureCannotRemainGreen() async throws {
    let pve = try machine("pve")
    let script = Script([try registry([pve]), healthy, healthy, ok, failed, failed])
    let model = ConnectionModel(autoRefresh: false, runner: { exe, args in await script.run(exe, args) })
    model.states[pve.id] = .ready
    await model.reconnect(pve)
    #expect(model.states[pve.id] == .unreachable)
    #expect(model.message.contains("실패"))
    #expect(!model.busy)
}

@Test @MainActor func batchKeepsEarlierFailuresVisible() async throws {
    let pve = try machine("pve")
    let pn = try machine("pve-new")
    let script = Script([try registry([pve, pn]), failed, healthy, healthy, ok, ok, healthy])
    let model = ConnectionModel(autoRefresh: false, runner: { exe, args in await script.run(exe, args) })
    await model.reconnectAll()
    #expect(model.states[pve.id] == .unreachable)
    #expect(model.states[pn.id] == .ready)
    #expect(model.message.contains("1개 연결 갱신 완료"))
    #expect(model.message.contains("pve (접속 불가)"))
}

@Test @MainActor func removedOrChangedProfilesDoNotUseStaleState() async throws {
    let original = try machine("pve")
    let disabled = try machine("pve", enabled: false)
    let script = Script([try registry([disabled]), healthy, healthy, ok, healthy])
    let model = ConnectionModel(autoRefresh: false, runner: { exe, args in await script.run(exe, args) })
    await model.reconnect(original)
    let args = await script.arguments
    #expect(!args.contains(where: { $0.contains("disable") }))
    #expect(model.states[original.id] == .ready)
    let removedScript = Script([try registry([])])
    let removed = ConnectionModel(autoRefresh: false, runner: { exe, args in await removedScript.run(exe, args) })
    await removed.reconnect(original)
    #expect(await removedScript.arguments.count == 1)
    #expect(removed.message.contains("제거"))
}

@Test @MainActor func newlyExpiredAuthenticationIsHandledOnSameClick() async throws {
    let madp = try machine("madp")
    let script = Script([try registry([madp]), .init(code: 1, output: "expired")])
    let name = "dev.justn.cmw.test.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    let model = ConnectionModel(autoRefresh: false, preferences: preferences, runner: { exe, args in await script.run(exe, args) })
    model.states[madp.id] = .ready
    await model.reconnect(madp)
    #expect(model.states[madp.id] == .authentication)
    #expect(model.message.contains("로그인 링크 설정"))
    #expect(!model.waitingForAuthentication)
    #expect(await script.arguments.count == 2)
}

private actor DelayedAuthentication {
    var pending: [Int: CheckedContinuation<CommandResult, Never>] = [:]
    var requests = 0
    func run(_ exe: String, _ args: [String]) async -> CommandResult {
        guard args == ["status", "--format=json"] else { return failed }
        requests += 1
        let request = requests
        return await withCheckedContinuation { pending[request] = $0 }
    }
    func resume(_ request: Int) {
        pending.removeValue(forKey: request)?.resume(returning: failed)
    }
}

@Test @MainActor func cancelledAuthenticationCannotOverwriteNewAttempt() async throws {
    let script = DelayedAuthentication()
    let name = "dev.justn.cmw.test.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    let model = ConnectionModel(autoRefresh: false, preferences: preferences,
        authenticationPoll: .seconds(10), openURL: { _ in true },
        runner: { exe, args in await script.run(exe, args) })
    model.loginURL = "https://teleport.madp.cloud/web/login"
    model.startAuthentication()
    var deadline = Date().addingTimeInterval(2)
    while await script.requests < 1 && Date() < deadline { await Task.yield() }
    #expect(await script.requests == 1)
    model.cancelAuthentication()
    model.startAuthentication()
    deadline = Date().addingTimeInterval(2)
    while await script.requests < 2 && Date() < deadline { await Task.yield() }
    #expect(await script.requests == 2)
    await script.resume(1)
    // Let the cancelled task consume its delayed response.
    for _ in 0..<50 { await Task.yield() }
    #expect(model.waitingForAuthentication)
    #expect(model.message.contains("브라우저"))
    model.cancelAuthentication()
    await script.resume(2)
}

@Test @MainActor func authenticationCompletionReconnectsOnlyMADP() async throws {
    let madp = try machine("madp")
    let pve = try machine("pve")
    let valid = CommandResult(code: 0, output: """
    {"active":{"profile_url":"https://teleport.madp.cloud:443","cluster":"madp.cloud","valid_until":"2099-01-01T00:00:00Z"},"profiles":[]}
    """)
    let script = Script([valid, try registry([madp, pve]), valid, healthy, healthy, ok, ok, healthy])
    let name = "dev.justn.cmw.test.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    let model = ConnectionModel(autoRefresh: false, preferences: preferences, openURL: { _ in true },
        runner: { exe, args in await script.run(exe, args) })
    model.loginURL = "https://teleport.madp.cloud/web/login"
    model.startAuthentication()
    let deadline = Date().addingTimeInterval(2)
    while (model.waitingForAuthentication || model.busy) && Date() < deadline { await Task.yield() }
    #expect(!model.waitingForAuthentication)
    #expect(!model.busy)
    #expect(model.states[madp.id] == .ready)
    #expect(model.message.contains("연결 갱신 완료"))
    let commands = await script.arguments
    #expect(commands.contains(where: { $0.contains("enable") && $0.contains(madp.id) }))
    #expect(!commands.contains(where: { $0.contains(pve.id) }))
}

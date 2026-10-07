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

/// Isolated preferences so selection state never touches the real app defaults.
private func defaults() -> UserDefaults {
    let name = "dev.justn.cmw.test.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: name)!
    preferences.removePersistentDomain(forName: name)
    return preferences
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
    let model = ConnectionModel(autoRefresh: false, preferences: defaults(), runner: { exe, args in await script.run(exe, args) })
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
    let model = ConnectionModel(autoRefresh: false, preferences: defaults(), runner: { exe, args in await script.run(exe, args) })
    await model.reconnectSelected()
    #expect(model.states[pve.id] == .unreachable)
    #expect(model.states[pn.id] == .ready)
    #expect(model.message.contains("1개 연결 갱신 완료"))
    #expect(model.message.contains("pve (접속 불가)"))
}

@Test @MainActor func removedOrChangedProfilesDoNotUseStaleState() async throws {
    let original = try machine("pve")
    let disabled = try machine("pve", enabled: false)
    let script = Script([try registry([disabled]), healthy, healthy, ok, healthy])
    let model = ConnectionModel(autoRefresh: false, preferences: defaults(), runner: { exe, args in await script.run(exe, args) })
    await model.reconnect(original)
    let args = await script.arguments
    #expect(!args.contains(where: { $0.contains("disable") }))
    #expect(model.states[original.id] == .ready)
    let removedScript = Script([try registry([])])
    let removed = ConnectionModel(autoRefresh: false, preferences: defaults(), runner: { exe, args in await removedScript.run(exe, args) })
    await removed.reconnect(original)
    #expect(await removedScript.arguments.count == 1)
    #expect(removed.message.contains("제거"))
}

@Test @MainActor func onlyCheckedConnectionsReconnect() async throws {
    let pve = try machine("pve")
    let pn = try machine("pve-new")
    let old = try machine("madp", enabled: false)
    let preferences = defaults()
    let script = Script([try registry([pve, pn, old]), healthy, healthy, ok, ok, healthy,
                         healthy, healthy, ok, ok, healthy])
    let model = ConnectionModel(autoRefresh: false, preferences: preferences,
        runner: { exe, args in await script.run(exe, args) })
    await model.reconnectSelected()
    // First run selects only connections Herdr already has on; the disabled one stays off.
    #expect(model.selected == [pve.id, pn.id])
    #expect(!(await script.arguments).contains(where: { $0.contains(old.id) }))
    model.toggle(pn)
    #expect(model.selected == [pve.id])
    // The choice survives a relaunch.
    let relaunched = ConnectionModel(autoRefresh: false, preferences: preferences,
        runner: { exe, args in await script.run(exe, args) })
    #expect(relaunched.selected == [pve.id])

    let none = ConnectionModel(autoRefresh: false, preferences: defaults(),
        runner: { _, _ in try! registry([pve]) })
    none.toggle(pve)
    none.toggle(pve)
    // An explicitly emptied selection must not fall back to the first-run default.
    await none.reconnectSelected()
    #expect(none.selected.isEmpty)
    #expect(none.message.contains("선택한 연결이 없습니다"))
}

@Test @MainActor func tailscaleButtonSelectsOnlyTailnetHosts() async throws {
    let rapi = try machine("rapi-agent")
    let pn = try machine("pve-new")
    let madp = try machine("madp", enabled: false)
    let ip = try machine("ubuntu@100.75.152.85")
    let script = Script([try registry([rapi, pn, madp, ip]),
        .init(code: 0, output: "user ubuntu\nhostname rapi-agent.tail0000.ts.net\nport 22"),
        .init(code: 0, output: "hostname 192.168.0.26\nproxyjump pve"),
        .init(code: 0, output: "hostname dev.example.cloud"),
        .init(code: 0, output: "hostname 100.75.152.85")])
    let model = ConnectionModel(autoRefresh: false, preferences: defaults(),
        runner: { exe, args in await script.run(exe, args) })
    await model.selectTailscale()
    #expect(model.selected == [rapi.id, ip.id])
    #expect(model.message.contains("2개"))
    let commands = await script.arguments
    #expect(commands.dropFirst().allSatisfy { $0.first == "/usr/bin/ssh" && $0[1] == "-G" })
    #expect(!commands.contains(where: { $0.contains("enable") || $0.contains("disable") }))
}

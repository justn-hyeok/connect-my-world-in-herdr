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

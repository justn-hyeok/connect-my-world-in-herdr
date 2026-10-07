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
/// Names are fixed per test (no UUIDs) and removed afterwards, so runs never pile up plist files.
private final class TestDefaults {
    private let test: String
    private var names: [String] = []
    init(_ test: String = #function) { self.test = test.filter { $0.isLetter || $0.isNumber } }
    func make() -> UserDefaults {
        let name = "dev.justn.cmw.test.\(test).\(names.count)"
        names.append(name)
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }
    func clean() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        for name in names {
            UserDefaults.standard.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name + ".plist"))
        }
    }
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
    let scope = TestDefaults()
    defer { scope.clean() }
    let pve = try machine("pve")
    let script = Script([try registry([pve]), healthy, healthy, ok, failed, failed])
    let model = ConnectionModel(autoRefresh: false, preferences: scope.make(), runner: { exe, args in await script.run(exe, args) })
    model.states[pve.id] = .ready
    await model.reconnect(pve)
    #expect(model.states[pve.id] == .unreachable)
    #expect(model.message.contains("실패"))
    #expect(!model.busy)
}

@Test @MainActor func batchKeepsEarlierFailuresVisible() async throws {
    let scope = TestDefaults()
    defer { scope.clean() }
    let pve = try machine("pve")
    let pn = try machine("pve-new")
    let script = Script([try registry([pve, pn]), failed, healthy, healthy, ok, ok, healthy])
    let model = ConnectionModel(autoRefresh: false, preferences: scope.make(), runner: { exe, args in await script.run(exe, args) })
    await model.reconnectSelected()
    #expect(model.states[pve.id] == .unreachable)
    #expect(model.states[pn.id] == .ready)
    #expect(model.message.contains("1개 연결 갱신 완료"))
    #expect(model.message.contains("pve (접속 불가)"))
}

@Test @MainActor func removedOrChangedProfilesDoNotUseStaleState() async throws {
    let scope = TestDefaults()
    defer { scope.clean() }
    let original = try machine("pve")
    let disabled = try machine("pve", enabled: false)
    let script = Script([try registry([disabled]), healthy, healthy, ok, healthy])
    let model = ConnectionModel(autoRefresh: false, preferences: scope.make(), runner: { exe, args in await script.run(exe, args) })
    await model.reconnect(original)
    let args = await script.arguments
    #expect(!args.contains(where: { $0.contains("disable") }))
    #expect(model.states[original.id] == .ready)
    let removedScript = Script([try registry([])])
    let removed = ConnectionModel(autoRefresh: false, preferences: scope.make(), runner: { exe, args in await removedScript.run(exe, args) })
    await removed.reconnect(original)
    #expect(await removedScript.arguments.count == 1)
    #expect(removed.message.contains("제거"))
}

@Test @MainActor func onlyCheckedConnectionsReconnect() async throws {
    let scope = TestDefaults()
    defer { scope.clean() }
    let pve = try machine("pve")
    let pn = try machine("pve-new")
    let old = try machine("madp", enabled: false)
    let preferences = scope.make()
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

    let none = ConnectionModel(autoRefresh: false, preferences: scope.make(),
        runner: { _, _ in try! registry([pve]) })
    none.toggle(pve)
    none.toggle(pve)
    // An explicitly emptied selection must not fall back to the first-run default.
    await none.reconnectSelected()
    #expect(none.selected.isEmpty)
    #expect(none.message.contains("선택한 연결이 없습니다"))
}

@Test @MainActor func tailscaleButtonSelectsOnlyTailnetHosts() async throws {
    let scope = TestDefaults()
    defer { scope.clean() }
    let rapi = try machine("rapi-agent")
    let pn = try machine("pve-new")
    let madp = try machine("madp", enabled: false)
    let ip = try machine("ubuntu@100.100.10.20")
    let script = Script([try registry([rapi, pn, madp, ip]),
        .init(code: 0, output: "user ubuntu\nhostname rapi-agent.tail0000.ts.net\nport 22"),
        .init(code: 0, output: "hostname 192.168.0.26\nproxyjump ubuntu@pve:22"),
        .init(code: 0, output: "hostname fd7a:115c:a1e0::1:2"),
        // madp is off in Herdr, so it is never looked up.
        .init(code: 0, output: "hostname 100.100.10.20")])
    let model = ConnectionModel(autoRefresh: false, preferences: scope.make(),
        runner: { exe, args in await script.run(exe, args) })
    await model.selectTailscale()
    // pve-new is a LAN address reached through a Tailscale jump host, so it counts.
    #expect(model.selected == [rapi.id, pn.id, ip.id])
    #expect(model.message.contains("3개"))
    #expect(await script.arguments.contains(["/usr/bin/ssh", "-G", "pve"]))
    let commands = await script.arguments
    #expect(commands.dropFirst().allSatisfy { $0.first == "/usr/bin/ssh" && $0[1] == "-G" })
    #expect(!commands.contains(where: { $0.contains("enable") || $0.contains("disable") }))
}

@Test @MainActor func jumpLoopsAndLANJumpsAreNotTailscale() async throws {
    let scope = TestDefaults()
    defer { scope.clean() }
    let looped = try machine("a")
    let script = Script([try registry([looped]),
        .init(code: 0, output: "hostname 10.0.0.1\nproxyjump b"),
        .init(code: 0, output: "hostname 10.0.0.2\nproxyjump a"),
        .init(code: 0, output: "hostname 10.0.0.1\nproxyjump b")])
    let model = ConnectionModel(autoRefresh: false, preferences: scope.make(),
        runner: { exe, args in await script.run(exe, args) })
    await model.selectTailscale()
    #expect(model.selected.isEmpty)
    #expect(await script.arguments.count == 3)
}

@Test @MainActor func batchNeverTurnsOnDisabledConnections() async throws {
    let scope = TestDefaults()
    defer { scope.clean() }
    let pve = try machine("pve")
    let old = try machine("madp", enabled: false)
    let script = Script([try registry([pve, old]), healthy, healthy, ok, ok, healthy])
    let model = ConnectionModel(autoRefresh: false, preferences: scope.make(),
        runner: { exe, args in await script.run(exe, args) })
    model.setSelected(pve, true)
    model.setSelected(old, true)
    model.setSelected(old, true)  // Setting the same value twice must not flip it.
    #expect(model.selected == [pve.id, old.id])
    await model.reconnectSelected()
    #expect(!(await script.arguments).contains(where: { $0.contains(old.id) }))
    #expect(model.message.contains("1개 연결 갱신 완료"))
    #expect(model.message.contains("꺼진 연결 건너뜀: madp"))
}

@Test @MainActor func tailscaleSkipsDisabledAndSharesJumpLookups() async throws {
    let scope = TestDefaults()
    defer { scope.clean() }
    let a = try machine("vm-a")
    let b = try machine("vm-b")
    let off = try machine("ts-off", enabled: false)
    let script = Script([try registry([a, b, off]),
        .init(code: 0, output: "hostname 192.168.0.10\nproxyjump pve"),
        .init(code: 0, output: "hostname fd7a:115c:a1e0::1:2"),
        .init(code: 0, output: "hostname 192.168.0.11\nproxyjump pve")])
    let model = ConnectionModel(autoRefresh: false, preferences: scope.make(),
        runner: { exe, args in await script.run(exe, args) })
    await model.selectTailscale()
    #expect(model.selected == [a.id, b.id])
    let lookups = await script.arguments.dropFirst()
    #expect(lookups.filter { $0 == ["/usr/bin/ssh", "-G", "pve"] }.count == 1)
    #expect(!lookups.contains(where: { $0.contains("ts-off") }))
}

@Test @MainActor func brokenSSHConfigKeepsTheExistingSelection() async throws {
    let scope = TestDefaults()
    defer { scope.clean() }
    let pve = try machine("pve")
    let pn = try machine("pve-new")
    let script = Script([try registry([pve, pn]), .init(code: 0, output: "hostname 100.100.10.20"),
                         .init(code: 255, output: "bad configuration option")])
    let model = ConnectionModel(autoRefresh: false, preferences: scope.make(),
        runner: { exe, args in await script.run(exe, args) })
    model.setSelected(pn, true)
    await model.selectTailscale()
    #expect(model.selected == [pn.id])
    #expect(model.message.contains("ssh -G"))
}

@Test @MainActor func emptyFirstRegistryKeepsTheFirstRunDefault() async throws {
    let scope = TestDefaults()
    defer { scope.clean() }
    let pve = try machine("pve")
    let script = Script([try registry([]), try registry([pve])])
    let model = ConnectionModel(autoRefresh: false, preferences: scope.make(),
        runner: { exe, args in await script.run(exe, args) })
    await model.refresh()
    #expect(model.selected.isEmpty)
    await model.refresh()
    #expect(model.selected == [pve.id])
}

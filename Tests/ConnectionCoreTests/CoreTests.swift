import Testing
@testable import ConnectionCore
import Foundation

@Test func connectionEvidence() {
    let healthy = CommandResult(code: 0, output: "status: running\nendpoint_compatible: yes")
    #expect(Policy.state(ssh: healthy, enabled: true) == .ready)
    #expect(Policy.state(ssh: healthy, enabled: false) == .disabled)
    #expect(Policy.state(ssh: .init(code: 0, output: "status: stopped"), enabled: true) == .serverStopped)
    #expect(Policy.state(ssh: .init(code: 255, output: "timeout"), enabled: true) == .unreachable)
}

private actor FakeRunner {
    var responses: [CommandResult]
    var calls: [[String]] = []
    init(_ responses: [CommandResult]) { self.responses = responses }
    func run(_ exe: String, _ args: [String]) -> CommandResult {
        calls.append([exe] + args)
        return responses.isEmpty ? .init(code: -1, output: "unexpected call") : responses.removeFirst()
    }
}

@Test func reconnectPreservesOrderAndRestoresOnFailure() async throws {
    let machine = try JSONDecoder().decode(Machine.self, from: Data("""
    {"id":"test-id","label":"pve","target":"pve","session":"default","enabled":true}
    """.utf8))
    let healthy = CommandResult(code: 0, output: "status: running\nendpoint_compatible: yes")
    let fake = FakeRunner([healthy, .init(code: 0, output: ""), .init(code: 1, output: ""),
                           .init(code: 0, output: ""), healthy])
    let result = await Reconnection.run(machine, herdr: "/test/herdr") { exe, args in await fake.run(exe, args) }
    #expect(result.code == 0)
    let calls = await fake.calls
    #expect(calls.count == 5)
    #expect(calls[1] == ["/test/herdr", "machine", "disable", "test-id"])
    #expect(calls[2] == ["/test/herdr", "machine", "enable", "test-id"])
    #expect(calls[3] == calls[2])
    let offline = FakeRunner([.init(code: 255, output: "timeout")])
    let failure = await Reconnection.run(machine, herdr: "/test/herdr") { exe, args in await offline.run(exe, args) }
    #expect(failure.code != 0)
    #expect(await offline.calls.count == 1)
    let lostAfterEnable = FakeRunner([healthy, .init(code: 0, output: ""), .init(code: 0, output: ""), .init(code: 255, output: "")])
    let uncertain = await Reconnection.run(machine, herdr: "/test/herdr") { exe, args in await lostAfterEnable.run(exe, args) }
    #expect(uncertain.code != 0)
}

@Test func commandsAreBoundedAndPreserveArguments() async {
    let echo = await Command.run("/bin/echo", ["literal $(touch SHOULD_NOT_EXIST)"], timeout: 2)
    #expect(echo.code == 0)
    #expect(echo.output.contains("$(touch SHOULD_NOT_EXIST)"))
    let timedOut = await Command.run("/bin/sleep", ["5"], timeout: 0.15)
    #expect(timedOut.code == 124)
    let missing = await Command.run("/does/not/exist", [])
    #expect(missing.code == -1)
}

@Test func remoteSessionMustNotContainShellSeparators() throws {
    for session in ["default\n", "default;true", "", "default'", "default other"] {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "test", "label": "test", "target": "pve", "session": session, "enabled": true
        ])
        let machine = try JSONDecoder().decode(Machine.self, from: data)
        #expect(Reconnection.sshArguments(machine) == nil)
    }
}

@Test func shortCommandsCompleteAfterAsyncSuspensions() async {
    let start = ContinuousClock.now
    let success = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
        for _ in 0..<20 {
            group.addTask {
                let result = await Command.run("/bin/sleep", ["0.02"], timeout: 1)
                return result.code == 0
            }
        }
        var allSucceeded = true
        for await succeeded in group { allSucceeded = allSucceeded && succeeded }
        return allSucceeded
    }
    #expect(success)
    #expect(start.duration(to: .now) < .seconds(5))
}

@Test func tailscaleHostsAreRecognizedByAddressOrMagicDNS() {
    for host in ["rapi-agent.tail993e8d.ts.net", "100.64.0.1", "100.127.255.254", "100.75.152.85",
                 "fd7a:115c:a1e0::9829:9413", "[fd7a:115c:a1e0::1]", "HOST.TS.NET"] {
        #expect(Policy.isTailscale(host: host), "\(host)")
    }
    for host in ["192.168.0.26", "100.63.0.1", "100.128.0.1", "10.0.0.1", "dev.example.cloud",
                 "ts.net.example.com", "100.75.152", "100.75.152.85.5", "fd7a:115c:a1e1::1", ""] {
        #expect(!Policy.isTailscale(host: host), "\(host)")
    }
    #expect(Policy.sshHostname(.init(code: 0, output: "user a\nhostname 100.75.152.85\nport 22")) == "100.75.152.85")
    #expect(Policy.sshHostname(.init(code: 255, output: "hostname x")) == nil)
}

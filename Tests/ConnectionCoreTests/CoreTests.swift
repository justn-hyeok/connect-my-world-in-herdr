import Testing
@testable import ConnectionCore
import Foundation

@Test func connectionEvidence() {
    let healthy = CommandResult(code: 0, output: "status: running\nendpoint_compatible: yes")
    #expect(Policy.state(ssh: healthy, enabled: true, authExpired: false) == .ready)
    #expect(Policy.state(ssh: healthy, enabled: false, authExpired: false) == .disabled)
    #expect(Policy.state(ssh: healthy, enabled: true, authExpired: true) == .authentication)
    #expect(Policy.state(ssh: .init(code: 0, output: "status: stopped"), enabled: true, authExpired: false) == .serverStopped)
    #expect(Policy.state(ssh: .init(code: 255, output: "timeout"), enabled: true, authExpired: false) == .unreachable)
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

@Test func trustedLinkOnly() {
    #expect(Policy.loginURL("") == nil)
    #expect(Policy.loginURL("https://teleport.madp.cloud/web/login") != nil)
    #expect(Policy.loginURL("https://teleport.madp.cloud.evil.test/") == nil)
    #expect(Policy.loginURL("http://teleport.madp.cloud/") == nil)
    #expect(Policy.loginURL("https://user:password@teleport.madp.cloud/") == nil)
}

@Test func certificateMustActuallyBeValid() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let valid = """
    {"active":{"profile_url":"https://teleport.madp.cloud:443","cluster":"madp.cloud","valid_until":"2099-01-01T00:00:00Z"},"profiles":[]}
    """
    #expect(Policy.tshValid(.init(code: 0, output: valid), now: now))
    #expect(!Policy.tshValid(.init(code: 1, output: valid), now: now))
    #expect(!Policy.tshValid(.init(code: 0, output: valid.replacingOccurrences(of: "2099", with: "2000")), now: now))
    #expect(!Policy.tshValid(.init(code: 0, output: valid.replacingOccurrences(of: "madp.cloud", with: "other.cloud")), now: now))
    let misleading = """
    {"active":{"profile_url":"https://other.cloud","cluster":"other.cloud","valid_until":"2099-01-01T00:00:00Z"},"profiles":[{"cluster":"madp.cloud"}]}
    """
    #expect(!Policy.tshValid(.init(code: 0, output: misleading), now: now))
    #expect(!Policy.tshValid(.init(code: 0, output: "not JSON"), now: now))
    #expect(Policy.tshValid(.init(code: 0, output: valid.replacingOccurrences(of: "00:00:00Z", with: "00:00:00.123Z")), now: now))
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

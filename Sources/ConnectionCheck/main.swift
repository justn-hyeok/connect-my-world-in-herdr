import Foundation
import ConnectionCore

@main struct ConnectionCheck {
    static func main() async {
        let herdr = "/opt/homebrew/bin/herdr"
        let list = await Command.run(herdr, ["machine", "list", "--json"])
        guard list.code == 0, let data = list.output.data(using: .utf8),
              let machines = try? JSONDecoder().decode([Machine].self, from: data) else {
            print("Herdr 목록 조회 실패")
            exit(1)
        }
        let args = Array(CommandLine.arguments.dropFirst())
        let target = args.count == 2 && args[0] == "--reconnect" ? args[1] : nil
        if !args.isEmpty && target == nil { print("사용법: ConnectionCheck [--reconnect <등록된 SSH 대상>]"); exit(2) }
        if let target, !machines.contains(where: { $0.target == target }) { print("등록된 SSH 대상이 없습니다."); exit(2) }
        var failed = false
        for machine in machines where target == nil || target == machine.target {
            if target != nil {
                let result = await Reconnection.run(machine, herdr: herdr) { exe, args in
                    await Command.run(exe, args, timeout: 12)
                }
                print("\(machine.label): \(result.output)")
                failed = failed || result.code != 0
            } else if let ssh = Reconnection.sshArguments(machine) {
                let result = await Command.run("/usr/bin/ssh", ssh, timeout: 12)
                let state = Policy.state(ssh: result, enabled: machine.enabled)
                print("\(machine.label): \(state.rawValue)")
                failed = failed || state != .ready
            } else { failed = true }
        }
        exit(failed ? 1 : 0)
    }
}

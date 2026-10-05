import Foundation
import Testing
@testable import ConnectionCore

private func connection(_ target: String, _ label: String) throws -> Machine {
    let data = try JSONSerialization.data(withJSONObject: [
        "id": target, "target": target, "label": label, "session": "default", "enabled": true
    ])
    return try JSONDecoder().decode(Machine.self, from: data)
}

@Test func guestsFollowTheirOwnHostsRegardlessOfRegistryOrder() throws {
    let machines = try [connection("rapi-agent", "rapi-agent (pve)"), connection("madp", "madp"),
        connection("guest-new", "guest (pn)"), connection("pve-new", "pve-new"), connection("pve", "pve")]
    let rows = MachineHierarchy.rows(machines)
    #expect(rows.map(\.id) == ["pve", "rapi-agent", "pve-new", "guest-new", "madp"])
    #expect(rows[1].parentID == "pve")
    #expect(rows[3].parentID == "pve-new")
    #expect(rows[0].isProxmox)
    #expect(!rows[4].isVM)
    #expect(rows[1].machine.target == "rapi-agent")
}

@Test func missingHostsNeverHideOrMisparentGuests() throws {
    let machines = try [connection("orphan", "orphan (pn)"), connection("plain", "contains (pve) words"),
        connection("pve", "pve")]
    let rows = MachineHierarchy.rows(machines)
    #expect(rows.count == machines.count)
    #expect(rows.allSatisfy { $0.parentID == nil })
    #expect(Set(rows.map(\.id)) == Set(machines.map(\.id)))
}

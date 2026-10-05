import Foundation

public struct MachineRow: Identifiable, Sendable {
    public let machine: Machine
    public let parentID: String?
    public var id: String { machine.id }
    public var isVM: Bool { parentID != nil }
    public var isProxmox: Bool { machine.target == "pve" || machine.target == "pve-new" }
}

public enum MachineHierarchy {
    public static func rows(_ machines: [Machine]) -> [MachineRow] {
        let hosts = ["pve", "pve-new"]
        let suffixes = ["pve": " (pve)", "pve-new": " (pn)"]
        var parentIDs: [String: String] = [:]
        for host in hosts {
            guard let parent = machines.first(where: { $0.target == host }),
                  let suffix = suffixes[host] else { continue }
            for machine in machines where machine.id != parent.id && !hosts.contains(machine.target) {
                if machine.label.hasSuffix(suffix) { parentIDs[machine.id] = parent.id }
            }
        }
        let roots = machines.enumerated().filter { parentIDs[$0.element.id] == nil }.sorted {
            let left = hosts.firstIndex(of: $0.element.target) ?? hosts.count
            let right = hosts.firstIndex(of: $1.element.target) ?? hosts.count
            return left == right ? $0.offset < $1.offset : left < right
        }
        var rows: [MachineRow] = []
        for root in roots {
            rows.append(MachineRow(machine: root.element, parentID: nil))
            for child in machines where parentIDs[child.id] == root.element.id {
                rows.append(MachineRow(machine: child, parentID: root.element.id))
            }
        }
        return rows
    }
}

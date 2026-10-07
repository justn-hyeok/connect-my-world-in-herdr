import SwiftUI
import AppKit
import ServiceManagement
import ConnectionCore

typealias Model = ConnectionModel

struct Panel: View {
    @Bindable var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Connect My World", systemImage: "network") .font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            Text("in Herdr").font(.caption).foregroundStyle(.secondary)
            Divider()
            if model.machines.isEmpty {
                Text("Herdr 연결 목록이 없습니다.").foregroundStyle(.secondary)
            }
            ForEach(MachineHierarchy.rows(model.machines)) { row in
                let machine = row.machine
                let state = model.states[machine.id] ?? .checking
                HStack(spacing: 8) {
                Toggle("\(machine.label) 선택", isOn: Binding(
                    get: { model.selected.contains(machine.id) },
                    set: { model.setSelected(machine, $0) }))
                    .toggleStyle(.checkbox).labelsHidden()
                Button {
                    Task { await model.reconnect(machine) }
                } label: {
                    HStack(spacing: 10) {
                        if row.isVM {
                            Text("└")
                                .font(.body.monospaced())
                                .foregroundStyle(.tertiary)
                                .frame(width: 14)
                                .accessibilityHidden(true)
                        }
                        Image(systemName: symbol(state)).foregroundStyle(color(state)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(machine.label).font(.body.weight(.medium)).foregroundStyle(.primary)
                            Text(row.isVM ? "VM · \(state.rawValue)" : row.isProxmox ? "Proxmox · \(state.rawValue)" : state.rawValue)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                    }.contentShape(Rectangle()).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
                .help(model.details[machine.id] ?? "클릭하여 재연결")
                .accessibilityLabel("\(machine.label), \(row.isVM ? "소속 VM, " : "")\(state.rawValue), 재연결")
                }
            }
            Divider()
            Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("상태 확인") { Task { await model.refresh() } }
                Spacer()
                Group {
                    Button("Tailscale만") { Task { await model.selectTailscale() } }
                        .help("켜진 연결 중 SSH 접속 주소나 ProxyJump로 거치는 서버가 Tailscale(ts.net, 100.64.0.0/10, fd7a:115c:a1e0::/48)인 연결만 체크합니다.")
                    Button("선택 재연결 (\(model.selected.count))") { Task { await model.reconnectSelected() } }
                        .disabled(model.selected.isEmpty)
                        .help("체크한 연결 중 Herdr에서 켜진 연결만 재연결합니다.")
                }.disabled(model.machines.isEmpty)
            }.disabled(model.busy)
            HStack {
                Button("설정") { openWindow(id: "settings") }
                Spacer()
                if let updated = model.updated { Text(updated, style: .time).font(.caption2).foregroundStyle(.secondary) }
                Button("종료") { NSApplication.shared.terminate(nil) }
            }.font(.caption)
        }
        .padding(18).frame(width: 380)
    }
    func symbol(_ state: ConnectionState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .checking, .reconnecting: "clock"
        case .disabled: "pause.circle"
        default: "exclamationmark.circle.fill"
        }
    }
    func color(_ state: ConnectionState) -> Color {
        switch state {
        case .ready: .green
        case .disabled: .orange
        case .checking, .reconnecting: .secondary
        default: .red
        }
    }
}

struct SettingsPanel: View {
    @Bindable var model: Model
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var error = ""
    var body: some View {
        Form {
            Section("앱") {
                Toggle("Mac 로그인 시 실행", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { _, value in
                        do {
                            if value { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            error = ""
                        } catch {
                            self.error = error.localizedDescription
                            startAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Text("60초마다 서버 상태를 확인합니다. 재연결은 클릭했을 때 실행합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
        }.formStyle(.grouped).padding().frame(width: 500, height: 180)
    }
}

@main struct ConnectMyWorldApp: App {
    @State private var model = Model()
    var body: some Scene {
        MenuBarExtra("Connect My World in Herdr", systemImage: "network") {
            Panel(model: model)
        }.menuBarExtraStyle(.window)
        Window("Connect My World — 설정", id: "settings") { SettingsPanel(model: model) }
            .windowResizability(.contentSize)
        // A bounded native QA entrypoint; ordinary launches remain menu-bar only.
        Window("Connect My World — 연결 확인", id: "verify") { Panel(model: model) }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(CommandLine.arguments.contains("--verify-window") ? .presented : .suppressed)
    }
}

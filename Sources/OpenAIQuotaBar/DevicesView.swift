import SwiftUI

struct ActiveAccountBadge: View {
    let names: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var body: some View {
        Label("Active", systemImage: "checkmark.circle.fill")
            .font(.system(size: 10, weight: .semibold))
            .scaleEffect(appeared ? 1 : 0.8).opacity(appeared ? 1 : 0)
            .onAppear { withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.6)) { appeared = true } }
            .help("Active on: \(names)").accessibilityLabel("Active on \(names)")
    }
}

struct AccountSwitchButton: View {
    let account: Account
    @EnvironmentObject private var pool: AccountPool
    @State private var targets: Set<UUID> = [PoolDevice.local.id]

    var body: some View {
        VStack(spacing: 8) {
            let active = pool.activeDevices(for: account.id)
            if !active.isEmpty { ActiveAccountBadge(names: active.map(\.name).joined(separator: ", ")) }
            Menu {
                Button("This Mac") { targets = [PoolDevice.local.id] }
                Button("All devices") { targets = Set(pool.devices.map(\.id)) }
                ForEach(pool.devices.filter { !$0.isLocal }) { device in
                    Button("Only \(device.name)") { targets = [device.id] }
                }
                Divider()
                ForEach(pool.devices) { device in
                    Toggle(device.name, isOn: Binding(get: { targets.contains(device.id) }, set: { selected in
                        if selected { targets.insert(device.id) } else { targets.remove(device.id) }
                    }))
                }
            } label: {
                Label(targets.count == pool.devices.count ? "All devices" : pool.devices.filter { targets.contains($0.id) }.map(\.name).joined(separator: ", ").nonEmptyTarget,
                      systemImage: "desktopcomputer")
                    .font(.system(size: 11)).lineLimit(2)
            }.disabled(pool.isWorking).accessibilityIdentifier("switch-targets")
            Button { Task { await pool.use(account, on: targets) } } label: {
                HStack(spacing: 8) {
                    if pool.isWorking { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.triangle.swap") }
                    Text(pool.isWorking ? "Connecting…" : "Use this account")
                }
            }.buttonStyle(PrimaryButtonStyle()).disabled(pool.isWorking || targets.isEmpty)
                .accessibilityIdentifier("use-account").accessibilityLabel("Use this account")
            Button { pool.showingDevices = true } label: {
                Label("\(active.count) devices active · Details", systemImage: "desktopcomputer")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.buttonStyle(.plain).accessibilityIdentifier("account-devices")
            if let error = pool.error {
                Text(error).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.top, 4)
    }
}

private extension String {
    var nonEmptyTarget: String { isEmpty ? "Choose devices" : self }
}

struct DevicesView: View {
    @EnvironmentObject private var pool: AccountPool
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { pool.showingDevices = false } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(QuietButtonStyle()).accessibilityLabel("Back").accessibilityIdentifier("devices-back")
                Text("Your devices").font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                Button { Task { await pool.synchronize() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(QuietButtonStyle()).disabled(pool.isWorking).accessibilityLabel("Refresh devices")
            }.padding(.bottom, 20)
            Text("Your devices. Your choice.")
                .font(.system(size: 13, weight: .medium)).padding(.bottom, 6)
            Text("Switch the shared Codex connection. Running work stays open; requests already in progress finish on their original account.")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(pool.devices) { device in deviceCard(device) }
                    if adding {
                        ConnectDeviceView { adding = false }
                    } else {
                        Button { adding = true } label: {
                            Label("Connect a VPS", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 13)
                        }.buttonStyle(.plain).softSurface(radius: 16).accessibilityIdentifier("add-device")
                    }
                    if let error = pool.error {
                        Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About live switching").font(.system(size: 11, weight: .semibold))
                        Text("Shared Codex terminals follow this selection. Older terminals and private app-server sessions need to reconnect to the shared daemon. Existing provider connections may retain their account until they reconnect.")
                        Text("Keep LLM Usage running on your Mac to renew access on the VPS. Offline devices receive your latest choice when they reconnect.")
                    }.font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, 6)
                }.padding(1)
            }.scrollIndicators(.hidden)
        }.padding(24)
    }

    private func deviceCard(_ device: PoolDevice) -> some View {
        let connection = pool.connections[device.id]
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                Image(systemName: device.isLocal ? "laptopcomputer" : "server.rack").font(.system(size: 22, weight: .light))
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.system(size: 13, weight: .semibold))
                    Text(pool.label(for: device)).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        .accessibilityIdentifier("device-state-\(device.id)")
                }
                Spacer()
                if connection?.checking == true { ProgressView().controlSize(.small) }
                else { Image(systemName: connection?.reachable == true ? "checkmark.circle" : "circle.dotted").foregroundStyle(Palette.secondary) }
            }
            if !device.isLocal { Text(device.sshHost).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary) }
            if let last = connection?.status?.lastConfirmed {
                Text("Confirmed \(Date(timeIntervalSince1970: last).formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9)).foregroundStyle(Palette.secondary)
            }
            if let expiry = connection?.status?.expiresAt {
                Text("Access valid until \(Date(timeIntervalSince1970: expiry).formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9)).foregroundStyle(Palette.secondary)
            }
            if device.isLocal, connection?.reachable != true {
                Button("Connect this Mac") { Task { await pool.installLocal() } }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).disabled(pool.isWorking)
                    .accessibilityIdentifier("connect-mac")
            }
            if connection?.reachable == true {
                Rectangle().fill(Palette.foreground.opacity(0.08)).frame(height: 0.5)
                if connection?.status?.hermesInstalled == true {
                    Label("Hermes connector installed", systemImage: "checkmark").font(.system(size: 10, weight: .medium))
                    Text("Applies when Hermes next loads its plugins. Already-running Hermes processes need one restart or plugin reload before they can follow this selection.")
                        .font(.system(size: 9)).foregroundStyle(Palette.secondary)
                } else {
                    Button { Task { await pool.connectHermes(device) } } label: {
                        Label("Connect Hermes", systemImage: "link").font(.system(size: 11, weight: .medium))
                    }.buttonStyle(.plain).disabled(pool.isWorking).accessibilityIdentifier("connect-hermes-\(device.id)")
                }
            }
        }.padding(16).softSurface(radius: 18).accessibilityElement(children: .contain)
    }
}

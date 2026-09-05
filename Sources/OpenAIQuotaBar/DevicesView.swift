import SwiftUI

struct AccountSwitchButton: View {
    let account: Account
    @EnvironmentObject private var pool: AccountPool

    var body: some View {
        VStack(spacing: 8) {
            Button { Task { await pool.use(account) } } label: {
                HStack(spacing: 8) {
                    if pool.isWorking { ProgressView().controlSize(.small) }
                    else { Image(systemName: pool.accountID == account.id ? "checkmark.circle" : "arrow.triangle.swap") }
                    Text(pool.isWorking ? "Connecting…" : pool.accountID == account.id ? "Selected account" : "Use this account")
                }
            }.buttonStyle(PrimaryButtonStyle()).disabled(pool.isWorking)
                .accessibilityIdentifier("use-account").accessibilityLabel("Use this account")
                .accessibilityValue(pool.accountID == account.id ? "Selected account" : "Not selected")
            Button { pool.showingDevices = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "desktopcomputer")
                    Text(pool.accountID == account.id ? "\(pool.confirmedCount) of \(pool.devices.count) devices confirmed" : "Codex terminals · Connected devices")
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold))
                }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.buttonStyle(.plain).accessibilityIdentifier("account-devices")
            if let error = pool.error {
                Text(error).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.top, 4)
    }
}

struct DevicesView: View {
    @EnvironmentObject private var pool: AccountPool
    @State private var name = ""
    @State private var host = ""
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
            Text("One account. Across your devices.")
                .font(.system(size: 13, weight: .medium)).padding(.bottom, 6)
            Text("Switch the shared Codex connection. Running work stays open; requests already in progress finish on their original account.")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(pool.devices) { device in deviceCard(device) }
                    if adding {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Connect a VPS").font(.system(size: 13, weight: .semibold))
                            TextField("Name, e.g. My VPS", text: $name).textFieldStyle(.plain)
                                .padding(10).softSurface(radius: 10).accessibilityIdentifier("device-name")
                            TextField("SSH alias or user@hostname", text: $host).textFieldStyle(.plain)
                                .padding(10).softSurface(radius: 10).accessibilityIdentifier("device-host")
                            Text("Uses your existing SSH access. Installs a private connector for that Linux user. Python 3.9+, Codex and systemd are required.")
                                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                            HStack {
                                Button("Cancel") { adding = false }.buttonStyle(.plain)
                                Spacer()
                                Button("Connect") {
                                    Task {
                                        await pool.connect(name: name, host: host)
                                        if pool.error == nil { adding = false; name = ""; host = "" }
                                    }
                                }.buttonStyle(.plain).fontWeight(.semibold)
                                    .disabled(pool.isWorking || host.isEmpty).accessibilityIdentifier("connect-device")
                            }
                        }.padding(15).softSurface(radius: 18)
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

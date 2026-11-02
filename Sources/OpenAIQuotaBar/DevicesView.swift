import SwiftUI

struct ActiveAccountBadge: View {
    let names: String
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var body: some View {
        Label(compact ? "Ready" : "Ready for new requests", systemImage: "checkmark.circle.fill")
            .font(.system(size: 10, weight: .semibold))
            .scaleEffect(appeared ? 1 : 0.8).opacity(appeared ? 1 : 0)
            .onAppear { withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.6)) { appeared = true } }
            .help("Account and live switching verified on: \(names)").accessibilityLabel("Account and live switching verified on \(names)")
    }
}

struct AccountSwitchButton: View {
    let account: Account
    @EnvironmentObject private var pool: AccountPool
    @State private var targets: Set<UUID> = [PoolDevice.local.id]
    @State private var initializedTargets = false

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
                Label("\(active.count) devices ready · Details", systemImage: "desktopcomputer")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.buttonStyle(.plain).accessibilityIdentifier("account-devices")
            if let error = pool.error {
                Text(error).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.top, 4).onAppear {
            guard !initializedTargets else { return }
            targets = pool.lastTargets.isEmpty ? Set(pool.devices.map(\.id)) : pool.lastTargets.intersection(Set(pool.devices.map(\.id)))
            initializedTargets = true
        }
    }
}

private extension String {
    var nonEmptyTarget: String { isEmpty ? "Choose devices" : self }
}

struct DevicesView: View {
    @EnvironmentObject private var pool: AccountPool
    @State private var adding = false
    @State private var reconnecting: PoolDevice?

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
            Text(pool.isWorking ? "Checking every selected device…" : "\(pool.confirmedCount) of \(pool.selectedCount) shared connections ready")
                .font(.system(size: 13, weight: .medium)).padding(.bottom, 6)
            Text("Ready means the account, access and running Codex version are verified. Work already in progress may finish on its previous account.")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if pool.preview { Text("PREVIEW · SAMPLE DEVICES").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary) }
                    if pool.selectedCount > pool.confirmedCount {
                        Button { Task { await pool.retryPending() } } label: {
                            Label("Retry pending devices", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                        }.buttonStyle(.plain).softSurface(radius: 14).disabled(pool.isWorking)
                            .accessibilityIdentifier("retry-pending-devices")
                    }
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
                        Text("Verification covers the shared Codex connection. Separate terminals, private app servers and other Unix users need their own connection. On this Mac, terminal connections are also inspected; remote terminal coverage may be unknown.")
                        Text("Keep LLM Usage running on your Mac to renew access on the VPS. Offline devices receive your latest choice when they reconnect.")
                    }.font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, 6)
                }.padding(1)
            }.scrollIndicators(.hidden)
        }.padding(24).confirmationDialog("Reconnect Codex on \(reconnecting?.name ?? "this device")?", isPresented: Binding(
            get: { reconnecting != nil }, set: { if !$0 { reconnecting = nil } }), titleVisibility: .visible) {
            if let device = reconnecting {
                Button("Reconnect Codex") { Task { await pool.reconnect(device) }; reconnecting = nil }
            }
            Button("Cancel", role: .cancel) { reconnecting = nil }
        } message: {
            Text("Uses the installed update. Active tasks block reconnection. Saved conversations remain; idle terminals may need to resume them. Your selected account is checked again afterward.")
        }
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
                else { Image(systemName: pool.isConfirmed(device) ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(Palette.secondary) }
            }
            if !device.isLocal {
                HStack {
                    Text(device.sshHost).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Button { pool.remove(device) } label: {
                        Label("Remove", systemImage: "minus.circle").font(.system(size: 11, weight: .medium))
                    }.buttonStyle(.plain).disabled(pool.isWorking)
                        .accessibilityLabel("Remove \(device.name)").accessibilityIdentifier("remove-device-\(device.id)")
                        .help("Stop syncing this VPS. Keeps its SSH setup and running sessions. You can add it again from Connect a VPS.")
                }
            }
            if connection?.reachable == true {
                if let compatibility = connection?.compatibility {
                    if let message = compatibility.message {
                        Label("Reconnect required", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11, weight: .semibold))
                        Text(message).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("switch-compatibility-\(device.id)")
                    } else {
                        Label("Live switching supported · Codex \(compatibility.runningVersion ?? "")", systemImage: "checkmark.circle")
                            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }
                } else {
                    Text("Live switching not verified. The connection selection does not confirm every running session.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let check = connection?.verification {
                    if let shared = check.sharedTerminals, let other = check.otherTerminals {
                        Text("\(shared) shared terminals · \(other) separate terminals")
                            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    } else {
                        Text("Terminal coverage not verified on this device.")
                            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }
                    if let active = check.activeRequests, active > 0 {
                        Text("\(active) tasks in progress · kept open")
                            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }
                    if check.needsTerminalReconnect {
                        Text("Finish work in separate terminals, then resume on the shared connection:")
                            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        Text("codex --remote unix:// resume").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                    if check.restartRequired {
                        Button("Reconnect Codex safely…") { reconnecting = device }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).disabled(pool.isWorking)
                            .accessibilityIdentifier("reconnect-codex-\(device.id)")
                    }
                }
            }
            if let issue = connection?.error {
                Text(issue).font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("device-error-\(device.id)")
            }
            if pool.selections[device.id] != nil {
                Button("Retry this device") { Task { await pool.retry(device) } }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).disabled(pool.isWorking)
                    .accessibilityIdentifier("retry-device-\(device.id)")
            }
            if let last = connection?.verification?.checkedAt {
                Text("Checked \(Date(timeIntervalSince1970: last).formatted(date: .abbreviated, time: .shortened))")
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

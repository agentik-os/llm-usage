import SwiftUI

struct RemoteMachinesView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var monitor: RemoteMonitor
    @State private var adding = false
    @State private var name = ""
    @State private var host = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { store.showingRemote = false } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(QuietButtonStyle()).accessibilityLabel("Back").accessibilityIdentifier("remote-back")
                Text("Other machines").font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                Button { Task { await monitor.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(QuietButtonStyle()).disabled(!monitor.refreshing.isEmpty || monitor.preview)
                    .accessibilityLabel("Refresh other machines")
            }
            Text("Read-only activity over SSH. Each machine keeps its own accounts and providers.")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(monitor.machines) { machine in machineCard(machine) }
                    if adding {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Machine name", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("machine-name")
                            TextField("SSH alias or user@hostname", text: $host).textFieldStyle(.roundedBorder).accessibilityIdentifier("machine-host")
                            HStack {
                                Button("Cancel") { adding = false; error = nil }
                                Spacer()
                                Button("Add machine") {
                                    do { try monitor.add(name: name, host: host); adding = false; name = ""; host = ""; error = nil }
                                    catch { self.error = error.localizedDescription }
                                }.disabled(name.isEmpty || host.isEmpty)
                            }
                        }.padding(14).softSurface(radius: 16)
                    } else {
                        Button { adding = true } label: { Label("Monitor a machine", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 12) }
                            .buttonStyle(.plain).softSurface(radius: 16).accessibilityIdentifier("add-monitored-machine")
                    }
                    if let message = error ?? monitor.storageError { Text(message).font(.caption).foregroundStyle(Palette.secondary) }
                    Text("Subscription limits show the percentage remaining for an account across all its machines. Providers do not give an exact remaining token count. Token totals below come from this machine’s session logs, including cached input. Refreshes every minute while this page is open.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(1)
            }.scrollIndicators(.hidden)
        }.padding(24).task {
            while !Task.isCancelled {
                await monitor.refreshAll()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            }
        }
    }

    private func machineCard(_ machine: MonitoredMachine) -> some View {
        let observation = monitor.observations[machine.id]
        let failed = monitor.errors[machine.id] != nil
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: "desktopcomputer").font(.system(size: 20))
                VStack(alignment: .leading, spacing: 3) {
                    Text(machine.name).font(.system(size: 14, weight: .semibold))
                    Text(machine.sshHost).font(.system(size: 9, design: .monospaced)).lineLimit(1).truncationMode(.middle).foregroundStyle(Palette.secondary)
                }
                Spacer()
                if monitor.refreshing.contains(machine.id) { ProgressView().controlSize(.small) }
                else { Image(systemName: failed ? "exclamationmark.circle" : observation == nil ? "circle.dotted" : "checkmark.circle") }
                Menu {
                    Button("Refresh") { Task { await monitor.refresh(machine) } }
                    Button("Remove from monitoring") { do { try monitor.remove(machine) } catch { self.error = error.localizedDescription } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if let observation {
                Text("Accounts & remaining quota").font(.system(size: 12, weight: .semibold))
                if let accounts = observation.accounts {
                    ForEach(accounts) { account in accountCard(account) }
                } else {
                    Text("Update this machine’s monitor to see its connected accounts and remaining quotas.")
                        .font(.caption).foregroundStyle(Palette.secondary)
                }
                Divider().padding(.vertical, 3)
                Text("Usage on this machine").font(.system(size: 12, weight: .semibold))
                if let agents = observation.agents {
                    Text("Running · Codex \(agents["codex"] ?? 0) · Claude \(agents["claude"] ?? 0) · Hermes \(agents["hermes"] ?? 0) · OpenCode \(agents["opencode"] ?? 0)")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                } else { Text("Running agents unavailable").font(.caption).foregroundStyle(Palette.secondary) }
                ForEach(observation.usage) { usage in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(usage.name).font(.system(size: 11, weight: .semibold))
                            Spacer()
                            if observation.sources[usage.provider] == true {
                                Text("\(TokenFormat.compact(usage.tokens24h)) / 24h").font(.system(size: 14, weight: .medium, design: .rounded)).monospacedDigit()
                            } else { Text("No local logs").font(.caption).foregroundStyle(Palette.secondary) }
                        }
                        if observation.sources[usage.provider] == true {
                            Text("7 days · \(TokenFormat.compact(usage.tokens7d)) tokens · \(usage.sessions7d) sessions")
                                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                            Text("Input \(TokenFormat.compact(usage.input7d)) · output \(TokenFormat.compact(usage.output7d)) · cached \(TokenFormat.compact(usage.cached7d))")
                                .font(.system(size: 9)).foregroundStyle(Palette.muted)
                        }
                    }.padding(.vertical, 4)
                }
                if let models = observation.models {
                    Text(models.isEmpty ? "Ollama · no models in memory" : "Ollama · " + models.map(\.name).joined(separator: ", "))
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(3)
                }
                if observation.partial { Text("Partial totals · some logs could not be read within the scan limit.").font(.caption).foregroundStyle(Palette.secondary) }
                Text("\(failed ? "Last successful read" : "Read") \(Date(timeIntervalSince1970: observation.collectedAt).formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9)).foregroundStyle(Palette.muted)
            }
            if let message = monitor.errors[machine.id] {
                Text(message).font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            } else if observation == nil { Text("Waiting for the first reading…").font(.caption).foregroundStyle(Palette.secondary) }
        }.padding(15).softSurface(radius: 18).accessibilityIdentifier("monitored-machine-\(machine.id)")
    }

    private func accountCard(_ account: MachineObservation.ConnectedAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.providerName).font(.system(size: 11, weight: .semibold))
                Spacer()
                if let plan = account.planLabel { Text(plan).font(.system(size: 10)).foregroundStyle(Palette.secondary) }
            }
            Text(account.identityLabel).font(.system(size: 11)).textSelection(.enabled)
            Text(account.profile).font(.system(size: 9)).foregroundStyle(Palette.muted)
            ForEach(Array(account.windows.enumerated()), id: \.offset) { _, window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(window.name).font(.system(size: 10))
                        Spacer()
                        Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0...1))))% remaining")
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    }
                    ProgressView(value: window.fraction).tint(Palette.foreground)
                    if let reset = window.resetsAt, reset.isFinite {
                        Text("Resets \(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 9)).foregroundStyle(Palette.muted)
                    }
                }
            }
            if let message = account.message {
                Text(message).font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 7).accessibilityIdentifier("remote-account-\(account.id)")
    }
}

import SwiftUI

struct ConnectDeviceView: View {
    @EnvironmentObject private var pool: AccountPool
    var close: () -> Void
    @State private var discovery = SSHDiscoveryResult()
    @State private var selected: Set<String> = []
    @State private var scanning = false
    @State private var connecting = false
    @State private var manual = false
    @State private var name = ""
    @State private var host = ""
    @State private var message: String?
    @State private var search = ""

    private func added(_ alias: String) -> Bool { pool.devices.contains { $0.sshHost == alias } }
    private var choices: [DiscoveredSSHHost] { discovery.hosts.filter { selected.contains($0.alias) && !added($0.alias) } }
    private var visibleHosts: [DiscoveredSSHHost] {
        discovery.hosts.filter { search.isEmpty || $0.alias.localizedCaseInsensitiveContains(search) || $0.destination.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connect a VPS").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel", action: close).buttonStyle(.plain).disabled(connecting || pool.isWorking)
            }
            Text("Choose from this Mac’s SSH setup")
                .font(.system(size: 11, weight: .medium))
            Text("Reuses your aliases, keys, ports and jump hosts. Configured hosts are listed here; availability is checked when you connect.")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            if scanning {
                ProgressView("Reading SSH setup…").controlSize(.small)
            } else if discovery.hosts.isEmpty {
                Text("No named SSH hosts found. Add a VPS manually below.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            } else {
                TextField("Search SSH hosts", text: $search).textFieldStyle(.plain)
                    .padding(10).softSurface(radius: 10).accessibilityIdentifier("search-ssh-hosts")
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(visibleHosts) { candidate in
                            Button {
                                if selected.contains(candidate.alias) { selected.remove(candidate.alias) }
                                else { selected.insert(candidate.alias) }
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: added(candidate.alias) || selected.contains(candidate.alias) ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(candidate.alias).font(.system(size: 12, weight: .medium))
                                        Text(added(candidate.alias) ? "Already added" : candidate.destination)
                                            .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).softSurface(radius: 12)
                            }.buttonStyle(.plain).disabled(added(candidate.alias) || connecting || pool.isWorking)
                                .accessibilityIdentifier("ssh-host-\(candidate.alias)")
                                .accessibilityLabel(candidate.alias)
                                .accessibilityValue(added(candidate.alias) ? "Already added" : selected.contains(candidate.alias) ? "Selected" : "Not selected")
                        }
                    }
                }.frame(height: min(CGFloat(visibleHosts.count) * 68, 220))
                if visibleHosts.isEmpty { Text("No matching SSH hosts.").font(.system(size: 10)) }
                Button(connecting ? "Connecting…" : "Connect selected (\(choices.count))") {
                    Task { await connectSelected() }
                }.buttonStyle(PrimaryButtonStyle()).disabled(choices.isEmpty || connecting || pool.isWorking)
                    .accessibilityIdentifier("connect-selected-devices")
            }
            if discovery.incomplete {
                Text("Some SSH files could not be read. You can still enter an alias manually.")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            HStack {
                Button("Scan again") { Task { await scan() } }.disabled(scanning || connecting || pool.isWorking)
                    .accessibilityIdentifier("rescan-ssh-hosts")
                Spacer()
                Button(manual ? "Hide manual entry" : "Enter manually") { manual.toggle() }
                    .accessibilityIdentifier("manual-device-entry")
            }.buttonStyle(.plain).font(.system(size: 10, weight: .medium))
            if manual {
                TextField("Name, e.g. My VPS", text: $name).textFieldStyle(.plain)
                    .padding(10).softSurface(radius: 10).accessibilityIdentifier("device-name")
                TextField("SSH alias or user@hostname", text: $host).textFieldStyle(.plain)
                    .padding(10).softSurface(radius: 10).accessibilityIdentifier("device-host")
                Button("Connect") {
                    Task {
                        await pool.connect(name: name, host: host)
                        if pool.error == nil { close() }
                    }
                }.disabled(connecting || pool.isWorking || host.isEmpty).accessibilityIdentifier("connect-device")
            }
            Text("Connecting installs a private connector for that Linux user. Python 3.9+, Codex and systemd are required.")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            if let message { Text(message).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true) }
        }.padding(15).softSurface(radius: 18).task { await scan() }
    }

    private func scan() async {
        scanning = true
        defer { scanning = false }
        if pool.preview {
            discovery = SSHDiscoveryResult(hosts: [
                DiscoveredSSHHost(alias: "sample-vps", hostname: "vps.example.invalid", user: "developer", port: "2222"),
                DiscoveredSSHHost(alias: "sample-worker", hostname: "worker.example.invalid", user: "operator")])
        } else {
            discovery = await Task.detached(priority: .userInitiated) { SSHHostDiscovery.scan() }.value
        }
        selected.formIntersection(Set(discovery.hosts.map(\.alias)))
    }

    private func connectSelected() async {
        let targets = choices
        connecting = true; message = nil
        defer { connecting = false }
        var failed: [String] = []
        for candidate in targets {
            await pool.connect(name: candidate.alias, host: candidate.alias)
            if added(candidate.alias) { selected.remove(candidate.alias) }
            else { failed.append(candidate.alias) }
        }
        if failed.isEmpty { message = "Added \(targets.count) devices. Choose their account when you’re ready." }
        else { message = "Could not add: \(failed.joined(separator: ", ")). Check SSH access and retry; successful devices are already added." }
    }
}

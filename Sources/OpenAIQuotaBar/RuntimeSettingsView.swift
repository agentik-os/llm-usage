import SwiftUI

struct RuntimeModel: Codable, Identifiable {
    struct Effort: Codable { let reasoningEffort: String; let description: String }
    let id: String
    let model: String
    let displayName: String
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [Effort]
    let isDefault: Bool
}

struct RuntimeSnapshot: Codable {
    var model: String?
    var effort: String?
    var sandbox: String?
    var approval: String?
    var version: String?
    var models: [RuntimeModel]
}

extension AccountPool {
    func runtimeSettings(for device: PoolDevice, version: String? = nil, changes: [String: String]? = nil) async throws -> RuntimeSnapshot {
        if preview {
            var result = previewRuntime[device.id] ?? RuntimeSnapshot(model: "sample-model", effort: "medium",
                sandbox: "workspace-write", approval: "on-request", version: "preview", models: [
                    RuntimeModel(id: "sample-model", model: "sample-model", displayName: "Sample model", defaultReasoningEffort: "medium",
                        supportedReasoningEfforts: [.init(reasoningEffort: "medium", description: "Balanced"), .init(reasoningEffort: "high", description: "More reasoning")], isDefault: true)])
            if let changes {
                result.model = changes["model"] ?? result.model; result.effort = changes["effort"] ?? result.effort
                result.sandbox = changes["sandbox"] ?? result.sandbox; result.approval = changes["approval"] ?? result.approval
                previewRuntime[device.id] = result
            }
            return result
        }
        struct Request: Encodable { let version: String?; let changes: [String: String]? }
        struct Reply: Decodable { let ok: Bool; let result: RuntimeSnapshot?; let error: String? }
        var data = try JSONEncoder().encode(Request(version: version, changes: changes)); data.append(0x0A)
        let reply = try JSONDecoder().decode(Reply.self, from: await command(device, "runtime", input: data, timeout: 60))
        guard reply.ok, let result = reply.result else {
            throw UsageError.message(reply.error ?? "Codex could not confirm these settings. Reload and try again; check the installed Codex version and managed settings.")
        }
        return result
    }
}

struct RuntimeSettingsView: View {
    @EnvironmentObject private var pool: AccountPool
    @EnvironmentObject private var store: Store
    @State private var deviceID = PoolDevice.local.id
    @State private var snapshot: RuntimeSnapshot?
    @State private var model = ""
    @State private var effort = ""
    @State private var sandbox = ""
    @State private var approval = ""
    @State private var busy = false
    @State private var message: String?
    private var device: PoolDevice { pool.devices.first { $0.id == deviceID } ?? .local }
    private var selectedModel: RuntimeModel? { snapshot?.models.first { $0.model == model } }
    private var changes: [String: String] {
        guard let snapshot else { return [:] }
        var values: [String: String] = [:]
        if model != (snapshot.model ?? "") || effort != (snapshot.effort ?? "") {
            if !model.isEmpty { values["model"] = model }
            if !effort.isEmpty { values["effort"] = effort }
        }
        if sandbox != (snapshot.sandbox ?? "") { values["sandbox"] = sandbox }
        if approval != (snapshot.approval ?? "") { values["approval"] = approval }
        return values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Codex defaults")
            Picker("Device", selection: $deviceID) {
                ForEach(pool.devices) { Text($0.name).tag($0.id) }
            }.disabled(busy).accessibilityIdentifier("runtime-device")
                .onChange(of: deviceID) { _ in snapshot = nil; message = nil }
            Button(busy ? "Connecting…" : "Load settings") { Task { await load() } }
                .disabled(busy || store.showingDemo).accessibilityIdentifier("runtime-load")
            if let snapshot {
                Picker("Model", selection: Binding(get: { model }, set: { value in
                    model = value
                    if let selectedModel { effort = selectedModel.defaultReasoningEffort }
                })) {
                    if !snapshot.models.contains(where: { $0.model == model }) {
                        Text(model.isEmpty ? "Codex default" : model).tag(model)
                    }
                    ForEach(snapshot.models) { Text($0.displayName).tag($0.model) }
                }.accessibilityIdentifier("runtime-model")

                Picker("Reasoning", selection: $effort) {
                    if !(selectedModel?.supportedReasoningEfforts.contains { $0.reasoningEffort == effort } ?? false) {
                        Text(effort.isEmpty ? "Codex default" : effort).tag(effort)
                    }
                    ForEach(selectedModel?.supportedReasoningEfforts ?? [], id: \.reasoningEffort) {
                        Text($0.reasoningEffort.capitalized).tag($0.reasoningEffort)
                    }
                }.disabled(selectedModel == nil).accessibilityIdentifier("runtime-effort")
                Toggle("Full access", isOn: Binding(get: { sandbox == "danger-full-access" }, set: { value in
                    sandbox = value ? "danger-full-access" : "workspace-write"
                    if !value && approval == "never" { approval = "on-request" }
                })).accessibilityIdentifier("runtime-full-access")
                Text("Allows access outside the workspace.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                Toggle("YOLO mode", isOn: Binding(get: { sandbox == "danger-full-access" && approval == "never" }, set: { value in
                    approval = value ? "never" : "on-request"
                    if value { sandbox = "danger-full-access" }
                })).accessibilityIdentifier("runtime-yolo")
                Text("Full access without approval prompts.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                Button("Apply to \(device.name)") { Task { await apply() } }
                    .disabled(busy || changes.isEmpty || snapshot.version == nil || store.showingDemo)
                    .accessibilityIdentifier("runtime-apply")
            }
            Text("Applies to new conversations. Existing sessions keep their settings. Project settings and explicit session options can override these defaults.")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            if let message { Text(message).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true) }
        }.font(.system(size: 11)).disabled(busy).padding(14).softSurface(radius: 16)
    }

    private func adopt(_ result: RuntimeSnapshot) {
        snapshot = result; model = result.model ?? ""; effort = result.effort ?? ""
        sandbox = result.sandbox ?? ""; approval = result.approval ?? ""
    }
    private func load() async {
        busy = true; message = nil
        defer { busy = false }
        do { adopt(try await pool.runtimeSettings(for: device)) }
        catch { snapshot = nil; message = error.localizedDescription }
    }
    private func apply() async {
        busy = true; message = nil
        defer { busy = false }
        do {
            adopt(try await pool.runtimeSettings(for: device, version: snapshot?.version, changes: changes))
            message = "Saved for new conversations on \(device.name)."
        } catch { message = error.localizedDescription + " Reload settings before retrying." }
    }
}

import SwiftUI

/// Local models installed on this Mac, their measured speed, and running agent sessions.
struct LocalView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var monitor: LocalMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { store.showingLocal = false } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(QuietButtonStyle()).accessibilityLabel("Back").accessibilityIdentifier("local-back")
                Text("On this Mac").font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                Button { Task { await monitor.refresh() } } label: {
                    if monitor.loading { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    else { Image(systemName: "arrow.clockwise") }
                }.buttonStyle(QuietButtonStyle()).disabled(monitor.loading || monitor.preview)
                    .accessibilityLabel("Refresh local models and agents").help("Refresh")
            }.padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if monitor.preview {
                        Text("PREVIEW · SAMPLE DATA").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary)
                    }
                    agentsCard
                    HStack {
                        Eyebrow(text: "Local models")
                        Spacer()
                        Text(monitor.models.isEmpty ? "" : "\(monitor.models.count) installed · \(monitor.models.filter(\.isLoaded).count) in memory")
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.secondary)
                    }.padding(.top, 6)
                    if !monitor.serverReachable {
                        Label("Ollama isn’t answering on this Mac. Start it to list your local models.", systemImage: "exclamationmark.circle")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading).softSurface(radius: 16)
                            .accessibilityIdentifier("local-server-unreachable")
                    } else if monitor.models.isEmpty, !monitor.loading {
                        Text("No local models installed yet.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading).softSurface(radius: 16)
                    }
                    ForEach(monitor.models) { model in modelCard(model) }
                    if let error = monitor.error {
                        Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Speed comes from one short generation on this Mac. Measuring loads the model into memory, which can take a while for large models.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }.padding(1)
            }.scrollIndicators(.hidden)
        }.padding(24).task { await monitor.refresh() }
    }

    private var agentsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow(text: "Running agents")
                Spacer()
                Text("\(monitor.totalAgents) session\(monitor.totalAgents == 1 ? "" : "s")")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5).background(Color.primary.opacity(0.045), in: Capsule())
            }
            HStack(spacing: 0) {
                ForEach(AgentKind.allCases) { kind in
                    let count = monitor.agents[kind] ?? 0
                    VStack(spacing: 5) {
                        Image(systemName: kind.icon).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        Text("\(count)").font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(count == 0 ? Palette.muted : Palette.foreground)
                        Text(kind.rawValue).font(.system(size: 9)).foregroundStyle(Palette.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(kind.rawValue): \(count) running session\(count == 1 ? "" : "s")")
                        .accessibilityIdentifier("agents-\(kind.rawValue)")
                }
            }
        }.padding(16).softSurface(radius: 22)
    }

    private func modelCard(_ model: LocalModel) -> some View {
        let speed = monitor.speeds[model.name]
        let measuring = monitor.measuring == model.name
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if model.isLoaded {
                        Text("IN MEMORY").font(.system(size: 8, weight: .semibold)).tracking(0.8)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(Palette.foreground.opacity(0.12), in: Capsule())
                    }
                }
                Text(model.summary).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                if let speed {
                    Text("Measured \(speed.measuredAt, style: .relative) ago").font(.system(size: 9)).foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                if measuring {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                } else if let speed {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(LocalFormat.speed(speed.tokensPerSecond)).font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("tok/s").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                    }
                }
                if model.isEmbedding {
                    Text("Embeddings").font(.system(size: 9)).foregroundStyle(Palette.muted)
                } else if !measuring {
                    Button(speed == nil ? "Measure speed" : "Measure again") { Task { await monitor.measure(model) } }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                        .disabled(monitor.measuring != nil || monitor.preview)
                        .accessibilityIdentifier("measure-\(model.name)")
                        .accessibilityLabel("Measure the speed of \(model.name)")
                }
            }
        }.padding(14).softSurface(radius: 16)
            .accessibilityIdentifier("local-model-\(model.name)")
    }
}

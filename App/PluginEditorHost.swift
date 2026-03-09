import AppKit
@preconcurrency import AVFoundation
import CoreAudioKit
import SwiftUI

struct PluginEditorSession: Identifiable {
    let boxID: UUID
    let boxTitle: String
    let assignedPlugin: PluginDescriptor
    let editorPlugin: PluginDescriptor
    let liveAudioUnit: AVAudioUnit?

    var id: String { "\(boxID.uuidString):\(assignedPlugin.id):\(editorPlugin.id)" }
}

@MainActor
final class PluginEditorHost: ObservableObject {
    let session: PluginEditorSession

    @Published var statusMessage = "Loading plug-in editor..."
    @Published var viewController: NSViewController?

    private var audioUnit: AVAudioUnit?

    init(session: PluginEditorSession) {
        self.session = session
    }

    func load() {
        switch session.editorPlugin.format {
        case .audioUnit:
            loadAudioUnitEditor()
        case .vst2, .vst3:
            statusMessage = "This build can scan \(session.editorPlugin.format.rawValue) plug-ins, but it does not have a VST host/editor bridge yet."
            viewController = nil
        }
    }

    private func loadAudioUnitEditor() {
        if let liveAudioUnit = session.liveAudioUnit {
            audioUnit = liveAudioUnit
            statusMessage = "Requesting editor..."
            liveAudioUnit.auAudioUnit.requestViewController { [weak self] controller in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let controller {
                        self.viewController = controller
                        self.statusMessage = ""
                    } else {
                        self.statusMessage = "This Audio Unit does not expose a custom editor."
                    }
                }
            }
            return
        }

        guard let componentDescription = session.editorPlugin.audioUnitComponentDescription else {
            statusMessage = "Could not resolve the Audio Unit component."
            return
        }

        AVAudioUnit.instantiate(with: componentDescription, options: []) { [weak self] audioUnit, error in
            let resolved = AudioUnitInstantiationResult(audioUnit: audioUnit, error: error)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let resolvedError = resolved.error {
                    self.statusMessage = resolvedError.localizedDescription
                    return
                }
                guard let resolvedAudioUnit = resolved.audioUnit else {
                    self.statusMessage = "The Audio Unit could not be loaded."
                    return
                }

                self.audioUnit = resolvedAudioUnit
                self.statusMessage = "Requesting editor..."
                resolvedAudioUnit.auAudioUnit.requestViewController { controller in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let controller {
                            self.viewController = controller
                            self.statusMessage = ""
                        } else {
                            self.statusMessage = "This Audio Unit does not expose a custom editor."
                        }
                    }
                }
            }
        }
    }
}

private struct AudioUnitInstantiationResult: @unchecked Sendable {
    let audioUnit: AVAudioUnit?
    let error: Error?
}

struct PluginEditorSheet: View {
    let session: PluginEditorSession
    @StateObject private var host: PluginEditorHost
    @Environment(\.dismiss) private var dismiss

    init(session: PluginEditorSession) {
        self.session = session
        _host = StateObject(wrappedValue: PluginEditorHost(session: session))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.assignedPlugin.name)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(session.boxTitle) • \(session.assignedPlugin.format.rawValue)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.64))
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            }

            if let viewController = host.viewController {
                VStack(alignment: .leading, spacing: 10) {
                    if session.assignedPlugin.id != session.editorPlugin.id {
                        Text("Using matched Audio Unit editor for this plug-in.")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }

                    PluginEditorViewController(controller: viewController)
                        .frame(minWidth: 760, minHeight: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(host.statusMessage)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)

                    if session.editorPlugin.format != .audioUnit {
                        Text("Only Audio Unit editors can be opened in the current build. VST2/VST3 assignment is catalog-only until a real VST host is integrated.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.64))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
            }
        }
        .padding(22)
        .frame(minWidth: 820, minHeight: 620)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.07),
                    Color(red: 0.05, green: 0.07, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .task {
            host.load()
        }
    }
}

private struct PluginEditorViewController: NSViewControllerRepresentable {
    let controller: NSViewController

    func makeNSViewController(context: Context) -> NSViewController {
        controller
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}

private extension PluginDescriptor {
    var audioUnitComponentDescription: AudioComponentDescription? {
        guard format == .audioUnit, id.hasPrefix("au:") else { return nil }
        let payload = String(id.dropFirst(3))
        let pieces = payload.split(separator: ".")
        guard pieces.count == 3,
              let type = OSType(pieces[0]),
              let subtype = OSType(pieces[1]),
              let manufacturer = OSType(pieces[2]) else {
            return nil
        }

        return AudioComponentDescription(
            componentType: type,
            componentSubType: subtype,
            componentManufacturer: manufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }
}

private extension OSType {
    init?(_ text: Substring) {
        guard let value = UInt32(String(text)) else { return nil }
        self = value
    }
}

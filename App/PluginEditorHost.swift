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
final class PluginEditorWindowRegistry: ObservableObject {
    static let shared = PluginEditorWindowRegistry()

    private var sessions: [String: PluginEditorSession] = [:]

    private init() {}

    func register(_ session: PluginEditorSession) {
        sessions[session.id] = session
    }

    func session(for id: String?) -> PluginEditorSession? {
        guard let id else { return nil }
        return sessions[id]
    }

    func close(_ id: String?) {
        guard let id else { return }
        sessions[id] = nil
    }
}

@MainActor
final class PluginEditorHost: ObservableObject {
    let session: PluginEditorSession

    @Published var statusMessage = "Loading plug-in editor..."
    @Published var viewController: NSViewController?
    @Published var editorSize = CGSize(width: 720, height: 480)

    private var audioUnit: AVAudioUnit?
    private var loadStarted = false

    init(session: PluginEditorSession) {
        self.session = session
    }

    func load() {
        guard !loadStarted else { return }
        loadStarted = true
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
            requestViewController(from: liveAudioUnit, fallbackToSeparateInstance: true)
            return
        }

        instantiateSeparateAudioUnitForEditor()
    }

    private func instantiateSeparateAudioUnitForEditor() {
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
                self.requestViewController(from: resolvedAudioUnit, fallbackToSeparateInstance: false)
            }
        }
    }

    private func requestViewController(from audioUnit: AVAudioUnit, fallbackToSeparateInstance: Bool) {
        audioUnit.auAudioUnit.requestViewController { [weak self] controller in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let controller {
                    self.viewController = controller
                    self.editorSize = Self.preferredEditorSize(for: controller)
                    self.statusMessage = ""
                } else if fallbackToSeparateInstance {
                    self.statusMessage = "Opening a separate editor instance..."
                    self.instantiateSeparateAudioUnitForEditor()
                } else {
                    self.statusMessage = "This Audio Unit did not return a custom editor."
                }
            }
        }
    }

    func updateEditorSize(from controller: NSViewController) {
        editorSize = Self.preferredEditorSize(for: controller)
    }

    private static func preferredEditorSize(for controller: NSViewController) -> CGSize {
        let view = controller.view
        view.layoutSubtreeIfNeeded()

        let candidates = [
            controller.preferredContentSize,
            view.fittingSize,
            view.intrinsicContentSize,
            view.frame.size
        ]

        let measured = candidates.first { size in
            size.width.isFinite && size.height.isFinite && size.width > 32 && size.height > 32
        } ?? CGSize(width: 720, height: 480)

        return CGSize(
            width: min(max(measured.width, 360), 1440),
            height: min(max(measured.height, 220), 1000)
        )
    }
}

private struct AudioUnitInstantiationResult: @unchecked Sendable {
    let audioUnit: AVAudioUnit?
    let error: Error?
}

struct PluginEditorWindow: View {
    static let windowGroupID = "plugin-editor"

    let sessionID: String?
    @ObservedObject private var registry = PluginEditorWindowRegistry.shared

    var body: some View {
        Group {
            if let session = registry.session(for: sessionID) {
                PluginEditorContent(session: session)
                    .navigationTitle(session.assignedPlugin.name)
            } else {
                ContentUnavailableView {
                    Label("Editor unavailable", systemImage: "waveform.circle")
                } description: {
                    Text("Open a plug-in editor from a rack module.")
                }
                .frame(width: 420, height: 260)
            }
        }
        .onDisappear {
            registry.close(sessionID)
        }
    }
}

private struct PluginEditorContent: View {
    let session: PluginEditorSession
    @StateObject private var host: PluginEditorHost

    init(session: PluginEditorSession) {
        self.session = session
        _host = StateObject(wrappedValue: PluginEditorHost(session: session))
    }

    var body: some View {
        Group {
            if let viewController = host.viewController {
                PluginEditorViewController(controller: viewController) {
                    host.updateEditorSize(from: viewController)
                }
                .frame(width: host.editorSize.width, height: host.editorSize.height)
                .fixedSize()
            } else if session.editorPlugin.format == .audioUnit {
                ContentUnavailableView {
                    Label("Loading editor", systemImage: "waveform.circle")
                } description: {
                    Text(host.statusMessage)
                }
                .frame(width: 420, height: 260)
            } else {
                ContentUnavailableView {
                    Label("VST host not available", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("This build can scan VST2/VST3 plug-ins but does not yet host their editors. Audio Units open here directly.")
                }
                .frame(width: 520, height: 300)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            host.load()
        }
    }
}

private struct PluginEditorViewController: NSViewControllerRepresentable {
    let controller: NSViewController
    let sizeChanged: @MainActor () -> Void

    func makeNSViewController(context: Context) -> NSViewController {
        Task { @MainActor in
            sizeChanged()
        }
        return controller
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        Task { @MainActor in
            sizeChanged()
        }
    }
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

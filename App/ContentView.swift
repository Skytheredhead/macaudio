import SwiftUI

private let rackCoordinateSpace = "RackWorkspace"

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()
    @State private var inspectorVisible: Bool = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            RoutingSidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            RackWorkspace(viewModel: viewModel)
                .toolbar { transportToolbar }
                .safeAreaInset(edge: .top, spacing: 0) { warningStrip }
                .inspector(isPresented: $inspectorVisible) {
                    MeterInspector(engine: viewModel.engine)
                        .inspectorColumnWidth(min: 200, ideal: 240, max: 320)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(DS.Color.accent)
        .frame(minWidth: 1100, minHeight: 720)
        .sheet(item: $viewModel.pluginBrowserTarget) { target in
            PluginBrowserSheet(viewModel: viewModel, target: target)
        }
        .sheet(isPresented: $viewModel.showingPluginSettingsSheet) {
            PluginSettingsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showingSavePresetSheet) {
            SavePresetSheet(viewModel: viewModel)
        }
        .onAppear {
            viewModel.refreshDevices()
            viewModel.refreshPluginCatalog()
        }
        .onChange(of: viewModel.pluginEditorSession?.id) { _, _ in
            openPendingPluginEditor()
        }
    }

    private func openPendingPluginEditor() {
        guard let session = viewModel.pluginEditorSession else { return }
        PluginEditorWindowRegistry.shared.register(session)
        openWindow(id: PluginEditorWindow.windowGroupID, value: session.id)
        viewModel.pluginEditorSession = nil
    }

    @ToolbarContentBuilder
    private var transportToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            EmptyView()
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(viewModel.pluginCatalogRefreshInFlight ? "Scanning Plug-Ins…" : "Rescan Plug-Ins") {
                    viewModel.refreshPluginCatalog()
                }
                Button("Manual Plug-In Paths…") {
                    viewModel.showingPluginSettingsSheet = true
                }
                Divider()
                Picker("Sample Rate", selection: Binding(
                    get: { viewModel.engine.selectedSampleRate },
                    set: { viewModel.updateSampleRate($0) }
                )) {
                    ForEach(SampleRateOption.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Buffer", selection: Binding(
                    get: { viewModel.engine.selectedBufferSize },
                    set: { viewModel.updateBufferSize($0) }
                )) {
                    ForEach(BufferSizeOption.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(viewModel.engine.transportButtonTitle) {
                viewModel.toggleRunState()
            }
            .buttonStyle(.glassProminent)
            .tint(DS.Color.accent)
            .disabled(viewModel.engine.isTransportTransitioning)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                inspectorVisible.toggle()
            } label: {
                Label("Meters", systemImage: "waveform")
            }
        }
    }

    @ViewBuilder
    private var warningStrip: some View {
        if let warning = viewModel.engine.warningMessage, !warning.isEmpty {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(warning)
                    .font(DS.Font.caption)
                Spacer()
            }
            .foregroundStyle(DS.Color.warning)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.sm)
            .background(.thinMaterial)
            .overlay(alignment: .bottom) {
                Rectangle().fill(DS.Color.divider).frame(height: 0.5)
            }
        }
    }
}

// MARK: - Routing sidebar

private struct RoutingSidebar: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        Form {
            Section("Devices") {
                Picker("Input", selection: Binding(
                    get: { viewModel.engine.selectedInputDeviceID },
                    set: { viewModel.selectInputDevice($0) }
                )) {
                    ForEach(viewModel.engine.availableInputDevices) { device in
                        Text(device.channelCount > 1 ? "\(device.name) (\(device.channelCount) ch)" : device.name).tag(device.id)
                    }
                }
                Picker("Input Mode", selection: Binding(
                    get: { viewModel.engine.selectedInputChannelMode },
                    set: { viewModel.updateInputChannelMode($0) }
                )) {
                    ForEach(AudioChannelMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Output", selection: Binding(
                    get: { viewModel.engine.selectedOutputDeviceID },
                    set: { viewModel.selectOutputDevice($0) }
                )) {
                    ForEach(viewModel.engine.availableOutputDevices) { device in
                        Text(device.channelCount > 1 ? "\(device.name) (\(device.channelCount) ch)" : device.name).tag(device.id)
                    }
                }
                Picker("Output Mode", selection: Binding(
                    get: { viewModel.engine.selectedOutputChannelMode },
                    set: { viewModel.updateOutputChannelMode($0) }
                )) {
                    ForEach(AudioChannelMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Rack Mode") {
                Toggle("Dual mono", isOn: Binding(
                    get: { viewModel.rackMode == .dualMono },
                    set: { viewModel.setDualMonoEnabled($0) }
                ))
                Picker("End", selection: Binding(
                    get: { viewModel.dualMonoEndMode },
                    set: { viewModel.updateDualMonoEndMode($0) }
                )) {
                    ForEach(DualMonoEndMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(viewModel.rackMode != .dualMono)
                Button("Merge to Single Rack") {
                    viewModel.mergeDualMonoRackToSingle()
                }
                .disabled(viewModel.rackMode != .dualMono)
            }

            Section("Monitor") {
                Toggle("Enable monitor", isOn: Binding(
                    get: { viewModel.engine.monitorEnabled },
                    set: { viewModel.setMonitorEnabled($0) }
                ))
                Picker("Device", selection: Binding(
                    get: { viewModel.engine.selectedMonitorDeviceID },
                    set: { viewModel.selectMonitorDevice($0) }
                )) {
                    ForEach(viewModel.engine.availableOutputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .disabled(!viewModel.engine.monitorEnabled)
            }

            Section("Preset") {
                Picker("Preset", selection: Binding(
                    get: { viewModel.selectedPresetID },
                    set: { viewModel.selectPreset(id: $0) }
                )) {
                    ForEach(viewModel.presetChoices) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                HStack {
                    Button("Save") { viewModel.beginSavingPreset() }
                    Button("Delete") { viewModel.deleteSelectedPreset() }
                        .disabled(!viewModel.canDeleteSelectedPreset)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Routing")
    }
}

// MARK: - Rack workspace

private struct RackWorkspace: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        Group {
            if viewModel.rackMode == .dualMono {
                HStack(spacing: 0) {
                    RackLaneWorkspace(viewModel: viewModel, lane: .left)
                    Divider()
                    RackLaneWorkspace(viewModel: viewModel, lane: .right)
                }
            } else {
                RackLaneWorkspace(viewModel: viewModel, lane: .main)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(viewModel.rackMode == .dualMono ? "Dual Mono" : "Rack")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    if viewModel.rackMode == .dualMono {
                        viewModel.addRackBoxAndChoosePlugin(in: .left)
                    } else {
                        viewModel.addRackBoxAndChoosePlugin()
                    }
                } label: {
                    Label("Add Module", systemImage: "plus.circle.fill")
                }
            }
            if viewModel.rackMode == .dualMono {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button("Left Rack") { viewModel.addRackBoxAndChoosePlugin(in: .left) }
                        Button("Right Rack") { viewModel.addRackBoxAndChoosePlugin(in: .right) }
                    } label: {
                        Label("Add To", systemImage: "plus.rectangle.on.rectangle")
                    }
                }
            }
        }
    }
}

private struct RackLaneWorkspace: View {
    @ObservedObject var viewModel: MainViewModel
    let lane: RackLane
    @State private var activeCable: ActiveCable?
    @State private var highlightedDestination: RackRouteDestination?

    private let moduleHeight: CGFloat = 84
    private let moduleGap: CGFloat = 14
    private let canvasInset: CGFloat = 24
    private let portSpread: CGFloat = 16
    private let portAnchorInset: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = proxy.size
            let contentSize = CGSize(width: canvasSize.width, height: rackContentHeight())

            ScrollView(.vertical, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    GlassEffectContainer(spacing: moduleGap) {
                        ZStack(alignment: .topLeading) {
                            ForEach(orderedNodeIDs(), id: \.self) { nodeID in
                                if let frame = moduleFrame(for: nodeID, canvasSize: contentSize) {
                                    nodeView(for: nodeID)
                                        .frame(width: frame.width, height: frame.height)
                                        .position(CGPoint(x: frame.midX, y: frame.midY))
                                }
                            }
                        }
                    }

                    Canvas { ctx, _ in
                        drawConnections(in: &ctx, canvasSize: contentSize)
                    }
                    .allowsHitTesting(false)
                }
                .frame(width: canvasSize.width, height: contentSize.height, alignment: .topLeading)
                .coordinateSpace(name: rackCoordinateSpace)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Add Module") { viewModel.addRackBoxAndChoosePlugin() }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .overlay(alignment: .topLeading) {
            if lane != .main {
                Text(lane.title)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.top, DS.Space.sm)
            }
        }
    }

    @ViewBuilder
    private func nodeView(for nodeID: UUID) -> some View {
        if nodeID == viewModel.inputNodeID(for: lane) {
            EndpointCard(
                role: lane.inputTitle,
                name: selectedInputName,
                hasInput: false,
                hasOutput: true,
                isInputHighlighted: false,
                portSpread: portSpread,
                portAnchorInset: portAnchorInset,
                onCableChanged: { start, current, canvas in
                    updateCable(from: .input, start: start, current: current, canvasSize: canvas)
                },
                onCableEnded: { point, canvas in
                    finishCable(from: .input, at: point, canvasSize: canvas)
                },
                canvasSize: currentCanvasSize
            )
        } else if nodeID == viewModel.outputNodeID(for: lane) {
            EndpointCard(
                role: lane.outputTitle,
                name: selectedOutputName,
                hasInput: true,
                hasOutput: false,
                isInputHighlighted: highlightedDestination == .output,
                portSpread: portSpread,
                portAnchorInset: portAnchorInset,
                onCableChanged: { _, _, _ in },
                onCableEnded: { _, _ in },
                canvasSize: currentCanvasSize
            )
        } else if let box = viewModel.rackBoxes(in: lane).first(where: { $0.id == nodeID }) {
            ModuleCard(
                box: box,
                canOpenEditor: viewModel.canOpenPluginEditor(for: box.id),
                editorButtonTitle: viewModel.editorButtonTitle(for: box.id),
                isInputHighlighted: highlightedDestination == .box(box.id),
                portSpread: portSpread,
                portAnchorInset: portAnchorInset,
                onCableChanged: { start, current, canvas in
                    updateCable(from: .box(box.id), start: start, current: current, canvasSize: canvas)
                },
                onCableEnded: { point, canvas in
                    finishCable(from: .box(box.id), at: point, canvasSize: canvas)
                },
                openPluginBrowser: { viewModel.openPluginBrowser(for: box, in: lane) },
                openPluginEditor: { viewModel.openPluginEditor(for: box.id) },
                clearPlugin: { viewModel.clearPlugin(in: box.id) },
                removeBox: { viewModel.removeRackBox(box.id, in: lane) },
                toggleBypass: { viewModel.toggleBoxBypass(box.id) },
                canvasSize: currentCanvasSize
            )
        }
    }

    // The drag callbacks need the canvas size for hit-testing; we capture the
    // most recently observed value here.
    @State private var currentCanvasSize: CGSize = .zero

    private var selectedInputName: String {
        let name = viewModel.engine.availableInputDevices
            .first(where: { $0.id == viewModel.engine.selectedInputDeviceID })?.name ?? "No input"
        switch lane {
        case .main:
            return name
        case .left:
            return "\(name) - L"
        case .right:
            return "\(name) - R"
        }
    }

    private var selectedOutputName: String {
        let name = viewModel.engine.availableOutputDevices
            .first(where: { $0.id == viewModel.engine.selectedOutputDeviceID })?.name ?? "No output"
        if lane == .main {
            return name
        }
        return viewModel.dualMonoEndMode == .merge ? "\(name) - merged" : "\(name) - \(lane == .left ? "L" : "R")"
    }

    private func orderedNodeIDs() -> [UUID] {
        [viewModel.inputNodeID(for: lane)] + viewModel.rackBoxes(in: lane).map(\.id) + [viewModel.outputNodeID(for: lane)]
    }

    private func rackContentHeight() -> CGFloat {
        let count = max(2, viewModel.rackBoxes(in: lane).count + 2)
        return CGFloat(count) * moduleHeight + CGFloat(max(0, count - 1)) * moduleGap + canvasInset * 2
    }

    private func moduleFrame(for nodeID: UUID, canvasSize: CGSize) -> CGRect? {
        let orderedIDs = orderedNodeIDs()
        guard let index = orderedIDs.firstIndex(of: nodeID) else { return nil }
        let cableGutter: CGFloat = 80
        let width = max(420, canvasSize.width - canvasInset * 2 - cableGutter)
        let y = canvasInset + CGFloat(index) * (moduleHeight + moduleGap)
        return CGRect(x: canvasInset, y: y, width: width, height: moduleHeight)
    }

    private func inputPortPoint(for nodeID: UUID, canvasSize: CGSize) -> CGPoint? {
        guard let frame = moduleFrame(for: nodeID, canvasSize: canvasSize) else { return nil }
        let y = nodeID == viewModel.outputNodeID(for: lane) ? frame.midY : frame.midY - portSpread
        return CGPoint(x: frame.maxX - portAnchorInset, y: y)
    }

    private func outputPortPoint(for nodeID: UUID, canvasSize: CGSize) -> CGPoint? {
        guard let frame = moduleFrame(for: nodeID, canvasSize: canvasSize) else { return nil }
        let y = nodeID == viewModel.inputNodeID(for: lane) ? frame.midY : frame.midY + portSpread
        return CGPoint(x: frame.maxX - portAnchorInset, y: y)
    }

    private func cableLaneX(for canvasSize: CGSize) -> CGFloat {
        let firstFrame = moduleFrame(for: viewModel.inputNodeID(for: lane), canvasSize: canvasSize)
        let rightEdge = firstFrame?.maxX ?? canvasSize.width
        return min(rightEdge + 36, canvasSize.width - 18)
    }

    private func drawConnections(in ctx: inout GraphicsContext, canvasSize: CGSize) {
        currentCanvasSize = canvasSize
        for connection in viewModel.rackConnections(in: lane) {
            guard let start = outputPortPoint(for: connection.sourceID, canvasSize: canvasSize),
                  let end = inputPortPoint(for: connection.targetID, canvasSize: canvasSize) else { continue }
            drawCable(from: start, to: end, laneX: cableLaneX(for: canvasSize), color: DS.Color.signalIdle, active: false, in: &ctx)
        }

        if let activeCable {
            drawCable(from: activeCable.startPoint, to: activeCable.currentPoint, laneX: cableLaneX(for: canvasSize), color: DS.Color.signalActive, active: true, in: &ctx)
        }
    }

    private func drawCable(from start: CGPoint, to end: CGPoint, laneX: CGFloat, color: Color, active: Bool, in ctx: inout GraphicsContext) {
        let outerX = max(laneX, start.x + 18, end.x + 18)
        let startExit = CGPoint(x: outerX, y: start.y)
        let endEntry = CGPoint(x: outerX, y: end.y)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: startExit,
                      control1: CGPoint(x: start.x + 12, y: start.y),
                      control2: CGPoint(x: outerX - 16, y: start.y))
        path.addLine(to: endEntry)
        path.addCurve(to: end,
                      control1: CGPoint(x: outerX - 16, y: end.y),
                      control2: CGPoint(x: end.x + 12, y: end.y))
        if active {
            ctx.stroke(path, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)), with: .color(color))
        ctx.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)), with: .color(color))
    }

    private func updateCable(from source: RackCableSource, start: CGPoint, current: CGPoint, canvasSize: CGSize) {
        activeCable = ActiveCable(source: source, currentPoint: current, startPoint: start)
        highlightedDestination = nearestDestination(to: current, for: source, canvasSize: canvasSize)
    }

    private func finishCable(from source: RackCableSource, at point: CGPoint, canvasSize: CGSize) {
        defer {
            activeCable = nil
            highlightedDestination = nil
        }
        guard let destination = nearestDestination(to: point, for: source, canvasSize: canvasSize) else { return }
        viewModel.connect(source: source, to: destination, in: lane)
    }

    private func nearestDestination(to point: CGPoint, for source: RackCableSource, canvasSize: CGSize) -> RackRouteDestination? {
        let options: [RackRouteChoice] = {
            switch source {
            case .input: return viewModel.routeOptions(for: nil, in: lane)
            case .box(let id): return viewModel.routeOptions(for: id, in: lane)
            }
        }()

        var best: (destination: RackRouteDestination, distance: CGFloat)?
        for option in options {
            let targetPoint: CGPoint? = {
                switch option.destination {
                case .output: return inputPortPoint(for: viewModel.outputNodeID(for: lane), canvasSize: canvasSize)
                case .box(let id): return inputPortPoint(for: id, canvasSize: canvasSize)
                }
            }()
            guard let targetPoint else { continue }
            let dx = targetPoint.x - point.x
            let dy = targetPoint.y - point.y
            let distance = sqrt(dx * dx + dy * dy)
            guard distance < 56 else { continue }
            if let best, best.distance <= distance { continue }
            best = (option.destination, distance)
        }
        return best?.destination
    }
}

// MARK: - Module cards

private struct ModuleCard: View {
    let box: RackBoxNode
    let canOpenEditor: Bool
    let editorButtonTitle: String
    let isInputHighlighted: Bool
    let portSpread: CGFloat
    let portAnchorInset: CGFloat
    let onCableChanged: (CGPoint, CGPoint, CGSize) -> Void
    let onCableEnded: (CGPoint, CGSize) -> Void
    let openPluginBrowser: () -> Void
    let openPluginEditor: () -> Void
    let clearPlugin: () -> Void
    let removeBox: () -> Void
    let toggleBypass: () -> Void
    let canvasSize: CGSize

    var body: some View {
        GlassCard(cornerRadius: DS.Radius.lg, interactive: false) {
            HStack(spacing: DS.Space.md) {
                titleColumn
                Spacer(minLength: DS.Space.sm)
                actionRow
                portColumn
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
        }
    }

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.sm) {
                Text(box.displayName)
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                if let format = box.assignedPlugin?.format {
                    FormatPill(text: format.rawValue)
                }
            }
            Text(box.assignedPlugin == nil ? "Empty" : box.assignedPlugin!.vendor)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if box.assignedPlugin == nil {
            Button("Choose Plug-In…", action: openPluginBrowser)
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else {
            HStack(spacing: DS.Space.sm) {
                Button(editorButtonTitle, action: openPluginEditor)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canOpenEditor)
                if box.isBypassed {
                    Image(systemName: "circle")
                        .foregroundStyle(DS.Color.textTertiary)
                        .help("Bypassed")
                } else {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(DS.Color.accent)
                        .help("Live")
                }
            }
        }
        Menu {
            Button(box.isBypassed ? "Enable" : "Bypass", action: toggleBypass)
                .disabled(box.assignedPlugin == nil)
            Divider()
            Button("Choose Plug-In…", action: openPluginBrowser)
            Button("Clear Plug-In", action: clearPlugin)
                .disabled(box.assignedPlugin == nil)
            Divider()
            Button("Remove Module", role: .destructive, action: removeBox)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var portColumn: some View {
        VStack(spacing: portSpread - 8) {
            PortDot(role: .input, highlighted: isInputHighlighted)
            OutputPortDot(onCableChanged: { start, current in
                onCableChanged(start, current, canvasSize)
            }, onCableEnded: { point in
                onCableEnded(point, canvasSize)
            })
        }
        .frame(width: 14)
        .padding(.trailing, 0)
    }
}

private struct EndpointCard: View {
    let role: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
    let isInputHighlighted: Bool
    let portSpread: CGFloat
    let portAnchorInset: CGFloat
    let onCableChanged: (CGPoint, CGPoint, CGSize) -> Void
    let onCableEnded: (CGPoint, CGSize) -> Void
    let canvasSize: CGSize

    var body: some View {
        GlassCard(cornerRadius: DS.Radius.lg, tint: DS.Color.accent, interactive: false) {
            HStack(spacing: DS.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(role)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.accent)
                    Text(name)
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Color.textPrimary)
                        .lineLimit(1)
                }
                Spacer()
                portColumn
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
        }
    }

    private var portColumn: some View {
        VStack(spacing: portSpread - 8) {
            if hasInput {
                PortDot(role: .input, highlighted: isInputHighlighted)
            } else {
                Color.clear.frame(width: 10, height: 10)
            }
            if hasOutput {
                OutputPortDot(onCableChanged: { start, current in
                    onCableChanged(start, current, canvasSize)
                }, onCableEnded: { point in
                    onCableEnded(point, canvasSize)
                })
            } else {
                Color.clear.frame(width: 10, height: 10)
            }
        }
        .frame(width: 14)
    }
}

private struct FormatPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
    }
}

private struct PortDot: View {
    enum Role { case input, output }
    let role: Role
    var highlighted: Bool = false
    @State private var hovering: Bool = false

    var body: some View {
        let size: CGFloat = highlighted || hovering ? 12 : 9
        let fill: Color = highlighted ? DS.Color.accent : DS.Color.textTertiary
        Circle()
            .fill(fill)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(DS.Color.divider, lineWidth: 0.5))
            .shadow(color: highlighted ? DS.Color.accent.opacity(0.6) : .clear, radius: 6)
            .animation(.easeInOut(duration: 0.12), value: highlighted)
            .animation(.easeInOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .frame(width: 14, height: 14)
    }
}

private struct OutputPortDot: View {
    let onCableChanged: (CGPoint, CGPoint) -> Void
    let onCableEnded: (CGPoint) -> Void
    @State private var hovering: Bool = false

    var body: some View {
        let size: CGFloat = hovering ? 12 : 9
        Circle()
            .fill(DS.Color.textTertiary)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(DS.Color.divider, lineWidth: 0.5))
            .animation(.easeInOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(rackCoordinateSpace))
                    .onChanged { value in
                        onCableChanged(value.startLocation, value.location)
                    }
                    .onEnded { value in
                        onCableEnded(value.location)
                    }
            )
    }
}

// MARK: - Meters

private struct MeterInspector: View {
    @ObservedObject var engine: AudioEngineController

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(alignment: .top, spacing: DS.Space.lg) {
                MeterStrip(label: "IN",  level: engine.inputPeak)
                MeterStrip(label: "OUT", level: engine.outputPeak)
                ReductionStrip(label: "GR", reductionDB: engine.gainReductionDB)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                StatRow(label: "Clipped", value: "\(engine.clippedSamples)")
                StatRow(label: "XRuns",   value: "\(engine.xrunsOverruns)")
            }
            .padding(.top, DS.Space.sm)

            Spacer()
        }
        .padding(DS.Space.lg)
        .navigationTitle("Meters")
    }
}

private struct MeterStrip: View {
    let label: String
    let level: Float

    private static let scale: [Int] = [0, -12, -24, -48]
    private let barHeight: CGFloat = 200
    private let barWidth: CGFloat = 5

    var body: some View {
        VStack(spacing: DS.Space.sm) {
            Text(dbText)
                .font(DS.Font.meter)
                .foregroundStyle(DS.Color.textPrimary)

            HStack(alignment: .top, spacing: DS.Space.xs) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(MeterStrip.scale, id: \.self) { value in
                        Text("\(value)")
                            .font(DS.Font.meter)
                            .foregroundStyle(DS.Color.textTertiary)
                        if value != MeterStrip.scale.last { Spacer(minLength: 0) }
                    }
                }
                .frame(height: barHeight)

                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(DS.Color.divider.opacity(0.4))
                        .frame(width: barWidth, height: barHeight)
                    Capsule()
                        .fill(DS.Color.accent)
                        .frame(width: barWidth, height: barHeight * CGFloat(meterNormalized))
                }
            }

            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        }
    }

    private var meterNormalized: Double {
        let db = 20 * log10(max(level, 0.000_001))
        return min(max((Double(db) + 60) / 60, 0), 1)
    }

    private var dbText: String {
        let db = 20 * log10(max(level, 0.000_001))
        return db <= -59.5 ? "-∞" : String(format: "%.0f", db)
    }
}

private struct ReductionStrip: View {
    let label: String
    let reductionDB: Float

    private static let scale: [Int] = [24, 12, 0]
    private let barHeight: CGFloat = 200
    private let barWidth: CGFloat = 5

    var body: some View {
        VStack(spacing: DS.Space.sm) {
            Text(String(format: "%.1f", reductionDB))
                .font(DS.Font.meter)
                .foregroundStyle(DS.Color.textPrimary)

            HStack(alignment: .top, spacing: DS.Space.xs) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(ReductionStrip.scale, id: \.self) { value in
                        Text("\(value)")
                            .font(DS.Font.meter)
                            .foregroundStyle(DS.Color.textTertiary)
                        if value != ReductionStrip.scale.last { Spacer(minLength: 0) }
                    }
                }
                .frame(height: barHeight)

                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(DS.Color.divider.opacity(0.4))
                        .frame(width: barWidth, height: barHeight)
                    Capsule()
                        .fill(DS.Color.accent)
                        .frame(width: barWidth, height: barHeight * CGFloat(fill))
                }
            }

            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        }
    }

    private var fill: Double {
        min(max(Double(reductionDB) / 24.0, 0), 1)
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            Spacer()
            Text(value)
                .font(DS.Font.meter)
                .foregroundStyle(DS.Color.textPrimary)
        }
    }
}

// MARK: - Sheets

private struct PluginBrowserSheet: View {
    @ObservedObject var viewModel: MainViewModel
    let target: PluginBrowserTarget
    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery = ""
    @State private var filter: PluginBrowserFilter = .all
    @State private var selectedID: String?

    var body: some View {
        NavigationStack {
            List(filteredPlugins, selection: $selectedID) { plugin in
                HStack(spacing: DS.Space.md) {
                    FormatPill(text: plugin.format.rawValue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name)
                            .font(DS.Font.body)
                        Text("\(plugin.vendor) • \(plugin.category)")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                    Spacer()
                    Text(plugin.location)
                        .font(DS.Font.meter)
                        .foregroundStyle(DS.Color.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { commit(pluginID: plugin.id) }
                .tag(plugin.id)
            }
            .listStyle(.inset)
            .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search plug-ins")
            .navigationTitle("Choose Plug-In")
            .navigationSubtitle(target.slotTitle)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Picker("Format", selection: $filter) {
                        ForEach(PluginBrowserFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        if let id = selectedID { commit(pluginID: id) }
                    }
                    .disabled(selectedID == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.finishPluginBrowserSelection(for: target, committed: false)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onDisappear {
            viewModel.finishPluginBrowserSelection(for: target, committed: viewModel.boxHasAssignedPlugin(target.slotID))
        }
    }

    private var filteredPlugins: [PluginDescriptor] {
        viewModel.filteredPlugins(searchQuery: searchQuery, filter: filter)
    }

    private func commit(pluginID: String) {
        guard let plugin = viewModel.availablePlugins.first(where: { $0.id == pluginID }) else { return }
        viewModel.assignPlugin(plugin, to: target.slotID)
        viewModel.finishPluginBrowserSelection(for: target, committed: true)
        dismiss()
    }
}

private struct PluginSettingsSheet: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Catalog") {
                    LabeledContent("VST2",  value: "\(viewModel.vst2Count)")
                    LabeledContent("VST3",  value: "\(viewModel.vst3Count)")
                    LabeledContent("Audio Unit", value: "\(viewModel.audioUnitCount)")
                    Button {
                        viewModel.refreshPluginCatalog()
                    } label: {
                        Label(
                            viewModel.pluginCatalogRefreshInFlight ? "Scanning…" : "Rescan",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(viewModel.pluginCatalogRefreshInFlight)
                }

                Section("Manual paths") {
                    HStack(spacing: DS.Space.sm) {
                        TextField("Path to VST/VST3 bundle", text: $viewModel.manualPluginPathDraft)
                        Button("Add") { viewModel.addManualPluginPath() }
                            .disabled(viewModel.manualPluginPathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let warning = viewModel.pluginSettingsWarning, !warning.isEmpty {
                        Text(warning)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.warning)
                    }
                    ForEach(viewModel.manualPluginPaths, id: \.self) { path in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(DS.Font.body)
                            Text(path)
                                .font(DS.Font.meter)
                                .foregroundStyle(DS.Color.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Remove", role: .destructive) {
                                viewModel.removeManualPluginPath(path)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Plug-In Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

private struct SavePresetSheet: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Preset name", text: $viewModel.savePresetName)
            }
            .formStyle(.grouped)
            .navigationTitle("Save Preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showingSavePresetSheet = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.saveCurrentPreset()
                        dismiss()
                    }
                    .disabled(viewModel.savePresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 360, height: 200)
    }
}

// MARK: - Cable state

private struct ActiveCable {
    let source: RackCableSource
    var currentPoint: CGPoint
    var startPoint: CGPoint
}

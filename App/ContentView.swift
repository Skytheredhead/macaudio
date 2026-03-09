import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        ZStack {
            RackTheme.background

            VStack(spacing: 0) {
                HeaderBar(viewModel: viewModel, engine: viewModel.engine, accentOrange: accentOrange, accentCyan: accentCyan)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                HStack(spacing: 0) {
                    SidebarSection(viewModel: viewModel, engine: viewModel.engine, accentOrange: accentOrange, accentCyan: accentCyan)
                        .frame(width: 300)

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    RackWorkspaceSection(viewModel: viewModel, engine: viewModel.engine, accentOrange: accentOrange, accentCyan: accentCyan)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 20)
            }
        }
        .frame(minWidth: 1360, minHeight: 880)
        .sheet(item: $viewModel.pluginBrowserTarget) { target in
            PluginBrowserSheet(viewModel: viewModel, target: target, accentOrange: accentOrange, accentCyan: accentCyan)
        }
        .sheet(item: $viewModel.pluginEditorSession) { session in
            PluginEditorSheet(session: session)
        }
        .sheet(isPresented: $viewModel.showingPluginSettingsSheet) {
            PluginSettingsSheet(viewModel: viewModel, accentOrange: accentOrange, accentCyan: accentCyan)
        }
        .sheet(isPresented: $viewModel.showingSavePresetSheet) {
            SavePresetSheet(viewModel: viewModel)
        }
        .onAppear {
            viewModel.refreshDevices()
            viewModel.refreshPluginCatalog()
        }
    }

    private var isWindowActive: Bool {
        controlActiveState == .active || controlActiveState == .key
    }

    private var accentOrange: Color {
        isWindowActive ? Color(red: 0.96, green: 0.62, blue: 0.23) : Color(red: 0.76, green: 0.61, blue: 0.43)
    }

    private var accentCyan: Color {
        isWindowActive ? Color(red: 0.25, green: 0.83, blue: 0.95) : Color(red: 0.39, green: 0.71, blue: 0.78)
    }
}

private struct HeaderBar: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var engine: AudioEngineController
    let accentOrange: Color
    let accentCyan: Color

    var body: some View {
        HStack(spacing: 16) {
            Text("MacAudio")
                .font(.custom("Avenir Next Condensed", size: 40))
                .fontWeight(.heavy)
                .foregroundStyle(.white)

            Spacer()

            Menu {
                Button(viewModel.pluginCatalogRefreshInFlight ? "Scanning Plug-Ins..." : "Rescan Plug-Ins") {
                    viewModel.refreshPluginCatalog()
                }

                Button("Manual Plug-In Paths...") {
                    viewModel.showingPluginSettingsSheet = true
                }

                Divider()

                Picker("Sample Rate", selection: Binding(
                    get: { viewModel.engine.selectedSampleRate },
                    set: {
                        viewModel.updateSampleRate($0)
                    }
                )) {
                    ForEach(SampleRateOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }

                Picker("Buffer", selection: Binding(
                    get: { viewModel.engine.selectedBufferSize },
                    set: {
                        viewModel.updateBufferSize($0)
                    }
                )) {
                    ForEach(BufferSizeOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Rectangle().fill(Color.white.opacity(0.05)))
                    .overlay(Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)

            Button(engine.transportButtonTitle) {
                viewModel.toggleRunState()
            }
            .buttonStyle(.plain)
            .font(.custom("Avenir Next Condensed", size: 24))
            .fontWeight(.heavy)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Rectangle().fill(accentOrange))
            .disabled(engine.isTransportTransitioning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(RackTheme.sectionFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }
}

private struct SidebarSection: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var engine: AudioEngineController
    let accentOrange: Color
    let accentCyan: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader("Routing")

            VStack(alignment: .leading, spacing: 18) {
                RackTheme.menuField("Input", selectionText: selectedInputName) {
                    ForEach(engine.availableInputDevices) { device in
                        Button(device.name) {
                            viewModel.selectInputDevice(device.id)
                        }
                    }
                }

                RackTheme.menuField("Route Output", selectionText: selectedOutputName) {
                    ForEach(engine.availableOutputDevices) { device in
                        Button(device.name) {
                            viewModel.selectOutputDevice(device.id)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("MONITOR")
                            .font(RackTheme.labelFont)
                            .foregroundStyle(Color.white.opacity(0.45))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { engine.monitorEnabled },
                            set: {
                                viewModel.setMonitorEnabled($0)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(accentCyan)
                    }

                    RackTheme.menuField("Monitor Device", selectionText: selectedMonitorName, disabled: !engine.monitorEnabled) {
                        ForEach(engine.availableOutputDevices) { device in
                            Button(device.name) {
                                viewModel.selectMonitorDevice(device.id)
                            }
                        }
                    }
                    .opacity(engine.monitorEnabled ? 1 : 0.35)
                }

                RackTheme.menuField("Preset", selectionText: selectedPresetName) {
                    ForEach(viewModel.presetChoices) { preset in
                        Button(preset.name) {
                            viewModel.selectPreset(id: preset.id)
                        }
                    }
                }

                HStack(spacing: 10) {
                    RackTheme.commandButton("Save", fill: Color.white.opacity(0.08), enabled: true) {
                        viewModel.beginSavingPreset()
                    }

                    RackTheme.commandButton("Delete", fill: Color.white.opacity(0.05), enabled: viewModel.canDeleteSelectedPreset) {
                        viewModel.deleteSelectedPreset()
                    }
                }

                if let warning = engine.warningMessage, !warning.isEmpty {
                    Text(warning)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(accentOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)

            Spacer(minLength: 0)
        }
        .background(RackTheme.sectionFill)
    }

    private func sidebarHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.custom("Avenir Next Condensed", size: 24))
                .fontWeight(.bold)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    private var selectedInputName: String {
        engine.availableInputDevices.first(where: { $0.id == engine.selectedInputDeviceID })?.name ?? "No input"
    }

    private var selectedOutputName: String {
        engine.availableOutputDevices.first(where: { $0.id == engine.selectedOutputDeviceID })?.name ?? "No output"
    }

    private var selectedMonitorName: String {
        engine.availableOutputDevices.first(where: { $0.id == engine.selectedMonitorDeviceID })?.name ?? "No monitor"
    }

    private var selectedPresetName: String {
        viewModel.presetChoices.first(where: { $0.id == viewModel.selectedPresetID })?.name ?? "Preset"
    }
}

private struct RackWorkspaceSection: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var engine: AudioEngineController
    let accentOrange: Color
    let accentCyan: Color

    @State private var activeCable: ActiveCable?
    @State private var highlightedDestination: RackRouteDestination?

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader

            GeometryReader { proxy in
                let canvasSize = proxy.size
                let contentSize = CGSize(width: canvasSize.width, height: rackContentHeight(for: canvasSize))

                ZStack(alignment: .bottomTrailing) {
                    ScrollView(.vertical, showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            RackWorkspaceGrid()

                            RackVerticalRails(frame: rackFrame(in: contentSize), contentHeight: contentSize.height)

                            if let frame = moduleFrame(for: viewModel.inputNodeID, canvasSize: contentSize) {
                                InputNodeView(
                                    title: selectedInputName,
                                    accent: accentCyan,
                                    onCableChanged: { start, current in
                                        updateCable(from: .input, start: start, current: current, canvasSize: contentSize)
                                    },
                                    onCableEnded: { point in
                                        finishCable(from: .input, at: point, canvasSize: contentSize)
                                    }
                                )
                                .frame(width: frame.width, height: frame.height)
                                .position(CGPoint(x: frame.midX, y: frame.midY))
                            }

                            ForEach(viewModel.rackBoxes) { box in
                                if let frame = moduleFrame(for: box.id, canvasSize: contentSize) {
                                    RackBoxNodeView(
                                        box: box,
                                        accentOrange: accentOrange,
                                        accentCyan: accentCyan,
                                        isInputHighlighted: highlightedDestination == .box(box.id),
                                        canOpenEditor: viewModel.canOpenPluginEditor(for: box.id),
                                        editorButtonTitle: viewModel.editorButtonTitle(for: box.id),
                                        onCableChanged: { start, current in
                                            updateCable(from: .box(box.id), start: start, current: current, canvasSize: contentSize)
                                        },
                                        onCableEnded: { point in
                                            finishCable(from: .box(box.id), at: point, canvasSize: contentSize)
                                        },
                                        openPluginBrowser: { viewModel.openPluginBrowser(for: box) },
                                        openPluginEditor: { viewModel.openPluginEditor(for: box.id) },
                                        clearPlugin: { viewModel.clearPlugin(in: box.id) },
                                        removeBox: { viewModel.removeRackBox(box.id) },
                                        toggleBypass: { viewModel.toggleBoxBypass(box.id) }
                                    )
                                    .frame(width: frame.width, height: frame.height)
                                    .position(CGPoint(x: frame.midX, y: frame.midY))
                                }
                            }

                            if let frame = moduleFrame(for: viewModel.outputNodeID, canvasSize: contentSize) {
                                OutputNodeView(
                                    title: selectedOutputName,
                                    accent: accentOrange,
                                    isInputHighlighted: highlightedDestination == .output
                                )
                                .frame(width: frame.width, height: frame.height)
                                .position(CGPoint(x: frame.midX, y: frame.midY))
                            }

                            Canvas { context, _ in
                                drawConnections(in: &context, canvasSize: contentSize)
                            }
                            .allowsHitTesting(false)
                        }
                        .frame(width: canvasSize.width, height: contentSize.height, alignment: .topLeading)
                        .coordinateSpace(name: RackTheme.workspaceCoordinateSpace)
                        .contentShape(Rectangle())
                        .clipped()
                        .contextMenu {
                            Button("Add Box") {
                                viewModel.addRackBoxAndChoosePlugin()
                            }
                        }
                    }
                    .clipped()

                    MeterDock(engine: engine, accentOrange: accentOrange, accentCyan: accentCyan)
                        .frame(width: RackTheme.meterDockWidth)
                        .padding(18)
                }
            }
        }
        .background(RackTheme.workspaceFill)
    }

    private var workspaceHeader: some View {
        HStack {
            Text("Rack")
                .font(.custom("Avenir Next Condensed", size: 26))
                .fontWeight(.bold)
                .foregroundStyle(.white)

            Spacer()

            RackTheme.commandButton("Add Box", fill: accentCyan.opacity(0.25), enabled: true) {
                viewModel.addRackBoxAndChoosePlugin()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    private var selectedInputName: String {
        engine.availableInputDevices.first(where: { $0.id == engine.selectedInputDeviceID })?.name ?? "No input"
    }

    private var selectedOutputName: String {
        engine.availableOutputDevices.first(where: { $0.id == engine.selectedOutputDeviceID })?.name ?? "No output"
    }

    private func rackFrame(in size: CGSize) -> CGRect {
        let leftInset = RackTheme.canvasInset
        let topInset = RackTheme.canvasInset
        let rightInset = RackTheme.canvasInset + RackTheme.meterDockWidth + RackTheme.meterDockGap
        return CGRect(
            x: leftInset,
            y: topInset,
            width: max(520, size.width - leftInset - rightInset),
            height: size.height - topInset - RackTheme.canvasInset
        )
    }

    private func rackContentHeight(for canvasSize: CGSize) -> CGFloat {
        let moduleCount = max(2, viewModel.rackBoxes.count + 2)
        let totalModulesHeight = CGFloat(moduleCount) * RackTheme.verticalModuleHeight
        let totalSpacing = CGFloat(max(0, moduleCount - 1)) * RackTheme.verticalRackGap
        return totalModulesHeight + totalSpacing + RackTheme.canvasInset * 2
    }

    private func moduleFrame(for nodeID: UUID, canvasSize: CGSize) -> CGRect? {
        let orderedIDs = [viewModel.inputNodeID] + viewModel.rackBoxes.map(\.id) + [viewModel.outputNodeID]
        guard let index = orderedIDs.firstIndex(of: nodeID) else { return nil }
        let rack = rackFrame(in: canvasSize)
        let y = rack.minY + CGFloat(index) * (RackTheme.verticalModuleHeight + RackTheme.verticalRackGap)
        return CGRect(x: rack.minX, y: y, width: rack.width, height: RackTheme.verticalModuleHeight)
    }

    private func inputPortPoint(for nodeID: UUID, canvasSize: CGSize) -> CGPoint? {
        guard let frame = moduleFrame(for: nodeID, canvasSize: canvasSize) else { return nil }
        return CGPoint(x: frame.maxX - RackTheme.patchBayAnchorInset, y: inputPortY(for: nodeID, frame: frame))
    }

    private func outputPortPoint(for nodeID: UUID, canvasSize: CGSize) -> CGPoint? {
        guard let frame = moduleFrame(for: nodeID, canvasSize: canvasSize) else { return nil }
        return CGPoint(x: frame.maxX - RackTheme.patchBayAnchorInset, y: outputPortY(for: nodeID, frame: frame))
    }

    private func inputPortY(for nodeID: UUID, frame: CGRect) -> CGFloat {
        if nodeID == viewModel.outputNodeID {
            return frame.midY
        }
        return frame.midY - RackTheme.patchBayPortSpread
    }

    private func outputPortY(for nodeID: UUID, frame: CGRect) -> CGFloat {
        if nodeID == viewModel.inputNodeID {
            return frame.midY
        }
        return frame.midY + RackTheme.patchBayPortSpread
    }

    private func cableLaneX(for canvasSize: CGSize) -> CGFloat {
        let rack = rackFrame(in: canvasSize)
        return min(rack.maxX + 32, canvasSize.width - RackTheme.meterDockWidth - 16)
    }

    private func drawConnections(in context: inout GraphicsContext, canvasSize: CGSize) {
        for connection in viewModel.rackConnections {
            guard let start = outputPortPoint(for: connection.sourceID, canvasSize: canvasSize),
                  let end = inputPortPoint(for: connection.targetID, canvasSize: canvasSize) else { continue }
            drawCable(from: start, to: end, laneX: cableLaneX(for: canvasSize), color: RackTheme.cableBlue, in: &context)
        }

        if let activeCable,
           let start = activeCable.sourcePortPoint(in: canvasSize, viewModel: viewModel) {
            drawCable(from: start, to: activeCable.currentPoint, laneX: cableLaneX(for: canvasSize), color: RackTheme.cableAmber, in: &context)
        }
    }

    private func drawCable(from start: CGPoint, to end: CGPoint, laneX: CGFloat, color: Color, in context: inout GraphicsContext) {
        let outerX = max(laneX, start.x + 20, end.x + 20)
        let startExit = CGPoint(x: outerX, y: start.y)
        let endEntry = CGPoint(x: outerX, y: end.y)
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: startExit,
            control1: CGPoint(x: start.x + 12, y: start.y),
            control2: CGPoint(x: outerX - 18, y: start.y)
        )
        path.addLine(to: endEntry)
        path.addCurve(
            to: end,
            control1: CGPoint(x: outerX - 18, y: end.y),
            control2: CGPoint(x: end.x + 12, y: end.y)
        )
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        context.fill(Path(ellipseIn: CGRect(x: start.x - 5, y: start.y - 5, width: 10, height: 10)), with: .color(color))
        context.fill(Path(ellipseIn: CGRect(x: end.x - 5, y: end.y - 5, width: 10, height: 10)), with: .color(color))
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
        viewModel.connect(source: source, to: destination)
    }

    private func nearestDestination(to point: CGPoint, for source: RackCableSource, canvasSize: CGSize) -> RackRouteDestination? {
        let options: [RackRouteChoice] = {
            switch source {
            case .input:
                return viewModel.routeOptions(for: nil)
            case .box(let id):
                return viewModel.routeOptions(for: id)
            }
        }()

        var best: (destination: RackRouteDestination, distance: CGFloat)?
        for option in options {
            let targetPoint: CGPoint? = {
                switch option.destination {
                case .output:
                    return inputPortPoint(for: viewModel.outputNodeID, canvasSize: canvasSize)
                case .box(let id):
                    return inputPortPoint(for: id, canvasSize: canvasSize)
                }
            }()

            guard let targetPoint else { continue }
            let dx = targetPoint.x - point.x
            let dy = targetPoint.y - point.y
            let distance = sqrt(dx * dx + dy * dy)
            guard distance < 52 else { continue }

            if let best, best.distance <= distance { continue }
            best = (option.destination, distance)
        }

        return best?.destination
    }
}

private struct InputNodeView: View {
    let title: String
    let accent: Color
    let onCableChanged: (CGPoint, CGPoint) -> Void
    let onCableEnded: (CGPoint) -> Void

    var body: some View {
        FixedNodeShell(
            role: "INPUT",
            name: title,
            accent: accent,
            leadingPort: false,
            trailingPort: true,
            onCableChanged: onCableChanged,
            onCableEnded: onCableEnded
        )
    }
}

private struct OutputNodeView: View {
    let title: String
    let accent: Color
    let isInputHighlighted: Bool

    var body: some View {
        FixedNodeShell(
            role: "OUTPUT",
            name: title,
            accent: accent,
            leadingPort: true,
            trailingPort: false,
            isLeadingPortHighlighted: isInputHighlighted,
            onCableChanged: nil,
            onCableEnded: nil
        )
    }
}

private struct FixedNodeShell: View {
    let role: String
    let name: String
    let accent: Color
    let leadingPort: Bool
    let trailingPort: Bool
    var isLeadingPortHighlighted: Bool = false
    let onCableChanged: ((CGPoint, CGPoint) -> Void)?
    let onCableEnded: ((CGPoint) -> Void)?

    var body: some View {
        ModuleFrame(accent: accent) {
            VStack(alignment: .leading, spacing: 8) {
                Text(role)
                    .font(RackTheme.labelFont)
                    .foregroundStyle(accent)
                Text(name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer()
                Text(role == "INPUT" ? "Source" : "Destination")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.65))
            }
            .padding(.trailing, RackTheme.patchBayWidth)
        }
        .overlay(alignment: .trailing) {
            RackPatchBay(
                color: accent,
                showsInput: leadingPort,
                showsOutput: trailingPort,
                inputLabel: "IN",
                outputLabel: "OUT",
                isInputHighlighted: isLeadingPortHighlighted,
                onCableChanged: onCableChanged,
                onCableEnded: onCableEnded,
                compact: true
            )
            .frame(width: RackTheme.patchBayWidth)
        }
    }
}

private struct RackBoxNodeView: View {
    let box: RackBoxNode
    let accentOrange: Color
    let accentCyan: Color
    let isInputHighlighted: Bool
    let canOpenEditor: Bool
    let editorButtonTitle: String
    let onCableChanged: (CGPoint, CGPoint) -> Void
    let onCableEnded: (CGPoint) -> Void
    let openPluginBrowser: () -> Void
    let openPluginEditor: () -> Void
    let clearPlugin: () -> Void
    let removeBox: () -> Void
    let toggleBypass: () -> Void

    private var accent: Color {
        box.assignedPlugin?.format == .audioUnit ? accentCyan : accentOrange
    }

    var body: some View {
        ModuleFrame(accent: accent) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(box.title.uppercased())
                            .font(RackTheme.labelFont)
                            .foregroundStyle(accent)
                        Text(box.displayName)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(box.vendorLine)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.48))
                    }
                    Spacer(minLength: 0)
                    Text(box.isBypassed ? "BYPASSED" : "LIVE")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(box.isBypassed ? Color.white.opacity(0.45) : accent)
                }

                HStack(spacing: 8) {
                    if box.assignedPlugin == nil {
                        RackTheme.tinyButton("Plug-In", fill: accentCyan.opacity(0.22), enabled: true, action: openPluginBrowser)
                    }
                    RackTheme.tinyButton(editorButtonTitle, fill: accentOrange.opacity(0.22), enabled: canOpenEditor, action: openPluginEditor)
                    RackTheme.tinyButton(box.isBypassed ? "Enable" : "Bypass", fill: Color.white.opacity(0.07), enabled: box.assignedPlugin != nil, action: toggleBypass)
                }

                HStack(spacing: 8) {
                    RackTheme.tinyButton("Clear", fill: Color.white.opacity(0.06), enabled: box.assignedPlugin != nil, action: clearPlugin)
                    RackTheme.tinyButton("Remove", fill: Color.white.opacity(0.06), enabled: true, action: removeBox)
                }

                Spacer(minLength: 0)
            }
            .padding(.trailing, RackTheme.patchBayWidth)
        }
        .overlay(alignment: .trailing) {
            RackPatchBay(
                color: accent,
                showsInput: true,
                showsOutput: true,
                inputLabel: "IN",
                outputLabel: "OUT",
                isInputHighlighted: isInputHighlighted,
                onCableChanged: onCableChanged,
                onCableEnded: onCableEnded
            )
            .frame(width: RackTheme.patchBayWidth)
        }
    }
}

private struct ModuleFrame<Content: View>: View {
    let accent: Color
    var height: CGFloat = RackTheme.verticalModuleHeight
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(accent)
                .frame(height: 3)

            content
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: height - 3, maxHeight: height - 3, alignment: .topLeading)
                .background(
                    Rectangle()
                        .fill(Color(red: 0.09, green: 0.11, blue: 0.15))
                )
        }
        .overlay(Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .overlay(alignment: .leading) {
            rackEar
        }
        .overlay(alignment: .trailing) {
            rackEar
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 10)
    }

    private var rackEar: some View {
        VStack(spacing: 16) {
            RackScrew()
            Spacer()
            RackScrew()
        }
        .frame(width: 16)
        .padding(.vertical, 12)
    }
}

private struct RackScrew: View {
    var body: some View {
        Circle()
            .fill(Color.black.opacity(0.62))
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
    }
}

private struct RackPort: View {
    let label: String
    let color: Color
    var isHighlighted: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if label == "IN" {
                Text(label)
                    .font(RackTheme.labelFont)
                    .foregroundStyle(isHighlighted ? .white : Color.white.opacity(0.55))
            }
            Circle()
                .fill(color.opacity(isHighlighted ? 1 : 0.95))
                .frame(width: isHighlighted ? 18 : 14, height: isHighlighted ? 18 : 14)
                .overlay(Circle().stroke(Color.white.opacity(isHighlighted ? 0.9 : 0.22), lineWidth: isHighlighted ? 2 : 1))
                .shadow(color: isHighlighted ? color.opacity(0.75) : .clear, radius: 12)
            if label == "OUT" {
                Text(label)
                    .font(RackTheme.labelFont)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
    }
}

private struct RackPatchBay: View {
    let color: Color
    let showsInput: Bool
    let showsOutput: Bool
    let inputLabel: String
    let outputLabel: String
    var isInputHighlighted: Bool = false
    let onCableChanged: ((CGPoint, CGPoint) -> Void)?
    let onCableEnded: ((CGPoint) -> Void)?
    var compact: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let laneX = width - RackTheme.patchBayAnchorInset
            let inputY = compact || !showsOutput ? height * 0.5 : height * 0.36
            let outputY = compact || !showsInput ? height * 0.5 : height * 0.70

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1, height: height - 28)
                    .position(x: width - RackTheme.patchBayLaneInset, y: height * 0.5)

                Text("PATCH")
                    .font(RackTheme.labelFont)
                    .foregroundStyle(Color.white.opacity(0.35))
                    .position(x: width - (RackTheme.patchBayWidth * 0.42), y: 16)

                if showsInput {
                    RackPatchPort(label: inputLabel, color: color, isHighlighted: isInputHighlighted)
                        .position(x: laneX, y: inputY)
                }

                if showsOutput, let onCableChanged, let onCableEnded {
                    RackOutputPort(label: outputLabel, color: color, onCableChanged: onCableChanged, onCableEnded: onCableEnded)
                        .position(x: laneX, y: outputY)
                }
            }
        }
        .allowsHitTesting(showsInput || showsOutput)
    }
}

private struct RackPatchPort: View {
    let label: String
    let color: Color
    var isHighlighted: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(RackTheme.labelFont)
                .foregroundStyle(isHighlighted ? .white : Color.white.opacity(0.55))
            Circle()
                .fill(color.opacity(isHighlighted ? 1 : 0.95))
                .frame(width: isHighlighted ? 18 : 14, height: isHighlighted ? 18 : 14)
                .overlay(Circle().stroke(Color.white.opacity(isHighlighted ? 0.9 : 0.22), lineWidth: isHighlighted ? 2 : 1))
                .shadow(color: isHighlighted ? color.opacity(0.75) : .clear, radius: 12)
        }
        .fixedSize()
    }
}

private struct RackOutputPort: View {
    let label: String
    let color: Color
    let onCableChanged: (CGPoint, CGPoint) -> Void
    let onCableEnded: (CGPoint) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(RackTheme.labelFont)
                .foregroundStyle(Color.white.opacity(0.55))
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(RackTheme.workspaceCoordinateSpace))
                .onChanged { value in
                    onCableChanged(value.startLocation, value.location)
                }
                .onEnded { value in
                    onCableEnded(value.location)
                }
        )
    }
}

private struct RackVerticalRails: View {
    let frame: CGRect
    let contentHeight: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
                .frame(width: frame.width, height: contentHeight - frame.minY - RackTheme.canvasInset)
                .position(x: frame.midX, y: frame.minY + (contentHeight - frame.minY - RackTheme.canvasInset) / 2)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 3, height: contentHeight - frame.minY - RackTheme.canvasInset)
                .position(x: frame.minX + 13, y: frame.minY + (contentHeight - frame.minY - RackTheme.canvasInset) / 2)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 3, height: contentHeight - frame.minY - RackTheme.canvasInset)
                .position(x: frame.maxX - 13, y: frame.minY + (contentHeight - frame.minY - RackTheme.canvasInset) / 2)
        }
    }
}

private struct MeterDock: View {
    @ObservedObject var engine: AudioEngineController
    let accentOrange: Color
    let accentCyan: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Meters")
                .font(.custom("Avenir Next Condensed", size: 22))
                .fontWeight(.bold)
                .foregroundStyle(.white)

            HStack(alignment: .bottom, spacing: 18) {
                VerticalMeter(label: "Input", level: engine.inputPeak, accent: .green)
                VerticalMeter(label: "Output", level: engine.outputPeak, accent: accentCyan)
                VerticalReductionMeter(label: "GR", reductionDB: engine.gainReductionDB, accent: accentOrange)
            }

            HStack(spacing: 10) {
                RackTheme.metricBox(label: "Clip", value: "\(engine.clippedSamples)")
                RackTheme.metricBox(label: "XRuns", value: "\(engine.xrunsOverruns)")
            }
        }
        .padding(16)
        .background(RackTheme.sectionFill)
        .overlay(Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct VerticalMeter: View {
    let label: String
    let level: Float
    let accent: Color
    private let scale: [Int] = [0, -12, -24, -36, -48, -60]

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(scale, id: \.self) { value in
                    Text("\(value)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.42))
                    if value != scale.last {
                        Spacer()
                    }
                }
            }
            .frame(height: 220)

            VStack(spacing: 8) {
                Text(RackTheme.dbText(for: level))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)

                GeometryReader { _ in
                    let fill = RackTheme.meterNormalized(level)
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.white.opacity(0.05))
                        VStack(spacing: 1) {
                            ForEach(0..<28, id: \.self) { index in
                                Rectangle()
                                    .fill(index >= Int((1 - fill) * 28) ? accent : Color.white.opacity(0.06))
                                    .frame(height: 6)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                    }
                }
                .frame(width: 52, height: 220)

                Text(label.uppercased())
                    .font(RackTheme.labelFont)
                    .foregroundStyle(Color.white.opacity(0.62))
            }
        }
    }
}

private struct VerticalReductionMeter: View {
    let label: String
    let reductionDB: Float
    let accent: Color
    private let scale: [Int] = [24, 18, 12, 6, 0]

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(scale, id: \.self) { value in
                    Text("\(value)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.42))
                    if value != scale.last {
                        Spacer()
                    }
                }
            }
            .frame(height: 220)

            VStack(spacing: 8) {
                Text(String(format: "%.1f", reductionDB))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)

                GeometryReader { _ in
                    let fill = min(max(Double(reductionDB) / 24.0, 0), 1)
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.white.opacity(0.05))
                        VStack(spacing: 1) {
                            ForEach(0..<28, id: \.self) { index in
                                Rectangle()
                                    .fill(index >= Int((1 - fill) * 28) ? accent : Color.white.opacity(0.06))
                                    .frame(height: 6)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                    }
                }
                .frame(width: 52, height: 220)

                Text(label.uppercased())
                    .font(RackTheme.labelFont)
                    .foregroundStyle(Color.white.opacity(0.62))
            }
        }
    }
}

private struct PluginBrowserSheet: View {
    @ObservedObject var viewModel: MainViewModel
    let target: PluginBrowserTarget
    let accentOrange: Color
    let accentCyan: Color
    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery = ""
    @State private var filter: PluginBrowserFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Choose Plug-In")
                    .font(.custom("Avenir Next Condensed", size: 28))
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                Spacer()
                RackTheme.commandButton("Close", fill: Color.white.opacity(0.08), enabled: true) {
                    viewModel.finishPluginBrowserSelection(for: target, committed: false)
                    dismiss()
                }
            }

            Text(target.slotTitle)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.58))

            HStack(spacing: 12) {
                RackTheme.textEntryField("Search", text: $searchQuery)
                Picker("Format", selection: $filter) {
                    ForEach(PluginBrowserFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }

            List {
                ForEach(viewModel.filteredPlugins(searchQuery: searchQuery, filter: filter)) { plugin in
                    Button {
                        viewModel.assignPlugin(plugin, to: target.slotID)
                        viewModel.finishPluginBrowserSelection(for: target, committed: true)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Text(plugin.format.rawValue)
                                .font(RackTheme.labelFont)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Rectangle().fill((plugin.format == .audioUnit ? accentCyan : accentOrange).opacity(0.24)))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(plugin.name)
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text("\(plugin.vendor) • \(plugin.category)")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.62))
                            }

                            Spacer()

                            Text(plugin.location)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.5))
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .padding(22)
        .frame(minWidth: 760, minHeight: 560)
        .background(RackTheme.background)
        .onDisappear {
            viewModel.finishPluginBrowserSelection(for: target, committed: viewModel.boxHasAssignedPlugin(target.slotID))
        }
    }
}

private struct PluginSettingsSheet: View {
    @ObservedObject var viewModel: MainViewModel
    let accentOrange: Color
    let accentCyan: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Plug-In Settings")
                    .font(.custom("Avenir Next Condensed", size: 28))
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                Spacer()
                RackTheme.commandButton("Close", fill: Color.white.opacity(0.08), enabled: true) {
                    dismiss()
                }
            }

            HStack(spacing: 12) {
                RackTheme.metricBox(label: "VST2", value: "\(viewModel.vst2Count)")
                RackTheme.metricBox(label: "VST3", value: "\(viewModel.vst3Count)")
                RackTheme.metricBox(label: "AU", value: "\(viewModel.audioUnitCount)")
            }

            HStack(spacing: 10) {
                RackTheme.commandButton(viewModel.pluginCatalogRefreshInFlight ? "Scanning..." : "Rescan", fill: accentCyan.opacity(0.24), enabled: true) {
                    viewModel.refreshPluginCatalog()
                }

                RackTheme.textEntryField("Manual VST/VST3 path", text: $viewModel.manualPluginPathDraft)

                RackTheme.commandButton("Add", fill: accentOrange.opacity(0.24), enabled: true) {
                    viewModel.addManualPluginPath()
                }
            }

            if let warning = viewModel.pluginSettingsWarning, !warning.isEmpty {
                Text(warning)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(accentOrange)
            }

            List {
                ForEach(viewModel.manualPluginPaths, id: \.self) { path in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(path)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.58))
                                .lineLimit(2)
                        }
                        Spacer()
                        RackTheme.commandButton("Remove", fill: Color.white.opacity(0.08), enabled: true) {
                            viewModel.removeManualPluginPath(path)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .padding(22)
        .frame(minWidth: 820, minHeight: 500)
        .background(RackTheme.background)
    }
}

private struct SavePresetSheet: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Preset")
                .font(.custom("Avenir Next Condensed", size: 24))
                .fontWeight(.bold)
                .foregroundStyle(.white)

            RackTheme.textEntryField("Preset name", text: $viewModel.savePresetName)

            HStack {
                Spacer()
                RackTheme.commandButton("Cancel", fill: Color.white.opacity(0.08), enabled: true) {
                    viewModel.showingSavePresetSheet = false
                    dismiss()
                }
                RackTheme.commandButton("Save", fill: Color(red: 0.25, green: 0.83, blue: 0.95).opacity(0.24), enabled: true) {
                    viewModel.saveCurrentPreset()
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(RackTheme.background)
    }
}

private struct RackWorkspaceGrid: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { _ in
            Canvas { context, size in
                let minor: CGFloat = 28
                let major: CGFloat = 140

                for x in stride(from: 0, through: size.width, by: minor) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    let isMajor = truncatingRemainder(dividingBy: major, value: x) < 0.1
                    context.stroke(path, with: .color(Color.white.opacity(isMajor ? 0.06 : 0.025)), lineWidth: isMajor ? 1.2 : 0.6)
                }

                for y in stride(from: 0, through: size.height, by: minor) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    let isMajor = truncatingRemainder(dividingBy: major, value: y) < 0.1
                    context.stroke(path, with: .color(Color.white.opacity(isMajor ? 0.06 : 0.025)), lineWidth: isMajor ? 1.2 : 0.6)
                }
            }
        }
    }

    private func truncatingRemainder(dividingBy divisor: CGFloat, value: CGFloat) -> CGFloat {
        value.truncatingRemainder(dividingBy: divisor)
    }
}

private struct ActiveCable {
    let source: RackCableSource
    var currentPoint: CGPoint
    var startPoint: CGPoint

    @MainActor
    func sourcePortPoint(in canvasSize: CGSize, viewModel: MainViewModel) -> CGPoint? {
        startPoint
    }
}

@MainActor
private enum RackTheme {
    static let workspaceCoordinateSpace = "RackWorkspace"
    static let cableBlue = Color(red: 0.29, green: 0.83, blue: 0.95)
    static let cableAmber = Color(red: 0.96, green: 0.62, blue: 0.23)
    static let moduleSize = CGSize(width: 224, height: 160)
    static let verticalModuleHeight: CGFloat = 116
    static let verticalRackGap: CGFloat = 28
    static let canvasInset: CGFloat = 28
    static let meterDockWidth: CGFloat = 320
    static let meterDockGap: CGFloat = 24
    static let patchBayWidth: CGFloat = 120
    static let patchBayAnchorInset: CGFloat = 34
    static let patchBayLaneInset: CGFloat = 16
    static let patchBayPortSpread: CGFloat = 18
    static let labelFont = Font.system(size: 10, weight: .black, design: .monospaced)

    static var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.03, green: 0.04, blue: 0.06),
                Color(red: 0.01, green: 0.04, blue: 0.08),
                Color(red: 0.03, green: 0.04, blue: 0.07)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            LinearGradient(
                colors: [Color.clear, Color(red: 0.01, green: 0.18, blue: 0.33).opacity(0.18), Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .ignoresSafeArea()
    }

    static let sectionFill = Color(red: 0.09, green: 0.11, blue: 0.15)
    static let workspaceFill = Color(red: 0.07, green: 0.09, blue: 0.13)

    static func menuField<MenuContent: View>(_ title: String, selectionText: String, disabled: Bool = false, @ViewBuilder content: () -> MenuContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(labelFont)
                .foregroundStyle(Color.white.opacity(0.44))

            Menu {
                content()
            } label: {
                HStack(spacing: 10) {
                    Text(selectionText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(disabled ? Color.white.opacity(0.5) : .white)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(disabled ? Color.white.opacity(0.42) : Color.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Rectangle().fill(Color.white.opacity(0.06)))
                .overlay(Rectangle().stroke(Color.white.opacity(0.06), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .disabled(disabled)
        }
    }

    static func commandButton(_ title: String, fill: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.74))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Rectangle().fill(enabled ? fill : fill.opacity(0.72)))
            .overlay(Rectangle().stroke(Color.white.opacity(0.05), lineWidth: 1))
            .disabled(!enabled)
    }

    static func tinyButton(_ title: String, fill: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.74))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Rectangle().fill(enabled ? fill : fill.opacity(0.72)))
            .overlay(Rectangle().stroke(Color.white.opacity(0.05), lineWidth: 1))
            .disabled(!enabled)
    }

    static func textEntryField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Rectangle().fill(Color.white.opacity(0.06)))
            .overlay(Rectangle().stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    static func metricBox(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(labelFont)
                .foregroundStyle(Color.white.opacity(0.44))
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Rectangle().fill(Color.white.opacity(0.05)))
        .overlay(Rectangle().stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    static func meterNormalized(_ level: Float) -> Double {
        let db = 20 * log10(max(level, 0.000_001))
        return min(max((Double(db) + 60) / 60, 0), 1)
    }

    static func dbText(for level: Float) -> String {
        let db = 20 * log10(max(level, 0.000_001))
        if db <= -59.5 {
            return "-inf"
        }
        return String(format: "%.0f", db)
    }
}

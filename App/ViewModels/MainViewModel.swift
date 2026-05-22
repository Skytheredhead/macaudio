import CoreAudio
import CoreGraphics
import Combine
import Foundation

@MainActor
final class MainViewModel: ObservableObject {
    let engine: AudioEngineController
    let inputNodeID = UUID(uuidString: "8FE29C3D-7B80-4EAF-9B9F-D301A75A8001")!
    let outputNodeID = UUID(uuidString: "6D801B8C-572B-4F98-BF25-7D78017F7F0A")!
    let leftInputNodeID = UUID(uuidString: "6A0D8E86-4C67-4668-BDBB-F42D6CBA2F66")!
    let leftOutputNodeID = UUID(uuidString: "7F79CE29-76DE-464D-A4BF-5D23B2B31F73")!
    let rightInputNodeID = UUID(uuidString: "056E85E5-26F1-4482-9C80-C2C52C5BE569")!
    let rightOutputNodeID = UUID(uuidString: "8D7DE4D6-9F19-4FAD-BA18-EDE7A1BF3FC3")!

    @Published var settings: VoiceProcessingSettings {
        didSet {
            engine.updateSettings(settings)
        }
    }

    @Published var customPresets: [UserPreset] = [] {
        didSet {
            PresetStore.saveUserPresets(customPresets)
            presetChoices = PresetStore.allChoices(customPresets: customPresets)
        }
    }
    @Published var presetChoices: [PresetChoice] = []
    @Published var selectedPresetID: String = VoicePreset.cleanVoice.id
    @Published var savePresetName: String = ""
    @Published var showingSavePresetSheet = false

    @Published var availablePlugins: [PluginDescriptor] = []
    @Published var pluginCatalogRefreshInFlight = false
    @Published var pluginBrowserTarget: PluginBrowserTarget?
    @Published var pluginEditorSession: PluginEditorSession?
    @Published var showingPluginSettingsSheet = false
    @Published var manualPluginPaths: [String] = []
    @Published var manualPluginPathDraft: String = ""
    @Published var pluginSettingsWarning: String?

    @Published var rackBoxes: [RackBoxNode] = []
    @Published var inputRouteTarget: RackRouteDestination = .output
    @Published var leftRackBoxes: [RackBoxNode] = []
    @Published var leftInputRouteTarget: RackRouteDestination = .output
    @Published var rightRackBoxes: [RackBoxNode] = []
    @Published var rightInputRouteTarget: RackRouteDestination = .output
    @Published var rackMode: RackWorkspaceMode = .single
    @Published var dualMonoEndMode: DualMonoEndMode = .separate

    private var engineChangeCancellable: AnyCancellable?

    init(engine: AudioEngineController = AudioEngineController(), scanPluginsOnInit: Bool = true) {
        self.engine = engine
        self.settings = VoicePreset.cleanVoice.settings
        self.customPresets = PresetStore.loadUserPresets()
        self.presetChoices = PresetStore.allChoices(customPresets: customPresets)
        self.manualPluginPaths = ManualPluginPathStore.loadPaths()
        self.engineChangeCancellable = engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        engine.setPreset(.cleanVoice)
        engine.updateSettings(settings)
        refreshDevices()
        if scanPluginsOnInit {
            refreshPluginCatalog()
        }
        syncRackToEngine()
    }

    var selectedPresetChoice: PresetChoice? {
        presetChoices.first(where: { $0.id == selectedPresetID })
    }

    var canDeleteSelectedPreset: Bool {
        selectedPresetChoice?.isBuiltIn == false
    }

    var vst2Count: Int {
        availablePlugins.filter { $0.format == .vst2 }.count
    }

    var vst3Count: Int {
        availablePlugins.filter { $0.format == .vst3 }.count
    }

    var audioUnitCount: Int {
        availablePlugins.filter { $0.format == .audioUnit }.count
    }

    var assignedPluginCount: Int {
        rackBoxes.filter { $0.assignedPlugin != nil }.count
    }

    var rackConnections: [RackConnection] {
        rackConnections(in: .main)
    }

    func assignedPluginCount(in lane: RackLane) -> Int {
        rackBoxes(in: lane).filter { $0.assignedPlugin != nil }.count
    }

    func rackConnections(in lane: RackLane) -> [RackConnection] {
        var connections: [RackConnection] = []
        if let targetID = resolvedTargetID(for: inputRouteTarget(in: lane), in: lane) {
            connections.append(RackConnection(sourceID: inputNodeID(for: lane), targetID: targetID, title: lane.inputTitle))
        }

        for box in rackBoxes(in: lane) {
            if let targetID = resolvedTargetID(for: box.routeTarget, in: lane) {
                connections.append(RackConnection(sourceID: box.id, targetID: targetID, title: box.displayName))
            }
        }
        return connections
    }

    func toggleRunState() {
        if engine.isRunning {
            engine.stop()
        } else {
            engine.updateSettings(settings)
            engine.start()
        }
    }

    func refreshDevices() {
        engine.refreshInputDevices()
    }

    func refreshPluginCatalog() {
        guard !pluginCatalogRefreshInFlight else { return }
        pluginCatalogRefreshInFlight = true
        let manualPaths = manualPluginPaths

        Task.detached(priority: .userInitiated) {
            let plugins = PluginCatalog.scanAvailablePlugins(manualPaths: manualPaths)
            await MainActor.run {
                self.availablePlugins = plugins
                self.pluginCatalogRefreshInFlight = false
                self.reconcileRackGraph()
            }
        }
    }

    func filteredPlugins(searchQuery: String, filter: PluginBrowserFilter) -> [PluginDescriptor] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return availablePlugins.filter { plugin in
            guard filter.includes(plugin.format) else { return false }
            guard !query.isEmpty else { return true }
            return plugin.name.localizedCaseInsensitiveContains(query)
                || plugin.vendor.localizedCaseInsensitiveContains(query)
                || plugin.category.localizedCaseInsensitiveContains(query)
        }
    }

    func updateInputDevice() {
        engine.updateInputDevice(engine.selectedInputDeviceID)
    }

    func updateOutputDevice() {
        engine.updateOutputDevice(engine.selectedOutputDeviceID)
    }

    func updateMonitorDevice() {
        engine.updateMonitorDevice(engine.selectedMonitorDeviceID)
    }

    func updateMonitorEnabled() {
        engine.setMonitorEnabled(engine.monitorEnabled)
    }

    func applyLatencyQuality() {
        engine.applyLatencyQuality(engine.latencyQuality)
    }

    func updateIOConfiguration() {
        engine.updateIOConfiguration(sampleRate: engine.selectedSampleRate, bufferSize: engine.selectedBufferSize)
    }

    func updateInputChannelMode(_ mode: AudioChannelMode) {
        engine.updateInputChannelMode(mode)
    }

    func updateOutputChannelMode(_ mode: AudioChannelMode) {
        engine.updateOutputChannelMode(mode)
    }

    func updateDualMonoEndMode(_ mode: DualMonoEndMode) {
        dualMonoEndMode = mode
        engine.updateDualMonoEndMode(mode)
    }

    func selectInputDevice(_ deviceID: AudioDeviceID) {
        guard engine.selectedInputDeviceID != deviceID else { return }
        engine.selectedInputDeviceID = deviceID
        updateInputDevice()
    }

    func selectOutputDevice(_ deviceID: AudioDeviceID) {
        guard engine.selectedOutputDeviceID != deviceID else { return }
        engine.selectedOutputDeviceID = deviceID
        updateOutputDevice()
    }

    func selectMonitorDevice(_ deviceID: AudioDeviceID) {
        guard engine.selectedMonitorDeviceID != deviceID else { return }
        engine.selectedMonitorDeviceID = deviceID
        updateMonitorDevice()
    }

    func setMonitorEnabled(_ enabled: Bool) {
        guard engine.monitorEnabled != enabled else { return }
        engine.monitorEnabled = enabled
        updateMonitorEnabled()
    }

    func updateSampleRate(_ sampleRate: SampleRateOption) {
        guard engine.selectedSampleRate != sampleRate else { return }
        engine.selectedSampleRate = sampleRate
        updateIOConfiguration()
    }

    func updateBufferSize(_ bufferSize: BufferSizeOption) {
        guard engine.selectedBufferSize != bufferSize else { return }
        engine.selectedBufferSize = bufferSize
        updateIOConfiguration()
    }

    func setDualMonoEnabled(_ enabled: Bool) {
        if enabled {
            enableDualMono()
        } else {
            collapseDualMonoToSingle()
        }
    }

    func mergeDualMonoRackToSingle() {
        guard rackMode == .dualMono else { return }
        rackBoxes = duplicatedRackBoxes(from: leftRackBoxes)
        inputRouteTarget = remappedRouteTarget(from: leftInputRouteTarget, sourceBoxes: leftRackBoxes, destinationBoxes: rackBoxes)
        rackMode = .single
        engine.updateRackWorkspaceMode(.single)
        reflowRackLayout(in: .main)
        syncRackToEngine()
    }

    private func enableDualMono() {
        guard rackMode != .dualMono else { return }
        leftRackBoxes = duplicatedRackBoxes(from: rackBoxes)
        leftInputRouteTarget = remappedRouteTarget(from: inputRouteTarget, sourceBoxes: rackBoxes, destinationBoxes: leftRackBoxes)
        rightRackBoxes = duplicatedRackBoxes(from: rackBoxes)
        rightInputRouteTarget = remappedRouteTarget(from: inputRouteTarget, sourceBoxes: rackBoxes, destinationBoxes: rightRackBoxes)
        rackMode = .dualMono
        engine.updateRackWorkspaceMode(.dualMono)
        engine.updateInputChannelMode(.stereo)
        engine.updateOutputChannelMode(.stereo)
        reflowRackLayout(in: .left)
        reflowRackLayout(in: .right)
        syncRackToEngine()
    }

    private func collapseDualMonoToSingle() {
        guard rackMode != .single else { return }
        rackBoxes = duplicatedRackBoxes(from: leftRackBoxes.isEmpty ? rightRackBoxes : leftRackBoxes)
        let sourceBoxes = leftRackBoxes.isEmpty ? rightRackBoxes : leftRackBoxes
        let sourceRoute = leftRackBoxes.isEmpty ? rightInputRouteTarget : leftInputRouteTarget
        inputRouteTarget = remappedRouteTarget(from: sourceRoute, sourceBoxes: sourceBoxes, destinationBoxes: rackBoxes)
        rackMode = .single
        engine.updateRackWorkspaceMode(.single)
        reflowRackLayout(in: .main)
        syncRackToEngine()
    }

    func selectPreset(id: String) {
        guard let choice = presetChoices.first(where: { $0.id == id }) else { return }
        selectedPresetID = id
        settings = choice.settings
        engine.updateSettings(settings)
    }

    func beginSavingPreset() {
        savePresetName = selectedPresetChoice?.isBuiltIn == false ? (selectedPresetChoice?.name ?? "") : ""
        showingSavePresetSheet = true
    }

    func saveCurrentPreset() {
        let trimmed = savePresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let existingIndex = customPresets.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            customPresets[existingIndex].settings = settings
            selectedPresetID = "user:\(customPresets[existingIndex].id.uuidString)"
        } else {
            let preset = UserPreset(id: UUID(), name: trimmed, settings: settings)
            customPresets.append(preset)
            selectedPresetID = "user:\(preset.id.uuidString)"
        }
        showingSavePresetSheet = false
    }

    func deleteSelectedPreset() {
        guard let choice = selectedPresetChoice, !choice.isBuiltIn else { return }
        customPresets.removeAll { "user:\($0.id.uuidString)" == choice.id }
        selectPreset(id: VoicePreset.cleanVoice.id)
    }

    func addRackBox(at position: CGPoint? = nil) {
        addRackBox(in: .main, at: position)
    }

    func addRackBox(in lane: RackLane, at position: CGPoint? = nil) {
        let existingBoxes = rackBoxes(in: lane)
        let newBox = RackBoxNode(
            id: UUID(),
            title: "Box \(existingBoxes.count + 1)",
            assignedPlugin: nil,
            isBypassed: false,
            position: position ?? suggestedPosition(for: existingBoxes.count),
            routeTarget: .output
        )

        appendRackBox(newBox, in: lane)
        if rackBoxes(in: lane).count == 1 {
            setInputRouteTarget(.box(newBox.id), in: lane)
        }
        if position == nil {
            reflowRackLayout(in: lane)
        }
    }

    func addRackBoxAndChoosePlugin(at position: CGPoint? = nil) {
        addRackBoxAndChoosePlugin(in: .main, at: position)
    }

    func addRackBoxAndChoosePlugin(in lane: RackLane, at position: CGPoint? = nil) {
        let existingBoxes = rackBoxes(in: lane)
        let newBox = RackBoxNode(
            id: UUID(),
            title: "Box \(existingBoxes.count + 1)",
            assignedPlugin: nil,
            isBypassed: false,
            position: position ?? suggestedPosition(for: existingBoxes.count),
            routeTarget: .output
        )

        appendRackBox(newBox, in: lane)
        if rackBoxes(in: lane).count == 1 {
            setInputRouteTarget(.box(newBox.id), in: lane)
        }
        if position == nil {
            reflowRackLayout(in: lane)
        }
        pluginBrowserTarget = PluginBrowserTarget(slotID: newBox.id, slotTitle: newBox.title, lane: lane, removeIfCancelled: true)
    }

    func removeRackBox(_ boxID: UUID) {
        removeRackBox(boxID, in: lane(containing: boxID) ?? .main)
    }

    func removeRackBox(_ boxID: UUID, in lane: RackLane) {
        if pluginBrowserTarget?.slotID == boxID {
            pluginBrowserTarget = nil
        }
        if pluginEditorSession?.boxID == boxID {
            pluginEditorSession = nil
        }
        removeRackBoxWithID(boxID, in: lane)

        if inputRouteTarget(in: lane) == .box(boxID) {
            setInputRouteTarget(.output, in: lane)
        }

        mutateRackBoxes(in: lane) { boxes in
            for index in boxes.indices where boxes[index].routeTarget == .box(boxID) {
                boxes[index].routeTarget = .output
            }
        }

        reflowRackLayout(in: lane)
        syncRackToEngine()
    }

    func moveRackBox(_ boxID: UUID, to position: CGPoint, in canvasSize: CGSize) {
        moveRackBox(boxID, to: position, in: canvasSize, lane: lane(containing: boxID) ?? .main)
    }

    func moveRackBox(_ boxID: UUID, to position: CGPoint, in canvasSize: CGSize, lane: RackLane) {
        mutateRackBoxes(in: lane) { boxes in
            guard let index = boxes.firstIndex(where: { $0.id == boxID }) else { return }
            boxes[index].position = clamped(position: position, in: canvasSize)
        }
    }

    func openPluginBrowser(for box: RackBoxNode) {
        openPluginBrowser(for: box, in: lane(containing: box.id) ?? .main)
    }

    func openPluginBrowser(for box: RackBoxNode, in lane: RackLane) {
        guard box.assignedPlugin == nil else { return }
        pluginBrowserTarget = PluginBrowserTarget(slotID: box.id, slotTitle: box.title, lane: lane, removeIfCancelled: false)
    }

    func assignPlugin(_ plugin: PluginDescriptor, to boxID: UUID) {
        let lane = lane(containing: boxID) ?? .main
        guard let box = rackBoxes(in: lane).first(where: { $0.id == boxID }) else { return }
        if box.assignedPlugin?.id == plugin.id {
            pluginBrowserTarget = nil
            return
        }
        mutateRackBoxes(in: lane) { boxes in
            guard let index = boxes.firstIndex(where: { $0.id == boxID }) else { return }
            boxes[index].assignedPlugin = plugin
            boxes[index].isBypassed = false
        }
        pluginBrowserTarget = nil
        syncRackToEngine()
    }

    func finishPluginBrowserSelection(for target: PluginBrowserTarget, committed: Bool) {
        if pluginBrowserTarget?.slotID == target.slotID {
            pluginBrowserTarget = nil
        }
        guard !committed, target.removeIfCancelled else { return }
        guard let box = rackBoxes(in: target.lane).first(where: { $0.id == target.slotID }), box.assignedPlugin == nil else { return }
        removeRackBox(target.slotID, in: target.lane)
    }

    func boxHasAssignedPlugin(_ boxID: UUID) -> Bool {
        guard let lane = lane(containing: boxID) else { return false }
        return rackBoxes(in: lane).first(where: { $0.id == boxID })?.assignedPlugin != nil
    }

    func canOpenPluginEditor(for boxID: UUID) -> Bool {
        guard let lane = lane(containing: boxID),
              let box = rackBoxes(in: lane).first(where: { $0.id == boxID }),
              let plugin = box.assignedPlugin else {
            return false
        }
        if engine.liveProcessorPlugin(for: boxID) != nil {
            return true
        }
        return resolvedProcessorPlugin(for: plugin) != nil
    }

    func editorButtonTitle(for boxID: UUID) -> String {
        guard let lane = lane(containing: boxID),
              let box = rackBoxes(in: lane).first(where: { $0.id == boxID }),
              let plugin = box.assignedPlugin else {
            return "UI"
        }
        if let liveProcessorPlugin = engine.liveProcessorPlugin(for: boxID) {
            return liveProcessorPlugin.id == plugin.id ? "UI" : "AU UI"
        }
        if plugin.format == .audioUnit {
            return "UI"
        }
        return resolvedProcessorPlugin(for: plugin) == nil ? "No UI" : "AU UI"
    }

    func openPluginEditor(for boxID: UUID) {
        guard let lane = lane(containing: boxID),
              let box = rackBoxes(in: lane).first(where: { $0.id == boxID }),
              let assignedPlugin = box.assignedPlugin else {
            return
        }
        if let liveAudioUnit = engine.liveAudioUnit(for: boxID),
           let editorPlugin = engine.liveProcessorPlugin(for: boxID) {
            pluginEditorSession = PluginEditorSession(
                boxID: box.id,
                boxTitle: box.title,
                assignedPlugin: assignedPlugin,
                editorPlugin: editorPlugin,
                liveAudioUnit: liveAudioUnit
            )
            return
        }
        guard let editorPlugin = resolvedProcessorPlugin(for: assignedPlugin) else { return }
        pluginEditorSession = PluginEditorSession(
            boxID: box.id,
            boxTitle: box.title,
            assignedPlugin: assignedPlugin,
            editorPlugin: editorPlugin,
            liveAudioUnit: nil
        )
    }

    func clearPlugin(in boxID: UUID) {
        guard let lane = lane(containing: boxID) else { return }
        mutateRackBoxes(in: lane) { boxes in
            guard let index = boxes.firstIndex(where: { $0.id == boxID }) else { return }
            boxes[index].assignedPlugin = nil
            boxes[index].isBypassed = false
        }
        if pluginEditorSession?.boxID == boxID {
            pluginEditorSession = nil
        }
        syncRackToEngine()
    }

    func toggleBoxBypass(_ boxID: UUID) {
        guard let lane = lane(containing: boxID) else { return }
        mutateRackBoxes(in: lane) { boxes in
            guard let index = boxes.firstIndex(where: { $0.id == boxID }) else { return }
            guard boxes[index].assignedPlugin != nil else { return }
            boxes[index].isBypassed.toggle()
        }
        syncRackToEngine()
    }

    func routeOptions(for boxID: UUID?) -> [RackRouteChoice] {
        routeOptions(for: boxID, in: boxID.flatMap { lane(containing: $0) } ?? .main)
    }

    func routeOptions(for boxID: UUID?, in lane: RackLane) -> [RackRouteChoice] {
        let boxes = rackBoxes(in: lane)
        if let boxID {
            var options = [RackRouteChoice(destination: .output, title: "Output")]
            for candidate in boxes where candidate.id != boxID {
                let destination = RackRouteDestination.box(candidate.id)
                if canConnect(source: .box(boxID), to: destination, in: lane) {
                    options.append(RackRouteChoice(destination: destination, title: candidate.displayName))
                }
            }
            return sortedRouteChoices(options)
        }

        var options = [RackRouteChoice(destination: .output, title: "Output")]
        for candidate in boxes {
            let destination = RackRouteDestination.box(candidate.id)
            if canConnect(source: .input, to: destination, in: lane) {
                options.append(RackRouteChoice(destination: destination, title: candidate.displayName))
            }
        }
        return sortedRouteChoices(options)
    }

    func setInputRouteTarget(_ destination: RackRouteDestination) {
        setInputRouteTarget(destination, in: .main)
    }

    func setInputRouteTarget(_ destination: RackRouteDestination, in lane: RackLane) {
        guard canConnect(source: .input, to: destination, in: lane) else { return }
        setInputRouteTargetValue(destination, in: lane)
        reflowRackLayout(in: lane)
        syncRackToEngine()
    }

    func setRouteTarget(_ destination: RackRouteDestination, for boxID: UUID) {
        setRouteTarget(destination, for: boxID, in: lane(containing: boxID) ?? .main)
    }

    func setRouteTarget(_ destination: RackRouteDestination, for boxID: UUID, in lane: RackLane) {
        guard rackBoxes(in: lane).contains(where: { $0.id == boxID }) else { return }
        guard canConnect(source: .box(boxID), to: destination, in: lane) else { return }
        mutateRackBoxes(in: lane) { boxes in
            guard let index = boxes.firstIndex(where: { $0.id == boxID }) else { return }
            boxes[index].routeTarget = destination
        }
        reflowRackLayout(in: lane)
        syncRackToEngine()
    }

    func connect(source: RackCableSource, to destination: RackRouteDestination) {
        connect(source: source, to: destination, in: lane(for: source) ?? .main)
    }

    func connect(source: RackCableSource, to destination: RackRouteDestination, in lane: RackLane) {
        switch source {
        case .input:
            setInputRouteTarget(destination, in: lane)
        case .box(let id):
            setRouteTarget(destination, for: id, in: lane)
        }
    }

    func addManualPluginPath() {
        let trimmed = manualPluginPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: normalized) else {
            pluginSettingsWarning = "That path does not exist."
            return
        }

        manualPluginPaths = ManualPluginPathStore.normalizedPaths(manualPluginPaths + [normalized])
        ManualPluginPathStore.savePaths(manualPluginPaths)
        manualPluginPathDraft = ""
        pluginSettingsWarning = nil
        refreshPluginCatalog()
    }

    func removeManualPluginPath(_ path: String) {
        manualPluginPaths.removeAll { $0 == path }
        manualPluginPaths = ManualPluginPathStore.normalizedPaths(manualPluginPaths)
        ManualPluginPathStore.savePaths(manualPluginPaths)
        pluginSettingsWarning = nil
        refreshPluginCatalog()
    }

    private func resolvedTargetID(for destination: RackRouteDestination) -> UUID? {
        resolvedTargetID(for: destination, in: .main)
    }

    private func resolvedTargetID(for destination: RackRouteDestination, in lane: RackLane) -> UUID? {
        switch destination {
        case .output:
            return outputNodeID(for: lane)
        case .box(let id):
            return rackBoxes(in: lane).contains(where: { $0.id == id }) ? id : nil
        }
    }

    private func reconcileRackGraph() {
        let validPluginIDs = Set(availablePlugins.map(\.id))
        for lane in activeLanesForReconciliation() {
            reconcileRackGraph(in: lane, validPluginIDs: validPluginIDs)
        }
        syncRackToEngine()
    }

    private func reconcileRackGraph(in lane: RackLane, validPluginIDs: Set<String>) {
        let validBoxIDs = Set(rackBoxes(in: lane).map(\.id))

        mutateRackBoxes(in: lane) { boxes in
            for index in boxes.indices {
                if let assignedPlugin = boxes[index].assignedPlugin, !validPluginIDs.contains(assignedPlugin.id) {
                    boxes[index].assignedPlugin = nil
                    boxes[index].isBypassed = false
                }

                if case .box(let targetID) = boxes[index].routeTarget, !validBoxIDs.contains(targetID) {
                    boxes[index].routeTarget = .output
                }
            }
        }

        if case .box(let targetID) = inputRouteTarget(in: lane), !validBoxIDs.contains(targetID) {
            setInputRouteTargetValue(.output, in: lane)
        }

        mutateRackBoxes(in: lane) { boxes in
            for index in boxes.indices {
                if !canConnect(source: .box(boxes[index].id), to: boxes[index].routeTarget, in: lane) {
                    boxes[index].routeTarget = .output
                }
            }
        }

        reflowRackLayout(in: lane)
    }

    private func syncRackToEngine() {
        switch rackMode {
        case .single:
            engine.updateInsertChains(main: activeProcessorPlugins(in: .main), left: [], right: [])
        case .dualMono:
            engine.updateInsertChains(main: [], left: activeProcessorPlugins(in: .left), right: activeProcessorPlugins(in: .right))
        }
    }

    private func activeProcessorPlugins() -> [InsertChainStage] {
        activeProcessorPlugins(in: .main)
    }

    private func activeProcessorPlugins(in lane: RackLane) -> [InsertChainStage] {
        let boxes = rackBoxes(in: lane)
        let activeIDs = orderedPrimaryRouteIDs(in: lane)
        return activeIDs.compactMap { id in
            guard let box = boxes.first(where: { $0.id == id }),
                  !box.isBypassed,
                  let assignedPlugin = box.assignedPlugin else {
                return nil
            }
            guard let processorPlugin = resolvedProcessorPlugin(for: assignedPlugin) else {
                return nil
            }
            return InsertChainStage(
                boxID: box.id,
                boxTitle: box.title,
                assignedPlugin: assignedPlugin,
                processorPlugin: processorPlugin
            )
        }
    }

    private func canConnect(source: RackCableSource, to destination: RackRouteDestination) -> Bool {
        canConnect(source: source, to: destination, in: lane(for: source) ?? .main)
    }

    private func canConnect(source: RackCableSource, to destination: RackRouteDestination, in lane: RackLane) -> Bool {
        let boxes = rackBoxes(in: lane)
        switch (source, destination) {
        case (_, .output):
            return true
        case (.input, .box(let id)):
            return boxes.contains(where: { $0.id == id })
        case (.box(let sourceID), .box(let targetID)):
            guard sourceID != targetID else { return false }
            return !wouldCreateCycle(sourceID: sourceID, targetID: targetID, in: lane)
        }
    }

    private func wouldCreateCycle(sourceID: UUID, targetID: UUID) -> Bool {
        wouldCreateCycle(sourceID: sourceID, targetID: targetID, in: lane(containing: sourceID) ?? .main)
    }

    private func wouldCreateCycle(sourceID: UUID, targetID: UUID, in lane: RackLane) -> Bool {
        let boxes = rackBoxes(in: lane)
        var cursor: RackRouteDestination = .box(targetID)
        var visited = Set<UUID>()

        while true {
            switch cursor {
            case .output:
                return false
            case .box(let id):
                if id == sourceID {
                    return true
                }
                guard visited.insert(id).inserted,
                      let box = boxes.first(where: { $0.id == id }) else {
                    return false
                }
                cursor = box.routeTarget
            }
        }
    }

    private func suggestedPosition(for index: Int) -> CGPoint {
        let row = index / 4
        let column = index % 4
        return CGPoint(x: 420 + CGFloat(column) * 280, y: 320 + CGFloat(row) * 220)
    }

    private func clamped(position: CGPoint, in canvasSize: CGSize) -> CGPoint {
        let halfWidth: CGFloat = 112
        let halfHeight: CGFloat = 80
        let minX = halfWidth + 28
        let maxX = max(minX, canvasSize.width - halfWidth - 28)
        let minY = halfHeight + 84
        let maxY = max(minY, canvasSize.height - halfHeight - 28)
        return CGPoint(
            x: min(max(position.x, minX), maxX),
            y: min(max(position.y, minY), maxY)
        )
    }

    private func sortedRouteChoices(_ options: [RackRouteChoice]) -> [RackRouteChoice] {
        options.sorted { lhs, rhs in
            switch (lhs.destination, rhs.destination) {
            case (.output, .output):
                return false
            case (.output, _):
                return true
            case (_, .output):
                return false
            default:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private func resolvedProcessorPlugin(for plugin: PluginDescriptor) -> PluginDescriptor? {
        if plugin.format == .audioUnit {
            return plugin
        }

        let targetName = normalizedPluginKey(plugin.name)
        let targetVendor = normalizedPluginKey(plugin.vendor)
        let targetStem = plugin.bundlePath.map { normalizedPluginKey(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent) } ?? targetName
        let audioUnits = availablePlugins.filter { $0.format == .audioUnit }

        return audioUnits
            .compactMap { candidate -> (PluginDescriptor, Int)? in
                let candidateName = normalizedPluginKey(candidate.name)
                let candidateVendor = normalizedPluginKey(candidate.vendor)
                let candidateStem = candidate.bundlePath.map { normalizedPluginKey(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent) } ?? candidateName

                var score = 0
                if candidateName == targetName { score += 100 }
                if candidateVendor == targetVendor, !targetVendor.isEmpty { score += 30 }
                if candidateStem == targetStem { score += 24 }
                if candidateName.contains(targetName) || targetName.contains(candidateName) { score += 18 }
                if candidateStem.contains(targetStem) || targetStem.contains(candidateStem) { score += 12 }
                if score == 0 { return nil }
                return (candidate, score)
            }
            .sorted {
                if $0.1 != $1.1 {
                    return $0.1 > $1.1
                }
                return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
            }
            .first?
            .0
    }

    private func normalizedPluginKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func reflowRackLayout() {
        reflowRackLayout(in: .main)
    }

    private func reflowRackLayout(in lane: RackLane) {
        guard !rackBoxes(in: lane).isEmpty else { return }

        let laneY: CGFloat = 470
        let secondaryStartY: CGFloat = 690
        let startX: CGFloat = 420
        let spacingX: CGFloat = 300
        let secondarySpacingX: CGFloat = 260
        let secondarySpacingY: CGFloat = 210

        let primaryIDs = orderedPrimaryRouteIDs(in: lane)
        var indexByID: [UUID: Int] = [:]
        let boxes = rackBoxes(in: lane)
        for index in boxes.indices {
            indexByID[boxes[index].id] = index
        }

        mutateRackBoxes(in: lane) { boxes in
            for (offset, id) in primaryIDs.enumerated() {
                guard let index = indexByID[id] else { continue }
                boxes[index].position = CGPoint(
                    x: startX + CGFloat(offset) * spacingX,
                    y: laneY
                )
            }

            let placed = Set(primaryIDs)
            let secondaryBoxes = boxes.filter { !placed.contains($0.id) }
            for (offset, box) in secondaryBoxes.enumerated() {
                guard let index = indexByID[box.id] else { continue }
                let row = offset / 3
                let column = offset % 3
                boxes[index].position = CGPoint(
                    x: startX + CGFloat(column) * secondarySpacingX,
                    y: secondaryStartY + CGFloat(row) * secondarySpacingY
                )
            }
        }
    }

    private func orderedPrimaryRouteIDs() -> [UUID] {
        orderedPrimaryRouteIDs(in: .main)
    }

    private func orderedPrimaryRouteIDs(in lane: RackLane) -> [UUID] {
        var ordered: [UUID] = []
        var visited = Set<UUID>()
        var cursor = inputRouteTarget(in: lane)
        let boxes = rackBoxes(in: lane)

        while case .box(let id) = cursor {
            guard visited.insert(id).inserted,
                  let box = boxes.first(where: { $0.id == id }) else {
                break
            }

            ordered.append(id)
            cursor = box.routeTarget
        }

        return ordered
    }

    func inputNodeID(for lane: RackLane) -> UUID {
        switch lane {
        case .main:
            return inputNodeID
        case .left:
            return leftInputNodeID
        case .right:
            return rightInputNodeID
        }
    }

    func outputNodeID(for lane: RackLane) -> UUID {
        switch lane {
        case .main:
            return outputNodeID
        case .left:
            return leftOutputNodeID
        case .right:
            return rightOutputNodeID
        }
    }

    func rackBoxes(in lane: RackLane) -> [RackBoxNode] {
        switch lane {
        case .main:
            return rackBoxes
        case .left:
            return leftRackBoxes
        case .right:
            return rightRackBoxes
        }
    }

    func inputRouteTarget(in lane: RackLane) -> RackRouteDestination {
        switch lane {
        case .main:
            return inputRouteTarget
        case .left:
            return leftInputRouteTarget
        case .right:
            return rightInputRouteTarget
        }
    }

    private func appendRackBox(_ box: RackBoxNode, in lane: RackLane) {
        mutateRackBoxes(in: lane) { boxes in
            boxes.append(box)
        }
    }

    private func removeRackBoxWithID(_ boxID: UUID, in lane: RackLane) {
        mutateRackBoxes(in: lane) { boxes in
            boxes.removeAll { $0.id == boxID }
        }
    }

    private func mutateRackBoxes(in lane: RackLane, _ body: (inout [RackBoxNode]) -> Void) {
        switch lane {
        case .main:
            body(&rackBoxes)
        case .left:
            body(&leftRackBoxes)
        case .right:
            body(&rightRackBoxes)
        }
    }

    private func setInputRouteTargetValue(_ destination: RackRouteDestination, in lane: RackLane) {
        switch lane {
        case .main:
            inputRouteTarget = destination
        case .left:
            leftInputRouteTarget = destination
        case .right:
            rightInputRouteTarget = destination
        }
    }

    private func lane(containing boxID: UUID) -> RackLane? {
        for lane in [RackLane.main, .left, .right] where rackBoxes(in: lane).contains(where: { $0.id == boxID }) {
            return lane
        }
        return nil
    }

    private func lane(for source: RackCableSource) -> RackLane? {
        switch source {
        case .input:
            return nil
        case .box(let id):
            return lane(containing: id)
        }
    }

    private func activeLanesForReconciliation() -> [RackLane] {
        [.main, .left, .right]
    }

    private func duplicatedRackBoxes(from sourceBoxes: [RackBoxNode]) -> [RackBoxNode] {
        let idMap = Dictionary(uniqueKeysWithValues: sourceBoxes.map { ($0.id, UUID()) })
        return sourceBoxes.map { box in
            let routeTarget: RackRouteDestination
            switch box.routeTarget {
            case .output:
                routeTarget = .output
            case .box(let id):
                routeTarget = idMap[id].map(RackRouteDestination.box) ?? .output
            }

            return RackBoxNode(
                id: idMap[box.id] ?? UUID(),
                title: box.title,
                assignedPlugin: box.assignedPlugin,
                isBypassed: box.isBypassed,
                position: box.position,
                routeTarget: routeTarget
            )
        }
    }

    private func remappedRouteTarget(
        from sourceRoute: RackRouteDestination,
        sourceBoxes: [RackBoxNode],
        destinationBoxes: [RackBoxNode]
    ) -> RackRouteDestination {
        switch sourceRoute {
        case .output:
            return .output
        case .box(let sourceID):
            guard let sourceIndex = sourceBoxes.firstIndex(where: { $0.id == sourceID }),
                  destinationBoxes.indices.contains(sourceIndex) else {
                return .output
            }
            return .box(destinationBoxes[sourceIndex].id)
        }
    }
}

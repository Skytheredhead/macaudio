import CoreAudio
import CoreGraphics
import Foundation

@MainActor
final class MainViewModel: ObservableObject {
    let engine: AudioEngineController
    let inputNodeID = UUID(uuidString: "8FE29C3D-7B80-4EAF-9B9F-D301A75A8001")!
    let outputNodeID = UUID(uuidString: "6D801B8C-572B-4F98-BF25-7D78017F7F0A")!

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

    init(engine: AudioEngineController = AudioEngineController(), scanPluginsOnInit: Bool = true) {
        self.engine = engine
        self.settings = VoicePreset.cleanVoice.settings
        self.customPresets = PresetStore.loadUserPresets()
        self.presetChoices = PresetStore.allChoices(customPresets: customPresets)
        self.manualPluginPaths = ManualPluginPathStore.loadPaths()
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
        var connections: [RackConnection] = []
        if let targetID = resolvedTargetID(for: inputRouteTarget) {
            connections.append(RackConnection(sourceID: inputNodeID, targetID: targetID, title: "Input"))
        }

        for box in rackBoxes {
            if let targetID = resolvedTargetID(for: box.routeTarget) {
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
        let newBox = RackBoxNode(
            id: UUID(),
            title: "Box \(rackBoxes.count + 1)",
            assignedPlugin: nil,
            isBypassed: false,
            position: position ?? suggestedPosition(for: rackBoxes.count),
            routeTarget: .output
        )

        rackBoxes.append(newBox)
        if rackBoxes.count == 1 {
            inputRouteTarget = .box(newBox.id)
        }
        if position == nil {
            reflowRackLayout()
        }
    }

    func addRackBoxAndChoosePlugin(at position: CGPoint? = nil) {
        let newBox = RackBoxNode(
            id: UUID(),
            title: "Box \(rackBoxes.count + 1)",
            assignedPlugin: nil,
            isBypassed: false,
            position: position ?? suggestedPosition(for: rackBoxes.count),
            routeTarget: .output
        )

        rackBoxes.append(newBox)
        if rackBoxes.count == 1 {
            inputRouteTarget = .box(newBox.id)
        }
        if position == nil {
            reflowRackLayout()
        }
        pluginBrowserTarget = PluginBrowserTarget(slotID: newBox.id, slotTitle: newBox.title, removeIfCancelled: true)
    }

    func removeRackBox(_ boxID: UUID) {
        if pluginBrowserTarget?.slotID == boxID {
            pluginBrowserTarget = nil
        }
        if pluginEditorSession?.boxID == boxID {
            pluginEditorSession = nil
        }
        rackBoxes.removeAll { $0.id == boxID }

        if inputRouteTarget == .box(boxID) {
            inputRouteTarget = .output
        }

        for index in rackBoxes.indices where rackBoxes[index].routeTarget == .box(boxID) {
            rackBoxes[index].routeTarget = .output
        }

        reflowRackLayout()
        syncRackToEngine()
    }

    func moveRackBox(_ boxID: UUID, to position: CGPoint, in canvasSize: CGSize) {
        guard let index = rackBoxes.firstIndex(where: { $0.id == boxID }) else { return }
        rackBoxes[index].position = clamped(position: position, in: canvasSize)
    }

    func openPluginBrowser(for box: RackBoxNode) {
        guard box.assignedPlugin == nil else { return }
        pluginBrowserTarget = PluginBrowserTarget(slotID: box.id, slotTitle: box.title, removeIfCancelled: false)
    }

    func assignPlugin(_ plugin: PluginDescriptor, to boxID: UUID) {
        guard let index = rackBoxes.firstIndex(where: { $0.id == boxID }) else { return }
        if rackBoxes[index].assignedPlugin?.id == plugin.id {
            pluginBrowserTarget = nil
            return
        }
        rackBoxes[index].assignedPlugin = plugin
        rackBoxes[index].isBypassed = false
        pluginBrowserTarget = nil
        syncRackToEngine()
    }

    func finishPluginBrowserSelection(for target: PluginBrowserTarget, committed: Bool) {
        if pluginBrowserTarget?.slotID == target.slotID {
            pluginBrowserTarget = nil
        }
        guard !committed, target.removeIfCancelled else { return }
        guard let box = rackBoxes.first(where: { $0.id == target.slotID }), box.assignedPlugin == nil else { return }
        removeRackBox(target.slotID)
    }

    func boxHasAssignedPlugin(_ boxID: UUID) -> Bool {
        rackBoxes.first(where: { $0.id == boxID })?.assignedPlugin != nil
    }

    func canOpenPluginEditor(for boxID: UUID) -> Bool {
        guard let box = rackBoxes.first(where: { $0.id == boxID }),
              let plugin = box.assignedPlugin else {
            return false
        }
        if engine.liveProcessorPlugin(for: boxID) != nil {
            return true
        }
        return resolvedProcessorPlugin(for: plugin) != nil
    }

    func editorButtonTitle(for boxID: UUID) -> String {
        guard let box = rackBoxes.first(where: { $0.id == boxID }),
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
        guard let box = rackBoxes.first(where: { $0.id == boxID }),
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
        guard let index = rackBoxes.firstIndex(where: { $0.id == boxID }) else { return }
        rackBoxes[index].assignedPlugin = nil
        rackBoxes[index].isBypassed = false
        if pluginEditorSession?.boxID == boxID {
            pluginEditorSession = nil
        }
        syncRackToEngine()
    }

    func toggleBoxBypass(_ boxID: UUID) {
        guard let index = rackBoxes.firstIndex(where: { $0.id == boxID }) else { return }
        guard rackBoxes[index].assignedPlugin != nil else { return }
        rackBoxes[index].isBypassed.toggle()
        syncRackToEngine()
    }

    func routeOptions(for boxID: UUID?) -> [RackRouteChoice] {
        if let boxID {
            var options = [RackRouteChoice(destination: .output, title: "Output")]
            for candidate in rackBoxes where candidate.id != boxID {
                let destination = RackRouteDestination.box(candidate.id)
                if canConnect(source: .box(boxID), to: destination) {
                    options.append(RackRouteChoice(destination: destination, title: candidate.displayName))
                }
            }
            return sortedRouteChoices(options)
        }

        var options = [RackRouteChoice(destination: .output, title: "Output")]
        for candidate in rackBoxes {
            let destination = RackRouteDestination.box(candidate.id)
            if canConnect(source: .input, to: destination) {
                options.append(RackRouteChoice(destination: destination, title: candidate.displayName))
            }
        }
        return sortedRouteChoices(options)
    }

    func setInputRouteTarget(_ destination: RackRouteDestination) {
        guard canConnect(source: .input, to: destination) else { return }
        inputRouteTarget = destination
        reflowRackLayout()
        syncRackToEngine()
    }

    func setRouteTarget(_ destination: RackRouteDestination, for boxID: UUID) {
        guard let index = rackBoxes.firstIndex(where: { $0.id == boxID }) else { return }
        guard canConnect(source: .box(boxID), to: destination) else { return }
        rackBoxes[index].routeTarget = destination
        reflowRackLayout()
        syncRackToEngine()
    }

    func connect(source: RackCableSource, to destination: RackRouteDestination) {
        switch source {
        case .input:
            setInputRouteTarget(destination)
        case .box(let id):
            setRouteTarget(destination, for: id)
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
        switch destination {
        case .output:
            return outputNodeID
        case .box(let id):
            return rackBoxes.contains(where: { $0.id == id }) ? id : nil
        }
    }

    private func reconcileRackGraph() {
        let validPluginIDs = Set(availablePlugins.map(\.id))
        let validBoxIDs = Set(rackBoxes.map(\.id))

        for index in rackBoxes.indices {
            if let assignedPlugin = rackBoxes[index].assignedPlugin, !validPluginIDs.contains(assignedPlugin.id) {
                rackBoxes[index].assignedPlugin = nil
                rackBoxes[index].isBypassed = false
            }

            if case .box(let targetID) = rackBoxes[index].routeTarget, !validBoxIDs.contains(targetID) {
                rackBoxes[index].routeTarget = .output
            }
        }

        if case .box(let targetID) = inputRouteTarget, !validBoxIDs.contains(targetID) {
            inputRouteTarget = .output
        }

        for index in rackBoxes.indices {
            if !canConnect(source: .box(rackBoxes[index].id), to: rackBoxes[index].routeTarget) {
                rackBoxes[index].routeTarget = .output
            }
        }

        reflowRackLayout()
        syncRackToEngine()
    }

    private func syncRackToEngine() {
        engine.updateInsertChain(activeProcessorPlugins())
    }

    private func activeProcessorPlugins() -> [InsertChainStage] {
        let activeIDs = orderedPrimaryRouteIDs()
        return activeIDs.compactMap { id in
            guard let box = rackBoxes.first(where: { $0.id == id }),
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
        switch (source, destination) {
        case (_, .output):
            return true
        case (.input, .box(let id)):
            return rackBoxes.contains(where: { $0.id == id })
        case (.box(let sourceID), .box(let targetID)):
            guard sourceID != targetID else { return false }
            return !wouldCreateCycle(sourceID: sourceID, targetID: targetID)
        }
    }

    private func wouldCreateCycle(sourceID: UUID, targetID: UUID) -> Bool {
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
                      let box = rackBoxes.first(where: { $0.id == id }) else {
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
        guard !rackBoxes.isEmpty else { return }

        let laneY: CGFloat = 470
        let secondaryStartY: CGFloat = 690
        let startX: CGFloat = 420
        let spacingX: CGFloat = 300
        let secondarySpacingX: CGFloat = 260
        let secondarySpacingY: CGFloat = 210

        let primaryIDs = orderedPrimaryRouteIDs()
        var indexByID: [UUID: Int] = [:]
        for index in rackBoxes.indices {
            indexByID[rackBoxes[index].id] = index
        }

        for (offset, id) in primaryIDs.enumerated() {
            guard let index = indexByID[id] else { continue }
            rackBoxes[index].position = CGPoint(
                x: startX + CGFloat(offset) * spacingX,
                y: laneY
            )
        }

        let placed = Set(primaryIDs)
        let secondaryBoxes = rackBoxes.filter { !placed.contains($0.id) }
        for (offset, box) in secondaryBoxes.enumerated() {
            guard let index = indexByID[box.id] else { continue }
            let row = offset / 3
            let column = offset % 3
            rackBoxes[index].position = CGPoint(
                x: startX + CGFloat(column) * secondarySpacingX,
                y: secondaryStartY + CGFloat(row) * secondarySpacingY
            )
        }
    }

    private func orderedPrimaryRouteIDs() -> [UUID] {
        var ordered: [UUID] = []
        var visited = Set<UUID>()
        var cursor = inputRouteTarget

        while case .box(let id) = cursor {
            guard visited.insert(id).inserted,
                  let box = rackBoxes.first(where: { $0.id == id }) else {
                break
            }

            ordered.append(id)
            cursor = box.routeTarget
        }

        return ordered
    }
}

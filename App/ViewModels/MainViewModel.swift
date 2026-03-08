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

    func removeRackBox(_ boxID: UUID) {
        rackBoxes.removeAll { $0.id == boxID }

        if inputRouteTarget == .box(boxID) {
            inputRouteTarget = .output
        }

        for index in rackBoxes.indices where rackBoxes[index].routeTarget == .box(boxID) {
            rackBoxes[index].routeTarget = .output
        }

        reflowRackLayout()
    }

    func moveRackBox(_ boxID: UUID, to position: CGPoint, in canvasSize: CGSize) {
        guard let index = rackBoxes.firstIndex(where: { $0.id == boxID }) else { return }
        rackBoxes[index].position = clamped(position: position, in: canvasSize)
    }

    func openPluginBrowser(for box: RackBoxNode) {
        pluginBrowserTarget = PluginBrowserTarget(slotID: box.id, slotTitle: box.title)
    }

    func assignPlugin(_ plugin: PluginDescriptor, to boxID: UUID) {
        guard let index = rackBoxes.firstIndex(where: { $0.id == boxID }) else { return }
        rackBoxes[index].assignedPlugin = plugin
        rackBoxes[index].isBypassed = false
        pluginBrowserTarget = nil
    }

    func openPluginEditor(for boxID: UUID) {
        guard let box = rackBoxes.first(where: { $0.id == boxID }), let plugin = box.assignedPlugin else { return }
        pluginEditorSession = PluginEditorSession(boxID: box.id, boxTitle: box.title, plugin: plugin)
    }

    func clearPlugin(in boxID: UUID) {
        guard let index = rackBoxes.firstIndex(where: { $0.id == boxID }) else { return }
        rackBoxes[index].assignedPlugin = nil
        rackBoxes[index].isBypassed = false
    }

    func toggleBoxBypass(_ boxID: UUID) {
        guard let index = rackBoxes.firstIndex(where: { $0.id == boxID }) else { return }
        guard rackBoxes[index].assignedPlugin != nil else { return }
        rackBoxes[index].isBypassed.toggle()
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
    }

    func setRouteTarget(_ destination: RackRouteDestination, for boxID: UUID) {
        guard let index = rackBoxes.firstIndex(where: { $0.id == boxID }) else { return }
        guard canConnect(source: .box(boxID), to: destination) else { return }
        rackBoxes[index].routeTarget = destination
        reflowRackLayout()
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

import Foundation

final class MainViewModel: ObservableObject {
    let engine: AudioEngineController

    @Published var selectedPreset: VoicePreset = .cleanVoice {
        didSet {
            engine.setPreset(selectedPreset)
            settings = selectedPreset.settings
        }
    }

    @Published var settings: VoiceProcessingSettings {
        didSet {
            engine.updateSettings(settings)
        }
    }

    init(engine: AudioEngineController = AudioEngineController()) {
        self.engine = engine
        settings = VoicePreset.cleanVoice.settings
        engine.setPreset(.cleanVoice)
    }

    func toggleRunState() {
        if engine.isRunning {
            engine.stop()
        } else {
            engine.setPreset(selectedPreset)
            engine.updateSettings(settings)
            engine.start()
        }
    }

    func refreshDevices() {
        engine.refreshInputDevices()
    }

    func updateInputDevice() {
        engine.updateInputDevice(engine.selectedInputDeviceID)
    }

    func applyLatencyQuality() {
        engine.applyLatencyQuality(engine.latencyQuality)
    }

    func updateMonitorDevice() {
        engine.updateMonitorDevice(engine.selectedMonitorDeviceID)
    }

    func updateIOConfiguration() {
        engine.updateIOConfiguration(
            sampleRate: engine.selectedSampleRate,
            bufferSize: engine.selectedBufferSize
        )
    }
}

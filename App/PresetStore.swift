import Foundation

struct PresetChoice: Identifiable {
    let id: String
    let name: String
    let settings: VoiceProcessingSettings
    let isBuiltIn: Bool
}

enum PresetStore {
    private static let defaultsKey = "MacAudio.customPresets"

    static func loadUserPresets() -> [UserPreset] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([UserPreset].self, from: data)) ?? []
    }

    static func saveUserPresets(_ presets: [UserPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func allChoices(customPresets: [UserPreset]) -> [PresetChoice] {
        let builtIns = VoicePreset.allCases.map {
            PresetChoice(id: $0.id, name: $0.rawValue, settings: $0.settings, isBuiltIn: true)
        }
        let custom = customPresets
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { preset in
                PresetChoice(id: "user:\(preset.id.uuidString)", name: preset.name, settings: preset.settings, isBuiltIn: false)
            }
        return builtIns + custom
    }
}

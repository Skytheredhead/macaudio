import Foundation

enum ManualPluginPathStore {
    private static let defaultsKey = "MacAudio.manualPluginPaths"

    static func loadPaths(defaults: UserDefaults = .standard) -> [String] {
        let stored = defaults.stringArray(forKey: defaultsKey) ?? []
        return normalizedPaths(stored)
    }

    static func savePaths(_ paths: [String], defaults: UserDefaults = .standard) {
        defaults.set(normalizedPaths(paths), forKey: defaultsKey)
    }

    static func normalizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }

        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

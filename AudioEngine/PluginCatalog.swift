import AVFoundation
import Foundation

enum PluginFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case vst2 = "VST2"
    case vst3 = "VST3"
    case audioUnit = "AU"

    var id: String { rawValue }

    var bundleExtension: String? {
        switch self {
        case .vst2:
            return "vst"
        case .vst3:
            return "vst3"
        case .audioUnit:
            return nil
        }
    }

    var pluginCategoryLabel: String {
        switch self {
        case .vst2:
            return "VST2 Plug-In"
        case .vst3:
            return "VST3 Plug-In"
        case .audioUnit:
            return "Audio Unit"
        }
    }
}

struct PluginDescriptor: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let vendor: String
    let format: PluginFormat
    let category: String
    let location: String
    let bundlePath: String?
}

struct InsertChainStage: Hashable, Sendable {
    let boxID: UUID
    let boxTitle: String
    let assignedPlugin: PluginDescriptor
    let processorPlugin: PluginDescriptor
}

struct RackInsertSlot: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var title: String
    var isBypassed: Bool
    var assignedPlugin: PluginDescriptor?

    var subtitle: String {
        guard let assignedPlugin else { return "Empty insert" }
        return "\(assignedPlugin.format.rawValue) • \(assignedPlugin.vendor)"
    }

    static func defaults() -> [RackInsertSlot] {
        [
            RackInsertSlot(id: UUID(), title: "Insert 1", isBypassed: false, assignedPlugin: nil),
            RackInsertSlot(id: UUID(), title: "Insert 2", isBypassed: false, assignedPlugin: nil),
            RackInsertSlot(id: UUID(), title: "Insert 3", isBypassed: false, assignedPlugin: nil),
            RackInsertSlot(id: UUID(), title: "Insert 4", isBypassed: false, assignedPlugin: nil)
        ]
    }
}

struct PluginBrowserTarget: Identifiable, Equatable, Sendable {
    let slotID: UUID
    let slotTitle: String
    var lane: RackLane = .main
    let removeIfCancelled: Bool

    var id: String { "\(lane.rawValue):\(slotID.uuidString)" }
}

enum PluginBrowserFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case vst2 = "VST2"
    case vst3 = "VST3"
    case audioUnit = "Audio Units"

    var id: String { rawValue }

    func includes(_ format: PluginFormat) -> Bool {
        switch self {
        case .all:
            return true
        case .vst2:
            return format == .vst2
        case .vst3:
            return format == .vst3
        case .audioUnit:
            return format == .audioUnit
        }
    }
}

enum PluginCatalog {
    static let standardVST2Directories: [URL] = [
        URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/VST", isDirectory: true)
    ]

    static let standardVST3Directories: [URL] = [
        URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/VST3", isDirectory: true)
    ]

    static func scanAvailablePlugins(manualPaths: [String] = ManualPluginPathStore.loadPaths()) -> [PluginDescriptor] {
        let audioUnits = scanAudioUnits()
        let manualURLs = ManualPluginPathStore.normalizedPaths(manualPaths).map { URL(fileURLWithPath: $0) }
        let vst2Bundles = scanBundlePlugins(in: standardVST2Directories + manualURLs, format: .vst2)
        let vst3Bundles = scanBundlePlugins(in: standardVST3Directories + manualURLs, format: .vst3)

        var seen = Set<String>()
        return (audioUnits + vst2Bundles + vst3Bundles)
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.format != rhs.format {
                    return lhs.format.rawValue < rhs.format.rawValue
                }
                if lhs.vendor != rhs.vendor {
                    return lhs.vendor.localizedCaseInsensitiveCompare(rhs.vendor) == .orderedAscending
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func scanBundlePlugins(in roots: [URL], format: PluginFormat) -> [PluginDescriptor] {
        guard let bundleExtension = format.bundleExtension else { return [] }

        let fileManager = FileManager.default
        var seenPaths = Set<String>()
        var descriptors: [PluginDescriptor] = []

        for root in roots {
            let standardizedRoot = root.standardizedFileURL
            let rootPath = standardizedRoot.path
            guard fileManager.fileExists(atPath: rootPath) else { continue }

            let rootExtension = standardizedRoot.pathExtension.lowercased()
            if rootExtension == bundleExtension {
                if let descriptor = descriptorForBundle(at: standardizedRoot, format: format, root: standardizedRoot.deletingLastPathComponent()), seenPaths.insert(standardizedRoot.path).inserted {
                    descriptors.append(descriptor)
                }
                continue
            }

            if !rootExtension.isEmpty {
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else { continue }

            guard let enumerator = fileManager.enumerator(
                at: standardizedRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles],
                errorHandler: nil
            ) else { continue }

            while let item = enumerator.nextObject() as? URL {
                guard item.pathExtension.lowercased() == bundleExtension else { continue }
                enumerator.skipDescendants()

                let standardizedItem = item.standardizedFileURL
                guard seenPaths.insert(standardizedItem.path).inserted else { continue }
                if let descriptor = descriptorForBundle(at: standardizedItem, format: format, root: standardizedRoot) {
                    descriptors.append(descriptor)
                }
            }
        }

        return descriptors
    }

    static func descriptorForBundle(at url: URL, format: PluginFormat, root: URL? = nil) -> PluginDescriptor? {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary
        let name = (
            info?[kCFBundleNameKey as String] as? String
            ?? info?["CFBundleDisplayName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let vendor = (
            info?[kCFBundleIdentifierKey as String] as? String
            ?? bundle?.bundleIdentifier
            ?? format.rawValue
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let location: String
        if let root {
            let rootPath = root.standardizedFileURL.path
            let bundlePath = url.deletingLastPathComponent().standardizedFileURL.path
            if bundlePath.hasPrefix(rootPath), bundlePath != rootPath {
                location = URL(fileURLWithPath: bundlePath).lastPathComponent
            } else {
                location = root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
            }
        } else {
            location = url.deletingLastPathComponent().lastPathComponent
        }

        return PluginDescriptor(
            id: "\(format.rawValue.lowercased()):\(url.standardizedFileURL.path)",
            name: name.nonEmpty ?? url.deletingPathExtension().lastPathComponent,
            vendor: vendor.nonEmpty ?? format.rawValue,
            format: format,
            category: format.pluginCategoryLabel,
            location: location.nonEmpty ?? "Manual Path",
            bundlePath: url.standardizedFileURL.path
        )
    }

    private static func scanAudioUnits() -> [PluginDescriptor] {
        let manager = AVAudioUnitComponentManager.shared()
        let types: [OSType] = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        var allComponents: [AVAudioUnitComponent] = []

        for type in types {
            let description = AudioComponentDescription(
                componentType: type,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            allComponents.append(contentsOf: manager.components(matching: description))
        }

        var seen = Set<String>()
        return allComponents.compactMap { component in
            let audioDescription = component.audioComponentDescription
            let identifier = [
                String(audioDescription.componentType),
                String(audioDescription.componentSubType),
                String(audioDescription.componentManufacturer)
            ].joined(separator: ".")
            guard seen.insert(identifier).inserted else { return nil }

            let displayName: String
            let vendor: String
            if let separator = component.name.firstIndex(of: ":") {
                vendor = String(component.name[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                displayName = String(component.name[component.name.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                vendor = component.manufacturerName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Audio Unit"
                displayName = component.name.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            return PluginDescriptor(
                id: "au:\(identifier)",
                name: displayName.nonEmpty ?? component.name,
                vendor: vendor.nonEmpty ?? "Audio Unit",
                format: .audioUnit,
                category: component.typeName.nonEmpty ?? "Audio Unit",
                location: "Audio Units",
                bundlePath: nil
            )
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

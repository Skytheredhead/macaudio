import CoreGraphics
import Foundation

struct RackBoxNode: Identifiable, Equatable {
    let id: UUID
    var title: String
    var assignedPlugin: PluginDescriptor?
    var isBypassed: Bool
    var position: CGPoint
    var routeTarget: RackRouteDestination

    var displayName: String {
        assignedPlugin?.name ?? title
    }

    var vendorLine: String {
        if let assignedPlugin {
            return "\(assignedPlugin.format.rawValue) • \(assignedPlugin.vendor)"
        }
        return "Empty"
    }
}

enum RackRouteDestination: Hashable, Codable, Sendable {
    case output
    case box(UUID)
}

struct RackRouteChoice: Identifiable, Hashable {
    let destination: RackRouteDestination
    let title: String

    var id: String {
        switch destination {
        case .output:
            return "output"
        case .box(let id):
            return "box:\(id.uuidString)"
        }
    }
}

struct RackConnection: Identifiable, Equatable {
    let sourceID: UUID
    let targetID: UUID
    let title: String

    var id: String { "\(sourceID.uuidString)->\(targetID.uuidString)" }
}

enum RackCableSource: Hashable {
    case input
    case box(UUID)
}

enum RackLane: String, CaseIterable, Identifiable, Sendable {
    case main
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .main:
            return "Rack"
        case .left:
            return "Left Rack"
        case .right:
            return "Right Rack"
        }
    }

    var inputTitle: String {
        switch self {
        case .main:
            return "INPUT"
        case .left:
            return "LEFT INPUT"
        case .right:
            return "RIGHT INPUT"
        }
    }

    var outputTitle: String {
        switch self {
        case .main:
            return "OUTPUT"
        case .left:
            return "LEFT OUT"
        case .right:
            return "RIGHT OUT"
        }
    }
}

enum RackWorkspaceMode: String, CaseIterable, Identifiable {
    case single = "Single"
    case dualMono = "Dual Mono"

    var id: String { rawValue }
}

enum AudioChannelMode: String, CaseIterable, Identifiable, Sendable {
    case mono = "Mono"
    case stereo = "Stereo"

    var id: String { rawValue }
}

enum DualMonoEndMode: String, CaseIterable, Identifiable, Sendable {
    case separate = "Separate"
    case merge = "Merge"

    var id: String { rawValue }
}

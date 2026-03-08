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

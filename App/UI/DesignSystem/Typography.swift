import SwiftUI

extension DS {
    enum Font {
        static let display = SwiftUI.Font.system(.largeTitle, design: .rounded).weight(.semibold)
        static let title   = SwiftUI.Font.system(.title3,     design: .rounded).weight(.semibold)
        static let body    = SwiftUI.Font.system(.body,       design: .rounded)
        static let caption = SwiftUI.Font.system(.caption,    design: .rounded).weight(.medium)
        static let meter   = SwiftUI.Font.system(.caption2,   design: .monospaced)
    }
}

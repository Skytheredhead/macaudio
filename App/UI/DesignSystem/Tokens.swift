import SwiftUI

enum DS {}

extension DS {
    enum Color {
        static let accent          = SwiftUI.Color.accentColor
        static let textPrimary     = SwiftUI.Color.primary
        static let textSecondary   = SwiftUI.Color.secondary
        static let textTertiary    = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        static let divider         = SwiftUI.Color(nsColor: .separatorColor)
        static let signalActive    = SwiftUI.Color.accentColor.opacity(0.75)
        static let signalIdle      = SwiftUI.Color.secondary.opacity(0.35)
        static let warning         = SwiftUI.Color(nsColor: .systemYellow)
    }
}

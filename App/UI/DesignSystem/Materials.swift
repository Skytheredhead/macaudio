import SwiftUI

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = DS.Radius.lg
    var tint: Color? = nil
    var interactive: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content()
            .clipShape(shape)
            .glassEffect(glass, in: shape)
    }

    private var glass: Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

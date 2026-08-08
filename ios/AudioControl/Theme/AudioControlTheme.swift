import SwiftUI

enum AudioControlTheme {
    static let canvas = Color(red: 0.957, green: 0.969, blue: 0.980)
    static let panel = Color.white
    static let panelRaised = Color(red: 0.906, green: 0.929, blue: 0.957)
    static let rule = Color(red: 0.780, green: 0.827, blue: 0.875)
    static let ink = Color(red: 0.082, green: 0.141, blue: 0.227)
    static let muted = Color(red: 0.365, green: 0.435, blue: 0.522)
    static let signal = Color(red: 0.784, green: 0.227, blue: 0.153)
    static let connected = Color(red: 0.000, green: 0.455, blue: 0.420)
    static let caution = Color(red: 0.773, green: 0.420, blue: 0.067)
}

struct PanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(AudioControlTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AudioControlTheme.rule.opacity(0.65), lineWidth: 1)
            }
    }
}

extension View {
    func controlPanel() -> some View { modifier(PanelModifier()) }
}

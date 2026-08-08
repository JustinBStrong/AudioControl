import AVKit
import SwiftUI

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.activeTintColor = UIColor(AudioControlTheme.connected)
        picker.tintColor = UIColor(AudioControlTheme.ink)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}


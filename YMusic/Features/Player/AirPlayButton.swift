import MediaPlayer
import SwiftUI
import UIKit

/// Системная кнопка AirPlay. `MPVolumeView` сам открывает route picker,
/// поэтому не нужен свой список устройств. Слайдер громкости скрыт:
/// громкость системная, дублировать её в плеере незачем.
struct AirPlayButton: UIViewRepresentable {
    var tint: UIColor = .white

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.showsVolumeSlider = false
        view.showsRouteButton = true
        view.tintColor = tint
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        view.tintColor = tint
    }
}
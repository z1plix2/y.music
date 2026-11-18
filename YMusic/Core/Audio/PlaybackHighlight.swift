import Combine
import Foundation

/// Лёгкий срез состояния плеера для списков: только «какой трек» и «играет ли».
///
/// Подписка на сам `AudioPlayer` тянет перерисовку на каждый тик `currentTime`
/// (дважды в секунду). Здесь публикуется изменение только по факту смены
/// трека или play/pause, поэтому строки каталога не перерисовываются зря.
///
/// Мутации приходят только с главного потока (`AudioPlayer` изолирован
/// `@MainActor`), класс намеренно не помечен `@MainActor`: иначе статический
/// `shared` нельзя было бы читать из инициализаторов View-структур.
final class PlaybackHighlight: ObservableObject {
    static let shared = PlaybackHighlight()

    @Published private(set) var trackID: Int?
    @Published private(set) var isPlaying = false

    /// Идемпотентно: одинаковые значения не публикуются.
    func sync(trackID: Int?, isPlaying: Bool) {
        if self.trackID != trackID {
            self.trackID = trackID
        }
        if self.isPlaying != isPlaying {
            self.isPlaying = isPlaying
        }
    }
}
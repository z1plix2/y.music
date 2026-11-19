import Foundation
import Network

/// Наличие сети: один `NWPathMonitor` на приложение.
///
/// Нужен только для UI-подсказки «нет интернета», когда запрос всё равно
/// упадёт: так пользователь видит причину, а не молчаливое пустое состояние.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnline = true
    /// Дешёвый интернет (сотовая сеть): можно не качать тяжёлые обложки,
    /// но это не запрет — только подсказка для экранов.
    @Published private(set) var isExpensive = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.example.ymusic.network")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor in
                self?.isOnline = online
                self?.isExpensive = expensive
            }
        }
        monitor.start(queue: queue)
    }
}

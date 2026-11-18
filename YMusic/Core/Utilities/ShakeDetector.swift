import UIKit

/// Детектор тряски без сторонних библиотек: `UIWindow` получает `motionEnded`
/// от системы, а SwiftUI подписывается на уведомление.
///
/// Переопределение в расширении безопасно: метод объявлен в `UIResponder`
/// и не требует изменения класса окна.
extension UIDevice {
    static let deviceDidShakeNotification = Notification.Name("deviceDidShakeNotification")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)

        if motion == .motionShake {
            NotificationCenter.default.post(
                name: UIDevice.deviceDidShakeNotification,
                object: nil
            )
        }
    }
}
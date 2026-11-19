import UIKit

/// Тактильный отклик. Генераторы создаются один раз и `prepare()` после
/// каждого срабатывания: так первый тап не «съедается» задержкой Taptic Engine.
///
/// `@MainActor`: `UIImpactFeedbackGenerator` не `Sendable`, а вызывается
/// только из UI-замыканий.
@MainActor
enum Haptics {
    private static let lightGenerator: UIImpactFeedbackGenerator = {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        return generator
    }()

    private static let selectionGenerator: UISelectionFeedbackGenerator = {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        return generator
    }()

    private static let notificationGenerator: UINotificationFeedbackGenerator = {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        return generator
    }()

    /// Play/pause, next/previous, тап по треку.
    static func light() {
        lightGenerator.impactOccurred(intensity: 0.7)
        lightGenerator.prepare()
    }

    /// Смена выбранного элемента (пока не используется: в UI нет сегментов).
    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    /// Успешное действие: добавление в плейлист и подобное.
    static func success() {
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }
}
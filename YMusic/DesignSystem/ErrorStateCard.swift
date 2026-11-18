import SwiftUI

/// Одна карточка ошибки для всех экранов: сеть, таймаут, истёкшая сессия,
/// 404, 5xx, «нужен Plus». Текст — из `APIError+Humanized`, никаких сырых
/// `localizedDescription` в интерфейсе.
///
/// `onRetry` опционален: в плеере повтор — это та же кнопка play, отдельная
/// кнопка там не нужна.
struct ErrorStateCard: View {
    let error: APIError
    var context: APIError.Context = .generic
    var cornerRadius: CGFloat = 24
    var padding: CGFloat = 18
    /// Необязательная приписка под текстом (например, про честный ответ сервера).
    var footnote: String?
    var onRetry: (() -> Void)?

    @Environment(\.contentTone) private var tone

    private var title: String {
        if error.isSubscriptionRequired { return "Требуется подписка" }
        return error.humanizedTitle(context: context)
    }

    private var icon: String {
        if error.isSubscriptionRequired { return "lock.fill" }
        return error.humanizedIcon
    }

    var body: some View {
        GlassCard(cornerRadius: cornerRadius, padding: padding) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))

                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(tone.primary)

                Text(error.humanizedDescription(context: context))
                    .font(.footnote)
                    .foregroundStyle(tone.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let footnote = footnote {
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(tone.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let onRetry = onRetry {
                    GlassButton(
                        error.requiresReauthentication ? "Войти заново" : "Повторить",
                        systemImage: error.requiresReauthentication
                            ? "person.crop.circle"
                            : "arrow.clockwise",
                        action: onRetry
                    )
                }
            }
        }
    }
}
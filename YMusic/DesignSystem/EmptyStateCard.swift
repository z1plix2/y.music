import SwiftUI

/// Пустое состояние: иконка, заголовок, пояснение и необязательное действие.
/// Один вид на все экраны, чтобы «ничего нет» выглядело одинаково и не
/// притворялось ошибкой (`ErrorStateCard` — только для сбоев).
struct EmptyStateCard: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var actionSystemImage: String = "arrow.clockwise"
    var action: (() -> Void)?
    var cornerRadius: CGFloat = 24
    var padding: CGFloat = 18

    @Environment(\.contentTone) private var tone

    var body: some View {
        GlassCard(cornerRadius: cornerRadius, padding: padding) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))

                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(tone.primary)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(tone.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle, let action {
                    GlassButton(actionTitle, systemImage: actionSystemImage, action: action)
                }
            }
        }
    }
}
import SwiftUI

/// Единая шапка модального экрана: крупный заголовок и закрытие справа.
///
/// Экраны открываются через `.sheet` без `NavigationView`, поэтому
/// `navigationTitle` там не виден — заголовок рисуем сами.
struct GlassScreenHeader: View {
    let title: String
    var subtitle: String?
    var onClose: (() -> Void)?

    @Environment(\.contentTone) private var tone

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(tone.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(tone.tertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let onClose {
                GlassIconButton("xmark.circle.fill", label: "Закрыть", action: onClose)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
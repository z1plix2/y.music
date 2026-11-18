import SwiftUI
import UIKit

/// Сердечко в стеклянном стиле. Тактильный отклик — через
/// `UIImpactFeedbackGenerator`: `.sensoryFeedback` на iOS 15 недоступен.
struct LikeButton: View {
    let isLiked: Bool
    let isPending: Bool
    var size: CGFloat = 34
    let action: () -> Void

    @Environment(\.contentTone) private var tone

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isLiked ? accent : tone.secondary)
                .frame(width: size, height: size)
                .opacity(isPending ? 0.45 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .disabled(isPending)
        .accessibilityLabel(isLiked ? "Убрать из «Мне нравится»" : "Добавить в «Мне нравится»")
    }

    private var accent: Color {
        Color(red: 0.85, green: 0.20, blue: 0.30)
    }
}

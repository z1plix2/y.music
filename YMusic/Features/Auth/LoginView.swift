import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: AuthService

    @State private var isShowingLogin = false

    var body: some View {
        ZStack {
            LiquidBackdrop()

            VStack(spacing: 0) {
                Spacer(minLength: 32)
                brand
                Spacer(minLength: 36)
                card
                Spacer(minLength: 24)
                footnote
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: 480)
        }
        .animation(.easeInOut(duration: 0.25), value: auth.isAuthenticating)
        .sheet(isPresented: $isShowingLogin) {
            if let url = auth.authorizeURL {
                YandexLoginView(
                    authorizeURL: url,
                    onToken: { token in
                        isShowingLogin = false
                        Task { await auth.completeSignIn(with: token) }
                    },
                    onError: { message in
                        isShowingLogin = false
                        auth.reportLoginError(message)
                    },
                    onCancel: { isShowingLogin = false }
                )
            }
        }
    }

    // MARK: - Шапка

    private var brand: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.99, green: 0.45, blue: 0.12),
                                Color(red: 0.86, green: 0.10, blue: 0.24)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 96, height: 96)
                    .shadow(color: Color(red: 0.95, green: 0.3, blue: 0.2).opacity(0.45), radius: 30, y: 14)

                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text("YMusic")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Ваша музыка, ваш плеер")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Карточка входа

    private var card: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Вход в Яндекс.Музыку")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("Откроется окно Яндекс ID — пароль вводится на стороне Яндекса.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            signInButton

            if let message = auth.errorMessage {
                errorLabel(message)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(22)
        .glassPanel(cornerRadius: 32, material: .regularMaterial)
    }

    private var signInButton: some View {
        Button {
            auth.clearError()
            isShowingLogin = true
        } label: {
            HStack(spacing: 12) {
                Group {
                    if auth.isAuthenticating {
                        ProgressView().tint(.white)
                    } else {
                        YandexMark()
                    }
                }
                .frame(width: 26, height: 26)

                Text(auth.isAuthenticating ? "Загружаем аккаунт..." : "Войти через Яндекс")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .bold))
                    .opacity(auth.isAuthenticating ? 0 : 0.75)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 58)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.92, green: 0.18, blue: 0.24),
                        Color(red: 0.82, green: 0.08, blue: 0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: Color(red: 0.9, green: 0.15, blue: 0.2).opacity(0.35), radius: 22, y: 10)
        }
        .buttonStyle(PressableStyle())
        .disabled(auth.isAuthenticating)
        .accessibilityLabel("Войти через Яндекс")
    }

    private func errorLabel(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55))
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.red.opacity(0.14))
        )
    }

    private var footnote: some View {
        Text("Приложение получает только токен доступа. Пароль и данные карты остаются у Яндекса.")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.35))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
    }
}

private struct YandexMark: View {
    var body: some View {
        Text("Я")
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.92, green: 0.16, blue: 0.22))
            .frame(width: 26, height: 26)
            .background(Circle().fill(.white))
    }
}

#if DEBUG
struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
            .environmentObject(AuthService())
            .preferredColorScheme(.dark)
    }
}
#endif
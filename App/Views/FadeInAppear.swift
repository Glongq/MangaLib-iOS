import SwiftUI

extension View {
    /// Плавное появление (fade + лёгкое увеличение) при первом рендере — для
    /// кастомных кнопок "назад"/действий на экранах, куда попадают пушем
    /// (NavigationStack), которые иначе появляются мгновенно вместе с
    /// остальным экраном вместо отдельной анимации.
    ///
    /// Небольшая задержка перед стартом (0.05с) — без неё эффект был
    /// НЕВИДИМ на практике: `withAnimation` внутри `onAppear` иногда успевает
    /// полностью доиграть ДО того, как экран реально появится на экране
    /// (у пунктов NavigationStack `onAppear` срабатывает уже на этапе
    /// подготовки перехода, а не после него) — тогда к моменту, когда кнопку
    /// физически видно, opacity уже 1 и анимации не видно вообще.
    func fadeInOnAppear() -> some View {
        modifier(FadeInAppearModifier())
    }
}

private struct FadeInAppearModifier: ViewModifier {
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.7)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeOut(duration: 0.28)) { appeared = true }
                }
            }
    }
}

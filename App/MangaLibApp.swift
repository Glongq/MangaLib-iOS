import SwiftUI

@main
struct MangaLibApp: App {
    var body: some Scene {
        WindowGroup {
            // Корень приложения снова RootView.swift (самодельная SwiftUI-
            // панель) — см. историю выбора в комментарии там. Больше не
            // требует iOS 26 (UITabBarController был единственной причиной
            // ограничения деплоймент-таргета).
            RootView()
        }
    }
}

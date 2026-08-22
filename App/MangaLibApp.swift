import SwiftUI

@main
struct MangaLibApp: App {
    var body: some Scene {
        WindowGroup {
            // Корень приложения — RootView.swift (настоящий системный
            // TabView/Tab, Liquid Glass "из коробки") — см. историю выбора
            // в комментарии там.
            RootView()
        }
    }
}

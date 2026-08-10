import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Неофициальный клиент для mangalib.org.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("О приложении")
                }

                Section {
                    LabeledContent("Сайт", value: MangaLibConfig.siteHost)
                } header: {
                    Text("Сервис")
                }
            }
            .navigationTitle("Настройки")
        }
    }
}

#Preview {
    SettingsView()
}

import SwiftUI

struct SearchView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Поиск",
                systemImage: "magnifyingglass",
                description: Text("Поиск по каталогу — следующий этап.")
            )
            .navigationTitle("Поиск")
        }
    }
}

#Preview {
    SearchView()
}

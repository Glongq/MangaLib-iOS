import SwiftUI

struct CatalogView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Каталог",
                systemImage: "books.vertical",
                description: Text("Список манги появится на следующем этапе.")
            )
            .navigationTitle("Каталог")
        }
    }
}

#Preview {
    CatalogView()
}

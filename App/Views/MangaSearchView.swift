import SwiftUI

/// Совместимость: экран поиска теперь реализован в `MangaCatalogView`.
/// Оставлено тонкой обёрткой, чтобы не ломать существующие ссылки.
struct MangaSearchView: View {
    var body: some View { MangaCatalogView() }
}

#Preview {
    MangaSearchView().preferredColorScheme(.dark)
}

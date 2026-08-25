import SwiftUI

/// Полноэкранная листалка доп. обложек тайтла (GET /manga/{slug}/covers —
/// ПОДТВЕРЖДЕНО реальным перехваченным запросом, см.
/// MangaNetworkService.fetchCoverGallery). Открывается тапом по обложке в
/// шапке карточки тайтла (см. MangaDetailView.heroHeader/coverGalleryBadge).
///
/// Крестик закрытия — та же позиция (padding.trailing 16/padding.top 54) и
/// тот же стеклянный кружок, что и у кнопки "..." на карточке тайтла (как
/// явно попросили — "крест находится там же где и три точки в карточке
/// тайтла"). Картинки — центрированы, растянуты во всю ширину экрана
/// (scaledToFit, края доходят до горизонтальных краёв экрана). Внизу —
/// текстовый индикатор "N / всего" (не точки — просили именно "номер").
struct CoverGalleryView: View {
    let items: [MangaCoverGalleryItem]
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(items.indices, id: \.self) { index in
                    ZStack {
                        // Слабый блюр той же картинки на весь экран — под
                        // основной (scaledToFit, поэтому по бокам/сверху-снизу
                        // у некадрированных под экран обложек остаются пустые
                        // поля) — по прямой просьбе, вместо голого чёрного фона.
                        // Тот же URL — RemoteImageCache отдаст уже скачанный
                        // байткод картинки, а не второй отдельный запрос.
                        RemoteImage(url: items[index].cover.fullResURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        } failure: {
                            Color.clear
                        }
                        .blur(radius: 24)
                        .overlay(Color.black.opacity(0.35))
                        .clipped()

                        RemoteImage(url: items[index].cover.fullResURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            ProgressView().tint(.white)
                        } failure: {
                            Image(systemName: "photo")
                                .font(.system(size: 40))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .glassEffect(.regular, in: Circle())
            }
            .padding(.trailing, 16)
            .padding(.top, 54)
        }
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                Text("\(currentIndex + 1) / \(items.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.bottom, 24)
            }
        }
        .persistentSystemOverlays(.hidden)
    }
}

#Preview {
    CoverGalleryView(items: [])
        .preferredColorScheme(.dark)
}

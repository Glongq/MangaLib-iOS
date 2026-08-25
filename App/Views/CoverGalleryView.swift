import SwiftUI

/// Один элемент листалки — раздельные URL для блюр-фона и резкой картинки.
/// Раньше был один и тот же (полноразмерный "orig") URL для ОБОИХ слоёв —
/// блюру такое разрешение всё равно не нужно (после blur(radius: 24) детали
/// не видны), а качать orig ДВАЖДЫ на каждую страницу заметно тормозило
/// открытие галереи (см. фидбек "грузит обложки медленно"). Теперь фон —
/// маленький thumbnail (грузится почти мгновенно), а резкая картинка —
/// полное разрешение, как и раньше.
struct CoverGalleryImage {
    let thumbnailURL: URL?
    let fullURL: URL?
}

/// Полноэкранная листалка доп. обложек тайтла (GET /manga/{slug}/covers —
/// ПОДТВЕРЖДЕНО реальным перехваченным запросом, см.
/// MangaNetworkService.fetchCoverGallery). Открывается тапом по обложке в
/// шапке карточки тайтла (см. MangaDetailView.heroHeader/coverGalleryBadge).
///
/// - Крестик закрытия — та же позиция (padding.trailing 16/padding.top 54) и
///   тот же стеклянный кружок, что и у кнопки "..." на карточке тайтла.
///   ВАЖНО: .ignoresSafeArea() должен стоять ДО .overlay() (а не после) —
///   иначе overlay считает позицию от урезанного safe-area фрейма, а не от
///   истинного края экрана, и крестик оказывается ниже, чем нужно (плюс
///   высота статус-бара сверху) — именно так и было раньше, поправлено.
/// - Каждая страница получает ЯВНЫЙ фиксированный размер (proxy.size из
///   ОДНОГО общего GeometryReader, а не измеряется индивидуально) — иначе
///   пока картинка (или её плейсхолдер) ещё грузится/меняет размер, страницы
///   TabView(.page) могут на мгновение "наехать" друг на друга при свайпе
///   (см. фидбек "картинки вылазят за экран и нажаливаются друг на друга").
/// - Переход открытия — .navigationTransition(.zoom(...)) (iOS 18+): картинка
///   визуально "вырастает" из обложки на карточке тайтла, а не резко
///   выезжает отдельным чёрным экраном — источник помечен модификатором
///   .matchedTransitionSource(id:in:) на самой обложке (см. MangaDetailView).
struct CoverGalleryView: View {
    let images: [CoverGalleryImage]
    let transitionSourceID: String
    let transitionNamespace: Namespace.ID

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex = 0

    var body: some View {
        GeometryReader { proxy in
            TabView(selection: $currentIndex) {
                ForEach(images.indices, id: \.self) { index in
                    page(images[index], index: index, size: proxy.size)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black)
        .ignoresSafeArea()
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
            if images.count > 1 {
                Text("\(currentIndex + 1) / \(images.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.bottom, 24)
            }
        }
        .persistentSystemOverlays(.hidden)
        .navigationTransition(.zoom(sourceID: transitionSourceID, in: transitionNamespace))
    }

    /// Блюр-фон (маленький thumbnail, во весь фиксированный размер страницы)
    /// + резкая картинка ПОВЕРХ, по центру, вписанная по ширине/высоте
    /// (scaledToFit — самый длинный край упирается в границу страницы, без
    /// обрезки и без вылезания за неё).
    ///
    /// "Окно" — реальные RemoteImage только у текущей страницы и её
    /// НЕПОСРЕДСТВЕННЫХ соседей (currentIndex ± 1), у остальных просто
    /// чёрный прямоугольник. TabView(.page) в SwiftUI, в отличие от
    /// LazyHStack, строит ВСЕ страницы сразу (не лениво) — без этого окна
    /// открытие галереи из 37 обложек стартовало 37 параллельных загрузок
    /// разом, забивая канал и заметно тормозя именно ТЕКУЩУЮ картинку (см.
    /// фидбек "грузит обложки медленно"). Соседей (не только текущую)
    /// держим прогретыми — иначе при свайпе следующая страница на мгновение
    /// была бы пустой, пока стартует загрузка.
    @ViewBuilder
    private func page(_ image: CoverGalleryImage, index: Int, size: CGSize) -> some View {
        if abs(index - currentIndex) <= 1 {
            ZStack {
                RemoteImage(url: image.thumbnailURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                } failure: {
                    Color.clear
                }
                .frame(width: size.width, height: size.height)
                .blur(radius: 24)
                .overlay(Color.black.opacity(0.35))
                .clipped()

                RemoteImage(url: image.fullURL) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().tint(.white)
                } failure: {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        } else {
            Color.black
                .frame(width: size.width, height: size.height)
        }
    }
}

private struct CoverGalleryPreview: View {
    @Namespace private var ns
    var body: some View {
        CoverGalleryView(images: [], transitionSourceID: "preview", transitionNamespace: ns)
            .preferredColorScheme(.dark)
    }
}

#Preview {
    CoverGalleryPreview()
}

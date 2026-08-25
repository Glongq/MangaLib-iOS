import SwiftUI
import UIKit

/// Снимок текущего окна приложения — для блюр-фона листалки (см.
/// CoverGalleryView): "размываться должна не картинка, а именно приложение
/// за ней" — реальный кадр экрана В МОМЕНТ открытия (карточка тайтла под
/// галереей), а не блюр самой обложки/фото. Один статичный снимок на всю
/// сессию просмотра (не на каждую страницу) — так и корректно (за галереей
/// всегда один и тот же экран тайтла), и быстрее (не нужно ничего грузить).
extension UIView {
    func renderedSnapshot() -> UIImage {
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { _ in drawHierarchy(in: bounds, afterScreenUpdates: false) }
    }
}

extension UIApplication {
    var activeKeyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

/// Полноэкранная листалка доп. обложек тайтла (GET /manga/{slug}/covers —
/// ПОДТВЕРЖДЕНО реальным перехваченным запросом, см.
/// MangaNetworkService.fetchCoverGallery). Открывается тапом по обложке в
/// шапке карточки тайтла (см. MangaDetailView.heroHeader/coverGalleryBadge).
///
/// - Стартует с ПОСЛЕДНЕЙ картинки (initialIndex = images.count - 1), не с
///   первой — по прямой просьбе: последний элемент галереи всегда и есть
///   ТЕКУЩАЯ обложка тайтла, значит открывать нужно именно с неё ("37/37"),
///   а свайп дальше — уже вглубь истории обложек. Дальше — обычный
///   двусторонний свайп TabView(.page), отдельной логики направления не
///   нужно: от последнего индекса можно свайпнуть в обе стороны как обычно.
/// - Блюр-фон — ОДИН снимок приложения (см. UIView.renderedSnapshot выше),
///   а не блюр текущей картинки.
/// - Крестик закрытия — та же позиция (padding.trailing 16/padding.top 54) и
///   тот же стеклянный кружок, что и у кнопки "..." на карточке тайтла.
///   ВАЖНО: .ignoresSafeArea() должен стоять ДО .overlay() (а не после) —
///   иначе overlay считает позицию от урезанного safe-area фрейма, а не от
///   истинного края экрана.
/// - Каждая страница получает ЯВНЫЙ фиксированный размер (proxy.size из
///   ОДНОГО общего GeometryReader) — устраняет наезд страниц друг на друга
///   при свайпе, пока картинка ещё грузится.
/// - Переход открытия — .navigationTransition(.zoom(...)) (iOS 18+): картинка
///   визуально "вырастает" из обложки на карточке тайтла — источник помечен
///   .matchedTransitionSource(id:in:) на самой обложке (см. MangaDetailView).
///   Блюр-фон СИНХРОННО нарастает вместе с этим ростом (не появляется сразу
///   готовым) — см. isBlurred/background(size:) — а при закрытии так же
///   плавно спадает, ПЕРЕД тем как реально закрыть экран (см. closeGallery),
///   т.е. в точности то же самое, просто в обратном порядке, как попросили.
struct CoverGalleryView: View {
    let images: [URL]
    let backgroundSnapshot: UIImage?
    let transitionSourceID: String
    let transitionNamespace: Namespace.ID

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    /// Управляет интенсивностью блюра/затемнения фона — false в момент
    /// появления (пока картинка ещё "летит" от обложки к полному экрану),
    /// затем анимированно true. При закрытии — обратно к false, и уже
    /// ПОСЛЕ этого закрытие экрана (см. closeGallery).
    @State private var isBlurred = false

    init(images: [URL], backgroundSnapshot: UIImage?, transitionSourceID: String, transitionNamespace: Namespace.ID) {
        self.images = images
        self.backgroundSnapshot = backgroundSnapshot
        self.transitionSourceID = transitionSourceID
        self.transitionNamespace = transitionNamespace
        _currentIndex = State(initialValue: max(0, images.count - 1))
    }

    /// Длительность фейда блюра — подобрана под примерную длительность
    /// системного .navigationTransition(.zoom), её саму API не отдаёт.
    private static let blurFadeDuration: Double = 0.35

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background(size: proxy.size)

                TabView(selection: $currentIndex) {
                    ForEach(images.indices, id: \.self) { index in
                        page(images[index], index: index, size: proxy.size)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: Self.blurFadeDuration)) { isBlurred = true }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: closeGallery) {
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
            // Тот же стеклянный бабл, что у номера страницы в читалке манги
            // (см. MangaReaderView.pageBubble) — тот же шрифт/паддинг/капсула,
            // просто белый текст (в читалке fg зависит от темы страницы, тут
            // всегда поверх фото/блюра).
            if images.count > 1 {
                Text("\(currentIndex + 1)/\(images.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.bottom, 24)
            }
        }
        .persistentSystemOverlays(.hidden)
        .navigationTransition(.zoom(sourceID: transitionSourceID, in: transitionNamespace))
    }

    /// Сначала плавно снимаем блюр (та же анимация, что при открытии, в
    /// обратную сторону), и ТОЛЬКО ПОСЛЕ этого реально закрываем экран —
    /// иначе dismiss() убрал бы вьюху мгновенно, а обратная анимация блюра
    /// просто не успела бы отыграть.
    private func closeGallery() {
        withAnimation(.easeIn(duration: Self.blurFadeDuration)) { isBlurred = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.blurFadeDuration) {
            dismiss()
        }
    }

    @ViewBuilder
    private func background(size: CGSize) -> some View {
        if let backgroundSnapshot {
            Image(uiImage: backgroundSnapshot)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .blur(radius: isBlurred ? 30 : 0)
                .overlay(Color.black.opacity(isBlurred ? 0.45 : 0))
                .clipped()
        } else {
            Color.black.opacity(isBlurred ? 1 : 0)
        }
    }

    /// "Окно" — реальный RemoteImage только у текущей страницы и её
    /// НЕПОСРЕДСТВЕННЫХ соседей (currentIndex ± 1), у остальных пусто.
    /// TabView(.page) в SwiftUI, в отличие от LazyHStack, строит ВСЕ
    /// страницы сразу (не лениво) — без этого окна открытие галереи из 37
    /// обложек стартовало 37 параллельных загрузок разом, забивая канал и
    /// заметно тормозя именно ТЕКУЩУЮ картинку (см. фидбек "грузит обложки
    /// медленно"). Соседей держим прогретыми — иначе при свайпе следующая
    /// страница на мгновение была бы пустой, пока стартует загрузка.
    @ViewBuilder
    private func page(_ url: URL, index: Int, size: CGSize) -> some View {
        let isInWindow = abs(index - currentIndex) <= 1
        Group {
            if isInWindow {
                RemoteImage(url: url) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().tint(.white)
                } failure: {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .transition(.opacity)
            } else {
                Color.clear
            }
        }
        // Только контент СВОЕЙ страницы (не сам жест пролистывания
        // TabView — тот уже нативно плавный) плавно проявляется/меняется —
        // раньше плейсхолдер/картинка внутри страницы просто резко
        // подменялись, отсюда и ощущение "резких" свайпов.
        .animation(.easeInOut(duration: 0.2), value: isInWindow)
        .frame(width: size.width, height: size.height)
    }
}

private struct CoverGalleryPreview: View {
    @Namespace private var ns
    var body: some View {
        CoverGalleryView(images: [], backgroundSnapshot: nil, transitionSourceID: "preview", transitionNamespace: ns)
            .preferredColorScheme(.dark)
    }
}

#Preview {
    CoverGalleryPreview()
}

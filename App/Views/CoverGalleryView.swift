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
///   первой — последний элемент галереи всегда и есть ТЕКУЩАЯ обложка
///   тайтла, значит открывать нужно именно с неё ("37/37").
/// - Блюр-фон — background(), ОДИН вью-инстанс, СИБЛИНГ у TabView в общем
///   ZStack (а не что-то внутри каждой страницы) — один и тот же для ВСЕХ
///   страниц галереи, не пересоздаётся при пролистывании. Внутри — снимок
///   приложения (см. UIView.renderedSnapshot выше), не блюр текущей
///   картинки, и всегда включён на полную (без своей анимации нарастания/
///   спада — отдельная от системного .navigationTransition(.zoom) анимация
///   не синхронизировалась с ней и давала дёрганое закрытие).
/// - НИКАКОГО GeometryReader — раньше страницы и фон получали явный размер
///   через proxy.size из GeometryReader, и это было источником сразу
///   нескольких проблем: 1) фон иногда не докрывал экран до конца ("блюр не
///   на всё, снизу какая-то штука недоделанная" — GeometryReader не всегда
///   успевал пересчитать size синхронно с .ignoresSafeArea()/скрытием home
///   indicator), 2) свайп между страницами слегка "довозил" в конце
///   (лишний пересчёт geometry). Теперь и фон, и страницы — просто
///   .frame(maxWidth: .infinity, maxHeight: .infinity) — тянутся под
///   реальный размер контейнера НЕПРЕРЫВНО, в каждом кадре анимации, без
///   отдельного измерения.
/// - Крестик закрытия — тот же стеклянный кружок, что и у кнопки "..." на
///   карточке тайтла, поднят на высоту своей же кнопки (48pt).
/// - Плейсхолдер картинки, пока грузится — скелетон (SkeletonBox), не
///   спиннер — тот же приём, что и везде в приложении.
struct CoverGalleryView: View {
    let images: [URL]
    let backgroundSnapshot: UIImage?
    let transitionSourceID: String
    let transitionNamespace: Namespace.ID

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int

    init(images: [URL], backgroundSnapshot: UIImage?, transitionSourceID: String, transitionNamespace: Namespace.ID) {
        self.images = images
        self.backgroundSnapshot = backgroundSnapshot
        self.transitionSourceID = transitionSourceID
        self.transitionNamespace = transitionNamespace
        _currentIndex = State(initialValue: max(0, images.count - 1))
    }

    var body: some View {
        // Крестик закрытия и бабл номера страницы — ТЕПЕРЬ одна общая нижняя
        // "полоса" (HStack), а не два независимых оверлея с одинаковым
        // .padding(.bottom, 24), которые формально стояли на одной высоте, но
        // визуально не были ничем связаны — бабл по центру, крестик отдельно
        // в углу сам по себе, "как будто забыт там" (по прямой просьбе
        // исправлено — "крестик теперь вообще в углу"). Бабл — по центру ВСЕЙ
        // строки (Spacer с обеих сторон, тот же эффект, что и раньше давал
        // .overlay(alignment: .bottom) на всю ширину), крестик — оверлеем
        // поверх этой ЖЕ строки у trailing-края, то есть буквально на одной
        // высоте и в одном визуальном "блоке", а не отдельно.
        //
        // ОТДЕЛЬНЫЙ слой ПОВЕРХ содержимого (а не overlay уже
        // .ignoresSafeArea()'нутого TabView/фона) — чтобы позиция считалась
        // от НАСТОЯЩЕЙ safe area, а не от буквального края экрана; фон/
        // листалка при этом по-прежнему полноэкранные (их .ignoresSafeArea()
        // ниже не тронут).
        ZStack(alignment: .bottom) {
            ZStack {
                background

                TabView(selection: $currentIndex) {
                    ForEach(images.indices, id: \.self) { index in
                        page(images[index], index: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .ignoresSafeArea()

            HStack {
                Spacer(minLength: 0)
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
                }
                Spacer(minLength: 0)
            }
            .overlay(alignment: .trailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular, in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .persistentSystemOverlays(.hidden)
        .navigationTransition(.zoom(sourceID: transitionSourceID, in: transitionNamespace))
    }

    /// ОДИН общий фон на всю галерею — сиблинг TabView в ZStack выше, не
    /// часть какой-либо отдельной страницы, поэтому не пересоздаётся и не
    /// "мигает" при пролистывании. .frame(maxWidth:.infinity,
    /// maxHeight:.infinity) вместо явного числового размера — гарантированно
    /// покрывает весь контейнер целиком, включая углы под статус-баром/home
    /// indicator, без риска не успеть пересчитаться.
    @ViewBuilder
    private var background: some View {
        Group {
            if let backgroundSnapshot {
                Image(uiImage: backgroundSnapshot)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blur(radius: 20) // было 30, уменьшили в 1.5х по просьбе
        .overlay(Color.black.opacity(0.45))
        .clipped()
        .ignoresSafeArea()
    }

    /// "Окно" — реальный RemoteImage только у текущей страницы и её
    /// НЕПОСРЕДСТВЕННЫХ соседей (currentIndex ± 1), у остальных пусто.
    /// TabView(.page) в SwiftUI, в отличие от LazyHStack, строит ВСЕ
    /// страницы сразу (не лениво) — без этого окна открытие галереи из 37
    /// обложек стартовало 37 параллельных загрузок разом, забивая канал и
    /// заметно тормозя именно ТЕКУЩУЮ картинку (см. фидбек "грузит обложки
    /// медленно"). Соседей держим прогретыми — иначе при свайпе следующая
    /// страница на мгновение была бы пустой, пока стартует загрузка.
    ///
    /// БЕЗ .animation()/.transition() внутри страницы — раньше здесь была
    /// анимация появления контента, но именно она, похоже, и мешала
    /// TabView(.page) нативно ОТСЛЕЖИВАТЬ палец при свайпе (SwiftUI
    /// оборачивал обновления страницы в анимированную транзакцию, из-за
    /// которой сам жест не тянулся плавно, а "телепортировал" сразу на
    /// финальную позицию). Смена окна теперь мгновенная, без фейда — жест
    /// пролистывания важнее декоративного появления картинки.
    @ViewBuilder
    private func page(_ url: URL, index: Int) -> some View {
        let isInWindow = abs(index - currentIndex) <= 1
        Group {
            if isInWindow {
                RemoteImage(url: url) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                // Раньше — Color.clear (пусто совсем, без скелетона): если
                // окно ±1 почему-то не успело прогреться к моменту, когда
                // страница реально показывается (например, TabView(.page)
                // отрапортовал новый currentIndex чуть раньше, чем сама
                // страница успела попасть в окно на предыдущем рендере),
                // пользователь видел голый блюр-фон без вообще какого-либо
                // индикатора — по прямой просьбе теперь всегда скелетон,
                // как и у реально грузящейся картинки.
                SkeletonBox()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

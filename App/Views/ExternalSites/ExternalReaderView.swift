import SwiftUI

/// Чтение тайтла внешнего сайта (см. план, Часть 6) — простая непрерывная
/// вертикальная лента всех страниц, БЕЗ переиспользования MangaReaderView/
/// ReaderViewModel (те завязаны на PageItem/ChapterItem из LibSite-моделей,
/// см. план). У хитоми один тайтл — это ОДНА "глава" целиком, постранично
/// листать между главами, как в LibSite, незачем.
struct ExternalReaderView: View {
    let site: ExternalSite
    let detail: ExternalGalleryDetail
    /// Открыть сразу на этой странице (1-based, `ExternalGalleryPage.index`)
    /// — тап по миниатюре в превью-гриде карточки тайтла (см.
    /// ExternalGalleryDetailView.previewGridSection, план ЧАСТЬ B.3). `nil`
    /// (по умолчанию, обычное открытие через «Читать») — начинает с начала.
    var initialPage: Int?

    @Environment(\.dismiss) private var dismiss
    @State private var showUI = true

    private var provider: any ExternalSiteProvider { ExternalSiteRegistry.provider(for: site) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(detail.pages.enumerated()), id: \.offset) { _, page in
                            ExternalReaderPage(provider: provider, galleryId: detail.id, page: page)
                                .id(page.index)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() } }
                .onAppear {
                    guard let initialPage else { return }
                    // Без анимации и с небольшой задержкой — ScrollViewReader
                    // не может проскроллить к `.id()`, который ещё не успел
                    // разложиться в LazyVStack на первом кадре появления.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo(initialPage, anchor: .top)
                    }
                }
            }

            if showUI {
                topBar
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!showUI)
        .navigationBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular, in: Circle())
            }
            Spacer()
            Text(detail.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .glassEffect(.regular, in: Capsule())
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

/// Одна страница чтения — pageImageURL теперь async throws (у hitomi это
/// чистая формула без сети, у e-hentai — РЕАЛЬНЫЙ запрос за временной
/// H@H-ссылкой каждый раз, см. EHentaiProvider.pageImageURL), поэтому
/// ссылку сначала нужно разрешить в `.task`, а уже потом отдать в
/// ExternalImage (которая качает саму картинку по готовому URL).
private struct ExternalReaderPage: View {
    let provider: any ExternalSiteProvider
    let galleryId: Int
    let page: ExternalGalleryPage

    @State private var resolvedURL: URL?

    /// У e-hentai width/height всегда 0 (см. ExternalGalleryPage doc-comment
    /// — реальный размер известен только после открытия страницы) — плейсхолдер
    /// в этом случае берёт обычное книжное соотношение вместо 0/1 (которое
    /// SwiftUI отрисует нулевой высотой).
    private var placeholderAspectRatio: CGFloat {
        page.width > 0 && page.height > 0 ? CGFloat(page.width) / CGFloat(page.height) : 0.7
    }

    var body: some View {
        ExternalImage(url: resolvedURL) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .aspectRatio(placeholderAspectRatio, contentMode: .fit)
        }
        .scaledToFit()
        .frame(maxWidth: .infinity)
        .task {
            resolvedURL = try? await provider.pageImageURL(galleryId: galleryId, page: page)
        }
    }
}

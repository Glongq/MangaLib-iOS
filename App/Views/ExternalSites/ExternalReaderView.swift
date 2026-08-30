import SwiftUI

/// Чтение тайтла внешнего сайта (см. план, Часть 6) — простая непрерывная
/// вертикальная лента всех страниц, БЕЗ переиспользования MangaReaderView/
/// ReaderViewModel (те завязаны на PageItem/ChapterItem из LibSite-моделей,
/// см. план). У хитоми один тайтл — это ОДНА "глава" целиком, постранично
/// листать между главами, как в LibSite, незачем.
struct ExternalReaderView: View {
    let site: ExternalSite
    let detail: ExternalGalleryDetail

    @Environment(\.dismiss) private var dismiss
    @State private var showUI = true

    private var provider: any ExternalSiteProvider { ExternalSiteRegistry.provider(for: site) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(detail.pages.enumerated()), id: \.offset) { _, page in
                        ExternalImage(url: provider.pageImageURL(hash: page.hash)) {
                            Rectangle()
                                .fill(Color.white.opacity(0.06))
                                .aspectRatio(CGFloat(page.width) / CGFloat(max(page.height, 1)), contentMode: .fit)
                        }
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() } }

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

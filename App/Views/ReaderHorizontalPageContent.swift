import SwiftUI
import UIKit

/// Reusable horizontal page content shared by swipe and tap-only modes.
struct ReaderHorizontalPageContent: View {
    let index: Int
    let candidates: [URL]
    let pageWidth: Int?
    let pageHeight: Int?
    let chapterId: Int?
    let siteId: Int?
    let fitWidth: Bool
    let doubleTapZoom: Bool
    let inertiaMultiplier: Double
    let ringColor: UIColor
    let onTap: (CGFloat) -> Void
    let onZoomChanged: (Bool) -> Void

    @State private var zoomed = false
    @State private var commentsRevealed = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ZoomableImageScrollView(
                        candidates: candidates,
                        fitWidth: fitWidth,
                        doubleTapZoom: doubleTapZoom,
                        doubleTapScale: 1.75,
                        onTap: onTap,
                        onZoomChanged: { isZoomed in
                            zoomed = isZoomed
                            onZoomChanged(isZoomed)
                        },
                        ringColor: ringColor,
                        viewportHeight: geometry.size.height
                    )
                    .frame(width: geometry.size.width, height: imageHeight(in: geometry.size))

                    if let chapterId {
                        Color.clear.frame(height: 1)
                            .onAppear { commentsRevealed = true }
                        if commentsRevealed {
                            Divider().overlay(Color(ringColor).opacity(0.15))
                            ChapterCommentsSheet(
                                chapterId: chapterId,
                                postPage: index + 1,
                                siteId: siteId,
                                embedded: true
                            )
                            .padding(.bottom, 40)
                        }
                    }
                }
                .background(
                    ReaderScrollInertiaConfigurator(enabled: !zoomed, multiplier: inertiaMultiplier)
                        .frame(width: 0, height: 0)
                )
            }
            .scrollDisabled(zoomed)
            .scrollBounceBehavior(.basedOnSize)
        }
        .ignoresSafeArea()
    }

    private func imageHeight(in viewport: CGSize) -> CGFloat {
        guard fitWidth, let pageWidth, let pageHeight, pageWidth > 0, pageHeight > 0 else {
            return viewport.height
        }
        return max(viewport.width * CGFloat(pageHeight) / CGFloat(pageWidth), viewport.height)
    }
}

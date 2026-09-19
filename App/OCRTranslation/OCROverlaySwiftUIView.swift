import SwiftUI

/// SwiftUI overlay for the vertical/continuous reader — positioned inside
/// a GeometryReader over VerticalPageImage's `.overlay`. `fitRect` is the
/// actual letterboxed rect the image occupies within that container
/// (accounting for `.scaledToFit()`), so blocks are placed relative to
/// the image itself, not the (possibly taller/wider) container.
struct OCROverlaySwiftUIView: View {
    let blocks: [RecognizedTextBlock]
    let texts: [UUID: String]
    let style: OCROverlayStyle
    let fitRect: CGRect

    var body: some View {
        ForEach(blocks) { block in
            if let text = texts[block.id] {
                let base = CGRect(
                    x: fitRect.minX + fitRect.width * block.rect.minX,
                    y: fitRect.minY + fitRect.height * block.rect.minY,
                    width: fitRect.width * block.rect.width,
                    height: fitRect.height * block.rect.height
                )
                // Best-effort fit: shrink the font toward the original
                // bbox first, same algorithm as the horizontal/UIKit
                // overlay (OCROverlayFit) so both modes behave alike.
                // `.fixedSize(vertical: true)` is a safety net in case
                // SwiftUI's own text layout needs a touch more room than
                // the UIKit-based estimate — it can only grow, never clip.
                let startFontSize = max(10, min(28, base.height * 0.35))
                let fit = OCROverlayFit.fit(text: text, baseSize: base.size, startFontSize: startFontSize)

                Text(text)
                    .font(.system(size: fit.fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .frame(width: fit.size.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        if style == .backdropPlate {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.72))
                        }
                    }
                    .shadow(color: style.hasTextShadow ? .black.opacity(0.9) : .clear, radius: 3)
                    .position(x: base.midX, y: base.midY)
            }
        }
    }

    /// The rendered rect of `imageSize` inside `containerSize` under
    /// `.scaledToFit()` — centered, letterboxed on the shorter axis.
    static func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (containerSize.width - size.width) / 2, y: (containerSize.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }
}

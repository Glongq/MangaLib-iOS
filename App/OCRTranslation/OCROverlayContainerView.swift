import UIKit

/// UIKit overlay for the horizontal/paged reader — added as a subview of
/// ZoomableImageScrollView's own `imageView` (see PageTranslationController
/// .attach(to:)), so UIScrollView's zoom transform scales/pans it together
/// with the page image for free, with no manual zoomScale/contentOffset
/// math. `isUserInteractionEnabled = false` so it never intercepts
/// taps/pinch/pan.
final class OCROverlayContainerView: UIView {
    private final class BlockLabelView: UIView {
        let label = UILabel()
        init() {
            super.init(frame: .zero)
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.textColor = .white
            label.textAlignment = .center
            addSubview(label)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            label.frame = bounds.insetBy(dx: 4, dy: 2)
        }
    }

    private var blockViews: [UUID: BlockLabelView] = [:]

    func render(blocks: [RecognizedTextBlock], texts: [UUID: String], style: OCROverlayStyle, eraseOriginalText: Bool) {
        let visibleIDs = Set(blocks.compactMap { texts[$0.id] != nil ? $0.id : nil })

        for (id, view) in blockViews where !visibleIDs.contains(id) {
            view.removeFromSuperview()
            blockViews.removeValue(forKey: id)
        }

        for block in blocks {
            guard let text = texts[block.id] else { continue }
            let view = blockViews[block.id] ?? {
                let created = BlockLabelView()
                addSubview(created)
                blockViews[block.id] = created
                return created
            }()

            // "Erase original text" overrides the plate/text-only style
            // choice — filling with the sampled background color IS the
            // point, so a text-only (no background) style wouldn't erase
            // anything.
            let textColor: UIColor
            if eraseOriginalText {
                let sampled = block.backgroundColor
                view.backgroundColor = (sampled?.uiColor ?? .white).withAlphaComponent(1)
                view.layer.cornerRadius = 3
                textColor = (sampled?.isDark ?? false) ? .white : .black
                view.label.layer.shadowOpacity = 0
            } else {
                view.backgroundColor = style.backgroundColor
                view.layer.cornerRadius = style.cornerRadius
                textColor = .white
                if style.hasTextShadow {
                    view.label.layer.shadowColor = UIColor.black.cgColor
                    view.label.layer.shadowOpacity = 0.9
                    view.label.layer.shadowRadius = 3
                    view.label.layer.shadowOffset = .zero
                } else {
                    view.label.layer.shadowOpacity = 0
                }
            }

            // Small outward margin beyond Vision's tight bbox — its edges
            // hug the glyphs closely enough that, flush, a sliver of the
            // original text/anti-aliasing could still peek out from under
            // the plate.
            let baseRect = CGRect(
                x: bounds.width * block.rect.minX,
                y: bounds.height * block.rect.minY,
                width: bounds.width * block.rect.width,
                height: bounds.height * block.rect.height
            ).insetBy(dx: -2, dy: -2)
            // Best-effort fit: shrink the font toward the original bbox
            // first; only grow the box (never truncate) if it still
            // doesn't fit at the minimum readable size — see
            // OCROverlayFit's doc-comment for the exact steps.
            let horizontalInset: CGFloat = 8
            let startFontSize = max(OCROverlayFit.minFontSize, min(28, baseRect.height * 0.35))
            let fit = OCROverlayFit.fit(
                text: text,
                baseSize: CGSize(width: max(1, baseRect.width - horizontalInset), height: baseRect.height - 4),
                startFontSize: startFontSize
            )
            let font = UIFont.systemFont(ofSize: fit.fontSize, weight: .semibold)
            view.label.attributedText = NSAttributedString(string: fit.wrappedText, attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: OCROverlayFit.paragraphStyle()
            ])
            let finalSize = CGSize(width: fit.size.width + horizontalInset, height: fit.size.height + 4)
            view.frame = CGRect(
                x: baseRect.midX - finalSize.width / 2, y: baseRect.midY - finalSize.height / 2,
                width: finalSize.width, height: finalSize.height
            )
        }
    }
}

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
            label.textColor = .white
            label.textAlignment = .center
            label.minimumScaleFactor = 0.5
            label.adjustsFontSizeToFitWidth = true
            addSubview(label)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            label.frame = bounds.insetBy(dx: 4, dy: 2)
        }
    }

    private var blockViews: [UUID: BlockLabelView] = [:]

    func render(blocks: [RecognizedTextBlock], texts: [UUID: String], style: OCROverlayStyle) {
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

            view.backgroundColor = style.backgroundColor
            view.layer.cornerRadius = style.cornerRadius
            view.label.text = text
            let fontSize = max(10, bounds.height * block.rect.height * 0.35)
            view.label.font = .systemFont(ofSize: fontSize, weight: .semibold)
            if style.hasTextShadow {
                view.label.layer.shadowColor = UIColor.black.cgColor
                view.label.layer.shadowOpacity = 0.9
                view.label.layer.shadowRadius = 3
                view.label.layer.shadowOffset = .zero
            } else {
                view.label.layer.shadowOpacity = 0
            }

            let baseRect = CGRect(
                x: bounds.width * block.rect.minX,
                y: bounds.height * block.rect.minY,
                width: bounds.width * block.rect.width,
                height: bounds.height * block.rect.height
            )
            // Translated text tends to run longer than the source CJK —
            // let the plate grow a bit rather than clip, capped so it
            // doesn't swallow neighboring bubbles.
            let grownHeight = min(baseRect.height * 1.6, baseRect.height + 40)
            view.frame = CGRect(
                x: baseRect.minX, y: baseRect.minY - (grownHeight - baseRect.height) / 2,
                width: baseRect.width, height: grownHeight
            )
        }
    }
}

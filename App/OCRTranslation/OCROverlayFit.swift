import UIKit

/// Best-effort text-fitting for the translation overlay: given a block's
/// original on-screen box, picks a font size (and, if needed, a slightly
/// widened box) so the translated text lands close to that box — never by
/// cutting text off, only by shrinking the font and, as a last resort,
/// growing the box to whatever size the text actually needs.
enum OCROverlayFit {
    struct Result {
        let fontSize: CGFloat
        let size: CGSize
    }

    /// Lowered from 8 — small bubbles with a lot of translated text (a
    /// short original CJK/EN line packing into a compact bubble, but
    /// expanding a lot once translated) need to be able to shrink further
    /// before the "grow the box instead" fallback kicks in.
    static let minFontSize: CGFloat = 6
    /// How far the box is allowed to stray from the original bbox before
    /// giving up on shrinking further and just letting it grow — a soft
    /// tolerance, not a hard cap (see step 3 below).
    static let maxWidthMultiplier: CGFloat = 1.2
    static let maxHeightMultiplier: CGFloat = 1.6
    /// UIKit/SwiftUI's default multi-line leading is noticeably looser
    /// than typical comic-bubble lettering — tightened here so wrapped
    /// translated text reads as compact/native instead of visibly
    /// "airier" than the original, and so it actually needs a size closer
    /// to the original bbox. Shared by `measure` (sizing) AND the actual
    /// renderers (OCROverlayContainerView/OCROverlaySwiftUIView) so what
    /// gets sized is what gets drawn.
    static let lineHeightMultiple: CGFloat = 0.86

    static func paragraphStyle(alignment: NSTextAlignment = .center) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineHeightMultiple = lineHeightMultiple
        return style
    }

    static func fit(text: String, baseSize: CGSize, startFontSize: CGFloat, weight: UIFont.Weight = .semibold) -> Result {
        guard baseSize.width > 0, baseSize.height > 0, !text.isEmpty else {
            return Result(fontSize: startFontSize, size: baseSize)
        }
        let heightBudget = baseSize.height * maxHeightMultiplier
        var fontSize = max(minFontSize, startFontSize)

        // 1) Shrink the font at the ORIGINAL width until it fits the
        // height budget — the common case (translation a bit longer than
        // the source, same rough shape).
        var measured = measure(text: text, width: baseSize.width, fontSize: fontSize, weight: weight)
        while measured.height > heightBudget, fontSize > minFontSize {
            fontSize -= 1
            measured = measure(text: text, width: baseSize.width, fontSize: fontSize, weight: weight)
        }
        if measured.height <= heightBudget {
            return Result(fontSize: fontSize, size: CGSize(width: baseSize.width, height: max(baseSize.height, measured.height)))
        }

        // 2) Still doesn't fit even at the minimum font size — a bit of
        // extra width often lets long words/phrases wrap into fewer
        // lines. Retry the shrink from the top once more at that width.
        let widerWidth = baseSize.width * maxWidthMultiplier
        fontSize = max(minFontSize, startFontSize)
        measured = measure(text: text, width: widerWidth, fontSize: fontSize, weight: weight)
        while measured.height > heightBudget, fontSize > minFontSize {
            fontSize -= 1
            measured = measure(text: text, width: widerWidth, fontSize: fontSize, weight: weight)
        }

        // 3) Never truncates: if it STILL doesn't fit within the
        // tolerance at min font size, just let the box be as tall as it
        // actually needs to be — an oversized bubble beats cut-off text.
        return Result(fontSize: fontSize, size: CGSize(width: widerWidth, height: max(baseSize.height, measured.height)))
    }

    private static func measure(text: String, width: CGFloat, fontSize: CGFloat, weight: UIFont.Weight) -> CGSize {
        let font = UIFont.systemFont(ofSize: fontSize, weight: weight)
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraphStyle()],
            context: nil
        )
        return CGSize(width: min(width, bounding.width.rounded(.up)), height: bounding.height.rounded(.up))
    }
}

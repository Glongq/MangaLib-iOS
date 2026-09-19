import UIKit

extension OCRSampledColor {
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
}

/// Visual style of the translation overlay when "erase original text" is
/// OFF (see PageTranslationController.eraseOriginalText) — a fixed plate
/// color/text-only caption, not any per-block color sampling.
enum OCROverlayStyle: Int {
    case backdropPlate = 0
    case textOnly = 1

    var backgroundColor: UIColor {
        switch self {
        case .backdropPlate: return UIColor.black.withAlphaComponent(0.72)
        case .textOnly: return .clear
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .backdropPlate: return 6
        case .textOnly: return 0
        }
    }

    var hasTextShadow: Bool {
        self == .textOnly
    }
}

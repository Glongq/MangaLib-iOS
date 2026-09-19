import UIKit

/// Visual style of the translation overlay — no color-sampling/inpainting
/// attempted anywhere, per the explicit "не нужен идеал" product decision.
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

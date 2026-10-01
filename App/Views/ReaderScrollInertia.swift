import SwiftUI
import UIKit

enum ReaderScrollInertia {
    static let defaultMultiplier = 8.0
    static let allowedMultipliers = 1.0...20.0

    static func adjusted(
        from rate: UIScrollView.DecelerationRate,
        multiplier: Double
    ) -> UIScrollView.DecelerationRate {
        let original = Double(rate.rawValue)
        let validMultiplier = multiplier.isFinite
            ? min(max(multiplier, allowedMultipliers.lowerBound), allowedMultipliers.upperBound)
            : defaultMultiplier
        // Deceleration distance is proportional to rate / (1 - rate).
        let adjustedRate = validMultiplier * original / (1 + (validMultiplier - 1) * original)
        return UIScrollView.DecelerationRate(rawValue: CGFloat(adjustedRate))
    }
}

struct ReaderScrollInertiaConfigurator: UIViewRepresentable {
    var enabled = true
    var multiplier = ReaderScrollInertia.defaultMultiplier

    func makeUIView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.isUserInteractionEnabled = false
        view.enabled = enabled
        view.multiplier = multiplier
        return view
    }

    func updateUIView(_ uiView: ConfiguratorView, context: Context) {
        uiView.enabled = enabled
        uiView.multiplier = multiplier
        uiView.configureScrollView()
    }

    final class ConfiguratorView: UIView {
        var enabled = true
        var multiplier = ReaderScrollInertia.defaultMultiplier
        private weak var configuredScrollView: UIScrollView?
        private var originalRate: UIScrollView.DecelerationRate?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                detachScrollView()
            }
            configureScrollView()
        }

        private func detachScrollView() {
            if let configuredScrollView {
                if let originalRate {
                    configuredScrollView.decelerationRate = originalRate
                }
            }
            configuredScrollView = nil
            originalRate = nil
        }

        func configureScrollView() {
            guard window != nil else { return }

            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    if configuredScrollView !== scrollView {
                        detachScrollView()
                        configuredScrollView = scrollView
                        originalRate = scrollView.decelerationRate
                    }
                    if let originalRate {
                        let rate = enabled
                            ? ReaderScrollInertia.adjusted(from: originalRate, multiplier: multiplier)
                            : originalRate
                        if scrollView.decelerationRate.rawValue != rate.rawValue {
                            scrollView.decelerationRate = rate
                        }
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

import SwiftUI
import UIKit

enum ReaderScrollInertia {
    static func increased(from rate: UIScrollView.DecelerationRate) -> UIScrollView.DecelerationRate {
        let original = rate.rawValue
        // Deceleration distance is proportional to rate / (1 - rate).
        let adjusted = 8 * original / (1 + 7 * original)
        return UIScrollView.DecelerationRate(rawValue: adjusted)
    }
}

struct ReaderScrollInertiaConfigurator: UIViewRepresentable {
    var enabled = true

    func makeUIView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.isUserInteractionEnabled = false
        view.enabled = enabled
        return view
    }

    func updateUIView(_ uiView: ConfiguratorView, context: Context) {
        uiView.enabled = enabled
        uiView.configureScrollView()
    }

    final class ConfiguratorView: UIView {
        var enabled = true
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
                        let rate = enabled ? ReaderScrollInertia.increased(from: originalRate) : originalRate
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

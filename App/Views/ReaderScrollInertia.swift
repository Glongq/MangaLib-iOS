import SwiftUI
import UIKit

enum ReaderScrollInertia {
    static func increased(from rate: UIScrollView.DecelerationRate) -> UIScrollView.DecelerationRate {
        let original = rate.rawValue
        // Deceleration distance is proportional to rate / (1 - rate).
        let adjusted = 4 * original / (1 + 3 * original)
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
        private var lastPanTranslation: CGFloat = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                detachScrollView()
            }
            configureScrollView()
        }

        private func detachScrollView() {
            if let configuredScrollView {
                configuredScrollView.panGestureRecognizer.removeTarget(self, action: #selector(amplifyPan(_:)))
                if let originalRate {
                    configuredScrollView.decelerationRate = originalRate
                }
            }
            configuredScrollView = nil
            originalRate = nil
            lastPanTranslation = 0
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
                        scrollView.panGestureRecognizer.addTarget(self, action: #selector(amplifyPan(_:)))
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

        @objc private func amplifyPan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView = configuredScrollView else { return }

            switch gesture.state {
            case .began, .changed:
                let translation = gesture.translation(in: scrollView.window).y
                let delta = translation - lastPanTranslation
                lastPanTranslation = translation
                guard enabled, delta != 0 else { return }

                let minOffset = -scrollView.adjustedContentInset.top
                let maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
                scrollView.contentOffset.y = min(max(scrollView.contentOffset.y - delta, minOffset), maxOffset)
            default:
                lastPanTranslation = 0
            }
        }
    }
}

import SwiftUI
import UIKit

enum ReaderScrollInertia {
    static let defaultMultiplier = 8.0
    static let allowedMultipliers = 1.0...20.0

    static func destination(
        current: CGFloat,
        proposed: CGFloat,
        multiplier: Double,
        lowerBound: CGFloat,
        upperBound: CGFloat
    ) -> CGFloat {
        let validMultiplier = multiplier.isFinite
            ? min(max(multiplier, allowedMultipliers.lowerBound), allowedMultipliers.upperBound)
            : defaultMultiplier
        let destination = current + (proposed - current) * CGFloat(validMultiplier)
        return min(max(destination, lowerBound), upperBound)
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
        private let delegateProxy = DelegateProxy()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                detachScrollView()
            } else {
                configureScrollView()
            }
        }

        private func detachScrollView() {
            if let configuredScrollView {
                configuredScrollView.panGestureRecognizer.removeTarget(self, action: #selector(installDelegateForPan(_:)))
                restoreOriginalDelegate(on: configuredScrollView)
            }
            configuredScrollView = nil
        }

        func configureScrollView() {
            guard window != nil else { return }

            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    if configuredScrollView !== scrollView {
                        detachScrollView()
                        configuredScrollView = scrollView
                        scrollView.panGestureRecognizer.addTarget(self, action: #selector(installDelegateForPan(_:)))
                    }
                    delegateProxy.enabled = enabled
                    delegateProxy.multiplier = multiplier
                    if enabled && multiplier > 1 {
                        installDelegate(on: scrollView)
                    } else {
                        restoreOriginalDelegate(on: scrollView)
                    }
                    return
                }
                ancestor = view.superview
            }
        }

        private func installDelegate(on scrollView: UIScrollView) {
            guard scrollView.delegate !== delegateProxy else { return }
            delegateProxy.forwardedDelegate = scrollView.delegate
            scrollView.delegate = delegateProxy
        }

        private func restoreOriginalDelegate(on scrollView: UIScrollView) {
            if scrollView.delegate === delegateProxy {
                scrollView.delegate = delegateProxy.forwardedDelegate
            }
            delegateProxy.forwardedDelegate = nil
        }

        @objc private func installDelegateForPan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .began || gesture.state == .changed,
                  enabled,
                  multiplier > 1,
                  let scrollView = configuredScrollView else { return }
            installDelegate(on: scrollView)
        }
    }

    final class DelegateProxy: NSObject, UIScrollViewDelegate {
        // Forward every other callback to SwiftUI's delegate so reader behavior stays intact.
        weak var forwardedDelegate: UIScrollViewDelegate?
        var enabled = true
        var multiplier = ReaderScrollInertia.defaultMultiplier

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (forwardedDelegate?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if let forwardedDelegate, forwardedDelegate.responds(to: selector) {
                return forwardedDelegate
            }
            return super.forwardingTarget(for: selector)
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            forwardedDelegate?.scrollViewWillEndDragging?(
                scrollView,
                withVelocity: velocity,
                targetContentOffset: targetContentOffset
            )
            guard enabled, abs(velocity.y) > 0.01 else { return }

            let lowerBound = -scrollView.adjustedContentInset.top
            let upperBound = max(
                lowerBound,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            targetContentOffset.pointee.y = ReaderScrollInertia.destination(
                current: scrollView.contentOffset.y,
                proposed: targetContentOffset.pointee.y,
                multiplier: multiplier,
                lowerBound: lowerBound,
                upperBound: upperBound
            )
        }
    }
}

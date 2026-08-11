import SwiftUI
import UIKit
import ObjectiveC

/// Расширяет СИСТЕМНЫЙ интерактивный жест «назад» NavigationStack на левую
/// ПОЛОВИНУ экрана (обычно он активен только у самого края). Используется именно
/// системный переход — во время свайпа реально виден предыдущий экран, всё
/// следует за пальцем, как в родном iOS.
///
/// Ставится через `.background(InteractivePopGesture())` внутри конкретного
/// экрана (карточка тайтла). Установка выполняется ОДИН РАЗ на навигационный
/// контроллер, а делегат жеста хранится как associated object самого
/// navigation controller — поэтому он живёт столько же, сколько навигация, и
/// жест продолжает работать при КАЖДОМ последующем открытии карточки (раньше
/// делегат жил в per-view координаторе и умирал после первого закрытия — из-за
/// этого свайп срабатывал только один раз).
///
/// ⚠️ KVC-доступ к приватному ключу "targets" системного жеста — единственный
/// способ «расширить» зону активации родного перехода. Для App Store это серая
/// зона, для личной сборки — норм.
struct InteractivePopGesture: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false // фон, не перехватывает тапы
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            guard let nav = uiViewController.navigationController else { return }
            FullSwipePop.install(on: nav)
        }
    }
}

/// Устанавливает pan-жест на левую половину экрана, подключённый к тем же целям
/// (targets), что и штатный `interactivePopGestureRecognizer`.
private enum FullSwipePop {
    private static var delegateKey: UInt8 = 0

    static func install(on nav: UINavigationController) {
        // Уже установлено на этот nav — второй раз не добавляем.
        if objc_getAssociatedObject(nav, &delegateKey) != nil { return }
        guard let popGR = nav.interactivePopGestureRecognizer,
              let targets = popGR.value(forKey: "targets") else { return }

        let delegate = FullSwipePopDelegate()
        delegate.navController = nav

        let pan = UIPanGestureRecognizer()
        pan.setValue(targets, forKey: "targets") // те же обработчики, что у штатного edge-жеста
        pan.delegate = delegate
        nav.view.addGestureRecognizer(pan)

        // Держим делегат живым столько же, сколько живёт navigation controller.
        objc_setAssociatedObject(nav, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

final class FullSwipePopDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var navController: UINavigationController?

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let nav = navController,
              nav.viewControllers.count > 1,      // есть куда возвращаться
              nav.transitionCoordinator == nil,   // не во время уже идущего перехода
              let pan = g as? UIPanGestureRecognizer,
              let view = pan.view else { return false }
        let start = pan.location(in: view)
        let v = pan.velocity(in: view)
        // Левая половина + движение вправо + преимущественно горизонтально.
        return start.x < view.bounds.width / 2 && v.x > 0 && abs(v.x) > abs(v.y)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}

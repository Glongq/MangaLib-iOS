import SwiftUI
import UIKit

/// Расширяет СИСТЕМНЫЙ интерактивный жест «назад» NavigationStack на левую
/// ПОЛОВИНУ экрана (обычно он активен только у самого края). Важно: используется
/// именно системный переход — поэтому во время свайпа реально виден предыдущий
/// экран и всё следует за пальцем, как в родном iOS, а не «пустота» под ручным
/// сдвигом вью.
///
/// Ставится через `.background(InteractivePopGesture())` ВНУТРИ конкретного
/// экрана (сейчас — карточка тайтла), поэтому эффект ограничен именно этим
/// стеком навигации.
///
/// ⚠️ Технически: к view навигационного контроллера добавляется UIPanGesture,
/// подключённый к тем же целям (targets), что и штатный
/// `interactivePopGestureRecognizer` — это единственный способ «расширить» зону
/// активации системного перехода. Используется KVC-доступ к приватному ключу
/// "targets"; для App Store это серая зона, для личной сборки — норм.
struct InteractivePopGesture: UIViewControllerRepresentable {

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false // фон, не перехватывает тапы
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            guard let nav = uiViewController.navigationController,
                  let navView = nav.view else { return }
            // Ставим наш pan только один раз на этот навигационный контроллер.
            if navView.gestureRecognizers?.contains(where: { $0.name == Self.gestureName }) == true { return }
            guard let popGR = nav.interactivePopGestureRecognizer,
                  let targets = popGR.value(forKey: "targets") else { return }

            let pan = UIPanGestureRecognizer()
            pan.name = Self.gestureName
            pan.setValue(targets, forKey: "targets") // те же обработчики, что у штатного edge-жеста
            pan.delegate = context.coordinator
            navView.addGestureRecognizer(pan)
        }
    }

    private static let gestureName = "leftHalfInteractivePop"

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        // Начинаем, только если жест: стартовал в ЛЕВОЙ ПОЛОВИНЕ, направлен
        // ВПРАВО и преимущественно ГОРИЗОНТАЛЕН — чтобы не мешать вертикальному
        // скроллу. (Горизонтальные карусели в левой половине могут конфликтовать —
        // это осознанный компромисс «активна половина».)
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let start = pan.location(in: view)
            let v = pan.velocity(in: view)
            return start.x < view.bounds.width / 2 && v.x > 0 && abs(v.x) > abs(v.y)
        }

        // Не даём распознаваться вместе с другими жестами (чтобы pop, начавшись,
        // забирал жест на себя, а не двигал заодно контент).
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }
    }
}

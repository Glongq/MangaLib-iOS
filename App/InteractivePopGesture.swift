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

/// Гасит АВТОМАТИЧЕСКУЮ системную кнопку «назад» на уровне UIKit — страховка к
/// SwiftUI-модификатору .navigationBarBackButtonHidden(true), который на ПЕРВОМ
/// пуше экрана в стек срабатывает не всегда (см. историю в комментарии к
/// transparentSystemNavigationBar() ниже — именно эта ненадёжность и была
/// причиной трёх раундов "задвоения" кнопки назад в прошлом).
///
/// ⚠️ Работает СТРОГО со своим экраном, а НЕ с nav.topViewController: этот
/// representable живёт в .background(...) конкретного экрана, а
/// updateUIViewController у него вызывается при КАЖДОМ обновлении тела этого
/// экрана — в т.ч. когда экран уже НЕ верхний в стеке (например, карточка
/// тайтла продолжает обновляться, пока поверх неё открыта FranchiseView). Через
/// topViewController мы бы в этот момент погасили кнопку "назад" ЧУЖОМУ экрану
/// — а у FranchiseView своей кнопки нет вообще (обычный системный чеврон), уйти
/// с неё стало бы нечем. Поэтому поднимаемся по цепочке parent до контроллера,
/// который реально лежит в nav.viewControllers — это и есть hosting-контроллер
/// ИМЕННО этого экрана.
///
/// Убирать за собой (dismantle) не нужно: navigationItem принадлежит самому
/// hosting-контроллеру экрана и умирает вместе с ним при pop — в отличие от
/// прежнего DisableInteractivePopGesture, который трогал общее для всего стека
/// interactivePopGestureRecognizer и поэтому обязан был восстанавливать его.
struct HideSystemBackButton: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> UIViewController { Suppressor() }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Страховочный повтор: viewWillAppear ниже обычно уже всё сделал, но
        // SwiftUI может пересобрать бар позже.
        DispatchQueue.main.async { (uiViewController as? Suppressor)?.apply() }
    }

    final class Suppressor: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false // фон, не перехватывает тапы
        }

        /// Самый ранний надёжный момент: вызывается ДО того, как navigation bar
        /// разложится под начавшийся push, — системная кнопка не успевает
        /// мелькнуть даже на один кадр.
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        func apply() {
            guard let nav = navigationController else { return }
            var candidate: UIViewController? = self
            while let vc = candidate {
                if nav.viewControllers.contains(where: { $0 === vc }) {
                    vc.navigationItem.hidesBackButton = true
                    return
                }
                candidate = vc.parent
            }
        }
    }
}

extension View {
    /// РЕАЛЬНЫЙ, но полностью прозрачный и ПУСТОЙ системный navigation bar для
    /// экранов со своей ручной шапкой поверх hero-баннера (MangaDetailView/
    /// TeamView/CharacterView/DirectoryDetailView).
    ///
    /// ЗАЧЕМ (главное — не откатывать обратно на .toolbar(.hidden...)): когда у
    /// текущего экрана бара НЕТ ВООБЩЕ, а у экрана под ним бар ЕСТЬ, да ещё с
    /// .searchable() (Каталог/Закладки/Читают/списки Меню), UIKit при ЛЮБОМ
    /// pop-переходе интерполирует бар между "бара нет" и "бар с полем поиска" —
    /// поле поиска видимо просвечивает сквозь карточку. Это одинаково
    /// происходит и на интерактивном свайпе, и на обычном тапе по "назад" (на
    /// тапе просто быстрее и потому менее заметно). Раньше это лечили полным
    /// отключением самого жеста (DisableInteractivePopGesture) — свайп пропадал
    /// целиком, а глитч на тапе оставался. Если бар ЕСТЬ по обе стороны
    /// перехода — интерполировать нечего, глитча нет ни в одном сценарии, и
    /// свайп-назад работает штатно, без единого хака.
    ///
    /// ЧЕМ ЭТО ОТЛИЧАЕТСЯ от трёх прошлых неудачных заходов: те КАЖДЫЙ РАЗ
    /// вместе с прозрачным баром переносили кнопки "назад"/"..."/подписки в
    /// НАСТОЯЩИЕ ToolbarItem (то .topBarLeading, то .navigation) — и именно там
    /// конкурировали с автоматической системной кнопкой "назад" (задвоение
    /// слева / "фантом" справа за подпиской). Здесь в баре НЕТ НИЧЕГО: ни
    /// заголовка, ни единого ToolbarItem. Кнопки как были, так и остаются
    /// ручным слоем-сиблингом в ZStack поверх ScrollView. Конкурировать больше
    /// не с чем — авто-кнопку мы только ГАСИМ (дважды: и SwiftUI-модификатором,
    /// и UIKit-страховкой HideSystemBackButton), но ничем не заменяем.
    ///
    /// Проверенный прецедент той же схемы в этом же приложении — ProfileView
    /// (AccountInfoView.body): прозрачный бар + своя ручная topBar отдельным
    /// слоем, задвоений не было ни разу.
    func transparentSystemNavigationBar() -> some View {
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .background(HideSystemBackButton())
    }
}

/// Поднимает ручную шапку-оверлей (pinnedTopBar/backButton) на высоту
/// прозрачного системного бара.
///
/// Бар теперь РЕАЛЬНО существует (см. transparentSystemNavigationBar) и, хотя
/// он прозрачный и пустой, он занимает место в safe area: верхний inset стал
/// "статус-бар + высота бара" вместо просто "статус-бар". Без компенсации
/// стеклянные кнопки уехали бы вниз ровно на высоту бара и наехали бы на
/// обложку/аватар (те стоят на фиксированном отступе от верха баннера).
/// Компенсируем ИМЕННО высоту бара (а не "добавляем высоту статус-бара"): так
/// поведение остаётся правильным и в листе (CreditsSheet → DirectoryDetailView),
/// где статус-бара над контентом нет вовсе.
private struct TransparentNavigationBarOverlayInset: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Стандартная высота UINavigationBar: 44 в обычной высоте, 32 в компактной
    /// (айфон в ландшафте). Значение известно синхронно, на ПЕРВОМ проходе
    /// layout — поэтому шапка не "прыгает" на первом кадре.
    private var navigationBarHeight: CGFloat { verticalSizeClass == .compact ? 32 : 44 }

    func body(content: Content) -> some View {
        content.padding(.top, -navigationBarHeight)
    }
}

extension View {
    func alignedWithTransparentNavigationBar() -> some View {
        modifier(TransparentNavigationBarOverlayInset())
    }
}

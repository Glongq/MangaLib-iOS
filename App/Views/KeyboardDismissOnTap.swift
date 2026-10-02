import SwiftUI

extension View {
    /// Первый тап ГДЕ УГОДНО по этому view (даже по карточке тайтла/строке
    /// списка внутри), пока активна клавиатура поиска (`active == true`),
    /// СЪЕДАЕТСЯ — просто снимает фокус с поля поиска, а НЕ долетает до
    /// NavigationLink/Button под пальцем (тайтл не открывается) — по прямой
    /// просьбе: "нажать над клавиатурой даже по какому-то тайтлу и поиск
    /// уберётся, и не откроется тайтл". Второй тап (клавиатура уже закрыта,
    /// `active == false`) работает как обычно — модификатор в этот момент
    /// вообще не навешан (@ViewBuilder), никакого перехвата.
    ///
    /// `.highPriorityGesture` побеждает дочерние жесты/NavigationLink ТОЛЬКО
    /// пока реально навешан — именно поэтому условный, а не просто с пустым
    /// действием внутри: безусловный `.highPriorityGesture` перехватывал бы
    /// вообще любой тап всегда, даже когда клавиатура и не была открыта,
    /// намертво ломая обычную навигацию по списку/сетке. TapGesture не
    /// конкурирует со скроллом (тот распознаётся как drag, не tap) — прокрутка
    /// списка с открытой клавиатурой продолжает работать как раньше.
    @ViewBuilder
    func dismissKeyboardOnFirstTap(active: Bool, dismiss: @escaping () -> Void) -> some View {
        if active {
            self.highPriorityGesture(TapGesture().onEnded { dismiss() })
        } else {
            self
        }
    }
}

/// Замена NavigationLink(value:) для строк/карточек внутри списка с активным
/// поиском — по прямой жалобе: ".highPriorityGesture (см. dismissKeyboardOnFirstTap
/// выше) не всегда реально побеждает NavigationLink — тап по карточке в
/// Каталоге одновременно и закрывал поиск, И открывал тайтл (гонка, а не
/// гарантия). Здесь гарантия другого рода: пока `isSearching == true`,
/// НАСТОЯЩЕГО NavigationLink в дереве вообще нет — вместо него обычная
/// Button, которая просто снимает фокус с поля поиска. Как только поиск
/// закрыт, view пересобирается с обычным NavigationLink — навигация тапом
/// работает как всегда. Никакой гонки жестов, потому что нечему
/// конкурировать.
struct SearchDismissibleNavigationLink<Value: Hashable, Label: View>: View {
    let value: Value
    let isSearching: Bool
    let dismiss: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        if isSearching {
            Button(action: dismiss) { label() }
        } else {
            NavigationLink(value: value) { label() }
        }
    }
}

/// Тот же приём, что и SearchDismissibleNavigationLink, но для
/// NavigationLink(destination:) — экраны, где пункт списка не Hashable-
/// значение с .navigationDestination(for:), а сразу готовый destination-view
/// (см. DirectoryDetailView.grid).
struct SearchDismissibleDestinationLink<Destination: View, Label: View>: View {
    let isSearching: Bool
    let dismiss: () -> Void
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label

    var body: some View {
        if isSearching {
            Button(action: dismiss) { label() }
        } else {
            NavigationLink(destination: destination) { label() }
        }
    }
}

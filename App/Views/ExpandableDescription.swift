import SwiftUI

/// Текст описания, ограниченный 4 строками — если реально не помещается,
/// снизу появляется оранжевая ссылка "Подробнее..." (разворачивает весь
/// текст), а после разворота — "Свернуть", тоже оранжевым.
///
/// Определяет, нужна ли вообще ссылка (а не показывает её всегда "на
/// всякий случай"), сравнивая РЕАЛЬНУЮ высоту текста без лимита строк с
/// высотой при лимите 4 — тот же приём измерения через невидимый
/// GeometryReader-в-background, что и TitleBlockHeightKey в MangaDetailView
/// (просто чистый SwiftUI, без ручного счёта строк через UIFont/NSString).
struct ExpandableDescription: View {
    let text: String
    var collapsedLines: Int = 4

    @State private var expanded = false
    @State private var truncatedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var needsToggle: Bool { fullHeight > truncatedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            textView
                .lineLimit(expanded ? nil : collapsedLines)
                .background(measurement)

            if needsToggle {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "Свернуть" : "Подробнее...")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.orange)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var textView: some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.textSecondary)
    }

    /// Два невидимых замера ТОЙ ЖЕ ширины, что и видимый текст (background
    /// наследует размер модифицируемой вью) — с лимитом collapsedLines и без
    /// лимита вовсе. Если высоты совпадают — текст и так помещается целиком,
    /// ссылка не нужна.
    private var measurement: some View {
        ZStack(alignment: .topLeading) {
            textView.lineLimit(collapsedLines).fixedSize(horizontal: false, vertical: true)
                .background(heightReader($truncatedHeight))
                .hidden()
            textView.lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                .background(heightReader($fullHeight))
                .hidden()
        }
    }

    private func heightReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { geo -> Color in
            DispatchQueue.main.async {
                if binding.wrappedValue != geo.size.height { binding.wrappedValue = geo.size.height }
            }
            return Color.clear
        }
    }
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            ExpandableDescription(text: String(repeating: "Очень длинное описание тайтла. ", count: 20))
            ExpandableDescription(text: "Короткое описание в одну строку.")
        }
        .padding()
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}

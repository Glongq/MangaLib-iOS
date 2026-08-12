import SwiftUI
import UIKit

/// Блок «чипсов» (жанры/теги) с обводкой и переносом по строкам.
/// Свёрнут: столько элементов, сколько реально помещается в maxCollapsedRows
/// строк (считаем по РЕАЛЬНОЙ ширине текста, а не по фиксированному
/// количеству элементов — раньше был магический "первые 12", из-за чего
/// свёрнутый блок мог занимать то 2 строки, то 4, в зависимости от длины
/// конкретных названий). Развёрнут: все (переносятся, высота считается точно).
struct CollapsibleChips: View {
    /// Один чип. `tint` — nil = обычная (нейтральная) раскраска, как раньше;
    /// не-nil — чип красится в этот цвет (обводка + текст), нужно для
    /// возрастного рейтинга (18+ красным/16+ оранжевым), см. MangaDetailView.
    struct Item {
        let text: String
        var tint: Color? = nil
        /// Действие по тапу (напр. открыть каталог по этому жанру/тегу). nil —
        /// чип некликабельный, как раньше.
        var onTap: (() -> Void)? = nil
    }

    let items: [Item]
    var maxCollapsedRows: Int = 2

    /// Старый вызов CollapsibleChips(items: [String]) продолжает работать
    /// без изменений на остальных экранах — просто оборачивает строки в
    /// Item с tint = nil (обычная раскраска).
    init(items: [String], maxCollapsedRows: Int = 2) {
        self.items = items.map { Item(text: $0) }
        self.maxCollapsedRows = maxCollapsedRows
    }

    init(items: [Item], maxCollapsedRows: Int = 2) {
        self.items = items
        self.maxCollapsedRows = maxCollapsedRows
    }

    @State private var expanded = false
    @State private var totalHeight: CGFloat = 0

    private struct Chip: Identifiable { let id: Int; let text: String; let toggle: Bool; let tint: Color?; let onTap: (() -> Void)? }

    private static let font = UIFont.preferredFont(forTextStyle: .caption1)
    // Горизонтальный паддинг чипа (12+12) + зазор до следующего (8) — те же
    // числа, что в chipView/generate ниже.
    private static let chipHorizontalOverhead: CGFloat = 12 + 12 + 8

    private static func chipWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width + chipHorizontalOverhead
    }

    /// Считает, сколько элементов из items реально помещается в первые
    /// maxCollapsedRows строк при данной ширине контейнера — включая место
    /// под чип "+ещё N" в последней из этих строк (если что-то остаётся
    /// скрытым). Чистый расчёт по ширине текста, без лишнего GeometryReader
    /// на этапе рендера — тот же принцип "не измерять точную геометрию
    /// вручную", что и в MangaCardView (см. комментарий там).
    private func collapsedVisibleCount(for width: CGFloat) -> Int {
        guard width > 0, !items.isEmpty else { return items.count }
        var x: CGFloat = 0
        var row = 0
        var count = 0
        for item in items {
            let w = Self.chipWidth(item.text)
            if x + w > width {
                row += 1
                x = 0
                if row >= maxCollapsedRows { break }
            }
            x += w
            count += 1
        }
        // Если что-то осталось за кадром — надо, чтобы чип "+ещё N" тоже
        // влез в последнюю разрешённую строку; если не влезает — убираем
        // один обычный чип, освобождая место.
        if count < items.count {
            let hidden = items.count - count
            let toggleWidth = Self.chipWidth("+еще \(hidden)")
            if x + toggleWidth > width, count > 0 {
                count -= 1
            }
        }
        return count
    }

    private func chips(collapsedVisible: Int) -> [Chip] {
        let visible = expanded ? items : Array(items.prefix(collapsedVisible))
        var result = visible.enumerated().map { Chip(id: $0.offset, text: $0.element.text, toggle: false, tint: $0.element.tint, onTap: $0.element.onTap) }
        let hidden = items.count - visible.count
        if !expanded && hidden > 0 {
            result.append(Chip(id: -1, text: "+еще \(hidden)", toggle: true, tint: nil, onTap: nil))
        } else if expanded && items.count > collapsedVisible {
            result.append(Chip(id: -2, text: "свернуть", toggle: true, tint: nil, onTap: nil))
        }
        return result
    }

    var body: some View {
        GeometryReader { geo in
            generate(in: geo)
        }
        .frame(height: totalHeight)
        .animation(.easeInOut(duration: 0.2), value: expanded)
    }

    private func generate(in geo: GeometryProxy) -> some View {
        var x = CGFloat.zero
        var y = CGFloat.zero
        let list = chips(collapsedVisible: collapsedVisibleCount(for: geo.size.width))

        return ZStack(alignment: .topLeading) {
            ForEach(list) { chip in
                chipView(chip)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .alignmentGuide(.leading) { d in
                        if abs(x - d.width) > geo.size.width {
                            x = 0
                            y -= d.height
                        }
                        let result = x
                        if chip.id == list.last?.id { x = 0 } else { x -= d.width }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = y
                        if chip.id == list.last?.id { y = 0 }
                        return result
                    }
            }
        }
        .background(heightReader($totalHeight))
    }

    private func chipView(_ chip: Chip) -> some View {
        // tint (возрастной рейтинг 18+/16+) имеет приоритет над обычной/toggle
        // раскраской — красный/оранжевый текст и обводка вместо нейтральной.
        let color = chip.tint ?? (chip.toggle ? Theme.accent : nil)
        let content = Text(chip.text)
            .font(.caption)
            .fontWeight(chip.tint != nil ? .bold : .regular)
            .foregroundStyle(color ?? Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(chip.tint != nil ? AnyShapeStyle((chip.tint ?? .clear).opacity(0.14)) : (chip.toggle ? AnyShapeStyle(Theme.accent.opacity(0.14)) : AnyShapeStyle(Theme.surfaceElevated)), in: Capsule())
            .overlay(Capsule().stroke(color?.opacity(0.6) ?? Theme.separator, lineWidth: chip.tint != nil ? 1.5 : 1))

        return Group {
            if chip.toggle {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: { content }
                .buttonStyle(.plain)
            } else if let onTap = chip.onTap {
                Button(action: onTap) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
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
        VStack(alignment: .leading) {
            CollapsibleChips(items: (1...30).map { "Тег номер \($0)" })
        }
        .padding()
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}

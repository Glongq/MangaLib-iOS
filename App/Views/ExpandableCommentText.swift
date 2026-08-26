import SwiftUI

/// Текст комментария, ограниченный 5 строками — если реально не помещается,
/// последняя видимая строка уходит в лёгкое затемнение (градиент-маска, а не
/// обрезка "впритык"), и снизу появляется "Показать полностью" (после
/// разворота — "Свернуть"), НАД рядом "Ответить"/"Жалоба"/голоса (см.
/// MangaDetailView.commentRow). Тот же приём измерения высоты через
/// невидимый background(GeometryReader), что и ExpandableDescription —
/// отдельный компонент, а не переиспользование той же вью, т.к. у комментария
/// другой лимит строк, другой цвет текста/кнопки и градиент-маска, которых у
/// описания тайтла нет.
struct ExpandableCommentText: View {
    let text: String
    var collapsedLines: Int = 5

    @State private var expanded = false
    @State private var truncatedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var needsToggle: Bool { fullHeight > truncatedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            textView
                .lineLimit(expanded ? nil : collapsedLines)
                .mask(alignment: .top) { fadeMask }
                .background(measurement)

            if needsToggle {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "Свернуть" : "Показать полностью")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var textView: some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.textPrimary)
    }

    /// Пока свёрнуто и реально обрезано — последняя видимая строка уходит в
    /// затемнение (плавный градиент вместо жёсткого обреза); развёрнуто или
    /// текст и так помещается целиком — маска сплошная, никакого эффекта.
    @ViewBuilder
    private var fadeMask: some View {
        if !expanded && needsToggle {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.82),
                    .init(color: .black.opacity(0.35), location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
        } else {
            Color.black
        }
    }

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

/// Тело комментария: если есть хотя бы один спойлер (см. Comment.segments) —
/// обычный текст + чипы-спойлеры друг под другом (тап по чипу раскрывает
/// его СВОЙ, независимо от остальных), без 5-строчного лимита/затемнения
/// (сочетать оба сразу — отдельная задача, спойлеры на практике редки). Без
/// спойлеров — прежнее поведение целиком (ExpandableCommentText: 5 строк,
/// затемнение, "Показать полностью").
struct CommentBodyView: View {
    let comment: Comment

    var body: some View {
        let segments = comment.segments
        if segments.contains(where: { if case .spoiler = $0 { return true } else { return false } }) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let s):
                        Text(s).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    case .spoiler(let label, let text):
                        SpoilerSegmentView(label: label, text: text)
                    }
                }
            }
        } else if !comment.text.isEmpty {
            ExpandableCommentText(text: comment.text)
        }
    }
}

/// Один спойлер внутри комментария — пунктирная рамка с подписью автора
/// (`data-spoiler-text`, см. Comment.segments), тап раскрывает скрытый текст
/// на месте. Своё состояние — раскрытие одного спойлера не трогает соседние.
private struct SpoilerSegmentView: View {
    let label: String
    let text: String

    @State private var revealed = false

    var body: some View {
        if revealed {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { revealed = true }
            } label: {
                Text(label.isEmpty ? "Спойлер" : label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            ExpandableCommentText(text: String(repeating: "Очень длинный комментарий. ", count: 20))
            ExpandableCommentText(text: "Короткий комментарий в одну строку.")
        }
        .padding()
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}

import SwiftUI
import UIKit

/// Sheet настроек комментариев (открывается кнопкой "Настройки" над полем
/// ввода, см. MangaDetailView.commentsHeader):
///   - "Отключить комментарии в читалке" — ПОКА ЗАГЛУШКА (см. поле ниже) —
///     переключатель есть и сохраняется, но реально ни на что не влияет,
///     т.к. комментариев в самой читалке в этом раунде ещё нет.
///   - "Сворачивать вложенные комментарии с уровня N" — слайдер 1...10, над
///     ним живая подпись "с N ур." (обновляется по ходу перетаскивания),
///     плюс короткая вибрация на каждый шаг (см. .onChange ниже).
struct CommentSettingsSheet: View {
    @Binding var disabledInReader: Bool
    @Binding var collapseFromLevel: Double

    @Environment(\.dismiss) private var dismiss

    private let levelRange: ClosedRange<Double> = 1...10
    /// Один и тот же генератор на весь sheet — .prepare() держит "прогретым",
    /// чтобы вибрация срабатывала сразу без задержки на каждом шаге слайдера.
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $disabledInReader) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Отключить комментарии в читалке")
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Пока не реализовано — переключатель ни на что не влияет")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .tint(Theme.accent)
                    }
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Сворачивать вложенные комментарии с уровня")
                            .foregroundStyle(Theme.textPrimary)

                        // Живая подпись над слайдером — меняется сразу по
                        // ходу перетаскивания (не только по отпусканию),
                        // как явно попросили.
                        Text("с \(Int(collapseFromLevel)) ур.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)

                        Slider(value: $collapseFromLevel, in: levelRange, step: 1)
                            .tint(Theme.accent)
                            // Короткая вибрация РОВНО РАЗ на каждый шаг —
                            // step:1 у Slider выше уже гарантирует, что
                            // collapseFromLevel меняется только целыми
                            // шагами, поэтому одного .onChange достаточно
                            // (никакой доп. защиты от "дребезга" не нужно).
                            .onChange(of: collapseFromLevel) { _, _ in
                                haptic.impactOccurred()
                            }
                            .onAppear { haptic.prepare() }

                        HStack {
                            Text("1").font(.caption2).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text("10 (максимум)").font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .navigationTitle("Настройки комментариев")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .tint(Theme.accent)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.accent)
    }
}

#Preview {
    CommentSettingsSheet(disabledInReader: .constant(false), collapseFromLevel: .constant(3))
        .preferredColorScheme(.dark)
}

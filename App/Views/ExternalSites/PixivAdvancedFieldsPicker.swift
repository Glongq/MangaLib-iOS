import SwiftUI

/// Pixiv's "Search options" screen, 1-to-1 with the real app (see
/// PixivAdvancedQuery for which fields are confirmed by HAR). Left out on
/// purpose, all because nothing in the Sep 16 capture ever exercised them:
/// Likes/Bookmarked works/Bookmark date (Premium-only account state, no
/// confirmed query params), Resolution's named presets and Aspect ratio
/// (only raw width/height min/max were ever seen, not a separate ratio
/// param), Creation tools and "Other" (never opened in the capture).
struct PixivAdvancedFieldsPicker: View {
    @Binding var query: PixivAdvancedQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            picker("Targets", selection: $query.searchTarget)
            picker("Type of Work", selection: $query.contentType)
            picker("AI-generated work", selection: $query.aiFilter)
            picker("Sort", selection: $query.sort)
            dateRangeSection
            resolutionSection
        }
    }

    private func picker<T: CaseIterable & Identifiable & Hashable & RawRepresentable>(_ title: String, selection: Binding<T>) -> some View where T.AllCases: RandomAccessCollection, T.RawValue == String {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            Menu {
                ForEach(Array(T.allCases)) { option in
                    Button {
                        selection.wrappedValue = option
                    } label: {
                        let label = (option as? PixivDisplayNameProviding)?.displayName ?? option.rawValue
                        if option == selection.wrappedValue {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            } label: {
                HStack {
                    Text((selection.wrappedValue as? PixivDisplayNameProviding)?.displayName ?? selection.wrappedValue.rawValue)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var dateRangeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Posting date").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                dateField("От", date: $query.startDate)
                dateField("До", date: $query.endDate)
            }
        }
    }

    private func dateField(_ title: String, date: Binding<Date?>) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { date.wrappedValue != nil },
                set: { isOn in date.wrappedValue = isOn ? Date() : nil }
            )) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
            if let value = date.wrappedValue {
                DatePicker(title, selection: Binding(get: { value }, set: { date.wrappedValue = $0 }), displayedComponents: .date)
                    .labelsHidden()
                    .tint(Theme.accent)
            } else {
                Text(title).font(.footnote).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var resolutionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resolution (px)").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                numberField("Width min", value: $query.widthMin)
                numberField("Width max", value: $query.widthMax)
            }
            HStack(spacing: 8) {
                numberField("Height min", value: $query.heightMin)
                numberField("Height max", value: $query.heightMax)
            }
        }
    }

    private func numberField(_ placeholder: String, value: Binding<Int?>) -> some View {
        TextField(placeholder, text: Binding(
            get: { value.wrappedValue.map(String.init) ?? "" },
            set: { value.wrappedValue = Int($0.filter(\.isNumber)) }
        ))
        .keyboardType(.numberPad)
        .textFieldStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// So the generic `picker(_:selection:)` above can show a friendly label
/// instead of the raw API value (e.g. "date_desc") — every enum it's used
/// with (PixivContentType/PixivSearchTarget/PixivSort/PixivAiFilter)
/// already has this exact property; this just lets one generic helper see
/// it without hard-coding all four types by name.
private protocol PixivDisplayNameProviding {
    var displayName: String { get }
}
extension PixivContentType: PixivDisplayNameProviding {}
extension PixivSearchTarget: PixivDisplayNameProviding {}
extension PixivSort: PixivDisplayNameProviding {}
extension PixivAiFilter: PixivDisplayNameProviding {}

#Preview {
    PixivAdvancedFieldsPicker(query: .constant(PixivAdvancedQuery()))
        .padding(16)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}

import SwiftUI

/// Keep editable values in the same leading, full-width layout as instructions.
/// A hidden native label avoids the trailing value column used by macOS Form.
struct LocusFormField<Content: View>: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.locus(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            content
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .font(.locus(size: 11))
                .foregroundStyle(viewColors.inkSoft)
                .tint(viewColors.signalDeep)
                .padding(11)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .background(viewColors.surfaceCard, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LocusFormTextField: View {
    private let title: String
    private let input: AnyView

    init(_ title: String, text: Binding<String>, prompt: Text? = nil, axis: Axis = .horizontal) {
        self.title = title
        input = AnyView(TextField("", text: text, prompt: prompt ?? Text(title), axis: axis))
    }

    init<F: ParseableFormatStyle>(_ title: String, value: Binding<F.FormatInput>, format: F)
    where F.FormatOutput == String {
        self.title = title
        input = AnyView(TextField("", value: value, format: format, prompt: Text(title)))
    }

    init<F: ParseableFormatStyle>(_ title: String, value: Binding<F.FormatInput?>, format: F)
    where F.FormatOutput == String {
        self.title = title
        input = AnyView(TextField("", value: value, format: format, prompt: Text(title)))
    }

    var body: some View {
        LocusFormField(title: title) { input }
    }
}

struct LocusFormSecureField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    var body: some View {
        LocusFormField(title: title) {
            SecureField("", text: $text, prompt: Text(title))
        }
    }
}

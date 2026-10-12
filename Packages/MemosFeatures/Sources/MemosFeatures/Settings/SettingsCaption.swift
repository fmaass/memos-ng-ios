import SwiftUI

/// The line under a section heading that says what the controls below it will do. Footnote weight
/// and secondary, because it is the explanation and never the control.
struct SettingsCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

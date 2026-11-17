import SwiftUI

/// The pieces of the Settings page. They keep the names of SwiftUI's Form and Section on purpose: a grouped Form on
/// macOS keeps its own narrow, centred column, so the cards would not line up with the header and the other screens.

/// A scrolling column of cards, as wide as the screens around it.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.section + 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.page).padding(.top, DS.Space.tight).padding(.bottom, DS.Space.pageBottom)
        }
    }
}

/// A title, a card holding the rows, and an optional note under it.
struct SettingsSection<Content: View, Header: View, Footer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var header: Header
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: DS.Space.item) { content }
                .padding(DS.Space.card)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            footer.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }
}

extension SettingsSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) { self.init(content: content, header: { EmptyView() }, footer: { EmptyView() }) }
}

extension SettingsSection where Header == Text, Footer == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

extension SettingsSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension SettingsSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

/// Label on the left, switch on the right, as in the rest of the Settings cards.
struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: configuration.$isOn) { EmptyView() }
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

import SwiftUI
import TidyCore

/// Design tokens and small reusable pieces for the main window. Everything here follows the system appearance
/// (Auto / Light / Dark): a calm neutral surface, one accent colour, and cards with a hairline edge.
extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    /// A colour that switches with the appearance of the view that shows it.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

enum DS {
    // Surfaces
    static let window = Color.adaptive(light: NSColor(hex: 0xEFEEEB), dark: NSColor(hex: 0x1C1C1E))
    static let sidebar = Color.adaptive(light: NSColor(hex: 0xE6E5E1), dark: NSColor(hex: 0x242427))
    static let card = Color.adaptive(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0xFFFFFF, alpha: 0.06))
    static let cardHover = Color.adaptive(light: NSColor(hex: 0xF9F8F6), dark: NSColor(hex: 0xFFFFFF, alpha: 0.10))
    static let border = Color.adaptive(light: NSColor(hex: 0x000000, alpha: 0.11), dark: NSColor(hex: 0xFFFFFF, alpha: 0.10))
    static let selection = Color.adaptive(light: NSColor(hex: 0x000000, alpha: 0.075), dark: NSColor(hex: 0xFFFFFF, alpha: 0.10))
    static let track = Color.adaptive(light: NSColor(hex: 0x000000, alpha: 0.08), dark: NSColor(hex: 0xFFFFFF, alpha: 0.10))

    // Colour
    static let accent = Color.adaptive(light: NSColor(hex: 0x2F7BF0), dark: NSColor(hex: 0x5AA0FF))
    static let safe = Color.adaptive(light: NSColor(hex: 0x1F8A4C), dark: NSColor(hex: 0x58D68D))
    static let caution = Color.adaptive(light: NSColor(hex: 0xB8610B), dark: NSColor(hex: 0xFFB454))

    /// The filled action button: ink on light, paper on dark.
    static let ink = Color.adaptive(light: NSColor(hex: 0x2B2B2D), dark: NSColor(hex: 0xF2F2F4))
    static let inkText = Color.adaptive(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x1C1C1E))

    /// Neutral tone for glyphs and icon chips: the interface stays grey, colour is kept for status (safe / caution / danger).
    static let glyph = Color.adaptive(light: NSColor(hex: 0x5E5E63), dark: NSColor(hex: 0xB6B6BC))
    static let danger = Color.adaptive(light: NSColor(hex: 0xC0392B), dark: NSColor(hex: 0xFF7A6B))

    static let radius: CGFloat = 14

    /// One spacing scale for every screen, so pages line up with each other.
    enum Space {
        /// Left and right margin of every page.
        static let page: CGFloat = 32
        /// Gap above a screen header, and below it.
        static let headerTop: CGFloat = 34
        static let headerBottom: CGFloat = 22
        /// Bottom margin of a scrolling page.
        static let pageBottom: CGFloat = 32
        /// Gap between the cards / blocks of a page.
        static let section: CGFloat = 20
        /// Inner padding of a card, and of one row inside a card.
        static let card: CGFloat = 20
        static let rowH: CGFloat = 16
        static let rowV: CGFloat = 13
        /// Small gaps between related items.
        static let tight: CGFloat = 10
        static let item: CGFloat = 14
    }
}

// MARK: - Card

struct CardBackground: ViewModifier {
    var radius: CGFloat = DS.radius
    var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hovering ? DS.cardHover : DS.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

extension Module {
    /// The module's colour, as on a System Settings icon: one flat, saturated hue per area, used only on its icon badge.
    var tint: Color {
        func c(_ light: UInt32, _ dark: UInt32) -> Color { .adaptive(light: NSColor(hex: light), dark: NSColor(hex: dark)) }
        switch self {
        case .smartCare: return c(0x3478F6, 0x4C8DFF)
        case .cleanup: return c(0x2FB457, 0x34C759)
        case .clutter: return c(0x1FA2B8, 0x30B8D0)
        case .applications: return c(0x5856D6, 0x6E6CE8)
        case .protection: return c(0xE5484D, 0xF2555A)
        case .performance: return c(0xF08A00, 0xFF9F0A)
        case .spaceLens: return c(0x9B51D8, 0xB066E8)
        case .myTools: return c(0x7C7C82, 0x8E8E93)
        case .activity: return c(0xE0527E, 0xF0638F)
        }
    }
}

extension View {
    /// Margins of a screen header: the same on every screen.
    func headerPadding() -> some View {
        padding(.horizontal, DS.Space.page).padding(.top, DS.Space.headerTop).padding(.bottom, DS.Space.headerBottom)
    }

    /// Margins of a screen's scrolling content: the same on every screen.
    func pagePadding() -> some View {
        padding(.horizontal, DS.Space.page).padding(.bottom, DS.Space.pageBottom)
    }

    func card(radius: CGFloat = DS.radius, hovering: Bool = false) -> some View {
        modifier(CardBackground(radius: radius, hovering: hovering))
    }
}

// MARK: - Buttons

/// The one filled action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.inkText)
            .padding(.horizontal, 16).frame(height: 32)
            .background(Capsule().fill(DS.ink.opacity(configuration.isPressed ? 0.78 : 1)))
            .opacity(enabled ? 1 : 0.35)
            .animation(Motion.animation(.easeOut(duration: 0.12)), value: configuration.isPressed)
    }
}

/// Outlined, for everything that is not the main action.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14).frame(height: 32)
            .background(Capsule().fill(configuration.isPressed ? DS.selection : hover ? DS.cardHover : DS.card))
            .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
            .onHover { hover = $0 && enabled }
            .animation(Motion.animation(.easeOut(duration: 0.12)), value: hover)
    }
}

// MARK: - Pieces

/// Title block at the top of a screen, with the screen's actions on the right.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 24, weight: .semibold)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { trailing }
        }
    }
}

/// A coloured rounded square with a white symbol, like the icons in System Settings. Used to mark where something lives
/// (sidebar, areas, tools, groups): never to decorate plain data rows.
struct IconChip: View {
    let symbol: String
    var tint: Color = DS.glyph
    var size: CGFloat = 36
    var dimmed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.86)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            .opacity(dimmed ? 0.5 : 1)
    }
}

/// "Recommended" / "Check First" tag on a result row.
struct StatusBadge: View {
    enum Kind { case safe, check }
    let kind: Kind

    var body: some View {
        let color = kind == .safe ? DS.safe : DS.caution
        Text(kind == .safe ? String(localized: "Recommended") : String(localized: "Check First"))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.13)))
            .fixedSize()
    }
}

/// Tab-like filter with a count.
struct FilterChip: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                Text("\(count)").font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(selected ? DS.cardHover : hover ? DS.selection.opacity(0.6) : Color.clear))
            .overlay(Capsule().strokeBorder(selected ? DS.border : Color.clear, lineWidth: 1))
            .shadow(color: .black.opacity(selected ? 0.05 : 0), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.animation(.easeOut(duration: 0.12)), value: selected)
    }
}

/// Round-cornered checkbox, drawn by hand so rows look the same in every appearance.
struct CheckBox: View {
    let state: Bool?   // true = on, false = off, nil = mixed
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(state == false ? Color.clear : DS.accent)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(state == false ? Color.secondary.opacity(0.5) : DS.accent, lineWidth: 1.2)
                if state != false {
                    Image(systemName: state == nil ? "minus" : "checkmark")
                        .font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.white)
                }
            }
            .frame(width: 17, height: 17)
            .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
    }
}

/// A horizontal bar made of coloured shares of a whole.
struct UsageBar: View {
    struct Segment: Identifiable { let id = UUID(); let fraction: Double; let color: Color }
    let segments: [Segment]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments) { s in
                    Capsule().fill(s.color)
                        .frame(width: max(0, (geo.size.width - CGFloat(max(segments.count - 1, 0)) * 2) * s.fraction))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Capsule().fill(DS.track))
        .clipShape(Capsule())
    }
}

/// Explains what a missing permission costs, with one action. Replaces the old floating pill.
struct InfoBanner: View {
    var message: String
    var symbol = "lock.shield.fill"
    var tint: Color = DS.caution
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconChip(symbol: symbol, tint: tint, size: 32)
            Text(message).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(actionTitle, action: action).buttonStyle(SecondaryButtonStyle())
        }
        .padding(DS.Space.item)
        .card()
    }
}

/// Centred empty state: an icon on a soft halo, a title, a sentence, the one action, and room for extra content below.
struct EmptyState<Extra: View>: View {
    let symbol: String
    var tint: Color = DS.glyph
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var primary = true
    var action: () -> Void = {}
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(spacing: 0) {
            IconChip(symbol: symbol, tint: tint, size: 56).padding(.bottom, 16)
            Text(title).font(.system(size: 19, weight: .semibold)).multilineTextAlignment(.center)
            if let message {
                Text(message).font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .lineSpacing(2).frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            if let actionTitle {
                Group {
                    if primary {
                        Button(actionTitle, action: action).buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button(actionTitle, action: action).buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.top, 22)
            }
            extra.padding(.top, 26)
        }
        .frame(maxWidth: .infinity)
    }
}

extension EmptyState where Extra == EmptyView {
    init(symbol: String, tint: Color = DS.glyph, title: String, message: String? = nil, actionTitle: String? = nil,
         primary: Bool = true, action: @escaping () -> Void = {}) {
        self.init(symbol: symbol, tint: tint, title: title, message: message, actionTitle: actionTitle, primary: primary, action: action) { EmptyView() }
    }
}

/// What a module looks at, as small pills under an empty state.
struct FeaturePills: View {
    let features: [(String, String)]
    var tint: Color = DS.glyph

    var body: some View {
        HStack(spacing: 8) {
            ForEach(features, id: \.1) { f in
                HStack(spacing: 6) {
                    Image(systemName: f.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                    Text(f.1).font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(DS.card))
                .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
            }
        }
    }
}

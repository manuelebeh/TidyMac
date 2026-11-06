import SwiftUI
import TidyCore

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Sidebar modules, in display order, with each module's palette.
enum Module: String, CaseIterable, Identifiable {
    case smartCare, cleanup, protection, performance, applications, clutter, spaceLens, myTools, activity
    var id: String { rawValue }

    var name: String {
        switch self {
        case .smartCare: String(localized: "Full Scan")
        case .cleanup: String(localized: "Cleanup")
        case .protection: String(localized: "Protection")
        case .performance: String(localized: "Performance")
        case .applications: String(localized: "Applications")
        case .clutter: String(localized: "Declutter")
        case .spaceLens: String(localized: "Storage Map")
        case .myTools: String(localized: "Toolkit")
        case .activity: String(localized: "History")
        }
    }

    var headline: String { self == .cleanup ? String(localized: "Junk Cleanup") : name }

    var tagline: String {
        switch self {
        case .smartCare: String(localized: "Quick maintenance that takes care of the essentials.")
        case .cleanup: String(localized: "Clean your system to achieve maximum performance and reclaim more free space.")
        case .protection: String(localized: "Check your Mac for all kind of threats and vulnerabilities.")
        case .performance: String(localized: "Keep your Mac in top shape with recommended maintenance.")
        case .applications: String(localized: "Take control of your applications. Uninstall, update or remove old application leftovers.")
        case .clutter: String(localized: "Sort through your files and reduce the mess in just a few clicks.")
        case .spaceLens: String(localized: "Visualize what's taking up the most disk space and clean up your storage quickly.")
        case .myTools: String(localized: "Quick tools for focused tasks — clean up, protect, and maintain your Mac in just a few clicks.")
        case .activity: String(localized: "See how much space TidyMac has freed and how your disk is used.")
        }
    }

    var features: [(String, String)] {
        switch self {
        case .smartCare: [("magnifyingglass", String(localized: "Quick Scan")), ("gearshape.fill", String(localized: "System Tune-up")), ("checkmark.shield.fill", String(localized: "Security Check"))]
        case .cleanup: [("archivebox.fill", String(localized: "System Junk")), ("sparkles", String(localized: "AI Clutter")), ("paperclip", String(localized: "Mail Attachments")), ("trash.fill", String(localized: "Trash Bins"))]
        case .protection: [("ladybug.fill", String(localized: "Malware Removal")), ("hand.raised.fill", String(localized: "Privacy Check")), ("lock.shield.fill", String(localized: "Application Permissions"))]
        case .performance: [("wrench.and.screwdriver.fill", String(localized: "Maintenance Tasks")), ("person.badge.clock.fill", String(localized: "Login Items")), ("gearshape.2.fill", String(localized: "Background Items"))]
        case .applications: [("xmark.app.fill", String(localized: "App Uninstaller")), ("arrow.up.circle.fill", String(localized: "App Updater")), ("shippingbox.fill", String(localized: "File Leftovers"))]
        case .clutter: [("doc.fill", String(localized: "Large Files")), ("doc.on.doc.fill", String(localized: "Duplicates")), ("photo.on.rectangle", String(localized: "Similar Images")), ("arrow.down.circle.fill", String(localized: "Downloads"))]
        case .spaceLens: [("circle.hexagongrid.fill", String(localized: "Visual Storage Map")), ("eye.fill", String(localized: "Hidden Files Uncovered")), ("folder.fill", String(localized: "Large Folders Overview"))]
        case .myTools: []
        case .activity: [("chart.bar.fill", String(localized: "Space Freed")), ("internaldrive.fill", String(localized: "Disk Usage"))]
        }
    }

    var symbol: String {
        switch self {
        case .smartCare: "desktopcomputer"
        case .cleanup: "circle.circle.fill"
        case .protection: "hand.raised.fill"
        case .performance: "bolt.fill"
        case .applications: "xmark"
        case .clutter: "folder.fill"
        case .spaceLens: "circle.dashed"
        case .myTools: "square.grid.2x2.fill"
        case .activity: "chart.xyaxis.line"
        }
    }

    /// Shape of the large glass icon on the intro screen.
    var iconShape: GlassShape.Kind {
        switch self {
        case .cleanup: .circle
        case .protection: .polygon(8)
        case .performance: .polygon(5)
        case .applications: .polygon(6)
        case .clutter: .clover
        default: .squircle
        }
    }

    var dark: Color {
        switch self {
        case .smartCare: Color(hex: 0x260C55)
        case .cleanup: Color(hex: 0x0C2318)
        case .protection: Color(hex: 0x521349)
        case .performance: Color(hex: 0x3A1305)
        case .applications: Color(hex: 0x1A1A5A)
        case .clutter: Color(hex: 0x0B2D33)
        case .spaceLens: Color(hex: 0x190A52)
        case .myTools: Color(hex: 0x1E1530)
        case .activity: Color(hex: 0x111C2B)
        }
    }

    var light: Color {
        switch self {
        case .smartCare: Color(hex: 0x8E1FA2)
        case .cleanup: Color(hex: 0x3F812D)
        case .protection: Color(hex: 0xC33A86)
        case .performance: Color(hex: 0xC4621D)
        case .applications: Color(hex: 0x3D5BD8)
        case .clutter: Color(hex: 0x2E7E78)
        case .spaceLens: Color(hex: 0x5728CC)
        case .myTools: Color(hex: 0x56406F)
        case .activity: Color(hex: 0x305177)
        }
    }

    var accent: Color {
        switch self {
        case .smartCare: Color(hex: 0xE352D3)
        case .cleanup: Color(hex: 0x7BD65C)
        case .protection: Color(hex: 0xFF79BA)
        case .performance: Color(hex: 0xFFAA4E)
        case .applications: Color(hex: 0x72A2FF)
        case .clutter: Color(hex: 0x62D6C8)
        case .spaceLens: Color(hex: 0xA27DFF)
        case .myTools: Color(hex: 0xD58BF0)
        case .activity: Color(hex: 0x7FB2E5)
        }
    }

    var progressTitle: String {
        switch self {
        case .cleanup: String(localized: "Looking for junk...")
        case .protection: String(localized: "Checking for threats...")
        case .performance: String(localized: "Analyzing your Mac...")
        case .applications: String(localized: "Looking at your apps...")
        case .clutter: String(localized: "Sorting through your files...")
        default: String(localized: "Scanning your Mac...")
        }
    }

    var actionTitle: String {
        switch self {
        case .cleanup: String(localized: "Clean")
        case .clutter, .applications, .protection: String(localized: "Remove")
        default: String(localized: "Run")
        }
    }

    func engine(clutterRoot: URL) -> any ScanEngine {
        switch self {
        case .cleanup: CleanupEngine()
        case .protection: ProtectionEngine()
        case .performance: PerformanceEngine()
        case .applications: ApplicationsEngine()
        case .clutter: ClutterEngine(root: clutterRoot)
        default: SmartCareEngine()
        }
    }
}

/// Settings › General › Reduce Motion. Read on every use, so a change applies at the next redraw.
enum Motion {
    static var reduced: Bool { GeneralSettings.reducesMotion(system: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
    /// The animation, or none when motion is reduced.
    static func animation(_ a: Animation) -> Animation? { reduced ? nil : a }
}

/// "Play sounds for main TidyMac actions": a system sound when a scan or a cleanup finishes.
enum Sounds {
    static func scanFinished() { play("Tink") }
    static func cleanupFinished() { play("Glass") }
    private static func play(_ name: String) { if GeneralSettings.playsSounds() { NSSound(named: name)?.play() } }
}

struct GlassShape: Shape {
    enum Kind { case circle, squircle, polygon(Int), clover }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .circle: return Circle().path(in: rect)
        case .squircle: return RoundedRectangle(cornerRadius: rect.width * 0.26, style: .continuous).path(in: rect)
        case .polygon(let n): return Self.roundedPolygon(n, in: rect, corner: rect.width * 0.12)
        case .clover:
            // Four overlapping rounded lobes.
            var p = Path()
            let s = rect.width * 0.62
            for (dx, dy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                p.addRoundedRect(in: CGRect(x: rect.minX + dx * (rect.width - s), y: rect.minY + dy * (rect.height - s), width: s, height: s),
                                 cornerSize: CGSize(width: s * 0.42, height: s * 0.42), style: .continuous)
            }
            p.addRect(rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.18))
            return p
        }
    }

    static func roundedPolygon(_ n: Int, in rect: CGRect, corner: CGFloat) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2
        let rotation = n % 2 == 0 ? Double.pi / Double(n) : -Double.pi / 2
        let pts = (0..<n).map { i -> CGPoint in
            let a = rotation + Double(i) * 2 * .pi / Double(n)
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        func lerp(_ a: CGPoint, _ b: CGPoint, _ d: CGFloat) -> CGPoint {
            let len = hypot(b.x - a.x, b.y - a.y), t = min(d / len, 0.5)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        var p = Path()
        for i in 0..<n {
            let prev = pts[(i + n - 1) % n], cur = pts[i], next = pts[(i + 1) % n]
            let a = lerp(cur, prev, corner), b = lerp(cur, next, corner)
            i == 0 ? p.move(to: a) : p.addLine(to: a)
            p.addQuadCurve(to: b, control: cur)
        }
        p.closeSubpath()
        return p
    }
}

/// A loop driven by the clock instead of a repeating `withAnimation`. A repeating animation started in `onAppear`
/// also animates every layout change in the same transaction, forever: the sidebar rows then drift up and down.
/// `content` receives a wave that goes 0 → 1 → 0 once per `period`, and the raw phase (0..<1).
struct Cycle<Content: View>: View {
    var period: Double
    var paused = false
    @ViewBuilder let content: (_ wave: Double, _ phase: Double) -> Content

    var body: some View {
        TimelineView(.animation(paused: paused || Motion.reduced)) { timeline in
            let phase = Motion.reduced ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            content((1 - cos(2 * .pi * phase)) / 2, phase)
        }
    }
}

/// The large translucent "glass" emblem shown on module screens.
struct GlassIcon: View {
    let module: Module
    var size: CGFloat = 290
    var pulsing = false

    var body: some View {
        // At rest the emblem floats; while scanning it breathes.
        Cycle(period: pulsing ? 2 : 6) { wave, _ in
            emblem
                .background(
                    // A halo in the module's button colours, brighter while scanning.
                    AuroraDisc(colors: module.aurora, speed: pulsing ? 1 : 0.3)
                        .frame(width: size * 1.25, height: size * 1.25)
                        .blur(radius: size * 0.16)
                        .opacity(pulsing ? 0.4 + 0.35 * wave : 0.35)
                )
                .scaleEffect(pulsing ? 1 + 0.04 * wave : 1)
                .offset(y: pulsing ? 0 : -6 * wave)
        }
    }

    var emblem: some View {
        let shape = GlassShape(kind: module.iconShape)
        return ZStack {
            shape.fill(LinearGradient(colors: [module.accent.opacity(0.95), module.light.opacity(0.85), module.dark.opacity(0.9)],
                                      startPoint: .top, endPoint: .bottom))
                .offset(y: size * 0.05)
                .opacity(0.55)
                .blur(radius: 1)
            shape.fill(LinearGradient(colors: [module.accent.opacity(0.85), module.light.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.0)], startPoint: .top, endPoint: .center))
                .padding(size * 0.04)
            shape.stroke(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.1), .white.opacity(0.4)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.5)
            Image(systemName: module.symbol)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .shadow(color: module.dark.opacity(0.6), radius: 8, y: 6)
        }
        .frame(width: size, height: size)
        .rotation3DEffect(.degrees(12), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .shadow(color: module.dark.opacity(0.7), radius: 30, y: 25)
    }
}

/// The round button pinned to the bottom centre (Scan / Stop / Run / Clean): a colour disc with a white rim and a glow
/// that rises above it. While `busy`, a ring turns around it and the disc breathes.
struct ScanButton: View {
    let title: String
    let module: Module
    var subtitle: String? = nil
    var busy = false
    var dimmed = false
    let action: () -> Void
    @State private var hover = false
    private let size: CGFloat = 96

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Cycle(period: busy ? 1.1 : 2.4, paused: !busy) { wave, phase in
                    ZStack {
                        // A soft halo all around the button, a little brighter above it.
                        AuroraDisc(colors: module.aurora, speed: busy ? 1.2 : 0.5)
                            .frame(width: size * 1.7, height: size * 1.7)
                            .blur(radius: 28)
                            .padding(size * 0.5)
                            .offset(y: -size * 0.06)
                            .opacity(dimmed ? 0.15 : hover ? 0.9 : 0.65)
                            .allowsHitTesting(false)
                        AuroraDisc(colors: module.aurora, speed: busy ? 1.2 : 0.5)
                            .frame(width: size, height: size)
                            .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center)))
                            .scaleEffect(busy ? 1 + 0.04 * wave : 1)
                        Circle().strokeBorder(.white.opacity(hover ? 1 : 0.9), lineWidth: 2.5)
                            .frame(width: size, height: size)
                        if busy {
                            Circle().trim(from: 0, to: 0.28)
                                .stroke(AngularGradient(colors: [.white.opacity(0), .white], center: .center,
                                                        startAngle: .degrees(0), endAngle: .degrees(100)),
                                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .frame(width: size + 14, height: size + 14)
                                .rotationEffect(.degrees(phase * 360))
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                        // The size to free sits in the disc, under the title: below it would hang outside the window.
                        VStack(spacing: 1) {
                            Text(title)
                                .font(.system(size: 17, weight: .regular))
                                .id(title)
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                            if let subtitle {
                                Text(subtitle).font(.system(size: 11, weight: .medium)).opacity(0.85)
                                    .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: size - 16)
                                    .contentTransition(.numericText())
                                    .transition(.opacity)
                            }
                        }
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    }
                }
                .frame(width: size + 20, height: size + 20)
                .contentShape(Circle())
            }
            .buttonStyle(AuroraPressStyle(hover: hover))
            .onHover { hover = $0 }
            .opacity(dimmed ? 0.55 : 1)
        }
        .animation(Motion.animation(.spring(response: 0.35, dampingFraction: 0.75)), value: hover)
        .animation(Motion.animation(.spring(response: 0.45, dampingFraction: 0.8)), value: title)
        .animation(Motion.animation(.easeInOut(duration: 0.3)), value: busy)
        .animation(Motion.animation(.easeOut(duration: 0.2)), value: subtitle)
    }
}

/// Grows a little under the pointer and sinks when pressed.
struct AuroraPressStyle: ButtonStyle {
    let hover: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : hover ? 1.04 : 1)
            .animation(Motion.animation(.spring(response: 0.25, dampingFraction: 0.7)), value: configuration.isPressed)
    }
}

struct FeatureRow: View {
    let symbol: String, title: String, module: Module
    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [module.aurora[1], module.aurora[3]], startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
        }
    }
}

/// White on the dark module backgrounds; follows the appearance where it is not forced (the menu bar tray).
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pill(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct Pill<Label: View>: View {
        let label: Label
        let pressed: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(.primary.opacity(pressed ? 0.3 : hover ? 0.22 : 0.16)))
                .overlay(Capsule().strokeBorder(LinearGradient(colors: [.primary.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)))
                .scaleEffect(pressed ? 0.96 : 1)
                .opacity(enabled ? 1 : 0.5)
                .onHover { hover = $0 && enabled }
                .animation(Motion.animation(.easeOut(duration: 0.12)), value: hover)
                .animation(Motion.animation(.spring(response: 0.2, dampingFraction: 0.7)), value: pressed)
        }
    }
}

extension MacHealth.State {
    /// The glow behind the Mac in the menu header.
    var glow: Color {
        switch self {
        case .excellent: Color(hex: 0x85E3F3)
        case .good: Color(hex: 0xA2F6F2)
        case .normal: Color(hex: 0x82FFB4)
        case .requiresAttention: Color(hex: 0xFFEF62)
        case .critical: Color(hex: 0xFFB662)
        }
    }

    /// On the dark module backgrounds; the light-mode tray needs a darker green to stay readable.
    func color(_ scheme: ColorScheme = .dark) -> Color {
        switch self {
        case .excellent, .good: scheme == .dark ? Color(hex: 0x7EE8C8) : Color(hex: 0x1E9E77)
        case .normal: scheme == .dark ? .yellow : Color(hex: 0xB07D00)
        case .requiresAttention: .orange
        case .critical: .red
        }
    }
}

func formatSize(_ b: Int64) -> String { FileSize.format(b) }

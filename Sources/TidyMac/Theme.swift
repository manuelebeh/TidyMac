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


    var tagline: String {
        switch self {
        case .smartCare: String(localized: "Quick maintenance that takes care of the essentials.")
        case .cleanup: String(localized: "Clean your system to achieve maximum performance and reclaim more free space.")
        case .protection: String(localized: "Check your Mac for all kinds of threats and vulnerabilities.")
        case .performance: String(localized: "Keep your Mac in top shape with recommended maintenance.")
        case .applications: String(localized: "Take control of your applications. Uninstall, update or remove old application leftovers.")
        case .clutter: String(localized: "Sort through your files and reduce the mess in just a few clicks.")
        case .spaceLens: String(localized: "Visualize what's taking up the most disk space and clean up your storage quickly.")
        case .myTools: String(localized: "Quick tools for focused tasks - clean up, protect, and maintain your Mac in just a few clicks.")
        case .activity: String(localized: "See how much space and time TidyMac has saved you.")
        }
    }

    /// What Storage Map shows, under its scan button. The other modules list their own tools on their intro instead.
    var features: [(String, String)] {
        guard self == .spaceLens else { return [] }
        return [("circle.hexagongrid.fill", String(localized: "Visual Storage Map")), ("eye.fill", String(localized: "Hidden Files Uncovered")), ("folder.fill", String(localized: "Large Folders Overview"))]
    }

    var symbol: String {
        switch self {
        case .smartCare: "house.fill"
        case .cleanup: "trash.fill"
        case .protection: "shield.lefthalf.filled"
        case .performance: "speedometer"
        case .applications: "macwindow"
        case .clutter: "tray.full.fill"
        case .spaceLens: "circle.hexagongrid.fill"
        case .myTools: "wrench.and.screwdriver.fill"
        case .activity: "clock.arrow.circlepath"
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

import SwiftUI
import TidyCore

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Sidebar modules, in CleanMyMac's order, with the palette sampled from its screenshots.
enum Module: String, CaseIterable, Identifiable {
    case smartCare, cleanup, protection, performance, applications, clutter, spaceLens, myTools, activity
    var id: String { rawValue }

    var name: String {
        switch self {
        case .smartCare: "Smart Care"
        case .cleanup: "Cleanup"
        case .protection: "Protection"
        case .performance: "Performance"
        case .applications: "Applications"
        case .clutter: "My Clutter"
        case .spaceLens: "Space Lens"
        case .myTools: "My Tools"
        case .activity: "My Activity"
        }
    }

    var headline: String { self == .cleanup ? "Junk Cleanup" : name }

    var tagline: String {
        switch self {
        case .smartCare: "Quick maintenance that takes care of the essentials."
        case .cleanup: "Clean your system to achieve maximum performance and reclaim more free space."
        case .protection: "Check your Mac for all kind of threats and vulnerabilities."
        case .performance: "Keep your Mac in top shape with recommended maintenance."
        case .applications: "Take control of your applications. Uninstall, update or remove old application leftovers."
        case .clutter: "Sort through your files and reduce the mess in just a few clicks."
        case .spaceLens: "Visualize what's taking up the most disk space and clean up your storage quickly."
        case .myTools: "Quick tools for focused tasks — clean up, protect, and maintain your Mac in just a few clicks."
        case .activity: "See how much space TidyMac has freed and how your disk is used."
        }
    }

    var features: [(String, String)] {
        switch self {
        case .smartCare: [("magnifyingglass", "Quick Scan"), ("gearshape.fill", "System Tune-up"), ("checkmark.shield.fill", "Security Check")]
        case .cleanup: [("archivebox.fill", "System Junk"), ("sparkles", "AI Clutter"), ("paperclip", "Mail Attachments"), ("trash.fill", "Trash Bins")]
        case .protection: [("ladybug.fill", "Malware Removal"), ("hand.raised.fill", "Privacy Check"), ("lock.shield.fill", "Application Permissions")]
        case .performance: [("wrench.and.screwdriver.fill", "Maintenance Tasks"), ("person.badge.clock.fill", "Login Items"), ("gearshape.2.fill", "Background Items")]
        case .applications: [("xmark.app.fill", "App Uninstaller"), ("arrow.up.circle.fill", "App Updater"), ("shippingbox.fill", "File Leftovers")]
        case .clutter: [("doc.fill", "Large Files"), ("doc.on.doc.fill", "Duplicates"), ("photo.on.rectangle", "Similar Images"), ("arrow.down.circle.fill", "Downloads")]
        case .spaceLens: [("circle.hexagongrid.fill", "Visual Storage Map"), ("eye.fill", "Hidden Files Uncovered"), ("folder.fill", "Large Folders Overview")]
        case .myTools: []
        case .activity: [("chart.bar.fill", "Space Freed"), ("internaldrive.fill", "Disk Usage")]
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
        case .cleanup: "Looking for junk..."
        case .protection: "Checking for threats..."
        case .performance: "Analyzing your Mac..."
        case .applications: "Looking at your apps..."
        case .clutter: "Sorting through your files..."
        default: "Scanning your Mac..."
        }
    }

    var actionTitle: String {
        switch self {
        case .cleanup: "Clean"
        case .clutter, .applications, .protection: "Remove"
        default: "Run"
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

/// Full-window gradient with two soft light blobs, like the module backgrounds.
struct ModuleBackground: View {
    let module: Module
    var body: some View {
        ZStack {
            LinearGradient(colors: [module.dark, module.light], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [module.light.opacity(0.75), .clear], center: .init(x: 0.85, y: 0.15), startRadius: 10, endRadius: 520)
            RadialGradient(colors: [module.dark.opacity(0.9), .clear], center: .init(x: 0.1, y: 0.95), startRadius: 10, endRadius: 600)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: module)
    }
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

/// The large translucent "glass" emblem shown on module screens.
struct GlassIcon: View {
    let module: Module
    var size: CGFloat = 250
    var pulsing = false
    @State private var phase = false

    var body: some View {
        let shape = GlassShape(kind: module.iconShape)
        ZStack {
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
        .scaleEffect(pulsing && phase ? 1.04 : 1)
        .onAppear { if pulsing { withAnimation(.easeInOut(duration: 1).repeatForever()) { phase = true } } }
    }
}

/// The round button pinned to the bottom centre (Scan / Stop / Run / Clean).
struct ScanButton: View {
    let title: String
    let module: Module
    var subtitle: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(
                        Circle().fill(LinearGradient(colors: [module.accent.opacity(0.9), module.light], startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(Circle().stroke(.white.opacity(hover ? 0.9 : 0.6), lineWidth: 2))
                    .shadow(color: module.accent.opacity(0.8), radius: hover ? 28 : 18)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.8)) }
        }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

struct FeatureRow: View {
    let symbol: String, title: String, module: Module
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(module.accent.opacity(0.55)))
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.3 : 0.16)))
    }
}

func formatSize(_ b: Int64) -> String { FileSize.format(b) }

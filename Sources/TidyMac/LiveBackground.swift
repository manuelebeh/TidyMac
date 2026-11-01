import SwiftUI

/// A module's live background: a dark base and three translucent radial gradients that orbit the window centre.
struct LivePalette: Equatable {
    let base: Color
    let blobs: [Color]

    init(base: UInt32, _ blobs: UInt32..., opacity: [Double] = [0.5, 0.5, 0.5]) {
        self.base = Color(hex: base)
        self.blobs = zip(blobs, opacity).map { Color(hex: $0).opacity($1) }
    }

    /// The same palette over a pale base, for the Light Mode menu.
    func light(base: UInt32) -> LivePalette {
        LivePalette(base: Color(hex: base), blobs: blobs.map { $0.opacity(0.45) })
    }

    private init(base: Color, blobs: [Color]) { self.base = base; self.blobs = blobs }
}

extension Module {
    var live: LivePalette {
        switch self {
        case .smartCare: LivePalette(base: 0x090048, 0x4F0038, 0xBA00FC, 0xED00FF)
        case .cleanup: LivePalette(base: 0x002E0A, 0x001C12, 0x009912, 0x85C200)
        case .protection: LivePalette(base: 0x5C0026, 0x4F0038, 0xD400E8, 0xFF54F7)
        case .performance: LivePalette(base: 0x781C00, 0x3B0F00, 0xFF4500, 0xFF7A00)
        case .applications: LivePalette(base: 0x002761, 0x000A3D, 0x8008DE, 0x246EFF)
        case .clutter: LivePalette(base: 0x004A47, 0x002E2B, 0x009EC2, 0x00C9BF)
        case .spaceLens: LivePalette(base: 0x120A33, 0x12002F, 0x6100C2, 0x7E0BFF)
        case .myTools, .activity: LivePalette(base: 0x170F2E, 0x292469, 0x5957A3, 0x47577D)
        }
    }

    /// Colours of the round action button, left to right.
    var aurora: [Color] {
        let hex: [UInt32] = switch self {
        case .smartCare: [0x6783FF, 0x6087EC, 0xF55BB1, 0xF98762, 0xB6A691]
        case .cleanup: [0xB1AE3C, 0x8FB73B, 0x84C139, 0x7BBB50, 0x6BBB84]
        case .protection: [0xC378CE, 0xEB61BA, 0xFC5CB4, 0xF95DA8, 0xFA6F8D]
        case .performance: [0xF9806E, 0xFA914E, 0xFD9D49, 0xEF9B41, 0xD1A43F]
        case .applications: [0x6085FF, 0x2E93FF, 0x289EFF, 0x3791F8, 0x7B80E4]
        case .clutter: [0x58BBB5, 0x43BBDF, 0x49C0F1, 0x4BB4F0, 0x729DF4]
        case .spaceLens: [0x817EFE, 0x845BFE, 0x8450FE, 0x8D51FE, 0x9B51FF]
        case .myTools, .activity: [0x5954A5, 0x594C98, 0x57498F, 0x61499A, 0x7148A8]
        }
        return hex.map(Color.init(hex:))
    }
}

struct LiveBackground: View {
    let palette: LivePalette
    var paused = false

    /// Each gradient rotates around its anchor point, which sits at the window centre. Sizes are relative to the view.
    private static let layers: [(anchor: CGFloat, size: CGSize, angle: Double)] = [
        (-0.1389, CGSize(width: 1.2, height: 2.1), .pi / 12),
        (0.00664, CGSize(width: 1.0, height: 1.7), -.pi / 3),
        (0, CGSize(width: 1.6, height: 1.6), .pi),
    ]
    /// Seconds per full turn.
    static let period = 20.0
    /// Shared by every instance, so a cross-fade between two modules keeps the gradients in step.
    private static let start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || Motion.reduced)) { timeline in
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.base))
                let turn = 2 * .pi * timeline.date.timeIntervalSince(Self.start) / Self.period
                for (layer, color) in zip(Self.layers, palette.blobs) {
                    var c = ctx
                    let w = layer.size.width * size.width, h = layer.size.height * size.height
                    c.translateBy(x: size.width / 2, y: size.height / 2)
                    c.rotate(by: .radians(-(layer.angle + turn)))
                    c.translateBy(x: (0.5 - layer.anchor) * w, y: 0)
                    c.scaleBy(x: w / 2, y: h / 2)
                    c.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                           with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: .zero, startRadius: 0, endRadius: 1))
                }
            }
        }
    }
}

/// Pauses while the app is in the background, like the window it decorates.
struct AppActivePause: ViewModifier {
    @Binding var paused: Bool
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in paused = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in paused = false }
    }
}

/// Full-window live background; a module change cross-fades to the new palette.
struct ModuleBackground: View {
    let module: Module
    @State private var shown: Module
    @State private var outgoing: Module?
    @State private var fade = 1.0
    @State private var paused = false

    init(module: Module) {
        self.module = module
        _shown = State(initialValue: module)
    }

    var body: some View {
        ZStack {
            if let outgoing { LiveBackground(palette: outgoing.live, paused: paused) }
            LiveBackground(palette: shown.live, paused: paused).opacity(fade)
        }
        .ignoresSafeArea()
        .modifier(AppActivePause(paused: $paused))
        .onChange(of: module) { new in
            guard new != shown else { return }
            outgoing = shown
            shown = new
            guard let animation = Motion.animation(.easeInOut(duration: 0.6)) else { outgoing = nil; return }
            fade = 0
            withAnimation(animation) { fade = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { if fade == 1 { outgoing = nil } }
        }
    }
}

/// The swirling colour disc of the round action button: the module's colours turn slowly and are blurred together.
struct AuroraDisc: View {
    let colors: [Color]
    /// Radians per second.
    var speed = 0.5

    var body: some View {
        TimelineView(.animation(paused: Motion.reduced)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000) * speed
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                ZStack {
                    Circle().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .rotationEffect(.radians(t))
                    // A smaller counter-rotating copy, drifting off centre, gives the swirl.
                    Circle().fill(LinearGradient(colors: colors.reversed(), startPoint: .leading, endPoint: .trailing))
                        .frame(width: d * 0.7, height: d * 0.7)
                        .offset(x: d * 0.12 * cos(t * 1.3), y: d * 0.12 * sin(t * 1.3))
                        .rotationEffect(.radians(-t * 1.7))
                        .opacity(0.65)
                }
                .frame(width: d, height: d)
                .blur(radius: d * 0.08)
                .mask(Circle().fill(RadialGradient(colors: [.white, .white, .white.opacity(0)], center: .center,
                                                   startRadius: 0, endRadius: d / 2)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Fades and lifts a view in when it appears, after `delay`.
struct AppearEffect: ViewModifier {
    var delay: Double = 0
    var offset: CGSize = CGSize(width: 0, height: 14)
    var scale: CGFloat = 1
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(shown ? .zero : offset)
            .scaleEffect(shown ? 1 : scale)
            .onAppear {
                guard let animation = Motion.animation(.spring(response: 0.55, dampingFraction: 0.82).delay(delay)) else { shown = true; return }
                withAnimation(animation) { shown = true }
            }
    }
}

extension View {
    func appear(delay: Double = 0, offset: CGSize = CGSize(width: 0, height: 14), scale: CGFloat = 1) -> some View {
        modifier(AppearEffect(delay: delay, offset: offset, scale: scale))
    }
}

/// Tile surface: a soft vertical gradient with a gradient border, lighter at the top.
struct GlassTile: ViewModifier {
    var cornerRadius: CGFloat = 16
    var highlighted = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let lift = highlighted ? 1.6 : 1
        // Dark Mode tiles are faint white glass; Light Mode tiles are frosted white with a hairline edge.
        let fill = dark ? [Color.white.opacity(0.13 * lift), .white.opacity(0.05 * lift)] : [Color.white.opacity(0.62 + 0.1 * (lift - 1)), .white.opacity(0.38)]
        let edge = dark ? [Color.white.opacity(0.32 * lift), .white.opacity(0.04)] : [Color.white.opacity(0.95), .black.opacity(0.06 * lift)]
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(
                LinearGradient(colors: fill, startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(
                LinearGradient(colors: edge, startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

extension View {
    func glassTile(cornerRadius: CGFloat = 16, highlighted: Bool = false) -> some View {
        modifier(GlassTile(cornerRadius: cornerRadius, highlighted: highlighted))
    }
}

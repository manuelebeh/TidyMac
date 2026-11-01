import SwiftUI

/// The round action button straddling the window's bottom edge. A window clips its content, so the button and its halo
/// are drawn in a borderless child panel that follows the place this view takes in the layout.
struct EdgeButton<Content: View>: View {
    @ViewBuilder let content: Content
    /// Room for the button's halo around it.
    static var side: CGFloat { 300 }
    /// How far the button's centre sits above the window's bottom edge; about a third of the button hangs below it.
    static var lift: CGFloat { 16 }

    var body: some View {
        WindowOverflow(content: content.environment(\.colorScheme, .dark))
            .frame(width: Self.side, height: Self.side)
            .padding(.bottom, Self.lift - Self.side / 2)
    }
}

/// Shows its content in a child panel laid exactly over its own frame, so the content can spill past the window.
struct WindowOverflow<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> Anchor { Anchor(root: root) }
    func updateNSView(_ view: Anchor, context: Context) { view.host.rootView = root }
    private var root: AnyView { AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity)) }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }

    final class Anchor: NSView {
        let host: Host
        private let panel: NSPanel
        private var observers: [Any] = []

        /// Takes clicks while the main window, not this panel, is key.
        final class Host: NSHostingView<AnyView> {
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        }

        init(root: AnyView) {
            host = Host(rootView: root)
            // The panel takes the anchor's size; the hosted button must not shrink it to its own.
            host.sizingOptions = []
            panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                },
                // A sheet covers the window; the button must not float above it.
                center.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.panel.orderOut(nil) }
                },
                center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.attach() }
                },
            ]
            DispatchQueue.main.async { self.attach() }
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); place() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); place() }

        private func attach() {
            guard let window, window.attachedSheet == nil, panel.parent == nil else { return }
            place()
            window.addChildWindow(panel, ordered: .above)
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = Motion.reduced ? 0 : 0.3; panel.animator().alphaValue = 1 }
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        private func place() {
            guard let window, bounds.width > 0 else { return }
            panel.setFrame(window.convertToScreen(convert(bounds, to: nil)), display: true)
        }
    }
}

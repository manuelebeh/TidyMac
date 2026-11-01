import SwiftUI
import Combine

/// The menu bar item and its panel. SwiftUI's MenuBarExtra window grows with its content but never shrinks back,
/// which left an invisible strip under the menu, so TidyMac shows its own panel, pinned to the top right of the
/// screen. It closes on a click elsewhere, on the item again, or on Escape.
@MainActor
final class TrayController: NSObject {
    private(set) static weak var shared: TrayController?
    private let app: AppState
    private let monitor: MonitorModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = TrayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var monitors: [Any] = []
    private var changes: AnyCancellable?
    private var attention: Bool?
    private var top: CGFloat = 0
    /// Gap between the panel and the menu bar or the screen edge.
    static let margin: CGFloat = 8

    /// Takes the keyboard (Escape) without activating TidyMac.
    private final class TrayPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    init(app: AppState, monitor: MonitorModel) {
        self.app = app; self.monitor = monitor
        super.init()
        // The content reports its size, but sets no minimum or maximum on the panel: TrayView sizes it (`fitWindow`).
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        item.button?.target = self
        item.button?.action = #selector(toggle)
        updateIcon()
        // Whatever resizes the panel, its top stays under the menu bar.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, abs(self.panel.frame.maxY - self.top) > 0.5 else { return }
                self.panel.setFrameTopLeftPoint(NSPoint(x: self.panel.frame.minX, y: self.top))
            }
        }
        changes = monitor.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.updateIcon() } }
        Self.shared = self
    }

    var isOpen: Bool { panel.isVisible }

    @objc func toggle() { isOpen ? close() : open() }

    func open() {
        guard !isOpen else { return }
        host.rootView = AnyView(TrayView(app: app, monitor: monitor))
        let size = host.fittingSize
        let screen = item.button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        top = visible.maxY - Self.margin
        panel.setFrame(NSRect(x: visible.maxX - Self.margin - size.width, y: visible.maxY - Self.margin - size.height,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = Motion.reduced ? 0 : 0.15; panel.animator().alphaValue = 1 }
        item.button?.highlight(true)
        watchOutsideClicks()
    }

    func close() {
        guard isOpen else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        item.button?.highlight(false)
        panel.orderOut(nil)
        // Ends TrayView, which stops the fast readings and closes the detail panel.
        host.rootView = AnyView(EmptyView())
    }

    private func watchOutsideClicks() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            let escape = event.type == .keyDown && event.keyCode == 53
            guard event.type != .keyDown || escape else { return event }
            let window = event.window
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if escape { self.close(); return true }
                // Clicks in the panel, its detail panel or on the menu bar item (which toggles) keep it open.
                let mine = [self.panel] + (self.panel.childWindows ?? []) + [self.item.button?.window].compactMap { $0 }
                if !mine.contains(where: { $0 === window }) { self.close() }
                return false
            }
            return swallow ? nil : event
        }) { monitors.append(local) }
    }

    private func updateIcon() {
        let needs = monitor.needsAttention
        guard needs != attention else { return }
        attention = needs
        item.button?.image = MenuBarIcon.image(attention: needs)
    }

    /// The Settings item of the app menu, which works without a SwiftUI scene around the caller.
    static func openSettings() {
        shared?.close()
        guard let menu = NSApp.mainMenu?.items.first?.submenu, let i = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        menu.performActionForItem(at: i)
    }
}

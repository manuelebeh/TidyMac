import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Screen Cleaning Mode, rebuilt from CleanMyMac's ScreenCleaningMode.framework (see REVERSE.md):
/// black windows at the shielding level on every display, the cursor hidden, keyboard and clicks
/// swallowed while the app is in front, and ⌘ Esc as the only way out. The held keys are also polled
/// directly so the way out works even if another window takes focus. A countdown ends the session
/// on its own in case the way out is missed.
@MainActor
final class ScreenCleaningSession: ObservableObject {
    @Published private(set) var active = false
    @Published var showSuccess = false
    @Published private(set) var secondsRemaining = 0
    nonisolated static let duration = 180
    static let reminderKey = "TidyMac.screenCleaningReminder"

    private var windows: [NSWindow] = []
    private var monitor: Any?
    private var timer: Timer?
    private var ticks = 0
    private var savedOptions: NSApplication.PresentationOptions = []

    /// Set when the user turns on reminders; the menu bar recommends a wipe once it has passed.
    static var reminderDue: Bool {
        guard let d = UserDefaults.standard.object(forKey: reminderKey) as? Date else { return false }
        return d <= Date()
    }

    func start(duration: Int = ScreenCleaningSession.duration) {
        guard !active else { return }
        active = true
        secondsRemaining = duration
        ticks = 0
        NSApp.activate(ignoringOtherApps: true)
        savedOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication, .disableAppleMenu]
        for (i, screen) in NSScreen.screens.enumerated() {
            let w = ShieldWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.backgroundColor = .black
            w.isOpaque = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.contentView = NSHostingView(rootView: ScreenCleaningOverlay(session: self, main: i == 0))
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        windows.first?.makeKey()
        NSCursor.hide()
        // Everything that reaches the app is dropped, so wiping cannot type or click anything.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                                                              .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                                              .leftMouseDragged, .scrollWheel, .magnify, .rotate, .swipe]) { [weak self] e in
            if e.type == .keyDown, e.keyCode == UInt16(kVK_Escape), e.modifierFlags.contains(.command) {
                MainActor.assumeIsolated { self?.end() }
            }
            return nil
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let escHeld = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape))
        let cmdHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
        if escHeld && cmdHeld { end(); return }
        ticks += 1
        if ticks % 10 == 0 {
            secondsRemaining -= 1
            if secondsRemaining <= 0 { end() }
        }
    }

    func end() {
        guard active else { return }
        active = false
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        NSApp.presentationOptions = savedOptions
        NSCursor.unhide()
        UserDefaults.standard.removeObject(forKey: Self.reminderKey)
        showSuccess = true
    }

    func turnOnReminders() {
        UserDefaults.standard.set(Date().addingTimeInterval(14 * 86_400), forKey: Self.reminderKey)
    }
}

/// Borderless windows refuse key status by default.
private final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct ScreenCleaningOverlay: View {
    @ObservedObject var session: ScreenCleaningSession
    let main: Bool
    @State private var sweep = false
    @State private var introVisible = true
    private let message = [
        "Thank you for this moment of care 🌱 Your Mac is in good hands — inside and out.",
        "Every swipe counts ✨ When you're done, let us help you find and remove duplicate files too.",
        "While you clean the outside, Space Lens can show you what's taking up space inside 🌱",
        "Files unopened for over a year are most of the clutter 🥰 Large and Old Files can help you take care of them.",
    ].randomElement()!

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                // One wiper pass across the screen when the session starts.
                LinearGradient(colors: [.clear, .white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: sweep ? geo.size.width : -geo.size.width)
                if main {
                    VStack(spacing: 10) {
                        Text("Screen Cleaning Mode").font(.system(size: 34, weight: .light))
                        Text("Your screen is ready — wipe it clean and make it shine.").font(.system(size: 16))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .opacity(introVisible ? 1 : 0)
                    VStack(spacing: 8) {
                        Spacer()
                        Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.28))
                        Text("Press ⌘ Esc to exit · ends on its own in \(session.secondsRemaining / 60):\(String(format: "%02d", session.secondsRemaining % 60))")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.22))
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6)) { sweep = true }
            withAnimation(.easeOut(duration: 1).delay(3)) { introVisible = false }
        }
    }
}

struct ScreenCleaningSuccess: View {
    @ObservedObject var session: ScreenCleaningSession
    @State private var remindersOn = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.yellow)
            Text("Your screen is shining!").font(.title.weight(.semibold))
            Text(remindersOn ? "Great! We'll remind you in 2 weeks."
                 : "A clean screen, a happy Mac. Give your screen a clean every couple of weeks — we can send you a gentle nudge when it's time.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(width: 360)
            HStack {
                if !remindersOn { Button("Turn On Reminders") { session.turnOnReminders(); remindersOn = true } }
                Button("Done") { session.showSuccess = false }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(30)
    }
}

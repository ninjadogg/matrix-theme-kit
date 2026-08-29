import Cocoa
import ScreenSaver
import IOKit.ps

func mlog(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(s)\n".data(using: .utf8)!)
}

/// Desktop-level rain, hardened for the login race.
///
/// At login this agent can start before WindowServer, Finder's desktop, and the
/// hotkey subsystem are ready. Anything set up once at launch is therefore
/// unreliable. Instead every piece of state is re-asserted by a watchdog:
///   - hotkey registration retries until it reports noErr
///   - windows are rebuilt if a screen appears/disappears or one goes missing
///   - window level and ordering are reasserted so Finder's desktop can't bury us
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var views: [MatrixRainView] = []
    private var animTimer: Timer?
    private var watchTimer: Timer?
    private var onBattery = false
    private var tickParity = 0
    private var hotkeyOK = false

    private var desktopLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        mlog("launched; screens=\(NSScreen.screens.count)")
        ensureHotKey()
        rebuild(reason: "startup")

        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in
            self?.step()
        }
        RunLoop.main.add(animTimer!, forMode: .common)

        watchTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.watchdog()
        }
        RunLoop.main.add(watchTimer!, forMode: .common)

        let nc = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didLaunchApplicationNotification,
        ] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.watchdog()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.rebuild(reason: "screen change")
        }
    }

    // MARK: - hotkey

    private func ensureHotKey() {
        guard !hotkeyOK else { return }
        hotkeyOK = HotKeys.register()
        mlog(hotkeyOK ? "hotkey ⌃⌥⌘M registered" : "hotkey registration failed; will retry")
    }

    // MARK: - animation

    private func step() {
        tickParity ^= 1
        if onBattery && tickParity == 0 { return }        // 4fps on battery
        for (i, w) in windows.enumerated() where w.occlusionState.contains(.visible) {
            views[i].animateOneFrame()
        }
    }

    // MARK: - watchdog

    private func watchdog() {
        ensureHotKey()
        checkPower()

        if windows.count != NSScreen.screens.count {
            rebuild(reason: "screen count \(windows.count) != \(NSScreen.screens.count)")
            return
        }
        if windows.isEmpty && !NSScreen.screens.isEmpty {
            rebuild(reason: "no windows but screens exist")
            return
        }
        for w in windows where !w.isVisible || w.level != desktopLevel {
            w.level = desktopLevel
            w.orderFrontRegardless()
            mlog("reasserted a window (visible=\(w.isVisible))")
        }
    }

    private func checkPower() {
        let b = Self.runningOnBattery()
        if b != onBattery { onBattery = b; mlog("power: \(b ? "battery" : "AC")") }
    }

    private static func runningOnBattery() -> Bool {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue()
                    as? [String: Any],
                  let state = d[kIOPSPowerSourceStateKey] as? String else { continue }
            return state == kIOPSBatteryPowerValue
        }
        return false
    }

    // MARK: - windows

    private func rebuild(reason: String) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            mlog("rebuild(\(reason)) skipped: no screens yet, watchdog will retry")
            return
        }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll(); views.removeAll()

        for screen in screens {
            guard let v = MatrixRainView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                         isPreview: false) else { continue }
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.level = desktopLevel
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.isOpaque = true
            w.backgroundColor = .black
            w.hasShadow = false
            w.contentView = v
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w); views.append(v)
        }
        mlog("rebuild(\(reason)): \(windows.count) window(s) on \(screens.count) screen(s)")
    }
}

MatrixRainView.desktopMode = true
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

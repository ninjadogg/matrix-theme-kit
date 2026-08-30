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
    private var animTimer: DispatchSourceTimer?
    private var watchTimer: Timer?
    private var onBattery = false
    private var tickParity = 0
    private var hotkeyOK = false
    /// The desktop window still reports occlusionState .visible underneath a
    /// running screensaver, so the guard in step() never fires and we draw rain
    /// nobody can see. Track it explicitly.
    ///
    /// Notifications are the WHOLE mechanism, deliberately:
    ///  - legacyScreenSaver.appex stays RESIDENT long after the saver is
    ///    dismissed, so "is the process alive" is NOT ground truth — using it
    ///    pinned this paused and froze the desktop.
    ///  - The screensaver's window is absent from CGWindowList, and the only
    ///    things above screenSaverWindow level are the 28x28 camera/mic
    ///    StatusIndicators, permanently present while the camera is in use.
    /// Both fallbacks were tried and both were worse than none.
    private var paused = false
    private var locked = false
    private var frames = 0
    private var ticks = 0
    private var visibleTicks = 0
    private var wasVisible = false
    private var lastFPSReport = Date()
    private var activity: NSObjectProtocol?

    private var desktopLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        mlog("launched; screens=\(NSScreen.screens.count)")
        // ProcessType=Background + LSUIElement makes this agent a prime App Nap
        // target: napped timers coalesce to ~1Hz (worse in Low Power Mode) and
        // the rain crawls. Visible desktop animation is user-facing work.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "desktop rain animation")
        ensureHotKey()
        rebuild(reason: "startup")

        // A .strict dispatch timer opts out of timer coalescing entirely —
        // Low Power Mode (which this Mac enables on battery) coalesces plain
        // Timer/RunLoop timers even for App-Nap-exempt processes.
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / MatrixRainView.saverFPS, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.step() }
        t.resume()
        animTimer = t

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

        // This app is .accessory/LSUIElement, and distributed notifications to a
        // background app are SUSPENDED unless immediate delivery is requested.
        // The block-based addObserver cannot set that and silently never fires.
        let dnc = DistributedNotificationCenter.default()
        for (name, sel) in [("com.apple.screensaver.didstart", #selector(onPause(_:))),
                            ("com.apple.screensaver.didstop",  #selector(onResume(_:))),
                            ("com.apple.screenIsLocked",       #selector(onLock(_:))),
                            ("com.apple.screenIsUnlocked",     #selector(onUnlock(_:)))] {
            dnc.addObserver(self, selector: sel,
                            name: NSNotification.Name(name), object: nil,
                            suspensionBehavior: .deliverImmediately)
        }

        // Lock-screen rain: macOS keeps a running screensaver as the live
        // backdrop of the lock UI, but only timer luck decides whether one is
        // running when the lock engages. Kill the luck: start the saver on
        // lock, stop it when the panel sleeps (nothing to see, don't burn
        // battery), and start it again on wake-while-locked so the rain is
        // already falling when the clock appears.
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                        object: nil, queue: .main) { [weak self] _ in
            guard let self, self.locked else { return }
            self.sweepSaverProcesses()
            mlog("display slept while locked: saver stopped")
        }
        wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                        object: nil, queue: .main) { [weak self] _ in
            guard let self, self.locked else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.locked else { return }
                self.launchSaverIfNeeded(reason: "display woke while locked")
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.rebuild(reason: "screen change")
        }
    }

    @objc private func onPause(_ n: Notification)  { setPaused(true,  reason: n.name.rawValue) }

    @objc private func onLock(_ n: Notification) {
        locked = true
        setPaused(true, reason: n.name.rawValue)
        launchSaverIfNeeded(reason: "screen locked")
    }

    @objc private func onUnlock(_ n: Notification) {
        locked = false
        setPaused(false, reason: n.name.rawValue)
        // The saver engine is dismissed by authentication; sweep any lingerers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.paused else { return }
            self.sweepSaverProcesses()
            mlog("post-unlock sweep of lingering saver processes")
        }
    }

    private func launchSaverIfNeeded(reason: String) {
        let engineRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.ScreenSaver.Engine"
        }
        guard !engineRunning else { return }
        matrixStartScreensaver()
        mlog("lock-screen rain: launched saver (\(reason))")
    }

    private func sweepSaverProcesses() {
        for name in ["ScreenSaverEngine", "legacyScreenSaver"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            // -x matches the process NAME exactly. -f matches the whole
            // command line, so it also killed any unrelated process that
            // merely mentioned the name — a shell running a grep for it, an
            // editor with the file open, a script like this one. Verified
            // that -x still matches: the names are 17 chars, and pkill does
            // not truncate them the way p_comm does at 16.
            p.arguments = ["-x", name]
            try? p.run()
        }
    }
    @objc private func onResume(_ n: Notification) {
        setPaused(false, reason: n.name.rawValue)
        // Both ScreenSaverEngine and legacyScreenSaver.appex can linger after
        // dismissal, animating offscreen; a headless lingering engine also
        // blinds the launchd watchdog, whose rule is engine-alive == saver
        // genuinely up. didstop is the event-precise dismissal signal, so
        // sweep shortly after it — unless the saver started again meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.paused, !self.locked else { return }
            self.sweepSaverProcesses()
            mlog("post-dismissal sweep of lingering saver processes")
        }
    }

    private func setPaused(_ p: Bool, reason: String) {
        guard p != paused else { return }
        paused = p
        mlog(p ? "paused (\(reason))" : "resumed (\(reason))")
    }

    // MARK: - hotkey

    private func ensureHotKey() {
        guard !hotkeyOK else { return }
        hotkeyOK = HotKeys.register()
        mlog(hotkeyOK ? "hotkey ⌃⌥⌘M registered" : "hotkey registration failed; will retry")
    }

    // MARK: - animation

    private func step() {
        if paused { return }
        ticks += 1
        // No battery half-rate: measured cost is ~0.2% of a core — the real
        // savings come from occlusion gating and the pause-under-saver flag.
        let visible = windows.contains { $0.occlusionState.contains(.visible) }
        if visible {
            visibleTicks += 1
            if !wasVisible {
                // Coming out from under opaque windows: repaint immediately so
                // the reveal never shows a stale frame.
                views.forEach { $0.needsDisplay = true }
            }
            for (i, w) in windows.enumerated() where w.occlusionState.contains(.visible) {
                views[i].animateOneFrame()
            }
            frames += 1
        }
        wasVisible = visible
        let now = Date()
        let dt = now.timeIntervalSince(lastFPSReport)
        if dt >= 10 {
            let scale = views.first?.scaleDebug ?? "no views"
            mlog(String(format: "ticks=\(ticks) visible=\(visibleTicks) drew=\(frames) over %.0fs (visible-fps=%.1f) \(scale)",
                        dt, visibleTicks > 0 ? Double(frames)/dt * Double(ticks)/Double(visibleTicks) : 0))
            frames = 0; ticks = 0; visibleTicks = 0; lastFPSReport = now
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

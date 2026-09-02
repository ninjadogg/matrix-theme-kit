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
    private var onBattery = false     // diagnostic only: feeds the power log line
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
    private var ticks = 0
    private var visibleTicks = 0
    private var wasVisible = false
    private var lastFPSReport = Date()
    private var activity: NSObjectProtocol?
    /// didChangeScreenParameters arrives in bursts (twice inside one second,
    /// observed) and fires for far more than real display changes -- an app
    /// going fullscreen or a window crossing displays is enough. Rebuilding
    /// there is what the user sees as the desktop "relaunching": it drops every
    /// view, resets the rain to a blank grid, and stalls the main thread for
    /// seconds. Coalesce the burst, then rebuild only if geometry actually moved.

    private var screenSignature = ""
    private var rebuildDebounce: DispatchWorkItem?

    /// The documented-standard level for a desktop wallpaper window, and what
    /// this has always shipped. Measured live stack (2026-08-31):
    ///     -2147483626  Window Server
    ///     -2147483624  Dock
    ///     -2147483623  .desktopWindow  <- us
    ///     -2147483622  Dock  <- full-screen: the wallpaper, ABOVE us
    ///     -2147483603  .desktopIconWindow
    /// So on current macOS the wallpaper is drawn by DOCK (not Finder) and one
    /// of its windows outranks us. That looks alarming but is benign in
    /// practice -- the rain has always rendered correctly here. Moving to
    /// desktopIconWindow-1 to break the tie WAS tried against the
    /// fullscreen-exit wallpaper flash and changed nothing, so it was reverted
    /// rather than keep an unjustified deviation from the standard config.
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
                self?.reassertWindows(src: name.rawValue)
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
        // needsDisplay only SCHEDULES a repaint, and the next 12fps tick can be
        // 83ms away -- long enough for a fullscreen-exit animation to composite
        // our stale surface and show Dock's wallpaper through. React to the
        // occlusion event itself and paint synchronously.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil, queue: .main) { [weak self] n in
                guard let self, let w = n.object as? NSWindow,
                      let i = self.windows.firstIndex(of: w),
                      w.occlusionState.contains(.visible) else { return }
                self.views[i].animateOneFrame()
                self.views[i].display()
                self.wasVisible = true
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRebuild(reason: "screen change")
        }
    }

    @objc private func onPause(_ n: Notification)  { setPaused(true,  reason: n.name.rawValue) }

    @objc private func onLock(_ n: Notification)   { lockStateChanged(true,  reason: n.name.rawValue) }
    @objc private func onUnlock(_ n: Notification) { lockStateChanged(false, reason: n.name.rawValue) }

    private func lockStateChanged(_ isLocked: Bool, reason: String) {
        locked = isLocked
        setPaused(isLocked, reason: reason)
        if isLocked {
            launchSaverIfNeeded(reason: "screen locked")
        } else {
            // The saver engine is dismissed by authentication; sweep lingerers.
            scheduleSweep(reason: "post-unlock")
        }
    }

    private func launchSaverIfNeeded(reason: String) {
        // A dark panel renders to nobody: locks that follow display sleep
        // (common with 'require password after sleep begins') must not start
        // the saver — the wake handler launches it when there's something to
        // see.
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
            mlog("lock-screen rain: display asleep, deferring launch (\(reason))")
            return
        }
        guard !engineRunning() else { return }
        // Engine absent + appex alive is by definition an orphan (lock -> quick
        // unlock -> re-lock can strand one inside the sweep grace); clear it so
        // the fresh engine doesn't run alongside a second animating appex.
        if processRunning("legacyScreenSaver") {
            sweepSaverProcesses()
        }
        matrixStartScreensaver()
        mlog("lock-screen rain: launched saver (\(reason))")
    }

    /// How long after didstop the sweep first runs, and how long after a launch
    /// an engine is protected from it. These two were independent literals (8
    /// and 15) and silently contradicted each other -- see scheduleSweep.
    private static let sweepDelay: TimeInterval = 8
    private static let launchGrace: TimeInterval = 15

    /// Shared delayed sweep: skips if the saver is (or is about to be) up —
    /// paused/locked re-set, or an engine we launched within the grace window
    /// hasn't posted didstart yet (login-race machines take their time).
    ///
    /// The grace is a DEFERRAL, not a cancellation. The old code ran one shot at
    /// didstop+8 and returned outright if the launch was younger than 15s, so
    /// whenever didstop landed within (15-8)=7s of our own launch the sweep
    /// always fired inside its own grace and dropped silently, with nothing
    /// rescheduling it. `display woke while locked` posts didstop in the same
    /// second we launch, so it hit that window every time; the engine then
    /// survived forever, because applySaverState only sweeps while the display
    /// is ASLEEP. Measured: engines stranded at 0s/0s/2s gaps, swept at
    /// 10s/20s/37s/54s/229s -- no exceptions in 8 events.
    ///
    /// Re-arm for whatever grace is left instead, and log it: a silent return is
    /// what disguised a deterministic leak as an unreproducible ghost.
    private func scheduleSweep(reason: String, after delay: TimeInterval? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? Self.sweepDelay)) { [weak self] in
            guard let self, !self.paused, !self.locked else { return }
            let sinceLaunch = Date().timeIntervalSince(matrixLastSaverLaunch)
            guard sinceLaunch > Self.launchGrace else {
                let remaining = Self.launchGrace - sinceLaunch
                mlog(String(format: "sweep deferred %.1fs inside launch grace (%@)",
                            remaining, reason))
                self.scheduleSweep(reason: reason, after: remaining + 0.5)
                return
            }
            self.sweepSaverProcesses()
            mlog("sweep of lingering saver processes (\(reason))")
        }
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
        // genuinely up. didstop is the event-precise dismissal signal.
        scheduleSweep(reason: "post-dismissal")
    }

    private func setPaused(_ p: Bool, reason: String) {
        guard p != paused else { return }
        paused = p
        // Suspend the coalescing-exempt timer while paused: 12 wakeups/s for
        // the whole duration of every lock would be pure waste. Balanced by
        // the p != paused guard.
        if p { animTimer?.suspend() } else { animTimer?.resume() }
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
        let onScreen = windows.contains { $0.occlusionState.contains(.visible) }
        if onScreen {
            visibleTicks += 1
            if !wasVisible {
                // Coming out from under opaque windows: repaint immediately so
                // the reveal never shows a stale frame.
                views.forEach { $0.needsDisplay = true }
            }
            for (i, w) in windows.enumerated() where w.occlusionState.contains(.visible) {
                views[i].animateOneFrame()
            }
        }
        wasVisible = onScreen
        let now = Date()
        let dt = now.timeIntervalSince(lastFPSReport)
        if dt >= 10 {
            let scale = views.first?.scaleDebug ?? "no views"
            // tick-rate proves the timer isn't coalesced; visible counts the
            // ticks that actually drew (a draw happens on every visible tick,
            // so visible/dt IS the on-screen frame rate).
            mlog(String(format: "ticks=\(ticks) visible=\(visibleTicks) over %.0fs (tick-rate=%.1f/s) \(scale)",
                        dt, Double(ticks)/dt))
            ticks = 0; visibleTicks = 0; lastFPSReport = now
        }
    }

    // MARK: - watchdog

    /// Space changes and app launches fire constantly -- every Cmd-Tab into an
    /// app on another Space lands here. They only need the cheap "did Finder
    /// bury our window" check, so do NOT run the full watchdog: its power and
    /// saver-state reconciliation blocks the main thread (measured 71-111ms),
    /// which stalls the 12fps render timer and reads as a stutter on every
    /// window switch. The 3s timer still runs the full reconciliation.
    private func reassertWindows(src: String) {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard windows.count == NSScreen.screens.count, !windows.isEmpty else {
            rebuild(reason: "reassert(\(src)): window/screen mismatch")
            return
        }
        for w in windows where !w.isVisible || w.level != desktopLevel {
            w.level = desktopLevel
            w.orderFrontRegardless()
            mlog("reasserted a window (visible=\(w.isVisible))")
        }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if ms > 20 { mlog(String(format: "reassert slow: %.0fms src=%@", ms, src)) }
    }

    private func watchdog(src: String = "timer") {
        let t0 = CFAbsoluteTimeGetCurrent()
        var marks: [String] = []
        var t = t0
        func mark(_ label: String) {
            let now = CFAbsoluteTimeGetCurrent()
            marks.append(String(format: "%@=%.0f", label, (now - t) * 1000))
            t = now
        }
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            if ms > 20 { mlog(String(format: "watchdog slow: %.0fms src=%@ [%@]", ms, src, marks.joined(separator: " "))) }
        }
        ensureHotKey();        mark("hotkey")
        checkPower();          mark("power")
        reconcileSaverState(); mark("saverstate")

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
        mark("windows")
    }

    /// DNC delivery is best-effort and this agent can be relaunched mid-saver,
    /// so a missed notification could wedge paused/locked forever. Re-derive
    /// what CAN be re-derived every watchdog tick:
    ///  - locked: the session dictionary is ground truth in both directions.
    ///  - paused stuck true: a saver cannot be displaying with no engine and
    ///    no appex alive — process ABSENCE is reliable (presence is not: the
    ///    appex lingers after dismissal, so it must never set paused).
    ///  - display asleep with an engine alive: nothing is visible, whatever
    ///    the engine's legitimacy — sweep it (wake-while-locked relaunches).
    /// CGSessionCopyCurrentDictionary is a WindowServer round-trip and measured
    /// 38-48ms on the main thread -- half a frame at 12fps, every 3s. This is a
    /// safety net, not a live control path, so a one-cycle lag costs nothing:
    /// sample off-thread, then apply on main.
    private func reconcileSaverState() {
        DispatchQueue.global(qos: .utility).async {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let sysLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
            let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
            DispatchQueue.main.async { [weak self] in
                self?.applySaverState(sysLocked: sysLocked, displayAsleep: displayAsleep)
            }
        }
    }

    /// The remaining probes here (engineRunning, processRunning->pgrep) are only
    /// reached when the display is asleep or we are already paused -- i.e. when
    /// nothing is being rendered, so a stall there is invisible by construction.
    private func applySaverState(sysLocked: Bool, displayAsleep: Bool) {
        if sysLocked != locked {
            mlog("watchdog: reconciling locked \(locked) -> \(sysLocked)")
            lockStateChanged(sysLocked, reason: "watchdog reconcile")
        }
        if displayAsleep, engineRunning(),
           Date().timeIntervalSince(matrixLastSaverLaunch) > Self.launchGrace {
            sweepSaverProcesses()
            mlog("watchdog: swept saver rendering against a sleeping display")
        }
        if paused, !locked, !engineRunning(), !processRunning("legacyScreenSaver") {
            setPaused(false, reason: "watchdog: no saver processes alive")
        }
    }

    private func engineRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.ScreenSaver.Engine"
        }
    }

    private func processRunning(_ exactName: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", exactName]
        p.standardOutput = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    /// IOPSCopyPowerSourcesInfo measured 48ms of a 63ms watchdog -- more than
    /// half a frame at 12fps, burned every 3s on the main thread. onBattery is
    /// diagnostic only (it feeds the log line and nothing else), so there is no
    /// reason to make the render timer wait on it. Query off-thread and hop back
    /// to main only to record a CHANGE.
    private func checkPower() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let b = Self.runningOnBattery()
            DispatchQueue.main.async {
                guard let self, b != self.onBattery else { return }
                self.onBattery = b
                mlog("power: \(b ? "battery" : "AC")")
            }
        }
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

    /// Coalesce a burst of screen-parameter notifications into one evaluation.
    private func scheduleRebuild(reason: String) {
        rebuildDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild(reason: reason) }
        rebuildDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func screenGeometrySignature(_ screens: [NSScreen]) -> String {
        screens.map { s in
            let f = s.frame
            return "\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.width)),\(Int(f.height))@\(s.backingScaleFactor)"
        }.joined(separator: "|")
    }

    private func rebuild(reason: String) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            mlog("rebuild(\(reason)) skipped: no screens yet, watchdog will retry")
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let sig = screenGeometrySignature(screens)

        // The display layout did not move. Reassert the cheap window properties
        // and leave the rain running rather than tearing every view down.
        if sig == screenSignature, windows.count == screens.count, !windows.isEmpty {
            for (w, screen) in zip(windows, screens) {
                if w.frame != screen.frame { w.setFrame(screen.frame, display: true) }
                w.level = desktopLevel
                w.orderFrontRegardless()
            }
            mlog("rebuild(\(reason)) skipped: geometry unchanged")
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
            // Dropping .stationary was tried against the fullscreen-exit flash
            // (2026-08-31) and made the hang WORSE. This trio is also the
            // documented-standard config for a desktop wallpaper window.
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
        screenSignature = sig
        let rms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        mlog(String(format: "rebuild(\(reason)): \(windows.count) window(s) on \(screens.count) screen(s) [\(sig)] took %.0fms", rms))
    }
}

MatrixRainView.desktopMode = true
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

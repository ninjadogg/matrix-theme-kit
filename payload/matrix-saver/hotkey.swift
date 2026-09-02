import Cocoa
import Carbon.HIToolbox

/// When the saver engine was last launched by us; sweeps skip a grace window
/// after this so they can't kill an engine that hasn't posted didstart yet.
var matrixLastSaverLaunch = Date.distantPast

/// pkill the saver processes. Lives here rather than on the app delegate so the
/// hotkey path and the delegate share ONE implementation.
func matrixSweepSaverProcesses() {
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

/// pgrep -x. Blocks on a subprocess, so never call it on the main thread while
/// anything is rendering — see the render-stall notes in main.swift.
func matrixProcessRunning(_ exactName: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", exactName]
    p.standardOutput = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
    catch { return false }
}

/// Launches the screensaver engine. Global (C callback reaches it directly).
///
/// A lingering engine hijacks this: openApplication resolves to the EXISTING
/// instance instead of starting a new one, and an engine wedged in state T
/// never answers the activation handshake, so LaunchServices puts up
/// "The application ScreenSaverEngine is not open anymore" and no saver
/// appears. Observed with an engine stranded for 1h16m: the keypress created
/// no new process and no log line. Clear a stale engine before launching.
///
/// All of it runs off the main thread. This is reached from the Carbon hotkey
/// handler, and pgrep/pkill block on subprocesses while the 12fps render timer
/// lives on main — the exact shape of stall that was measured and removed.
/// Removes an engine that would otherwise hijack the next launch. Split out of
/// matrixStartScreensaver so it can be exercised on its own without putting a
/// screensaver over the display. Blocking; call it off the main thread.
/// Returns true if an engine was there to clear.
@discardableResult
func matrixClearStaleEngine() -> Bool {
    guard matrixProcessRunning("ScreenSaverEngine") else { return false }
    matrixSweepSaverProcesses()
    // Bounded ~1s: don't relaunch into a corpse LaunchServices would still
    // resolve to. Falls through and launches anyway if it will not die, which
    // is no worse than the old unconditional launch.
    for _ in 0..<20 {
        if !matrixProcessRunning("ScreenSaverEngine") { break }
        usleep(50_000)
    }
    return true
}

func matrixStartScreensaver() {
    let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
    DispatchQueue.global(qos: .userInitiated).async {
        matrixClearStaleEngine()
        DispatchQueue.main.async {
            // Set here, not on entry: the grace window must cover the launch we
            // actually perform, not the moment the hotkey was pressed.
            matrixLastSaverLaunch = Date()
            NSWorkspace.shared.openApplication(at: url,
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Real system-wide hotkey via Carbon's RegisterEventHotKey. Unlike a Services
/// key equivalent this binds globally and needs no Accessibility permission.
enum HotKeys {
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false

    @discardableResult
    static func register() -> Bool {
        // Install the Carbon event handler exactly once: the login-race
        // watchdog retries register() every 3s until RegisterEventHotKey
        // succeeds, and each InstallEventHandler call would leak another
        // handler on the app event target.
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            let st = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            if id.id == 1 { matrixStartScreensaver() }
                return noErr
            }, 1, &spec, nil, nil)
            if st == noErr { handlerInstalled = true }
        }

        let id = EventHotKeyID(signature: OSType(0x4D545258), id: 1)   // 'MTRX'
        let mods = UInt32(cmdKey | optionKey | controlKey)             // ⌘⌥⌃
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_M), mods, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            FileHandle.standardError.write(
                "MatrixWallpaper: hotkey registration failed (OSStatus \(status))\n"
                    .data(using: .utf8)!)
            return false
        }
        return true
    }
}

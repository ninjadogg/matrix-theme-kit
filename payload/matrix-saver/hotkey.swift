import Cocoa
import Carbon.HIToolbox

/// When the saver engine was last launched by us; sweeps skip a grace window
/// after this so they can't kill an engine that hasn't posted didstart yet.
var matrixLastSaverLaunch = Date.distantPast

/// Launches the screensaver engine. Global (C callback reaches it directly).
func matrixStartScreensaver() {
    matrixLastSaverLaunch = Date()
    let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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

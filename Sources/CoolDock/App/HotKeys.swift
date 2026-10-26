import AppKit
import Carbon.HIToolbox

/// Global shortcuts via Carbon hot keys (no Accessibility permission needed).
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]

    static let numberKeyCodes: [UInt32] = [
        UInt32(kVK_ANSI_0), UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4),
        UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6), UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
    ]

    func install() {
        uninstall()
        installHandlerIfNeeded()
        let s = AppStore.shared.settings
        var nextID: UInt32 = 1
        if s.toggleHotKey.enabled {
            register(s.toggleHotKey.keyCode, s.toggleHotKey.modifiers, id: nextID) { DockController.shared.toggleVisibility() }
        }
        nextID += 1
        if s.profileHotKeysEnabled {
            for i in 0..<min(AppStore.shared.profiles.count, 8) {
                register(Self.numberKeyCodes[i], s.profileHotKeyModifiers, id: nextID + UInt32(i)) { AppStore.shared.switchProfile(to: i) }
            }
        }
    }

    func uninstall() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    private func register(_ key: UInt32, _ mods: UInt32, id: UInt32, action: @escaping () -> Void) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4344_4B21), id: id) // "CDK!"
        if RegisterEventHotKey(key, mods, hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
            actions[id] = action
        }
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    // MARK: Display helpers

    static func modifierString(_ mods: UInt32) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    static func keyString(_ code: UInt32) -> String {
        let map: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Delete: "⌫", kVK_Tab: "⇥",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
        ]
        if let s = map[Int(code)] { return s }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        data.withUnsafeBytes { raw in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }

    static func display(_ spec: HotKeySpec) -> String { modifierString(spec.modifiers) + keyString(spec.keyCode) }

    /// Converts AppKit modifier flags to the Carbon mask used for registration.
    static func carbonMask(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}
